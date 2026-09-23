defmodule T3.Acp.UrlAuth do
  @moduledoc """
  An ACP agent's request to open a sign-in page outside an explicit sign-in (while
  it is probed, or in a session), as the Node server's registry coordinator handles
  it: the agent's `elicitation/create` waits while the provider's `auth.action`
  shows the page to every client, and `server.acceptAcpRegistryUrlAuth` answers it
  once a user opens the page. Unanswered after 10 minutes, or replaced by a newer
  request, it is declined. One request per instance is pending at a time.
  """

  use GenServer

  @ttl_ms :timer.minutes(10)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Asks for `params` (an `elicitation/create` in `url` mode) for `instance` and waits:
  `%{"action" => "accept" | "decline"}`, the agent's answer.
  """
  def request(instance, params) do
    with %{"url" => url, "elicitationId" => id} when is_binary(url) and is_binary(id) <- params,
         %URI{scheme: scheme, host: host}
         when scheme in ["http", "https"] and host not in [nil, ""] <-
           URI.parse(url),
         true <- byte_size(url) <= 2048 and String.trim(id) != "" and byte_size(id) <= 128,
         true <- Process.whereis(__MODULE__) != nil do
      action = %{
        "elicitationId" => String.trim(id),
        "url" => url,
        "message" => String.slice(params["message"] || "", 0, 1024)
      }

      if GenServer.call(__MODULE__, {:request, instance, action}, @ttl_ms + 5_000),
        do: %{"action" => "accept"},
        else: %{"action" => "decline"}
    else
      _ -> %{"action" => "decline"}
    end
  catch
    :exit, _ -> %{"action" => "decline"}
  end

  @doc "`server.acceptAcpRegistryUrlAuth`: `{:ok, %{\"accepted\" => boolean}}`."
  def accept(%{"instanceId" => instance, "elicitationId" => id}),
    do: {:ok, %{"accepted" => GenServer.call(__MODULE__, {:accept, instance, id})}}

  @doc "The pending action to show on `instance`'s auth, or nil."
  def action(instance) do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(__MODULE__, instance) do
          [{_, action}] -> action
          [] -> nil
        end
    end
  end

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:request, instance, action}, from, pending) do
    # A newer request replaces the one before it.
    with %{from: previous, timer: timer} <- pending[instance] do
      Process.cancel_timer(timer)
      GenServer.reply(previous, false)
    end

    now = DateTime.utc_now()

    action =
      Map.merge(action, %{
        "createdAt" => DateTime.to_iso8601(now),
        "expiresAt" => DateTime.to_iso8601(DateTime.add(now, @ttl_ms, :millisecond))
      })

    timer = Process.send_after(self(), {:expire, instance, action["elicitationId"]}, @ttl_ms)
    publish(instance, action)
    {:noreply, Map.put(pending, instance, %{from: from, action: action, timer: timer})}
  end

  def handle_call({:accept, instance, id}, _from, pending) do
    case pending[instance] do
      %{action: %{"elicitationId" => ^id}, from: from, timer: timer} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, true)
        publish(instance, nil)
        {:reply, true, Map.delete(pending, instance)}

      _ ->
        {:reply, false, pending}
    end
  end

  @impl true
  def handle_info({:expire, instance, id}, pending) do
    case pending[instance] do
      %{action: %{"elicitationId" => ^id}, from: from} ->
        GenServer.reply(from, false)
        publish(instance, nil)
        {:noreply, Map.delete(pending, instance)}

      _ ->
        {:noreply, pending}
    end
  end

  defp publish(instance, nil), do: notify(:ets.delete(__MODULE__, instance))
  defp publish(instance, action), do: notify(:ets.insert(__MODULE__, {instance, action}))

  defp notify(_), do: T3.Settings.notify_providers()
end
