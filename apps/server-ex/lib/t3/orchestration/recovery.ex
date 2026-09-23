defmodule T3.Orchestration.Recovery do
  @moduledoc """
  Settles turns a node was running when it stopped. Provider processes die with
  the node, so at boot every run still active on this node's threads is ended as
  interrupted, with its items, prompts, and provider thread; otherwise the thread
  would stay "running" and refuse its next message.

  Only threads whose sidebar row shows an active run are opened.
  """

  require Logger

  alias T3.Orchestration.Entities
  alias T3.{Patch, StreamState}

  @active_runs ~w(preparing queued starting running waiting)
  @active ~w(pending preparing queued starting running waiting active)

  @doc "Settles every interrupted turn on this node; returns the threads touched."
  def run do
    threads =
      for {{node, thread_id}, {"thread", row}} <- T3.Shell.rows(),
          node == node(),
          row["status"] in @active_runs,
          settle(thread_id) > 0,
          do: thread_id

    if threads != [], do: Logger.info("settled interrupted turns in #{length(threads)} threads")
    threads
  end

  @doc "Settles one thread's interrupted turn; returns how many entities changed."
  def settle(thread_id) do
    T3.Streams.transact(thread_id, :thread, fn state ->
      changes = changes(state, Entities.now())
      {changes, length(changes)}
    end)
  end

  defp changes(state, at) do
    done = %{"status" => "interrupted", "completedAt" => at}

    for {kind, fun} <- [
          {"run",
           fn run ->
             cond do
               # Queued messages wait for the user to resume the queue.
               run["status"] == "queued" -> Map.put(run, "queueHeld", true)
               run["status"] in @active_runs -> Map.merge(run, done)
               true -> nil
             end
           end},
          {"run-attempt", &if(&1["status"] in @active, do: Map.merge(&1, done))},
          {"provider-turn", &if(&1["status"] in @active, do: Map.merge(&1, done))},
          {"node", &if(&1["status"] in @active, do: Map.merge(&1, done))},
          {"turn-item",
           &if(&1["status"] in @active,
             do:
               Map.merge(&1, %{
                 "status" => "interrupted",
                 "completedAt" => at,
                 "updatedAt" => at,
                 "streaming" => false
               })
           )},
          {"message",
           &if(&1["streaming"] == true,
             do: Map.merge(&1, %{"streaming" => false, "updatedAt" => at})
           )},
          {"runtime-request",
           &if(&1["status"] == "pending",
             do: Map.merge(&1, %{"status" => "cancelled", "resolvedAt" => at})
           )},
          {"provider-thread",
           &if(&1["status"] == "active",
             do: Map.merge(&1, %{"status" => "idle", "updatedAt" => at})
           )}
        ],
        {id, entity} <- StreamState.get(state, kind),
        next = fun.(entity),
        next != nil,
        patch = Patch.diff(entity, next),
        patch != :unchanged,
        do: {kind, id, patch}
  end
end
