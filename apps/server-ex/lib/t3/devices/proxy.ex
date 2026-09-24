defmodule T3.Devices.Proxy do
  @moduledoc """
  `/api/device-hub/*`: the device hub (`T3.Devices`) of any node in the cluster,
  served by the node a client is connected to.

  A path names the node that owns the devices, `/api/device-hub/nodes/<node>/…` (the
  `hubBasePath` each node reports); a path without one is this node's. The receiving
  node checks the credential and relays the request to a process on the owning
  node, which talks to that node's loopback hub. Responses stream (MJPEG never
  ends), and WebSockets are relayed frame by frame, both paced by the client.

  The hub exposes shell execution and unauthenticated device control, so only the
  routes the Device panel needs pass: reading needs `orchestration:read`, controlling
  a device `orchestration:operate`. `<img>` and WebSocket cannot set headers, so the
  credential is the `wsTicket` query parameter (reusable while it lasts), a bearer
  header, or the node's own `token`.
  """

  import Plug.Conn

  @allowed [
    ~r"^/api/devices$",
    ~r"^/vendor/serve-sim/api$",
    ~r"^/vendor/serve-sim/api/screenshot$",
    ~r"^/vendor/serve-sim/api/event-log(/events)?$",
    ~r"^/vendor/serve-sim/helper/[^/]+/(stream\.mjpeg|stream\.avcc|config|health|ax|foreground)$",
    ~r"^/vendor/serve-sim/appstate$",
    ~r"^/vendor/serve-emu/api/(devices|screenshot|stream-mode|stream-settings|accessibility)$",
    ~r"^/vendor/serve-emu/health$"
  ]
  # Reads are GET-only; only these take other methods.
  @mutable [
    ~r"^/vendor/serve-sim/api/screenshot$",
    ~r"^/vendor/serve-emu/api/(screenshot|stream-mode|stream-settings)$"
  ]
  @sockets [
    ~r"^/api/devices/ws$",
    ~r"^/vendor/serve-sim/helper/ws$",
    ~r"^/vendor/serve-emu/ws$"
  ]
  @dropped_request ~w(host connection upgrade keep-alive te transfer-encoding sec-websocket-key
                      sec-websocket-version sec-websocket-extensions sec-websocket-protocol cookie
                      authorization dpop content-length accept-encoding)
  @dropped_response ~w(connection keep-alive transfer-encoding content-length)
  @credentials ~w(wsTicket hostId token)

  @doc "Serves one `/api/device-hub` request; `segments` is the path after the prefix."
  def serve(conn, segments) do
    conn = fetch_query_params(conn)

    {owner, rest} =
      case segments do
        ["nodes", name | rest] -> {known_node(URI.decode_www_form(name)), rest}
        rest -> {node(), rest}
      end

    path = "/" <> Enum.join(rest, "/")
    socket = websocket?(conn)
    read_only = conn.method in ~w(GET HEAD)

    cond do
      owner == nil or not Enum.any?(if(socket, do: @sockets, else: @allowed), &(path =~ &1)) ->
        send_resp(conn, 404, "Not Found")

      not socket and not read_only and not Enum.any?(@mutable, &(path =~ &1)) ->
        send_resp(conn, 405, "Method Not Allowed")

      true ->
        controls =
          (socket and path != "/api/devices/ws") or
            (not read_only and path =~ ~r"/api/stream-(mode|settings)$")

        case authorize(
               conn,
               if(controls, do: "orchestration:operate", else: "orchestration:read")
             ) do
          :ok -> relay(conn, owner, path <> search(conn), socket)
          {status, body} -> json(conn, status, body)
        end
    end
  end

  defp relay(conn, owner, path, true) do
    conn
    |> WebSockAdapter.upgrade(T3.Devices.ProxySocket, %{owner: owner, path: path},
      timeout: :timer.hours(24)
    )
    |> halt()
  end

  defp relay(conn, owner, path, false) do
    with {:ok, body, conn} <- request_body(conn),
         request = %{method: conn.method, path: path, headers: forward_headers(conn), body: body},
         {:ok, relay} <- start(owner, :http, request) do
      ref = Process.monitor(relay)

      receive do
        {:device_hub, ^relay, {:response, status, headers}} ->
          conn
          |> merge_resp_headers(headers)
          # Long-lived MJPEG and AVCC responses must not be buffered or compressed.
          |> put_resp_header("cache-control", "no-store, no-transform")
          |> send_chunked(status)
          |> stream(relay, ref)

        {:device_hub, ^relay, {:error, _}} ->
          send_resp(conn, 502, "The device hub did not answer.")

        {:DOWN, ^ref, _, _, _} ->
          send_resp(conn, 502, "The device hub did not answer.")
      after
        30_000 ->
          send(relay, :stop)
          send_resp(conn, 504, "The device hub did not answer in time.")
      end
    else
      {:error, :not_running} -> send_resp(conn, 503, "Device hub is not running")
      {:error, :too_large} -> send_resp(conn, 413, "Request Entity Too Large")
      _ -> send_resp(conn, 502, "The node with this device is unavailable.")
    end
  end

  defp stream(conn, relay, ref) do
    receive do
      {:device_hub, ^relay, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} ->
            send(relay, :ack)
            stream(conn, relay, ref)

          {:error, _} ->
            send(relay, :stop)
            conn
        end

      {:device_hub, ^relay, :done} ->
        Process.demonitor(ref, [:flush])
        conn

      {:device_hub, ^relay, {:error, _}} ->
        conn

      {:DOWN, ^ref, _, _, _} ->
        conn
    end
  end

  defp request_body(%{method: method} = conn) when method in ~w(GET HEAD), do: {:ok, nil, conn}

  defp request_body(conn) do
    case read_body(conn, length: 10_000_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      _ -> {:error, :too_large}
    end
  end

  defp forward_headers(conn),
    do: for({name, value} <- conn.req_headers, name not in @dropped_request, do: {name, value})

  # Every credential is this node's business; the hub never sees one.
  defp search(%{query_string: ""}), do: ""

  defp search(conn) do
    kept =
      conn.query_string
      |> String.split("&", trim: true)
      |> Enum.reject(&((&1 |> String.split("=", parts: 2) |> hd()) in @credentials))

    if kept == [], do: "", else: "?" <> Enum.join(kept, "&")
  end

  defp websocket?(conn),
    do: Enum.any?(get_req_header(conn, "upgrade"), &(String.downcase(&1) == "websocket"))

  defp known_node(name), do: Enum.find([node() | Node.list()], &(Atom.to_string(&1) == name))

  defp authorize(conn, scope) do
    scopes =
      case {conn.query_params, get_req_header(conn, "authorization")} do
        {%{"wsTicket" => ticket}, _} when is_binary(ticket) ->
          T3.Auth.ticket_scopes(ticket)

        {%{"token" => token}, _} when is_binary(token) ->
          if Plug.Crypto.secure_compare(token, T3.Web.token()), do: {:ok, :all}, else: :error

        {_, ["Bearer " <> bearer]} ->
          with {:ok, session} <- T3.Auth.session(bearer), do: {:ok, session.scopes}

        # A browser running the app this node serves (`T3.Web.Router`).
        {_, []} ->
          with token when is_binary(token) <-
                 Plug.Conn.fetch_cookies(conn).cookies[T3.Environment.session_cookie()],
               {:ok, session} <- T3.Auth.session(token),
               do: {:ok, session.scopes},
               else: (_ -> :error)

        _ ->
          :error
      end

    case scopes do
      {:ok, :all} ->
        :ok

      {:ok, scopes} ->
        if scope in scopes,
          do: :ok,
          else:
            {403,
             %{
               "_tag" => "EnvironmentScopeRequiredError",
               "code" => "insufficient_scope",
               "requiredScope" => scope
             }}

      :error ->
        {401,
         %{
           "_tag" => "EnvironmentAuthInvalidError",
           "code" => "auth_invalid",
           "reason" => "invalid_credential"
         }}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  # --- relays ----------------------------------------------------------------------------

  @doc """
  Starts a relay on `owner` that sends its hub's answer to the calling process as
  `{:device_hub, relay, event}`: `{:response, status, headers}`, `{:data, binary}`
  (answered with `:ack`), `:done` or `{:error, reason}` for HTTP; `:open`,
  `{:frames, frames}` (answered with `:ack`) and `:closed` for a WebSocket, which
  takes `{:frame, frame}` to send. `:stop` ends either.
  """
  def start(owner, mode, request) do
    :erpc.call(owner, __MODULE__, :spawn_relay, [self(), mode, request], 15_000)
  catch
    _, _ -> {:error, :unavailable}
  end

  @doc false
  def spawn_relay(caller, mode, request) do
    case T3.Devices.hub_origin() do
      nil -> {:error, :not_running}
      origin -> {:ok, spawn(fn -> relay_init(caller, mode, URI.parse(origin), request) end)}
    end
  end

  defp relay_init(caller, :http, uri, request) do
    ref = Process.monitor(caller)

    # serve-emu refuses mutations whose Origin differs from its own.
    headers =
      for {name, value} <- request.headers,
          do:
            if(name == "origin",
              do: {name, "http://#{uri.host}:#{uri.port}"},
              else: {name, value}
            )

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, uri.port),
         {:ok, conn, req} <-
           Mint.HTTP.request(conn, request.method, request.path, headers, request.body) do
      http_loop(conn, req, caller, ref, nil)
    else
      error -> send(caller, {:device_hub, self(), {:error, inspect(error)}})
    end
  end

  defp relay_init(caller, :ws, uri, %{path: path}) do
    ref = Process.monitor(caller)

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, uri.port),
         {:ok, conn, req} <- Mint.WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, ws, early} <- await_upgrade(conn, req, []) do
      send(caller, {:device_hub, self(), :open})
      {:ok, ws, frames} = Mint.WebSocket.decode(ws, early)

      case deliver(frames, conn, ws, req, caller, ref) do
        {:ok, conn, ws} -> ws_loop(conn, ws, req, caller, ref)
        :stop -> Mint.HTTP.close(conn)
      end
    else
      _ -> send(caller, {:device_hub, self(), :closed})
    end
  end

  defp http_loop(conn, req, caller, ref, status) do
    receive do
      {:DOWN, ^ref, _, _, _} ->
        Mint.HTTP.close(conn)

      :stop ->
        Mint.HTTP.close(conn)

      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            http_loop(conn, req, caller, ref, status)

          {:ok, conn, responses} ->
            {status, data, done} =
              Enum.reduce(responses, {status, [], false}, fn
                {:status, ^req, code}, {_, data, done} ->
                  {code, data, done}

                {:headers, ^req, headers}, {code, data, done} when is_integer(code) ->
                  kept =
                    for {name, value} <- headers, name not in @dropped_response, do: {name, value}

                  send(caller, {:device_hub, self(), {:response, code, kept}})
                  {:sent, data, done}

                {:data, ^req, chunk}, {code, data, done} ->
                  {code, [data, chunk], done}

                {:done, ^req}, {code, data, _} ->
                  {code, data, true}

                _, acc ->
                  acc
              end)

            data = IO.iodata_to_binary(data)
            delivered = data == "" or ack(caller, ref, {:data, data})

            cond do
              not delivered ->
                Mint.HTTP.close(conn)

              done ->
                send(caller, {:device_hub, self(), :done})
                Mint.HTTP.close(conn)

              true ->
                http_loop(conn, req, caller, ref, status)
            end

          {:error, conn, reason, _} ->
            send(caller, {:device_hub, self(), {:error, inspect(reason)}})
            Mint.HTTP.close(conn)
        end
    end
  end

  defp await_upgrade(conn, req, acc) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      message
      when is_tuple(message) and elem(message, 0) in [:tcp, :tcp_closed, :tcp_error] and
             elem(message, 1) == socket ->
        with {:ok, conn, responses} <- Mint.WebSocket.stream(conn, message) do
          acc = acc ++ responses

          if Enum.any?(acc, &match?({:done, ^req}, &1)) do
            status =
              Enum.find_value(acc, fn
                {:status, ^req, s} -> s
                _ -> nil
              end)

            headers =
              Enum.find_value(acc, [], fn
                {:headers, ^req, h} -> h
                _ -> nil
              end)

            early = for {:data, ^req, data} <- acc, into: "", do: data

            with {:ok, conn, ws} <- Mint.WebSocket.new(conn, req, status, headers),
                 do: {:ok, conn, ws, early}
          else
            await_upgrade(conn, req, acc)
          end
        end
    after
      10_000 -> {:error, :timeout}
    end
  end

  defp ws_loop(conn, ws, req, caller, ref) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {:DOWN, ^ref, _, _, _} ->
        close(conn, ws, req)

      :stop ->
        close(conn, ws, req)

      {:frame, frame} ->
        case send_frame(conn, ws, req, frame) do
          {:ok, conn, ws} -> ws_loop(conn, ws, req, caller, ref)
          _ -> send(caller, {:device_hub, self(), :closed})
        end

      message
      when is_tuple(message) and elem(message, 0) in [:tcp, :tcp_closed, :tcp_error] and
             elem(message, 1) == socket ->
        with {:ok, conn, responses} <- Mint.WebSocket.stream(conn, message),
             data = for({:data, ^req, data} <- responses, into: "", do: data),
             {:ok, ws, frames} <- Mint.WebSocket.decode(ws, data),
             {:ok, conn, ws} <- deliver(frames, conn, ws, req, caller, ref) do
          ws_loop(conn, ws, req, caller, ref)
        else
          _ ->
            send(caller, {:device_hub, self(), :closed})
            Mint.HTTP.close(conn)
        end
    end
  end

  # Answers pings, ends on a close, and hands everything else to the client.
  defp deliver(frames, conn, ws, req, caller, ref) do
    {conn, ws} =
      Enum.reduce(frames, {conn, ws}, fn
        {:ping, data}, {conn, ws} ->
          case send_frame(conn, ws, req, {:pong, data}) do
            {:ok, conn, ws} -> {conn, ws}
            _ -> {conn, ws}
          end

        _, acc ->
          acc
      end)

    data = for {kind, _} = frame <- frames, kind in [:text, :binary], do: frame

    cond do
      Enum.any?(frames, &match?({:close, _, _}, &1)) ->
        send(caller, {:device_hub, self(), :closed})
        :stop

      data == [] or ack(caller, ref, {:frames, data}) ->
        {:ok, conn, ws}

      true ->
        :stop
    end
  end

  defp send_frame(conn, ws, req, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, req, data),
         do: {:ok, conn, ws}
  end

  defp close(conn, ws, req) do
    send_frame(conn, ws, req, :close)
    Mint.HTTP.close(conn)
  end

  # One message in flight: the next is read from the hub once the client took this one.
  defp ack(caller, ref, event) do
    send(caller, {:device_hub, self(), event})

    receive do
      :ack -> true
      :stop -> false
      {:DOWN, ^ref, _, _, _} -> false
    end
  end
end

defmodule T3.Devices.ProxySocket do
  @moduledoc "A client WebSocket to a device hub, relayed by `T3.Devices.Proxy`."

  @behaviour WebSock

  @impl true
  def init(%{owner: owner, path: path}) do
    case T3.Devices.Proxy.start(owner, :ws, %{path: path}) do
      {:ok, relay} -> {:ok, %{relay: relay, ref: Process.monitor(relay)}}
      _ -> {:stop, :normal, %{relay: nil}}
    end
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) when opcode in [:text, :binary] do
    send(state.relay, {:frame, {opcode, data}})
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:device_hub, relay, {:frames, frames}}, %{relay: relay} = state) do
    send(relay, :ack)
    {:push, frames, state}
  end

  def handle_info({:device_hub, relay, :closed}, %{relay: relay} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, _, _, _}, %{ref: ref} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{relay: relay}) when is_pid(relay), do: send(relay, :stop)
  def terminate(_reason, _state), do: :ok
end
