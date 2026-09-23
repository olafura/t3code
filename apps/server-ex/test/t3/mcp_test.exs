defmodule T3.McpTest do
  use ExUnit.Case, async: false

  alias T3.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @project "project-mcp"

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    {_, 0} =
      System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m init),
        cd: work
      )

    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:t3, :codex_command) end)

    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!({Registry, keys: :unique, name: T3.Codex.Registry})
    start_supervised!({Registry, keys: :unique, name: T3.Claude.Registry}, id: :claude_registry)
    start_supervised!({Registry, keys: :unique, name: T3.Acp.Registry}, id: :acp_registry)
    start_supervised!({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})
    start_supervised!(T3.Mcp)
    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => @project,
        "title" => "Work",
        "workspaceRoot" => work
      })

    await_row(@project)
    %{work: work, dir: dir}
  end

  test "an agent launches a thread and works its own queue" do
    {caller, tool} = caller("wait for it")

    {:ok, launched} = tool.("t3_thread_launch", %{"title" => "Side quest", "message" => "hello"})
    assert %{"projectId" => @project, "runId" => run_id} = launched
    assert is_binary(run_id)
    launched_id = launched["threadId"]

    assert [%{"status" => "completed"}] = runs(await_statuses(launched_id, ["completed"]))

    assert %{"createdBy" => "agent", "creationSource" => "mcp", "title" => "Side quest"} =
             StreamState.get(current(launched_id), "thread")[launched_id]

    {:ok, _} = tool.("t3_thread_send", %{"message" => "first later", "mode" => "queue"})
    {:ok, _} = tool.("t3_thread_send", %{"message" => "second later", "mode" => "queue"})
    [_, first, second] = runs(await_statuses(caller, ["running", "queued", "queued"]))

    {:ok, %{"items" => items, "nextCursor" => nil}} = tool.("t3_queue_list", %{})
    assert Enum.map(items, & &1["text"]) == ["first later", "second later"]

    {:ok, _} =
      tool.("t3_queue_edit", %{"queuedRunId" => second["id"], "text" => "second, edited"})

    {:ok, _} =
      tool.("t3_queue_reorder", %{
        "queuedRunId" => second["id"],
        "beforeRunId" => first["id"]
      })

    {:ok, _} = tool.("t3_queue_cancel", %{"queuedRunId" => first["id"]})

    {:ok, %{"items" => items}} = tool.("t3_queue_list", %{})
    assert [%{"queuedRunId" => id, "text" => "second, edited"}] = items
    assert id == second["id"]

    assert {:ok, %{"text" => "second, edited", "truncated" => false}} =
             tool.("t3_queue_read", %{"queuedRunId" => id})

    assert {:error, text} = tool.("t3_queue_cancel", %{"queuedRunId" => first["id"]})
    assert text =~ "invalid_request"
  end

  test "an agent answers a pending question through MCP" do
    {caller, tool} = caller("ask me")
    request = await_request(caller)

    assert {:ok, %{"requestIds" => [id]}} = tool.("t3_pending_request_list", %{})
    assert id == request["id"]

    assert {:ok, %{"questions" => [%{"id" => "color", "question" => "Which color?"}]}} =
             tool.("t3_pending_request_read", %{"requestId" => id})

    assert {:ok, %{"sequence" => _}} =
             tool.("t3_pending_request_respond", %{
               "requestId" => id,
               "answers" => %{"color" => "Red"}
             })

    state = await_statuses(caller, ["completed"])

    assert [%{"status" => "resolved", "answers" => %{"color" => "Red"}}] =
             StreamState.list(state, "runtime-request")

    assert {:ok, %{"requestIds" => []}} = tool.("t3_pending_request_list", %{})
  end

  test "an agent registers and updates projects, and lists its workspace's branches", %{
    dir: dir,
    work: work
  } do
    {_caller, tool} = caller("wait for it")
    root = Path.join(dir, "other")

    {:ok, project} =
      tool.("t3_project_create", %{
        "title" => "Other",
        "workspaceRoot" => root,
        "createWorkspaceRootIfMissing" => true
      })

    assert %{"title" => "Other", "workspaceRoot" => ^root} = project
    assert File.dir?(root)
    await_row(project["id"])

    assert {:error, text} =
             tool.("t3_project_create", %{"title" => "Again", "workspaceRoot" => work})

    assert text =~ "already registered"

    assert {:ok, %{"title" => "Renamed", "autoPull" => true}} =
             tool.("t3_project_update", %{
               "projectId" => project["id"],
               "title" => "Renamed",
               "autoPull" => true
             })

    assert {:ok, %{"isRepo" => true, "refs" => refs}} = tool.("t3_worktree_list", %{})
    assert Enum.any?(refs, &(&1["name"] == "main"))

    assert {:ok, %{"attached" => false, "projectWorkspaceRoot" => ^work}} =
             tool.("t3_worktree_status", %{})
  end

  test "an agent renames and pins its thread, and links its pull requests" do
    {caller, tool} = caller("wait for it")

    {:ok, %{"title" => "Renamed"}} =
      tool.("t3_thread_update", %{"action" => "rename", "title" => "Renamed"})

    {:ok, _} = tool.("t3_thread_organize", %{"action" => "pin"})
    assert current(caller) |> StreamState.get("thread") |> get_in([caller, "pinnedAt"])

    url = "https://github.com/acme/app/pull/7"

    assert {:ok, %{"host" => "github.com", "number" => 7, "alreadyLinked" => false}} =
             tool.("link_pull_request", %{"url" => url})

    assert {:ok, %{"alreadyLinked" => true}} = tool.("link_pull_request", %{"url" => url})

    assert {:ok, %{"pullRequests" => [%{"url" => ^url, "source" => "agent"}]}} =
             tool.("list_thread_pull_requests", %{})

    assert {:ok, %{"wasLinked" => true}} =
             tool.("unlink_pull_request", %{
               "repository" => "acme/app",
               "number" => 7,
               "host" => "github.com"
             })

    assert {:ok, %{"pullRequests" => []}} = tool.("list_thread_pull_requests", %{})
  end

  test "the new tools are advertised, and an idle caller cannot use them to change things" do
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    await_row(thread_id)
    tool = tool(thread_id)

    %{authorization: auth} = T3.Mcp.server(thread_id, "codex")

    {200, %{"result" => %{"tools" => tools}}} =
      T3.Mcp.handle(
        auth,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      )

    names = Enum.map(tools, & &1["name"])
    assert "t3_queue_list" in names and "t3_thread_launch" in names
    assert "delegate_task" in names and "preview_snapshot" in names

    assert {:ok, %{"threadId" => ^thread_id, "runtimeMode" => "full-access"}} =
             tool.("t3_thread_configuration", %{})

    assert {:error, text} = tool.("t3_thread_launch", %{"title" => "Nope"})
    assert text =~ "parent_not_active"
  end

  # --- helpers ----------------------------------------------------------------------------

  # A running thread of the project and a function calling tools as its agent.
  defp caller(text) do
    thread_id = launch(text)
    await_statuses(thread_id, ["running"])
    await_row(thread_id)
    {thread_id, tool(thread_id)}
  end

  defp tool(thread_id) do
    %{authorization: auth} = T3.Mcp.server(thread_id, "codex")

    fn name, arguments ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      }

      case T3.Mcp.handle(auth, JSON.encode!(request)) do
        {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} ->
          {:error, text}

        {200, %{"result" => %{"structuredContent" => result}}} ->
          {:ok, result}
      end
    end
  end

  defp launch(text) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-#{thread_id}",
        "threadId" => thread_id,
        "projectId" => @project,
        "title" => "Caller",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "msg-#{thread_id}",
          "text" => text,
          "attachments" => []
        }
      })

    thread_id
  end

  defp await_row(id) do
    unless T3.Shell.row(node(), id) do
      receive do
        {:t3_shell, _} -> await_row(id)
      after
        5_000 -> flunk("no sidebar row for #{id}")
      end
    end
  end

  defp current(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  # Waits until the thread's runs, in order, have these statuses.
  defp await_statuses(thread_id, statuses) do
    :ok = T3.Streams.subscribe(thread_id, self(), nil)
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
    case thread_id |> current() |> StreamState.list("runtime-request") do
      [%{"status" => "pending"} = request] ->
        request

      _ ->
        receive do
          {:t3_stream, ^thread_id, _} -> await_request(thread_id)
        after
          5_000 -> flunk("no pending request")
        end
    end
  end
end
