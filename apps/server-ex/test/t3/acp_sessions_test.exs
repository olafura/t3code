defmodule T3.Acp.SessionsTest do
  use ExUnit.Case, async: false

  alias T3.Acp.Sessions
  alias T3.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    app = Path.join(dir, "app")
    File.mkdir_p!(app)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: app)
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})
    on_exit(fn -> Application.delete_env(:t3, :acp_commands) end)

    start_supervised!(T3.Settings)
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!({Registry, keys: :unique, name: T3.Acp.Registry})
    start_supervised!({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})

    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => app
      })

    assert_receive {:t3_shell, {:rows, _, [{"p1", _}]}}, 1_000
    :ok
  end

  test "sessions list, import once, resume on the first message, and delete" do
    input = %{"instanceId" => "opencode", "projectId" => "p1"}

    assert {:ok, %{"sessions" => [first, second], "canResume" => true, "canDelete" => true}} =
             Sessions.list(input)

    assert %{"sessionId" => "old-1", "title" => "Earlier work", "importedThreadId" => nil} = first
    assert %{"sessionId" => "old/2", "title" => nil} = second

    import = Map.merge(input, %{"sessionId" => "old-1", "title" => "Earlier work"})
    assert {:ok, %{"threadId" => thread_id, "imported" => true}} = Sessions.import(import)

    assert thread_id ==
             "thread:provider:acpRegistry:provider-instance:opencode:native-thread:old-1"

    assert {:ok, %{"threadId" => ^thread_id, "imported" => false}} = Sessions.import(import)

    assert_receive {:t3_shell,
                    {:rows, _, [{^thread_id, {"thread", %{"title" => "Earlier work"}}}]}},
                   1_000

    assert {:ok, %{"sessions" => [%{"importedThreadId" => ^thread_id}, _]}} = Sessions.list(input)

    # The imported thread's first message continues the agent's session.
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "m1",
        "text" => "continue",
        "modelSelection" => %{"instanceId" => "opencode", "model" => "fake/one"}
      })

    state = await_run(thread_id)

    assert [%{"nativeThreadRef" => %{"nativeId" => "old-1"}}] =
             StreamState.list(state, "provider-thread")

    # An imported session is deleted with its thread, not on its own.
    assert {:error, %{"reason" => "session_delete_failed"}} =
             Sessions.delete(Map.put(input, "sessionId", "old-1"))

    assert {:ok, %{"deleted" => true}} = Sessions.delete(Map.put(input, "sessionId", "old/2"))
  end

  test "providers and logout go to the agent" do
    input = %{"instanceId" => "opencode", "projectId" => "p1"}

    assert {:ok,
            %{"providers" => [%{"providerId" => "openai", "current" => %{"apiType" => "openai"}}]}} =
             Sessions.providers(input)

    assert {:ok, %{"configured" => true}} =
             Sessions.set_provider(
               Map.merge(input, %{
                 "providerId" => "openai",
                 "apiType" => "openai",
                 "baseUrl" => "https://x"
               })
             )

    assert {:ok, %{"disabled" => true}} =
             Sessions.disable_provider(Map.put(input, "providerId", "openai"))

    assert {:ok, %{"loggedOut" => true}} = Sessions.logout(%{"instanceId" => "opencode"})
  end

  test "an unknown project is refused" do
    assert {:error, %{"reason" => "project_not_found"}} =
             Sessions.list(%{"instanceId" => "opencode", "projectId" => "nope"})
  end

  defp await_run(thread_id) do
    receive do
      {:t3_stream, ^thread_id, _} ->
        state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))

        case StreamState.list(state, "run") do
          [%{"status" => "completed"} | _] -> state
          _ -> await_run(thread_id)
        end
    after
      10_000 -> flunk("the run did not complete")
    end
  end
end
