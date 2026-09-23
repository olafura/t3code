defmodule T3.ScheduledTasksTest do
  use ExUnit.Case, async: true

  alias T3.ScheduledTasks

  @from ~U[2026-09-23 12:00:00.000Z]

  defp local(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)

    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  test "an interval runs that long after the last run, at least a minute" do
    assert ScheduledTasks.next_run(%{"type" => "interval", "everyMs" => 300_000}, @from) ==
             "2026-09-23T12:05:00.000Z"

    assert ScheduledTasks.next_run(%{"type" => "interval", "everyMs" => 1_000}, @from) ==
             "2026-09-23T12:01:00.000Z"
  end

  test "a fixed time runs at the next local wall-clock time on an allowed weekday" do
    for time <- ["9:30", "23:59", "00:00"] do
      next = ScheduledTasks.next_run(%{"type" => "fixed_time", "timeOfDay" => time}, @from)
      [hour, minute] = time |> String.split(":") |> Enum.map(&String.to_integer/1)
      local = local(next)

      assert {local.hour, local.minute} == {hour, minute}
      {:ok, at, _} = DateTime.from_iso8601(next)
      assert DateTime.compare(at, @from) == :gt
      assert DateTime.diff(at, @from, :hour) < 24
    end

    # Sundays only.
    next =
      ScheduledTasks.next_run(
        %{"type" => "fixed_time", "timeOfDay" => "10:00", "weekdays" => [0]},
        @from
      )

    assert Date.day_of_week(NaiveDateTime.to_date(local(next))) == 7
  end
end
