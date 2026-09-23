defmodule T3.Settings do
  @moduledoc """
  This node's `ServerSettings`, kept in `<home>/settings.json` (owner-only, since
  provider environments can hold secrets).

  The node stores the document; it does not interpret patches. A client applies a
  `server.updateSettings` patch with the shared `applyServerSettingsPatch` to the
  version it read and writes the whole result back with `put/2`, which refuses a
  stale version so concurrent editors retry instead of overwriting each other.
  Watchers (client sockets) get `{:t3_settings, node, settings}` on every change,
  and `{:t3_providers_changed, node}` when something else changes the node's
  provider list (`notify_providers/0`).

  Hub management keys never stay in the document: `T3.UsageLimitSources.seal_keys/2`
  moves them to the secret store on every write, so nothing a client reads carries one.
  """

  use GenServer

  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The settings document (`%{}` when never written; clients fill in defaults)."
  def settings, do: elem(get(), 0)

  # The keys a project may override (`ProjectSettingsOverrides`).
  @project_scoped ~w(worktreeCleanup defaultModelSelection defaultRuntimeMode defaultThreadEnvMode
                     newWorktreesStartFromOrigin worktreeSubmodules defaultAutoPull
                     defaultProjectScripts enableAgentBrowserAccess enableAgentDeviceAccess
                     textGenerationModelSelection sourceControlWriterModelSelection
                     sourceControlWritingStyle pullRequestMergeMethod sidebarAutoSettleOnMerge
                     sidebarAutoSettleAfterDays continueThreadsAfterServerUpdate
                     responseStreamingMode)

  @doc """
  The settings as they apply to one project: its `projectSettingsOverrides` entry
  over the environment's values, as the Node server resolves them. A model
  override on a disabled provider falls back to the environment's.
  """
  def for_project(project_id), do: resolve(settings(), project_id)

  @doc false
  def resolve(settings, project_id) do
    overrides = get_in(settings, ["projectSettingsOverrides", project_id]) || %{}

    Enum.reduce(overrides, settings, fn {key, value}, acc ->
      cond do
        key not in @project_scoped ->
          acc

        key in ~w(textGenerationModelSelection defaultModelSelection) and is_map(value) and
            not provider_enabled?(settings, value["instanceId"]) ->
          acc

        true ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp provider_enabled?(settings, instance) do
    case get_in(settings, ["providerInstances", instance]) do
      %{} = config -> config["enabled"] != false
      nil -> get_in(settings, ["providers", instance, "enabled"]) != false
    end
  end

  @doc "`{settings, version}`."
  def get do
    GenServer.call(__MODULE__, :get)
  catch
    # A node started without settings (tests, tools) has defaults.
    :exit, {:noproc, _} -> {%{}, 0}
  end

  @doc "Replaces the document if it is still at `version`; returns the new version."
  def put(settings, version), do: GenServer.call(__MODULE__, {:put, settings, version})

  def watch(pid) do
    GenServer.call(__MODULE__, {:watch, pid})
  catch
    :exit, {:noproc, _} -> :ok
  end

  def unwatch(pid), do: GenServer.cast(__MODULE__, {:unwatch, pid})

  @doc "Whether any client watches this node's config; background refreshes wait for one."
  def watched? do
    GenServer.call(__MODULE__, :watched?)
  catch
    :exit, {:noproc, _} -> false
  end

  @doc "Tells watchers to read the provider list again, such as after a model probe."
  def notify_providers, do: GenServer.cast(__MODULE__, :providers_changed)

  @doc "Tells watchers the published themes changed (`T3.EnvironmentThemes`)."
  def notify_themes(themes), do: GenServer.cast(__MODULE__, {:themes_changed, themes})

  @doc "Tells watchers the usage-limit source snapshots changed (`T3.UsageLimitSources`)."
  def notify_usage_limit_sources(sources),
    do: GenServer.cast(__MODULE__, {:usage_limit_sources_changed, sources})

  @doc "Tells watchers the keybinding rules changed (`T3.Keybindings`)."
  def notify_keybindings(rules), do: GenServer.cast(__MODULE__, {:keybindings_changed, rules})

  @impl true
  def init(nil) do
    path = Path.join(Application.fetch_env!(:t3, :home), "settings.json")

    settings =
      with {:ok, text} <- File.read(path),
           {:ok, %{} = settings} <- JSON.decode(text) do
        settings
      else
        {:error, :enoent} ->
          %{}

        other ->
          Logger.warning("ignoring unreadable #{path}: #{inspect(other)}")
          %{}
      end

    # A key written in plain text (by hand, or before keys were sealed) moves out now.
    {settings, changed} = T3.UsageLimitSources.seal_keys(settings, %{})
    if changed, do: write!(path, settings)

    {:ok, %{path: path, settings: settings, version: 0, watchers: %{}}}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, {state.settings, state.version}, state}

  def handle_call({:put, settings, version}, _from, %{version: version} = state) do
    {settings, keys_changed} = T3.UsageLimitSources.seal_keys(settings, state.settings)
    write!(state.path, settings)

    if keys_changed or settings["usageLimitSources"] != state.settings["usageLimitSources"],
      do: T3.UsageLimitSources.refresh_async()

    for {pid, _} <- state.watchers, do: send(pid, {:t3_settings, node(), settings})
    {:reply, {:ok, version + 1}, %{state | settings: settings, version: version + 1}}
  end

  def handle_call({:put, _settings, _version}, _from, state),
    do: {:reply, {:error, :stale}, state}

  def handle_call(:watched?, _from, state), do: {:reply, state.watchers != %{}, state}

  def handle_call({:watch, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast(:providers_changed, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:t3_providers_changed, node()})
    {:noreply, state}
  end

  def handle_cast({:keybindings_changed, rules}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:t3_keybindings, node(), rules})
    {:noreply, state}
  end

  def handle_cast({:usage_limit_sources_changed, sources}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:t3_usage_limit_sources, node(), sources})
    {:noreply, state}
  end

  def handle_cast({:themes_changed, themes}, state) do
    for {pid, _} <- state.watchers, do: send(pid, {:t3_themes, node(), themes})
    {:noreply, state}
  end

  def handle_cast({:unwatch, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  # Written to a temporary file and renamed, so a crash never leaves half a file.
  defp write!(path, settings) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode_to_iodata!(settings))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end
end
