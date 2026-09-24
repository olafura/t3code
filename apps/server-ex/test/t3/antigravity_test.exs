defmodule T3.AntigravityTest do
  use ExUnit.Case, async: false

  alias T3.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake Path.expand("../support/fake_antigravity.py", __DIR__)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    previous_cwd = File.cwd!()
    File.cd!(work)
    on_exit(fn -> File.cd!(previous_cwd) end)

    home = Path.join(dir, "home")
    Application.put_env(:t3, :home, home)

    # A custom runtime: the fake agent and its harness.
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    exe = Path.join(bin, "agy_acp_server.par")
    File.cp!(@fake, exe)
    File.write!(Path.join(bin, "localharness_external"), "#!/bin/sh\n")
    File.chmod!(Path.join(bin, "localharness_external"), 0o755)
    log = Path.join(dir, "agent.log")

    start_supervised!(T3.Settings)
    start_supervised!({T3.Store, path: Path.join(home, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!({Registry, keys: :unique, name: T3.Codex.Registry})
    start_supervised!({Registry, keys: :unique, name: T3.Claude.Registry}, id: :claude_registry)
    start_supervised!({Registry, keys: :unique, name: T3.Acp.Registry}, id: :acp_registry)
    start_supervised!({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})

    {:ok, _} =
      T3.Settings.put(
        %{
          "providerInstances" => %{
            "antigravity" => %{
              "driver" => "antigravity",
              "enabled" => true,
              "config" => %{"binaryPath" => exe},
              "environment" => [%{"name" => "FAKE_AGY_LOG", "value" => log}]
            }
          }
        },
        0
      )

    {:ok, work: work, log: log}
  end

  defp sign_in do
    token = Path.join(T3.Antigravity.Profile.dir("antigravity"), "antigravity-acp/acp_token.json")
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, "{}")
  end

  defp launch(text, mode \\ "full-access", model \\ "antigravity-default", attachments \\ []) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-1",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Antigravity",
        "modelSelection" => %{"instanceId" => "antigravity", "model" => model},
        "runtimeMode" => mode,
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "m1", "text" => text, "attachments" => attachments}
      })

    thread_id
  end

  defp current(thread_id), do: T3.Streams.Server.state(T3.Streams.ensure(thread_id))

  defp await(thread_id, fun) do
    receive do
      {:t3_stream, ^thread_id, _} ->
        state = current(thread_id)
        if fun.(state), do: state, else: await(thread_id, fun)
    after
      10_000 -> flunk("thread never got there")
    end
  end

  defp await_run(thread_id, status),
    do: await(thread_id, &match?([%{"status" => ^status} | _], StreamState.list(&1, "run")))

  defp await_request(thread_id) do
    state =
      await(thread_id, fn state ->
        Enum.any?(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
      end)

    Enum.find(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
  end

  defp requests(log) do
    for line <- String.split(File.read!(log), "\n", trim: true),
        entry = JSON.decode!(line),
        entry["method"],
        do: {entry["method"], entry["params"]}
  end

  defp item(state, type),
    do: Enum.find(StreamState.list(state, "turn-item"), &(&1["type"] == type))

  test "a turn authenticates, sets the mode and default model, and maps native commands", %{
    log: log
  } do
    sign_in()
    thread_id = launch("list everything")
    state = await_run(thread_id, "completed")

    assert %{"input" => "ls -la", "output" => "a.txt\n", "status" => "completed"} =
             item(state, "command_execution")

    assert %{"text" => "Done"} = item(state, "assistant_message")

    calls = requests(log)
    assert {"authenticate", %{"methodId" => "oauth-personal"}} in calls

    assert {"initialize",
            %{
              "clientCapabilities" => %{
                "fs" => %{"readTextFile" => true, "writeTextFile" => true}
              }
            }} =
             List.keyfind(calls, "initialize", 0)

    assert {"session/new", %{"additionalDirectories" => [attachments]}} =
             List.keyfind(calls, "session/new", 0)

    assert attachments == T3.Attachments.dir()

    options = for {"session/set_config_option", p} <- calls, do: {p["configId"], p["value"]}
    assert options == [{"mode", "yolo"}, {"model", "gemini-3.8-flash-high"}]

    # The session told the provider about the account.
    entry = T3.Acp.entry("antigravity")

    assert %{
             "status" => "ready",
             "installed" => true,
             "version" => "agy_acp_server_1.1.1",
             "auth" => %{"status" => "authenticated", "label" => "Google account"},
             "slashCommands" => [%{"name" => "compact"}]
           } = entry

    assert [
             %{"slug" => "gemini-2.5-pro", "isLegacy" => true},
             %{"slug" => "gemini-3.8-flash-high", "isDefault" => true} | _
           ] =
             entry["models"]

    # A new runtime mode switches the session's mode, without a new process.
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "threadId" => thread_id,
        "runtimeMode" => "auto-accept-edits"
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "m2",
        "text" => "again"
      })

    await(thread_id, fn state ->
      runs = StreamState.list(state, "run")
      length(runs) == 2 and Enum.all?(runs, &(&1["status"] == "completed"))
    end)

    calls = requests(log)
    assert length(for {"initialize", _} <- calls, do: 1) == 1

    assert {"session/set_config_option", %{"configId" => "mode", "value" => "auto_edit"}} =
             List.last(for {"session/set_config_option", _} = call <- calls, do: call)
  end

  test "native questions and approvals reach the user, with the agent's options", %{log: log} do
    sign_in()
    thread_id = launch("question", "approval-required")
    request = await_request(thread_id)
    assert %{"kind" => "user_input"} = request

    assert %{"questions" => [%{"id" => "interaction_1", "question" => "Pick a colour"}]} =
             item(current(thread_id), "user_input_request")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => thread_id,
        "requestId" => request["id"],
        "answers" => %{"interaction_1" => "Blue"}
      })

    state = await_run(thread_id, "completed")
    assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "You chose blue"))

    thread_id = launch("approve", "approval-required")
    request = await_request(thread_id)
    assert %{"kind" => "command"} = request

    assert %{
             "prompt" => "rm -rf build",
             "options" => [
               %{"decision" => "accept"},
               %{"decision" => "acceptForSession", "warning" => "Could be prompt injection"},
               %{"decision" => "decline"},
               %{"decision" => "cancel"}
             ]
           } = item(current(thread_id), "approval_request")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => thread_id,
        "requestId" => request["id"],
        "decision" => "accept"
      })

    state = await_run(thread_id, "completed")
    assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "allowed"))
    assert File.exists?(log)
  end

  test "the agent reads and writes files through T3, inside the workspace only", %{work: work} do
    sign_in()
    thread_id = launch("files")
    state = await_run(thread_id, "completed")
    assert File.read!(Path.join(work, "out.txt")) == "one\ntwo\nthree"
    refute File.exists?("/etc/t3-outside.txt")

    assert Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["text"] == "read two; outside refused")
           )
  end

  test "uploads go to the agent as native content", %{log: log} do
    sign_in()
    # An upload the thread already owns.
    id = "thread-files-#{System.unique_integer([:positive])}"
    File.mkdir_p!(T3.Attachments.dir())
    File.write!(Path.join(T3.Attachments.dir(), id <> ".md"), "hello")

    launch("read this", "full-access", "antigravity-default", [
      %{
        "type" => "file",
        "id" => id,
        "name" => "notes.md",
        "mimeType" => "text/markdown",
        "sizeBytes" => 5
      }
    ])
    |> await_run("completed")

    {"session/prompt", %{"prompt" => blocks}} = List.keyfind(requests(log), "session/prompt", 0)

    assert [
             %{"type" => "text"},
             %{
               "type" => "resource",
               "resource" => %{"text" => "hello", "mimeType" => "text/markdown"}
             }
           ] =
             blocks
  end

  test "without a sign-in the turn asks for one instead of waiting on Google" do
    thread_id = launch("hello")
    state = await_run(thread_id, "failed")

    assert [%{"lastError" => failure}] = StreamState.list(state, "provider-session")
    assert failure =~ "Sign in to Antigravity in Settings"

    assert %{"status" => "warning", "auth" => %{"status" => "unauthenticated"}, "models" => []} =
             T3.Acp.entry("antigravity")
  end

  test "an unknown account is reported without starting the agent", %{log: log} do
    assert %{"status" => "warning", "installed" => true, "auth" => %{"status" => "unknown"}} =
             T3.Acp.entry("antigravity")

    refute File.exists?(log)

    {:ok, {settings, version}} = {:ok, T3.Settings.get()}

    {:ok, _} =
      T3.Settings.put(
        put_in(
          settings,
          ["providerInstances", "antigravity", "config", "authMethod"],
          "gemini-api-key"
        ),
        version
      )

    assert %{"status" => "error", "message" => "Enter a Gemini API key" <> _} =
             T3.Acp.entry("antigravity")
  end

  test "a model refresh opens a throwaway session and cleans up after it", %{log: log} do
    sign_in()
    :ok = T3.Antigravity.refresh("antigravity")

    assert %{"auth" => %{"status" => "authenticated"}, "models" => [_ | _]} =
             T3.Acp.entry("antigravity")

    assert {"session/new", %{"cwd" => cwd}} = List.keyfind(requests(log), "session/new", 0)
    refute File.exists?(cwd)
  end

  describe "sign-in" do
    setup do
      start_supervised!({Registry, keys: :unique, name: T3.ProviderAuth.Registry})

      start_supervised!(
        {DynamicSupervisor, name: T3.ProviderAuth.Supervisor, strategy: :one_for_one}
      )

      {:ok, _} = T3.ProviderAuth.subscribe("antigravity", self())
      :ok
    end

    defp await_phase(phase) do
      receive do
        {:t3_provider_auth, _, %{"phase" => ^phase} = state} ->
          state

        {:t3_provider_auth, _, %{"phase" => "failed"} = state} ->
          flunk("failed: #{state["message"]}")

        {:t3_provider_auth, _, _} ->
          await_phase(phase)
      after
        10_000 -> flunk("no #{phase} state")
      end
    end

    defp set_env(name, value) do
      {settings, version} = T3.Settings.get()

      env =
        get_in(settings, ["providerInstances", "antigravity", "environment"]) ++
          [%{"name" => name, "value" => value}]

      {:ok, _} =
        T3.Settings.put(
          put_in(settings, ["providerInstances", "antigravity", "environment"], env),
          version
        )
    end

    defp sign_in_with_google(stdout?) do
      if stdout?, do: set_env("FAKE_AGY_STDOUT_URL", "1")

      {:ok, %{"phase" => "starting", "flowId" => flow}} =
        T3.ProviderAuth.start(%{"instanceId" => "antigravity"})

      waiting = await_phase("waiting")

      assert %{
               "type" => "browser",
               "acceptsCallback" => true,
               "requiresConsent" => false,
               "url" => url
             } =
               waiting["interaction"]

      assert waiting["message"] =~ "paste the redirect URL"

      assert {:ok, %{redirect_uri: redirect, state: state}} =
               T3.Antigravity.Protocol.parse_authorization_url(url)

      # A redirect for another sign-in is refused; the real one finishes it.
      assert {:error, %{"detail" => "This redirect URL does not belong" <> _}} =
               T3.ProviderAuth.complete(%{
                 "instanceId" => "antigravity",
                 "flowId" => flow,
                 "callbackUrl" => "#{redirect}?state=other&code=abc"
               })

      assert {:ok, _} =
               T3.ProviderAuth.complete(%{
                 "instanceId" => "antigravity",
                 "flowId" => flow,
                 "callbackUrl" => "#{redirect}?state=#{state}&code=abc"
               })

      await_phase("succeeded")
    end

    test "Google sign-in takes the pasted redirect and reads the account" do
      sign_in_with_google(false)

      assert %{"status" => "ready", "auth" => %{"status" => "authenticated"}, "models" => [_ | _]} =
               T3.Acp.entry("antigravity")

      assert {:ok, %{"phase" => "idle", "message" => "Signed out."}} =
               T3.ProviderAuth.logout(%{"instanceId" => "antigravity"})

      refute File.exists?(
               Path.join(
                 T3.Antigravity.Profile.dir("antigravity"),
                 "antigravity-acp/acp_token.json"
               )
             )

      assert %{"status" => "warning", "auth" => %{"status" => "unauthenticated"}, "models" => []} =
               T3.Acp.entry("antigravity")
    end

    test "the sign-in URL the agent prints on stdout is the same request" do
      sign_in_with_google(true)
      assert %{"auth" => %{"status" => "authenticated"}} = T3.Acp.entry("antigravity")
    end

    test "an API key signs in without a page; a missing one says what to set" do
      {settings, version} = T3.Settings.get()

      settings =
        put_in(
          settings,
          ["providerInstances", "antigravity", "config", "authMethod"],
          "gemini-api-key"
        )

      {:ok, version} = T3.Settings.put(settings, version)

      {:ok, _} = T3.ProviderAuth.start(%{"instanceId" => "antigravity"})

      receive do
        {:t3_provider_auth, _, %{"phase" => "failed", "message" => message}} ->
          assert message =~ "Enter a Gemini API key"
      after
        10_000 -> flunk("no failure")
      end

      settings = put_in(settings, ["providerInstances", "antigravity", "config", "apiKey"], "k")
      {:ok, _} = T3.Settings.put(settings, version)
      {:ok, _} = T3.ProviderAuth.start(%{"instanceId" => "antigravity"})
      await_phase("succeeded")

      assert %{"auth" => %{"status" => "authenticated", "label" => "Gemini API key"}} =
               T3.Acp.entry("antigravity")
    end
  end
end
