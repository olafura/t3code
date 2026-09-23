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

  @doc false
  # Settles before the node takes requests, so no client sees a stale "running".
  def start_link do
    run()
    :ignore
  end

  @doc """
  Settles every interrupted turn on this node; returns the threads touched. Runs
  that could go on are kept for `continue/0`.
  """
  def run do
    settled =
      for {{node, thread_id}, {"thread", row}} <- T3.Shell.rows(),
          node == node(),
          row["status"] in @active_runs,
          {count, continuable} = settle(thread_id),
          count > 0,
          do: {thread_id, continuable}

    :persistent_term.put(
      {__MODULE__, :continuable},
      for({thread_id, %{} = run} <- settled, do: {thread_id, run})
    )

    if settled != [], do: Logger.info("settled interrupted turns in #{length(settled)} threads")
    Enum.map(settled, &elem(&1, 0))
  end

  @doc """
  Settles one thread's interrupted turn: `{entities changed, run}`, where `run` is
  the one that was mid-turn on a provider thread that can resume, or nil.
  """
  def settle(thread_id) do
    T3.Streams.transact(thread_id, :thread, fn state ->
      changes = changes(state, Entities.now())
      {changes, {length(changes), continuable(state)}}
    end)
  end

  @doc """
  Asks each thread whose turn the restart cut off to continue, when its project's
  `continueThreadsAfterServerUpdate` is on and nothing newer was sent, as the Node
  server does. Runs once the node can start turns.
  """
  def continue do
    runs = :persistent_term.get({__MODULE__, :continuable}, [])
    :persistent_term.erase({__MODULE__, :continuable})

    for {thread_id, run} <- runs,
        {"thread", thread} <- [T3.Shell.row(node(), thread_id)],
        thread["archivedAt"] == nil and thread["deletedAt"] == nil,
        T3.Settings.for_project(thread["projectId"])["continueThreadsAfterServerUpdate"] == true,
        latest?(thread_id, run) do
      T3.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "command:restart-continuation:#{run["id"]}",
        "threadId" => thread_id,
        "messageId" => "message:restart-continuation:#{run["id"]}",
        "text" => "Continue where you left off.",
        "attachments" => [],
        "modelSelection" => run["modelSelection"],
        "dispatchMode" => %{"type" => "start_immediately"},
        "createdBy" => "agent",
        "creationSource" => "server"
      })
    end

    :ok
  end

  # A message the user sent since takes precedence.
  defp latest?(thread_id, run) do
    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
    Enum.all?(StreamState.list(state, "run"), &(&1["ordinal"] <= run["ordinal"]))
  end

  defp continuable(state) do
    with %{"status" => "running"} = run <-
           state |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"], fn -> nil end),
         %{"nativeThreadRef" => %{}} <-
           StreamState.get(state, "provider-thread")[run["providerThreadId"]] do
      run
    else
      _ -> nil
    end
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
