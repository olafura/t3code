defmodule T3.Acp.Catalog do
  @moduledoc """
  The official ACP Registry: searching it, and installing its agents into the node's
  tools directory so `acpRegistry` provider instances can run them.

  The index is cached in `<home>/cache/acp-registry/registry.json`, refreshed on
  every search and otherwise once a day. An agent installs under
  `<home>/tools/<id>/<version>/`: a binary archive (checked against the registry's
  sha256 when it lists one) is extracted into `<platform>/`, an npx package goes to
  `npm/` through `npm install --global` with that prefix, and a uvx package to
  `python/` through `uv tool install`. Sessions run the installed executable, never
  `npx` or `uvx`, so a turn does not wait on a package manager.

  Failures are `AcpRegistryOperationError` details, which clients decode.
  """

  require Logger

  @url "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
  @max_index_bytes 1_048_576
  @max_results 20
  @stale_ms 24 * 60 * 60 * 1000
  @install_timeout 20 * 60 * 1000
  @id ~r/^[a-z0-9][a-z0-9._-]{0,127}$/
  @version ~r/^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/

  # --- RPCs ------------------------------------------------------------------------

  @doc "`server.searchAcpRegistry`: agents matching a query, best first."
  def search(%{} = input) do
    query = input["query"] |> to_string() |> String.trim() |> String.downcase()

    with {:ok, agents} <- index(true) do
      found =
        for agent <- agents,
            dist = distribution(agent, "auto"),
            rank = rank(agent, query),
            do: {rank, String.downcase(agent["name"]), agent, dist}

      {:ok,
       %{
         "agents" =>
           found
           |> Enum.sort_by(fn {rank, name, agent, _} -> {rank, name, agent["id"]} end)
           |> Enum.take(@max_results)
           |> Enum.map(fn {_, _, agent, dist} -> summary(agent, dist) end)
       }}
    end
  end

  @doc "`server.prepareAcpRegistryAgent`: installs an agent's current version."
  def prepare(%{"agentId" => id}) do
    with {:ok, agent} <- agent(id, true),
         {:ok, dist} <- pick(agent, "auto"),
         {:ok, _exe} <- install(agent, dist) do
      {:ok,
       %{
         "agentId" => id,
         "version" => agent["version"],
         "distribution" => dist.kind,
         "prepared" => true
       }}
    end
  end

  @doc """
  `server.uninstallAcpRegistryManagedBinary`: removes an agent's installs, unless a
  provider instance still uses it.
  """
  def uninstall(%{"agentId" => id}) do
    cond do
      not Regex.match?(@id, to_string(id)) ->
        error("agent_not_found", "Unknown ACP Registry agent #{inspect(id)}.")

      referenced?(id) ->
        {:ok, %{"agentId" => id, "removed" => false}}

      true ->
        dir = Path.join(tools_dir(), id)
        removed = File.exists?(dir)
        File.rm_rf!(dir)
        {:ok, %{"agentId" => id, "removed" => removed}}
    end
  end

  defp referenced?(id) do
    T3.Settings.settings()
    |> Map.get("providerInstances", %{})
    |> Enum.any?(fn {_, instance} ->
      is_map(instance) and instance["driver"] == "acpRegistry" and
        get_in(instance, ["config", "agentId"]) == id
    end)
  end

  # --- running ---------------------------------------------------------------------

  @doc """
  The command and environment that start an `acpRegistry` instance's agent, from its
  settings `config`, installing the agent's current version first when needed.
  """
  def command(%{} = config) do
    with {:ok, agent} <- agent(config["agentId"], false),
         {:ok, dist} <- pick(agent, config["distribution"] || "auto"),
         {:ok, exe} <- executable(agent, dist, config["commandPath"]) do
      {:ok, [exe | dist.args], Enum.to_list(dist.env)}
    end
  end

  defp executable(_agent, _dist, path) when is_binary(path) and path != "" do
    case System.find_executable(path) do
      nil -> error("runner_unavailable", "#{path} was not found.")
      exe -> {:ok, exe}
    end
  end

  defp executable(agent, dist, _path), do: install(agent, dist)

  @doc "The registry entry's name and version, for an instance's provider snapshot."
  def describe(agent_id) do
    case agent(agent_id, false) do
      {:ok, agent} -> %{name: agent["name"], version: agent["version"], website: agent["website"]}
      _ -> nil
    end
  end

  # --- index -----------------------------------------------------------------------

  defp agent(id, refresh) do
    with {:ok, agents} <- index(refresh) do
      case Enum.find(agents, &(&1["id"] == id)) do
        nil -> error("agent_not_found", "#{inspect(id)} is not in the ACP Registry.")
        agent -> {:ok, agent}
      end
    end
  end

  @doc "The registry's agents, from memory, disk, or the network."
  def index(refresh \\ false) do
    now = System.system_time(:millisecond)

    case :persistent_term.get({__MODULE__, :index}, nil) || read_cache() do
      {at, agents} when not refresh and now - at < @stale_ms ->
        {:ok, agents}

      cached ->
        case fetch() do
          {:ok, text, agents} ->
            write_cache(text)
            :persistent_term.put({__MODULE__, :index}, {now, agents})
            {:ok, agents}

          {:error, _} = error ->
            case cached do
              {_, agents} -> {:ok, agents}
              nil -> error
            end
        end
    end
  end

  defp fetch do
    with {:ok, text} <- get(registry_url(), 30_000),
         true <- byte_size(text) <= @max_index_bytes,
         {:ok, %{"agents" => agents}} when is_list(agents) <- JSON.decode(text) do
      {:ok, text, Enum.filter(agents, &valid?/1)}
    else
      _ -> error("registry_unavailable", "The ACP Registry could not be loaded.")
    end
  end

  defp read_cache do
    with {:ok, %{mtime: mtime}} <- File.stat(cache_path(), time: :posix),
         {:ok, text} <- File.read(cache_path()),
         {:ok, %{"agents" => agents}} when is_list(agents) <- JSON.decode(text) do
      cached = {mtime * 1000, Enum.filter(agents, &valid?/1)}
      :persistent_term.put({__MODULE__, :index}, cached)
      cached
    else
      _ -> nil
    end
  end

  defp write_cache(text) do
    path = cache_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", text)
    File.rename!(path <> ".tmp", path)
  end

  # Ids and versions become directory names; commands must stay inside the install.
  defp valid?(%{"id" => id, "name" => name, "version" => version, "distribution" => %{}} = agent)
       when is_binary(id) and is_binary(name) and is_binary(version) do
    Regex.match?(@id, id) and Regex.match?(@version, version) and
      is_binary(agent["description"] || "") and
      Enum.all?(Map.values(get_in(agent, ["distribution", "binary"]) || %{}), &valid_target?/1)
  end

  defp valid?(_), do: false

  # Archives come over HTTPS; plain HTTP only from this machine (a local mirror, tests).
  defp valid_target?(%{"archive" => archive, "cmd" => cmd})
       when is_binary(archive) and is_binary(cmd) do
    uri = URI.parse(archive)

    (uri.scheme == "https" or (uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost"])) and
      uri.userinfo == nil and relative_segments(cmd) != nil
  end

  defp valid_target?(_), do: false

  defp relative_segments(path) do
    normalized = path |> String.trim() |> String.replace("\\", "/") |> String.trim_leading("./")
    segments = String.split(normalized, "/", trim: true)

    if segments != [] and not String.starts_with?(normalized, "/") and
         not Regex.match?(~r/^[a-zA-Z]:/, normalized) and
         not Enum.any?(segments, &(&1 in [".", ".."])),
       do: segments
  end

  # --- search ----------------------------------------------------------------------

  defp rank(_agent, ""), do: 100

  defp rank(agent, query) do
    id = String.downcase(agent["id"])
    name = String.downcase(agent["name"])
    authors = (agent["authors"] || []) |> Enum.join(" ") |> String.downcase()
    description = String.downcase(agent["description"] || "")
    terms = String.split(query)
    tokens = String.split("#{id} #{name}", ~r/[^a-z0-9]+/, trim: true)

    cond do
      id == query or name == query -> 0
      String.starts_with?(id, query) or String.starts_with?(name, query) -> 10
      Enum.all?(terms, fn t -> Enum.any?(tokens, &String.starts_with?(&1, t)) end) -> 20
      Enum.all?(terms, &(String.contains?(id, &1) or String.contains?(name, &1))) -> 30
      Enum.all?(terms, &String.contains?(authors, &1)) -> 40
      Enum.all?(terms, &String.contains?("#{id} #{name} #{authors} #{description}", &1)) -> 50
      true -> nil
    end
  end

  defp summary(agent, dist) do
    %{
      "id" => agent["id"],
      "name" => agent["name"],
      "version" => agent["version"],
      "description" => String.slice(agent["description"] || "", 0, 1024),
      "authors" => Enum.take(agent["authors"] || [], 16),
      "license" => agent["license"],
      "website" => agent["website"],
      "repository" => agent["repository"],
      "icon" => agent["icon"],
      "distribution" => dist.kind,
      "integrity" =>
        if(dist.kind == "binary" and dist.target["sha256"], do: "sha256", else: "registry")
    }
  end

  # --- distributions ---------------------------------------------------------------

  defp pick(agent, preference) do
    case distribution(agent, preference) do
      nil ->
        error(
          "unsupported_platform",
          "#{agent["name"]} has no distribution for #{platform() || "this platform"}."
        )

      dist ->
        {:ok, dist}
    end
  end

  defp distribution(agent, preference) do
    dists = agent["distribution"]
    kinds = if preference in ["binary", "npx", "uvx"], do: [preference], else: ~w(binary npx uvx)

    Enum.find_value(kinds, fn
      "binary" ->
        target = platform() && get_in(dists, ["binary", platform()])
        if target, do: dist("binary", target, target)

      kind ->
        if is_binary(get_in(dists, [kind, "package"])), do: dist(kind, dists[kind], nil)
    end)
  end

  defp dist(kind, spec, target) do
    %{
      kind: kind,
      target: target,
      package: spec["package"],
      args: Enum.filter(spec["args"] || [], &is_binary/1),
      env: for({k, v} <- spec["env"] || %{}, is_binary(v), into: %{}, do: {k, v})
    }
  end

  @doc "The registry's name for this machine, such as `darwin-aarch64`."
  def platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        {:win32, _} -> "windows"
        _ -> nil
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64" <> _ -> "aarch64"
        "arm64" <> _ -> "aarch64"
        "x86_64" <> _ -> "x86_64"
        "amd64" <> _ -> "x86_64"
        _ -> nil
      end

    if os && arch, do: "#{os}-#{arch}"
  end

  # --- installs --------------------------------------------------------------------

  # One install per agent at a time; a second caller waits and finds it done.
  defp install(agent, dist) do
    lock = {{__MODULE__, agent["id"]}, self()}
    :global.trans(lock, fn -> installed(agent, dist) || do_install(agent, dist) end, [node()])
  end

  defp version_dir(agent),
    do: Path.join([tools_dir(), agent["id"], URI.encode_www_form(agent["version"])])

  defp installed(agent, %{kind: "binary"} = dist) do
    exe = Path.join([version_dir(agent), platform() | relative_segments(dist.target["cmd"])])
    if File.regular?(exe), do: {:ok, exe}
  end

  defp installed(agent, dist) do
    case package_executable(agent, dist) do
      {:ok, exe} -> {:ok, exe}
      _ -> nil
    end
  end

  defp do_install(agent, %{kind: "binary", target: target} = dist) do
    root = Path.join(version_dir(agent), platform())
    tmp = "#{root}.tmp-#{System.unique_integer([:positive])}"
    archive = Path.join(tmp <> ".download", archive_name(target["archive"]))

    try do
      File.mkdir_p!(Path.dirname(archive))
      File.mkdir_p!(tmp)

      with :ok <- download(target["archive"], archive),
           :ok <- verify(archive, target["sha256"]),
           :ok <- extract(archive, tmp, target["cmd"]) do
        exe = Path.join([tmp | relative_segments(target["cmd"])])

        if File.regular?(exe) do
          File.chmod!(exe, 0o755)
          File.rm_rf!(root)
          File.rename!(tmp, root)
          installed(agent, dist)
        else
          error("archive_invalid", "#{agent["name"]}'s archive has no #{target["cmd"]}.")
        end
      end
    after
      File.rm_rf(tmp)
      File.rm_rf(tmp <> ".download")
    end
  end

  defp do_install(agent, %{kind: kind, package: package} = dist) do
    {manager, args} =
      if kind == "npx",
        do: {"npm", ["install", "--global", package]},
        else: {"uv", ["tool", "install", "--force", package]}

    with {:ok, path} <- runner(manager),
         dir = package_dir(agent, kind),
         :ok <- File.mkdir_p(dir),
         {:ok, _} <- run([path | args], package_env(agent, kind)) do
      case package_executable(agent, dist) do
        {:ok, exe} ->
          {:ok, exe}

        :error ->
          error("install_failed", "#{package} installed no executable for #{agent["name"]}.")
      end
    end
  end

  defp runner(manager) do
    case System.find_executable(manager) do
      nil -> error("runner_unavailable", "Install #{manager} to use this agent.")
      path -> {:ok, path}
    end
  end

  defp package_dir(agent, "npx"), do: Path.join(version_dir(agent), "npm")
  defp package_dir(agent, "uvx"), do: Path.join(version_dir(agent), "python")

  defp package_env(agent, "npx"), do: [{"npm_config_prefix", package_dir(agent, "npx")}]

  defp package_env(agent, "uvx") do
    dir = package_dir(agent, "uvx")
    [{"UV_TOOL_DIR", dir}, {"UV_TOOL_BIN_DIR", Path.join(dir, "bin")}]
  end

  # npm names its commands in the package manifest; uv puts them in the bin dir.
  defp package_executable(agent, %{kind: "npx", package: package}) do
    name = package_name(package)
    root = Path.join([package_dir(agent, "npx"), "lib", "node_modules" | String.split(name, "/")])

    with {:ok, text} <- File.read(Path.join(root, "package.json")),
         {:ok, %{"bin" => bin}} <- JSON.decode(text),
         command when is_binary(command) <- bin_command(bin, name),
         exe = Path.join([package_dir(agent, "npx"), "bin", command]),
         true <- File.exists?(exe) do
      {:ok, exe}
    else
      _ -> :error
    end
  end

  defp package_executable(agent, %{kind: "uvx", package: package}) do
    bin = Path.join(package_dir(agent, "uvx"), "bin")
    name = package_name(package)

    with {:ok, [_ | _] = entries} <- File.ls(bin) do
      command = Enum.find(entries, &(&1 == name)) || Enum.min(entries)
      {:ok, Path.join(bin, command)}
    else
      _ -> :error
    end
  end

  defp package_name(package) do
    case String.split(package, "==") do
      [name, _] ->
        name

      _ ->
        {name, _} = package |> String.split("@") |> Enum.split(-1)
        Enum.join(name, "@")
    end
  end

  defp bin_command(bin, name) when is_binary(bin), do: name |> String.split("/") |> List.last()

  defp bin_command(%{} = bin, name) when map_size(bin) > 0 do
    short = name |> String.split("/") |> List.last()
    if Map.has_key?(bin, short), do: short, else: bin |> Map.keys() |> Enum.min()
  end

  defp bin_command(_, _), do: nil

  defp archive_name(url) do
    path = URI.parse(url).path |> to_string() |> String.downcase()

    cond do
      String.ends_with?(path, [".tar.gz", ".tgz"]) -> "agent.tar.gz"
      String.ends_with?(path, [".tar.bz2", ".tbz2"]) -> "agent.tar.bz2"
      String.ends_with?(path, ".zip") -> "agent.zip"
      true -> "agent.bin"
    end
  end

  defp verify(_archive, nil), do: :ok

  defp verify(archive, sha256) do
    digest =
      File.stream!(archive, 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if digest == String.downcase(sha256),
      do: :ok,
      else: error("checksum_mismatch", "The downloaded archive does not match its sha256.")
  end

  # erl_tar and zip refuse entries that would land outside `dir`.
  defp extract(archive, dir, cmd) do
    result =
      case Path.basename(archive) do
        "agent.tar.gz" ->
          :erl_tar.extract(to_charlist(archive), [:compressed, cwd: to_charlist(dir)])

        "agent.zip" ->
          with {:ok, _} <- :zip.extract(to_charlist(archive), cwd: to_charlist(dir)), do: :ok

        "agent.tar.bz2" ->
          case System.cmd("tar", ["-xjf", archive, "-C", dir], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {out, _} -> {:error, out}
          end

        "agent.bin" ->
          File.cp(archive, Path.join([dir | relative_segments(cmd)]))
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        error("archive_invalid", "The archive could not be extracted: #{inspect(reason)}")
    end
  end

  # --- processes and HTTP ----------------------------------------------------------

  defp run(cmd, env) do
    task =
      Task.async(fn ->
        Exile.stream(cmd, env: env, stderr: :redirect_to_stdout, ignore_epipe: true)
        |> Enum.reduce({[], nil}, fn
          {:exit, status}, {out, _} -> {out, status}
          data, {out, status} when is_binary(data) -> {[out, data], status}
          _, acc -> acc
        end)
      end)

    case Task.yield(task, @install_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:ok, {out, _}} ->
        text = out |> IO.iodata_to_binary() |> String.trim() |> String.slice(-1000, 1000)
        error("install_failed", "#{Path.basename(hd(cmd))} failed: #{text}")

      nil ->
        error("install_failed", "#{Path.basename(hd(cmd))} timed out")
    end
  rescue
    e in Exile.Stream.AbnormalExit ->
      error("install_failed", "#{Path.basename(hd(cmd))} failed: #{Exception.message(e)}")
  end

  defp get(url, timeout) do
    case :httpc.request(:get, {to_charlist(url), headers()}, http_options(timeout),
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp download(url, path) do
    case :httpc.request(:get, {to_charlist(url), headers()}, http_options(@install_timeout),
           stream: to_charlist(path)
         ) do
      {:ok, :saved_to_file} ->
        :ok

      other ->
        Logger.warning("ACP agent download failed: #{inspect(other)}")
        error("download_failed", "The agent could not be downloaded.")
    end
  end

  defp headers, do: [{~c"user-agent", ~c"t3code"}]

  defp http_options(timeout) do
    [
      timeout: timeout,
      connect_timeout: 15_000,
      autoredirect: true,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp error(reason, message),
    do:
      {:error, %{"_tag" => "AcpRegistryOperationError", "reason" => reason, "message" => message}}

  defp registry_url, do: Application.get_env(:t3, :acp_registry_url, @url)

  defp home, do: Application.fetch_env!(:t3, :home)
  defp cache_path, do: Path.join([home(), "cache", "acp-registry", "registry.json"])
  defp tools_dir, do: Path.join(home(), "tools")
end
