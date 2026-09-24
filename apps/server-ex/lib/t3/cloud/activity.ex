defmodule T3.Cloud.Activity do
  @moduledoc """
  Publishes what this node's agents are doing to the T3 Connect relay, which turns
  it into push notifications and Live Activities, as the Node server's
  `AgentAwarenessRelay` does. Only while a link exists and publishing is on
  (`T3.Cloud.publishing?/0`).

  Each thread's shell row is projected to a `RelayAgentActivityState`
  (`state/3`, after `@t3tools/shared/agentAwareness`): starting, running, waiting
  for approval or input, completed, failed, or nil when there is nothing to show.
  A state is sent only when it differs from the last one sent, signed by the
  node's key; clearing one, and a first "completed", wait five seconds to be
  confirmed so a thread settling for a moment does not notify. Failed sends are
  retried after 1, 2, 4, 8 and 16 seconds.
  """

  use GenServer
  require Logger

  @confirm_after 5_000
  @retry_delays [1_000, 2_000, 4_000, 8_000, 16_000]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Publishes every thread with something to show; called when publishing turns on."
  def publish_active, do: GenServer.cast(__MODULE__, :publish_active)

  @doc """
  A thread row's `RelayAgentActivityState` on the environment `environment_id`,
  under `project_title`; nil for a subagent, an archived thread, or one at rest.
  """
  def state(environment_id, project_title, thread) do
    phase = phase(thread)

    if phase && thread["archivedAt"] == nil &&
         get_in(thread, ["lineage", "relationshipToParent"]) != "subagent" do
      id = thread["id"]

      %{
        "environmentId" => environment_id,
        "threadId" => id,
        "projectTitle" => project_title,
        "threadTitle" => thread["title"],
        "phase" => phase,
        "headline" => headline(phase),
        "modelTitle" => get_in(thread, ["modelSelection", "model"]),
        "updatedAt" => thread["updatedAt"],
        "deepLink" => "/threads/#{URI.encode_www_form(environment_id)}/#{URI.encode_www_form(id)}"
      }
      |> put_detail(phase)
    end
  end

  defp phase(%{"pendingRuntimeRequest" => %{"kind" => "user_input"}}), do: "waiting_for_input"

  defp phase(%{"pendingRuntimeRequest" => %{"kind" => kind}}) when kind != "auth_refresh",
    do: "waiting_for_approval"

  defp phase(thread) do
    case thread["activityRunStatus"] || thread["status"] do
      status when status in ["preparing", "starting"] -> "starting"
      status when status in ["running", "waiting"] -> "running"
      "completed" -> "completed"
      "failed" -> "failed"
      _ -> nil
    end
  end

  defp headline("starting"), do: "Starting agent"
  defp headline("running"), do: "Agent is working"
  defp headline("waiting_for_approval"), do: "Approval needed"
  defp headline("waiting_for_input"), do: "Waiting for input"
  defp headline("completed"), do: "Agent finished"
  defp headline("failed"), do: "Agent failed"

  # A failure's own text can carry anything; the relay only ever sees a fixed line.
  defp put_detail(state, "completed"), do: Map.put(state, "detail", "Review the completed task.")
  defp put_detail(state, "failed"), do: Map.put(state, "detail", "The agent run failed.")
  defp put_detail(state, _phase), do: state

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ok = T3.Shell.subscribe(self())
    send(self(), :publish_active)
    # published: thread id -> identity of the state last sent; waiting: thread id
    # -> confirmation deadline; retries: thread id -> attempts made.
    {:ok, %{published: %{}, waiting: %{}, retries: %{}}}
  end

  @impl true
  def handle_cast(:publish_active, state), do: handle_info(:publish_active, state)

  @impl true
  def handle_info(:publish_active, state) do
    if T3.Cloud.publishing?() do
      env = T3.Environment.id()

      state =
        for {{node, id}, {"thread", row}} <- T3.Shell.rows(),
            node == node(),
            state(env, "", row) != nil,
            reduce: state,
            do: (state -> publish(state, id))

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:t3_shell, {:rows, node, rows}}, state) when node == node() do
    state =
      for {id, {"thread", _row}} <- rows, reduce: state, do: (state -> publish(state, id))

    {:noreply, state}
  end

  def handle_info({:confirm, id}, state), do: {:noreply, publish(state, id)}
  def handle_info({:retry, id}, state), do: {:noreply, publish(state, id)}
  def handle_info(_message, state), do: {:noreply, state}

  defp publish(state, id) do
    with true <- T3.Cloud.publishing?(),
         relay when relay != nil <- T3.Cloud.relay() do
      publish(state, id, relay)
    else
      # Unlinked or turned off: forget what was sent, so turning it on sends afresh.
      _ -> %{state | published: %{}, waiting: %{}, retries: %{}}
    end
  end

  defp publish(state, id, relay) do
    env = T3.Environment.id()
    activity = current(env, id)
    identity = identity(activity)
    now = System.monotonic_time(:millisecond)

    confirm? =
      (activity == nil and Map.get(state.published, id, identity(nil)) != identity(nil)) or
        (activity != nil and activity["phase"] == "completed" and
           not Map.has_key?(state.published, id))

    cond do
      Map.get(state.published, id) == identity ->
        %{state | waiting: Map.delete(state.waiting, id)}

      confirm? and not Map.has_key?(state.waiting, id) ->
        Process.send_after(self(), {:confirm, id}, @confirm_after)
        %{state | waiting: Map.put(state.waiting, id, now + @confirm_after)}

      confirm? and now < state.waiting[id] ->
        state

      true ->
        state = %{state | waiting: Map.delete(state.waiting, id)}

        case send_state(relay, env, id, activity) do
          :ok ->
            %{
              state
              | published: Map.put(state.published, id, identity),
                retries: Map.delete(state.retries, id)
            }

          {:error, reason} ->
            attempts = Map.get(state.retries, id, 0)
            Logger.warning("agent activity publish for #{id} failed: #{inspect(reason)}")

            case Enum.at(@retry_delays, attempts) do
              nil ->
                %{state | retries: Map.delete(state.retries, id)}

              delay ->
                Process.send_after(self(), {:retry, id}, delay)
                %{state | retries: Map.put(state.retries, id, attempts + 1)}
            end
        end
    end
  end

  defp current(env, id) do
    with {"thread", thread} <- T3.Shell.row(node(), id),
         {"project", project} <- T3.Shell.row(node(), thread["projectId"]),
         true <- project["deletedAt"] == nil do
      state(env, project["title"], thread)
    else
      _ -> nil
    end
  end

  defp identity(nil), do: "null"
  defp identity(activity), do: activity |> Map.delete("updatedAt") |> Enum.sort()

  defp send_state(relay, env, id, activity) do
    now = System.os_time(:second)

    proof =
      T3.Cloud.sign_activity(%{
        "iss" => "t3-env:#{env}",
        "aud" => T3.Cloud.Jwt.normalize_issuer(relay.issuer),
        "sub" => env,
        "jti" => T3.Environment.uuid4(),
        "iat" => now,
        "exp" => now + 300,
        "environmentId" => env,
        "threadId" => id,
        "state" => activity
      })

    url =
      "#{String.trim_trailing(relay.url, "/")}/v1/environments/#{URI.encode_www_form(env)}/threads/#{URI.encode_www_form(id)}/agent-activity"

    request =
      {String.to_charlist(url),
       [{~c"authorization", ~c"Bearer " ++ to_charlist(relay.credential)}], ~c"application/json",
       JSON.encode!(%{"state" => activity, "proof" => proof})}

    case :httpc.request(:post, request, [timeout: 15_000, autoredirect: false], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, body}} -> {:error, {status, to_string(body)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
