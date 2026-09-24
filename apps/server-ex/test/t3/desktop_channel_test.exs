defmodule T3.Desktop.ChannelTest do
  use ExUnit.Case, async: false

  alias T3.Desktop.Channel

  setup do
    start_supervised!({Channel, transport: {:test, self()}})
    :ok
  end

  test "the desktop app updates itself when asked, reporting its progress" do
    test = self()
    task = Task.async(fn -> Channel.update(fn stage -> send(test, {:stage, stage}) end) end)

    assert_receive {:desktop_control,
                    %{"type" => "requestDesktopUpdate", "requestId" => id, "version" => 1}}

    # Only one update at a time.
    assert {:error, "A desktop app update is already in progress."} =
             Channel.update(fn _ -> :ok end)

    status(%{"requestId" => id, "state" => %{"status" => "downloading"}})
    assert_receive {:stage, "downloading"}
    # Reports for other runs are someone else's.
    status(%{"requestId" => "other", "outcome" => "failed", "state" => %{"status" => "error"}})

    status(%{
      "requestId" => id,
      "outcome" => "ready-to-install",
      "state" => %{
        "status" => "downloaded",
        "currentVersion" => "1.0.0",
        "downloadedVersion" => "1.1.0"
      }
    })

    assert_receive {:stage, "installing"}

    assert {:ok,
            %{"method" => "desktop-app", "targetVersion" => "1.1.0", "desktopUpdateToken" => ^id}} =
             Task.await(task)

    # Installing stops the node; only a failure comes back.
    commit = Task.async(fn -> Channel.commit(id) end)
    assert_receive {:desktop_control, %{"type" => "commitDesktopUpdate", "requestId" => ^id}}

    status(%{
      "requestId" => id,
      "outcome" => "failed",
      "reason" => "Disk full.",
      "state" => %{"status" => "error"}
    })

    assert {:error, "Disk full."} = Task.await(commit)
  end

  test "an app already up to date says so" do
    task = Task.async(fn -> Channel.update(fn _ -> :ok end) end)
    assert_receive {:desktop_control, %{"type" => "requestDesktopUpdate", "requestId" => id}}

    status(%{
      "requestId" => id,
      "outcome" => "up-to-date",
      "state" => %{"status" => "up-to-date", "currentVersion" => "1.0.0"}
    })

    assert {:error, message} = Task.await(task)
    assert message =~ "already up to date on 1.0.0"
  end

  test "telemetry is kept for diagnostics, which ask for it only while watched" do
    line(%{"type" => "desktopTelemetryHello", "electronPid" => 42})

    line(%{
      "type" => "desktopTelemetry",
      "sequence" => 1,
      "sampledAtUnixMs" => 1_790_000_000_000,
      "electronPid" => 42,
      "speedLimitPercent" => nil,
      "electronProcesses" => [
        %{
          "pid" => 42,
          "type" => "Browser",
          "creationTimeMs" => 1,
          "cpuPercent" => 3.5,
          "idleWakeupsPerSecond" => 0,
          "workingSetBytes" => 100,
          "peakWorkingSetBytes" => 120
        }
      ]
    })

    assert %{"electronPid" => 42, "electronProcesses" => [%{"type" => "Browser"}]} =
             Channel.telemetry()

    Channel.set_diagnostics_demand(true)
    assert_receive {:desktop_control, %{"type" => "setDiagnosticsDemand", "enabled" => true}}
  end

  test "a node the desktop app runs is updated through the app" do
    Application.put_env(:t3, :desktop_token, "token")
    on_exit(fn -> Application.delete_env(:t3, :desktop_token) end)
    assert T3.Upgrade.capability() == "desktop-managed"
  end

  defp status(fields),
    do: line(Map.merge(%{"version" => 1, "type" => "desktopUpdateStatus"}, fields))

  defp line(message), do: send(Channel, {:desktop_line, JSON.encode!(message)})
end
