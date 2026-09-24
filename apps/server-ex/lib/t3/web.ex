defmodule T3.Web do
  @moduledoc "Client-facing HTTP and WebSocket listener."

  @doc "Bandit child spec for the configured port and host (loopback by default)."
  def child_spec(_opts) do
    port = Application.get_env(:t3, :port, 3780)
    host = Application.get_env(:t3, :host, "127.0.0.1")
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    Bandit.child_spec(plug: T3.Web.Router, ip: ip, port: port, startup_log: false)
  end

  @doc """
  At startup outside the desktop app, prints a pairing URL with administrative
  scopes, as `npx t3` does, so a new node can be opened in a browser right away.
  """
  def announce do
    unless Application.get_env(:t3, :desktop_token) do
      token = T3.Auth.create_pairing_token(T3.Store.path(), true)
      IO.puts("T3 node is ready. Pairing URL: #{base_url()}/pair#token=#{token}")
    end

    :ok
  end

  @doc "The address other machines reach this node at."
  def base_url do
    port = Application.get_env(:t3, :port, 3780)

    host =
      case Application.get_env(:t3, :host, "127.0.0.1") do
        any when any in ["0.0.0.0", "::"] -> external_ipv4() || "localhost"
        host -> host
      end

    "http://#{if String.contains?(host, ":"), do: "[#{host}]", else: host}:#{port}"
  end

  defp external_ipv4 do
    with {:ok, interfaces} <- :inet.getifaddrs() do
      Enum.find_value(interfaces, fn {_name, opts} ->
        Enum.find_value(Keyword.get_values(opts, :addr), fn
          {a, _, _, _} = ip when a != 127 -> :inet.ntoa(ip) |> to_string()
          _ -> nil
        end)
      end)
    else
      _ -> nil
    end
  end

  @doc """
  The node's access token, generated on first use and kept in the T3 home directory
  with owner-only permissions.
  """
  @spec token() :: String.t()
  def token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        path = Path.join(Application.fetch_env!(:t3, :home), "access-token")

        token =
          case File.read(path) do
            {:ok, token} ->
              String.trim(token)

            {:error, :enoent} ->
              token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
              File.mkdir_p!(Path.dirname(path))
              File.write!(path, token)
              File.chmod!(path, 0o600)
              token
          end

        :persistent_term.put({__MODULE__, :token}, token)
        token

      token ->
        token
    end
  end
end
