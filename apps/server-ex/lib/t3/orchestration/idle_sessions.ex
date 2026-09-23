defmodule T3.Orchestration.IdleSessions do
  @moduledoc """
  Stops provider processes (Codex app-servers, Claude and ACP agents) that have sat
  idle, as the Node server releases idle sessions: after 30 minutes without a turn,
  or up to 4 hours while the provider still has background tasks running. The
  session is marked stopped and the next run starts it again, resuming the
  provider's thread (`T3.Orchestration.release_session/1`).

  A check runs every few minutes over the threads that have a live process.
  """

  use GenServer

  @registries [T3.Codex.Registry, T3.Claude.Registry, T3.Acp.Registry]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Releases every idle session now; returns the released thread ids."
  def check, do: GenServer.call(__MODULE__, :check, :timer.minutes(1))

  @impl true
  def init(nil) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call(:check, _from, state), do: {:reply, release_idle(), state}

  @impl true
  def handle_info(:check, state) do
    release_idle()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    case Application.get_env(:t3, :idle_session_check_ms, :timer.minutes(5)) do
      nil -> :ok
      ms -> Process.send_after(self(), :check, ms)
    end
  end

  defp release_idle do
    now = System.system_time(:millisecond)
    idle_ms = Application.get_env(:t3, :session_idle_ms, :timer.minutes(30))
    pinned_ms = Application.get_env(:t3, :session_max_pin_ms, :timer.hours(4))

    for registry <- @registries,
        Process.whereis(registry) != nil,
        thread_id <- Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        idle?(T3.Shell.row(node(), thread_id), now, idle_ms, pinned_ms),
        T3.Orchestration.release_session(thread_id) == :ok,
        uniq: true,
        do: thread_id
  end

  defp idle?({"thread", row}, now, idle_ms, pinned_ms) do
    quiet = now - last_activity(row)
    background = (row["pendingBackgroundTasks"] || []) != []

    row["activeRunId"] == nil and row["pendingRuntimeRequest"] == nil and
      quiet >= if(background, do: pinned_ms, else: idle_ms)
  end

  # A process with no thread row (a deleted thread) has nothing to wait for.
  defp idle?(nil, _now, _idle_ms, _pinned_ms), do: true
  defp idle?(_other, _now, _idle_ms, _pinned_ms), do: false

  defp last_activity(row) do
    ~w(createdAt latestUserMessageAt latestRunRequestedAt latestRunStartedAt latestRunCompletedAt)
    |> Enum.flat_map(fn key ->
      with at when is_binary(at) <- row[key],
           {:ok, time, _} <- DateTime.from_iso8601(at) do
        [DateTime.to_unix(time, :millisecond)]
      else
        _ -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
  end
end
