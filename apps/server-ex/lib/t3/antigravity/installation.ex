defmodule T3.Antigravity.Installation do
  @moduledoc """
  The Antigravity runtime this node manages (`provider.install.*`), and finding the
  runtime an instance runs: a custom `binaryPath`, else the managed install, else
  `agy_acp_server.par` on `PATH`. Every runtime is the executable plus its
  `localharness_external` sibling.

  The managed install lives in `<home>/tools/antigravity-acp/<platform>/`:
  `versions/<sha256>/` holds a release with its `.install-complete.json` record, and
  `active.json` names the release in use. Installing downloads the pinned archive
  (`T3.Antigravity.Release`) into a `versions/.install-*` staging directory,
  checking its size and SHA-256 as it streams, extracts exactly the two expected
  files, starts the executable once to check it identifies as the expected
  release, then publishes it and switches `active.json` over. A cancelled or failed
  install leaves the previous release in use.

  One process holds the install's `ProviderInstallState` and sends it to
  subscribers as `{:t3_provider_install, instance, state}` on every change. Running
  agents hold a lease (`lease/2`) on their managed release, so it cannot be removed
  under them.
  """

  use GenServer

  require Logger

  alias T3.Antigravity.{Files, Profile, Release}

  @download_timeout :timer.minutes(45)
  @validation_timeout 90_000
  @free_space_margin 256 * 1024 * 1024
  @record_max_bytes 8 * 1024
  @record ".install-complete.json"
  @release_id ~r/^[a-f0-9]{64}$/

  # --- API -------------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The current `ProviderInstallState`."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Starts installing the pinned release (a running install is returned as is)."
  def start, do: GenServer.call(__MODULE__, :start)

  @doc "Cancels the install `operation_id`, which must be the current one."
  def cancel(operation_id), do: GenServer.call(__MODULE__, {:cancel, operation_id})

  @doc """
  Removes the managed runtime, unless it is installing or in use, or a configured
  `binaryPath` (in `protected`) points inside it.
  """
  def remove(protected \\ []), do: GenServer.call(__MODULE__, {:remove, protected}, 60_000)

  @doc "Adds `pid` as a subscriber for `instance`; `{:ok, state}`."
  def subscribe(instance, pid), do: GenServer.call(__MODULE__, {:subscribe, instance, pid})

  def unsubscribe(instance, pid), do: GenServer.cast(__MODULE__, {:unsubscribe, instance, pid})

  @doc """
  Keeps `executable`'s managed release from being removed while `pid` lives. A
  runtime found elsewhere needs no lease.
  """
  def lease(pid, %{dir: dir}) when is_binary(dir) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:lease, pid, dir}), else: :ok
  end

  def lease(_pid, _executable), do: :ok

  @doc "The managed install's directory for this machine."
  def managed_dir,
    do:
      Path.join([
        Application.fetch_env!(:t3, :home),
        "tools",
        "antigravity-acp",
        Release.platform()
      ])

  defp versions_dir, do: Path.join(managed_dir(), "versions")
  defp active_path, do: Path.join(managed_dir(), "active.json")

  # --- resolving -------------------------------------------------------------------

  @doc """
  The runtime to start: `{:ok, %{path, harness, source, version, dir}}` where
  `source` is `"override"`, `"managed"` or `"path"`, `version` is known for managed
  releases, and `dir` is the managed release directory (for leases). `path_env` is
  the `PATH` to search.
  """
  def resolve(binary_path \\ nil, path_env \\ System.get_env("PATH")) do
    {executable, _harness} = Release.names()

    case String.trim(binary_path || "") do
      "" ->
        cond do
          File.exists?(active_path()) ->
            with {:ok, %{"releaseId" => id}} <- read_record(active_path()),
                 true <- is_binary(id) and Regex.match?(@release_id, id) do
              completed_release(id)
            else
              {:error, _} = error -> error
              _ -> {:error, "The managed runtime record is invalid. Reinstall Antigravity."}
            end

          found = Enum.find_value(path_candidates(executable, path_env), &external(&1, "path")) ->
            {:ok, found}

          Release.asset() ->
            {:error,
             "Antigravity is not installed. Install it in this environment or set a custom executable path."}

          true ->
            {:error,
             "Google does not publish an Antigravity runtime for #{Release.platform()}. Use a supported environment or a custom executable."}
        end

      override ->
        candidates =
          if String.contains?(override, ["/", "\\"]),
            do: [Path.expand(override)],
            else: path_candidates(override, path_env)

        case Enum.find_value(candidates, &external(&1, "override")) do
          nil ->
            {:error,
             "The custom Antigravity executable or its localharness_external sibling is missing or not executable."}

          found ->
            {:ok, found}
        end
    end
  end

  defp path_candidates(name, path_env) do
    for dir <- String.split(path_env || "", ":", trim: true),
        dir = dir |> String.trim() |> String.trim("\""),
        dir != "",
        do: Path.expand(name, dir)
  end

  # A runtime outside the managed install; inside it, the release's record decides.
  defp external(candidate, source) do
    {_executable, harness_name} = Release.names()

    with true <- executable_file?(candidate),
         {:ok, real} <- Files.realpath(candidate),
         dir = Path.dirname(real),
         harness = Path.join(dir, harness_name),
         true <- executable_file?(harness) do
      managed =
        with {:ok, versions} <- Files.realpath(versions_dir()),
             true <- Path.dirname(dir) == versions,
             true <- Regex.match?(@release_id, Path.basename(dir)),
             {:ok, release} <- completed_release(Path.basename(dir)) do
          release
        else
          _ -> nil
        end

      Map.merge(managed || %{version: nil, dir: nil}, %{
        path: real,
        harness: harness,
        source: source
      })
    else
      _ -> nil
    end
  end

  defp executable_file?(path, bytes \\ nil) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} ->
        (bytes == nil or size == bytes) and Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp read_record(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @record_max_bytes <-
           File.stat(path),
         {:ok, text} <- File.read(path),
         {:ok, %{} = record} <- JSON.decode(text) do
      {:ok, record}
    else
      _ -> {:error, "The managed runtime record is invalid. Reinstall Antigravity."}
    end
  end

  defp completed_release(id) do
    {executable, harness} = Release.names()
    dir = Path.join(versions_dir(), id)

    with {:ok, record} <- read_record(Path.join(dir, @record)),
         %{
           "releaseId" => ^id,
           "version" => version,
           "executable" => %{"name" => ^executable, "bytes" => exe_bytes},
           "harness" => %{"name" => ^harness, "bytes" => harness_bytes}
         }
         when is_binary(version) and is_integer(exe_bytes) and exe_bytes > 0 and
                is_integer(harness_bytes) and harness_bytes > 0 <- record,
         true <- String.trim(version) != "",
         true <- executable_file?(Path.join(dir, executable), exe_bytes),
         true <- executable_file?(Path.join(dir, harness), harness_bytes) do
      {:ok,
       %{
         path: Path.join(dir, executable),
         harness: Path.join(dir, harness),
         source: "managed",
         version: version,
         dir: dir
       }}
    else
      _ -> {:error, "The managed Antigravity runtime is incomplete. Reinstall it."}
    end
  end

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(nil) do
    asset = Release.asset()
    # Staging left by a node that stopped mid-install.
    for dir <- Path.wildcard(Path.join(versions_dir(), ".install-*"), match_dot: true),
        do: File.rm_rf(dir)

    state = %{
      "driver" => "antigravity",
      "operationId" => nil,
      "phase" => "idle",
      "downloadedBytes" => 0,
      "totalBytes" => asset && asset.archive_bytes,
      "version" => asset && asset.version,
      "installedVersion" => nil,
      "canRemove" => File.exists?(managed_dir()),
      "message" => nil
    }

    state =
      if File.exists?(active_path()) do
        case resolve() do
          {:ok, %{source: "managed", version: version}} ->
            Map.put(state, "installedVersion", version)

          _ ->
            Map.merge(state, %{
              "phase" => "failed",
              "message" =>
                "The managed Antigravity runtime is incomplete. Remove it and reinstall."
            })
        end
      else
        state
      end

    {:ok, %{install: state, asset: asset, running: nil, leases: %{}, subscribers: %{}}}
  end

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s.install, s}

  def handle_call({:subscribe, instance, pid}, _from, s) do
    subscribers =
      Map.update(s.subscribers, pid, {Process.monitor(pid), MapSet.new([instance])}, fn {ref, set} ->
        {ref, MapSet.put(set, instance)}
      end)

    {:reply, {:ok, s.install}, %{s | subscribers: subscribers}}
  end

  def handle_call({:lease, pid, dir}, _from, s) do
    {:reply, :ok, %{s | leases: Map.put(s.leases, Process.monitor(pid), dir)}}
  end

  def handle_call(:start, _from, %{running: %{}} = s), do: {:reply, {:ok, s.install}, s}

  def handle_call(:start, _from, %{asset: nil} = s) do
    {:reply,
     error(
       "start",
       "Google does not publish an Antigravity runtime for #{Release.platform()}. Use a supported remote environment or a custom executable."
     ), s}
  end

  def handle_call(:start, _from, s) do
    operation = T3.Environment.uuid4()
    server = self()
    asset = s.asset

    {pid, ref} =
      spawn_monitor(fn -> send(server, {:done, operation, install(asset, server, operation)}) end)

    s =
      publish(%{s | running: %{operation: operation, pid: pid, ref: ref}}, %{
        "operationId" => operation,
        "phase" => "downloading",
        "downloadedBytes" => 0,
        "totalBytes" => asset.archive_bytes,
        "version" => asset.version,
        "message" => "Downloading Google's official Antigravity runtime."
      })

    {:reply, {:ok, s.install}, s}
  end

  def handle_call({:cancel, operation}, _from, s) do
    cond do
      s.install["operationId"] != operation ->
        {:reply,
         error(
           "cancel",
           "This installation is no longer current. Refresh its status before cancelling."
         ), s}

      match?(%{operation: ^operation}, s.running) ->
        Process.demonitor(s.running.ref, [:flush])
        Process.exit(s.running.pid, :kill)
        s = finish(s, "cancelled", "Installation cancelled. The previous runtime is unchanged.")
        {:reply, {:ok, s.install}, s}

      true ->
        {:reply, {:ok, s.install}, s}
    end
  end

  def handle_call({:remove, protected}, _from, s) do
    cond do
      s.running != nil or map_size(s.leases) > 0 ->
        {:reply,
         error(
           "remove",
           "Stop Antigravity sessions and sign-in flows before removing its managed runtime."
         ), s}

      protects?(protected) ->
        {:reply,
         error(
           "remove",
           "A provider instance has a custom path inside this managed runtime. Clear that path before removing it."
         ), s}

      true ->
        case File.rm_rf(managed_dir()) do
          {:ok, _} ->
            s =
              publish(s, %{
                "operationId" => nil,
                "phase" => "idle",
                "downloadedBytes" => 0,
                "installedVersion" => nil,
                "canRemove" => false,
                "message" => nil
              })

            {:reply, :ok, s}

          {:error, _, _} ->
            {:reply,
             error(
               "remove",
               "Could not remove the managed Antigravity runtime. Check for open processes and try again."
             ), s}
        end
    end
  end

  defp protects?(paths) do
    case Files.realpath(managed_dir()) do
      {:ok, managed} ->
        Enum.any?(paths, fn path ->
          path = String.trim(path || "")

          path != "" and
            (match?({:ok, %{dir: dir}} when is_binary(dir), resolve(path)) or
               Files.inside?(
                 case Files.realpath(path) do
                   {:ok, real} -> real
                   _ -> Path.expand(path)
                 end,
                 managed
               ))
        end)

      _ ->
        false
    end
  end

  @impl true
  def handle_cast({:unsubscribe, instance, pid}, s) do
    subscribers =
      case s.subscribers[pid] do
        nil ->
          s.subscribers

        {ref, set} ->
          set = MapSet.delete(set, instance)

          if MapSet.size(set) == 0 do
            Process.demonitor(ref, [:flush])
            Map.delete(s.subscribers, pid)
          else
            Map.put(s.subscribers, pid, {ref, set})
          end
      end

    {:noreply, %{s | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:progress, operation, patch}, %{running: %{operation: operation}} = s),
    do: {:noreply, publish(s, patch)}

  def handle_info({:done, operation, result}, %{running: %{operation: operation} = running} = s) do
    Process.demonitor(running.ref, [:flush])
    sweep_staging()

    s =
      case result do
        {:ok, version} ->
          T3.Settings.notify_providers()

          publish(%{s | running: nil}, %{
            "phase" => "succeeded",
            "installedVersion" => version,
            "message" => nil
          })

        {:error, message} ->
          finish(s, "failed", message)
      end

    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = s) do
    Logger.warning("Antigravity install stopped: #{inspect(reason)}")

    {:noreply,
     finish(
       s,
       "failed",
       "Could not finish the Antigravity installation. Check disk space and directory access."
     )}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case Map.pop(s.leases, ref) do
      {nil, _} ->
        {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}

      {_dir, leases} ->
        {:noreply, %{s | leases: leases}}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  defp finish(s, phase, message) do
    sweep_staging()
    publish(%{s | running: nil}, %{"phase" => phase, "message" => message})
  end

  defp sweep_staging do
    for dir <- Path.wildcard(Path.join(versions_dir(), ".install-*"), match_dot: true),
        do: File.rm_rf(dir)
  end

  defp publish(s, patch) do
    install = Map.merge(s.install, patch)

    for {pid, {_ref, instances}} <- s.subscribers,
        instance <- instances,
        do: send(pid, {:t3_provider_install, instance, install})

    %{s | install: install}
  end

  defp error(operation, detail), do: {:error, %{operation: operation, detail: detail}}

  # --- installing (in the worker) --------------------------------------------------

  defp install(asset, server, operation) do
    report = fn patch -> send(server, {:progress, operation, patch}) end
    {exe_name, exe_bytes} = asset.executable
    {harness_name, harness_bytes} = asset.harness
    destination = Path.join(versions_dir(), asset.sha256)

    with :ok <- mkdir(versions_dir()),
         _ = report.(%{"canRemove" => true}) do
      if File.exists?(destination) do
        with {:ok, existing} <- completed_release(asset.sha256),
             :ok <- same_version(existing, asset),
             _ =
               report.(%{"phase" => "verifying", "message" => "Checking the installed runtime."}),
             :ok <- validate(existing, asset.version),
             :ok <- activate(asset.sha256),
             do: {:ok, asset.version}
      else
        staging = Path.join(versions_dir(), ".install-#{System.unique_integer([:positive])}")
        archive = Path.join(staging, "download.zip")
        runtime = Path.join(staging, "runtime")

        try do
          with :ok <- free_space(asset),
               :ok <- mkdir(runtime),
               :ok <- download(asset, archive, report),
               _ =
                 report.(%{
                   "phase" => "extracting",
                   "message" => "Extracting the verified runtime."
                 }),
               :ok <- extract(archive, runtime, asset),
               _ = File.rm(archive),
               :ok <- File.chmod(Path.join(runtime, exe_name), 0o755),
               :ok <- File.chmod(Path.join(runtime, harness_name), 0o755),
               _ =
                 report.(%{
                   "phase" => "verifying",
                   "message" => "Checking the downloaded runtime."
                 }),
               :ok <-
                 validate(
                   %{
                     path: Path.join(runtime, exe_name),
                     harness: Path.join(runtime, harness_name)
                   },
                   asset.version
                 ),
               :ok <-
                 File.write(
                   Path.join(runtime, @record),
                   JSON.encode!(%{
                     "releaseId" => asset.sha256,
                     "version" => asset.version,
                     "executable" => %{"name" => exe_name, "bytes" => exe_bytes},
                     "harness" => %{"name" => harness_name, "bytes" => harness_bytes}
                   })
                 ),
               :ok <- publish_release(runtime, destination, asset),
               :ok <- activate(asset.sha256) do
            {:ok, asset.version}
          else
            {:error, message} when is_binary(message) ->
              {:error, message}

            other ->
              Logger.warning("Antigravity install failed: #{inspect(other)}")

              {:error,
               "Could not install Antigravity. Check free disk space and directory access, then try again."}
          end
        after
          File.rm_rf(staging)
        end
      end
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      _ ->
        {:error,
         "Could not install Antigravity. Check free disk space and directory access, then try again."}
    end
  end

  defp same_version(%{version: version}, %{version: version}), do: :ok

  defp same_version(_, _),
    do:
      {:error,
       "The existing managed release has the wrong version. Remove it before reinstalling."}

  defp publish_release(runtime, destination, asset) do
    case File.rename(runtime, destination) do
      :ok ->
        :ok

      {:error, _} ->
        # Another install got there first; keep it if it is this release.
        with {:ok, existing} <- completed_release(asset.sha256),
             :ok <- same_version(existing, asset),
             :ok <- validate(existing, asset.version) do
          :ok
        else
          _ ->
            {:error,
             "Could not publish the Antigravity runtime. The previous release is unchanged. Try again."}
        end
    end
  end

  # The pointer commits the install.
  defp activate(release_id) do
    tmp = Path.join(managed_dir(), "active.json.#{System.unique_integer([:positive])}")

    with :ok <- File.write(tmp, JSON.encode!(%{"releaseId" => release_id})),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, active_path()) do
      :ok
    else
      _ ->
        File.rm(tmp)

        {:error,
         "Could not activate Antigravity. The previous runtime is unchanged. Check for locked files and try again."}
    end
  end

  defp free_space(asset) do
    {_, exe} = asset.executable
    {_, harness} = asset.harness
    required = asset.archive_bytes + exe + harness + @free_space_margin

    case System.cmd("df", ["-Pk", versions_dir()], stderr_to_stdout: true) do
      {out, 0} ->
        with [_header, line | _] <- String.split(out, "\n", trim: true),
             [_fs, _size, _used, available | _] <- String.split(line),
             {kib, ""} <- Integer.parse(available),
             true <- kib * 1024 < required do
          {:error,
           "Antigravity needs at least #{div(required + 1_048_575, 1_048_576)} MiB of free space to install."}
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Streams the archive to disk, hashing and counting as it goes.
  defp download(asset, path, report) do
    {:ok, file} = File.open(path, [:write, :binary, :exclusive])

    progress = fn bytes, acc ->
      now = System.monotonic_time(:millisecond)

      if now - acc.at >= 250 or bytes == asset.archive_bytes do
        report.(%{"downloadedBytes" => bytes})
        %{acc | at: now}
      else
        acc
      end
    end

    acc = %{hash: :crypto.hash_init(:sha256), bytes: 0, at: 0}

    write = fn chunk, acc ->
      bytes = acc.bytes + byte_size(chunk)

      if bytes > asset.archive_bytes do
        {:error, "The Antigravity download exceeded the pinned release size."}
      else
        :ok = IO.binwrite(file, chunk)
        {:ok, progress.(bytes, %{acc | hash: :crypto.hash_update(acc.hash, chunk), bytes: bytes})}
      end
    end

    result =
      try do
        case URI.parse(asset.url) do
          %URI{scheme: "file", path: source} -> read_file(source, acc, write)
          _ -> fetch(asset, acc, write)
        end
      after
        File.close(file)
      end

    with {:ok, acc} <- result do
      digest = acc.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

      if acc.bytes == asset.archive_bytes and digest == asset.sha256,
        do: :ok,
        else:
          {:error,
           "The Antigravity download failed its size or SHA-256 check. Nothing was installed."}
    end
  end

  # A local mirror (and tests).
  defp read_file(source, acc, write) do
    File.open!(source, [:read, :binary], fn io ->
      Stream.repeatedly(fn -> IO.binread(io, 1_048_576) end)
      |> Enum.reduce_while({:ok, acc}, fn
        data, {:ok, acc} when is_binary(data) ->
          case write.(data, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            error -> {:halt, error}
          end

        _eof, result ->
          {:halt, result}
      end)
    end)
  end

  defp fetch(asset, acc, write) do
    request = {String.to_charlist(asset.url), [{~c"user-agent", ~c"t3code"}]}

    options = [
      timeout: @download_timeout,
      connect_timeout: 15_000,
      autoredirect: true,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, request, options,
           sync: false,
           stream: {:self, :once},
           body_format: :binary
         ) do
      {:ok, ref} -> receive_body(ref, nil, asset, acc, write)
      _ -> {:error, "The Antigravity runtime could not be downloaded."}
    end
  end

  defp receive_body(ref, pid, asset, acc, write) do
    receive do
      {:http, {^ref, :stream_start, headers, pid}} ->
        headers = Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
        encoding = headers |> Map.get("content-encoding", "identity") |> String.downcase()
        length = headers["content-length"]

        if encoding == "identity" and length != nil and
             String.to_integer(String.trim(length)) != asset.archive_bytes do
          :httpc.cancel_request(ref)
          {:error, "The Antigravity download size did not match the pinned release."}
        else
          :httpc.stream_next(pid)
          receive_body(ref, pid, asset, acc, write)
        end

      {:http, {^ref, :stream, chunk}} ->
        case write.(chunk, acc) do
          {:ok, acc} ->
            :httpc.stream_next(pid)
            receive_body(ref, pid, asset, acc, write)

          error ->
            :httpc.cancel_request(ref)
            error
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, acc}

      {:http, {^ref, _other}} ->
        {:error, "The Antigravity runtime could not be downloaded."}
    after
      @download_timeout ->
        :httpc.cancel_request(ref)
        {:error, "The Antigravity download timed out."}
    end
  end

  # Exactly the executable and its harness, flat, regular, and at their pinned sizes.
  defp extract(archive, dir, asset) do
    expected = Map.new([asset.executable, asset.harness])
    unsafe = {:error, "The archive contains an unexpected, unsafe, or incorrectly sized member."}

    with {:ok, [_comment | entries]} <- :zip.list_dir(String.to_charlist(archive)),
         {:count, 2} <- {:count, length(entries)},
         names = for({:zip_file, name, _, _, _, _} <- entries, do: to_string(name)),
         true <- Enum.sort(names) == Enum.sort(Map.keys(expected)) || unsafe,
         true <-
           Enum.all?(entries, fn {:zip_file, name, info, _, _, _} ->
             elem(info, 1) == expected[to_string(name)] and elem(info, 2) == :regular
           end) || unsafe,
         {:ok, _} <-
           :zip.extract(String.to_charlist(archive),
             cwd: String.to_charlist(dir),
             file_list: Enum.map(names, &String.to_charlist/1)
           ),
         true <-
           Enum.all?(expected, fn {name, bytes} ->
             match?(
               {:ok, %File.Stat{type: :regular, size: ^bytes}},
               File.lstat(Path.join(dir, name))
             )
           end) || {:error, "An archive member was truncated."} do
      :ok
    else
      {:count, _} ->
        {:error, "The archive must contain exactly the Antigravity executable and its harness."}

      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, "The Antigravity archive could not be extracted."}
    end
  end

  # Starts the runtime once in a throwaway profile: it must be the pinned release.
  defp validate(executable, version) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "t3-antigravity-validate-#{System.unique_integer([:positive])}"
      )

    config = %{
      "authMethod" => "oauth-personal",
      "apiKey" => "",
      "gcpProject" => "",
      "gcpLocation" => ""
    }

    try do
      with {:ok, profile} <- Profile.prepare_dir(tmp, config),
           {argv, env} = Profile.command(executable, profile, config),
           {:ok, conn} <-
             T3.JsonRpc.Connection.start_link(
               cmd: argv,
               handler: self(),
               cd: tmp,
               env: env,
               dialect: :v2
             ) do
        try do
          case T3.JsonRpc.Connection.call(
                 conn,
                 "initialize",
                 initialize_params(),
                 @validation_timeout
               ) do
            {:ok, init} ->
              if expected?(init, version),
                do: :ok,
                else:
                  {:error,
                   "The downloaded runtime did not identify as the expected Google Antigravity release."}

            _ ->
              {:error, "The downloaded Antigravity runtime could not start in this environment."}
          end
        after
          T3.JsonRpc.Connection.stop(conn)
        end
      else
        {:error, message} when is_binary(message) -> {:error, message}
        _ -> {:error, "The downloaded Antigravity runtime could not start in this environment."}
      end
    catch
      :exit, _ ->
        {:error, "The downloaded Antigravity runtime could not start in this environment."}
    after
      File.rm_rf(tmp)
    end
  end

  defp initialize_params do
    %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      "clientInfo" => %{"name" => "t3-code", "version" => "0.0.0"}
    }
  end

  # Antigravity 1.1.1 reports protocol 2 with the version 1 wire shapes.
  defp expected?(init, version) do
    caps = init["agentCapabilities"] || %{}

    get_in(init, ["agentInfo", "name"]) == "antigravity-acp" and
      get_in(init, ["agentInfo", "version"]) == version and
      init["protocolVersion"] in [1, 2] and caps["loadSession"] == true and
      is_map(get_in(caps, ["sessionCapabilities", "resume"])) and
      is_map(get_in(caps, ["auth", "logout"])) and
      Enum.any?(init["authMethods"] || [], &(&1["id"] == "oauth-personal"))
  end
end
