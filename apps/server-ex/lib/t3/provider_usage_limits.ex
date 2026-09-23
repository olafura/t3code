defmodule T3.ProviderUsageLimits do
  @moduledoc """
  Subscription quota on this node's Codex and Claude provider entries
  (`ServerProvider.usageLimits`), as the Node server reports it.

  A probe reads the whole picture: Codex's `account/rateLimits/read` from a
  short-lived `codex app-server`, Claude's `get_usage` from a short-lived `claude`
  session (`T3.ProviderUsageLimits.Codex`, `T3.ProviderUsageLimits.Claude`). Probes run
  at boot, on `server.refreshProviders` (`refresh/1`), and every
  `providerHealthRefreshInterval` while a client in front shows provider status. Turns
  fill in between: the thread runtimes pass on the rate-limit updates their
  providers stream (`update/2`, `claude_event/1`), which merge by window id.

  A probe that fails keeps the last good windows; `unsupported` (an API key account)
  replaces them. `T3.Environment.providers/0` reads the published limits from ETS, so
  it never waits on a probe, and every change makes clients read the provider list
  again (`T3.Settings.notify_providers/0`).

  `provider.consumeResetCredit` redeems a Codex reset credit here, or a hub
  account's through `T3.UsageLimitSources`.
  """

  use GenServer

  require Logger

  alias T3.ProviderUsageLimits.{Claude, Codex}

  @instances ["codex", "claudeAgent"]
  @kind_order %{"session" => 0, "weekly" => 1, "monthly" => 2, "other" => 3}
  @probe_timeout 30_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The published limits of one instance, or nil."
  def get(instance) do
    case :ets.lookup(__MODULE__, instance) do
      [{_, limits}] -> limits
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  A provider entry with its published `usageLimits`, and the signed-in account's
  email, type and label on its `auth` (clients merge one account seen on several
  environments by its email).
  """
  def put(%{"instanceId" => instance} = entry) do
    entry =
      case get(instance) do
        nil -> entry
        limits -> Map.put(entry, "usageLimits", limits)
      end

    case {lookup({:account, instance}), entry} do
      {%{} = account, %{"auth" => %{} = auth}} when map_size(account) > 0 ->
        Map.put(entry, "auth", Map.merge(auth, account))

      _ ->
        entry
    end
  end

  @doc "Records the account a probe saw for `instance` (`auth` fields)."
  def remember_account(instance, account),
    do: GenServer.cast(__MODULE__, {:account, instance, account})

  defp lookup(key) do
    case :ets.lookup(__MODULE__, key) do
      [{_, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Probes the given instances now and publishes what they report."
  def refresh(instances \\ @instances) do
    GenServer.call(__MODULE__, {:refresh, Enum.filter(instances, &(&1 in @instances))}, 60_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Merges a turn's sparse window update (`[ServerProviderUsageWindow]`) into `instance`."
  def update(_instance, []), do: :ok
  def update(instance, windows), do: GenServer.cast(__MODULE__, {:update, instance, windows})

  @doc "Merges a Claude `rate_limit_event`'s `rate_limit_info`."
  def claude_event(info), do: GenServer.cast(__MODULE__, {:claude_event, info})

  @doc "`provider.consumeResetCredit`."
  def consume_reset_credit(%{"sourceId" => _} = input),
    do: T3.UsageLimitSources.consume_reset_credit(input)

  def consume_reset_credit(%{"instanceId" => "codex"}) do
    if Codex.installed?(),
      do: GenServer.call(__MODULE__, :consume_codex, 90_000),
      else: setup_error("codex", "Provider instance not found.")
  end

  def consume_reset_credit(%{"instanceId" => instance}) do
    if Enum.any?(T3.Environment.providers(), &(&1["instanceId"] == instance)),
      do: setup_error(instance, "This provider does not bank reset credits."),
      else: setup_error(instance, "Provider instance not found.")
  end

  @doc """
  How often provider status (and quota) is re-read: the settings'
  `providerHealthRefreshInterval` in ms, or `:off` when it is zero.
  """
  def interval do
    case T3.BackgroundPolicy.settings()["providerHealthRefreshInterval"] do
      ms when is_number(ms) and ms > 0 -> round(ms)
      _ -> :off
    end
  end

  @doc "Whether a client in front shows provider status (`T3.BackgroundPolicy`)."
  def wanted?(instances \\ []) do
    Enum.any?(
      [
        %{"type" => "provider-status"}
        | for(i <- instances, do: %{"type" => "provider-status", "instanceId" => i})
      ],
      &T3.BackgroundPolicy.run_scope_work?/1
    )
  end

  # --- shaping -------------------------------------------------------------------

  @doc "`ServerProviderUsageLimits` with its windows in display order."
  def limits(checked_at, windows),
    do: %{"checkedAt" => checked_at, "windows" => Enum.sort_by(windows, &sort_key/1)}

  @doc "Limits that could not be read (`probeFailed`) or never can be (`unsupported`)."
  def unavailable(checked_at, reason, message \\ nil) do
    %{
      "checkedAt" => checked_at,
      "windows" => [],
      "unavailable" =>
        if(message, do: %{"reason" => reason, "message" => message}, else: %{"reason" => reason})
    }
  end

  @doc """
  Folds a sparse update into the published limits: windows upsert by id, and one that
  arrives without `resetsAt` or `windowDurationMins` keeps what was known. Returns
  `previous` itself when nothing changed, and leaves `unsupported` alone.
  """
  def merge(previous, [], _checked_at), do: previous
  def merge(%{"unavailable" => %{"reason" => "unsupported"}} = previous, _, _), do: previous

  def merge(previous, windows, checked_at) do
    known = Map.new((previous || %{})["windows"] || [], &{&1["id"], &1})

    {merged, changed} =
      Enum.reduce(windows, {known, false}, fn window, {acc, changed} ->
        existing = acc[window["id"]]

        next =
          window
          |> Map.update!("usedPercent", &clamp/1)
          |> keep(existing, "resetsAt")
          |> keep(existing, "windowDurationMins")

        if existing == next, do: {acc, changed}, else: {Map.put(acc, next["id"], next), true}
      end)

    if not changed and previous != nil and previous["unavailable"] == nil do
      previous
    else
      checked_at
      |> limits(Map.values(merged))
      |> put_present("resetCredits", (previous || %{})["resetCredits"])
    end
  end

  @doc "What to publish after a probe: a failed probe keeps the last good windows."
  def after_probe(%{} = published, %{"unavailable" => %{"reason" => "probeFailed"}})
      when not is_map_key(published, "unavailable"),
      do: published

  def after_probe(_published, probed), do: probed

  def clamp(value) when is_number(value), do: value |> max(0) |> min(100)
  def clamp(_), do: 0

  @doc "Epoch seconds as the ISO timestamp clients expect, or nil."
  def iso_from_seconds(value) when is_number(value) and value > 0,
    do: round(value * 1000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  def iso_from_seconds(_), do: nil

  @doc "An ISO timestamp normalised to UTC milliseconds, or nil."
  def iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        {us, _} = dt.microsecond
        DateTime.to_iso8601(%{dt | microsecond: {div(us, 1000) * 1000, 3}})

      _ ->
        nil
    end
  end

  def iso(_), do: nil

  @doc "Adds `key => value` unless the value is nil."
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  defp keep(window, existing, key) do
    if window[key] == nil and existing[key] != nil,
      do: Map.put(window, key, existing[key]),
      else: window
  end

  defp sort_key(window), do: {Map.get(@kind_order, window["kind"], 3), window["id"]}

  # --- server --------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    {:ok, %{claude_names: nil, redeem_key: nil}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    state = probe(state, @instances)
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call({:refresh, instances}, _from, state),
    do: {:reply, :ok, probe(state, instances)}

  # One redemption at a time, with one idempotency key kept until Codex reports an
  # outcome, so a retry after a timeout is the same attempt rather than a second credit.
  def handle_call(:consume_codex, _from, state) do
    key = state.redeem_key || T3.Environment.uuid4()

    case run(fn -> Codex.consume(key) end, 25_000) do
      {:ok, outcome} ->
        before = get("codex")
        state = probe(%{state | redeem_key: nil}, ["codex"])
        now = get("codex")

        if now == nil or now["checkedAt"] == (before || %{})["checkedAt"] or
             get_in(now, ["unavailable", "reason"]) == "probeFailed" do
          {:reply,
           setup_error(
             "codex",
             "The reset was applied, but Codex could not confirm the new limits. Refresh to check."
           ), state}
        else
          {:reply, {:ok, %{"outcome" => outcome}}, state}
        end

      failure ->
        Logger.warning("Codex reset credit redemption failed: #{inspect(failure)}")

        {:reply, setup_error("codex", "Codex could not redeem the reset credit."),
         %{state | redeem_key: key}}
    end
  end

  @impl true
  def handle_cast({:account, instance, account}, state) do
    if lookup({:account, instance}) != account do
      :ets.insert(__MODULE__, {{:account, instance}, account})
      T3.Settings.notify_providers()
    end

    {:noreply, state}
  end

  def handle_cast({:update, instance, windows}, state) do
    publish(instance, merge(get(instance), windows, T3.Orchestration.Entities.now()))
    {:noreply, state}
  end

  def handle_cast({:claude_event, info}, state) do
    case Claude.event_window(info, state.claude_names) do
      nil -> :ok
      window -> handle_cast({:update, "claudeAgent", [window]}, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      if wanted?(@instances) and interval() != :off, do: probe(state, @instances), else: state

    schedule()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule do
    ms = with :off <- interval(), do: 60_000
    Process.send_after(self(), :tick, ms)
  end

  defp probe(state, instances) do
    checked_at = T3.Orchestration.Entities.now()

    probes =
      for instance <- instances, installed?(instance) do
        {instance, Task.async(fn -> probe_instance(instance, checked_at) end)}
      end

    results = Task.yield_many(Enum.map(probes, &elem(&1, 1)), @probe_timeout)

    Enum.zip(probes, results)
    |> Enum.reduce(state, fn {{instance, task}, {_, result}}, state ->
      if result == nil, do: Task.shutdown(task, :brutal_kill)

      {probed, state} =
        case result do
          # A failed read keeps the bucket name the last good one saw.
          {:ok, {%{"unavailable" => %{"reason" => "probeFailed"}} = limits, _}} -> {limits, state}
          {:ok, {%{} = limits, names}} -> {limits, %{state | claude_names: names}}
          {:ok, %{} = limits} -> {limits, state}
          _ -> {unavailable(checked_at, "probeFailed"), state}
        end

      publish(instance, after_probe(get(instance), probed))
      state
    end)
  end

  defp probe_instance("codex", checked_at), do: Codex.probe(checked_at)
  defp probe_instance("claudeAgent", checked_at), do: Claude.probe(checked_at)

  defp installed?("codex"), do: Codex.installed?()
  defp installed?("claudeAgent"), do: Claude.installed?()

  defp publish(instance, limits) do
    if limits != get(instance) do
      :ets.insert(__MODULE__, {instance, limits})
      T3.Settings.notify_providers()
    end
  end

  # Runs `fun` in a task, so a provider process that dies cannot take this one along.
  defp run(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp setup_error(instance, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => instance,
       "operation" => "consume-reset-credit",
       "detail" => detail,
       "message" => detail
     }}
  end
end
