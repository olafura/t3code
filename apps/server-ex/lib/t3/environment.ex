defmodule T3.Environment do
  @moduledoc """
  This node's identity as a client-facing environment.

  The environment id is generated once and kept in the T3 home directory, so it
  survives restarts, address changes, and cluster membership. Clients key their
  caches and settings by it, exactly as they do for Node servers.
  """

  @protocol 3

  @doc "The descriptor served at `/.well-known/t3/environment`."
  @spec descriptor() :: map
  def descriptor do
    %{
      "environmentId" => id(),
      "label" => label(),
      "platform" => platform(),
      "serverVersion" => version(),
      "orchestrationProtocolVersion" => @protocol,
      # Commands are resolved against the thread on the node, so clients need not
      # read the projection before sending.
      "capabilities" => %{
        "repositoryIdentity" => false,
        "serverResolvedCommandContext" => true,
        # GitHub pull requests through `gh` (`T3.PullRequests`), diff over HTTP.
        "pullRequests" => true,
        "pullRequestChecks" => true,
        # Threads link many pull requests, kept in sync with the host
        # (`T3.PullRequests.Sync`, `T3.PullRequests.Discovery`), and settle on their own
        # (`T3.Orchestration.Settlement`). Stack actions are not served.
        "threadPullRequests" => true,
        "threadPullRequestLinking" => true,
        "threadAutoSettlement" => true,
        # Files besides images upload to `T3.Attachments` too.
        "attachmentUploads" => true,
        "fileAttachments" => %{"maxUploadBytes" => 50 * 1024 * 1024},
        "questionAttachments" => true,
        # Context links become markers plus an envelope (`T3.ComposerContext`).
        "inlineMessageContext" => true,
        # A worktree that cannot be made fails its run; it never falls back to the root.
        "requiredWorktreeBootstrap" => true,
        "usagePriceOverrides" => true,
        # The icon setting persists, and `platform.machine` is detected.
        "environmentIcon" => true,
        # Project-scoped settings resolve per project (`T3.Settings.for_project/1`).
        "projectSettingsOverrides" => true,
        # Worktrees and browser artifacts are cleaned up by the rules (`T3.StorageCleanup`).
        # Turns a restart cut off go on when asked (`T3.Orchestration.Recovery`).
        "threadRestartContinuation" => true,
        # Themes in `<home>/themes` reach clients (`T3.EnvironmentThemes`).
        "environmentThemes" => true,
        # Quota from CLIProxyAPI hubs in settings (`T3.UsageLimitSources`).
        "usageLimitSources" => true,
        "storageCleanup" => true,
        "projectWorktreeCleanup" => true,
        # Thread commands `T3.Orchestration` understands (`@thread_updates`).
        "threadSettlement" => true,
        "threadSnooze" => true,
        "threadPinning" => true,
        "threadPinReorder" => true,
        "threadActiveReorder" => true,
        "threadVisitedTracking" => true,
        "threadTitleRegeneration" => true,
        "projectCloneTracking" => true
      }
    }
  end

  @doc """
  `server.refreshProviders`: reads models again when the user asks
  (`refreshModels`), for one instance or all, then returns the provider list.
  Subscription quota is read again too (`T3.ProviderUsageLimits`), and an untargeted
  refresh re-reads the usage-limit sources, as the Node server's status probe does;
  a workspace refresh (with a `cwd`) leaves quota alone.
  """
  def refresh_providers(input) do
    case input do
      %{"cwd" => cwd} when is_binary(cwd) ->
        :ok

      %{"instanceId" => id} when is_binary(id) ->
        T3.ProviderUsageLimits.refresh([id])

      _ ->
        T3.ProviderUsageLimits.refresh()
        T3.UsageLimitSources.refresh()
    end

    if input["refreshModels"] == true do
      case input["instanceId"] do
        nil ->
          T3.Codex.Provider.load()
          for id <- T3.Acp.instances(), do: T3.Acp.reload(id)

        "codex" ->
          T3.Codex.Provider.load()

        id ->
          if T3.Acp.agent?(id), do: T3.Acp.reload(id)
      end

      T3.Settings.notify_providers()
    end

    {:ok, %{"providers" => providers()}}
  end

  @doc """
  The client's `ServerConfig` for this node. Only what a node serves today is
  filled in: Codex and Claude when installed, the user's keybinding rules, the installed editors, and
  the stored settings (`T3.Settings`), which decode to their defaults.
  """
  @spec server_config() :: map
  def server_config do
    home = Application.fetch_env!(:t3, :home)

    %{
      "environment" => descriptor(),
      "auth" => %{
        "policy" => "loopback-browser",
        "bootstrapMethods" => ["one-time-token"],
        "sessionMethods" => ["bearer-access-token"],
        "sessionCookieName" => "t3_session"
      },
      "cwd" => File.cwd!(),
      "keybindingsConfigPath" => Path.join(home, "keybindings.json"),
      # Clients compile the rules with the defaults into `keybindings`.
      "keybindings" => [],
      "keybindingRules" => T3.Keybindings.rules(),
      "issues" => [],
      "providers" => providers(),
      "availableEditors" => T3.Editors.available(),
      "observability" => %{
        "logsDirectoryPath" => Path.join(home, "logs"),
        "localTracingEnabled" => false,
        "otlpTracesEnabled" => false,
        "otlpMetricsEnabled" => false,
        "otlpLogsEnabled" => false
      },
      "settings" => T3.Settings.settings()
    }
  end

  @doc "`ServerConfig.providers`: the agents this node can run."
  def providers do
    for(
      entry <- [T3.Codex.Provider.entry(), T3.Claude.Provider.entry()],
      entry != nil,
      do: T3.ProviderUsageLimits.put(entry)
    ) ++ T3.Acp.entries()
  end

  @spec id() :: String.t()
  def id do
    case :persistent_term.get({__MODULE__, :id}, nil) do
      nil ->
        path = Path.join(Application.fetch_env!(:t3, :home), "environment-id")

        id =
          case File.read(path) do
            {:ok, id} ->
              String.trim(id)

            {:error, :enoent} ->
              id = uuid4()
              File.mkdir_p!(Path.dirname(path))
              File.write!(path, id)
              id
          end

        :persistent_term.put({__MODULE__, :id}, id)
        id

      id ->
        id
    end
  end

  # The machine's host name, unless T3_LABEL names it.
  defp label do
    case System.get_env("T3_LABEL") do
      nil ->
        {:ok, host} = :inet.gethostname()
        List.to_string(host)

      label ->
        label
    end
  end

  defp platform do
    base = %{"os" => os(), "arch" => arch()}

    case T3.Environment.Machine.kind() do
      nil -> base
      machine -> Map.put(base, "machine", machine)
    end
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "win32"
      {_, other} -> Atom.to_string(other)
    end
  end

  defp arch do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      arch =~ ~r/aarch64|arm64/ -> "arm64"
      arch =~ ~r/x86_64|amd64/ -> "x64"
      true -> arch
    end
  end

  defp version, do: Application.spec(:t3, :vsn) |> to_string()

  @doc "A random (v4) UUID."
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
    end)
  end
end
