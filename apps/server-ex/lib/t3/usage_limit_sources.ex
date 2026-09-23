defmodule T3.UsageLimitSources do
  @moduledoc """
  Quota from places this node cannot run turns on: today CLIProxyAPI hubs pooling
  several subscription accounts (`settings.usageLimitSources`, read with
  `T3.UsageLimitSources.Cliproxy`), as the Node server's UsageLimitSources does.

  Every enabled source is read at boot, when the sources in settings change, on an
  untargeted `server.refreshProviders`, and every `providerHealthRefreshInterval`
  while a client watches this node's config. Clients get the snapshots
  (`UsageLimitSourceSnapshot[]`) after the config snapshot and whenever they change,
  as `{:t3_usage_limit_sources, node, sources}` through `T3.Settings` watchers. A
  source that cannot be read keeps its row with `error` set. Nothing is persisted.

  Reads and redemptions run one at a time in this process, so a slow read started
  before a settings change never publishes after the change's own read. The published
  set lives in ETS, so `current/0` never waits on a hub.

  A hub's management key is a bearer secret. `seal_keys/2` keeps it out of the settings
  document, in `<home>/secrets`, as the Node server does: settings carry a marker
  instead, and a client that sends the marker back means "keep the key".
  """

  use GenServer

  alias T3.UsageLimitSources.Cliproxy

  @marker "••••••"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The published snapshots."
  def current do
    case :ets.lookup(__MODULE__, :sources) do
      [{_, sources}] -> sources
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Reads every source now."
  def refresh do
    GenServer.call(__MODULE__, :refresh, 120_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Reads every source soon, such as after a settings change."
  def refresh_async, do: GenServer.cast(__MODULE__, :refresh)

  @doc "`provider.consumeResetCredit` for a hub account."
  def consume_reset_credit(%{"sourceId" => _, "accountId" => _, "creditId" => _} = input),
    do: GenServer.call(__MODULE__, {:consume, input}, 120_000)

  def consume_reset_credit(_), do: source_error("The reset credit request is incomplete.")

  @doc """
  Moves plain management keys in `next` into the secret store and forgets those of
  sources `current` had and `next` drops. Returns the settings to store and whether a
  key changed, which the stored document alone cannot show.
  """
  def seal_keys(next, current) do
    sources = next["usageLimitSources"]
    previous = (current["usageLimitSources"] || %{}) |> Map.keys()

    {sealed, changed} =
      if is_map(sources) do
        Enum.map_reduce(sources, false, fn
          {id, %{"managementKey" => @marker} = source}, changed ->
            {{id, source}, changed}

          {id, %{"managementKey" => key} = source}, _ when is_binary(key) and key != "" ->
            write_key(id, key)
            {{id, Map.put(source, "managementKey", @marker)}, true}

          {id, source}, changed ->
            {{id, source}, remove_key(id) or changed}
        end)
      else
        {[], false}
      end

    dropped = Enum.reject(previous, &Map.has_key?(sources || %{}, &1))
    changed = Enum.reduce(dropped, changed, &(remove_key(&1) or &2))

    settings =
      if is_map(sources), do: Map.put(next, "usageLimitSources", Map.new(sealed)), else: next

    {settings, changed}
  end

  @doc "A source's management key, or \"\"."
  def key(id) do
    case File.read(key_path(id)) do
      {:ok, key} -> key
      _ -> ""
    end
  end

  defp write_key(id, key) do
    path = key_path(id)
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    tmp = path <> ".tmp"
    File.write!(tmp, key)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  defp remove_key(id), do: File.rm(key_path(id)) == :ok

  defp key_path(id),
    do:
      Path.join([
        Application.fetch_env!(:t3, :home),
        "secrets",
        "usage-limit-source-#{Base.url_encode64(id, padding: false)}.bin"
      ])

  # --- server --------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    :ets.insert(__MODULE__, {:sources, []})
    {:ok, nil, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state) do
    read_all()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    read_all()
    {:reply, :ok, state}
  end

  def handle_call({:consume, input}, _from, state) do
    %{"sourceId" => id, "accountId" => account, "creditId" => credit} = input
    config = get_in(T3.Settings.settings(), ["usageLimitSources", id])
    key = key(id)

    reply =
      if not is_map(config) or config["enabled"] == false or key == "" do
        source_error("The usage limit source is missing or disabled.")
      else
        case Cliproxy.consume(config, key, account, credit) do
          {:ok, result} ->
            snapshot = read_source(id, config)
            publish(Enum.map(current(), &if(&1["id"] == id, do: snapshot, else: &1)))
            {:ok, result}

          {:error, detail} ->
            source_error(detail)
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    drain_refreshes()
    read_all()
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if T3.ProviderUsageLimits.wanted?() and T3.ProviderUsageLimits.interval() != :off,
      do: read_all()

    schedule()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule do
    ms = with :off <- T3.ProviderUsageLimits.interval(), do: 60_000
    Process.send_after(self(), :tick, ms)
  end

  # Settings edits arrive in bursts; one read after them covers them all.
  defp drain_refreshes do
    receive do
      {:"$gen_cast", :refresh} -> drain_refreshes()
    after
      0 -> :ok
    end
  end

  defp read_all do
    (T3.Settings.settings()["usageLimitSources"] || %{})
    |> Enum.filter(fn {_, config} ->
      is_map(config) and config["kind"] == "cliproxy" and config["enabled"] != false
    end)
    |> Task.async_stream(fn {id, config} -> read_source(id, config) end,
      max_concurrency: 4,
      timeout: 120_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, snapshot} -> snapshot
      {:exit, {{id, config}, _}} -> failed(id, config, "The hub management request failed.")
    end)
    |> publish()
  end

  defp read_source(id, config) do
    case key(id) do
      "" ->
        failed(id, config, "No management key configured.")

      key ->
        case Cliproxy.read_accounts(config, key) do
          {:ok, accounts} -> Map.put(base(id, config), "accounts", accounts)
          {:error, detail} -> failed(id, config, detail)
        end
    end
  end

  defp failed(id, config, error),
    do: base(id, config) |> Map.merge(%{"accounts" => [], "error" => error})

  defp base(id, config),
    do: %{
      "id" => id,
      "kind" => config["kind"],
      "label" => label(id, config),
      "checkedAt" => T3.Orchestration.Entities.now()
    }

  # The configured label, else the hub's host (with a port it names), else the id.
  defp label(id, config) do
    with nil <- non_empty(config["label"]),
         %URI{host: host, port: port, scheme: scheme} when host not in [nil, ""] <-
           URI.parse(config["url"] || "") do
      if port && port != URI.default_port(scheme || ""),
        do: "#{host}:#{port}",
        else: host
    else
      label when is_binary(label) -> label
      _ -> id
    end
  end

  defp non_empty(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp non_empty(_), do: nil

  defp publish(sources) do
    if sources != current() do
      :ets.insert(__MODULE__, {:sources, sources})
      T3.Settings.notify_usage_limit_sources(sources)
    end
  end

  defp source_error(detail),
    do: {:error, %{"_tag" => "UsageLimitSourceError", "detail" => detail, "message" => detail}}
end
