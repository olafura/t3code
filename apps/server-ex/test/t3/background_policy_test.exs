defmodule T3.BackgroundPolicyTest do
  use ExUnit.Case, async: false

  alias T3.BackgroundPolicy

  @scope %{"type" => "vcs-status", "cwd" => "/repo"}

  setup do
    start_supervised!(T3.Settings)
    start_supervised!(BackgroundPolicy)
    :ok
  end

  defp report(pid, fields) do
    lease =
      Map.merge(
        %{
          "clientId" => "tab-1",
          "clientKind" => "web",
          "visible" => true,
          "focused" => true,
          "recentlyInteracted" => false,
          "scopes" => [@scope],
          "observedAt" => "2026-09-24T00:00:00.000Z"
        },
        fields
      )

    BackgroundPolicy.report_client_activity("session-1", pid, lease)
  end

  defp power(fields) do
    BackgroundPolicy.report_host_power(
      Map.merge(
        %{
          "source" => "desktop",
          "stale" => false,
          "suspended" => false,
          "locked" => "false",
          "onBattery" => "false",
          "lowPowerMode" => "false",
          "thermalState" => "nominal",
          "updatedAt" => DateTime.to_iso8601(DateTime.utc_now())
        },
        fields
      )
    )
  end

  test "work for a scope runs only while a client in front shows it" do
    refute BackgroundPolicy.run_scope_work?(@scope)

    report(self(), %{})
    assert BackgroundPolicy.run_scope_work?(@scope)
    refute BackgroundPolicy.run_scope_work?(%{"type" => "vcs-status", "cwd" => "/other"})

    report(self(), %{"focused" => false})
    refute BackgroundPolicy.run_scope_work?(@scope)

    assert %{"activeForegroundLeaseCount" => 0, "activeScopeKeys" => ["vcs-status:/repo"]} =
             BackgroundPolicy.snapshot()
  end

  test "a locked host pauses it, and a closed socket takes its leases along" do
    client = spawn(fn -> Process.sleep(:infinity) end)
    report(client, %{})
    assert BackgroundPolicy.run_scope_work?(@scope)

    power(%{"locked" => "true"})
    refute BackgroundPolicy.run_scope_work?(@scope)
    power(%{"locked" => "false"})
    assert BackgroundPolicy.run_scope_work?(@scope)

    ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert %{"leases" => []} = BackgroundPolicy.snapshot()
  end

  test "the battery saver profile turns automatic fetches off" do
    {_, version} = T3.Settings.get()

    {:ok, _} =
      T3.Settings.put(%{"backgroundActivity" => %{"profile" => "battery-saver"}}, version)

    assert %{"automaticGitFetchInterval" => 0, "pauseWhenOnBattery" => true} =
             BackgroundPolicy.settings()
  end
end
