defmodule T3.Preview do
  @moduledoc """
  The desktop's in-app browser tabs, per thread (`preview.*`). The desktop owns
  the actual webview and reports navigation here; the node keeps each tab's
  snapshot so it survives reconnects and reaches every window. Tabs live in
  memory: `serverEpoch` changes on restart and `revision` orders every change.
  Clients normalize URLs (`normalizePreviewUrl`) before sending them.

  Watchers (client sockets) get `{:t3_preview, node, PreviewEvent}`.
  """

  use GenServer

  @fill %{"_tag" => "fill"}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def open(input), do: GenServer.call(__MODULE__, {:open, input})
  def navigate(input), do: GenServer.call(__MODULE__, {:navigate, input})
  def report_status(input), do: GenServer.call(__MODULE__, {:report_status, input})
  def resize(input), do: GenServer.call(__MODULE__, {:resize, input})
  def refresh(input), do: GenServer.call(__MODULE__, {:refresh, input})
  def close(input), do: GenServer.call(__MODULE__, {:close, input})
  def list(input), do: GenServer.call(__MODULE__, {:list, input})
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  @impl true
  def init(nil),
    do: {:ok, %{epoch: T3.Environment.uuid4(), revision: 0, sessions: %{}, watchers: %{}}}

  @impl true
  def handle_call({:open, input}, _from, state) do
    tab = "tab-" <> T3.Environment.uuid4()
    at = now()

    snapshot =
      %{
        "threadId" => input["threadId"],
        "tabId" => tab,
        "navStatus" =>
          if(input["url"],
            do: %{"_tag" => "Loading", "url" => input["url"], "title" => ""},
            else: %{"_tag" => "Idle"}
          ),
        "canGoBack" => false,
        "canGoForward" => false,
        "viewport" => input["viewport"] || @fill,
        "updatedAt" => at
      }
      |> then(&if(input["profileId"], do: Map.put(&1, "profileId", input["profileId"]), else: &1))

    state = put(state, snapshot) |> emit(snapshot, "opened", %{"snapshot" => snapshot})
    {:reply, {:ok, snapshot}, state}
  end

  def handle_call({:navigate, input}, _from, state) do
    with_session(state, input, fn snapshot ->
      title =
        input["resolvedTitle"] ||
          if(snapshot["navStatus"]["_tag"] == "Idle",
            do: "",
            else: snapshot["navStatus"]["title"]
          )

      next =
        Map.merge(snapshot, %{
          "navStatus" => %{"_tag" => "Success", "url" => input["url"], "title" => title},
          "updatedAt" => now()
        })

      {next, {"navigated", %{"snapshot" => next}}, next}
    end)
  end

  def handle_call({:report_status, input}, _from, state) do
    with_session(state, input, fn snapshot ->
      next =
        snapshot
        |> Map.merge(Map.take(input, ~w(navStatus canGoBack canGoForward)))
        |> Map.put("updatedAt", now())

      event =
        case input["navStatus"] do
          %{"_tag" => "LoadFailed"} = failed ->
            {"failed", Map.take(failed, ~w(url title code description))}

          _ ->
            {"navigated", %{"snapshot" => next}}
        end

      {next, event, nil}
    end)
  end

  def handle_call({:resize, input}, _from, state) do
    with_session(state, input, fn snapshot ->
      next = Map.merge(snapshot, %{"viewport" => input["viewport"], "updatedAt" => now()})
      {next, {"resized", %{"snapshot" => next}}, next}
    end)
  end

  # The desktop reloads the page and reports how it went.
  def handle_call({:refresh, input}, _from, state),
    do: with_session(state, input, fn snapshot -> {snapshot, nil, nil} end)

  def handle_call({:close, %{"threadId" => thread} = input}, _from, state) do
    closing =
      for {{^thread, tab}, snapshot} <- state.sessions,
          input["tabId"] in [nil, tab],
          do: snapshot

    state =
      Enum.reduce(closing, state, fn snapshot, state ->
        %{state | sessions: Map.delete(state.sessions, {thread, snapshot["tabId"]})}
        |> emit(snapshot, "closed", %{})
      end)

    {:reply, {:ok, nil}, state}
  end

  def handle_call({:list, %{"threadId" => thread}}, _from, state) do
    sessions =
      for({{^thread, _}, snapshot} <- state.sessions, do: snapshot)
      |> Enum.sort_by(& &1["updatedAt"])

    {:reply,
     {:ok, %{"sessions" => sessions, "serverEpoch" => state.epoch, "revision" => state.revision}},
     state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  # Applies `fun` to the tab's snapshot: `{next, event | nil, reply}`.
  defp with_session(state, %{"threadId" => thread, "tabId" => tab}, fun) do
    case state.sessions[{thread, tab}] do
      nil ->
        {:reply,
         {:error, %{"_tag" => "PreviewSessionLookupError", "threadId" => thread, "tabId" => tab}},
         state}

      snapshot ->
        {next, event, reply} = fun.(snapshot)
        state = put(state, next)

        state =
          case event do
            nil -> state
            {type, fields} -> emit(state, next, type, fields)
          end

        {:reply, {:ok, reply}, state}
    end
  end

  defp put(state, snapshot),
    do: %{
      state
      | sessions: Map.put(state.sessions, {snapshot["threadId"], snapshot["tabId"]}, snapshot)
    }

  defp emit(state, snapshot, type, fields) do
    revision = state.revision + 1

    event =
      Map.merge(fields, %{
        "type" => type,
        "threadId" => snapshot["threadId"],
        "tabId" => snapshot["tabId"],
        "createdAt" => now(),
        "serverEpoch" => state.epoch,
        "revision" => revision
      })

    for {pid, _} <- state.watchers, do: send(pid, {:t3_preview, node(), event})
    %{state | revision: revision}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
