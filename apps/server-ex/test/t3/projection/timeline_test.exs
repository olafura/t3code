defmodule T3.Projection.TimelineTest do
  # Visibility cases ported from packages/shared/src/orchestrationV2Timeline.test.ts.
  use ExUnit.Case, async: true

  alias T3.Projection.Timeline

  @run "run:timeline"
  @node "node:timeline"

  defp visible?(item, run_status, attempts, items) do
    index = Timeline.index([%{"id" => @run, "status" => run_status}], attempts, items)
    Timeline.visible?(index, item)
  end

  defp item(type, extra \\ %{}),
    do: Map.merge(%{"type" => type, "runId" => @run, "nodeId" => @node}, extra)

  defp attempt(status, node \\ @node),
    do: %{"runId" => @run, "rootNodeId" => node, "status" => status}

  test "an unpaired interrupt result of a superseded attempt is hidden" do
    result = item("run_interrupt_result")
    refute visible?(result, "running", [attempt("superseded")], [result])
  end

  test "an interrupt result paired with a request stays visible" do
    result = item("run_interrupt_result")

    assert visible?(result, "running", [attempt("superseded")], [
             item("run_interrupt_request"),
             result
           ])
  end

  test "interrupt results of terminal attempts stay visible" do
    result = item("run_interrupt_result")
    assert visible?(result, "interrupted", [attempt("interrupted")], [result])
  end

  test "another attempt being superseded does not hide the result" do
    result = item("run_interrupt_result")

    assert visible?(
             result,
             "interrupted",
             [attempt("superseded", "node:older"), attempt("interrupted")],
             [result]
           )
  end

  test "a queued message disappears once its run is cancelled" do
    queued = item("user_message", %{"inputIntent" => "queued_turn"})
    refute visible?(queued, "cancelled", [], [queued])
    assert visible?(queued, "queued", [], [queued])

    started = item("user_message", %{"inputIntent" => "turn_start"})
    assert visible?(started, "cancelled", [], [started])
  end

  test "items of a rolled-back run are hidden; items without a run are not" do
    refute visible?(item("assistant_message"), "rolled_back", [], [])
    assert visible?(item("assistant_message", %{"runId" => :null}), "rolled_back", [], [])
  end
end
