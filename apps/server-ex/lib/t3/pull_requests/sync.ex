defmodule T3.PullRequests.Sync do
  @moduledoc """
  Keeps every thread link's host snapshot and native stack current
  (`thread.pull-request-link.sync`), as the Node server's `PullRequestSyncReactor`
  does, and links a stack's other layers to the thread with `source: "stack"`. A
  layer the user unlinked stays a tombstone and is never added again.

  A sweep a minute asks the host once per pull request however many threads link it,
  in one batch per host (`T3.PullRequests.summaries/1`), and only for links that are
  due: unsynced, open on an unsettled thread, or last read 15 minutes ago. Merged ones
  are left alone. The stack is read only when the snapshot changed. A newly linked
  pull request and `request/1` (after an action or a refresh) sync at once. `sweep/0`
  runs a sweep now and returns when it is done.
  """

  use GenServer

  require Logger

  alias T3.Orchestration
  alias T3.Projection.PullRequests, as: Links

  @interval 60_000
  @slow_interval 15 * 60_000
  @snapshot_fields ~w(state title headBranch baseBranch isDraft updatedAt closedAt mergedAt)
  @optional_fields ~w(author additions deletions changedFiles reviewDecision checksState mergeability)

  @doc "Options: `interval`, the sweep period in ms, or nil for no timer and no first sweep."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sweeps every due link now."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :infinity)

  @doc """
  Reads a pull request (`%{"repository", "number"}`, with `"host"` when known) again
  on the next sweep, which starts now, even when its snapshot is terminal.
  """
  def request(ref), do: GenServer.cast(__MODULE__, {:request, ref})

  @impl true
  def init(opts) do
    :ok = T3.Shell.subscribe(self())
    interval = Keyword.get(opts, :interval, @interval)
    if interval, do: send(self(), :tick)

    {:ok,
     %{
       interval: interval,
       unsynced: Map.new(threads(), &{&1["id"], unsynced(&1)}),
       last_synced: %{},
       requested: MapSet.new(),
       retry_stacks: MapSet.new(),
       pending: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, :ok, sweep(state, nil)}

  @impl true
  def handle_cast({:request, ref}, state) do
    repository = String.downcase(ref["repository"] || "")
    host = ref["host"] && String.downcase(ref["host"])

    keys =
      for row <- threads(),
          link <- Links.visible(row["pullRequests"] || []),
          %{"host" => link_host, "repository" => ^repository, "number" => number} <-
            [Links.normalize(link)],
          number == ref["number"] and host in [nil, link_host],
          uniq: true,
          do: Links.key(link)

    {:noreply, request_keys(state, keys)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = sweep(state, nil)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(:run, state),
    do: {:noreply, sweep(%{state | pending: MapSet.new()}, state.pending)}

  # A link that appears unsynced is read at once; one that stays unsynced waits for
  # the sweep, so a pull request the host cannot answer for is not asked every row.
  def handle_info({:t3_shell, {:rows, node, rows}}, state) when node == node() do
    {unsynced, keys} =
      for {id, {"thread", row}} <- rows, reduce: {state.unsynced, []} do
        {unsynced, keys} ->
          now = unsynced(row)
          new = MapSet.difference(now, Map.get(unsynced, id, MapSet.new()))
          {Map.put(unsynced, id, now), MapSet.to_list(new) ++ keys}
      end

    {:noreply, request_keys(%{state | unsynced: unsynced}, keys)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp request_keys(state, []), do: state

  defp request_keys(state, keys) do
    if MapSet.size(state.pending) == 0, do: send(self(), :run)

    %{
      state
      | requested: MapSet.union(state.requested, MapSet.new(keys)),
        pending: MapSet.union(state.pending, MapSet.new(keys))
    }
  end

  defp unsynced(row) do
    for link <- Links.visible(row["pullRequests"] || []),
        link["snapshot"] == nil,
        into: MapSet.new(),
        do: Links.key(link)
  end

  defp threads do
    for {{node, _}, {"thread", row}} <- T3.Shell.rows(),
        node == node() and row["deletedAt"] == nil,
        do: row
  end

  defp unsettled?(row), do: row["settledOverride"] != "settled" and row["settledAt"] == nil

  # `only` is nil for every due link, else the set of keys to read.
  defp sweep(state, only) do
    now = System.system_time(:millisecond)

    groups =
      for row <- threads(),
          row["archivedAt"] == nil,
          link <- Links.visible(row["pullRequests"] || []),
          reduce: %{} do
        groups -> Map.update(groups, Links.key(link), [{row, link}], &(&1 ++ [{row, link}]))
      end

    live = Map.keys(groups)

    state = %{
      state
      | last_synced: Map.take(state.last_synced, live),
        requested: MapSet.intersection(state.requested, MapSet.new(live)),
        retry_stacks: MapSet.intersection(state.retry_stacks, MapSet.new(live))
    }

    due =
      for {key, entries} <- groups,
          only == nil or MapSet.member?(only, key),
          due?(state, key, entries, now),
          do: {key, entries}

    refs =
      Map.new(due, fn {key, [{row, link} | _]} ->
        {key,
         link
         |> Links.normalize()
         |> Map.put("projectId", row["projectId"])}
      end)

    summaries = if refs == %{}, do: %{}, else: T3.PullRequests.summaries(Map.values(refs))

    {state, _linked} =
      Enum.reduce(due, {state, MapSet.new()}, fn {key, entries}, acc ->
        case summaries[refs[key]] do
          nil -> acc
          summary -> sync_group(acc, key, refs[key], entries, snapshot(summary), now)
        end
      end)

    state
  rescue
    error ->
      Logger.warning("pull request sync sweep failed: #{Exception.message(error)}")
      state
  end

  defp due?(state, key, entries, now) do
    snapshots = Enum.map(entries, fn {_row, link} -> link["snapshot"] end)
    last = state.last_synced[key]

    cond do
      MapSet.member?(state.requested, key) or MapSet.member?(state.retry_stacks, key) ->
        true

      nil in snapshots ->
        true

      Enum.all?(snapshots, &(&1["state"] == "merged")) ->
        false

      Enum.any?(entries, fn {row, link} ->
        link["snapshot"]["state"] == "open" and unsettled?(row)
      end) ->
        true

      true ->
        last == nil or now - last >= @slow_interval
    end
  end

  defp sync_group({state, linked}, key, ref, entries, fields, now) do
    needs_stack? =
      MapSet.member?(state.requested, key) or MapSet.member?(state.retry_stacks, key) or
        Enum.any?(entries, fn {_row, link} -> not same_snapshot?(link["snapshot"], fields) end)

    fetched = if needs_stack?, do: stack(ref), else: :unchanged

    if fetched == :error do
      {%{state | retry_stacks: MapSet.put(state.retry_stacks, key)}, linked}
    else
      # The host answered, so the cadence clock ticks even if a write below is refused.
      state = %{
        state
        | retry_stacks: MapSet.delete(state.retry_stacks, key),
          requested: MapSet.delete(state.requested, key),
          last_synced: Map.put(state.last_synced, key, now)
      }

      Enum.reduce(entries, {state, linked}, fn {row, link}, {state, linked} ->
        {ok?, linked} = sync_entry(row, link, fields, fetched, now, linked)

        {if(ok?, do: state, else: %{state | retry_stacks: MapSet.put(state.retry_stacks, key)}),
         linked}
      end)
    end
  end

  # Siblings are linked before the snapshot is written, so a terminal snapshot cannot
  # settle the thread before its stack is complete.
  defp sync_entry(row, link, fields, fetched, now, linked) do
    next_stack = if fetched == :unchanged, do: link["stack"], else: elem(fetched, 1)
    host = Links.normalize(link)["host"]
    present = MapSet.new(row["pullRequests"] || [], &Links.key/1)

    {ok?, linked} =
      for layer <- (fetched != :unchanged && next_stack && next_stack["layers"]) || [],
          layer_key = %{
            "host" => host,
            "repository" => link["repository"],
            "number" => layer["number"]
          },
          dedupe = {row["id"], Links.key(layer_key)},
          not MapSet.member?(linked, dedupe) and not MapSet.member?(present, Links.key(layer_key)),
          url = Links.sibling_url(link["url"], layer["number"]),
          reduce: {true, linked} do
        {ok?, linked} ->
          command =
            Map.merge(layer_key, %{
              "type" => "thread.pull-request.link",
              "commandId" => "server:pr-stack-link:#{row["id"]}:#{T3.Environment.uuid4()}",
              "threadId" => row["id"],
              "url" => url,
              "source" => "stack"
            })

          case Orchestration.dispatch(command) do
            {:ok, _} -> {ok?, MapSet.put(linked, dedupe)}
            {:error, _} -> {false, linked}
          end
      end

    if link["snapshot"] != nil and same_snapshot?(link["snapshot"], fields) and
         link["stack"] == next_stack do
      {ok?, linked}
    else
      result =
        Orchestration.dispatch(%{
          "type" => "thread.pull-request-link.sync",
          "commandId" => "server:pr-sync:#{row["id"]}:#{T3.Environment.uuid4()}",
          "threadId" => row["id"],
          "host" => host,
          "repository" => link["repository"],
          "number" => link["number"],
          "snapshot" => Map.put(fields, "syncedAt", T3.Projection.JS.iso(now)),
          "stack" => next_stack
        })

      {ok? and match?({:ok, _}, result), linked}
    end
  end

  # The native stack the pull request is in, as a link stores it; `:error` when the
  # host could not say.
  defp stack(ref) do
    case T3.PullRequests.stack(ref, false) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, stack} ->
        {:ok,
         stack
         |> Map.take(~w(id number url base))
         |> Map.merge(%{
           "kind" => "native",
           "layers" => Enum.map(stack["layers"] || [], &Map.take(&1, ~w(number headBranch state)))
         })}

      {:error, reason} ->
        Logger.warning("pull request stack lookup failed: #{inspect(reason)}")
        :error
    end
  end

  defp snapshot(summary) do
    summary
    |> Map.take(@snapshot_fields ++ @optional_fields)
    |> Map.put("isDraft", summary["isDraft"] == true)
    |> Map.put_new("closedAt", nil)
    |> Map.put_new("mergedAt", nil)
  end

  defp same_snapshot?(nil, _fields), do: false
  defp same_snapshot?(snapshot, fields), do: comparable(snapshot) == comparable(fields)

  defp comparable(snapshot) do
    author = snapshot["author"] || %{}

    Enum.map(@snapshot_fields ++ (@optional_fields -- ["author"]), &snapshot[&1]) ++
      [author["login"], author["avatarUrl"]]
  end
end
