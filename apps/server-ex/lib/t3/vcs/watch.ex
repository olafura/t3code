defmodule T3.Vcs.Watch do
  @moduledoc """
  One checkout's status for the clients watching it (`subscribeVcsStatus`).

  A watcher starts with its first subscriber and stops with its last. Subscribers
  get `{:t3_vcs, cwd, event}` messages shaped as `VcsStatusStreamEvent`, only when
  something changed. Local status is read again when told (`refresh/1`: a turn
  ended, a git action ran); remote status is fetched every `@remote_ms` while
  anyone watches, as the Node server does.
  """

  use GenServer, restart: :temporary

  alias T3.Vcs

  @registry T3.Vcs.Registry
  @supervisor T3.Vcs.Supervisor
  @remote_ms 30_000

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
       remote: Vcs.remote_status(cwd),
       timer: Process.send_after(self(), :fetch, @remote_ms)
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

  def handle_cast(:refresh, state) do
    {:noreply, update(state, Vcs.local_status(state.cwd), Vcs.remote_status(state.cwd))}
  end

  def handle_cast({:publish, local, remote}, state), do: {:noreply, update(state, local, remote)}

  @impl true
  def handle_info(:fetch, state) do
    state = update(state, state.local, Vcs.remote_status(state.cwd, fetch: true))
    {:noreply, %{state | timer: Process.send_after(self(), :fetch, @remote_ms)}}
  end

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
end
