defmodule T3.OrchestrationTest do
  use ExUnit.Case, async: false

  alias T3.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    # Threads without a project run in the node's cwd; make that a repo of its own so
    # checkpoints land there and not in this checkout.
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    previous_cwd = File.cwd!()
    File.cd!(work)
    on_exit(fn -> File.cd!(previous_cwd) end)
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :codex_command, ["python3", "-u", @fake_codex])
    Application.put_env(:t3, :claude_command, ["python3", "-u", @fake_claude])
    Application.put_env(:t3, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})

    on_exit(fn ->
      Application.delete_env(:t3, :codex_command)
      Application.delete_env(:t3, :claude_command)
      Application.delete_env(:t3, :acp_commands)
    end)

    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!({Registry, keys: :unique, name: T3.Codex.Registry})
    start_supervised!({Registry, keys: :unique, name: T3.Claude.Registry}, id: :claude_registry)
    start_supervised!({Registry, keys: :unique, name: T3.Acp.Registry}, id: :acp_registry)
    start_supervised!({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})
    %{work: work}
  end

  defp launch(text, instance \\ "codex", mode \\ "full-access", interaction \\ "default") do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-1",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Try codex",
        "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
        "runtimeMode" => mode,
        "interactionMode" => interaction,
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "msg-user-1", "text" => text, "attachments" => []}
      })

    thread_id
  end

  # Waits on the thread's own event stream until its run reaches a terminal status.
  defp await_run(thread_id, status) do
    receive do
      {:t3_stream, ^thread_id, _} ->
        state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))

        case StreamState.list(state, "run") do
          [%{"status" => ^status} | _] -> state
          _ -> await_run(thread_id, status)
        end
    after
      5_000 -> flunk("run never reached #{status}")
    end
  end

  test "a message runs a Codex turn and streams it into the thread" do
    thread_id = launch("list the files")
    state = await_run(thread_id, "completed")

    [run] = StreamState.list(state, "run")
    assert %{"ordinal" => 1, "startedAt" => started, "completedAt" => completed} = run
    assert started && completed

    items = StreamState.list(state, "turn-item")

    assert Enum.map(items, & &1["type"]) == [
             "user_message",
             "command_execution",
             "assistant_message",
             "checkpoint"
           ]

    assert Enum.map(items, & &1["ordinal"]) == [0, 1, 2, 3]

    [_user, command, answer, _checkpoint] = items

    assert %{"input" => "ls", "output" => "a.txt\n", "exitCode" => 0, "status" => "completed"} =
             command

    assert %{"text" => "Hello from codex", "streaming" => false, "status" => "completed"} = answer

    assert [%{"role" => "user"}, %{"role" => "assistant", "text" => "Hello from codex"}] =
             StreamState.list(state, "message")

    assert [%{"status" => "idle", "nativeThreadRef" => %{"nativeId" => "native-thread-1"}}] =
             StreamState.list(state, "provider-thread")

    assert [%{"status" => "completed"}] = StreamState.list(state, "provider-turn")
    # Every run, node, and item points at entities that exist.
    nodes = StreamState.get(state, "node")
    assert Map.has_key?(nodes, run["rootNodeId"])
    assert Enum.all?(items, &Map.has_key?(nodes, &1["nodeId"]))
  end

  test "streamed text is stored as appends, not re-sent whole" do
    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")

    patches =
      T3.Store.reduce_stream(T3.Store.path(), thread_id, 0, [], fn e, acc ->
        if e.entity == "turn-item:codex:msg-1", do: [e.patch | acc], else: acc
      end)

    assert Enum.any?(patches, &Map.has_key?(&1, "a"))
    refute Enum.any?(patches, &(get_in(&1, ["s", "text"]) == "Hello from codex"))
  end

  test "interrupt ends the running turn" do
    thread_id = launch("wait for me")
    _ = await_run(thread_id, "running")

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    state = await_run(thread_id, "interrupted")
    assert [%{"status" => "interrupted"}] = StreamState.list(state, "run-attempt")
  end

  test "a message's image upload reaches codex inline, with where it is saved" do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      T3.Attachments.create_upload_url(%{
        "name" => "a.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(png)
      })

    :ok = T3.Attachments.store(token, png)

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Look",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "look at this",
          "attachments" => [
            %{
              "type" => "image",
              "id" => id,
              "name" => "a.png",
              "mimeType" => "image/png",
              "sizeBytes" => byte_size(png)
            }
          ]
        }
      })

    state = await_run(thread_id, "completed")
    items = StreamState.list(state, "turn-item")
    assert Enum.any?(items, &(&1["text"] == "input text,image saved True"))

    assert %{"attachments" => [%{"id" => "thread-" <> _}]} =
             StreamState.get(state, "message")["m1"]
  end

  test "inline context reaches the agent as markers and an envelope, and stays on the message" do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(thread_id, self(), nil)
    skill = %{"version" => 1, "contextId" => "ctx_s", "kind" => "skill", "name" => "pinchtab"}

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Context",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "repeat with [$pinchtab](t3-context://v1/skill/ctx_s)",
          "context" => %{"version" => 1, "records" => [skill]},
          "attachments" => []
        }
      })

    state = await_run(thread_id, "completed")

    assert Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["text"] ==
                 "repeat with [Skill: $pinchtab; ref=ctx_s]\n\n<t3_context version=\"1\">\n" <>
                   ~s(<context kind="skill" id="ctx_s">\nname: pinchtab\n</context>\n</t3_context>))
           )

    assert %{"context" => %{"records" => [^skill]}} = StreamState.get(state, "message")["m1"]
  end

  describe "thread settings and plan mode" do
    test "thread commands set the thread's own fields" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      for {type, fields} <- [
            {"thread.metadata.update", %{"title" => "Renamed"}},
            {"thread.interaction-mode.set", %{"interactionMode" => "plan"}},
            {"thread.runtime-mode.set", %{"runtimeMode" => "approval-required"}},
            {"thread.pin", %{"orderKey" => "a0"}},
            {"thread.visit", %{"visitedAt" => "2026-09-23T12:00:00.000Z"}},
            {"thread.visit", %{"visitedAt" => "2026-09-23T11:00:00.000Z"}},
            {"thread.archive", %{}}
          ] do
        {:ok, _} =
          Orchestration.dispatch(Map.merge(%{"type" => type, "threadId" => thread_id}, fields))
      end

      assert %{
               "title" => "Renamed",
               "interactionMode" => "plan",
               "runtimeMode" => "approval-required",
               "pinOrderKey" => "a0",
               "pinnedAt" => pinned,
               "lastVisitedAt" => "2026-09-23T12:00:00.000Z",
               "archivedAt" => archived
             } = StreamState.get(current(thread_id), "thread")[thread_id]

      assert is_binary(pinned) and is_binary(archived)
    end

    test "regenerating a title marks it in flight until the attempt ends" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.metadata.update",
          "commandId" => "cmd-regen",
          "threadId" => thread_id,
          "regenerateTitle" => true
        })

      assert %{"titleRegeneration" => %{"requestId" => "cmd-regen"}} =
               StreamState.get(current(thread_id), "thread")[thread_id]

      # No text generator is installed in tests, so the attempt fails and clears it.
      await_thread(thread_id, &(&1["titleRegeneration"] == nil))
    end

    test "codex in plan mode proposes a plan and keeps a todo list; implementing completes it" do
      thread_id = launch("make a plan", "codex", "full-access", "plan")
      state = await_run(thread_id, "completed")

      assert [
               %{"kind" => "proposed_plan", "status" => "active", "markdown" => "# Plan\n- do it"} =
                 plan
             ] =
               Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

      items = StreamState.list(state, "turn-item")

      assert %{"markdown" => "# Plan\n- do it", "streaming" => false, "status" => "completed"} =
               Enum.find(items, &(&1["type"] == "proposed_plan"))

      assert %{
               "steps" => [%{"status" => "completed"}, %{"status" => "running"}],
               "explanation" => "Two steps"
             } =
               Enum.find(items, &(&1["type"] == "todo_list"))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => "m-implement",
          "text" => "go ahead",
          "attachments" => [],
          "sourcePlanRef" => %{"threadId" => thread_id, "planId" => plan["id"]},
          "dispatchMode" => %{"type" => "start_immediately"}
        })

      state = await_statuses(thread_id, ["completed", "completed"])
      assert %{"status" => "completed"} = StreamState.get(state, "plan")[plan["id"]]
    end

    test "codex outside plan mode is told so" do
      thread_id = launch("make a plan", "codex")
      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "mode default"))
    end

    test "claude's ExitPlanMode becomes the proposed plan, and TodoWrite a todo list" do
      thread_id = launch("make a plan", "claudeAgent", "full-access", "plan")
      state = await_run(thread_id, "completed")

      assert [%{"status" => "active", "markdown" => "# Plan\n- do it"}] =
               Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

      refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["toolName"] == "ExitPlanMode"))

      thread_id = launch("keep a todo list", "claudeAgent")
      state = await_run(thread_id, "completed")

      assert [%{"kind" => "todo_list", "status" => "active", "steps" => [first, second]}] =
               StreamState.list(state, "plan")

      assert {first["text"], first["status"], second["status"]} ==
               {"Read the code", "completed", "running"}
    end
  end

  test "pull requests link to a thread by host, repository and number" do
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    key = %{"host" => "github.com", "repository" => "t3/code", "number" => 7}

    link = fn url ->
      Orchestration.dispatch(
        Map.merge(key, %{
          "type" => "thread.pull-request.link",
          "threadId" => thread_id,
          "url" => url,
          "source" => "manual"
        })
      )
    end

    {:ok, _} = link.("https://github.com/t3/code/pull/7")
    {:ok, _} = link.("https://github.com/t3/code/pull/7?again")
    thread = StreamState.get(current(thread_id), "thread")[thread_id]

    assert [%{"number" => 7, "url" => "https://github.com/t3/code/pull/7?again"}] =
             thread["pullRequests"]

    {:ok, _} =
      Orchestration.dispatch(
        Map.merge(key, %{"type" => "thread.pull-request.unlink", "threadId" => thread_id})
      )

    assert [] = StreamState.get(current(thread_id), "thread")[thread_id]["pullRequests"]
  end

  test "threads are found by what was said in them, the user's words first" do
    thread_id = launch("hello there")
    await_statuses(thread_id, ["completed"])
    :ok = T3.Shell.subscribe(self())

    # Search lists active threads from the sidebar rows.
    unless T3.Shell.row(node(), thread_id) do
      assert_receive {:t3_shell, _}, 2_000
    end

    assert {:ok, %{"matches" => [%{"threadId" => ^thread_id, "source" => "assistant"} = match]}} =
             T3.Search.threads(%{"query" => "FROM CODEX"})

    assert match["snippet"] == "Hello from codex"

    assert {:ok, %{"matches" => [%{"source" => "user", "snippet" => "hello there"}]}} =
             T3.Search.threads(%{"query" => "hello"})

    assert {:ok, %{"matches" => []}} = T3.Search.threads(%{"query" => "100%"})
  end

  test "a scheduled task sends its prompt into its thread when run" do
    start_supervised!(T3.ScheduledTasks)
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])

    {:ok, %{"task" => task}} =
      T3.ScheduledTasks.upsert(%{
        "title" => "Nightly",
        "prompt" => "where are we",
        "enabled" => false,
        "schedule" => %{"type" => "fixed_time", "timeOfDay" => "03:00"},
        "projectId" => "project-1",
        "threadId" => thread_id,
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    assert %{"nextRunAt" => nil, "lastRunStatus" => "never"} = task

    assert {:ok, %{"task" => %{"lastRunStatus" => "succeeded", "runCount" => 1}}} =
             T3.ScheduledTasks.run_now(%{"id" => task["id"]})

    state = await_statuses(thread_id, ["completed", "completed"])
    assert Enum.any?(StreamState.list(state, "message"), &(&1["text"] == "where are we"))

    {:ok, %{"task" => %{"nextRunAt" => next}}} =
      T3.ScheduledTasks.set_enabled(%{"id" => task["id"], "enabled" => true})

    assert is_binary(next)
    {:ok, _} = T3.ScheduledTasks.delete(%{"id" => task["id"]})
    assert {:ok, %{"tasks" => []}} = T3.ScheduledTasks.list()
  end

  test "an agent's MCP credential reads its own project's threads, and nothing else" do
    start_supervised!(T3.Mcp)
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    :ok = T3.Shell.subscribe(self())

    unless T3.Shell.row(node(), thread_id) do
      assert_receive {:t3_shell, _}, 2_000
    end

    %{authorization: auth} = T3.Mcp.server(thread_id, "codex")
    rpc = &T3.Mcp.handle(auth, JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => 1}, &1)))

    assert {200, %{"result" => %{"serverInfo" => %{"name" => "t3-code"}, "instructions" => text}}} =
             rpc.(%{"method" => "initialize", "params" => %{"protocolVersion" => "2025-06-18"}})

    assert text =~ "t3-code"

    assert {202, nil} =
             T3.Mcp.handle(auth, ~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

    {200, %{"result" => %{"tools" => tools}}} = rpc.(%{"method" => "tools/list"})

    assert Enum.any?(
             tools,
             &(&1["name"] == "t3_thread_list" and &1["inputSchema"]["type"] == "object")
           )

    {200, %{"result" => %{"structuredContent" => listed}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{"name" => "t3_thread_list", "arguments" => %{}}
      })

    assert %{"currentThreadId" => ^thread_id, "threads" => [%{"threadId" => ^thread_id}]} = listed

    {200, %{"result" => %{"structuredContent" => read}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{"name" => "t3_thread_read", "arguments" => %{"threadId" => thread_id}}
      })

    assert Enum.map(read["items"], & &1["type"]) == ["user_message", "assistant_message"]

    # An idle caller cannot change things, and other projects are out of reach.
    {200, %{"result" => %{"isError" => true, "content" => [%{"text" => denied}]}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{
          "name" => "t3_thread_send",
          "arguments" => %{"threadId" => thread_id, "message" => "hi"}
        }
      })

    assert denied =~ "parent_not_active"
    assert {401, _} = T3.Mcp.handle("Bearer nope", "{}")
  end

  test "a running thread delegates a task, and hears the result when the child finishes" do
    start_supervised!(T3.Mcp)
    parent_id = launch("wait here")
    await_statuses(parent_id, ["running"])
    :ok = T3.Shell.subscribe(self())

    unless T3.Shell.row(node(), parent_id) do
      assert_receive {:t3_shell, _}, 2_000
    end

    %{authorization: auth} = T3.Mcp.server(parent_id, "codex")

    call = fn name, arguments ->
      {200, %{"result" => result}} =
        T3.Mcp.handle(
          auth,
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => arguments}
          })
        )

      result
    end

    %{"structuredContent" => %{"taskId" => task_id, "childThreadId" => child_id}} =
      call.("delegate_task", %{"task" => "hello", "title" => "Say hello"})

    :ok = T3.Streams.subscribe(child_id, self(), nil)
    await_statuses(child_id, ["completed"])

    child = StreamState.get(current(child_id), "thread")[child_id]

    assert %{"relationshipToParent" => "subagent", "parentThreadId" => ^parent_id} =
             child["lineage"]

    # The parent is still running, so the result waits in its queue.
    state = await_statuses(parent_id, ["running", "queued"])

    assert [%{"status" => "completed", "result" => "Hello from codex"}] =
             StreamState.list(state, "subagent")

    assert Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "delegated_task_result"))

    assert %{
             "structuredContent" => %{
               "workState" => "result_available",
               "summary" => "Hello from codex"
             }
           } =
             call.("task_status", %{"taskId" => task_id})
  end

  describe "queued messages" do
    test "a message sent during a run waits in the queue and starts when the run ends" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      {:ok, _} = send_message(thread_id, "m3", "and once more")

      state = await_statuses(thread_id, ["running", "queued", "queued"])
      [_, second, third] = runs(state)
      assert {second["queuePosition"], third["queuePosition"]} == {1, 2}
      assert %{"text" => "then list the files"} = StreamState.get(state, "message")["m2"]

      # Queued messages join the transcript only when their run starts.
      refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      state = await_statuses(thread_id, ["interrupted", "completed", "completed"])

      assert %{"inputIntent" => "queued_turn", "text" => "then list the files"} =
               Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      assert Enum.all?(runs(state), &(&1["queuePosition"] == nil))
    end

    test "archiving a thread cancels what it had queued" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      _ = await_statuses(thread_id, ["running", "queued"])

      {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})

      assert [_, %{"status" => "cancelled", "queuePosition" => nil}] = runs(current(thread_id))
    end

    test "queued runs can be reordered, edited, and cancelled" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "third")
      [_, second, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      {:ok, _} =
        queue_command("queued-run.reorder", thread_id, third["id"], %{
          "beforeRunId" => second["id"]
        })

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, third["id"], %{"text" => "third, edited"})

      {:ok, _} = queue_command("queued-run.cancel", thread_id, second["id"])

      state = current(thread_id)
      by_id = Map.new(runs(state), &{&1["id"], &1})
      assert %{"status" => "cancelled", "queuePosition" => nil} = by_id[second["id"]]
      assert %{"status" => "queued", "queuePosition" => 1} = by_id[third["id"]]
      assert %{"text" => "third, edited"} = StreamState.get(state, "message")["m3"]
    end

    test "an agent that cannot be steered is interrupted, and the steered message goes next" do
      thread_id = launch("wait for it", "opencode")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "third")
      [active, _, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => thread_id,
          "queuedRunId" => third["id"],
          "targetRunId" => active["id"]
        })

      state = await_statuses(thread_id, ["interrupted", "completed", "completed"])

      # The promoted message ran before the one queued ahead of it.
      order =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(&(&1["messageId"] in ["m2", "m3"]))
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(& &1["messageId"])

      assert order == ["m3", "m2"]
    end

    for instance <- ["codex", "claudeAgent"] do
      test "#{instance}: a message sent during a run steers it" do
        thread_id = launch("wait for it", unquote(instance))
        _ = await_run(thread_id, "running")

        {:ok, _} =
          send_message(thread_id, "m2", "look here instead", %{
            "dispatchMode" => %{"type" => "start_immediately"},
            "deliveryIntent" => "auto"
          })

        state = await_statuses(thread_id, ["completed"])
        items = StreamState.list(state, "turn-item")

        assert %{"inputIntent" => "steer", "runId" => run_id} =
                 Enum.find(items, &(&1["messageId"] == "m2"))

        assert [%{"id" => ^run_id}] = runs(state)
        assert Enum.any?(items, &(&1["text"] == "steered: look here instead"))
      end
    end

    test "a queued message promoted to steer joins the running turn" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      [active, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => thread_id,
          "queuedRunId" => queued["id"],
          "targetRunId" => active["id"]
        })

      state = await_statuses(thread_id, ["completed", "cancelled"])

      assert %{"inputIntent" => "promoted_queued_to_steer", "runId" => run_id} =
               Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      assert run_id == active["id"]
    end

    test "restart interrupts the running turn and starts the message next" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      {:ok, _} =
        send_message(thread_id, "m2", "do this instead", %{
          "dispatchMode" => %{"type" => "start_immediately"},
          "deliveryIntent" => "restart"
        })

      state = await_statuses(thread_id, ["interrupted", "completed"])
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))
    end
  end

  describe "Claude" do
    test "a message runs a Claude turn: thinking, a Bash call, and a streamed answer" do
      thread_id = launch("list the files", "claudeAgent")
      state = await_run(thread_id, "completed")

      items = StreamState.list(state, "turn-item")

      assert Enum.map(items, & &1["type"]) == [
               "user_message",
               "reasoning",
               "command_execution",
               "assistant_message",
               "checkpoint"
             ]

      [_, thinking, command, answer, _checkpoint] = items
      assert %{"text" => "Let me look.", "status" => "completed"} = thinking
      assert %{"input" => "ls", "output" => "a.txt\n", "status" => "completed"} = command

      assert %{"text" => "Hello from claude", "streaming" => false, "status" => "completed"} =
               answer

      assert [
               %{
                 "driver" => "claudeAgent",
                 "nativeThreadRef" => %{"nativeId" => "fake-session-1"}
               }
             ] =
               StreamState.list(state, "provider-thread")

      assert [%{"providerInstanceId" => "claudeAgent"}] = StreamState.list(state, "run")
    end

    test "interrupt ends a Claude run" do
      thread_id = launch("wait for me", "claudeAgent")
      _ = await_run(thread_id, "running")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      assert [%{"status" => "interrupted"}] =
               StreamState.list(await_run(thread_id, "interrupted"), "run-attempt")
    end
  end

  describe "approvals" do
    for {instance, answer_text} <- [{"codex", nil}, {"claudeAgent", "allowed"}] do
      test "#{instance}: a prompt becomes a pending request, and accepting it lets the turn go on" do
        thread_id = launch("approve this", unquote(instance))
        request = await_request(thread_id)
        assert %{"status" => "pending", "kind" => "command"} = request

        assert [%{"type" => "approval_request", "status" => "waiting", "prompt" => "touch x"}] =
                 thread_id
                 |> current()
                 |> StreamState.list("turn-item")
                 |> Enum.filter(&(&1["type"] == "approval_request"))

        assert {:ok, _} =
                 Orchestration.dispatch(%{
                   "type" => "runtime-request.respond",
                   "threadId" => thread_id,
                   "requestId" => request["id"],
                   "decision" => "accept"
                 })

        state = await_run(thread_id, "completed")

        assert [%{"status" => "resolved", "decision" => "accept"}] =
                 StreamState.list(state, "runtime-request")

        if unquote(answer_text) do
          assert Enum.any?(
                   StreamState.list(state, "turn-item"),
                   &(&1["text"] == unquote(answer_text))
                 )
        else
          assert Enum.any?(
                   StreamState.list(state, "turn-item"),
                   &(&1["type"] == "command_execution" and &1["status"] == "completed")
                 )
        end
      end
    end

    # Each fake says what it was told; Claude keys answers by question text.
    for {instance, question_id, told} <- [
          {"codex", "color", ~s(answered {"color": {"answers": ["Red"]}})},
          {"claudeAgent", "Which color?", ~s(answered {"Which color?": "Red"})}
        ] do
      test "#{instance}: a question waits for the user's answer and passes it on" do
        thread_id = launch("ask me", unquote(instance))
        request = await_request(thread_id)
        assert %{"status" => "pending", "kind" => "user_input"} = request

        assert [%{"status" => "waiting", "questions" => [question]}] =
                 thread_id
                 |> current()
                 |> StreamState.list("turn-item")
                 |> Enum.filter(&(&1["type"] == "user_input_request"))

        assert %{"id" => unquote(question_id), "header" => "Color", "question" => "Which color?"} =
                 question

        assert %{"label" => "Red", "description" => "Warm"} = hd(question["options"])

        {:ok, _} =
          Orchestration.dispatch(%{
            "type" => "runtime-request.respond",
            "threadId" => thread_id,
            "requestId" => request["id"],
            "answers" => %{unquote(question_id) => "Red"}
          })

        state = await_run(thread_id, "completed")

        assert [%{"status" => "resolved", "answers" => %{unquote(question_id) => "Red"}}] =
                 StreamState.list(state, "runtime-request")

        assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == unquote(told)))
      end
    end

    test "a file attached to an answer reaches the agent as where it is saved" do
      {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
        T3.Attachments.create_upload_url(%{
          "type" => "file",
          "name" => "notes.txt",
          "mimeType" => "text/plain",
          "sizeBytes" => 5
        })

      :ok = T3.Attachments.store(token, "notes")
      thread_id = launch("ask me")
      request = await_request(thread_id)
      file = %{"type" => "file", "id" => id, "name" => "notes.txt", "sizeBytes" => 5}

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "answers" => %{"color" => "Red"},
          "attachmentsByQuestionId" => %{"color" => [file]}
        })

      state = await_run(thread_id, "completed")

      assert [%{"questionAnswer" => %{"answers" => %{"color" => "Red"}} = answer}] =
               state
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "user_input_request"))

      # The file now belongs to the thread, and the agent was told where it is.
      assert [%{"id" => claimed, "name" => "notes.txt"}] =
               answer["attachmentsByQuestionId"]["color"]

      path = T3.Attachments.path(%{"id" => claimed})
      assert File.read!(path) == "notes"

      assert Enum.any?(
               StreamState.list(state, "turn-item"),
               &String.contains?(&1["text"] || "", ~s(Attached file \\"notes.txt\\": ))
             )
    end

    test "dismissing a question tells Claude no and cancels the request" do
      thread_id = launch("ask me", "claudeAgent")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.user-input.dismiss",
          "threadId" => thread_id,
          "requestId" => request["id"]
        })

      state = await_run(thread_id, "completed")
      assert [%{"status" => "cancelled"}] = StreamState.list(state, "runtime-request")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "denied"))
    end

    test "declining a Claude prompt is passed on to Claude" do
      thread_id = launch("approve this", "claudeAgent")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "decline"
        })

      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "denied"))
    end
  end

  describe "ACP agents (OpenCode)" do
    test "an agent that cannot start fails its run" do
      Application.put_env(:t3, :acp_commands, %{"opencode" => ["/nonexistent/agent"]})

      # The runtime settles the turn itself, before creating its provider turn.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:state, await_run(launch("hello", "opencode"), "failed")})
        end)

      assert_received {:state, state}
      refute log =~ "turn failed to start in"

      assert [%{"status" => "failed"}] = StreamState.list(state, "run-attempt")
      assert [%{"status" => "idle"}] = StreamState.list(state, "provider-thread")
      assert StreamState.list(state, "provider-turn") == []
    end

    test "a turn streams thinking, a command, and the answer; the session is recorded" do
      thread_id = launch("list the files", "opencode")
      state = await_run(thread_id, "completed")

      assert Enum.map(StreamState.list(state, "turn-item"), & &1["type"]) == [
               "user_message",
               "reasoning",
               "command_execution",
               "assistant_message",
               "checkpoint"
             ]

      items = StreamState.list(state, "turn-item")

      assert %{"input" => "ls", "output" => "a.txt\n", "status" => "completed"} =
               Enum.find(items, &(&1["type"] == "command_execution"))

      assert %{"text" => "Hello from acp", "streaming" => false} =
               Enum.find(items, &(&1["type"] == "assistant_message"))

      assert [%{"text" => "Hello from acp", "streaming" => false}] =
               Enum.filter(StreamState.list(state, "message"), &(&1["role"] == "assistant"))

      assert [%{"driver" => "opencode", "nativeThreadRef" => %{"nativeId" => "acp-1"}}] =
               StreamState.list(state, "provider-thread")

      # A follow-up is another prompt on the same session.
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => "msg-user-2",
          "text" => "again"
        })

      state = await_runs(thread_id, 2)
      assert Enum.all?(StreamState.list(state, "run"), &(&1["status"] == "completed"))
    end

    test "a supervised thread asks before a command, and the answer goes to the agent" do
      thread_id = launch("approve the command", "opencode", "approval-required")
      request = await_request(thread_id)
      assert %{"kind" => "command"} = request

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "decline"
        })

      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "not allowed"))
    end

    test "interrupt cancels the prompt" do
      thread_id = launch("wait for it", "opencode")
      await_item(thread_id, "command_execution")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_run(thread_id, "interrupted")
    end
  end

  describe "checkpoints" do
    test "a completed run records what it changed, and its diff is served", %{work: dir} do
      File.write!(Path.join(dir, "before.txt"), "already here\n")
      thread_id = launch("approve the command")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "accept"
        })

      state = await_run(thread_id, "completed")
      scope_id = T3.Checkpoint.scope_id(thread_id)

      assert [%{"id" => ^scope_id, "kind" => "root_run", "cwd" => ^dir}] =
               StreamState.list(state, "checkpoint-scope")

      assert [%{"status" => "ready", "appRunOrdinal" => 1, "files" => files} = checkpoint] =
               StreamState.list(state, "checkpoint")

      # The baseline was taken before the turn, so only the turn's own file shows.
      assert [%{"path" => "x", "additions" => 1}] = files
      assert [%{"checkpointId" => checkpoint_id}] = StreamState.list(state, "run")
      assert checkpoint_id == checkpoint["id"]

      assert %{"type" => "checkpoint", "files" => ^files} =
               state |> StreamState.list("turn-item") |> List.last()

      assert {:ok, %{"diff" => diff, "toTurnCount" => 1}} =
               Orchestration.handle("orchestration.getTurnDiff", %{
                 "threadId" => thread_id,
                 "fromTurnCount" => 0,
                 "toTurnCount" => 1
               })

      assert diff =~ "+++ b/x"
      refute diff =~ "before.txt"

      assert {:ok, %{"diff" => ^diff}} =
               Orchestration.handle("orchestration.getFullThreadDiff", %{
                 "threadId" => thread_id,
                 "toTurnCount" => 1
               })
    end
  end

  describe "checkpoint rollback" do
    # A thread working in `work` as its own worktree, so files can be restored.
    defp launch_in(work, text, instance) do
      thread_id = "thread-#{System.unique_integer([:positive])}"
      :ok = T3.Streams.subscribe(thread_id, self(), nil)

      {:ok, _} =
        Orchestration.launch_thread(%{
          "commandId" => "cmd-1",
          "threadId" => thread_id,
          "projectId" => "project-1",
          "title" => "Rewind",
          "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "workspaceStrategy" => %{
            "type" => "existing_worktree",
            "worktreePath" => work,
            "branch" => "main"
          },
          "initialMessage" => %{"messageId" => "msg-user-1", "text" => text, "attachments" => []}
        })

      thread_id
    end

    defp rollback(thread_id, ordinal, extra \\ %{}) do
      scope_id = T3.Checkpoint.scope_id(thread_id)

      Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "checkpoint.rollback",
            "commandId" => "cmd-rollback",
            "threadId" => thread_id,
            "scopeId" => scope_id,
            "checkpointId" => T3.Checkpoint.checkpoint_id(scope_id, ordinal)
          },
          extra
        )
      )
    end

    test "Codex drops the later turns, the files go back, and the next run diffs from there",
         %{work: work} do
      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      state = current(thread_id)
      assert ["completed", "rolled_back"] = Enum.map(runs(state), & &1["status"])
      assert File.exists?(Path.join(work, "a.txt"))
      refute File.exists?(Path.join(work, "b.txt"))

      assert [%{"lastRunOrdinal" => 1, "nativeThreadRef" => %{"nativeId" => native}}] =
               StreamState.list(state, "provider-thread")

      # Paginated history is cut before the first dropped turn.
      assert native == "native-thread-1-before-native-turn-2"

      assert %{"status" => "stale"} =
               StreamState.get(state, "checkpoint")[
                 T3.Checkpoint.checkpoint_id(T3.Checkpoint.scope_id(thread_id), 2)
               ]

      {:ok, _} = send_message(thread_id, "msg-user-3", "write c.txt")
      state = await_statuses(thread_id, ["completed", "rolled_back", "completed"])

      assert %{"files" => [%{"path" => "c.txt"}]} =
               StreamState.get(state, "checkpoint")[
                 T3.Checkpoint.checkpoint_id(T3.Checkpoint.scope_id(thread_id), 3)
               ]
    end

    test "a legacy Codex thread drops its later turns by count", %{work: work} do
      Application.put_env(:t3, :codex_command, [
        "env",
        "FAKE_CODEX_LEGACY=1",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      assert [%{"nativeThreadRef" => %{"nativeId" => "native-thread-1-dropped-1"}}] =
               StreamState.list(current(thread_id), "provider-thread")
    end

    test "files are only restored in a worktree of the thread's own" do
      thread_id = launch("write a.txt")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:error, "File restore requires an isolated worktree." <> _} = rollback(thread_id, 1)

      # Rewinding only the conversation leaves the files alone.
      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})
      assert ["completed", "rolled_back"] = Enum.map(runs(current(thread_id)), & &1["status"])
      assert File.exists?("b.txt")
    end

    test "Claude resumes the next turn at the last message of the kept turn", %{work: work} do
      thread_id = launch_in(work, "hello", "claudeAgent")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})

      {:ok, _} = send_message(thread_id, "msg-user-3", "where are we")
      state = await_statuses(thread_id, ["completed", "rolled_back", "completed"])

      assert Enum.any?(
               StreamState.list(state, "message"),
               &(&1["text"] == "resumed at uuid-1 fork False history False")
             )
    end
  end

  describe "forks and handoffs" do
    defp fork(source_id, run_id) do
      fork_id = "thread-#{System.unique_integer([:positive])}"
      :ok = T3.Streams.subscribe(fork_id, self(), nil)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.fork",
          "commandId" => "cmd-fork-#{fork_id}",
          "createdBy" => "user",
          "creationSource" => "web",
          "sourceThreadId" => source_id,
          "targetThreadId" => fork_id,
          "sourcePoint" => %{"type" => "run", "runId" => run_id}
        })

      fork_id
    end

    defp replies(state),
      do: for(m <- StreamState.list(state, "message"), m["role"] == "assistant", do: m["text"])

    defp claude, do: %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}

    test "a fork starts with its source's history and continues the native Codex thread" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])

      state = current(fork_id)

      assert %{
               "title" => "Try codex fork",
               "lineage" => %{"parentThreadId" => ^source_id, "relationshipToParent" => "fork"},
               "forkedFrom" => %{"threadId" => ^source_id}
             } = StreamState.get(state, "thread")[fork_id]

      assert [%{"status" => "completed", "threadId" => ^fork_id}] = runs(state)
      assert "Hello from codex" in replies(state)

      assert [%{"type" => "fork", "status" => "pending"}] =
               StreamState.list(state, "context-transfer")

      {:ok, _} = send_message(fork_id, "msg-fork-1", "where are we")
      state = await_statuses(fork_id, ["completed", "completed"])

      assert "on forked-native-thread-1-at-native-turn-1 history False merged False" in replies(
               state
             )

      assert [%{"status" => "consumed", "resolution" => %{"strategy" => "native_fork"}}] =
               StreamState.list(state, "context-transfer")
    end

    test "a fork on another provider gets the history as a transcript" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])

      {:ok, _} = send_message(fork_id, "msg-fork-1", "where are we", claude())
      state = await_statuses(fork_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)

      assert [%{"resolution" => %{"strategy" => "portable_context"}}] =
               StreamState.list(state, "context-transfer")

      assert [%{"strategy" => "full_thread_summary", "summaryText" => summary}] =
               StreamState.list(state, "context-handoff")

      assert summary =~ "User: hello"
      assert summary =~ "Assistant: Hello from codex"
    end

    test "switching provider mid-thread hands the conversation over" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we", claude())
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)
    end

    test "provider.switch moves the next run to the new provider, with the conversation" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])

      {:ok, _} =
        Orchestration.dispatch(
          Map.merge(claude(), %{"type" => "provider.switch", "threadId" => thread_id})
        )

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)
    end

    test "a stopped session starts again on the next run and resumes its thread" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])
      [session] = StreamState.list(current(thread_id), "provider-session")

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "provider-session.detach",
          "threadId" => thread_id,
          "providerSessionId" => session["id"]
        })

      assert [] = StreamState.list(current(thread_id), "provider-session")
      assert [] = Registry.lookup(T3.Codex.Registry, thread_id)

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "on native-thread-1 history False merged False" in replies(state)
      assert [_] = StreamState.list(state, "provider-session")
    end

    test "merging a fork back brings its newer work to the parent's next run" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])
      {:ok, _} = send_message(fork_id, "msg-fork-1", "write fork.txt")
      [_, fork_run] = runs(await_statuses(fork_id, ["completed", "completed"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.merge_back",
          "commandId" => "cmd-merge",
          "createdBy" => "user",
          "sourceThreadId" => fork_id,
          "targetThreadId" => source_id,
          "sourcePoint" => %{"type" => "run", "runId" => fork_run["id"]}
        })

      {:ok, _} = send_message(source_id, "msg-user-2", "where are we")
      state = await_statuses(source_id, ["completed", "completed"])

      assert "on native-thread-1 history False merged True" in replies(state)

      assert [%{"strategy" => "fork_delta_summary", "summaryText" => summary}] =
               StreamState.list(state, "context-handoff")

      # Only the fork's own work, not the history it started with.
      assert summary =~ "User: write fork.txt"
      refute summary =~ "User: hello"
    end
  end

  defp await_thread(thread_id, done?) do
    if done?.(StreamState.get(current(thread_id), "thread")[thread_id]) do
      :ok
    else
      receive do
        {:t3_stream, ^thread_id, _} -> await_thread(thread_id, done?)
      after
        5_000 -> flunk("the thread never got there")
      end
    end
  end

  defp await_runs(thread_id, count) do
    receive do
      {:t3_stream, ^thread_id, _} ->
        state = current(thread_id)
        runs = StreamState.list(state, "run")

        if length(runs) == count and Enum.all?(runs, &(&1["status"] == "completed")),
          do: state,
          else: await_runs(thread_id, count)
    after
      5_000 -> flunk("runs never completed")
    end
  end

  defp await_item(thread_id, type) do
    receive do
      {:t3_stream, ^thread_id, _} ->
        if Enum.any?(StreamState.list(current(thread_id), "turn-item"), &(&1["type"] == type)),
          do: :ok,
          else: await_item(thread_id, type)
    after
      5_000 -> flunk("no #{type} item")
    end
  end

  defp current(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp send_message(thread_id, message_id, text, extra \\ %{}) do
    Orchestration.dispatch(
      Map.merge(
        %{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => message_id,
          "text" => text,
          "attachments" => [],
          "dispatchMode" => %{"type" => "queue_after_active"}
        },
        extra
      )
    )
  end

  defp queue_command(type, thread_id, run_id, extra \\ %{}),
    do:
      Orchestration.dispatch(
        Map.merge(%{"type" => type, "threadId" => thread_id, "runId" => run_id}, extra)
      )

  # Waits until the thread's runs, in order, have these statuses.
  defp await_statuses(thread_id, statuses) do
    state = current(thread_id)

    if Enum.map(runs(state), & &1["status"]) == statuses do
      state
    else
      receive do
        {:t3_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 ->
          flunk(
            "runs never reached #{inspect(statuses)}: #{inspect(Enum.map(runs(state), & &1["status"]))}"
          )
      end
    end
  end

  defp await_request(thread_id) do
    receive do
      {:t3_stream, ^thread_id, _} ->
        case thread_id |> current() |> StreamState.list("runtime-request") do
          [%{"status" => "pending"} = request] -> request
          _ -> await_request(thread_id)
        end
    after
      5_000 -> flunk("no approval request")
    end
  end
end
