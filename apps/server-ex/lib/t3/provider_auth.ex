defmodule T3.ProviderAuth do
  @moduledoc """
  Signing a provider instance in on this node (`provider.auth.*`), for the agents
  that keep their own credentials: ACP agents today (`T3.Acp.Auth`).

  One process per instance holds its `ProviderAuthState` and runs at most one
  sign-in. It starts with its first subscriber or request and stops once no one
  watches and nothing runs. The sign-in itself is a linked worker that reports
  `{:auth_interaction, flow, interaction, responder}` (a URL to open, or a login
  terminal's output) and `{:auth_verifying, flow}`, and exits `:normal` when the
  agent can open a session again; client responses go to the responder as
  `{:auth_response, response}`.

  Every client of the node sees the same flow: a node's clients are one user's
  paired devices.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry T3.ProviderAuth.Registry
  @supervisor T3.ProviderAuth.Supervisor
  @timeout_ms 300_000

  # --- RPCs ------------------------------------------------------------------------

  @doc "`provider.auth.start`: signs in with a method (the first one by default)."
  def start(%{"instanceId" => instance} = input),
    do: call(instance, {:start, input["methodId"]})

  @doc "`provider.auth.respond`: answers the flow's current interaction."
  def respond(%{"instanceId" => instance} = input),
    do: call(instance, {:respond, input["flowId"], input["interactionId"], input["response"]})

  @doc "`provider.auth.cancel`."
  def cancel(%{"instanceId" => instance, "flowId" => flow_id}),
    do: call(instance, {:cancel, flow_id})

  @doc "`provider.auth.logout`."
  def logout(%{"instanceId" => instance}), do: call(instance, :logout)

  @doc "`provider.auth.complete`: no agent here takes a pasted redirect URL."
  def complete(%{"instanceId" => instance}),
    do: error(instance, "complete", "This provider does not accept a pasted redirect URL.")

  @doc "Adds `pid` as a subscriber; it gets `{:t3_provider_auth, instance, state}`."
  def subscribe(instance, pid), do: call(instance, {:subscribe, pid})

  def unsubscribe(instance, pid) do
    case Registry.lookup(@registry, instance) do
      [{server, _}] -> GenServer.cast(server, {:unsubscribe, pid})
      [] -> :ok
    end
  end

  defp call(instance, message) do
    cond do
      not T3.Acp.agent?(instance) ->
        error(instance, "start", "This provider does not sign in here.")

      true ->
        server =
          case DynamicSupervisor.start_child(@supervisor, {__MODULE__, instance}) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

        GenServer.call(server, message, 60_000)
    end
  end

  def start_link(instance),
    do: GenServer.start_link(__MODULE__, instance, name: {:via, Registry, {@registry, instance}})

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(instance) do
    Process.flag(:trap_exit, true)
    server = self()
    Task.start(fn -> send(server, {:methods, T3.Acp.Auth.methods(instance)}) end)

    {:ok,
     %{
       instance: instance,
       auth: idle(instance, nil),
       methods: nil,
       watchers: %{},
       flow: nil
     }}
  end

  defp idle(instance, message) do
    %{
      "instanceId" => instance,
      "phase" => "idle",
      "flowId" => nil,
      "authorizationUrl" => nil,
      "expiresAt" => nil,
      "message" => message,
      "interaction" => nil,
      "credentialOwner" => "provider"
    }
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, state.auth}, %{state | watchers: watchers}}
  end

  def handle_call({:start, _method}, _from, %{flow: %{}} = state),
    do: {:reply, {:ok, state.auth}, state}

  def handle_call({:start, method_id}, _from, state) do
    methods = state.methods || []
    method_id = method_id || default_method(state.instance, methods)

    if method_id != nil and (methods == [] or Enum.any?(methods, &(&1["id"] == method_id))) do
      flow_id = T3.Environment.uuid4()
      expires = System.system_time(:millisecond) + @timeout_ms
      server = self()
      instance = state.instance

      worker =
        spawn_link(fn -> T3.Acp.Auth.login(instance, method_id, server, flow_id) end)

      Process.send_after(self(), {:expire, flow_id}, @timeout_ms)

      state =
        publish(
          %{state | flow: %{id: flow_id, worker: worker, responder: nil}},
          %{
            "phase" => "starting",
            "flowId" => flow_id,
            "expiresAt" => iso(expires),
            "message" => "Starting sign-in.",
            "interaction" => nil,
            "authorizationUrl" => nil
          }
        )

      {:reply, {:ok, state.auth}, state}
    else
      {:reply,
       error(state.instance, "start", "The provider did not advertise this sign-in method."),
       state}
    end
  end

  def handle_call({:respond, flow_id, interaction_id, response}, _from, state) do
    interaction = state.auth["interaction"]

    case state.flow do
      %{id: ^flow_id, responder: responder}
      when is_pid(responder) and is_map(interaction) and is_map(response) ->
        if interaction["id"] == interaction_id and interaction["type"] == response["type"] do
          send(responder, {:auth_response, response})
          {:reply, {:ok, state.auth}, state}
        else
          {:reply,
           error(state.instance, "respond", "This sign-in interaction is no longer available."),
           state}
        end

      _ ->
        {:reply, error(state.instance, "respond", "This sign-in is no longer active."), state}
    end
  end

  def handle_call({:cancel, flow_id}, _from, %{flow: %{id: flow_id}} = state) do
    state = end_flow(state, "cancelled", "Sign-in cancelled.")
    {:reply, {:ok, state.auth}, state}
  end

  def handle_call({:cancel, _}, _from, state),
    do: {:reply, error(state.instance, "cancel", "This sign-in is no longer active."), state}

  def handle_call(:logout, _from, state) do
    state = if state.flow, do: end_flow(state, "idle", nil), else: state

    case T3.Acp.Sessions.logout(%{"instanceId" => state.instance}) do
      {:ok, _} ->
        state = %{state | auth: Map.merge(idle(state.instance, "Signed out."), methods(state))}
        broadcast(state)
        {:reply, {:ok, state.auth}, state}

      {:error, detail} ->
        {:reply,
         error(state.instance, "logout", detail["message"] || "Could not sign out. Try again."),
         state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    maybe_stop(%{state | watchers: watchers})
  end

  @impl true
  def handle_info({:methods, {:ok, methods}}, state) do
    state = %{state | methods: methods}
    {:noreply, publish(state, %{"methods" => methods})}
  end

  def handle_info({:methods, {:error, message}}, state) do
    state = %{state | methods: []}
    {:noreply, publish(state, %{"methods" => [], "message" => message})}
  end

  def handle_info(
        {:auth_interaction, flow_id, interaction, responder},
        %{flow: %{id: flow_id}} = state
      ) do
    state = put_in(state.flow.responder, responder)

    url = if interaction["type"] in ["browser", "deviceCode"], do: interaction["url"]

    {:noreply,
     publish(state, %{
       "phase" => "waiting",
       "interaction" => interaction,
       "authorizationUrl" => url,
       "message" => "Complete sign-in to continue."
     })}
  end

  def handle_info({:auth_verifying, flow_id}, %{flow: %{id: flow_id}} = state) do
    state = put_in(state.flow.responder, nil)

    {:noreply,
     publish(state, %{
       "phase" => "verifying",
       "interaction" => nil,
       "authorizationUrl" => nil,
       "message" => "Checking provider sign-in."
     })}
  end

  def handle_info({:expire, flow_id}, %{flow: %{id: flow_id}} = state),
    do: {:noreply, end_flow(state, "failed", "Sign-in expired. Start again.")}

  def handle_info({:EXIT, worker, reason}, %{flow: %{worker: worker}} = state) do
    state = %{state | flow: nil}

    state =
      case reason do
        :normal ->
          # The agent reads its new credentials when it is next started.
          T3.Acp.forget(state.instance)
          T3.Settings.notify_providers()
          finish(state, "succeeded", "Sign-in complete.")

        {:shutdown, {:failed, message}} ->
          finish(state, "failed", message)

        other ->
          Logger.warning("#{state.instance} sign-in failed: #{inspect(other)}")
          finish(state, "failed", "Sign-in failed. Start again.")
      end

    maybe_stop(state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    maybe_stop(%{state | watchers: Map.delete(state.watchers, pid)})
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- helpers ---------------------------------------------------------------------

  defp end_flow(state, phase, message) do
    Process.unlink(state.flow.worker)
    Process.exit(state.flow.worker, :kill)
    finish(%{state | flow: nil}, phase, message)
  end

  defp finish(state, phase, message) do
    publish(state, %{
      "phase" => phase,
      "flowId" => nil,
      "interaction" => nil,
      "authorizationUrl" => nil,
      "expiresAt" => nil,
      "message" => message
    })
  end

  defp publish(state, patch) do
    state = %{state | auth: Map.merge(state.auth, patch)}
    broadcast(state)
    state
  end

  defp broadcast(state) do
    for {pid, _} <- state.watchers, do: send(pid, {:t3_provider_auth, state.instance, state.auth})
  end

  defp methods(%{methods: nil}), do: %{}
  defp methods(%{methods: methods}), do: %{"methods" => methods}

  defp maybe_stop(%{watchers: watchers, flow: nil} = state) when map_size(watchers) == 0,
    do: {:stop, :normal, state}

  defp maybe_stop(state), do: {:noreply, state}

  # The instance's configured method, else the first one the agent listed.
  defp default_method(instance, methods) do
    configured =
      get_in(T3.Settings.settings(), ["providerInstances", instance, "config", "authMethodId"])

    if(is_binary(configured) and configured != "", do: configured) ||
      (List.first(methods) || %{})["id"]
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp error(instance, operation, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => instance,
       "operation" => operation,
       "detail" => detail,
       "message" => detail
     }}
  end
end
