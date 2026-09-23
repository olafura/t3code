defmodule T3.StreamsTest do
  # Uses the node-wide named Store, Streams, and Shell processes.
  use ExUnit.Case, async: false

  alias T3.Streams

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    :ok
  end

  defp thread(id, fields \\ %{}),
    do: [{"thread", id, T3.Patch.diff(nil, Map.merge(%{"id" => id, "title" => "t"}, fields))}]

  defp append(text), do: [{"turn-item", "item-1", %{"a" => %{"text" => text}}}]

  test "subscribers get the current state, then live events" do
    {:ok, _} = Streams.commit("th-1", :thread, thread("th-1"))
    :ok = Streams.subscribe("th-1", self(), nil)

    assert_receive {:t3_stream, "th-1",
                    {:snapshot, seq, _at, [{"thread", "th-1", %{"title" => "t"}}], :done}}

    {:ok, next} =
      Streams.commit("th-1", :thread, [{"turn-item", "item-1", %{"s" => %{"text" => "Hel"}}}])

    assert next == seq + 1

    assert_receive {:t3_stream, "th-1",
                    {:events,
                     [%{seq: ^next, kind: "turn-item", patch: %{"s" => %{"text" => "Hel"}}}]}}
  end

  test "a reconnecting subscriber replays only what it missed" do
    {:ok, _} = Streams.commit("th-2", :thread, thread("th-2"))

    {:ok, offset} =
      Streams.commit("th-2", :thread, [{"turn-item", "item-1", %{"s" => %{"text" => "Hel"}}}])

    {:ok, _} = Streams.commit("th-2", :thread, append("lo"))
    {:ok, last} = Streams.commit("th-2", :thread, append(", world"))

    :ok = Streams.subscribe("th-2", self(), offset)
    assert_receive {:t3_stream, "th-2", {:events, events}}

    assert [
             %{patch: %{"a" => %{"text" => "lo"}}},
             %{seq: ^last, patch: %{"a" => %{"text" => ", world"}}}
           ] = events
  end

  test "state survives the stream process stopping and reloads from the log" do
    {:ok, _} = Streams.commit("th-3", :thread, thread("th-3"))

    {:ok, _} =
      Streams.commit("th-3", :thread, [{"turn-item", "item-1", %{"s" => %{"text" => "a"}}}])

    {:ok, _} = Streams.commit("th-3", :thread, append("b"))
    pid = Streams.ensure("th-3")
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, _, _, _}

    state = T3.Streams.Server.state(Streams.ensure("th-3"))
    assert state.entities["turn-item"]["item-1"]["text"] == "ab"
  end

  test "large snapshots arrive in bounded chunks" do
    big = String.duplicate("x", 100_000)
    changes = for i <- 1..10, do: {"turn-item", "item-#{i}", %{"s" => %{"output" => big}}}
    {:ok, _} = Streams.commit("th-5", :thread, changes)
    :ok = Streams.subscribe("th-5", self(), nil)

    chunks = collect_snapshot("th-5", [])
    assert length(chunks) > 1
    assert chunks |> List.flatten() |> length() == 10
    assert Enum.all?(chunks, &(:erlang.external_size(&1) < 400_000))
  end

  defp collect_snapshot(id, acc) do
    receive do
      {:t3_stream, ^id, {:snapshot, _seq, _at, rows, :more}} -> collect_snapshot(id, [rows | acc])
      {:t3_stream, ^id, {:snapshot, _seq, _at, rows, :done}} -> Enum.reverse([rows | acc])
    after
      1_000 -> flunk("snapshot incomplete")
    end
  end

  test "thread changes update the shell row and notify its subscribers" do
    :ok = T3.Shell.subscribe(self())
    {:ok, _} = Streams.commit("th-4", :thread, thread("th-4", %{"projectId" => "p"}))

    # Rows are recomputed shortly after a commit, not on every one.
    assert_receive {:t3_shell, {:rows, node, [{"th-4", {"thread", row}}]}}, 1_000
    assert node == node()
    assert %{"id" => "th-4", "title" => "t", "projectId" => "p", "status" => "idle"} = row

    {:ok, _} =
      Streams.commit("th-4", :thread, [{"thread", "th-4", %{"s" => %{"title" => "Renamed"}}}])

    assert_receive {:t3_shell, {:rows, _, [{"th-4", {"thread", %{"title" => "Renamed"}}}]}}, 1_000

    assert [{"thread", %{"title" => "Renamed"}}] =
             for({{_, "th-4"}, kind_row} <- T3.Shell.rows(), do: kind_row)
  end
end
