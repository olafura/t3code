defmodule T3.Orchestration.RecoveryTest do
  use ExUnit.Case, async: false

  alias T3.Orchestration.Recovery
  alias T3.StreamState

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    :ok
  end

  test "a turn left running when the node stopped is settled at boot" do
    :ok = T3.Shell.subscribe(self())
    at = "2026-09-23T10:00:00.000Z"

    {:ok, _} =
      T3.Streams.commit("t1", :thread, [
        {"thread", "t1",
         %{"s" => %{"id" => "t1", "title" => "Busy", "createdAt" => at, "updatedAt" => at}}},
        {"run", "r1",
         %{"s" => %{"id" => "r1", "ordinal" => 1, "status" => "running", "requestedAt" => at}}},
        {"run", "r2",
         %{"s" => %{"id" => "r2", "ordinal" => 2, "status" => "queued", "queuePosition" => 1}}},
        {"run-attempt", "a1", %{"s" => %{"id" => "a1", "status" => "running"}}},
        {"node", "n1", %{"s" => %{"id" => "n1", "status" => "waiting"}}},
        {"turn-item", "i1",
         %{"s" => %{"id" => "i1", "status" => "running", "streaming" => true, "ordinal" => 0}}},
        {"message", "m1", %{"s" => %{"id" => "m1", "streaming" => true}}},
        {"runtime-request", "q1", %{"s" => %{"id" => "q1", "status" => "pending"}}},
        {"provider-thread", "p1", %{"s" => %{"id" => "p1", "status" => "active"}}}
      ])

    assert_receive {:t3_shell, {:rows, _, [{"t1", {"thread", %{"activeRunId" => "r1"}}}]}}, 1_000

    assert Recovery.run() == ["t1"]
    state = T3.Streams.Server.state(T3.Streams.ensure("t1"))

    assert %{"status" => "interrupted", "completedAt" => _} = StreamState.get(state, "run")["r1"]
    assert %{"status" => "interrupted"} = StreamState.get(state, "run-attempt")["a1"]
    # A queued message stays queued, held until the user resumes the queue.
    assert %{"status" => "queued", "queueHeld" => true} = StreamState.get(state, "run")["r2"]
    assert %{"status" => "interrupted"} = StreamState.get(state, "node")["n1"]

    assert %{"status" => "interrupted", "streaming" => false} =
             StreamState.get(state, "turn-item")["i1"]

    assert %{"streaming" => false} = StreamState.get(state, "message")["m1"]
    assert %{"status" => "cancelled"} = StreamState.get(state, "runtime-request")["q1"]
    assert %{"status" => "idle"} = StreamState.get(state, "provider-thread")["p1"]

    # Settled threads are left alone.
    assert Recovery.settle("t1") == 0
  end
end
