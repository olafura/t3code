defmodule T3.Auth do
  @moduledoc """
  Client authentication, wire-compatible with the Node server so existing clients
  pair with a node exactly as they pair with any environment.

    * A pairing token (5 minutes, single use) is exchanged at `/oauth/token` for a
      bearer access token (30 days). Tokens made in Settings → Connections are
      pairing links, listed and revocable until used.
    * The desktop app's bootstrap token (`T3.Desktop`) is exchanged the same way,
      as often as its window needs, for 24 hours from boot, with administrative
      scopes.
    * A bearer token buys a WebSocket ticket (5 minutes, single use), which the
      client puts in the socket URL so the long-lived token never appears there.
    * T3 Connect (`T3.Cloud`) mints pairing credentials bound to a client's DPoP
      key (`create_connect_credential/1`); exchanged with a proof from that key,
      they give a DPoP-bound session (1 hour) whose every request carries a new
      proof (`T3.Dpop`). Proof ids, and the relay's request ids, are remembered
      until they expire so none is accepted twice (`consume_once/2`).

  Pairing tokens and sessions are stored hashed in the node's SQLite file, so a
  `mix t3.pair` run next to a running node can mint a pairing token too. Tickets
  live in ETS. Sockets register their session (`connected/1`) so Connections can
  show which clients are online; watchers of the access list get
  `{:t3_auth_access, event}` (`AuthAccessStreamEvent`, with `current` left false
  for each socket to set).
  """

  use GenServer

  alias Exqlite.Sqlite3

  @pairing_ttl :timer.minutes(5)
  @connect_pairing_ttl :timer.minutes(2)
  @session_ttl :timer.hours(24 * 30)
  @bound_session_ttl :timer.hours(1)
  @ticket_ttl :timer.minutes(5)
  @standard_scopes ~w(orchestration:read orchestration:operate terminal:operate review:write relay:read)
  @admin_scopes @standard_scopes ++ ~w(access:read access:write relay:write)
  @desktop_ttl :timer.hours(24)
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
    """,
    "CREATE TABLE IF NOT EXISTS auth_replay (key TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)"
  ]

  # Added after the first release; `ensure_schema/1` adds them to older files.
  @columns [
    {"auth_pairing", "id", "TEXT"},
    {"auth_pairing", "label", "TEXT"},
    {"auth_pairing", "scopes", "TEXT"},
    {"auth_pairing", "created_at", "INTEGER"},
    {"auth_sessions", "id", "TEXT"},
    {"auth_sessions", "last_connected_at", "INTEGER"},
    {"auth_sessions", "device_type", "TEXT"},
    {"auth_sessions", "os", "TEXT"},
    {"auth_sessions", "user_agent", "TEXT"},
    {"auth_pairing", "proof_key", "TEXT"},
    {"auth_sessions", "proof_key", "TEXT"}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Creates a pairing token in the store at `path`; usable from outside the node.
  An `admin` one carries the administrative scopes (Connections, T3 Connect).
  """
  @spec create_pairing_token(String.t(), boolean) :: String.t()
  def create_pairing_token(path, admin \\ false) do
    with_db(path, fn db ->
      ensure_schema(db)
      insert_pairing(db, nil, if(admin, do: @admin_scopes, else: @standard_scopes))
    end)
    |> Map.fetch!("credential")
  end

  @doc """
  Exchanges a pairing token for `{:ok, access_token, expires_in_s, scopes}`.
  `client` describes who asked: `label`, `device_type`, `os`, `user_agent`.
  With `proof_key`, the thumbprint of the DPoP key the request proved, the session
  is bound to that key; a credential minted for a key is exchanged only with it.
  """
  @spec exchange(String.t(), map, String.t() | nil) ::
          {:ok, String.t(), pos_integer, [String.t()]} | :error
  def exchange(pairing_token, client \\ %{}, proof_key \\ nil),
    do: GenServer.call(__MODULE__, {:exchange, pairing_token, client, proof_key})

  @doc "The session behind an access token, if valid; `proof_key` is set for a DPoP-bound one."
  @spec session(String.t()) ::
          {:ok,
           %{
             id: String.t(),
             scopes: [String.t()],
             expires_at: integer,
             proof_key: String.t() | nil
           }}
          | :error
  def session(access_token), do: GenServer.call(__MODULE__, {:session, access_token})

  @doc """
  A one-time pairing credential for T3 Connect, usable for two minutes and only
  with a proof from the DPoP key `thumbprint`: `%{"credential", "expiresAt"}`.
  """
  def create_connect_credential(thumbprint),
    do: GenServer.call(__MODULE__, {:connect_credential, thumbprint})

  @doc """
  Records `keys` as used for `ttl_ms`: true when none was used before, false when
  any was (a replay).
  """
  @spec consume_once([String.t()], pos_integer) :: boolean
  def consume_once(keys, ttl_ms), do: GenServer.call(__MODULE__, {:consume_once, keys, ttl_ms})

  @spec issue_ticket(String.t()) :: {:ok, String.t(), integer} | :error
  def issue_ticket(access_token) do
    with {:ok, session} <- session(access_token) do
      ticket = random_token()
      expires_at = now() + @ticket_ttl
      :ets.insert(@tickets, {ticket, expires_at, session.id})
      {:ok, ticket, expires_at}
    end
  end

  @doc "Consumes a WebSocket ticket; each ticket opens one socket, for its session."
  @spec take_ticket(String.t()) :: {:ok, String.t()} | :error
  def take_ticket(ticket) do
    case :ets.take(@tickets, ticket) do
      [{_, expires_at, session_id}] -> if expires_at > now(), do: {:ok, session_id}, else: :error
      [] -> :error
    end
  end

  @doc """
  A WebSocket ticket's session scopes, leaving the ticket usable: `{:ok, scopes}`.
  The device hub proxy (`T3.Devices.Proxy`) authenticates every stream and image
  of a Device panel with one ticket, as the Node server does.
  """
  @spec ticket_scopes(String.t()) :: {:ok, [String.t()]} | :error
  def ticket_scopes(ticket) do
    case :ets.lookup(@tickets, ticket) do
      [{_, expires_at, session_id}] ->
        if expires_at > now(), do: GenServer.call(__MODULE__, {:scopes, session_id}), else: :error

      [] ->
        :error
    end
  end

  def standard_scopes, do: @standard_scopes

  @doc "Called by a socket of `session_id` once open; it counts as connected until it exits."
  def connected(session_id), do: GenServer.cast(__MODULE__, {:connected, session_id, self()})

  @doc "`POST /api/auth/pairing-token`: a pairing link, with its one-time credential."
  def create_pairing_link(input), do: GenServer.call(__MODULE__, {:create_link, input})

  @doc "`GET /api/auth/pairing-links`."
  def pairing_links, do: GenServer.call(__MODULE__, :links)

  @doc "`POST /api/auth/pairing-links/revoke`."
  def revoke_pairing_link(id), do: GenServer.call(__MODULE__, {:revoke_link, id})

  @doc "`GET /api/auth/clients`: `AuthClientSession`s, `current` false."
  def clients, do: GenServer.call(__MODULE__, :clients)

  @doc "`POST /api/auth/clients/revoke`."
  def revoke_client(id), do: GenServer.call(__MODULE__, {:revoke_client, id})

  @doc "`POST /api/auth/clients/revoke-others`: every session but `keep`."
  def revoke_other_clients(keep), do: GenServer.call(__MODULE__, {:revoke_others, keep})

  @doc "Watches the access list; replies with its revision and snapshot."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@tickets, [:named_table, :public, write_concurrency: true])
    path = T3.Store.path()
    with_db(path, &ensure_schema/1)

    desktop =
      case Application.get_env(:t3, :desktop_token) do
        nil -> nil
        token -> %{hash: hash(token), expires_at: now() + @desktop_ttl}
      end

    # Open sockets: socket pid -> session id.
    {:ok, %{path: path, desktop: desktop, revision: 0, watchers: %{}, sockets: %{}}}
  end

  @impl true
  def handle_call({:exchange, token, client, proof_key}, _from, %{desktop: desktop} = state) do
    {reply, events} =
      with_db(state.path, fn db ->
        cond do
          desktop != nil and :crypto.hash_equals(hash(token), desktop.hash) ->
            if desktop.expires_at > now(),
              do: create_session(db, @admin_scopes, client, [], state),
              else: {:error, []}

          true ->
            case query(
                   db,
                   "DELETE FROM auth_pairing WHERE token_hash = ?1 AND (proof_key IS NULL OR proof_key = ?2) RETURNING expires_at, id, scopes",
                   [hash(token), proof_key]
                 ) do
              [[expires_at, id, scopes]] when expires_at > 0 ->
                removed = [event("pairingLinkRemoved", %{"id" => id})]

                if expires_at > now(),
                  do: create_session(db, scopes(scopes), client, removed, state, proof_key),
                  else: {:error, removed}

              _ ->
                {:error, []}
            end
        end
      end)

    {:reply, reply, broadcast(state, events)}
  end

  def handle_call({:session, token}, _from, state) do
    reply =
      with_db(state.path, fn db ->
        case query(
               db,
               "SELECT id, scopes, expires_at, proof_key FROM auth_sessions WHERE token_hash = ?1",
               [hash(token)]
             ) do
          [[id, scopes, expires_at, proof_key]] ->
            if expires_at > now(),
              do:
                {:ok,
                 %{
                   id: id,
                   scopes: String.split(scopes),
                   expires_at: expires_at,
                   proof_key: proof_key
                 }},
              else: :error

          [] ->
            :error
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:scopes, session_id}, _from, state) do
    reply =
      with_db(state.path, fn db ->
        case query(db, "SELECT scopes, expires_at FROM auth_sessions WHERE id = ?1", [session_id]) do
          [[scopes, expires_at]] ->
            if expires_at > now(), do: {:ok, String.split(scopes)}, else: :error

          [] ->
            :error
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:connect_credential, thumbprint}, _from, state) do
    link =
      with_db(
        state.path,
        &insert_pairing(&1, "T3 Connect connect", @standard_scopes,
          ttl: @connect_pairing_ttl,
          proof_key: thumbprint
        )
      )

    listed =
      link
      |> Map.drop(["credential"])
      |> Map.merge(%{"scopes" => @standard_scopes, "subject" => "cloud-connect"})

    {:reply, Map.take(link, ["credential", "expiresAt"]),
     broadcast(state, [event("pairingLinkUpserted", listed)])}
  end

  def handle_call({:consume_once, keys, ttl_ms}, _from, state) do
    fresh =
      with_db(state.path, fn db ->
        at = now()
        exec(db, "DELETE FROM auth_replay WHERE expires_at <= ?1", [at])

        # An ignored insert returns no row: the key was used before.
        Enum.map(keys, fn key ->
          query(
            db,
            "INSERT OR IGNORE INTO auth_replay (key, expires_at) VALUES (?1, ?2) RETURNING 1",
            [key, at + ttl_ms]
          ) != []
        end)
      end)

    {:reply, Enum.all?(fresh), state}
  end

  def handle_call({:create_link, input}, _from, state) do
    scopes = Enum.filter(input["scopes"] || @standard_scopes, &(&1 in @admin_scopes))
    link = with_db(state.path, &insert_pairing(&1, input["label"], scopes))

    listed =
      Map.drop(link, ["credential"])
      |> Map.merge(%{"scopes" => scopes, "subject" => "pairing-link"})

    state = broadcast(state, [event("pairingLinkUpserted", listed)])
    {:reply, {:ok, Map.take(link, ~w(id credential label expiresAt))}, state}
  end

  def handle_call(:links, _from, state), do: {:reply, links(state.path), state}

  def handle_call({:revoke_link, id}, _from, state) do
    revoked =
      with_db(state.path, fn db ->
        query(db, "DELETE FROM auth_pairing WHERE id = ?1 RETURNING id", [id]) != []
      end)

    events = if revoked, do: [event("pairingLinkRemoved", %{"id" => id})], else: []
    {:reply, revoked, broadcast(state, events)}
  end

  def handle_call(:clients, _from, state), do: {:reply, clients(state), state}

  def handle_call({:revoke_client, id}, _from, state) do
    revoked = revoke(state.path, "id = ?1", [id])
    {:reply, revoked != [], broadcast(state, removed_clients(revoked))}
  end

  def handle_call({:revoke_others, keep}, _from, state) do
    revoked = revoke(state.path, "id IS NOT ?1", [keep])
    {:reply, length(revoked), broadcast(state, removed_clients(revoked))}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    snapshot = %{"pairingLinks" => links(state.path), "clientSessions" => clients(state)}
    {:reply, {:ok, state.revision, snapshot}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:connected, id, socket}, state) do
    Process.monitor(socket)
    state = %{state | sockets: Map.put(state.sockets, socket, id)}

    with_db(state.path, fn db ->
      exec(db, "UPDATE auth_sessions SET last_connected_at = ?1 WHERE id = ?2", [now(), id])
    end)

    {:noreply, broadcast(state, client_events(state, id))}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  # A watcher left, or a socket closed (its session may now be offline).
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {session, sockets} = Map.pop(state.sockets, pid)
    state = %{state | watchers: Map.delete(state.watchers, pid), sockets: sockets}
    events = if session, do: client_events(state, session), else: []
    {:noreply, broadcast(state, events)}
  end

  # --- store -------------------------------------------------------------------

  defp insert_pairing(db, label, scopes, opts \\ []) do
    token = random_token()
    id = "pairing-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    created = now()
    expires = created + Keyword.get(opts, :ttl, @pairing_ttl)

    exec(
      db,
      "INSERT INTO auth_pairing (token_hash, expires_at, id, label, scopes, created_at, proof_key) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      [hash(token), expires, id, label, Enum.join(scopes, " "), created, opts[:proof_key]]
    )

    %{
      "id" => id,
      "credential" => token,
      "createdAt" => iso(created),
      "expiresAt" => iso(expires)
    }
    |> put_present("label", label)
  end

  defp create_session(db, scopes, client, events, state, proof_key \\ nil) do
    access = random_token()
    id = "session-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    created = now()
    ttl = if proof_key, do: @bound_session_ttl, else: @session_ttl

    exec(
      db,
      """
      INSERT INTO auth_sessions (token_hash, scopes, label, created_at, expires_at, id, device_type, os, user_agent, proof_key)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      """,
      [
        hash(access),
        Enum.join(scopes, " "),
        client[:label],
        created,
        created + ttl,
        id,
        client[:device_type],
        client[:os],
        client[:user_agent],
        proof_key
      ]
    )

    upserted =
      for client <- session_rows(db, online(state), "id = ?1", [id]),
          do: event("clientUpserted", client)

    {{:ok, access, div(ttl, 1000), scopes}, events ++ upserted}
  end

  defp links(path) do
    with_db(path, fn db ->
      for [id, label, scopes, created, expires] <-
            query(
              db,
              "SELECT id, label, scopes, created_at, expires_at FROM auth_pairing WHERE expires_at > ?1 AND id IS NOT NULL ORDER BY created_at",
              [now()]
            ) do
        %{
          "id" => id,
          "scopes" => scopes(scopes),
          "subject" => "pairing-link",
          "createdAt" => iso(created || expires - @pairing_ttl),
          "expiresAt" => iso(expires)
        }
        |> put_present("label", label)
      end
    end)
  end

  defp clients(state),
    do: with_db(state.path, &session_rows(&1, online(state), "expires_at > ?1", [now()]))

  defp online(state), do: state.sockets |> Map.values() |> MapSet.new()

  defp session_rows(db, online, where, args) do
    for [id, scopes, label, created, expires, last, device, os, agent, proof_key] <-
          query(
            db,
            "SELECT id, scopes, label, created_at, expires_at, last_connected_at, device_type, os, user_agent, proof_key FROM auth_sessions WHERE #{where} ORDER BY created_at",
            args
          ) do
      %{
        "sessionId" => id,
        "subject" => "client",
        "scopes" => String.split(scopes),
        "method" => if(proof_key, do: "dpop-access-token", else: "bearer-access-token"),
        "client" =>
          %{"deviceType" => device || device_type(agent)}
          |> put_present("label", label)
          |> put_present("os", os)
          |> put_present("userAgent", agent),
        "issuedAt" => iso(created),
        "expiresAt" => iso(expires),
        "lastConnectedAt" => last && iso(last),
        "connected" => MapSet.member?(online, id),
        "current" => false
      }
    end
  end

  # Deletes matching sessions, returning their ids.
  defp revoke(path, where, args) do
    with_db(path, fn db ->
      for [id] <- query(db, "DELETE FROM auth_sessions WHERE #{where} RETURNING id", args), do: id
    end)
  end

  defp removed_clients(ids), do: for(id <- ids, do: event("clientRemoved", %{"sessionId" => id}))

  defp client_events(state, id) do
    with_db(state.path, fn db ->
      for client <- session_rows(db, online(state), "id = ?1", [id]),
          do: event("clientUpserted", client)
    end)
  end

  defp device_type(nil), do: "unknown"

  defp device_type(agent) do
    cond do
      agent =~ ~r/iPad|Tablet/i -> "tablet"
      agent =~ ~r/Mobile|iPhone|Android/i -> "mobile"
      agent =~ ~r/bot|curl|Elixir|node/i -> "bot"
      true -> "desktop"
    end
  end

  # --- events ------------------------------------------------------------------

  # `{type, payload}`, numbered when broadcast.
  defp event(type, payload), do: {type, payload}

  defp broadcast(state, []), do: state

  defp broadcast(state, events) do
    Enum.reduce(events, state, fn {type, payload}, state ->
      revision = state.revision + 1
      message = %{"version" => 1, "revision" => revision, "type" => type, "payload" => payload}
      for {pid, _} <- state.watchers, do: send(pid, {:t3_auth_access, message})
      %{state | revision: revision}
    end)
  end

  # --- helpers -----------------------------------------------------------------

  defp ensure_schema(db) do
    Enum.each(@schema, &(:ok = Sqlite3.execute(db, &1)))

    for {table, column, type} <- @columns do
      existing = for [_, name | _] <- query(db, "PRAGMA table_info(#{table})", []), do: name

      unless column in existing,
        do: :ok = Sqlite3.execute(db, "ALTER TABLE #{table} ADD COLUMN #{column} #{type}")
    end

    # Rows written before sessions and links had ids.
    exec(
      db,
      "UPDATE auth_sessions SET id = 'session-' || substr(token_hash, 1, 16) WHERE id IS NULL",
      []
    )

    exec(
      db,
      "UPDATE auth_pairing SET id = 'pairing-' || substr(token_hash, 1, 12) WHERE id IS NULL",
      []
    )
  end

  defp scopes(nil), do: @standard_scopes
  defp scopes(text), do: String.split(text)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  defp now, do: System.os_time(:millisecond)
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

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
