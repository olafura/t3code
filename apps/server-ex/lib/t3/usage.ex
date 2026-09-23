defmodule T3.Usage do
  @moduledoc """
  Usage reporting (`server.getUsageSummary`, `server.refreshUsageRates`): token
  totals and API-equivalent cost per day or hour, provider, and model, read from the
  provider CLIs' own transcripts so turns driven outside T3 Code count too.

  Each provider home in settings (and its `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or
  `GROK_HOME` override) is one source, fingerprinted by host, real path, and
  `device:inode` so clients drop a directory two environments both read. Parsed
  records are kept per file by size and mtime, in memory and in
  `<home>/usage-scan-cache.bin`, so a repeat scan parses only files that changed,
  and a file that only grew parses only its new lines. Cached files count for 90
  days even after the CLI cleans the transcript up.

  Scans run one at a time in this process; a request that waited on another finds
  the cache warm.
  """

  use GenServer

  alias T3.Usage.{Aggregator, Pricing, Transcripts}

  @contract_version 5
  # Files are filtered by mtime; a session whose last write lands just before local
  # midnight on the first day still counts.
  @mtime_slack_ms 36 * 60 * 60 * 1000
  @max_hourly_window_ms 24 * 60 * 60 * 1000
  @retention_ms 90 * 24 * 60 * 60 * 1000
  @cache_version 1

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`server.getUsageSummary`."
  def summary(input) do
    with {:ok, window} <- window(input) do
      GenServer.call(
        __MODULE__,
        {:summary, window, T3.Settings.settings()},
        :timer.minutes(5)
      )
    end
  end

  @doc "`server.refreshUsageRates`: refetches the rate table ahead of its daily TTL."
  def refresh_rates(_input), do: {:ok, GenServer.call(__MODULE__, :refresh_rates, 30_000)}

  defp window(%{"sinceDay" => since, "untilDay" => until, "timeZone" => zone} = input)
       when is_binary(since) and is_binary(until) and is_binary(zone) do
    with {:ok, since_date} <- day(since, "sinceDay"),
         {:ok, _} <- day(until, "untilDay"),
         true <- since <= until || invalid("sinceDay '#{since}' is after untilDay '#{until}'"),
         {:ok, hours} <- hours(input) do
      start = DateTime.new!(since_date, ~T[00:00:00]) |> DateTime.to_unix(:millisecond)

      {:ok,
       %{
         zone: zone,
         since: since,
         until: until,
         hours: hours,
         files_since: elem(hours || {start, nil}, 0) - @mtime_slack_ms
       }}
    end
  end

  defp window(_), do: invalid("sinceDay, untilDay, and timeZone are required")

  defp day(value, field) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> invalid("#{field} '#{value}' is not a valid date")
    end
  end

  defp hours(%{"resolution" => "hour"} = input) do
    with {:ok, since} <- instant(input["sinceTime"]),
         {:ok, until} <- instant(input["untilTime"]) do
      if until - since > 0 and until - since <= @max_hourly_window_ms,
        do: {:ok, {since, until}},
        else: invalid("Hourly usage window must be greater than zero and at most 24 hours")
    else
      _ -> invalid("Hourly usage requires valid sinceTime and untilTime instants")
    end
  end

  defp hours(_), do: {:ok, nil}

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> {:ok, DateTime.to_unix(at, :millisecond)}
      error -> error
    end
  end

  defp instant(_), do: :error

  defp invalid(detail), do: read_error("invalidWindow", detail)

  defp read_error(reason, detail),
    do:
      {:error,
       %{
         "_tag" => "UsageReadError",
         "reason" => reason,
         "detail" => detail,
         "message" => "Usage read failed (#{reason}): #{detail}"
       }}

  @impl true
  def init(nil) do
    {:ok, %{files: %{}, sources: %{}, loaded: false, dirty: false, rates: Pricing.empty()},
     :hibernate}
  end

  @impl true
  def handle_call(:refresh_rates, _from, state) do
    rates = Pricing.load(state.rates, true)
    {:reply, Pricing.describe(rates), %{state | rates: rates}, :hibernate}
  end

  def handle_call({:summary, window, settings}, _from, state) do
    {reply, state} = scan(window, settings, state)
    {:reply, reply, state, :hibernate}
  rescue
    _ -> {:reply, read_error("scanFailed", "Transcripts could not be scanned."), state}
  end

  # A rates load that outlived a failed scan.
  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp scan(window, settings, state) do
    started = System.system_time(:millisecond)
    cutoff = started - @retention_ms
    state = load_cache(state)

    # Rates load while transcripts stream, so a slow fetch does not add to the scan.
    previous = state.rates

    rates =
      Task.async(fn ->
        try do
          Pricing.load(previous, false)
        rescue
          _ -> previous
        end
      end)

    {dirs, state} = resolve_dirs(settings, state, cutoff)
    {dirs, state} = Enum.map_reduce(dirs, state, &parse_dir(&1, &2, window.files_since))
    state = %{state | rates: Task.await(rates, 30_000)}

    aggregator =
      Aggregator.new(
        time_zone: window.zone,
        since_day: window.since,
        until_day: window.until,
        window: window.hours,
        rates: state.rates.table,
        overrides: Pricing.overrides(settings)
      )

    {:ok, host} = :net.gethostname()

    {sources, aggregator} =
      Enum.map_reduce(dirs, aggregator, &aggregate(&1, &2, state.files, cutoff, to_string(host)))

    state = state |> prune(cutoff) |> persist()
    finished = System.system_time(:millisecond)

    summary = %{
      "contractVersion" => @contract_version,
      "readAt" => iso(finished),
      "timeZone" => window.zone,
      "sinceDay" => window.since,
      "untilDay" => window.until,
      "buckets" => Aggregator.finish(aggregator),
      "sources" => sources,
      "pricing" => Pricing.describe(state.rates),
      "scanDurationMs" => max(0, finished - started)
    }

    {{:ok, summary}, state}
  end

  # One transcript directory per provider home, however many accounts share it.
  # Disabled accounts count: they still have history.
  defp resolve_dirs(settings, state, cutoff) do
    instances = map(settings["providerInstances"])

    for driver <- ["claudeAgent", "codex", "grok"],
        instance <-
          for({_, %{"driver" => ^driver} = i} <- instances, do: i) ++
            if(Map.has_key?(instances, driver),
              do: [],
              else: [%{"config" => get_in(settings, ["providers", driver])}]
            ),
        reduce: {[], state} do
      {dirs, state} ->
        provider = if driver == "claudeAgent", do: "claude", else: driver
        subdir = if provider == "claude", do: "projects", else: "sessions"
        home = home(driver, map(instance["config"]), env(instance["environment"]))
        directory = Path.expand(subdir, home)
        previous = state.sources[{provider, directory}]

        # A removed directory keeps its last real path and identity while its
        # retained history still counts.
        dir =
          case real_path(directory) do
            {:ok, dir} -> dir
            _ -> if previous, do: elem(previous, 0), else: directory
          end

        current = volume_id(dir)

        volume =
          case previous do
            {^dir, volume} when volume != "" ->
              if current == "" or retained?(state.files, provider, dir, cutoff),
                do: volume,
                else: current

            _ ->
              current
          end

        state =
          if previous == {dir, volume},
            do: state,
            else: %{
              state
              | sources: Map.put(state.sources, {provider, directory}, {dir, volume}),
                dirty: true
            }

        if Enum.any?(dirs, &(&1.provider == provider and &1.dir == dir)),
          do: {dirs, state},
          else: {dirs ++ [%{provider: provider, dir: dir, volume: volume}], state}
    end
  end

  defp home("codex", config, env) do
    home = trim(config["homePath"])

    home =
      if home == "" and trim(config["shadowHomePath"]) == "",
        do: trim(env["CODEX_HOME"]),
        else: home

    Path.expand(if home == "", do: "~/.codex", else: home)
  end

  defp home("claudeAgent", config, env) do
    home = trim(config["homePath"])
    home = if home == "", do: trim(env["CLAUDE_CONFIG_DIR"]), else: home
    Path.expand(if home == "", do: "~/.claude", else: home)
  end

  defp home("grok", _config, env) do
    home = trim(env["GROK_HOME"])
    Path.expand(if home == "", do: "~/.grok", else: home)
  end

  defp env(variables) when is_list(variables) do
    for %{"name" => name, "value" => value} <- variables,
        is_binary(name) and is_binary(value),
        into: System.get_env(),
        do: {name, value}
  end

  defp env(_), do: System.get_env()

  defp retained?(files, provider, dir, cutoff) do
    Enum.any?(files, fn {path, entry} ->
      entry.provider == provider and entry.mtime_ms >= cutoff and
        (entry.records != [] or entry.tail != []) and within?(path, dir)
    end)
  end

  defp within?(path, dir), do: String.starts_with?(path, dir <> "/")

  # Parses the directory's files that changed since they were cached, in parallel.
  defp parse_dir(%{provider: provider, dir: dir} = source, state, files_since) do
    if File.exists?(dir) do
      files = Transcripts.list(dir, files_since, if(provider == "grok", do: "updates.jsonl"))

      changed =
        Enum.flat_map(files, fn file ->
          case state.files[file.path] do
            %{provider: ^provider, size: size, mtime_ms: mtime}
            when size == file.size and mtime == file.mtime_ms ->
              []

            # Only a file that grew may resume; a rewrite parses whole.
            %{provider: ^provider, size: size, position: position} when file.size > size ->
              [{file, position}]

            _ ->
              [{file, nil}]
          end
        end)

      state =
        changed
        |> Task.async_stream(
          fn {file, position} -> {file, Transcripts.read(file.path, provider, position)} end,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity
        )
        |> Enum.reduce(state, fn {:ok, {file, parsed}}, state ->
          cache(state, file, provider, parsed)
        end)

      {Map.put(source, :paths, Enum.map(files, & &1.path)), state}
    else
      {Map.put(source, :paths, nil), state}
    end
  end

  # A read failure is not an empty transcript; the cached parse (if any) stays.
  defp cache(state, _file, _provider, nil), do: state

  defp cache(state, file, provider, parsed) do
    base =
      case state.files[file.path] do
        %{records: records} when parsed.resumed -> records
        _ -> []
      end

    {records, seen} = dedupe(base ++ parsed.records, MapSet.new())
    {tail, _} = dedupe(parsed.tail, seen)

    entry = %{
      size: file.size,
      mtime_ms: file.mtime_ms,
      provider: provider,
      records: records,
      tail: tail,
      position: parsed.position
    }

    %{state | files: Map.put(state.files, file.path, entry), dirty: true}
  end

  # Most duplicates repeat within one file, so entries are cached without them.
  defp dedupe(records, seen) do
    {kept, seen} =
      Enum.reduce(records, {[], seen}, fn
        {_, _, _, _, _, nil} = record, {kept, seen} ->
          {[record | kept], seen}

        {_, _, _, _, _, key} = record, {kept, seen} ->
          if MapSet.member?(seen, key),
            do: {kept, seen},
            else: {[record | kept], MapSet.put(seen, key)}
      end)

    {Enum.reverse(kept), seen}
  end

  defp aggregate(
         %{provider: provider, dir: dir, paths: paths} = source,
         aggregator,
         files,
         cutoff,
         host
       ) do
    live = paths || []
    live_set = MapSet.new(live)

    # Transcripts the CLI has cleaned up still count while their parse is retained.
    retained =
      for {path, entry} <- files,
          entry.provider == provider and entry.mtime_ms >= cutoff,
          not MapSet.member?(live_set, path) and within?(path, dir),
          do: path

    {scanned, skipped, sessions, aggregator} =
      Enum.reduce(live ++ retained, {0, 0, MapSet.new(), aggregator}, fn path, acc ->
        add_file(files[path], provider, acc)
      end)

    {%{
       "fingerprint" => %{
         "hostId" => host,
         "provider" => provider,
         "resolvedHomePath" => dir,
         "volumeId" => source.volume
       },
       "status" => if(paths == nil and scanned == 0, do: "missing", else: "ok"),
       "scannedFiles" => scanned,
       "skippedFiles" => skipped,
       "malformedRecords" => 0,
       "distinctSessions" => MapSet.size(sessions),
       "message" => if(paths == nil, do: "No transcript directory on this environment.")
     }, aggregator}
  end

  defp add_file(
         %{provider: provider, records: records, tail: tail},
         provider,
         {scanned, skipped, sessions, aggregator}
       )
       when records != [] or tail != [] do
    {_, sessions, aggregator} =
      Enum.reduce(records ++ tail, {%{}, sessions, aggregator}, fn record,
                                                                   {occurrences, sessions, agg} ->
        {record, occurrences} = codex_key(provider, record, occurrences)
        {added, agg} = Aggregator.add(agg, provider, record)
        session = elem(record, 2)
        sessions = if added and session != "", do: MapSet.put(sessions, session), else: sessions
        {occurrences, sessions, agg}
      end)

    {scanned + 1, skipped, sessions, aggregator}
  end

  defp add_file(_entry, _provider, {scanned, skipped, sessions, aggregator}),
    do: {scanned, skipped + 1, sessions, aggregator}

  # A moved or copied rollout repeats its events; the nth equal event of a session
  # is the same event in every copy, while repeats within one rollout stay distinct.
  defp codex_key("codex", {ts, model, session, totals, cost, nil}, occurrences)
       when session != "" do
    event = {session, ts, model, totals}
    n = Map.get(occurrences, event, 0) + 1
    {{ts, model, session, totals, cost, {event, n}}, Map.put(occurrences, event, n)}
  end

  defp codex_key(_provider, record, occurrences), do: {record, occurrences}

  defp prune(state, cutoff) do
    files =
      for {path, entry} <- state.files, entry.mtime_ms >= cutoff, into: %{}, do: {path, entry}

    if map_size(files) == map_size(state.files),
      do: state,
      else: %{state | files: files, dirty: true}
  end

  defp cache_path, do: Path.join(Application.fetch_env!(:t3, :home), "usage-scan-cache.bin")

  defp load_cache(%{loaded: true} = state), do: state

  defp load_cache(state) do
    case File.read(cache_path()) do
      {:ok, binary} ->
        case :erlang.binary_to_term(binary, [:safe]) do
          %{version: @cache_version, files: %{} = files, sources: %{} = sources} ->
            %{state | files: files, sources: sources, loaded: true}

          _ ->
            %{state | loaded: true}
        end

      _ ->
        %{state | loaded: true}
    end
  rescue
    _ -> %{state | loaded: true}
  end

  # Cleared only once the write lands, so a failed write is retried next scan.
  defp persist(%{dirty: false} = state), do: state

  defp persist(state) do
    path = cache_path()
    tmp = path <> ".tmp"

    binary =
      :erlang.term_to_binary(%{
        version: @cache_version,
        files: state.files,
        sources: state.sources
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, binary),
         :ok <- File.rename(tmp, path) do
      %{state | dirty: false}
    else
      _ -> state
    end
  end

  defp real_path(path, depth \\ 0) do
    [root | parts] = Path.split(path)

    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, prefix} ->
      next = Path.join(prefix, part)

      case :file.read_link_all(next) do
        {:ok, target} when depth < 32 ->
          case real_path(Path.expand(to_string(target), prefix), depth + 1) do
            {:ok, resolved} -> {:cont, {:ok, resolved}}
            error -> {:halt, error}
          end

        {:ok, _} ->
          {:halt, {:error, :eloop}}

        {:error, :einval} ->
          {:cont, {:ok, next}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp volume_id(dir) do
    case File.stat(dir) do
      {:ok, %{major_device: device, inode: inode}} -> "#{device}:#{inode}"
      _ -> ""
    end
  end

  defp map(%{} = value), do: value
  defp map(_), do: %{}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
