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
      "platform" => %{"os" => os(), "arch" => arch()},
      "serverVersion" => version(),
      "orchestrationProtocolVersion" => @protocol,
      # Commands are resolved against the thread on the node, so clients need not
      # read the projection before sending.
      "capabilities" => %{"repositoryIdentity" => false, "serverResolvedCommandContext" => true}
    }
  end

  @doc """
  The client's `ServerConfig` for this node. Only what a node serves today is
  filled in: Codex and Claude when installed, empty keybinding and editor lists, and
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
      "keybindings" => [],
      "issues" => [],
      "providers" =>
        Enum.reject([T3.Codex.Provider.entry(), T3.Claude.Provider.entry()], &is_nil/1) ++
          T3.Acp.entries(),
      "availableEditors" => [],
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
