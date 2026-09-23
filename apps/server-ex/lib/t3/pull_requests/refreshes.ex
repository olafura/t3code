defmodule T3.PullRequests.Refreshes do
  @moduledoc """
  A revision that moves whenever a pull request is changed or refreshed through this
  node (`pullRequests.subscribeRefreshes`). Subscribers get the current revision,
  then `{:t3_pull_request_refreshes, node, revision}` on every bump, and refetch
  what they show.
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Adds `pid` as a subscriber; returns `{:ok, revision}`."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  @doc "Tells every subscriber to read again."
  def bump, do: GenServer.cast(__MODULE__, :bump)

  @impl true
  def init(nil), do: {:ok, %{revision: 0, watchers: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, state.revision}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_cast(:bump, state) do
    revision = state.revision + 1
    for {pid, _} <- state.watchers, do: send(pid, {:t3_pull_request_refreshes, node(), revision})
    {:noreply, %{state | revision: revision}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}
end
