defmodule T3.DiagnosticsTest do
  use ExUnit.Case, async: true

  test "the node's own processes are listed and can be signalled, but no others" do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, %{"processes" => processes, "error" => %{"_tag" => "None"}}} =
      T3.Diagnostics.processes()

    assert [root | _] = processes
    assert root["depth"] == 0

    assert %{"startTimeMs" => started, "command" => "/bin/sleep 30"} =
             Enum.find(processes, &(&1["pid"] == pid))

    # Not the process that was seen: it restarted, or never was ours.
    assert {:ok, %{"signaled" => false}} =
             T3.Diagnostics.signal(%{
               "pid" => pid,
               "startTimeMs" => started - 60_000,
               "signal" => "SIGKILL"
             })

    assert {:ok, %{"signaled" => false}} =
             T3.Diagnostics.signal(%{"pid" => 1, "startTimeMs" => 0, "signal" => "SIGKILL"})

    assert {:ok, %{"signaled" => true}} =
             T3.Diagnostics.signal(%{
               "pid" => pid,
               "startTimeMs" => started,
               "signal" => "SIGKILL"
             })
  end

  test "host memory is read" do
    assert {:ok, %{"totalMemoryBytes" => total, "availableMemoryBytes" => available}} =
             T3.Diagnostics.host()

    assert total > 0 and available > 0 and available <= total
  end
end
