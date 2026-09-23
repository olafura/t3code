defmodule T3.Hot do
  @moduledoc """
  Live code reload without a release upgrade.

  `reload/2` takes compiled modules, skips the ones whose md5 matches what is loaded,
  suspends every OTP process whose callback module changed, loads the new code, runs
  each process's `code_change/3`, and resumes them. Plain processes (reader loops,
  tasks) move to new code on their next fully qualified call.

  Old code is soft-purged afterwards. A module still referenced by a process that is
  blocked inside old code is reported as `lingering` and can be purged later; it is
  never force-purged, because that would kill the process.

  This cannot change the supervision tree, NIFs, or OTP itself; those need a restart.
  """

  require Logger

  @type beam :: {module, binary}
  @type report :: %{changed: [module], migrated: [pid], lingering: [module]}

  @suspend_timeout 5_000

  @doc "Reads every `.beam` file in `dir`."
  @spec beams_from_dir(Path.t()) :: [beam]
  def beams_from_dir(dir) do
    for file <- Path.wildcard(Path.join(dir, "*.beam")) do
      {String.to_atom(Path.basename(file, ".beam")), File.read!(file)}
    end
  end

  @doc "Reloads `beams` on this node and every connected node."
  @spec reload_cluster([beam], timeout) :: [{node, {:ok, report} | {:error, term}}]
  def reload_cluster(beams, timeout \\ 30_000) do
    nodes = [node() | Node.list()]

    nodes
    |> :erpc.multicall(__MODULE__, :reload, [beams], timeout)
    |> Enum.zip(nodes)
    |> Enum.map(fn
      {{:ok, result}, node} -> {node, result}
      {{kind, reason}, node} -> {node, {:error, {kind, reason}}}
    end)
  end

  @spec reload([beam], keyword) :: {:ok, report} | {:error, term}
  def reload(beams, opts \\ []) do
    changed = Enum.reject(beams, fn {mod, bin} -> loaded_md5(mod) == beam_md5(bin) end)
    mods = Enum.map(changed, &elem(&1, 0))
    old_vsns = Map.new(mods, &{&1, loaded_vsn(&1)})

    case purge_old(mods) do
      [] ->
        procs =
          mods
          |> processes_using()
          |> suspend(Keyword.get(opts, :suspend_timeout, @suspend_timeout))

        try do
          Enum.each(changed, &load/1)
          for {pid, mod} <- procs, do: :ok = :sys.change_code(pid, mod, old_vsns[mod], :hot)

          {:ok,
           %{changed: mods, migrated: Enum.map(procs, &elem(&1, 0)), lingering: purge_old(mods)}}
        after
          Enum.each(procs, fn {pid, _} -> :sys.resume(pid) end)
        end

      busy ->
        {:error, {:previous_version_still_running, busy}}
    end
  end

  defp load({mod, bin}) do
    {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", bin)
  end

  # A module can hold at most one old version, so the previous reload's leftovers must
  # be gone before loading again. Returns the modules that could not be purged.
  defp purge_old(mods), do: Enum.reject(mods, &:code.soft_purge/1)

  defp processes_using(mods) do
    set = MapSet.new(mods)

    for pid <- Process.list(),
        pid != self(),
        {mod, _, _} <- [callback_module(pid)],
        MapSet.member?(set, mod),
        do: {pid, mod}
  end

  defp callback_module(pid) do
    case :proc_lib.translate_initial_call(pid) do
      {mod, _, _} = mfa when is_atom(mod) -> mfa
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp suspend(procs, timeout) do
    Enum.filter(procs, fn {pid, mod} ->
      try do
        :sys.suspend(pid, timeout)
        true
      catch
        :exit, reason ->
          Logger.warning(
            "hot reload skipped #{inspect(pid)} (#{inspect(mod)}): #{inspect(reason)}"
          )

          false
      end
    end)
  end

  defp loaded_md5(mod) do
    if :code.is_loaded(mod), do: mod.module_info(:md5)
  end

  defp beam_md5(bin) do
    {:ok, {_mod, md5}} = :beam_lib.md5(bin)
    md5
  end

  defp loaded_vsn(mod) do
    if :code.is_loaded(mod), do: mod.module_info(:attributes)[:vsn]
  end
end
