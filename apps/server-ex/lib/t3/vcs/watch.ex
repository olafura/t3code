defmodule T3.Vcs.Watch do
  @moduledoc """
  One checkout's status for the clients watching it (`subscribeVcsStatus`).

  A watcher starts with its first subscriber and stops with its last. Subscribers
  get `{:t3_vcs, cwd, event}` messages shaped as `VcsStatusStreamEvent`, only when
  something changed. Local status is read again when told (`refresh/1`: a turn
  ended, a git action ran); remote status is fetched on the background activity
  settings' `automaticGitFetchInterval` (never at 0) while a client in front shows
  this checkout, as the Node server does (`T3.BackgroundPolicy`).
  """

  use GenServer, restart: :temporary

  alias T3.Vcs

  @registry T3.Vcs.Registry
  @supervisor T3.Vcs.Supervisor

  @doc "Adds `pid` as a subscriber; returns the snapshot event."
  def subscribe(cwd, pid) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, cwd}) do
      {:ok, watch} -> GenServer.call(watch, {:subscribe, pid}, 30_000)
      {:error, {:already_started, watch}} -> GenServer.call(watch, {:subscribe, pid}, 30_000)
    end
  end

  def unsubscribe(cwd, pid) do
    if watch = lookup(cwd), do: GenServer.cast(watch, {:unsubscribe, pid})
    :ok
  end

  @doc "Reads the checkout's status again if anyone watches it."
  def refresh(cwd) do
    if watch = lookup(cwd), do: GenServer.cast(watch, :refresh)
    :ok
  end

  @doc "Hands freshly read status to the watcher, if any, to publish."
  def publish(cwd, local, remote) do
    if watch = lookup(cwd), do: GenServer.cast(watch, {:publish, local, remote})
    :ok
  end

  def start_link(cwd),
    do: GenServer.start_link(__MODULE__, cwd, name: {:via, Registry, {@registry, cwd}})

  # Nil also when the registry is not running (a node started without watchers).
  defp lookup(cwd) do
    case Registry.lookup(@registry, cwd) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(cwd) do
    {:ok,
     %{
       cwd: cwd,
       subscribers: %{},
       local: Vcs.local_status(cwd),
       remote: Vcs.remote_status(cwd, pr: true),
       timer: schedule_fetch()
     }}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)

    {:reply, %{"_tag" => "snapshot", "local" => state.local, "remote" => state.remote},
     %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        {:noreply, state}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        stop_if_idle(%{state | subscribers: subscribers})
    end
  end

  # A local change keeps the pull request last looked up; the timer refreshes it.
  def handle_cast(:refresh, state) do
    remote =
      with %{} = remote <- Vcs.remote_status(state.cwd),
           do: Map.put(remote, "pr", state.remote && state.remote["pr"])

    {:noreply, update(state, Vcs.local_status(state.cwd), remote)}
  end

  def handle_cast({:publish, local, remote}, state), do: {:noreply, update(state, local, remote)}

  @impl true
  def handle_info(:fetch, state) do
    state =
      if T3.BackgroundPolicy.run_scope_work?(%{"type" => "vcs-status", "cwd" => state.cwd}),
        do: update(state, state.local, Vcs.remote_status(state.cwd, fetch: true, pr: true)),
        else: state

    {:noreply, %{state | timer: schedule_fetch()}}
  end

  def handle_info(:fetch_off, state), do: {:noreply, %{state | timer: schedule_fetch()}}

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.subscribers do
      %{^pid => ^ref} -> stop_if_idle(%{state | subscribers: Map.delete(state.subscribers, pid)})
      _ -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp update(state, local, remote) do
    if local != state.local, do: broadcast(state, %{"_tag" => "localUpdated", "local" => local})

    if remote != state.remote,
      do: broadcast(state, %{"_tag" => "remoteUpdated", "remote" => remote})

    %{state | local: local, remote: remote}
  end

  defp broadcast(state, event) do
    for {pid, _} <- state.subscribers, do: send(pid, {:t3_vcs, state.cwd, event})
  end

  defp stop_if_idle(%{subscribers: subscribers} = state) when map_size(subscribers) == 0,
    do: {:stop, :normal, state}

  defp stop_if_idle(state), do: {:noreply, state}

  # Checked again every 30 s while fetching is off, so turning it on takes effect.
  defp schedule_fetch do
    case T3.BackgroundPolicy.settings()["automaticGitFetchInterval"] do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :fetch, ms)
      _ -> Process.send_after(self(), :fetch_off, 30_000)
    end
  end
end
