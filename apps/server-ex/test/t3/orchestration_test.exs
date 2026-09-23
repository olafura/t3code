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

  defp launch(text, instance \\ "codex", mode \\ "full-access") do
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
        "interactionMode" => "default",
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

  test "a second message while a run is active is rejected, and interrupt ends the run" do
    thread_id = launch("wait for me")
    _ = await_run(thread_id, "running")

    assert {:error, "a run is already active" <> _} =
             Orchestration.dispatch(%{
               "type" => "message.dispatch",
               "threadId" => thread_id,
               "messageId" => "msg-2",
               "text" => "again"
             })

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    state = await_run(thread_id, "interrupted")
    assert [%{"status" => "interrupted"}] = StreamState.list(state, "run-attempt")
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
