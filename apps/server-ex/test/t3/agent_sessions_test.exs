defmodule T3.AgentSessionsTest do
  use ExUnit.Case, async: false

  alias T3.{AgentSessions, StreamState}

  @moduletag :tmp_dir
  @claude_session "0b8f5c1e-4a7d-4c2b-9e1f-2d3c4b5a6f70"

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, Path.join(dir, "t3home"))
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)

    app = Path.join([dir, "work", "app"])
    File.mkdir_p!(Path.join(app, ".git"))

    File.write!(Path.join([app, ".git", "config"]), """
    [core]
    \tbare = false
    [remote "origin"]
    \turl = git@github.com:Acme/App.git
    """)

    claude = Path.join(dir, "claude")
    codex = Path.join(dir, "codex")
    put_env("CLAUDE_CONFIG_DIR", claude)
    put_env("CODEX_HOME", codex)

    jsonl(Path.join([claude, "projects", "-work-app", "#{@claude_session}.jsonl"]), [
      %{
        "type" => "user",
        "cwd" => app,
        "sessionId" => @claude_session,
        "timestamp" => "2026-09-20T10:00:00.000Z",
        "message" => %{"role" => "user", "content" => "Fix the login bug\nplease"}
      },
      # A huge tool result line is skipped without being decoded.
      String.duplicate("x", 5 * 1024 * 1024),
      %{"type" => "assistant", "isSidechain" => true, "message" => %{"content" => "ignored"}},
      %{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "tool_result", "content" => "output"}]}
      },
      %{
        "type" => "assistant",
        "timestamp" => "2026-09-20T10:01:00.000Z",
        "message" => %{
          "model" => "claude-x",
          "content" => [%{"type" => "text", "text" => "Fixed."}]
        }
      }
    ])

    # Last active three days ago.
    File.touch!(
      Path.join([claude, "projects", "-work-app", "#{@claude_session}.jsonl"]),
      System.os_time(:second) - 3 * 86_400
    )

    jsonl(Path.join([codex, "sessions", "2026", "09", "20", "rollout-2026-09-20-a.jsonl"]), [
      %{"type" => "session_meta", "payload" => %{"id" => "codex-s1", "cwd" => app}},
      %{"type" => "turn_context", "payload" => %{"model" => "gpt-x"}},
      %{
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "<setup>\nAdd tests"}]
        }
      },
      %{
        "type" => "event_msg",
        "payload" => %{"type" => "user_message", "message" => "Add tests"}
      },
      %{
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Added."}]
        }
      }
    ])

    # A session in a directory that is gone is not a candidate.
    jsonl(Path.join([codex, "sessions", "2026", "09", "19", "rollout-2026-09-19-b.jsonl"]), [
      %{"type" => "session_meta", "payload" => %{"id" => "codex-s2", "cwd" => "/nope/gone"}}
    ])

    %{app: app}
  end

  test "a scan finds the project both agents ran in, with its GitHub identity", %{app: app} do
    assert {:ok, %{"candidates" => [candidate]}} = AgentSessions.scan()

    assert %{
             "path" => ^app,
             "title" => "app",
             "threadCount" => 2,
             "alreadyImported" => false,
             "git" => %{"remoteKey" => "github.com/acme/app", "repository" => "Acme/App"}
           } = candidate

    assert Enum.sort(candidate["sources"]) == ["claudeAgent", "codex"]
  end

  test "importing a project turns its sessions into resumable threads", %{app: app} do
    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => app
      })

    assert_receive {:t3_shell, {:rows, _, [{"p1", _}]}}, 1_000

    assert {:ok, %{"candidates" => [%{"alreadyImported" => true, "projectId" => "p1"}]}} =
             AgentSessions.scan()

    assert {:ok, %{"importedCount" => 2, "skippedCount" => 0}} =
             AgentSessions.import_project(%{"projectId" => "p1", "expectedWorkspaceRoot" => app})

    # The wizard imports right after creating a project, before its sidebar row.
    # These sessions already belong to p1, so they stay there.
    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p2",
        "workspaceRoot" => app
      })

    assert {:ok, %{"importedCount" => 0, "skippedCount" => 2}} =
             AgentSessions.import_project(%{"projectId" => "p2"})

    # The row sorts by the session's last activity, not the import.
    assert {"thread", %{"updatedAt" => updated}} =
             T3.Projection.rebuild("import:claudeAgent:#{@claude_session}")

    assert String.starts_with?(updated, Date.to_iso8601(Date.add(Date.utc_today(), -3)))

    claude = thread("import:claudeAgent:#{@claude_session}")
    assert %{"title" => "Fix the login bug", "projectId" => "p1"} = thread_entity(claude)
    assert texts(claude) == [{"user", "Fix the login bug\nplease"}, {"assistant", "Fixed."}]

    assert [%{"nativeThreadRef" => %{"nativeId" => @claude_session}}] =
             StreamState.list(claude, "provider-thread")

    # The prompt the user typed, not the response item wrapping it in setup text.
    codex = thread("import:codex:codex-s1")
    assert texts(codex) == [{"user", "Add tests"}, {"assistant", "Added."}]
    assert %{"modelSelection" => %{"model" => "gpt-x"}} = thread_entity(codex)

    # Importing again finds the threads already there.
    assert {:ok, %{"importedCount" => 2}} = AgentSessions.import_project(%{"projectId" => "p1"})

    assert {:error, %{"_tag" => "AgentSessionImportProjectChangedError"}} =
             AgentSessions.import_project(%{"projectId" => "p1", "expectedWorkspaceRoot" => "/x"})

    assert {:error, %{"_tag" => "AgentSessionImportProjectNotFoundError"}} =
             AgentSessions.import_project(%{"projectId" => "p9"})
  end

  test "git config remotes in their quoted, dotted, and fallback forms" do
    assert AgentSessions.origin_url(~s([remote "upstream"]\n url = https://a/b.git\n)) ==
             "https://a/b.git"

    assert AgentSessions.origin_url(
             ~s([remote.Origin]\n url = "ssh://git@host/x/y" # note\n[remote "b"]\nurl = z\n)
           ) == "ssh://git@host/x/y"

    assert AgentSessions.remote_key("https://GitHub.com/Acme/App.git/") == "github.com/acme/app"

    assert AgentSessions.remote_key("git@ssh.dev.azure.com:v3/org/proj/repo") ==
             "dev.azure.com/org/proj/_git/repo"
  end

  defp thread(id), do: T3.Streams.Server.state(T3.Streams.ensure(id))
  defp thread_entity(state), do: state |> StreamState.list("thread") |> hd()

  defp texts(state),
    do: for(m <- StreamState.list(state, "message"), do: {m["role"], m["text"]})

  defp jsonl(path, lines) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Enum.map_join(lines, "\n", fn
        line when is_binary(line) -> line
        record -> JSON.encode!(record)
      end) <> "\n"
    )
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end
end
