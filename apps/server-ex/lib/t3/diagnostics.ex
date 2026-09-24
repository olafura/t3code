defmodule T3.Diagnostics do
  @moduledoc """
  What the node and the processes it started are doing (Settings → Diagnostics).

  A sampler reads the process tree under the node with `ps`: every 15 seconds,
  or every 2 while a client watches the resource monitor. It keeps an hour of
  samples. From those come the process list (`server.getProcessDiagnostics`),
  the resource monitor's live snapshots and timeline (`subscribeResourceTelemetry`,
  `server.getResourceTelemetryHistory`) and the process history
  (`server.getProcessResourceHistory`). `server.signalProcess` only signals a
  process under the node that is still the one a client saw. `ps` has no I/O
  counters, so I/O is reported as unavailable. Nodes record no trace files, and
  there is no desktop host to supply power state.

  Watchers get `{:t3_resource_telemetry, node, snapshot}` after every sample.
  """

  use GenServer

  @idle_every 15_000
  @watched_every 2_000
  @keep :timer.hours(1)
  @providers ~w(codex claude opencode grok cursor-agent pi-acp node devin gemini)
  @shells ~w(zsh bash fish sh nu)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`server.getProcessDiagnostics`."
  def processes(_input \\ %{}) do
    root = os_pid()
    base = %{"serverPid" => root, "readAt" => now()}

    case tree(root) do
      {:ok, rows} ->
        {:ok,
         Map.merge(base, %{
           "processCount" => length(rows),
           "totalRssBytes" => rows |> Enum.map(& &1.rss) |> Enum.sum(),
           "totalCpuPercent" => rows |> Enum.map(& &1.cpu) |> Enum.sum(),
           "processes" => Enum.map(rows, &diagnostics_entry/1),
           "error" => none()
         })}

      {:error, message} ->
        {:ok,
         Map.merge(base, %{
           "processCount" => 0,
           "totalRssBytes" => 0,
           "totalCpuPercent" => 0,
           "processes" => [],
           "error" => some(%{"message" => message})
         })}
    end
  end

  @doc "`server.signalProcess`: only a process under this node, and only the one that was seen."
  def signal(%{"pid" => pid, "startTimeMs" => started, "signal" => signal}) do
    result = %{"pid" => pid, "signal" => signal}

    with {:ok, rows} <- tree(os_pid()),
         %{started: seen} <- Enum.find(rows, &(&1.pid == pid)) || :not_ours,
         true <- pid != os_pid() || :server,
         true <- abs(seen - started) < 2_000 || :replaced,
         {_, 0} <-
           System.cmd("kill", ["-#{String.trim_leading(signal, "SIG")}", "#{pid}"],
             stderr_to_stdout: true
           ) do
      {:ok, Map.merge(result, %{"signaled" => true, "message" => none()})}
    else
      reason ->
        message =
          case reason do
            :not_ours -> "That process is not one this node started."
            :server -> "The node itself cannot be signalled from here."
            :replaced -> "That process has already exited."
            {:error, message} -> message
            {out, _} -> String.trim(out)
          end

        {:ok, Map.merge(result, %{"signaled" => false, "message" => some(message)})}
    end
  end

  @doc "`server.getTraceDiagnostics`: nodes keep logs, not trace files."
  def traces(_input \\ %{}) do
    {:ok,
     %{
       "traceFilePath" =>
         Path.join([Application.fetch_env!(:t3, :home), "logs", "server.trace.ndjson"]),
       "scannedFilePaths" => [],
       "readAt" => now(),
       "recordCount" => 0,
       "parseErrorCount" => 0,
       "firstSpanAt" => none(),
       "lastSpanAt" => none(),
       "failureCount" => 0,
       "interruptionCount" => 0,
       "slowSpanThresholdMs" => 1_000,
       "slowSpanCount" => 0,
       "logLevelCounts" => %{},
       "topSpansByCount" => [],
       "slowestSpans" => [],
       "commonFailures" => [],
       "latestFailures" => [],
       "latestWarningAndErrorLogs" => [],
       "partialFailure" => none(),
       "error" =>
         some(%{
           "kind" => "trace-file-not-found",
           "message" => "This node does not record traces."
         })
     }}
  end

  @doc "`server.getHostResources`."
  def host(_input \\ %{}) do
    {total, available} = memory()

    {:ok,
     %{
       "sampledAt" => System.system_time(:millisecond),
       "cpuUtilization" => nil,
       "cpuCount" =>
         case :erlang.system_info(:logical_processors) do
           count when is_integer(count) -> count
           _ -> System.schedulers_online()
         end,
       "availableMemoryBytes" => available,
       "totalMemoryBytes" => total
     }}
  end

  @doc "`server.getProcessResourceHistory`."
  def history(%{"windowMs" => window, "bucketMs" => bucket}),
    do: {:ok, GenServer.call(__MODULE__, {:history, :process, window, bucket})}

  @doc "`server.getResourceTelemetryHistory`."
  def telemetry_history(%{"windowMs" => window, "bucketMs" => bucket}),
    do: {:ok, GenServer.call(__MODULE__, {:history, :telemetry, window, bucket})}

  @doc "`server.retryResourceTelemetry`: samples now."
  def retry(_input \\ %{}),
    do: {:ok, %{"accepted" => true, "snapshot" => GenServer.call(__MODULE__, :sample_now)}}

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  # --- sampler -----------------------------------------------------------------

  @impl true
  def init(nil) do
    send(self(), :sample)
    {:ok, %{samples: [], watchers: %{}, timer: nil}}
  end

  @impl true
  def handle_call(:sample_now, _from, state) do
    state = sample(state)
    {:reply, snapshot(state), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if state.watchers == %{}, do: T3.Desktop.Channel.set_diagnostics_demand(true)
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    state = sample(%{state | watchers: watchers})
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:history, kind, window, bucket}, _from, state) do
    at = System.system_time(:millisecond)
    samples = state.samples |> Enum.filter(fn {t, _} -> at - t <= window end) |> Enum.reverse()
    {:reply, history(kind, samples, window, max(bucket, interval(state)), state), state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, unwatched(%{state | watchers: watchers})}
  end

  @impl true
  def handle_info(:sample, state) do
    state = sample(%{state | timer: nil})
    snapshot = if state.watchers != %{}, do: snapshot(state)
    for {pid, _} <- state.watchers, do: send(pid, {:t3_resource_telemetry, node(), snapshot})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, unwatched(%{state | watchers: Map.delete(state.watchers, pid)})}

  # The desktop app samples Electron only while someone watches.
  defp unwatched(%{watchers: watchers} = state) when watchers == %{} do
    T3.Desktop.Channel.set_diagnostics_demand(false)
    state
  end

  defp unwatched(state), do: state

  defp sample(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    at = System.system_time(:millisecond)

    samples =
      case tree(os_pid()) do
        {:ok, rows} -> [{at, rows} | state.samples]
        _ -> state.samples
      end

    %{
      state
      | samples: Enum.take_while(samples, fn {t, _} -> at - t <= @keep end),
        timer: Process.send_after(self(), :sample, interval(state))
    }
  end

  defp interval(state), do: if(state.watchers == %{}, do: @idle_every, else: @watched_every)

  # --- telemetry ---------------------------------------------------------------

  # `ResourceTelemetrySnapshot` from the latest sample.
  defp snapshot(state) do
    {at, rows} = List.first(state.samples, {System.system_time(:millisecond), []})
    first_seen = first_seen(state.samples)

    processes =
      for row <- rows do
        %{
          "identity" => identity(row),
          "ppid" => row.ppid,
          "childPids" => row.children,
          "depth" => row.depth,
          "name" => row.name,
          "command" => row.command,
          "status" => row.stat,
          "category" => category(row),
          "cpuPercent" => row.cpu,
          "cpuTimeMs" => row.cpu_time,
          "residentBytes" => row.rss,
          "peakResidentBytes" => peak_rss(state.samples, key(row)),
          "virtualBytes" => row.vsz,
          "ioReadBytes" => 0,
          "ioWriteBytes" => 0,
          "ioReadBytesPerSecond" => 0,
          "ioWriteBytesPerSecond" => 0,
          "ioSemantics" => "unavailable",
          "runTimeMs" => max(at - row.started, 0),
          "firstSeenAt" => iso(Map.get(first_seen, key(row), at)),
          "lastSeenAt" => iso(at)
        }
      end

    backend = aggregate(rows, state.samples)
    empty = aggregate([], [])
    desktop = T3.Desktop.Channel.telemetry()
    electron = electron_processes(desktop, at)

    electron_group = %{
      empty
      | "processCount" => length(electron),
        "currentCpuPercent" => electron |> Enum.map(& &1["cpuPercent"]) |> Enum.sum(),
        "currentRssBytes" => electron |> Enum.map(& &1["residentBytes"]) |> Enum.sum(),
        "peakRssBytes" => electron |> Enum.map(& &1["peakResidentBytes"]) |> Enum.sum()
    }

    %{
      "readAt" => iso(at),
      "sampleIntervalMs" => interval(state),
      "processes" => processes ++ electron,
      "groups" => %{
        "backend" => backend,
        "electron" => electron_group,
        "monitor" => empty,
        "allT3" => %{
          backend
          | "processCount" => backend["processCount"] + electron_group["processCount"],
            "currentCpuPercent" =>
              backend["currentCpuPercent"] + electron_group["currentCpuPercent"],
            "currentRssBytes" => backend["currentRssBytes"] + electron_group["currentRssBytes"]
        }
      },
      "power" => (desktop && desktop["power"]) || power(),
      "speedLimitPercent" =>
        if(desktop && is_number(desktop["speedLimitPercent"]),
          do: some(desktop["speedLimitPercent"]),
          else: none()
        ),
      "attribution" => %{"readAt" => iso(at), "entries" => []},
      "health" => health(state, length(rows))
    }
  end

  defp aggregate(rows, samples) do
    %{
      "processCount" => length(rows),
      "currentCpuPercent" => rows |> Enum.map(& &1.cpu) |> Enum.sum(),
      "cpuTimeMs" => rows |> Enum.map(& &1.cpu_time) |> Enum.sum(),
      "currentRssBytes" => rows |> Enum.map(& &1.rss) |> Enum.sum(),
      "peakRssBytes" =>
        samples
        |> Enum.map(fn {_, rows} -> rows |> Enum.map(& &1.rss) |> Enum.sum() end)
        |> Enum.max(fn -> 0 end),
      "ioReadBytes" => 0,
      "ioWriteBytes" => 0,
      "ioReadBytesPerSecond" => 0,
      "ioWriteBytesPerSecond" => 0,
      "processStarts" => 0,
      "processExits" => 0
    }
  end

  defp health(state, count) do
    %{
      "native" => %{
        "status" => if(state.samples == [], do: "starting", else: "healthy"),
        "lastSampleAt" =>
          case state.samples do
            [{at, _} | _] -> some(iso(at))
            [] -> none()
          end,
        "lastError" => none()
      },
      "desktop" => desktop_health(),
      "sidecarVersion" => none(),
      "sidecarPid" => none(),
      "restartCount" => 0,
      "collectionDurationMicros" => 0,
      "scannedProcessCount" => count,
      "retainedProcessCount" => count,
      "inaccessibleProcessCount" => 0
    }
  end

  defp power do
    %{
      "source" => "unknown",
      "idle" => "unknown",
      "idleSeconds" => nil,
      "locked" => "unknown",
      "suspended" => false,
      "onBattery" => "unknown",
      "lowPowerMode" => "unknown",
      "thermalState" => "unknown",
      "stale" => true,
      "updatedAt" => now()
    }
  end

  defp category(%{depth: 0}), do: "server"

  defp category(row) do
    cond do
      row.name in @shells ->
        "terminal-root"

      Enum.any?(@providers, &(row.name == &1 or String.starts_with?(row.name, &1 <> "-"))) ->
        "provider-root"

      true ->
        "server-child"
    end
  end

  # --- history -----------------------------------------------------------------

  defp history(kind, samples, window, bucket, state) do
    buckets =
      samples
      |> Enum.group_by(fn {t, _} -> div(t, bucket) end)
      |> Enum.sort()
      |> Enum.map(fn {index, in_bucket} -> bucket(kind, index, bucket, in_bucket) end)

    root = os_pid()

    top =
      samples
      |> Enum.flat_map(fn {t, rows} -> Enum.map(rows, &{t, &1}) end)
      |> Enum.group_by(fn {_, row} -> key(row) end)
      |> Enum.map(fn {key, seen} ->
        {first, _} = hd(seen)
        {last, latest} = List.last(seen)
        cpu = Enum.map(seen, fn {_, row} -> row.cpu end)
        peak = seen |> Enum.map(fn {_, row} -> row.rss end) |> Enum.max()

        stats = %{
          "avgCpuPercent" => Enum.sum(cpu) / length(cpu),
          "maxCpuPercent" => Enum.max(cpu),
          "sampleCount" => length(seen)
        }

        {latest.cpu_time, summary(kind, key, latest, stats, {first, last, peak}, root)}
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(20)
      |> Enum.map(&elem(&1, 1))

    base = %{
      "readAt" => now(),
      "windowMs" => window,
      "bucketMs" => bucket,
      "sampleIntervalMs" => interval(state),
      "retainedSampleCount" => length(state.samples),
      "buckets" => buckets,
      "topProcesses" => top
    }

    case kind do
      :telemetry ->
        latest = samples |> List.last({0, []}) |> elem(1)
        Map.put(base, "health", health(state, length(latest)))

      :process ->
        Map.merge(base, %{
          "totalCpuSecondsApprox" => top |> Enum.map(& &1["cpuSecondsApprox"]) |> Enum.sum(),
          "error" => none()
        })
    end
  end

  defp bucket(kind, index, size, samples) do
    cpu = for {_, rows} <- samples, do: rows |> Enum.map(& &1.cpu) |> Enum.sum()

    %{
      "startedAt" => iso(index * size),
      "endedAt" => iso((index + 1) * size),
      "avgCpuPercent" => Enum.sum(cpu) / length(cpu),
      "maxCpuPercent" => Enum.max(cpu),
      "maxRssBytes" =>
        samples
        |> Enum.map(fn {_, rows} -> rows |> Enum.map(& &1.rss) |> Enum.sum() end)
        |> Enum.max(),
      "maxProcessCount" => samples |> Enum.map(fn {_, rows} -> length(rows) end) |> Enum.max()
    }
    |> then(
      &if(kind == :telemetry,
        do: Map.merge(&1, %{"ioReadBytes" => 0, "ioWriteBytes" => 0}),
        else: &1
      )
    )
  end

  defp summary(:telemetry, _key, row, stats, {first, last, peak}, _root) do
    Map.merge(stats, %{
      "identity" => identity(row),
      "ppid" => row.ppid,
      "depth" => row.depth,
      "name" => row.name,
      "command" => row.command,
      "category" => category(row),
      "firstSeenAt" => iso(first),
      "lastSeenAt" => iso(last),
      "currentCpuPercent" => row.cpu,
      "cpuTimeMs" => row.cpu_time,
      "currentRssBytes" => row.rss,
      "peakRssBytes" => peak,
      "ioReadBytes" => 0,
      "ioWriteBytes" => 0,
      "ioSemantics" => "unavailable"
    })
  end

  defp summary(:process, key, row, stats, {first, last, peak}, root) do
    Map.merge(stats, %{
      "processKey" => key,
      "pid" => row.pid,
      "ppid" => row.ppid,
      "command" => row.command,
      "depth" => row.depth,
      "isServerRoot" => row.pid == root,
      "firstSeenAt" => iso(first),
      "lastSeenAt" => iso(last),
      "currentCpuPercent" => row.cpu,
      "cpuSecondsApprox" => row.cpu_time / 1000,
      "currentRssBytes" => row.rss,
      "maxRssBytes" => peak
    })
  end

  defp first_seen(samples) do
    samples
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn {t, rows}, seen ->
      Enum.reduce(rows, seen, &Map.put_new(&2, key(&1), t))
    end)
  end

  defp peak_rss(samples, key) do
    for({_, rows} <- samples, row <- rows, key(row) == key, do: row.rss) |> Enum.max(fn -> 0 end)
  end

  defp key(row), do: "#{row.pid}:#{row.started}"
  defp identity(row), do: %{"pid" => row.pid, "startTimeMs" => max(row.started, 0)}

  # The desktop app's Electron processes, from its telemetry channel.
  defp electron_processes(nil, _at), do: []

  defp electron_processes(desktop, at) do
    for metric <- desktop["electronProcesses"] || [] do
      category =
        case metric["type"] do
          "Browser" -> "electron-main"
          "Tab" -> "electron-renderer"
          "GPU" -> "electron-gpu"
          _ -> "electron-utility"
        end

      started = metric["creationTimeMs"] || 0

      %{
        "identity" => %{"pid" => metric["pid"], "startTimeMs" => started},
        "ppid" => 0,
        "childPids" => [],
        "depth" => 0,
        "name" => metric["name"] || metric["type"],
        "command" => metric["serviceName"] || metric["name"] || metric["type"],
        "status" => "running",
        "category" => category,
        "electronType" => metric["type"],
        "cpuPercent" => metric["cpuPercent"] || 0,
        "cpuTimeMs" => round((metric["cumulativeCpuSeconds"] || 0) * 1000),
        "residentBytes" => metric["workingSetBytes"] || 0,
        "peakResidentBytes" => metric["peakWorkingSetBytes"] || 0,
        "virtualBytes" => 0,
        "ioReadBytes" => 0,
        "ioWriteBytes" => 0,
        "ioReadBytesPerSecond" => 0,
        "ioWriteBytesPerSecond" => 0,
        "ioSemantics" => "unavailable",
        "idleWakeupsPerSecond" => metric["idleWakeupsPerSecond"] || 0,
        "runTimeMs" => max(at - started, 0),
        "firstSeenAt" => iso(started),
        "lastSeenAt" => iso(at)
      }
      |> then(
        &if(metric["serviceName"],
          do: Map.put(&1, "electronServiceName", metric["serviceName"]),
          else: &1
        )
      )
    end
  end

  defp desktop_health do
    case T3.Desktop.Channel.telemetry() do
      %{"sampledAtUnixMs" => at} ->
        %{"status" => "healthy", "lastSampleAt" => some(iso(at)), "lastError" => none()}

      nil ->
        status = if T3.Desktop.Channel.available?(), do: "starting", else: "unavailable"
        %{"status" => status, "lastSampleAt" => none(), "lastError" => none()}
    end
  end

  defp diagnostics_entry(row) do
    %{
      "pid" => row.pid,
      "startTimeMs" => max(row.started, 0),
      "ppid" => row.ppid,
      "pgid" => if(row.pgid, do: some(row.pgid), else: none()),
      "status" => row.stat,
      "cpuPercent" => row.cpu,
      "rssBytes" => row.rss,
      "elapsed" => row.etime,
      "command" => row.command,
      "depth" => row.depth,
      "childPids" => row.children
    }
  end

  # --- process tree --------------------------------------------------------------

  # Every process under `root`, root first, with its depth and children.
  defp tree(root) do
    ps = ~w(-axo pid=,ppid=,pgid=,stat=,%cpu=,rss=,vsz=,time=,etime=,lstart=,command=)

    case System.cmd("ps", ps, stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {out, 0} ->
        rows = for line <- String.split(out, "\n", trim: true), row = row(line), do: row
        children = Enum.group_by(rows, & &1.ppid)

        case Enum.find(rows, &(&1.pid == root)) do
          nil -> {:error, "The node's own process was not found."}
          row -> {:ok, walk(row, 0, children)}
        end

      {out, _} ->
        {:error, String.trim(out)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp row(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 15) do
      [pid, ppid, pgid, stat, cpu, rss, vsz, time, etime, _day, month, date, clock, year, command] ->
        command = if(command == "", do: "?", else: String.slice(command, 0, 500))

        %{
          pid: String.to_integer(pid),
          ppid: String.to_integer(ppid),
          pgid:
            case Integer.parse(pgid) do
              {pgid, _} -> pgid
              :error -> nil
            end,
          stat: stat,
          cpu: parse_float(cpu),
          rss: String.to_integer(rss) * 1024,
          vsz: String.to_integer(vsz) * 1024,
          cpu_time: cpu_time_ms(time),
          etime: etime,
          command: command,
          name: command |> String.split(" ") |> hd() |> Path.basename(),
          started: started_ms(month, date, clock, year)
        }

      _ ->
        nil
    end
  end

  defp walk(row, depth, children) do
    kids = Map.get(children, row.pid, [])
    row = Map.merge(row, %{depth: depth, children: Enum.map(kids, & &1.pid)})
    [row | Enum.flat_map(kids, &walk(&1, depth + 1, children))]
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # `ps` start time (`lstart`, local time, whole seconds) as unix ms.
  defp started_ms(month, date, clock, year) do
    [hour, minute, second] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    month = Enum.find_index(@months, &(&1 == month)) + 1
    local = {{String.to_integer(year), month, String.to_integer(date)}, {hour, minute, second}}

    case :calendar.local_time_to_universal_time_dst(local) do
      [utc | _] -> (:calendar.datetime_to_gregorian_seconds(utc) - 62_167_219_200) * 1000
      [] -> 0
    end
  rescue
    _ -> 0
  end

  # `ps` cumulative CPU time: `[[dd-]hh:]mm:ss[.cc]`.
  defp cpu_time_ms(time) do
    {days, clock} =
      case String.split(time, "-") do
        [days, clock] -> {String.to_integer(days), clock}
        [clock] -> {0, clock}
      end

    seconds =
      clock
      |> String.split(":")
      |> Enum.map(&parse_float/1)
      |> Enum.reduce(0, &(&2 * 60 + &1))

    round((days * 86_400 + seconds) * 1000)
  rescue
    _ -> 0
  end

  defp parse_float(text) do
    case Float.parse(String.replace(text, ",", ".")) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  # Total and available memory, in bytes.
  defp memory do
    case :os.type() do
      {:unix, :darwin} ->
        page = sysctl("hw.pagesize")
        {out, _} = System.cmd("vm_stat", [])

        pages =
          for name <- ["Pages free", "Pages inactive", "Pages speculative"],
              [_, count] <- [Regex.run(~r/#{name}:\s+(\d+)/, out)],
              do: String.to_integer(count)

        {sysctl("hw.memsize"), Enum.sum(pages) * page}

      _ ->
        info = File.read!("/proc/meminfo")

        kb = fn key ->
          [value] = Regex.run(~r/#{key}:\s+(\d+)/, info, capture: :all_but_first)
          String.to_integer(value) * 1024
        end

        {kb.("MemTotal"), kb.("MemAvailable")}
    end
  rescue
    _ -> {0, 0}
  end

  defp sysctl(key) do
    {out, 0} = System.cmd("sysctl", ["-n", key])
    String.to_integer(String.trim(out))
  end

  defp os_pid, do: String.to_integer(System.pid())

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp some(value), do: %{"_tag" => "Some", "value" => value}
  defp none, do: %{"_tag" => "None"}
end
