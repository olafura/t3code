defmodule T3.Upgrade.Source do
  @moduledoc """
  Where a node gets the bundle for a version (`T3.Upgrade`), checked against its
  SHA-256 before use:

    1. its own cache, `<home>/upgrades/<version>/`, where `mix t3.upgrade` also
       leaves bundles it built;
    2. a cluster peer that already has it, over the peer's HTTP port with a
       one-time link the peer hands out over distribution (bundles never travel
       over distribution itself, which a large message would stall);
    3. the release artifact at `T3_UPGRADE_URL` (`{version}` and `{platform}` are
       filled in), with its `.sha256` beside it.

  Bundles are per platform, since native libraries and ERTS are.
  """

  require Logger

  @default_url "https://github.com/olafura/t3code/releases/download/node-v{version}/t3-node-{version}-{platform}.tar.gz"
  @link_ttl_ms :timer.minutes(10)

  @doc "The file name of a version's bundle for a platform."
  def file_name(version, platform), do: "t3-node-#{version}-#{platform}.tar.gz"

  @doc "The unpacked bundle directory: `{:ok, dir}` or `{:error, ServerSelfUpdateError}`."
  def fetch(version, platform) do
    archive = archive_path(version, platform)

    with {:error, _} <- cached(version, platform),
         {:error, _} <- from_peers(version, platform, archive),
         {:error, reason} <- from_url(version, platform, archive) do
      {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}}
    else
      {:ok, _} -> unpack(version, platform)
    end
  end

  @doc """
  Adds a bundle archive for `version` to this node's cache, so it can update from
  it and hand it to peers (`mix t3.upgrade`).
  """
  def put(version, platform, source_path) do
    target = archive_path(version, platform)
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source_path, target)
    File.write!(target <> ".sha256", sha256(target))
    :ok
  end

  @doc """
  Receives a bundle archive in pieces over distribution (`mix t3.upgrade`): `:begin`,
  then each `{:chunk, binary}`, then `{:finish, sha256}`, which checks it and adds it
  to the cache. Pieces are small, so they never hold up the distribution link.
  """
  def receive_part(version, platform, :begin) do
    path = archive_path(version, platform) <> ".incoming"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    :ok
  end

  def receive_part(version, platform, {:chunk, data}) do
    File.write!(archive_path(version, platform) <> ".incoming", data, [:append])
  end

  def receive_part(version, platform, {:finish, sum}) do
    target = archive_path(version, platform)
    incoming = target <> ".incoming"

    if sha256(incoming) == sum do
      File.rename!(incoming, target)
      File.write!(target <> ".sha256", sum)
      # A bundle for the same version unpacked before is stale now.
      File.rm_rf!(Path.join(cache_dir(version), "bundle-#{platform}"))
      :ok
    else
      File.rm(incoming)
      {:error, "the bundle arrived damaged"}
    end
  end

  @doc """
  Offered to a peer over distribution: a one-time HTTP link to this node's copy of
  the bundle, with its SHA-256, or nil when it has none.
  """
  def offer(version, platform) do
    path = archive_path(version, platform)

    with {:ok, sum} <- File.read(path <> ".sha256"), true <- File.regular?(path) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      :persistent_term.put({__MODULE__, token}, {path, System.monotonic_time(:millisecond)})

      %{
        "port" => Application.get_env(:t3, :port, 3780),
        "path" => "/api/upgrade/#{token}",
        "sha256" => String.trim(sum)
      }
    else
      _ -> nil
    end
  end

  @doc "The file a one-time link names, once (`GET /api/upgrade/:token`)."
  def take(token) do
    case :persistent_term.get({__MODULE__, token}, nil) do
      {path, at} ->
        :persistent_term.erase({__MODULE__, token})
        if System.monotonic_time(:millisecond) - at < @link_ttl_ms, do: {:ok, path}, else: :error

      nil ->
        :error
    end
  end

  # --- sources -------------------------------------------------------------------

  defp cached(version, platform) do
    path = archive_path(version, platform)

    with {:ok, sum} <- File.read(path <> ".sha256"),
         true <- File.regular?(path) and sha256(path) == String.trim(sum) do
      {:ok, path}
    else
      _ -> {:error, "not cached"}
    end
  end

  defp from_peers(version, platform, archive) do
    Enum.reduce_while(Node.list(), {:error, "no peer has it"}, fn peer, acc ->
      with %{"port" => port, "path" => path, "sha256" => sum} <-
             safe_erpc(peer, __MODULE__, :offer, [version, platform]),
           host = peer_host(peer),
           :ok <- download("http://#{host}:#{port}#{path}", archive),
           true <- sha256(archive) == sum || {:error, "the copy from #{peer} does not match"} do
        File.write!(archive <> ".sha256", sum)
        Logger.info("upgrade bundle #{version} came from #{peer}")
        {:halt, {:ok, archive}}
      else
        {:error, reason} ->
          Logger.warning("upgrade bundle from #{peer} failed: #{inspect(reason)}")
          {:cont, acc}

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp from_url(version, platform, archive) do
    url =
      (System.get_env("T3_UPGRADE_URL") || Application.get_env(:t3, :upgrade_url, @default_url))
      |> String.replace("{version}", version)
      |> String.replace("{platform}", platform)

    with :ok <- download(url, archive),
         {:ok, sum} <- fetch_text(url <> ".sha256"),
         sum = sum |> String.split() |> List.first(),
         true <- sha256(archive) == sum || {:error, "#{url} does not match its checksum"} do
      File.write!(archive <> ".sha256", sum)
      {:ok, archive}
    else
      {:error, reason} ->
        File.rm(archive)
        {:error, "#{version} is not available for #{platform}: #{reason}"}
    end
  end

  defp unpack(version, platform) do
    dir = Path.join(cache_dir(version), "bundle-#{platform}")

    if T3.Upgrade.manifest(dir) != nil do
      {:ok, dir}
    else
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      case :erl_tar.extract(String.to_charlist(archive_path(version, platform)), [
             :compressed,
             {:cwd, String.to_charlist(dir)}
           ]) do
        :ok ->
          {:ok, dir}

        {:error, reason} ->
          {:error,
           %{
             "_tag" => "ServerSelfUpdateError",
             "reason" => "The bundle could not be unpacked: #{inspect(reason)}"
           }}
      end
    end
  end

  # --- HTTP ------------------------------------------------------------------------

  defp download(url, path) do
    File.mkdir_p!(Path.dirname(path))
    part = path <> ".part"

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options(), [
           {:stream, String.to_charlist(part)}
         ]) do
      {:ok, :saved_to_file} ->
        File.rename!(part, path)
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        File.rm(part)
        {:error, "#{url} answered #{status}"}

      {:error, reason} ->
        File.rm(part)
        {:error, "#{url}: #{inspect(reason)}"}
    end
  end

  defp fetch_text(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, http_options(), body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      _ -> {:error, "no checksum at #{url}"}
    end
  end

  defp http_options do
    [
      timeout: :timer.minutes(10),
      connect_timeout: 15_000,
      autoredirect: true,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 4]
    ]
  end

  # The address the distribution connection reached the peer at; its name's host
  # part need not resolve (short names).
  defp peer_host(peer) do
    case :net_kernel.node_info(peer) do
      {:ok, info} ->
        case info[:address] do
          {:net_address, {{_, _, _, _} = ip, _port}, _, _, _} -> :inet.ntoa(ip) |> to_string()
          {:net_address, {{_, _, _, _, _, _, _, _} = ip, _port}, _, _, _} -> "[#{:inet.ntoa(ip)}]"
          _ -> name_host(peer)
        end

      _ ->
        name_host(peer)
    end
  end

  defp name_host(peer), do: peer |> Atom.to_string() |> String.split("@") |> List.last()

  defp safe_erpc(node, mod, fun, args) do
    :erpc.call(node, mod, fun, args, 10_000)
  catch
    _, _ -> nil
  end

  # --- paths ---------------------------------------------------------------------------

  defp cache_dir(version),
    do: Path.join([Application.fetch_env!(:t3, :home), "upgrades", version])

  defp archive_path(version, platform),
    do: Path.join(cache_dir(version), file_name(version, platform))

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
