defmodule T3.Cloud.RelayClient do
  @moduledoc """
  The relay client (`cloudflared`) a T3 Connect tunnel runs on, found and installed
  as `@t3tools/shared/relayClient` does: `T3CODE_CLOUDFLARED_PATH`, else the
  managed copy in `<home>/tools/cloudflared/<version>/<platform>`, else one on
  `PATH`. Installing downloads the pinned release, checks its SHA-256, and runs it
  once before putting it in place.
  """

  @version "2026.5.2"
  @base "https://github.com/cloudflare/cloudflared/releases/download/#{@version}"
  @assets %{
    "darwin-arm64" =>
      {"#{@base}/cloudflared-darwin-arm64.tgz",
       "ba94054c9fd4297645093d59d51442e5e546d07bb0516120e694a13d5b216d38", :tgz},
    "darwin-x64" =>
      {"#{@base}/cloudflared-darwin-amd64.tgz",
       "7240f709506bc2c1eb9da4d89cf2555499c60280ecb854b7d80e8f17d4b7903d", :tgz},
    "linux-arm64" =>
      {"#{@base}/cloudflared-linux-arm64",
       "5a4e8ce2701105271412059f44b6a0bf1ae4542b4d98ff3180c0c019443a5815", :binary},
    "linux-x64" =>
      {"#{@base}/cloudflared-linux-amd64",
       "5286698547f03df745adb2355f04c12dde52ef425491e81f433642d695521886", :binary}
  }

  @doc "`cloud.getRelayClientStatus`: the contracts' `RelayClientStatus`."
  def status do
    override = System.get_env("T3CODE_CLOUDFLARED_PATH")

    cond do
      override not in [nil, ""] ->
        if executable?(override), do: available(override, "override"), else: missing()

      executable?(managed_path()) ->
        available(managed_path(), "managed")

      path = System.find_executable("cloudflared") ->
        available(path, "path")

      Map.has_key?(assets(), platform()) ->
        missing()

      true ->
        [os, arch] = String.split(platform(), "-", parts: 2)
        %{"status" => "unsupported", "platform" => os, "arch" => arch, "version" => @version}
    end
  end

  @doc """
  `cloud.installRelayClient`: installs the managed copy unless one is available,
  calling `report.(stage)` as it goes. `{:ok, status}` or
  `{:error, %{"_tag" => "RelayClientInstallFailedError", ...}}`.
  """
  def install(report \\ fn _ -> :ok end) do
    report.("checking")

    case status() do
      %{"status" => "available"} = available ->
        {:ok, available}

      _ ->
        cond do
          System.get_env("T3CODE_CLOUDFLARED_PATH") not in [nil, ""] ->
            failed(
              "override_missing",
              "T3CODE_CLOUDFLARED_PATH does not point to an executable file."
            )

          asset = assets()[platform()] ->
            report.("waiting_for_lock")

            :global.trans({__MODULE__, node()}, fn -> install_locked(asset, report) end, [node()])

          true ->
            failed(
              "unsupported_platform",
              "T3 Code does not provide a managed relay client binary for #{platform()}."
            )
        end
    end
  end

  @doc """
  Installs in a task, reporting to `pid` as `{:t3_relay_client_install, node(),
  event}`: `RelayClientInstallProgressEvent`s, or `{:error, detail}`.
  """
  def start(pid) do
    Task.start(fn ->
      report = fn stage ->
        send(pid, {:t3_relay_client_install, node(), %{"type" => "progress", "stage" => stage}})
        :ok
      end

      event =
        case install(report) do
          {:ok, status} -> %{"type" => "complete", "status" => status}
          {:error, detail} -> {:error, detail}
        end

      send(pid, {:t3_relay_client_install, node(), event})
    end)

    :ok
  end

  defp install_locked({url, sha256, kind}, report) do
    with %{"status" => status} when status != "available" <- status(),
         :ok <- report.("downloading"),
         {:ok, bytes} <- download(url),
         :ok <- report.("verifying"),
         :ok <- checksum(bytes, sha256),
         :ok <- report.("installing"),
         {:ok, staged} <- stage(bytes, kind),
         :ok <- report.("validating"),
         :ok <- validate(staged),
         :ok <- report.("activating") do
      File.rename!(staged, managed_path())
      File.rm_rf(Path.dirname(staged))
      {:ok, status()}
    else
      %{"status" => "available"} = available -> {:ok, available}
      {:error, _} = error -> error
    end
  end

  defp download(url) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"t3-node"}]}

    case :httpc.request(:get, request, [timeout: 120_000, autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      _ -> failed("download_failed", "Could not download the relay client.")
    end
  end

  defp checksum(bytes, expected) do
    if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == expected,
      do: :ok,
      else: failed("invalid_checksum", "The relay client download did not match its checksum.")
  end

  # The executable, unpacked into a scratch directory beside its final place.
  defp stage(bytes, kind) do
    dir =
      Path.join(Path.dirname(managed_path()), ".install-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    target = Path.join(dir, "cloudflared")

    result =
      case kind do
        :binary ->
          File.write(target, bytes)

        :tgz ->
          case :erl_tar.extract({:binary, bytes}, [:compressed, cwd: String.to_charlist(dir)]) do
            :ok -> :ok
            error -> error
          end
      end

    with :ok <- result, :ok <- File.chmod(target, 0o755) do
      {:ok, target}
    else
      _ ->
        File.rm_rf(dir)
        failed("write_failed", "Could not extract the relay client.")
    end
  end

  defp validate(path) do
    case System.cmd(path, ["version"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        File.rm_rf(Path.dirname(path))
        failed("validation_failed", "The downloaded relay client did not run.")
    end
  rescue
    _ -> failed("validation_failed", "The downloaded relay client did not run.")
  end

  defp failed(reason, message),
    do:
      {:error,
       %{"_tag" => "RelayClientInstallFailedError", "reason" => reason, "message" => message}}

  defp available(path, source),
    do: %{
      "status" => "available",
      "executablePath" => path,
      "source" => source,
      "version" => @version
    }

  defp missing, do: %{"status" => "missing", "version" => @version}

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  @doc false
  def managed_path do
    Path.join([
      Application.fetch_env!(:t3, :home),
      "tools",
      "cloudflared",
      @version,
      platform(),
      "cloudflared"
    ])
  end

  defp platform, do: T3.Upgrade.platform()

  # Tests point the download at a local release.
  defp assets, do: Application.get_env(:t3, :relay_client_assets, @assets)
end
