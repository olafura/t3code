defmodule T3.BackgroundPolicy do
  @moduledoc """
  When a node may do background work nobody is looking at, as the Node server's
  BackgroundPolicy decides it.

  Clients report what they show and whether they are in front
  (`server.reportClientActivity`): each report is a lease on some scopes (a
  checkout's VCS status, a provider's status, a thread) that expires unless
  renewed, and goes with its socket. The desktop reports its host's power
  (`server.reportHostPowerState`). Periodic work asks `run_scope_work?/1`: a
  foreground client (any client, in the "performance" profile) must want the scope,
  and neither that client nor the host may be constrained by the background
  activity settings (locked, low power, on battery, hot).
  """

  use GenServer

  @default_ttl 45_000
  @max_ttl 120_000
  @max_leases_per_client 16
  @presets %{
    "performance" => %{
      "automaticGitFetchInterval" => 15_000,
      "providerHealthRefreshInterval" => 60_000,
      "pauseWhenHostLocked" => true,
      "pauseWhenHostLowPower" => false,
      "pauseWhenClientLowPower" => false,
      "pauseWhenOnBattery" => false
    },
    "balanced" => %{
      "automaticGitFetchInterval" => 30_000,
      "providerHealthRefreshInterval" => 300_000,
      "pauseWhenHostLocked" => true,
      "pauseWhenHostLowPower" => true,
      "pauseWhenClientLowPower" => true,
      "pauseWhenOnBattery" => false
    },
    "battery-saver" => %{
      "automaticGitFetchInterval" => 0,
      "providerHealthRefreshInterval" => 900_000,
      "pauseWhenHostLocked" => true,
      "pauseWhenHostLowPower" => true,
      "pauseWhenClientLowPower" => true,
      "pauseWhenOnBattery" => true
    }
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The background activity settings in effect: a profile's preset with any custom
  overrides, durations in milliseconds, plus `"profile"`.
  """
  def settings(server_settings \\ T3.Settings.settings()) do
    activity = server_settings["backgroundActivity"] || %{}

    profile =
      case activity["profile"] do
        "custom" -> activity["baseProfile"] || "balanced"
        profile when is_map_key(@presets, profile) -> profile
        _ -> "balanced"
      end

    overrides = if activity["profile"] == "custom", do: activity["overrides"] || %{}, else: %{}

    @presets[profile]
    |> Map.merge(Map.take(overrides, Map.keys(@presets[profile])))
    |> Map.put("profile", profile)
  end

  @doc "Records a client's activity report for its socket (`pid`) and session."
  def report_client_activity(session, pid, input),
    do: GenServer.cast(__MODULE__, {:lease, session, pid, input})

  def report_host_power(snapshot), do: GenServer.cast(__MODULE__, {:power, snapshot})

  @doc "`server.getBackgroundPolicy`: `BackgroundPolicySnapshot`."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, {:noproc, _} -> compute(%{}, unknown_power(), settings(), now_ms())
  end

  @doc """
  Whether periodic work for `scope` (`%{"type" => "vcs-status", "cwd" => cwd}` and
  so on) should run now.
  """
  def run_scope_work?(scope) do
    GenServer.call(__MODULE__, {:scope, scope})
  catch
    # A node without the policy (tools, tests) does its work.
    :exit, {:noproc, _} -> true
  end

  # --- server ------------------------------------------------------------------------

  @impl true
  def init(nil), do: {:ok, %{leases: %{}, power: unknown_power(), monitors: %{}}}

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, compute(state.leases, state.power, settings(), now_ms()), state}

  def handle_call({:scope, scope}, _from, state) do
    settings = settings()
    now = now_ms()

    allowed =
      not host_constrained?(state.power, settings) and
        Enum.any?(Map.values(state.leases), fn lease ->
          active?(lease, now) and has_scope?(lease, scope) and
            not client_constrained?(lease, settings) and
            (settings["profile"] == "performance" or foreground?(lease, now))
        end)

    {:reply, allowed, state}
  end

  @impl true
  def handle_cast({:lease, session, pid, input}, state) do
    now = now_ms()
    ttl = input["ttlMs"] |> then(&if(is_number(&1), do: &1, else: @default_ttl))
    ttl = ttl |> max(1_000) |> min(@max_ttl) |> round()
    rpc_client = inspect(pid)

    lease =
      input
      |> Map.take(
        ~w(clientId clientKind visible focused recentlyInteracted appState lowPowerMode batteryState networkType scopes)
      )
      |> Map.merge(%{
        "sessionId" => session || "anonymous",
        "rpcClientId" => rpc_client,
        "updatedAt" => iso(now),
        "expiresAt" => iso(now + ttl),
        :expires_ms => now + ttl,
        :updated_ms => now,
        :pid => pid
      })

    key = {pid, input["clientId"]}

    leases =
      state.leases
      |> Map.reject(fn {_key, lease} -> not active?(lease, now) end)
      |> cap(pid, key)
      |> Map.put(key, lease)

    monitors =
      Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)

    {:noreply, %{state | leases: leases, monitors: monitors}}
  end

  def handle_cast({:power, snapshot}, state) do
    # A report older than the one held (reordered on the way) is dropped.
    newer =
      with {:ok, at, _} <- DateTime.from_iso8601(snapshot["updatedAt"] || ""),
           {:ok, held, _} <- DateTime.from_iso8601(state.power["updatedAt"] || "") do
        DateTime.compare(at, held) != :lt
      else
        _ -> true
      end

    {:noreply, if(newer, do: %{state | power: snapshot}, else: state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    leases = Map.reject(state.leases, fn {{owner, _}, _} -> owner == pid end)
    {:noreply, %{state | leases: leases, monitors: Map.delete(state.monitors, pid)}}
  end

  # A client connection keeps at most 16 leases; the oldest goes first.
  defp cap(leases, pid, key) do
    own = for {{owner, _} = k, lease} <- leases, owner == pid, k != key, do: {k, lease}

    if length(own) >= @max_leases_per_client do
      {oldest, _} = Enum.min_by(own, fn {_k, lease} -> lease.updated_ms end)
      Map.delete(leases, oldest)
    else
      leases
    end
  end

  # --- rules ---------------------------------------------------------------------------

  defp active?(lease, now), do: lease.expires_ms > now

  defp foreground?(lease, now),
    do:
      active?(lease, now) and lease["visible"] == true and
        (lease["focused"] == true or lease["recentlyInteracted"] == true)

  defp has_scope?(lease, scope),
    do: Enum.any?(lease["scopes"] || [], &(scope_key(&1) == scope_key(scope)))

  defp scope_key(%{"type" => type} = scope) when type in ["vcs-status", "git-refs"],
    do: "#{type}:#{scope["cwd"]}"

  defp scope_key(%{"type" => "thread", "threadId" => id}), do: "thread:#{id}"

  defp scope_key(%{"type" => "provider-status"} = scope),
    do:
      if(scope["instanceId"],
        do: "provider-status:#{scope["instanceId"]}",
        else: "provider-status"
      )

  defp scope_key(%{"type" => type}), do: type

  defp host_constrained?(power, settings) do
    cond do
      power["stale"] == true -> false
      power["suspended"] == true -> true
      settings["pauseWhenHostLocked"] and power["locked"] == "true" -> true
      power["thermalState"] in ["serious", "critical"] -> true
      settings["pauseWhenHostLowPower"] and power["lowPowerMode"] == "true" -> true
      true -> settings["pauseWhenOnBattery"] and power["onBattery"] == "true"
    end
  end

  defp client_constrained?(lease, settings) do
    (settings["pauseWhenClientLowPower"] and lease["lowPowerMode"] == "true") or
      (settings["pauseWhenOnBattery"] and lease["batteryState"] == "unplugged")
  end

  defp compute(leases, power, settings, now) do
    active = for {_key, lease} <- leases, active?(lease, now), do: lease
    foreground = Enum.filter(active, &foreground?(&1, now))

    %{
      "hostPower" => power,
      "leases" => Enum.map(active, &Map.drop(&1, [:expires_ms, :updated_ms, :pid])),
      "activeForegroundLeaseCount" => length(foreground),
      "activeScopeKeys" =>
        active
        |> Enum.flat_map(&(&1["scopes"] || []))
        |> Enum.map(&scope_key/1)
        |> Enum.uniq()
        |> Enum.sort(),
      "shouldRunOpportunisticWork" =>
        Enum.any?(foreground, &(not client_constrained?(&1, settings))) and
          not host_constrained?(power, settings),
      "updatedAt" => iso(now)
    }
  end

  defp unknown_power do
    %{
      "source" => "unknown",
      "idle" => "unknown",
      "idleSeconds" => nil,
      "locked" => "unknown",
      "suspended" => false,
      "onBattery" => "unknown",
      "lowPowerMode" => "unknown",
      "thermalState" => "unknown",
      "stale" => true,
      "updatedAt" => iso(now_ms())
    }
  end

  defp now_ms, do: System.system_time(:millisecond)
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
