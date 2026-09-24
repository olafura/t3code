defmodule T3.Antigravity do
  @moduledoc """
  Google Antigravity instances on this node: the official ACP agent
  (`agy_acp_server`), run like the other ACP agents (`T3.Acp`,
  `T3.Acp.ThreadRuntime`) with the rules of `T3.Antigravity.Protocol`.

  An instance's settings (`AntigravitySettings`: `authMethod`, `apiKey`,
  `gcpProject`, `gcpLocation`, `binaryPath`) come from its `providerInstances`
  entry, and for the built-in `antigravity` instance from `providers.antigravity`
  too. Every agent process starts through `start_agent/3`: the runtime
  (`T3.Antigravity.Installation`), the instance's private profile
  (`T3.Antigravity.Profile`), `initialize`, then `authenticate` with the configured
  method before any session, since the method picks the credential source. A
  process that is not signing in and meets a Google sign-in page stops with
  `sign_in_required/0` instead of waiting on it.

  The agent unpacks about 1 GB each time it starts, so status never starts it:
  whether it is installed comes from the disk, and the account, version, models and
  commands from the sessions it opens (`session_started/4` and friends), kept per
  instance in the profile's `t3-account.json` so a restart remembers them. A model
  refresh (`refresh/1`) opens a throwaway session on purpose.
  """

  require Logger

  alias T3.Antigravity.{Installation, Profile, Protocol, Skills}
  alias T3.JsonRpc.Connection

  @sign_in_required "Sign in to Antigravity in Settings before you continue."
  @signed_out "Sign in with Google to use Antigravity."
  @unchecked "Antigravity is installed. Google account access is not checked yet."
  @max_workspaces 32
  @defaults %{
    "authMethod" => "oauth-personal",
    "apiKey" => "",
    "gcpProject" => "",
    "gcpLocation" => "",
    "binaryPath" => ""
  }

  @doc "The message a process gives when the instance must be signed in first."
  def sign_in_required, do: @sign_in_required

  # --- settings --------------------------------------------------------------------

  @doc "An instance's `AntigravitySettings`, defaults filled in, strings trimmed."
  def config(id) do
    legacy =
      if id == "antigravity",
        do: get_in(T3.Settings.settings(), ["providers", "antigravity"]) || %{},
        else: %{}

    config = Map.merge(legacy, T3.Acp.settings_entry(id)["config"] || %{})

    Map.new(@defaults, fn {key, default} ->
      case config[key] do
        value when is_binary(value) -> {key, String.trim(value)}
        _ -> {key, default}
      end
    end)
  end

  @doc "What the configured sign-in method still needs, or `nil`."
  def auth_config_issue(%{"authMethod" => method} = config) do
    project? = config["gcpProject"] != "" and config["gcpLocation"] != ""

    case method do
      "oauth-personal" ->
        nil

      "oauth-business" ->
        unless project?,
          do:
            "Gemini Enterprise needs a GCP project and location in the Antigravity provider settings."

      "gemini-api-key" ->
        if config["apiKey"] == "",
          do: "Enter a Gemini API key in the Antigravity provider settings."

      "agent-platform" ->
        unless config["apiKey"] != "" or project?,
          do:
            "Agent Platform needs an API key, or a GCP project and location, in the Antigravity provider settings."

      other ->
        "Antigravity does not know the sign-in method #{inspect(other)}."
    end
  end

  @doc "Whether the method signs in on a Google page (the others use a key)."
  def uses_browser?(method), do: method in ["oauth-personal", "oauth-business"]

  @doc "The provider card's label for a signed-in method."
  def auth_label("oauth-personal"), do: "Google account"
  def auth_label("oauth-business"), do: "Gemini Enterprise"
  def auth_label("gemini-api-key"), do: "Gemini API key"
  def auth_label(_agent_platform), do: "Agent Platform"

  defp user_home(id) do
    case List.keyfind(T3.Acp.env(id), "HOME", 0) do
      {_, home} when home != "" -> home
      _ -> System.user_home!()
    end
  end

  defp path_env(id) do
    case List.keyfind(T3.Acp.env(id), "PATH", 0) do
      {_, path} -> path
      nil -> System.get_env("PATH")
    end
  end

  @doc "The runtime the instance would start (`T3.Antigravity.Installation.resolve/2`)."
  def resolve(id), do: Installation.resolve(config(id)["binaryPath"], path_env(id))

  # --- processes -------------------------------------------------------------------

  @doc """
  Starts the instance's agent in `cwd`, initialized and authenticated:
  `{:ok, conn, initialize_result}` or `{:error, reason}` (a message, or the
  agent's JSON-RPC error). The caller is the connection's handler. Options:

    * `client_fs: true` offers the agent T3's file system (`T3.Antigravity.ClientFiles`)
    * `authenticate: false` stops after `initialize` (sign-out)
    * `on_url: fun` takes a Google sign-in request (`%{url, redirect_uri, state}`),
      returning `:ok` or `{:error, message}`; without it a sign-in page fails
    * `handle: fun` gets any other message while authenticating (`:ok` or
      `{:error, reason}` to stop)
  """
  def start_agent(id, cwd, opts \\ []) do
    config = config(id)

    with nil <- auth_config_issue(config) && {:error, auth_config_issue(config)},
         {:ok, executable} <- Installation.resolve(config["binaryPath"], path_env(id)),
         {:ok, profile} <- Profile.prepare(id, config, user_home(id)),
         {argv, env} = Profile.command(executable, profile, config, T3.Acp.env(id)),
         {:ok, conn} <- start_conn(argv, cwd, env) do
      Installation.lease(conn, executable)

      case Connection.call(
             conn,
             "initialize",
             initialize_params(opts[:client_fs] == true),
             90_000
           ) do
        {:ok, init} ->
          result =
            if opts[:authenticate] == false,
              do: :ok,
              else: authenticate(id, conn, config["authMethod"], opts)

          case result do
            :ok ->
              {:ok, conn, init}

            error ->
              Connection.stop(conn)
              error
          end

        {:error, reason} ->
          Connection.stop(conn)
          {:error, "Antigravity could not start: #{describe(reason)}"}
      end
    end
  end

  defp start_conn(argv, cwd, env) do
    case Connection.start_link(
           cmd: argv,
           handler: self(),
           cd: cwd,
           env: env,
           dialect: :v2,
           stderr: true
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "Antigravity could not start: #{describe(reason)}"}
    end
  end

  defp initialize_params(client_fs) do
    %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => client_fs, "writeTextFile" => client_fs},
        "terminal" => false
      },
      "clientInfo" => %{"name" => "t3code", "version" => "0.1.0"}
    }
  end

  defp authenticate(id, conn, method, opts) do
    timeout = if opts[:on_url], do: 300_000, else: 90_000

    task =
      Task.async(fn ->
        Connection.call(conn, "authenticate", %{"methodId" => method}, timeout)
      end)

    await_authenticate(id, conn, task, opts, "")
  end

  defp await_authenticate(id, conn, task, opts, pending) do
    handle = opts[:handle]

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, _} -> :ok
          {:error, %{"code" => -32000}} -> sign_in_failed(id)
          {:error, reason} -> {:error, reason}
        end

      {:json_rpc, ^conn, {:invalid, line}} ->
        case Protocol.auth_line(line) do
          :none -> await_authenticate(id, conn, task, opts, pending)
          found -> sign_in_page(id, conn, task, opts, pending, found)
        end

      {:json_rpc, ^conn, {:stderr, data}} ->
        {lines, rest} = split_lines(pending <> data)

        found =
          Enum.find_value(lines, fn line ->
            case Protocol.auth_line(line, Profile.auth_marker()) do
              {:ok, _} = found -> found
              _ -> nil
            end
          end)

        if found,
          do: sign_in_page(id, conn, task, opts, rest, found),
          else: await_authenticate(id, conn, task, opts, rest)

      {:json_rpc, ^conn, {:request, rpc_id, method, _params}} ->
        Connection.respond(
          conn,
          rpc_id,
          {:error, %{"code" => -32601, "message" => "#{method} is not supported"}}
        )

        await_authenticate(id, conn, task, opts, pending)

      {:json_rpc, ^conn, _other} ->
        await_authenticate(id, conn, task, opts, pending)

      message when is_function(handle, 1) ->
        case handle.(message) do
          :ok ->
            await_authenticate(id, conn, task, opts, pending)

          error ->
            Task.shutdown(task, :brutal_kill)
            error
        end
    end
  end

  defp sign_in_page(id, conn, task, opts, pending, found) do
    result =
      case {found, opts[:on_url]} do
        {{:ok, request}, on_url} when is_function(on_url, 1) -> on_url.(request)
        {{:ok, _request}, _} -> sign_in_failed(id)
        {{:error, _} = error, _} -> error
      end

    case result do
      :ok ->
        await_authenticate(id, conn, task, opts, pending)

      error ->
        Task.shutdown(task, :brutal_kill)
        error
    end
  end

  defp sign_in_failed(id) do
    auth_required(id)
    {:error, @sign_in_required}
  end

  # Lines without their newline; an overlong unfinished line is dropped.
  defp split_lines(buffer) do
    {lines, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {lines, if(byte_size(rest) > 17_000, do: "", else: rest)}
  end

  @doc """
  Runs `fun.(cwd)` in a new temporary directory, removed afterwards with the
  agent's files for the session `fun` names (`{:ok, session_id, result}`); the
  helpers that open a session for a moment (sign-in, refresh, text generation)
  never touch a workspace.
  """
  def in_temp_dir(id, prefix, fun) do
    cwd = Path.join(System.tmp_dir!(), "#{prefix}#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    try do
      case fun.(cwd) do
        {:ok, session_id, result} ->
          Profile.remove_session_files(id, session_id, cwd)
          result

        other ->
          other
      end
    after
      File.rm_rf(cwd)
    end
  end

  @doc """
  `refreshModels`: opens a throwaway session to read the account's models and
  commands again. `:ok` or `{:error, message}`.
  """
  def refresh(id) do
    in_temp_dir(id, "t3-antigravity-setup-", fn cwd ->
      with {:ok, conn, init} <- start_agent(id, cwd) do
        try do
          case Connection.call(conn, "session/new", %{"cwd" => cwd, "mcpServers" => []}, 60_000) do
            {:ok, %{"sessionId" => session_id} = result} ->
              session_started(id, init, result, nil)
              drain_updates(id, conn)
              {:ok, session_id, :ok}

            {:error, %{"code" => -32000}} ->
              sign_in_failed(id)

            {:error, reason} ->
              {:error, describe(reason)}
          end
        after
          Connection.stop(conn)
        end
      end
    end)
  end

  @doc "Takes the model and command updates a new session sends right after opening."
  def drain_updates(id, conn) do
    receive do
      {:json_rpc, ^conn, {:notification, "session/update", %{"update" => update}}} ->
        session_update(id, update, nil)
        drain_updates(id, conn)
    after
      200 -> :ok
    end
  end

  @doc "Records what a session update says about the account (models, commands)."
  def session_update(id, %{"sessionUpdate" => "available_commands_update"} = update, cwd),
    do: commands_updated(id, update["availableCommands"] || [], cwd)

  def session_update(id, %{"sessionUpdate" => "config_option_update"} = update, _cwd),
    do: config_options_updated(id, update["configOptions"] || [])

  def session_update(_id, _update, _cwd), do: :ok

  @doc "Removes the unpacked runtimes of every instance; at node start, before any launch."
  def boot do
    for id <- T3.Acp.instances(), T3.Acp.driver(id) == "antigravity", do: Profile.sweep_temp(id)
    :ok
  end

  # --- the account -----------------------------------------------------------------

  @empty %{
    "auth" => nil,
    "type" => nil,
    "version" => nil,
    "models" => [],
    "slashCommands" => [],
    "workspaces" => []
  }

  defp account_path(id), do: Path.join(Profile.dir(id), "t3-account.json")
  defp account_key(id), do: {__MODULE__, Profile.dir(id), :account}

  @doc "What sessions told us about the instance's account."
  def account(id) do
    case :persistent_term.get(account_key(id), nil) do
      nil ->
        account =
          with {:ok, text} <- File.read(account_path(id)),
               {:ok, %{} = saved} <- JSON.decode(text) do
            Map.merge(@empty, Map.take(saved, ~w(auth type version models slashCommands)))
          else
            _ -> @empty
          end

        :persistent_term.put(account_key(id), account)
        account

      account ->
        account
    end
  end

  defp update_account(id, fun) do
    before = account(id)
    account = fun.(before)

    if account != before do
      :persistent_term.put(account_key(id), account)

      saved = Map.take(account, ~w(auth type version models slashCommands))

      if saved != Map.take(before, ~w(auth type version models slashCommands)) do
        File.mkdir_p(Profile.dir(id))
        File.write(account_path(id), JSON.encode!(saved))
      end

      T3.Settings.notify_providers()
    end

    :ok
  end

  @doc "A session opened: the account is signed in, with these models."
  def session_started(id, init, result, cwd) do
    method = config(id)["authMethod"]

    update_account(id, fn account ->
      account
      |> Map.merge(%{
        "auth" => "authenticated",
        "type" => method,
        "version" => get_in(init, ["agentInfo", "version"]) || account["version"],
        "models" => Protocol.models(result || %{})
      })
      |> put_workspace(id, cwd, %{})
    end)
  end

  @doc "The session's model option changed."
  def config_options_updated(id, options) do
    update_account(id, fn
      %{"auth" => "authenticated"} = account ->
        Map.put(account, "models", Protocol.models(%{"configOptions" => options}))

      account ->
        account
    end)
  end

  @doc "The agent listed its slash commands (for a session in `cwd`)."
  def commands_updated(id, commands, cwd) do
    commands = Protocol.slash_commands(commands)

    update_account(id, fn
      %{"auth" => "unauthenticated"} = account ->
        account

      account ->
        account
        |> Map.put("slashCommands", commands)
        |> put_workspace(id, cwd, %{"slashCommands" => commands})
    end)
  end

  @doc "The agent needs a sign-in: what the account held is gone."
  def auth_required(id),
    do: update_account(id, fn _ -> Map.put(@empty, "auth", "unauthenticated") end)

  @doc "The instance signed out."
  def signed_out(id), do: auth_required(id)

  @doc """
  `server.refreshProviders` for a workspace: the skills Antigravity loads there,
  kept as the instance's snapshot for `cwd`.
  """
  def refresh_workspace(id, cwd) do
    case Skills.discover(cwd, user_home(id)) do
      {:ok, skills} ->
        update_account(id, &put_workspace(&1, id, cwd, %{"skills" => skills}))

      {:error, message} ->
        Logger.warning(message)
    end
  end

  # A workspace's snapshot: its commands and skills. A new one reads its skills
  # (clients ask for a workspace only while it has no snapshot).
  defp put_workspace(account, _id, nil, _fields), do: account

  defp put_workspace(account, id, cwd, fields) do
    existing = Enum.find(account["workspaces"], &(&1["cwd"] == cwd))

    base =
      existing ||
        %{
          "cwd" => cwd,
          "slashCommands" => account["slashCommands"],
          "skills" =>
            if(Map.has_key?(fields, "skills"),
              do: [],
              else:
                case Skills.discover(cwd, user_home(id)) do
                  {:ok, skills} -> skills
                  {:error, _} -> []
                end
            )
        }

    snapshot = Map.merge(base, fields)

    if existing != nil and snapshot == existing do
      account
    else
      snapshot = Map.put(snapshot, "checkedAt", T3.Orchestration.Entities.now())

      workspaces =
        (Enum.reject(account["workspaces"], &(&1["cwd"] == cwd)) ++ [snapshot])
        |> Enum.take(-@max_workspaces)

      Map.put(account, "workspaces", workspaces)
    end
  end

  # --- the provider entry ----------------------------------------------------------

  @doc "The instance's `ServerProvider`, from its settings, the disk and its account."
  def entry(id, instance) do
    config = config(id)
    enabled = T3.Acp.enabled?(id)
    account = account(id)
    resolved = Installation.resolve(config["binaryPath"], path_env(id))
    issue = auth_config_issue(config)
    installed = match?({:ok, _}, resolved)

    auth =
      cond do
        account["auth"] == "authenticated" and account["type"] == config["authMethod"] ->
          "authenticated"

        account["auth"] == "unauthenticated" ->
          "unauthenticated"

        true ->
          "unknown"
      end

    {status, message} =
      cond do
        not enabled -> {"disabled", "Antigravity is disabled in T3 Code settings."}
        issue != nil -> {"error", issue}
        not installed -> {"error", elem(resolved, 1)}
        auth == "authenticated" -> {"ready", nil}
        auth == "unauthenticated" -> {"warning", @signed_out}
        true -> {"warning", @unchecked}
      end

    known? = installed and auth != "unauthenticated"

    %{
      "instanceId" => id,
      "driver" => "antigravity",
      "displayName" => instance["displayName"] || "Antigravity",
      "enabled" => enabled,
      "installed" => installed,
      "version" =>
        account["version"] ||
          case resolved do
            {:ok, %{version: version}} -> version
            _ -> nil
          end,
      "status" => status,
      "auth" =>
        %{"status" => auth, "type" => config["authMethod"], "canLogout" => installed}
        |> then(
          &if(auth == "authenticated",
            do: Map.put(&1, "label", auth_label(config["authMethod"])),
            else: &1
          )
        ),
      "checkedAt" => T3.Orchestration.Entities.now(),
      "availability" => "available",
      "showInteractionModeToggle" => false,
      "supportsConversationRollback" => false,
      "supportsTextGeneration" =>
        known? and auth == "authenticated" and Profile.text_generation_available?(id),
      "setup" => %{"canAuthenticate" => true, "canInstall" => true},
      "models" => if(known?, do: Protocol.classify(account["models"]), else: []),
      "slashCommands" => if(known?, do: account["slashCommands"], else: []),
      "skills" => [],
      "workspaceSnapshots" => if(known?, do: account["workspaces"], else: [])
    }
    |> then(&if(message, do: Map.put(&1, "message", message), else: &1))
    |> then(
      &if(instance["accentColor"],
        do: Map.put(&1, "accentColor", instance["accentColor"]),
        else: &1
      )
    )
  end

  # --- managed install RPCs --------------------------------------------------------

  @doc "`provider.install.start`."
  def install_start(%{"instanceId" => id}) do
    with :ok <- managed(id, "install", true), do: setup(id, Installation.start())
  end

  @doc "`provider.install.cancel`."
  def install_cancel(%{"instanceId" => id, "operationId" => operation}) do
    with :ok <- managed(id, "cancel-install", false),
         do: setup(id, Installation.cancel(operation))
  end

  @doc "`provider.install.remove`: refused while a configured `binaryPath` points inside it."
  def install_remove(%{"instanceId" => id}) do
    with :ok <- managed(id, "remove-install", true),
         :ok <- setup(id, Installation.remove(configured_paths())) do
      T3.Settings.notify_providers()
      {:ok, Installation.state()}
    end
  end

  @doc "`provider.install.subscribe`: `{:ok, state}`, then `{:t3_provider_install, id, state}`."
  def install_subscribe(id, pid) do
    with :ok <- managed(id, "observe-install", false), do: Installation.subscribe(id, pid)
  end

  defp managed(id, operation, managed_only) do
    cond do
      T3.Acp.driver(id) != "antigravity" ->
        setup_error(
          id,
          operation,
          "Managed installation is not available for this provider instance."
        )

      managed_only and config(id)["binaryPath"] != "" ->
        setup_error(
          id,
          operation,
          "This instance uses a custom executable. Clear its binary path to manage installation in T3 Code."
        )

      true ->
        :ok
    end
  end

  defp configured_paths do
    settings = T3.Settings.settings()

    for entry <-
          Map.values(settings["providerInstances"] || %{}) ++
            Enum.map(Map.values(settings["providers"] || %{}), &%{"config" => &1}),
        is_map(entry),
        path = get_in(entry, ["config", "binaryPath"]),
        is_binary(path) and String.trim(path) != "",
        do: String.trim(path)
  end

  defp setup(_id, :ok), do: :ok
  defp setup(_id, {:ok, _} = ok), do: ok

  defp setup(id, {:error, %{operation: operation, detail: detail}}),
    do: setup_error(id, operation, detail)

  @doc "A `ProviderSetupError` for a client."
  def setup_error(id, operation, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => id,
       "operation" => operation,
       "detail" => detail,
       "message" => detail
     }}
  end

  @doc false
  def describe(%{"message" => message}) when is_binary(message), do: message
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason)
end
