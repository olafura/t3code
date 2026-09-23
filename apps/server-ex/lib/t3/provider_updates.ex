defmodule T3.ProviderUpdates do
  @moduledoc """
  Whether a provider CLI is behind its latest release (`versionAdvisory` on its
  `ServerProvider` entry), and updating it (`server.updateProvider`).

  The latest version is the npm registry's, read in the background at most hourly;
  providers are re-announced when it arrives. The update runs whatever installed
  the CLI, told apart by where its executable really lives: Homebrew, a global npm
  prefix, or Claude Code's own `claude update`. Anything else is reported without
  an update command.
  """

  @packages %{"codex" => "@openai/codex", "claudeAgent" => "@anthropic-ai/claude-code"}
  @ttl :timer.hours(1)

  @doc "The `versionAdvisory` for a provider whose executable is at `path`."
  def advisory(driver, path, current) do
    latest = latest(driver)
    update = update_command(driver, path)

    %{
      "status" =>
        cond do
          latest == nil or current in [nil, "unknown"] -> "unknown"
          newer?(latest, current) -> "behind_latest"
          true -> "current"
        end,
      "currentVersion" => if(current in [nil, "unknown"], do: nil, else: current),
      "latestVersion" => latest,
      "updateCommand" => update && Enum.join(update, " "),
      "canUpdate" => update != nil,
      "checkedAt" => checked_at(driver),
      "message" => nil
    }
  end

  @doc "`server.updateProvider`: runs the provider's updater, then reports providers again."
  def update(%{"provider" => driver}) do
    entry = Enum.find(T3.Environment.providers(), &(&1["driver"] == driver))
    path = entry && executable(driver)

    with {:path, path} when is_binary(path) <- {:path, path},
         {:command, [command | args]} <- {:command, update_command(driver, path)},
         {_out, 0} <- System.cmd(command, args, stderr_to_stdout: true) do
      forget_version(driver)
      T3.Settings.notify_providers()
      {:ok, %{"providers" => T3.Environment.providers()}}
    else
      {:path, _} -> error(driver, "#{driver} is not installed on this machine.")
      {:command, _} -> error(driver, "This installation cannot be updated from here.")
      {out, _status} -> error(driver, out |> String.trim() |> String.slice(-500, 500))
    end
  rescue
    exception -> error(driver, Exception.message(exception))
  end

  defp error(driver, reason),
    do:
      {:error,
       %{
         "_tag" => "ServerProviderUpdateError",
         "provider" => driver,
         "reason" => if(reason == "", do: "The update failed.", else: reason),
         "message" => reason
       }}

  # The updater for an executable, as argv, or nil.
  defp update_command(driver, path) do
    real = real_path(path)
    package = @packages[driver]

    cond do
      String.contains?(real, "/Caskroom/") ->
        [
          "brew",
          "upgrade",
          "--cask",
          real |> String.split("/Caskroom/") |> Enum.at(1) |> first_segment()
        ]

      String.contains?(real, "/Cellar/") ->
        ["brew", "upgrade", real |> String.split("/Cellar/") |> Enum.at(1) |> first_segment()]

      String.contains?(real, "/lib/node_modules/") and package != nil ->
        prefix = real |> String.split("/lib/node_modules/") |> hd()
        npm = Path.join([prefix, "bin", "npm"])

        [
          if(File.exists?(npm), do: npm, else: "npm"),
          "install",
          "-g",
          "--prefix",
          prefix,
          package <> "@latest"
        ]

      driver == "claudeAgent" and String.contains?(real, "/claude/") ->
        [path, "update"]

      true ->
        nil
    end
  end

  defp first_segment(rest), do: rest |> String.split("/") |> hd()

  defp real_path(path) do
    case :file.read_link_all(path) do
      {:ok, target} -> real_path(Path.expand(to_string(target), Path.dirname(path)))
      _ -> path
    end
  end

  defp executable("codex"), do: find(Application.get_env(:t3, :codex_command, ["codex"]))
  defp executable("claudeAgent"), do: find(Application.get_env(:t3, :claude_command, ["claude"]))
  defp executable(_), do: nil

  defp find([command | _]), do: System.find_executable(command)
  defp find(_), do: nil

  # Provider entries cache their version; an update makes it stale.
  defp forget_version("codex"), do: :persistent_term.erase({T3.Codex.Provider, :version})
  defp forget_version("claudeAgent"), do: :persistent_term.erase({T3.Claude.Provider, :version})
  defp forget_version(_), do: :ok

  # The latest release as last read, starting a read when it is missing or stale.
  defp latest(driver) do
    case :persistent_term.get({__MODULE__, driver}, nil) do
      {version, read_at} ->
        if System.monotonic_time(:millisecond) - read_at > @ttl, do: refresh(driver)
        version

      nil ->
        refresh(driver)
        nil
    end
  end

  defp checked_at(driver), do: :persistent_term.get({__MODULE__, driver, :checked_at}, nil)

  defp refresh(driver) do
    package = @packages[driver]
    key = {__MODULE__, driver, :reading}

    if package && Application.get_env(:t3, :provider_update_checks, true) &&
         :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Task.start(fn ->
        try do
          if version = registry_latest(package) do
            :persistent_term.put(
              {__MODULE__, driver},
              {version, System.monotonic_time(:millisecond)}
            )

            :persistent_term.put(
              {__MODULE__, driver, :checked_at},
              T3.Orchestration.Entities.now()
            )

            T3.Settings.notify_providers()
          end
        after
          :persistent_term.put(key, false)
        end
      end)
    end
  end

  defp registry_latest(package) do
    url = ~c"https://registry.npmjs.org/#{String.replace(package, "/", "%2F")}/latest"

    case :httpc.request(
           :get,
           {url, []},
           [timeout: 4_000, ssl: :httpc.ssl_verify_host_options(true)],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, %{"version" => version}} when is_binary(version) -> version
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp newer?(latest, current) do
    with {:ok, latest} <- Version.parse(latest),
         {:ok, current} <- Version.parse(current) do
      Version.compare(latest, current) == :gt
    else
      _ -> false
    end
  end
end
