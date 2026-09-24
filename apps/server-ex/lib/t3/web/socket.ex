defmodule T3.Web.Socket do
  @moduledoc """
  One client connection. See `T3.Web.Protocol` for the wire format.

  Stream subscriptions may live on any node in the cluster; the owning node's stream
  server sends straight to this process. Incoming events are buffered and flushed
  once the mailbox is drained, merged per entity, so a burst of streaming tokens
  becomes one frame. A subscription whose unsent buffer passes `@max_buffered` is
  dropped with a `resync`; the client resubscribes from its offset and the stream
  replays from the log instead of this process holding the backlog.
  """

  @behaviour WebSock

  alias T3.Web.{Protocol, Wire}

  @max_buffered 8 * 1024 * 1024

  # Sockets are Bandit's processes, so a code upgrade in place (`T3.Upgrade`) runs no
  # `code_change/3` for them: each callback first brings an older state up to date.
  @state_version 1

  @impl true
  def init(opts) do
    # A socket opened with a ticket belongs to that client's session.
    session = opts[:session]
    if session, do: T3.Auth.connected(session)

    state = %{
      v: @state_version,
      session: session,
      subs: %{},
      by_stream: %{},
      by_terminal: %{},
      buffers: %{},
      # Turn item types by stream subscription, for trimming patches (`T3.Web.Wire`).
      item_types: %{},
      flush_scheduled: false
    }

    {:push,
     Protocol.encode(%{
       "t" => "hello",
       "protocol" => Protocol.version(),
       "node" => Atom.to_string(node())
     }), state}
  end

  @impl true
  def handle_in(frame, state)
      when not is_map_key(state, :v) or :erlang.map_get(:v, state) != @state_version,
      do: handle_in(frame, migrate(state))

  def handle_in({frame, [opcode: :text]}, state) do
    case Protocol.decode(frame, [node() | Node.list()]) do
      {:ok, :ping} ->
        {:push, Protocol.encode(%{"t" => "pong"}), state}

      {:ok, {:sub, id, shape, offset}} ->
        subscribe(state, id, shape, offset)

      {:ok, {:unsub, id}} ->
        {:ok, unsubscribe(state, id)}

      {:ok, {:rpc, id, environment, method, payload}} ->
        {:ok, rpc(state, id, environment, method, payload)}

      {:error, reason} ->
        {:push, Protocol.encode(%{"t" => "error", "reason" => reason}), state}
    end
  end

  def handle_in(_binary, state), do: {:ok, state}

  @impl true
  def handle_info(message, state)
      when not is_map_key(state, :v) or :erlang.map_get(:v, state) != @state_version,
      do: handle_info(message, migrate(state))

  def handle_info({:t3_stream, stream_id, message}, state) do
    case state.by_stream do
      %{^stream_id => id} -> stream_message(state, id, message)
      _ -> {:ok, state}
    end
  end

  def handle_info({:t3_shell, message}, state) do
    case Enum.find(state.subs, &match?({_, :shell}, &1)) do
      {id, :shell} -> {:push, Protocol.encode(shell_message(id, message)), state}
      nil -> {:ok, state}
    end
  end

  def handle_info({:t3_terminal, key, event}, state) do
    case state.by_terminal do
      %{^key => id} ->
        {:push, Protocol.encode(%{"t" => "terminal", "id" => id, "event" => event}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_server_update, node, event}, state) do
    case state.by_terminal do
      %{{:server_update, ^node} => id} ->
        case event do
          {:error, detail} ->
            frame =
              Map.put(error_frame(id, detail["reason"] || "update failed"), "detail", detail)

            {:push, Protocol.encode(frame), unsubscribe(state, id)}

          %{"type" => "complete"} ->
            frames = [
              Protocol.encode(%{"t" => "serverUpdate", "id" => id, "event" => event}),
              Protocol.encode(%{"t" => "end", "id" => id})
            ]

            {:push, frames, unsubscribe(state, id)}

          _ ->
            {:push, Protocol.encode(%{"t" => "serverUpdate", "id" => id, "event" => event}),
             state}
        end

      _ ->
        {:ok, state}
    end
  end

  # The node moved to another version in place; clients watching it see its new
  # descriptor as a `ready`.
  def handle_info({:t3_upgraded, node, outcome}, state) do
    case remote(node, T3.Environment, :descriptor, []) do
      {:ok, descriptor} ->
        config_push(state, node, fn id ->
          %{
            "t" => "config.ready",
            "id" => id,
            "environment" => descriptor,
            "updateOutcome" => outcome
          }
        end)

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_git_action, action_id, event}, state) do
    case state.by_terminal do
      %{{:git_action, ^action_id} => id} ->
        {:push, Protocol.encode(%{"t" => "gitAction", "id" => id, "event" => event}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_settings, node, settings}, state) do
    # Settings can add, remove, or enable providers.
    if config_ids(state, node) != [], do: send(self(), {:t3_providers_changed, node})
    config_push(state, node, &%{"t" => "config.settings", "id" => &1, "settings" => settings})
  end

  def handle_info({:t3_themes, node, themes}, state),
    do: config_push(state, node, &%{"t" => "config.themes", "id" => &1, "themes" => themes})

  def handle_info({:t3_usage_limit_sources, node, sources}, state),
    do:
      config_push(
        state,
        node,
        &%{"t" => "config.usageLimitSources", "id" => &1, "sources" => sources}
      )

  def handle_info({:t3_keybindings, node, rules}, state),
    do: config_push(state, node, &%{"t" => "config.keybindings", "id" => &1, "rules" => rules})

  def handle_info({:t3_providers_changed, node}, state) do
    with [_ | _] <- config_ids(state, node),
         {:ok, providers} <- remote(node, T3.Environment, :providers, []) do
      config_push(
        state,
        node,
        &%{"t" => "config.providers", "id" => &1, "providers" => providers}
      )
    else
      _ -> {:ok, state}
    end
  end

  def handle_info({:t3_auth_access, event}, state) do
    case state.by_terminal do
      %{:auth_access => id} ->
        {:push, Protocol.encode(%{"t" => "authAccess", "id" => id, "event" => own(event, state)}),
         state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_resource_telemetry, node, snapshot}, state) do
    case state.by_terminal do
      %{{:resource_telemetry, ^node} => id} ->
        {:push,
         Protocol.encode(%{"t" => "resourceTelemetry", "id" => id, "snapshot" => snapshot}),
         state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_preview_automation, node, client_id, event}, state) do
    case state.by_terminal do
      %{{:preview_automation, ^node, ^client_id} => id} when event == :end ->
        {:push, Protocol.encode(%{"t" => "end", "id" => id}), unsubscribe(state, id)}

      %{{:preview_automation, ^node, ^client_id} => id} ->
        {:push, Protocol.encode(%{"t" => "previewAutomation", "id" => id, "event" => event}),
         state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_preview, node, event}, state) do
    case state.by_terminal do
      %{{:preview, ^node} => id} ->
        {:push, Protocol.encode(%{"t" => "preview", "id" => id, "event" => event}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_local_servers, node, list}, state) do
    case state.by_terminal do
      %{{:local_servers, ^node} => id} ->
        {:push, Protocol.encode(%{"t" => "localServers", "id" => id, "list" => list}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_devices, node, device_state}, state) do
    case state.by_terminal do
      %{{:devices, ^node} => id} ->
        {:push, Protocol.encode(%{"t" => "devices", "id" => id, "state" => device_state}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_project_clones, node, clones}, state) do
    case state.by_terminal do
      %{{:project_clones, ^node} => id} ->
        {:push, Protocol.encode(%{"t" => "projectClones", "id" => id, "clones" => clones}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_scheduled_tasks, node, tasks}, state) do
    case state.by_terminal do
      %{{:scheduled_tasks, ^node} => id} ->
        {:push, Protocol.encode(%{"t" => "scheduledTasks", "id" => id, "tasks" => tasks}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_pull_request_refreshes, node, revision}, state) do
    case state.by_terminal do
      %{{:pull_request_refreshes, ^node} => id} ->
        frame = %{"t" => "pullRequestRefreshes", "id" => id, "revision" => revision}
        {:push, Protocol.encode(frame), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_worktree_setup, thread_id, snapshot}, state) do
    case state.by_terminal do
      %{{:worktree_setup, ^thread_id} => id} ->
        {:push, Protocol.encode(%{"t" => "worktreeSetup", "id" => id, "event" => snapshot}),
         state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_provider_auth, instance, auth}, state) do
    case state.by_terminal do
      %{{:provider_auth, ^instance} => id} ->
        {:push, Protocol.encode(%{"t" => "providerAuth", "id" => id, "state" => auth}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_vcs, cwd, event}, state) do
    case state.by_terminal do
      %{{:vcs, ^cwd} => id} ->
        {:push, Protocol.encode(%{"t" => "vcs", "id" => id, "event" => event}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:t3_terminals, node, event}, state) do
    case state.by_terminal do
      %{{:terminals, ^node} => id} ->
        {:push, Protocol.encode(%{"t" => "terminals", "id" => id, "event" => event}), state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:rpc_reply, id, reply}, state) do
    frame =
      case reply do
        {:ok, result} ->
          %{"t" => "rpc.result", "id" => id, "result" => result}

        {:error, %{} = detail} ->
          %{
            "t" => "rpc.error",
            "id" => id,
            "error" => to_string(detail["message"] || detail["_tag"]),
            "detail" => Map.delete(detail, "message")
          }

        {:error, message} ->
          %{"t" => "rpc.error", "id" => id, "error" => to_string(message)}
      end

    {:push, Protocol.encode(frame), state}
  end

  def handle_info(:flush, state) do
    {frames, state} = flush(state)
    {:push, frames, %{state | flush_scheduled: false}}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    state = migrate(state)
    for {id, _} <- state.subs, do: unsubscribe(state, id)
    :ok
  end

  # Runs a client RPC on the node that owns the environment, off this process so a
  # slow command never holds up streaming.
  defp rpc(state, id, environment, method, payload) do
    socket = self()

    Task.start(fn ->
      reply =
        case node_for(environment) do
          nil ->
            {:error, "unknown environment"}

          # Activity leases belong to this socket and its session.
          node when method == "server.reportClientActivity" ->
            args = [state.session, socket, payload || %{}]
            :erpc.cast(node, T3.BackgroundPolicy, :report_client_activity, args)
            {:ok, nil}

          node ->
            try do
              # Each call runs in its own task; some (a provider update, a
              # scheduled task run) take minutes.
              :erpc.call(node, T3.Rpc, :handle, [method, payload || %{}], :timer.minutes(10))
            catch
              :error, {:erpc, reason} -> {:error, "node unavailable: #{reason}"}
              kind, reason -> {:error, Exception.format(kind, reason)}
            end
        end

      send(socket, {:rpc_reply, id, reply})
    end)

    state
  end

  defp node_for(environment_id) do
    Enum.find_value(T3.Shell.environments(), fn {node, descriptor} ->
      if descriptor["environmentId"] == environment_id, do: node
    end)
  end

  # --- subscriptions -------------------------------------------------------------

  defp subscribe(state, id, :shell, _offset) do
    :ok = T3.Shell.subscribe(self())
    online = MapSet.new(T3.Shell.online_nodes())

    rows =
      for {{node, stream}, {kind, row}} <- T3.Shell.rows(),
          do: [Atom.to_string(node), stream, kind, row]

    nodes =
      for {node, descriptor} <- T3.Shell.environments() do
        %{"node" => Atom.to_string(node), "online" => node in online, "environment" => descriptor}
      end

    frame = %{"t" => "shell", "id" => id, "nodes" => nodes, "rows" => rows}

    {:push, Protocol.encode(frame), put_in(state.subs[id], :shell)}
  end

  # A node's ServerConfig, fetched once; it is small and changes with settings.
  defp subscribe(state, id, {:config_for, environment_id}, offset) do
    case Enum.find(T3.Shell.environments(), fn {_node, d} ->
           d["environmentId"] == environment_id
         end) do
      {node, _} ->
        subscribe(state, id, {:config, node}, offset)

      nil ->
        {:push, Protocol.encode(%{"t" => "error", "id" => id, "reason" => "unknown environment"}),
         state}
    end
  end

  # The node's config, then its settings as they change.
  defp subscribe(state, id, {:config, node} = shape, _offset) do
    with {:ok, :ok} <- remote(node, T3.Settings, :watch, [self()]),
         {:ok, config} <- remote(node, T3.Environment, :server_config, []) do
      frame = %{"t" => "config", "id" => id, "node" => Atom.to_string(node), "config" => config}

      # How the node's last update went, so a client reconnecting after one can tell.
      frame =
        case remote(node, T3.Upgrade, :outcome, []) do
          {:ok, %{} = outcome} -> Map.put(frame, "updateOutcome", outcome)
          _ -> frame
        end

      # Published themes follow the snapshot, as the Node server streams them.
      themes =
        case remote(node, T3.EnvironmentThemes, :current, []) do
          {:ok, themes} when is_list(themes) -> themes
          _ -> []
        end

      themes_frame = %{"t" => "config.themes", "id" => id, "themes" => themes}

      # So do usage-limit source snapshots.
      sources =
        case remote(node, T3.UsageLimitSources, :current, []) do
          {:ok, sources} when is_list(sources) -> sources
          _ -> []
        end

      sources_frame = %{"t" => "config.usageLimitSources", "id" => id, "sources" => sources}

      {:push,
       [Protocol.encode(frame), Protocol.encode(themes_frame), Protocol.encode(sources_frame)],
       %{
         state
         | subs: Map.put(state.subs, id, shape),
           # One node's config may be watched by several subscriptions (config, lifecycle).
           by_terminal: Map.update(state.by_terminal, {:settings, node}, [id], &[id | &1])
       }}
    else
      {_, reason} -> {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:stream, node, stream_id} = shape, offset) do
    if Map.has_key?(state.by_stream, stream_id) do
      {:push, Protocol.encode(error_frame(id, "already subscribed")), state}
    else
      # The owning node may be gone or slow; the client retries when it is back.
      case remote(node, T3.Streams, :subscribe, [stream_id, self(), offset]) do
        {:ok, :ok} ->
          {:ok,
           %{
             state
             | subs: Map.put(state.subs, id, shape),
               by_stream: Map.put(state.by_stream, stream_id, id)
           }}

        {:error, reason} ->
          {:push, Protocol.encode(error_frame(id, reason)), state}
      end
    end
  end

  # A terminal lives on the node that owns its thread; its events come straight here.
  defp subscribe(state, id, {:terminal, node, input}, _offset) do
    key = {input["threadId"], input["terminalId"]}

    case remote(node, T3.Terminal, :attach, [input, self()]) do
      {:ok, {:ok, snapshot}} ->
        frame = %{"type" => "snapshot", "snapshot" => snapshot}

        {:push, Protocol.encode(%{"t" => "terminal", "id" => id, "event" => frame}),
         %{
           state
           | subs: Map.put(state.subs, id, {:terminal, node, key}),
             by_terminal: Map.put(state.by_terminal, key, id)
         }}

      {:ok, {:error, %{} = error}} ->
        frame =
          Map.put(error_frame(id, error["message"]), "detail", Map.delete(error, "message"))

        {:push, Protocol.encode(frame), state}

      {_, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:terminals, node} = shape, _offset) do
    case remote(node, T3.Terminal.Hub, :watch, [self()]) do
      {:ok, terminals} ->
        event = %{"type" => "snapshot", "terminals" => terminals}

        {:push, Protocol.encode(%{"t" => "terminals", "id" => id, "event" => event}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, shape, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:vcs, node, cwd} = shape, _offset) do
    case remote(node, T3.Vcs.Watch, :subscribe, [cwd, self()]) do
      {:ok, snapshot} ->
        {:push, Protocol.encode(%{"t" => "vcs", "id" => id, "event" => snapshot}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:vcs, cwd}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # Only an administrative session (or the node's own token) sees who is paired.
  defp subscribe(state, id, :auth_access, _offset) do
    allowed =
      state.session == nil or
        Enum.any?(
          T3.Auth.clients(),
          &(&1["sessionId"] == state.session and "access:read" in &1["scopes"])
        )

    if allowed do
      {:ok, revision, snapshot} = T3.Auth.subscribe(self())

      event = %{
        "version" => 1,
        "revision" => revision,
        "type" => "snapshot",
        "payload" => snapshot
      }

      {:push, Protocol.encode(%{"t" => "authAccess", "id" => id, "event" => own(event, state)}),
       %{
         state
         | subs: Map.put(state.subs, id, :auth_access),
           by_terminal: Map.put(state.by_terminal, :auth_access, id)
       }}
    else
      {:push, Protocol.encode(error_frame(id, "access:read is required")), state}
    end
  end

  defp subscribe(state, id, {:resource_telemetry, node} = shape, _offset) do
    case remote(node, T3.Diagnostics, :subscribe, [self()]) do
      {:ok, {:ok, snapshot}} ->
        {:push,
         Protocol.encode(%{"t" => "resourceTelemetry", "id" => id, "snapshot" => snapshot}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:resource_telemetry, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:preview_automation, node, host}, _offset) do
    key = {:preview_automation, node, host["clientId"]}

    case remote(node, T3.PreviewAutomation, :connect, [host, self()]) do
      {:ok, {:ok, _connection_id}} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, key),
             by_terminal: Map.put(state.by_terminal, key, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:preview, node} = shape, _offset) do
    case remote(node, T3.Preview, :subscribe, [self()]) do
      {:ok, :ok} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:preview, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:local_servers, node} = shape, _offset) do
    case remote(node, T3.LocalServers, :subscribe, [self()]) do
      {:ok, {:ok, list}} ->
        {:push, Protocol.encode(%{"t" => "localServers", "id" => id, "list" => list}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:local_servers, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:devices, node} = shape, _offset) do
    case remote(node, T3.Devices, :subscribe, [self()]) do
      {:ok, {:ok, device_state}} ->
        {:push, Protocol.encode(%{"t" => "devices", "id" => id, "state" => device_state}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, shape, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:project_clones, node} = shape, _offset) do
    case remote(node, T3.ProjectClones, :subscribe, [self()]) do
      {:ok, {:ok, clones}} ->
        {:push, Protocol.encode(%{"t" => "projectClones", "id" => id, "clones" => clones}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:project_clones, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:scheduled_tasks, node} = shape, _offset) do
    case remote(node, T3.ScheduledTasks, :subscribe, [self()]) do
      {:ok, {:ok, tasks}} ->
        {:push, Protocol.encode(%{"t" => "scheduledTasks", "id" => id, "tasks" => tasks}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:scheduled_tasks, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:pull_request_refreshes, node} = shape, _offset) do
    case remote(node, T3.PullRequests.Refreshes, :subscribe, [self()]) do
      {:ok, {:ok, revision}} ->
        {:push,
         Protocol.encode(%{"t" => "pullRequestRefreshes", "id" => id, "revision" => revision}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:pull_request_refreshes, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:worktree_setup, node, thread_id} = shape, _offset) do
    case remote(node, T3.WorktreeSetup, :subscribe, [thread_id, self()]) do
      {:ok, snapshot} ->
        {:push, Protocol.encode(%{"t" => "worktreeSetup", "id" => id, "event" => snapshot}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:worktree_setup, thread_id}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:provider_auth, node, instance} = shape, _offset) do
    case remote(node, T3.ProviderAuth, :subscribe, [instance, self()]) do
      {:ok, {:ok, auth}} ->
        {:push, Protocol.encode(%{"t" => "providerAuth", "id" => id, "state" => auth}),
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:provider_auth, instance}, id)
         }}

      {:ok, {:error, detail}} ->
        frame =
          Map.put(error_frame(id, detail["message"]), "detail", Map.delete(detail, "message"))

        {:push, Protocol.encode(frame), state}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # Runs on the checkout's node; its events come straight here.
  defp subscribe(state, id, {:server_update, node, input} = shape, _) do
    case remote(node, T3.Upgrade, :start, [input, self()]) do
      {:ok, :ok} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:server_update, node}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  defp subscribe(state, id, {:git_action, node, %{"actionId" => action_id} = input} = shape, _) do
    case remote(node, T3.GitActions, :start, [input, self()]) do
      {:ok, :ok} ->
        {:ok,
         %{
           state
           | subs: Map.put(state.subs, id, shape),
             by_terminal: Map.put(state.by_terminal, {:git_action, action_id}, id)
         }}

      {:error, reason} ->
        {:push, Protocol.encode(error_frame(id, reason)), state}
    end
  end

  # Calls a node without ever taking this socket down: an unreachable node, or one
  # without the feature (an older version), fails only the one subscription.
  defp remote(node, module, fun, args) do
    {:ok, :erpc.call(node, module, fun, args, 15_000)}
  catch
    :error, {:erpc, reason} ->
      {:error, "node unavailable: #{reason}"}

    kind, reason ->
      {:error, "#{node} cannot serve this: #{Exception.format_banner(kind, reason)}"}
  end

  # Marks this socket's own session in an access event.
  defp own(%{"type" => "snapshot", "payload" => payload} = event, state),
    do:
      put_in(
        event,
        ["payload", "clientSessions"],
        Enum.map(payload["clientSessions"], &mark(&1, state))
      )

  defp own(%{"type" => "clientUpserted", "payload" => client} = event, state),
    do: %{event | "payload" => mark(client, state)}

  defp own(event, _state), do: event

  defp mark(client, state), do: %{client | "current" => client["sessionId"] == state.session}

  # Version 1: a node's config may be watched by several subscriptions.
  defp migrate(state) when not is_map_key(state, :v) do
    by_terminal =
      Map.new(state.by_terminal, fn
        {{:settings, _node} = key, id} when is_integer(id) -> {key, [id]}
        entry -> entry
      end)

    %{state | by_terminal: by_terminal} |> Map.put(:v, 1)
  end

  defp migrate(state), do: state

  defp config_ids(state, node), do: Map.get(state.by_terminal, {:settings, node}, [])

  # A frame for each subscription watching `node`'s config, built by `frame.(id)`.
  defp config_push(state, node, frame) do
    case config_ids(state, node) do
      [] -> {:ok, state}
      ids -> {:push, Enum.map(ids, &Protocol.encode(frame.(&1))), state}
    end
  end

  defp error_frame(id, reason), do: %{"t" => "error", "id" => id, "reason" => to_string(reason)}

  defp unsubscribe(state, id) do
    case Map.pop(state.subs, id) do
      {{:terminal, node, {thread_id, terminal_id} = key}, subs} ->
        :erpc.cast(node, T3.Terminal, :detach, [thread_id, terminal_id, self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, key)}

      {{:vcs, node, cwd}, subs} ->
        :erpc.cast(node, T3.Vcs.Watch, :unsubscribe, [cwd, self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:vcs, cwd})}

      {{:server_update, node, _input}, subs} ->
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:server_update, node})}

      {{:git_action, _node, %{"actionId" => action_id}}, subs} ->
        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:git_action, action_id})
        }

      {{:config, node}, subs} ->
        case List.delete(config_ids(state, node), id) do
          [] ->
            :erpc.cast(node, T3.Settings, :unwatch, [self()])
            %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:settings, node})}

          ids ->
            %{state | subs: subs, by_terminal: Map.put(state.by_terminal, {:settings, node}, ids)}
        end

      {:auth_access, subs} ->
        T3.Auth.unsubscribe(self())
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, :auth_access)}

      {{:resource_telemetry, node}, subs} ->
        :erpc.cast(node, T3.Diagnostics, :unsubscribe, [self()])

        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:resource_telemetry, node})
        }

      {{:preview_automation, node, client_id} = key, subs} ->
        :erpc.cast(node, T3.PreviewAutomation, :disconnect, [client_id, self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, key)}

      {{:preview, node}, subs} ->
        :erpc.cast(node, T3.Preview, :unsubscribe, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:preview, node})}

      {{:local_servers, node}, subs} ->
        :erpc.cast(node, T3.LocalServers, :unsubscribe, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:local_servers, node})}

      {{:devices, node} = shape, subs} ->
        :erpc.cast(node, T3.Devices, :unsubscribe, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, shape)}

      {{:project_clones, node}, subs} ->
        :erpc.cast(node, T3.ProjectClones, :unsubscribe, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, {:project_clones, node})}

      {{:scheduled_tasks, node}, subs} ->
        :erpc.cast(node, T3.ScheduledTasks, :unsubscribe, [self()])

        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:scheduled_tasks, node})
        }

      {{:pull_request_refreshes, node} = shape, subs} ->
        :erpc.cast(node, T3.PullRequests.Refreshes, :unsubscribe, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, shape)}

      {{:worktree_setup, node, thread_id}, subs} ->
        :erpc.cast(node, T3.WorktreeSetup, :unsubscribe, [thread_id, self()])

        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:worktree_setup, thread_id})
        }

      {{:provider_auth, node, instance}, subs} ->
        :erpc.cast(node, T3.ProviderAuth, :unsubscribe, [instance, self()])

        %{
          state
          | subs: subs,
            by_terminal: Map.delete(state.by_terminal, {:provider_auth, instance})
        }

      {{:terminals, node} = shape, subs} ->
        :erpc.cast(node, T3.Terminal.Hub, :unwatch, [self()])
        %{state | subs: subs, by_terminal: Map.delete(state.by_terminal, shape)}

      {{:stream, node, stream_id}, subs} ->
        :erpc.cast(node, T3.Streams, :unsubscribe, [stream_id, self()])

        %{
          state
          | subs: subs,
            by_stream: Map.delete(state.by_stream, stream_id),
            buffers: Map.delete(state.buffers, id),
            item_types: Map.delete(state.item_types, id)
        }

      {_, subs} ->
        %{state | subs: subs}
    end
  end

  defp stream_message(state, id, {:snapshot, seq, updated_at, rows, part_state}) do
    part = get_in(state.buffers, [id, :snapshot_part]) || 0

    frame = %{
      "t" => "snapshot",
      "id" => id,
      "offset" => seq,
      "at" => updated_at,
      "part" => part,
      "done" => part_state == :done,
      "rows" => for({kind, eid, entity} <- rows, do: [kind, eid, Wire.entity(kind, entity)])
    }

    types = Wire.types(frame["rows"], if(part == 0, do: %{}, else: state.item_types[id] || %{}))
    state = %{state | item_types: Map.put(state.item_types, id, types)}

    buffers =
      if part_state == :done,
        do: Map.delete(state.buffers, id),
        else: Map.put(state.buffers, id, %{events: [], bytes: 0, snapshot_part: part + 1})

    {:push, Protocol.encode(frame), %{state | buffers: buffers}}
  end

  # Replayed events may still be buffered; they go out before the live marker.
  defp stream_message(state, id, {:live, seq}) do
    {frames, state} = flush(state)
    {:push, frames ++ [Protocol.encode(%{"t" => "live", "id" => id, "offset" => seq})], state}
  end

  defp stream_message(state, _id, {:events, []}), do: {:ok, state}

  defp stream_message(state, id, {:events, events}) do
    buffer = Map.get(state.buffers, id, %{events: [], bytes: 0})
    bytes = buffer.bytes + Enum.reduce(events, 0, &(:erlang.external_size(&1.patch) + &2))

    if bytes > @max_buffered do
      # The client has everything before the oldest event it has not been sent.
      oldest = List.last(buffer.events) || hd(events)
      state = unsubscribe(state, id)
      {:push, Protocol.encode(%{"t" => "resync", "id" => id, "offset" => oldest.seq - 1}), state}
    else
      buffer = %{buffer | events: Enum.reverse(events, buffer.events), bytes: bytes}
      state = %{state | buffers: Map.put(state.buffers, id, buffer)}
      {:ok, schedule_flush(state)}
    end
  end

  defp flush(state) do
    {frames, item_types} =
      for {id, %{events: events}} <- state.buffers,
          events != [],
          reduce: {[], state.item_types} do
        {frames, item_types} ->
          events = events |> Enum.reverse() |> Protocol.coalesce()
          {wire, types} = wire_events(events, item_types[id] || %{})

          # The offset stays the last event's, even when trimming dropped it.
          frame =
            Protocol.encode(%{
              "t" => "events",
              "id" => id,
              "offset" => List.last(events).seq,
              "events" => wire
            })

          {[frame | frames], Map.put(item_types, id, types)}
      end

    buffers =
      Map.new(state.buffers, fn {id, buffer} -> {id, %{buffer | events: [], bytes: 0}} end)

    {Enum.reverse(frames), %{state | buffers: buffers, item_types: item_types}}
  end

  defp wire_events(events, types) do
    {wire, types} =
      Enum.reduce(events, {[], types}, fn e, {wire, types} ->
        case Wire.patch(e.kind, e.entity, e.patch, types) do
          {nil, types} -> {wire, types}
          {patch, types} -> {[[e.seq, e.kind, e.entity, patch, e.at] | wire], types}
        end
      end)

    {Enum.reverse(wire), types}
  end

  # The flush message lands behind everything already in the mailbox, so each
  # flush drains a whole burst.
  defp schedule_flush(%{flush_scheduled: true} = state), do: state

  defp schedule_flush(state) do
    send(self(), :flush)
    %{state | flush_scheduled: true}
  end

  defp shell_message(id, {:rows, node, rows}),
    do: %{
      "t" => "shell.rows",
      "id" => id,
      "node" => Atom.to_string(node),
      "rows" => for({sid, {kind, row}} <- rows, do: [sid, kind, row])
    }

  defp shell_message(id, {:environment, node, descriptor}),
    do: %{
      "t" => "shell.environment",
      "id" => id,
      "node" => Atom.to_string(node),
      "environment" => descriptor
    }

  defp shell_message(id, {:node, node, status}),
    do: %{
      "t" => "shell.node",
      "id" => id,
      "node" => Atom.to_string(node),
      "online" => status == :up
    }
end
