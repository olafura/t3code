defmodule T3.Auth do
  @moduledoc """
  Client authentication, wire-compatible with the Node server so existing clients
  pair with a node exactly as they pair with any environment.

    * A pairing token (5 minutes, single use) is exchanged at `/oauth/token` for a
      bearer access token (30 days).
    * A bearer token buys a WebSocket ticket (5 minutes, single use), which the
      client puts in the socket URL so the long-lived token never appears there.

  Pairing tokens and sessions are stored hashed in the node's SQLite file, so a
  `mix t3.pair` run next to a running node can mint a pairing token too. Tickets
  live in ETS.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @pairing_ttl :timer.minutes(5)
  @session_ttl :timer.hours(24 * 30)
  @ticket_ttl :timer.minutes(5)
  @standard_scopes ~w(orchestration:read orchestration:operate terminal:operate review:write relay:read)
  @tickets __MODULE__.Tickets

  @schema [
    "CREATE TABLE IF NOT EXISTS auth_pairing (token_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)",
    """
    CREATE TABLE IF NOT EXISTS auth_sessions (
      token_hash TEXT PRIMARY KEY,
      scopes TEXT NOT NULL,
      label TEXT,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )
    """
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Creates a pairing token in the store at `path`; usable from outside the node."
  @spec create_pairing_token(String.t()) :: String.t()
  def create_pairing_token(path) do
    token = random_token()

    with_db(path, fn db ->
      ensure_schema(db)
      exec(db, "INSERT INTO auth_pairing VALUES (?1, ?2)", [hash(token), now() + @pairing_ttl])
    end)

    token
  end

  @doc "Exchanges a pairing token for `{:ok, access_token, expires_in_s, scopes}`."
  @spec exchange(String.t(), String.t() | nil) ::
          {:ok, String.t(), pos_integer, [String.t()]} | :error
  def exchange(pairing_token, label),
    do: GenServer.call(__MODULE__, {:exchange, pairing_token, label})

  @doc "The session behind a bearer token, if valid."
  @spec session(String.t()) :: {:ok, %{scopes: [String.t()], expires_at: integer}} | :error
  def session(access_token), do: GenServer.call(__MODULE__, {:session, access_token})

  @spec issue_ticket(String.t()) :: {:ok, String.t(), integer} | :error
  def issue_ticket(access_token) do
    with {:ok, _session} <- session(access_token) do
      ticket = random_token()
      expires_at = now() + @ticket_ttl
      :ets.insert(@tickets, {ticket, expires_at})
      {:ok, ticket, expires_at}
    end
  end

  @doc "Consumes a WebSocket ticket; each ticket opens one socket."
  @spec take_ticket(String.t()) :: :ok | :error
  def take_ticket(ticket) do
    case :ets.take(@tickets, ticket) do
      [{_, expires_at}] -> if expires_at > now(), do: :ok, else: :error
      [] -> :error
    end
  end

  def standard_scopes, do: @standard_scopes

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@tickets, [:named_table, :public, write_concurrency: true])
    path = T3.Store.path()
    with_db(path, &ensure_schema/1)
    {:ok, %{path: path}}
  end

  @impl true
  def handle_call({:exchange, token, label}, _from, state) do
    reply =
      with_db(state.path, fn db ->
        case query(db, "DELETE FROM auth_pairing WHERE token_hash = ?1 RETURNING expires_at", [
               hash(token)
             ]) do
          [[expires_at]] ->
            if expires_at > now() do
              access = random_token()
              expires = now() + @session_ttl

              exec(db, "INSERT INTO auth_sessions VALUES (?1, ?2, ?3, ?4, ?5)", [
                hash(access),
                Enum.join(@standard_scopes, " "),
                label,
                now(),
                expires
              ])

              {:ok, access, div(@session_ttl, 1000), @standard_scopes}
            else
              :error
            end

          _ ->
            :error
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:session, token}, _from, state) do
    reply =
      with_db(state.path, fn db ->
        case query(db, "SELECT scopes, expires_at FROM auth_sessions WHERE token_hash = ?1", [
               hash(token)
             ]) do
          [[scopes, expires_at]] ->
            if expires_at > now(),
              do: {:ok, %{scopes: String.split(scopes), expires_at: expires_at}},
              else: :error

          [] ->
            :error
        end
      end)

    {:reply, reply, state}
  end

  defp ensure_schema(db), do: Enum.each(@schema, &(:ok = Sqlite3.execute(db, &1)))

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  defp now, do: System.os_time(:millisecond)

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp query(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, args)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    Sqlite3.release(db, stmt)
    rows
  end

  defp exec(db, sql, args), do: query(db, sql, args) && :ok
end
