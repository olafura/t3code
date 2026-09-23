defmodule T3.Store do
  @moduledoc """
  The node's durable event log, in one SQLite file.

  A *stream* is a project or a thread, addressed by its string id and stored under a
  small integer key. Every event is a `T3.Patch` to one entity of one stream, and its
  `seq` is the node-wide offset clients resume from. Snapshots are a cache of folded
  stream state and can always be rebuilt from events.

  All writes go through this process. Reads open their own read-only connection, so
  a slow reader never blocks appends.

  Patches larger than `@compress_over` bytes (mostly command output) are stored
  zstd-compressed behind a zero byte, which a JSON document can never start with.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @schema_version 1
  @compress_over 1024

  @schema [
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    """
    CREATE TABLE IF NOT EXISTS streams (
      key INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      id TEXT NOT NULL UNIQUE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS events (
      seq INTEGER PRIMARY KEY,
      stream INTEGER NOT NULL REFERENCES streams(key),
      kind TEXT NOT NULL,
      entity TEXT NOT NULL,
      patch TEXT NOT NULL,
      at INTEGER NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS events_stream_seq ON events(stream, seq)",
    "CREATE INDEX IF NOT EXISTS events_shell ON events(stream, seq) WHERE kind IN ('thread', 'project')",
    """
    CREATE TABLE IF NOT EXISTS shell (
      stream INTEGER PRIMARY KEY REFERENCES streams(key),
      seq INTEGER NOT NULL,
      kind TEXT NOT NULL,
      row TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS snapshots (
      stream INTEGER PRIMARY KEY REFERENCES streams(key),
      seq INTEGER NOT NULL,
      state BLOB NOT NULL
    )
    """
  ]

  @type stream_kind :: :project | :thread
  @typedoc "A patch to one entity, optionally with its own time (unix ms)."
  @type change ::
          {kind :: String.t(), entity :: String.t(), T3.Patch.t()}
          | {kind :: String.t(), entity :: String.t(), T3.Patch.t(), at :: integer}
  @type event :: %{
          seq: pos_integer,
          kind: String.t(),
          entity: String.t(),
          patch: T3.Patch.t(),
          at: integer
        }

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :path),
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  Appends changes to a stream in one transaction, creating the stream on first use.
  Each entry is `{stream_kind, stream_id, changes}`. Returns the last `seq` written.
  """
  @spec append(GenServer.server(), [{stream_kind, String.t(), [change]}], integer) ::
          {:ok, non_neg_integer} | {:error, term}
  def append(store \\ __MODULE__, batches, at \\ System.os_time(:millisecond)),
    do: GenServer.call(store, {:append, batches, at}, 60_000)

  @spec put_snapshot(GenServer.server(), String.t(), non_neg_integer, term) :: :ok
  def put_snapshot(store \\ __MODULE__, stream_id, seq, state),
    do: GenServer.call(store, {:put_snapshot, stream_id, seq, state})

  @doc "Stores a stream's sidebar row (see `T3.Projection.row/3`) as of `seq`."
  @spec put_shell(GenServer.server(), String.t(), non_neg_integer, {String.t(), map}) :: :ok
  def put_shell(store \\ __MODULE__, stream_id, seq, {kind, row}),
    do: GenServer.call(store, {:put_shell, stream_id, seq, kind, row})

  @doc "Every stored sidebar row as `{stream_id, kind, row}`."
  @spec list_shell(String.t()) :: [{String.t(), String.t(), map}]
  def list_shell(path) do
    with_reader(path, fn db ->
      {:ok, stmt} =
        Sqlite3.prepare(
          db,
          "SELECT s.id, h.kind, h.row FROM shell h JOIN streams s ON s.key = h.stream"
        )

      step_reduce(db, stmt, [], fn [id, kind, row], acc ->
        [{id, kind, JSON.decode!(row)} | acc]
      end)
    end)
  end

  @spec path(GenServer.server()) :: String.t()
  def path(store \\ __MODULE__), do: GenServer.call(store, :path)

  @doc """
  Folds a stream's events after `after_seq` in order, reading from a private
  connection.

  Options: `:limit` caps how many events are read; `:kinds` reads only those entity
  kinds (`["thread", "project"]` is indexed for building the shell).
  """
  @spec reduce_stream(String.t(), String.t(), non_neg_integer, acc, (event, acc -> acc), keyword) ::
          acc
        when acc: term
  def reduce_stream(path, stream_id, after_seq, acc, fun, opts \\ []) do
    kinds = Keyword.get(opts, :kinds)

    kind_filter =
      if kinds,
        do: "AND e.kind IN (#{Enum.map_join(kinds, ", ", &"'#{safe_kind!(&1)}'")})",
        else: ""

    with_reader(path, fn db ->
      {:ok, stmt} =
        Sqlite3.prepare(db, """
        SELECT e.seq, e.kind, e.entity, e.patch, e.at FROM events e
        JOIN streams s ON s.key = e.stream
        WHERE s.id = ?1 AND e.seq > ?2 #{kind_filter} ORDER BY e.seq LIMIT ?3
        """)

      :ok = Sqlite3.bind(stmt, [stream_id, after_seq, Keyword.get(opts, :limit, -1)])

      step_reduce(db, stmt, acc, fn [seq, kind, entity, patch, at], acc ->
        fun.(%{seq: seq, kind: kind, entity: entity, patch: decode_patch(patch), at: at}, acc)
      end)
    end)
  end

  @doc "Latest snapshot of a stream, if any."
  @spec get_snapshot(String.t(), String.t()) :: {non_neg_integer, term} | nil
  def get_snapshot(path, stream_id) do
    with_reader(path, fn db ->
      {:ok, stmt} =
        Sqlite3.prepare(
          db,
          "SELECT n.seq, n.state FROM snapshots n JOIN streams s ON s.key = n.stream WHERE s.id = ?1"
        )

      :ok = Sqlite3.bind(stmt, [stream_id])

      case Sqlite3.step(db, stmt) do
        {:row, [seq, state]} -> {seq, :erlang.binary_to_term(state)}
        :done -> nil
      end
    end)
  end

  @doc "All streams with their latest seq, for building indexes."
  @spec list_streams(String.t()) :: [%{id: String.t(), kind: String.t(), seq: non_neg_integer}]
  def list_streams(path) do
    with_reader(path, fn db ->
      {:ok, stmt} =
        Sqlite3.prepare(db, """
        SELECT s.id, s.kind, COALESCE(MAX(e.seq), 0) FROM streams s
        LEFT JOIN events e ON e.stream = s.key GROUP BY s.key ORDER BY s.key
        """)

      step_reduce(db, stmt, [], fn [id, kind, seq], acc ->
        [%{id: id, kind: kind, seq: seq} | acc]
      end)
      |> Enum.reverse()
    end)
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)

    for pragma <- [
          "journal_mode = WAL",
          "synchronous = NORMAL",
          "foreign_keys = ON",
          "busy_timeout = 5000"
        ],
        do: :ok = Sqlite3.execute(db, "PRAGMA " <> pragma)

    Enum.each(@schema, &(:ok = Sqlite3.execute(db, &1)))

    :ok =
      Sqlite3.execute(
        db,
        "INSERT OR IGNORE INTO meta VALUES ('schema_version', '#{@schema_version}')"
      )

    {:ok, stream_key} = Sqlite3.prepare(db, "SELECT key FROM streams WHERE id = ?1")

    {:ok, insert_stream} =
      Sqlite3.prepare(db, "INSERT INTO streams (kind, id) VALUES (?1, ?2) RETURNING key")

    {:ok, insert_event} =
      Sqlite3.prepare(
        db,
        "INSERT INTO events (stream, kind, entity, patch, at) VALUES (?1, ?2, ?3, ?4, ?5) RETURNING seq"
      )

    {:ok,
     %{
       path: path,
       db: db,
       stmts: %{stream_key: stream_key, insert_stream: insert_stream, insert_event: insert_event},
       # Stream keys never change, so they are cached for the life of the process.
       keys: %{}
     }}
  end

  @impl true
  def handle_call({:append, batches, at}, _from, state) do
    :ok = Sqlite3.execute(state.db, "BEGIN IMMEDIATE")

    try do
      {last, state} =
        Enum.reduce(batches, {0, state}, fn {stream_kind, stream_id, changes}, {last, state} ->
          {key, state} = stream_key(state, stream_kind, stream_id)

          last =
            Enum.reduce(changes, last, fn change, _ ->
              {kind, entity, patch, change_at} = with_time(change, at)

              [[seq]] =
                run(state.db, state.stmts.insert_event, [
                  key,
                  kind,
                  entity,
                  encode_patch(patch),
                  change_at
                ])

              seq
            end)

          {last, state}
        end)

      :ok = Sqlite3.execute(state.db, "COMMIT")
      {:reply, {:ok, last}, state}
    rescue
      error ->
        Sqlite3.execute(state.db, "ROLLBACK")
        # Keys created inside the failed transaction were rolled back too.
        {:reply, {:error, error}, %{state | keys: %{}}}
    end
  end

  def handle_call({:put_snapshot, stream_id, seq, snapshot}, _from, state) do
    {key, state} = stream_key(state, :thread, stream_id)
    blob = :erlang.term_to_binary(snapshot, [:compressed])

    :ok =
      exec(
        state.db,
        "INSERT INTO snapshots (stream, seq, state) VALUES (?1, ?2, ?3) ON CONFLICT(stream) DO UPDATE SET seq = excluded.seq, state = excluded.state",
        [key, seq, {:blob, blob}]
      )

    {:reply, :ok, state}
  end

  def handle_call({:put_shell, stream_id, seq, kind, row}, _from, state) do
    {key, state} = stream_key(state, :thread, stream_id)

    :ok =
      exec(
        state.db,
        "INSERT INTO shell (stream, seq, kind, row) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(stream) DO UPDATE SET seq = excluded.seq, kind = excluded.kind, row = excluded.row",
        [key, seq, kind, IO.iodata_to_binary(JSON.encode_to_iodata!(row))]
      )

    {:reply, :ok, state}
  end

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  defp stream_key(state, kind, id) do
    case state.keys do
      %{^id => key} ->
        {key, state}

      _ ->
        key =
          case run(state.db, state.stmts.stream_key, [id]) do
            [[key]] -> key
            [] -> hd(hd(run(state.db, state.stmts.insert_stream, [Atom.to_string(kind), id])))
          end

        {key, %{state | keys: Map.put(state.keys, id, key)}}
    end
  end

  defp run(db, stmt, args) do
    :ok = Sqlite3.bind(stmt, args)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    rows
  end

  defp exec(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, args)
    :done = Sqlite3.step(db, stmt)
    Sqlite3.release(db, stmt)
  end

  defp with_time({kind, entity, patch}, at), do: {kind, entity, patch, at}
  defp with_time({_, _, _, _} = change, _at), do: change

  defp encode_patch(patch) do
    json = IO.iodata_to_binary(JSON.encode_to_iodata!(patch))

    if byte_size(json) > @compress_over,
      do: {:blob, IO.iodata_to_binary([0 | :zstd.compress(json)])},
      else: json
  end

  defp decode_patch(<<0, compressed::binary>>),
    do: compressed |> :zstd.decompress() |> IO.iodata_to_binary() |> JSON.decode!()

  defp decode_patch(json), do: JSON.decode!(json)

  # Entity kinds are interpolated into SQL, so only plain identifiers are allowed.
  defp safe_kind!(kind) do
    if kind =~ ~r/\A[a-z][a-z-]*\z/,
      do: kind,
      else: raise(ArgumentError, "bad entity kind #{inspect(kind)}")
  end

  defp with_reader(path, fun) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp step_reduce(db, stmt, acc, fun) do
    case Sqlite3.multi_step(db, stmt, 500) do
      {:rows, rows} -> step_reduce(db, stmt, Enum.reduce(rows, acc, fun), fun)
      {:done, rows} -> Enum.reduce(rows, acc, fun)
    end
  end
end
