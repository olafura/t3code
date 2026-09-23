defmodule T3.Import.V2Test do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3

  @tag :tmp_dir
  test "imported streams fold to the same entities as the Node log", %{tmp_dir: dir} do
    source = Path.join(dir, "node.sqlite")
    events = node_events()
    write_node_log(source, events)

    store = start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite"), name: nil})
    assert {:ok, report} = T3.Import.V2.run(source, store)

    assert report.source_events == length(events)
    # Dropped: the byte-identical re-emit, the update to an unbound session, and the
    # detach of a session that was never attached here.
    assert report.events == length(events) - 3
    assert report.bytes < report.source_bytes

    loaded = T3.StreamState.load(T3.Store.path(store), "thread-1")
    # ps-1 was attached then detached; ps-2 was only ever updated from another thread.
    assert T3.StreamState.get(loaded, "provider-session") == %{}

    for stream <- ["thread-1", "project-1"] do
      expected =
        for {_agg, ^stream, type, payload} <- events,
            not String.starts_with?(type, "provider-session."),
            reduce: %{} do
          acc ->
            {kind, id, entity} = T3.Import.V2.entity(type, payload)
            Map.update(acc, kind, %{id => entity}, &Map.put(&1, id, entity))
        end

      assert T3.StreamState.load(T3.Store.path(store), stream).entities == expected
    end
  end

  defp node_events do
    thread = %{"id" => "thread-1", "title" => "New thread", "projectId" => "project-1"}
    item = %{"id" => "item-1", "type" => "reasoning", "status" => "running", "text" => ""}

    streamed =
      for n <- 1..30 do
        {"thread", "thread-1", "turn-item.updated",
         %{item | "text" => Enum.map_join(1..n, " ", &"tok#{&1}")}}
      end

    done = %{item | "status" => "completed", "text" => "final"}

    [
      {"project", "project-1", "project.created",
       %{"projectId" => "project-1", "title" => "t3code"}},
      {"thread", "thread-1", "thread.created", thread},
      {"thread", "thread-1", "thread.visited", thread}
    ] ++
      streamed ++
      [
        {"thread", "thread-1", "turn-item.updated", done},
        {"thread", "thread-1", "thread.visited", Map.put(thread, "title", "Renamed")},
        {"thread", "thread-1", "provider-session.attached",
         %{"id" => "ps-1", "status" => "ready"}},
        {"thread", "thread-1", "provider-session.updated",
         %{"id" => "ps-2", "status" => "ready"}},
        {"thread", "thread-1", "provider-session.detached",
         %{"providerSessionId" => "ps-1", "detachedAt" => "now"}},
        {"thread", "thread-1", "provider-session.detached",
         %{"providerSessionId" => "ps-3", "detachedAt" => "now"}}
      ]
  end

  defp write_node_log(path, events) do
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
      """)

    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json, occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
      )

    for {agg, stream, type, payload} <- events do
      :ok =
        Sqlite3.bind(stmt, [
          agg,
          stream,
          type,
          IO.iodata_to_binary(JSON.encode_to_iodata!(payload)),
          "2026-09-01T12:00:00.000Z",
          if(agg == "project", do: nil, else: 2)
        ])

      :done = Sqlite3.step(db, stmt)
    end

    Sqlite3.close(db)
  end
end
