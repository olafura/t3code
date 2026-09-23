defmodule T3.Acp do
  @moduledoc """
  The Agent Client Protocol agents a node can run (`T3.Acp.ThreadRuntime`), and
  their entries in `ServerConfig.providers`.

  ACP agents are off until enabled in the node's settings (`providers.<driver>` or
  a `providerInstances` entry), as on the Node server, so nothing is spawned for
  users who never opted in. An enabled agent's model list comes from the `model`
  config option of a throwaway session, which lists the models of the providers it
  is connected to; it is read once, at boot or when the agent is first enabled.
  """

  alias T3.JsonRpc.Connection

  @agents %{
    "opencode" => %{binary: "opencode", label: "OpenCode"},
    "grok" => %{binary: "grok", label: "Grok"}
  }

  @doc "Driver ids of the ACP agents."
  def drivers, do: Map.keys(@agents)

  def agent?(driver), do: Map.has_key?(@agents, driver)

  def label(driver), do: get_in(@agents, [driver, :label]) || driver

  @doc """
  The command that starts an agent for a thread's runtime mode, with the binary
  set in the node's provider settings; `:acp_commands` overrides it (tests).
  """
  def command(driver, runtime_mode \\ nil) do
    cond do
      command = Application.get_env(:t3, :acp_commands, %{})[driver] ->
        {:ok, command}

      agent = @agents[driver] ->
        {:ok, [binary(driver, agent.binary) | args(driver, runtime_mode)]}

      true ->
        {:error, "unknown ACP agent #{driver}"}
    end
  end

  defp args("opencode", _mode), do: ["acp"]

  # Grok applies permissions itself; full access skips its prompts entirely.
  defp args("grok", "full-access"), do: ["agent", "--always-approve", "stdio"]
  defp args("grok", "approval-required"), do: ["--permission-mode", "default", "agent", "stdio"]

  defp args("grok", "auto-accept-edits"),
    do: ["--permission-mode", "acceptEdits", "agent", "stdio"]

  defp args("grok", "auto"), do: ["--permission-mode", "auto", "agent", "stdio"]
  defp args("grok", _mode), do: ["agent", "stdio"]

  defp binary(driver, default) do
    settings = T3.Settings.settings()

    [
      get_in(settings, ["providerInstances", driver, "config", "binaryPath"]),
      get_in(settings, ["providers", driver, "binaryPath"])
    ]
    |> Enum.find(default, &(is_binary(&1) and String.trim(&1) != ""))
  end

  @doc "Provider entries for the agents installed on this node."
  def entries, do: for(driver <- drivers(), entry = entry(driver), do: entry)

  def entry(driver) do
    with {:ok, [executable | _]} <- command(driver),
         path when is_binary(path) <- System.find_executable(executable) do
      _ = path
      enabled = enabled?(driver)
      models = :persistent_term.get({__MODULE__, driver, :models}, nil)
      if enabled and models == nil, do: load_once(driver)

      %{
        "instanceId" => driver,
        "driver" => driver,
        "enabled" => enabled,
        "installed" => true,
        "version" => :persistent_term.get({__MODULE__, driver, :version}, "unknown"),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => T3.Orchestration.Entities.now(),
        "models" => models || [],
        "slashCommands" => [],
        "skills" => []
      }
    else
      _ -> nil
    end
  end

  @doc "Reads each enabled agent's version and models from a throwaway session."
  def load do
    for driver <- drivers(), enabled?(driver), do: load(driver)
    :ok
  end

  # An agent enabled after boot is read in the background, once.
  defp load_once(driver) do
    if :persistent_term.get({__MODULE__, driver, :loading}, false) == false do
      :persistent_term.put({__MODULE__, driver, :loading}, true)
      Task.start(fn -> load(driver) end)
    end
  end

  @doc "Whether the node's settings enable an agent (off by default)."
  def enabled?(driver) do
    settings = T3.Settings.settings()
    instance = get_in(settings, ["providerInstances", driver]) || %{}

    cond do
      instance["enabled"] == false or get_in(instance, ["config", "enabled"]) == false ->
        false

      is_boolean(instance["enabled"]) ->
        instance["enabled"]

      is_boolean(get_in(instance, ["config", "enabled"])) ->
        get_in(instance, ["config", "enabled"])

      true ->
        get_in(settings, ["providers", driver, "enabled"]) == true
    end
  end

  defp load(driver) do
    dir = Path.join(System.tmp_dir!(), "t3-acp-#{driver}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      read_agent(driver, dir)
    catch
      _, _ -> :ok
    after
      File.rm_rf(dir)
    end
  end

  defp read_agent(driver, dir) do
    with {:ok, command} <- command(driver),
         path when is_binary(path) <- System.find_executable(hd(command)),
         {:ok, conn} <-
           Connection.start_link(cmd: command, handler: self(), cd: dir, dialect: :v2),
         {:ok, init} <-
           Connection.call(conn, "initialize", %{
             "protocolVersion" => 1,
             "clientCapabilities" => %{
               "fs" => %{"readTextFile" => false, "writeTextFile" => false},
               "terminal" => false
             }
           }),
         {:ok, session} <-
           Connection.call(conn, "session/new", %{"cwd" => dir, "mcpServers" => []}, 60_000) do
      :persistent_term.put(
        {__MODULE__, driver, :version},
        get_in(init, ["agentInfo", "version"]) || "unknown"
      )

      :persistent_term.put({__MODULE__, driver, :models}, models(session))
      Connection.stop(conn)
    end
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
