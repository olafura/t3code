defmodule T3.Acp do
  @moduledoc """
  The Agent Client Protocol agents a node can run (`T3.Acp.ThreadRuntime`), and
  their entries in `ServerConfig.providers`: the built-in OpenCode and Grok, more
  instances of them, and `acpRegistry` instances running an agent from the ACP
  Registry (`T3.Acp.Catalog`). Everything is keyed by provider instance id.

  Built-in agents are off until enabled in the node's settings (`providers.<driver>`
  or a `providerInstances` entry), as on the Node server, so nothing is spawned for
  users who never opted in; a registry instance is on once added. An enabled agent's model list comes from the `model`
  config option of a throwaway session, which lists the models of the providers it
  is connected to; it is read once, at boot or when the agent is first enabled.
  """

  alias T3.JsonRpc.Connection

  @agents %{
    "opencode" => %{binary: "opencode", label: "OpenCode"},
    "grok" => %{binary: "grok", label: "Grok"},
    # The Cursor SDK behind ACP (`packages/cursor-acp`), run by Node.
    "cursor" => %{binary: "node", label: "Cursor"},
    # Pi through the registry's pi-acp adapter, which runs `pi --mode rpc`.
    "pi" => %{binary: "pi", label: "Pi"}
  }

  # The Cursor sidecar: bundled under priv/ in a release, from packages/ in a checkout.
  @cursor_checkout Path.expand("../../../../packages/cursor-acp/src/main.ts", __DIR__)

  # Instances of this driver run an agent from the ACP Registry (`T3.Acp.Catalog`).
  @registry "acpRegistry"

  @doc "Instance ids of the ACP agents: the built-in agents and configured instances."
  def instances do
    configured =
      for {id, %{"driver" => driver}} <- T3.Settings.settings()["providerInstances"] || %{},
          driver == @registry or Map.has_key?(@agents, driver),
          do: id

    Enum.uniq(Map.keys(@agents) ++ configured)
  end

  @doc "Whether a provider instance runs over ACP."
  def agent?(instance), do: instance(instance) != nil

  # `{driver, instance settings}`; a built-in agent's id is its own default instance.
  defp instance(id) do
    case (T3.Settings.settings()["providerInstances"] || %{})[id] do
      %{"driver" => driver} = entry when driver == @registry ->
        {driver, entry}

      %{"driver" => driver} = entry ->
        if Map.has_key?(@agents, driver), do: {driver, entry}, else: builtin(id)

      _ ->
        builtin(id)
    end
  end

  defp builtin(id), do: if(Map.has_key?(@agents, id), do: {id, %{}})

  def label(instance) do
    case instance(instance) do
      {_, %{"displayName" => name}} when is_binary(name) -> name
      {@registry, entry} -> get_in(entry, ["config", "agentId"]) || instance
      {driver, _} -> @agents[driver].label
      nil -> instance
    end
  end

  @doc """
  The command and environment that start an instance's agent for a thread's
  runtime mode: the binary set in its settings, or a registry agent's install;
  `:acp_commands` overrides it (tests).
  """
  def command(instance, runtime_mode \\ nil) do
    override = Application.get_env(:t3, :acp_commands, %{})[instance]

    case override || instance(instance) do
      [_ | _] = command ->
        {_driver, entry} = instance(instance) || {nil, %{}}
        {:ok, command, instance_env(entry)}

      {@registry, entry} ->
        with {:ok, command, env} <- T3.Acp.Catalog.command(entry["config"] || %{}),
             do: {:ok, command, env ++ instance_env(entry)}

      {"cursor", entry} ->
        # Each instance keeps its own Cursor sign-in, owner-only, under the T3 home.
        credentials =
          Path.join([
            Application.fetch_env!(:t3, :home),
            "provider-auth",
            instance,
            "cursor.json"
          ])

        {node, node_env} = node_command()

        {:ok, [node, cursor_script(), "--mode", runtime_mode || "approval-required"],
         [{"T3_CURSOR_CREDENTIALS", credentials} | node_env ++ instance_env(entry)]}

      {"pi", entry} ->
        with {:ok, command, env} <- T3.Acp.Catalog.command(%{"agentId" => "pi-acp"}),
             do:
               {:ok, command,
                [{"PI_ACP_PI_COMMAND", binary("pi", entry, "pi")} | env ++ instance_env(entry)]}

      {driver, entry} ->
        binary = binary(driver, entry, @agents[driver].binary)
        {:ok, [binary | args(driver, runtime_mode)], instance_env(entry)}

      nil ->
        {:error, "unknown ACP agent #{instance}"}
    end
  end

  defp cursor_script do
    released = Application.app_dir(:t3, "priv/cursor-acp/main.mjs")
    if File.exists?(released), do: released, else: @cursor_checkout
  end

  # The desktop app names its own Electron binary, which runs as Node with
  # ELECTRON_RUN_AS_NODE (set for the sidecar only, never the node's terminals).
  defp node_command do
    case System.get_env("T3_NODE_COMMAND") do
      command when command in [nil, ""] ->
        {"node", []}

      command ->
        electron =
          if System.get_env("T3_NODE_ELECTRON") == "1", do: [{"ELECTRON_RUN_AS_NODE", "1"}]

        {command, electron || []}
    end
  end

  # Variables set on the instance in settings, such as an API key.
  defp instance_env(entry) do
    for %{"name" => name, "value" => value} <- entry["environment"] || [],
        is_binary(name) and is_binary(value),
        do: {name, value}
  end

  defp args("opencode", _mode), do: ["acp"]

  # Grok applies permissions itself; full access skips its prompts entirely.
  defp args("grok", "full-access"), do: ["agent", "--always-approve", "stdio"]
  defp args("grok", "approval-required"), do: ["--permission-mode", "default", "agent", "stdio"]

  defp args("grok", "auto-accept-edits"),
    do: ["--permission-mode", "acceptEdits", "agent", "stdio"]

  defp args("grok", "auto"), do: ["--permission-mode", "auto", "agent", "stdio"]
  defp args("grok", _mode), do: ["agent", "stdio"]

  defp binary(driver, entry, default) do
    [
      get_in(entry, ["config", "binaryPath"]),
      get_in(T3.Settings.settings(), ["providers", driver, "binaryPath"])
    ]
    |> Enum.find(default, &(is_binary(&1) and String.trim(&1) != ""))
  end

  @doc "Provider entries for the ACP instances on this node whose agent is available."
  def entries, do: for(id <- instances(), entry = entry(id), do: entry)

  def entry(id) do
    with {driver, instance} <- instance(id),
         {:ok, base} <- base_entry(id, driver, instance) do
      enabled = enabled?(id)
      models = :persistent_term.get({__MODULE__, id, :models}, nil)
      failure = :persistent_term.get({__MODULE__, id, :error}, nil)
      if enabled and models == nil and failure == nil, do: load_once(id)

      Map.merge(
        %{
          "instanceId" => id,
          "driver" => driver,
          "enabled" => enabled,
          "installed" => true,
          "version" => :persistent_term.get({__MODULE__, id, :version}, "unknown"),
          "status" => if(failure, do: "error", else: "ready"),
          "availability" => "available",
          # Commit messages and titles come from Claude or Codex (`T3.TextGeneration`).
          "supportsTextGeneration" => false,
          # ACP agents run without T3's plan mode.
          "showInteractionModeToggle" => false,
          "auth" => %{"status" => "authenticated"},
          "checkedAt" => T3.Orchestration.Entities.now(),
          "models" => models || [],
          "slashCommands" => [],
          "skills" => []
        },
        base
      )
      |> then(&if(failure, do: Map.put(&1, "message", failure), else: &1))
      |> Map.merge(capability_fields(capabilities(id)))
      |> Map.merge(access(id, base["setup"]))
    else
      _ -> nil
    end
  end

  # A registry agent is installed when first used, so it counts as available.
  defp base_entry(id, @registry, instance) do
    agent_id = get_in(instance, ["config", "agentId"])

    case T3.Acp.Catalog.describe(agent_id) do
      nil ->
        :error

      agent ->
        {:ok,
         %{
           "displayName" => instance["displayName"] || agent.name,
           "iconUrl" => "https://cdn.agentclientprotocol.com/registry/v1/latest/#{agent_id}.svg",
           "version" => :persistent_term.get({__MODULE__, id, :version}, agent.version)
         }
         |> then(
           &if(agent.website,
             do: Map.put(&1, "setup", %{"documentationUrl" => agent.website}),
             else: &1
           )
         )}
    end
  end

  # Pi is offered where Pi is installed; its adapter installs when first used.
  defp base_entry(_id, "pi", instance) do
    if System.find_executable(binary("pi", instance, "pi")), do: {:ok, %{}}, else: :error
  end

  defp base_entry(id, _driver, instance) do
    with {:ok, [executable | _], _env} <- command(id),
         path when is_binary(path) <- System.find_executable(executable) do
      {:ok,
       if(instance["displayName"], do: %{"displayName" => instance["displayName"]}, else: %{})}
    else
      _ -> :error
    end
  end

  # What the agent can do with its own sessions and model providers.
  defp capability_fields(nil), do: %{}

  defp capability_fields(caps) do
    sessions = caps["sessionCapabilities"] || %{}

    %{
      "nativeSessions" => %{
        "canList" => is_map(sessions["list"]),
        "canLoad" => caps["loadSession"] == true,
        "canResume" => is_map(sessions["resume"]),
        "canDelete" => is_map(sessions["delete"])
      },
      "configurableProviders" => is_map(caps["providers"])
    }
  end

  # Whether the agent can be signed in here (`T3.ProviderAuth`), and whether it must be.
  defp access(id, setup) do
    methods = :persistent_term.get({__MODULE__, id, :auth_methods}, 0)
    signed_out = :persistent_term.get({__MODULE__, id, :unauthenticated}, false)

    %{
      "setup" =>
        Map.merge(%{"canAuthenticate" => methods > 0, "canInstall" => false}, setup || %{}),
      "auth" => %{
        "status" =>
          cond do
            signed_out -> "unauthenticated"
            capabilities(id) == nil -> "unknown"
            true -> "authenticated"
          end,
        "canLogout" => is_map(get_in(capabilities(id) || %{}, ["auth", "logout"]))
      }
    }
  end

  @doc "Reads each enabled agent's version and models from a throwaway session."
  def load do
    for id <- instances(), enabled?(id), do: load(id)
    :ok
  end

  # An agent enabled after boot is read in the background, once.
  defp load_once(id) do
    if :persistent_term.get({__MODULE__, id, :loading}, false) == false do
      :persistent_term.put({__MODULE__, id, :loading}, true)
      Task.start(fn -> load(id) end)
    end
  end

  @doc "Whether the node's settings enable an instance (built-in agents are off by default)."
  def enabled?(id) do
    case instance(id) do
      nil -> false
      {driver, instance} -> enabled?(id, driver, instance)
    end
  end

  defp enabled?(id, driver, instance) do
    cond do
      instance["enabled"] == false or get_in(instance, ["config", "enabled"]) == false ->
        false

      is_boolean(instance["enabled"]) ->
        instance["enabled"]

      is_boolean(get_in(instance, ["config", "enabled"])) ->
        get_in(instance, ["config", "enabled"])

      driver == @registry ->
        true

      true ->
        id == driver and get_in(T3.Settings.settings(), ["providers", driver, "enabled"]) == true
    end
  end

  defp load(id) do
    dir = Path.join(System.tmp_dir!(), "t3-acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      case read_agent(id, dir) do
        :ok ->
          :persistent_term.erase({__MODULE__, id, :error})

        {:error, :unauthenticated} ->
          :persistent_term.put({__MODULE__, id, :error}, "Sign in to use this agent.")
          :persistent_term.put({__MODULE__, id, :unauthenticated}, true)

        {:error, reason} ->
          :persistent_term.put({__MODULE__, id, :error}, describe(reason))

        _ ->
          :ok
      end
    catch
      _, _ -> :ok
    after
      File.rm_rf(dir)
      T3.Settings.notify_providers()
    end
  end

  defp describe(%{"message" => message}) when is_binary(message), do: message
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp read_agent(id, dir) do
    with_agent(id, dir, fn conn, init ->
      version = get_in(init, ["agentInfo", "version"]) || "unknown"
      :persistent_term.put({__MODULE__, id, :version}, version)
      :persistent_term.put({__MODULE__, id, :capabilities}, init["agentCapabilities"] || %{})
      :persistent_term.put({__MODULE__, id, :auth_methods}, length(init["authMethods"] || []))

      case Connection.call(conn, "session/new", %{"cwd" => dir, "mcpServers" => []}, 60_000) do
        {:ok, session} -> :persistent_term.put({__MODULE__, id, :models}, models(session))
        # ACP's "authentication required".
        {:error, %{"code" => -32000}} -> {:error, :unauthenticated}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Starts an instance's agent in `cwd`, initializes it, and calls `fun.(conn,
  initialize_result)`; the agent stops when `fun` returns.
  """
  def with_agent(id, cwd, fun) do
    with {:ok, command, env} <- command(id),
         {:ok, conn} <-
           Connection.start_link(cmd: command, handler: self(), cd: cwd, env: env, dialect: :v2) do
      try do
        with {:ok, init} <- Connection.call(conn, "initialize", initialize_params()),
             do: fun.(conn, init)
      after
        Connection.stop(conn)
      end
    end
  end

  @doc """
  `initialize` for management and sign-in connections: the client can show a URL
  (`elicitation/create`) and run a login command in a terminal.
  """
  def initialize_params do
    %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false,
        "auth" => %{"terminal" => true},
        "elicitation" => %{"url" => %{}}
      },
      "clientInfo" => %{"name" => "t3code", "version" => "0.1.0"}
    }
  end

  @doc "The agent capabilities an instance reported when it was last probed, or `nil`."
  def capabilities(id), do: :persistent_term.get({__MODULE__, id, :capabilities}, nil)

  @doc "Reads one instance's agent again, now."
  def reload(id) do
    forget(id)
    if enabled?(id), do: load(id)
    :ok
  end

  @doc "Forgets what was read from an instance's agent, so it is probed again."
  def forget(id) do
    for key <- [
          :models,
          :version,
          :capabilities,
          :auth_methods,
          :unauthenticated,
          :error,
          :loading
        ],
        do: :persistent_term.erase({__MODULE__, id, key})

    :ok
  end

  # "Hugging Face/DeepSeek V3" is the model "DeepSeek V3" of the provider "Hugging Face".
  defp models(session) do
    option = Enum.find(session["configOptions"] || [], &(&1["id"] == "model")) || %{}
    current = option["currentValue"]

    for %{"value" => slug} = model <- option["options"] || [] do
      {sub, name} =
        case String.split(model["name"] || slug, "/", parts: 2) do
          [sub, name] -> {sub, name}
          [name] -> {nil, name}
        end

      %{
        "slug" => slug,
        "name" => name,
        "isCustom" => false,
        "isDefault" => slug == current,
        "capabilities" => nil
      }
      |> then(&if(sub, do: Map.put(&1, "subProvider", sub), else: &1))
    end
  end
end
