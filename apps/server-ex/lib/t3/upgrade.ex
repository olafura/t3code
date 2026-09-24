defmodule T3.Upgrade do
  @moduledoc """
  A node moving to another T3 version (`server.updateServer`), in place when it can.

  A version arrives as a bundle: a release's `lib/`, `releases/<vsn>/` and ERTS,
  with the `upgrade.json` manifest `mix release` writes (`T3.Upgrade.Source` finds
  one). The node compares it with the manifest of the release it runs:

    * Same runtime, applications, native libraries and configuration, and no
      supervisor among the changed modules: the bundle is installed next to the
      running release, code paths move to it, and `T3.Hot` loads the changed
      modules, migrating running processes through `code_change/3`. Nothing
      restarts; sockets and provider sessions stay up.
    * Anything else: the bundle is installed, `releases/start_erl.data` names it,
      and the node exits with status 75, which `bin/t3-service` answers by starting
      it again, now on the new version. Turns cut off go on where the project asks
      for that (`T3.Orchestration.Recovery`).

  Either way the next boot runs the new version. The outcome is kept in
  `<home>/upgrades/outcome.json` and reported with the node's next `ready`, so a
  client that asked can tell success from a rollback. One update runs at a time.
  """

  use GenServer

  require Logger

  @restart_status 75

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The version this node runs, including one loaded in place."
  def version do
    :persistent_term.get({__MODULE__, :version}, nil) || to_string(Application.spec(:t3, :vsn))
  end

  @doc "The release this node runs from, or nil when it runs from a checkout."
  def release_root, do: System.get_env("RELEASE_ROOT")

  @doc "`serverSelfUpdate` for the descriptor: only a release can install a version."
  def capability, do: if(release_root(), do: "hot-upgrade")

  @doc "This machine's bundle platform, e.g. `darwin-arm64`."
  def platform do
    os = :os.type() |> elem(1) |> to_string()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    arch =
      cond do
        arch =~ ~r/aarch64|arm64/ -> "arm64"
        arch =~ ~r/x86_64|amd64/ -> "x64"
        true -> arch
      end

    "#{os}-#{arch}"
  end

  @doc """
  `server.updateServer`: moves this node to `targetVersion`. `progress` gets
  `{:t3_server_update, node, %{"type" => "progress", "stage" => stage}}` as it goes. `{:ok, ServerSelfUpdateResult}` once
  the new version runs (hot) or is about to (restart).
  """
  def update(input, progress \\ nil) do
    GenServer.call(__MODULE__, {:update, input, progress}, :timer.minutes(15))
  catch
    :exit, {:noproc, _} -> failure("This node cannot update itself.")
  end

  @doc """
  `server.updateServerWithProgress`: runs `update/2` off the caller and sends `pid`
  `{:t3_server_update, node, event}` with `ServerSelfUpdateProgressEvent`s, ending
  with `complete`, or `{:error, ServerSelfUpdateError}`.
  """
  def start(input, pid) do
    # Progress comes from this node's updater and the end from this task, both on
    # this node, so they reach `pid` in order.
    Task.start(fn ->
      event =
        case update(input, pid) do
          {:ok, result} -> %{"type" => "complete", "result" => result}
          {:error, error} -> {:error, error}
        end

      send(pid, {:t3_server_update, node(), event})
    end)

    :ok
  end

  @doc """
  Loads what changed in this node's own checkout after `mix compile`, for nodes run
  from source (`mix t3.upgrade --dev`). Supervisors are left alone: they only take
  effect at start, so they are reported to restart for instead.
  """
  def reload_checkout do
    dirs =
      for path <- :code.get_path(),
          path = to_string(path),
          String.contains?(path, "/_build/"),
          do: path

    beams =
      for dir <- dirs,
          file <- Path.wildcard(Path.join(dir, "*.beam")),
          mod = String.to_atom(Path.basename(file, ".beam")),
          :code.is_loaded(mod),
          bin = File.read!(file),
          loaded_md5(mod) != beam_md5(bin),
          do: {mod, bin}

    {restart, hot} = Enum.split_with(beams, &restart_module?/1)

    with {:ok, report} <- T3.Hot.reload(hot) do
      {:ok, Map.put(report, :needs_restart, Enum.map(restart, &elem(&1, 0)))}
    end
  end

  @doc "The outcome of the last update this node finished, for `ready` events."
  def outcome, do: :persistent_term.get({__MODULE__, :outcome}, nil)

  @doc """
  What installing `bundle` would take: `:hot` with the modules that change, or
  `{:restart, reasons}`.
  """
  def plan(bundle, running \\ running_manifest()) do
    target = manifest(bundle)

    reasons =
      [
        running == nil && "the running release has no upgrade manifest",
        target == nil && "the bundle has no upgrade manifest",
        running && target && running["erts"] != target["erts"] && "the Erlang runtime changes",
        running && target && running["otpRelease"] != target["otpRelease"] && "OTP changes",
        running && target &&
          Map.keys(running["applications"] || %{}) != Map.keys(target["applications"] || %{}) &&
          "applications are added or removed",
        running && target && running["nifs"] != target["nifs"] && "native libraries change",
        running && target && running["config"] != target["config"] && "configuration changes"
      ]
      |> Enum.filter(& &1)

    if reasons == [] do
      changed = changed_modules(bundle, target)

      case Enum.filter(changed, &restart_module?(&1)) do
        [] -> {:hot, Enum.map(changed, &elem(&1, 0))}
        supervisors -> {:restart, ["#{inspect(elem(hd(supervisors), 0))} supervises processes"]}
      end
    else
      {:restart, reasons}
    end
  end

  # --- server --------------------------------------------------------------------

  @impl true
  def init(nil) do
    {:ok, nil, {:continue, :outcome}}
  end

  # A restart for an update ends here: the version that booted says how it went.
  @impl true
  def handle_continue(:outcome, state) do
    with {:ok, text} <- File.read(outcome_path()),
         {:ok, %{"status" => "restarting"} = pending} <- JSON.decode(text) do
      booted = version()

      outcome =
        if booted == pending["targetVersion"],
          do: Map.merge(pending, %{"status" => "committed"}),
          else:
            Map.merge(pending, %{
              "status" => "rolled-back",
              "reason" => "The node started #{booted} instead of #{pending["targetVersion"]}."
            })

      record(outcome)
    else
      {:ok, %{} = done} -> :persistent_term.put({__MODULE__, :outcome}, done)
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:update, input, progress}, _from, state) do
    {:reply, run(input, progress), state}
  end

  defp run(%{"targetVersion" => target}, progress) do
    from = version()
    root = release_root()
    id = "hot-upgrade-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    cond do
      root == nil ->
        failure("This node runs from a checkout; update it with `mix t3.upgrade`.")

      target == from ->
        failure("This node already runs #{target}.")

      true ->
        notify(progress, "downloading")

        with {:ok, bundle} <- T3.Upgrade.Source.fetch(target, platform()) do
          notify(progress, "installing")
          outcome = %{"id" => id, "fromVersion" => from, "targetVersion" => target}
          result = %{"targetVersion" => target, "method" => "hot-upgrade", "updateId" => id}

          case install(bundle, root, target) do
            :ok -> activate(plan(bundle), bundle, root, target, outcome, result)
            {:error, reason} -> failure("Installing #{target} failed: #{reason}")
          end
        end
    end
  end

  defp run(_input, _progress), do: failure("No target version was given.")

  defp activate({:hot, modules}, bundle, root, target, outcome, result) do
    case load(bundle, root, target, modules) do
      :ok ->
        set_start_version(root, target)
        :persistent_term.put({__MODULE__, :version}, target)
        record(Map.put(outcome, "status", "committed"))
        announce()
        Logger.info("upgraded in place to #{target} (#{length(modules)} modules)")
        {:ok, result}

      {:error, reason} ->
        # Whatever loaded stays; the next start runs the new version fully.
        restart(root, target, outcome, result, "loading in place failed: #{inspect(reason)}")
    end
  end

  defp activate({:restart, reasons}, _bundle, root, target, outcome, result),
    do: restart(root, target, outcome, result, Enum.join(reasons, "; "))

  defp restart(root, target, outcome, result, why) do
    if System.get_env("T3_SERVICE") == "1" do
      set_start_version(root, target)
      record(Map.put(outcome, "status", "restarting"))
      Logger.info("restarting into #{target}: #{why}")
      # After the reply has gone out.
      spawn(fn ->
        Process.sleep(500)
        System.stop(@restart_status)
      end)

      {:ok, result}
    else
      failure(
        "#{target} needs a restart (#{why}), and this node was not started by bin/t3-service, which would start it again."
      )
    end
  end

  # --- install ---------------------------------------------------------------------

  @doc false
  def install(bundle, root, target) do
    with true <-
           File.dir?(Path.join([bundle, "releases", target])) ||
             {:error, "the bundle is not #{target}"},
         :ok <- copy_new(bundle, root, "lib"),
         :ok <- copy_new(bundle, root, "releases"),
         :ok <- copy_new(bundle, root, "."),
         :ok <- copy_bin(bundle, root) do
      :ok
    end
  end

  # A versioned directory the running release already has is kept when it matches
  # the bundle's (the running version's own directories always do); a missing or
  # different one, such as a build's leftover, is replaced.
  defp copy_new(bundle, root, "." = _dir) do
    for erts <- Path.wildcard(Path.join(bundle, "erts-*")),
        do: replace_unless_same(erts, Path.join(root, Path.basename(erts)))

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp copy_new(bundle, root, dir) do
    for entry <- File.ls!(Path.join(bundle, dir)),
        source = Path.join([bundle, dir, entry]),
        File.dir?(source),
        do: replace_unless_same(source, Path.join([root, dir, entry]))

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp replace_unless_same(source, target) do
    unless same_dir?(source, target) do
      staged = target <> ".partial"
      File.rm_rf!(staged)
      File.cp_r!(source, staged)

      if File.exists?(target) do
        aside = "#{target}.replaced-#{System.system_time(:millisecond)}"
        File.rename!(target, aside)
        File.rename!(staged, target)
        File.rm_rf!(aside)
      else
        File.rename!(staged, target)
      end
    end
  end

  # Compared by what identifies the directory's contents: an application's `.app`,
  # a release's boot script and manifest, ERTS's emulator.
  defp same_dir?(source, target) do
    markers =
      Path.wildcard(Path.join(source, "ebin/*.app")) ++
        Enum.filter(
          Enum.map(~w(start.boot upgrade.json bin/beam.smp), &Path.join(source, &1)),
          &File.exists?/1
        )

    File.dir?(target) and markers != [] and
      Enum.all?(markers, fn marker ->
        File.read(Path.join(target, Path.relative_to(marker, source))) == File.read(marker)
      end)
  end

  defp copy_bin(bundle, root) do
    for file <- Path.wildcard(Path.join([bundle, "bin", "*"])) do
      target = Path.join([root, "bin", Path.basename(file)])
      File.cp!(file, target <> ".new")
      File.rename!(target <> ".new", target)
    end

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp set_start_version(root, target) do
    path = Path.join([root, "releases", "start_erl.data"])
    [erts | _] = path |> File.read!() |> String.split()
    erts = (manifest_of(root, target) || %{})["erts"] || erts
    File.write!(path <> ".new", "#{erts} #{target}\n")
    File.rename!(path <> ".new", path)
  end

  # --- load in place -----------------------------------------------------------------

  # Code paths move to the new release's directories, so modules loaded later come
  # from it too, then the changed modules load and running processes migrate.
  defp load(bundle, root, target, modules) do
    for {app, vsn} <- (manifest(bundle) || %{})["applications"] || %{} do
      ebin = Path.join([root, "lib", "#{app}-#{vsn}", "ebin"])
      if File.dir?(ebin), do: :code.replace_path(String.to_atom(app), String.to_charlist(ebin))
    end

    consolidated = Path.join([root, "releases", target, "consolidated"])

    for path <- :code.get_path(),
        path = to_string(path),
        String.ends_with?(path, "/consolidated") and path != consolidated,
        do: :code.del_path(String.to_charlist(path))

    if File.dir?(consolidated), do: :code.add_patha(String.to_charlist(consolidated))

    wanted = MapSet.new(modules)
    beams = for {mod, _} = beam <- beams(bundle), MapSet.member?(wanted, mod), do: beam

    case T3.Hot.reload(beams) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- manifests and modules -------------------------------------------------------------

  defp running_manifest do
    with root when is_binary(root) <- release_root(), do: manifest_of(root, version())
  end

  defp manifest_of(root, vsn) do
    with {:ok, text} <- File.read(Path.join([root, "releases", vsn, "upgrade.json"])),
         {:ok, manifest} <- JSON.decode(text),
         do: manifest,
         else: (_ -> nil)
  end

  @doc false
  def manifest(bundle) do
    case Path.wildcard(Path.join([bundle, "releases", "*", "upgrade.json"])) do
      [path | _] ->
        with {:ok, text} <- File.read(path),
             {:ok, manifest} <- JSON.decode(text),
             do: manifest,
             else: (_ -> nil)

      [] ->
        nil
    end
  end

  # Every compiled module in the bundle's applications and protocol consolidation.
  defp beams(bundle) do
    for dir <-
          Path.wildcard(Path.join([bundle, "lib", "*", "ebin"])) ++
            Path.wildcard(Path.join([bundle, "releases", "*", "consolidated"])),
        file <- Path.wildcard(Path.join(dir, "*.beam")) do
      {String.to_atom(Path.basename(file, ".beam")), File.read!(file)}
    end
  end

  defp changed_modules(bundle, _target) do
    for {mod, bin} = beam <- beams(bundle),
        loaded_md5(mod) != nil,
        loaded_md5(mod) != beam_md5(bin),
        do: beam
  end

  # Supervisors, and the application that lists the tree, only take effect at start.
  defp restart_module?({T3.Application, _bin}), do: true

  defp restart_module?({_mod, bin}) do
    case :beam_lib.chunks(bin, [:attributes]) do
      {:ok, {_, [attributes: attributes]}} ->
        behaviours = Keyword.get_values(attributes, :behaviour) |> List.flatten()
        :supervisor in behaviours or Supervisor in behaviours

      _ ->
        false
    end
  end

  defp loaded_md5(mod), do: if(:code.is_loaded(mod), do: mod.module_info(:md5))

  defp beam_md5(bin) do
    {:ok, {_mod, md5}} = :beam_lib.md5(bin)
    md5
  end

  # --- outcome -----------------------------------------------------------------------

  defp record(outcome) do
    File.mkdir_p!(Path.dirname(outcome_path()))
    File.write!(outcome_path(), JSON.encode!(outcome))

    if outcome["status"] != "restarting",
      do: :persistent_term.put({__MODULE__, :outcome}, outcome)
  end

  # Clients watching this node's config see its new descriptor and the outcome.
  defp announce, do: T3.Settings.notify_upgraded(outcome())

  defp outcome_path,
    do: Path.join([Application.fetch_env!(:t3, :home), "upgrades", "outcome.json"])

  defp notify(nil, _stage), do: :ok

  defp notify(pid, stage),
    do: send(pid, {:t3_server_update, node(), %{"type" => "progress", "stage" => stage}})

  defp failure(reason), do: {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}}
end
