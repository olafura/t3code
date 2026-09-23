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
