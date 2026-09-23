defmodule T3.PreviewAutomation do
  @moduledoc """
  Routes agents' browser actions (`preview_*` MCP tools) to a desktop client's
  browser panel, as the Node server's PreviewAutomationBroker does.

  A desktop registers as a host with the `previewAutomation` shape (`connect/2`),
  which streams it requests; it answers each with `previewAutomation.respond`
  (`respond/1`) and says when its window has focus (`focus_host/1`). An agent's
  call (`invoke/4`) goes to the host its provider session last used, so a
  multi-step interaction stays in one browser, or else to the most capable,
  focused, most recently focused host. The tab a session last touched is its
  current tab.

  A request unanswered within its timeout drops that host's connection, whose
  stream then ends so the desktop registers again; actions are never replayed.
  A host that registers again under the same client id replaces its old
  connection, which just stops getting requests.
  """

  use GenServer

  @v1_operations ~w(status open navigate snapshot click type press scroll evaluate waitFor recordingStart recordingStop)
  @default_timeout 15_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Registers `pid` (a socket) as the host `host` (`PreviewAutomationHost`). It gets
  `{:t3_preview_automation, node, client_id, event | :end}`, the first event being
  `connected`.
  """
  def connect(host, pid), do: GenServer.call(__MODULE__, {:connect, host, pid})

  @doc "Drops `pid`'s registration as `client_id`, as when its stream closes."
  def disconnect(client_id, pid), do: GenServer.cast(__MODULE__, {:disconnect, client_id, pid})

  def focus_host(host), do: GenServer.cast(__MODULE__, {:focus, host})
  def respond(response), do: GenServer.cast(__MODULE__, {:respond, response})

  @doc """
  Runs `operation` for the agent of `scope` (`%{thread_id, instance}`) on a host:
  `{:ok, result}` or `{:error, %{"_tag" => tag, ...}}`. Options: `:tab_id` (an
  explicit tab), `:timeout_ms`, and `update_current_tab: false` for background
  reads that must not move the session's current tab.
  """
  def invoke(scope, operation, input, opts \\ []) do
    timeout = opts[:timeout_ms] || @default_timeout
    GenServer.call(__MODULE__, {:invoke, scope, operation, input, opts}, timeout + 5_000)
  catch
    :exit, {:noproc, _} -> {:error, no_host(scope, operation)}
  end

  @doc "An error's message for an agent."
  def message(%{"_tag" => tag} = error) do
    op = error["operation"]
    client = error["clientId"]

    case tag do
      "PreviewAutomationNoAvailableHostError" ->
        "No preview automation host is available for #{op}. Open T3 Code's desktop app with this thread's browser panel available."

      "PreviewAutomationUnsupportedClientError" ->
        "Preview automation client #{client} does not support #{op}."

      "PreviewAutomationTabNotFoundError" ->
        if error["tabId"],
          do: "Preview tab #{error["tabId"]} was not found for #{op}.",
          else: "No active preview tab was found for #{op}."

      "PreviewAutomationTimeoutError" ->
        "Preview automation #{op} timed out after #{error["timeoutMs"]}ms."

      "PreviewAutomationClientDisconnectedError" ->
        "Preview automation client #{client} disconnected during #{op}."

      "PreviewAutomationMalformedResponseError" ->
        "Preview automation client #{client} returned a malformed response for #{op}."

      _ ->
        error["remoteMessage"] || "Preview automation #{op} failed on client #{client}."
    end
  end

  # --- server --------------------------------------------------------------------

  @impl true
  def init(nil) do
    {:ok, %{clients: %{}, assignments: %{}, pending: %{}, seq: 0, focus_seq: 0}}
  end

  @impl true
  def handle_call({:connect, host, pid}, _from, state) do
    client_id = host["clientId"]
    state = drop_connection(state, client_id, :replaced)
    connection_id = T3.Environment.uuid4()
    focus_seq = state.focus_seq + 1

    client = %{
      connection_id: connection_id,
      pid: pid,
      monitor: Process.monitor(pid),
      operations: MapSet.new(host["supportedOperations"] || @v1_operations),
      focused: false,
      focus_order: focus_seq
    }

    send(pid, {:t3_preview_automation, node(), client_id, connected(connection_id)})

    {:reply, {:ok, connection_id},
     %{state | clients: Map.put(state.clients, client_id, client), focus_seq: focus_seq}}
  end

  def handle_call({:invoke, scope, operation, input, opts}, from, state) do
    key = {scope.thread_id, scope.instance}
    assigned = live_assignment(state, key)

    host =
      case assigned do
        {client_id, client, _tab} ->
          if MapSet.member?(client.operations, operation), do: {client_id, client}

        nil ->
          state.clients
          |> Enum.filter(fn {_id, client} -> MapSet.member?(client.operations, operation) end)
          |> Enum.max_by(
            fn {_id, c} -> {MapSet.size(c.operations), c.focused, c.focus_order} end,
            fn -> nil end
          )
      end

    case host do
      nil ->
        {:reply, {:error, no_host(scope, operation)},
         %{
           state
           | assignments:
               if(assigned, do: state.assignments, else: Map.delete(state.assignments, key))
         }}

      {client_id, client} ->
        tab =
          case assigned do
            {_, _, %{tab_id: tab}} -> tab
            _ -> nil
          end

        timeout = opts[:timeout_ms] || @default_timeout
        request_id = "preview-#{state.seq}"
        tab_id = opts[:tab_id] || tab

        context =
          %{
            "operation" => operation,
            "threadId" => scope.thread_id,
            "providerInstanceId" => scope.instance,
            "clientId" => client_id,
            "connectionId" => client.connection_id,
            "requestId" => request_id,
            "timeoutMs" => timeout
          }
          |> put_present("tabId", tab_id)

        request =
          %{
            "requestId" => request_id,
            "threadId" => scope.thread_id,
            "tabIdExplicit" => opts[:tab_id] != nil,
            "operation" => operation,
            "input" => input,
            "timeoutMs" => timeout
          }
          |> put_present("tabId", tab_id)

        send(
          client.pid,
          {:t3_preview_automation, node(), client_id,
           %{"type" => "request", "connectionId" => client.connection_id, "request" => request}}
        )

        pending = %{
          from: from,
          client_id: client_id,
          connection_id: client.connection_id,
          context: context,
          key: key,
          seq: state.seq,
          explicit_tab: opts[:tab_id],
          update_tab: Keyword.get(opts, :update_current_tab, true),
          timer: Process.send_after(self(), {:timeout, request_id}, timeout)
        }

        assignment = %{
          client_id: client_id,
          connection_id: client.connection_id,
          tab_id: tab,
          tab_seq: (assigned && elem(assigned, 2)[:tab_seq]) || -1
        }

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, request_id, pending),
             assignments: Map.put(state.assignments, key, assignment),
             seq: state.seq + 1
         }}
    end
  end

  @impl true
  def handle_cast({:disconnect, client_id, pid}, state) do
    case state.clients[client_id] do
      %{pid: ^pid} -> {:noreply, drop_connection(state, client_id, :closed)}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:focus, %{"connectionId" => connection_id} = host}, state) do
    case state.clients[host["clientId"]] do
      %{connection_id: ^connection_id} = client ->
        focused = host["focused"] == true
        focus_seq = if focused, do: state.focus_seq + 1, else: state.focus_seq

        client = %{
          client
          | focused: focused,
            focus_order: if(focused, do: focus_seq, else: client.focus_order)
        }

        {:noreply,
         %{
           state
           | clients: Map.put(state.clients, host["clientId"], client),
             focus_seq: focus_seq
         }}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:respond, response}, state) do
    %{"clientId" => client_id, "connectionId" => connection_id} = response

    case Map.pop(state.pending, response["requestId"]) do
      {%{client_id: ^client_id, connection_id: ^connection_id} = pending, rest} ->
        Process.cancel_timer(pending.timer)
        state = %{state | pending: rest}

        if response["ok"] == true do
          result = response["result"]
          GenServer.reply(pending.from, {:ok, result})
          {:noreply, track_tab(state, pending, result)}
        else
          GenServer.reply(
            pending.from,
            {:error, remote_error(pending.context, response["error"])}
          )

          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case state.pending[request_id] do
      nil ->
        {:noreply, state}

      pending ->
        GenServer.reply(
          pending.from,
          {:error, tagged("PreviewAutomationTimeoutError", pending.context)}
        )

        state = %{state | pending: Map.delete(state.pending, request_id)}
        # The host may have applied the action before going quiet, so it is not retried.
        {:noreply, drop_connection(state, pending.client_id, :evicted)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.clients, fn {_id, client} -> client.pid == pid end) do
      {client_id, _} -> {:noreply, drop_connection(state, client_id, :closed)}
      nil -> {:noreply, state}
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp connected(connection_id), do: %{"type" => "connected", "connectionId" => connection_id}

  # Removes a host's connection: its session assignments go, its unanswered requests
  # fail, and an evicted host's stream ends so it registers again.
  defp drop_connection(state, client_id, how) do
    case Map.pop(state.clients, client_id) do
      {nil, _} ->
        state

      {client, clients} ->
        Process.demonitor(client.monitor, [:flush])

        if how == :evicted,
          do: send(client.pid, {:t3_preview_automation, node(), client_id, :end})

        {gone, pending} =
          Enum.split_with(state.pending, fn {_id, p} ->
            p.connection_id == client.connection_id
          end)

        for {_id, p} <- gone do
          Process.cancel_timer(p.timer)

          GenServer.reply(
            p.from,
            {:error, tagged("PreviewAutomationClientDisconnectedError", p.context)}
          )
        end

        assignments =
          Map.reject(state.assignments, fn {_key, a} ->
            a.connection_id == client.connection_id
          end)

        %{state | clients: clients, pending: Map.new(pending), assignments: assignments}
    end
  end

  defp live_assignment(state, key) do
    with %{client_id: client_id, connection_id: connection_id} = assignment <-
           state.assignments[key],
         %{connection_id: ^connection_id} = client <- state.clients[client_id] do
      {client_id, client, assignment}
    else
      _ -> nil
    end
  end

  # The tab a result names (or the explicit tab) becomes the session's current tab,
  # unless a later request already moved it.
  defp track_tab(state, %{update_tab: false}, _result), do: state

  defp track_tab(state, pending, result) do
    tab =
      case result do
        %{"tabId" => tab} -> {:ok, tab}
        _ when pending.explicit_tab != nil -> {:ok, pending.explicit_tab}
        _ -> :none
      end

    connection_id = pending.connection_id

    with {:ok, tab} <- tab,
         %{connection_id: ^connection_id, tab_seq: seq} = assignment when seq <= pending.seq <-
           state.assignments[pending.key] do
      assignment = %{assignment | tab_id: tab, tab_seq: pending.seq}
      %{state | assignments: Map.put(state.assignments, pending.key, assignment)}
    else
      _ -> state
    end
  end

  @passthrough ~w(PreviewAutomationRecordingDesktopUpdateRequiredError PreviewAutomationRecordingTooLargeError PreviewAutomationRecordingDeadlineExpiredError PreviewAutomationRecordingTransferError PreviewAutomationNoAvailableHostError PreviewAutomationUnsupportedClientError PreviewAutomationTabNotFoundError PreviewAutomationTimeoutError PreviewAutomationControlInterruptedError PreviewAutomationInvalidSelectorError PreviewAutomationTargetNotEditableError PreviewAutomationResultTooLargeError)

  defp remote_error(context, %{"_tag" => tag} = error) do
    tag =
      cond do
        tag in @passthrough -> tag
        tag == "PreviewAutomationUnavailableError" -> "PreviewAutomationRemoteUnavailableError"
        true -> "PreviewAutomationExecutionError"
      end

    context
    |> Map.merge(%{"remoteTag" => error["_tag"], "remoteMessage" => error["message"]})
    |> put_present("maximumBytes", get_in(error, ["detail", "maximumBytes"]))
    |> then(&tagged(tag, &1))
  end

  defp remote_error(context, _missing),
    do: tagged("PreviewAutomationMalformedResponseError", context)

  defp no_host(scope, operation),
    do:
      tagged("PreviewAutomationNoAvailableHostError", %{
        "operation" => operation,
        "threadId" => scope.thread_id,
        "providerInstanceId" => scope.instance
      })

  defp tagged(tag, fields), do: Map.put(fields, "_tag", tag)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
