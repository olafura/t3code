defmodule T3.Web.Router do
  @moduledoc """
  HTTP entry point: environment discovery, pairing and session auth (`T3.Auth`), and
  the client WebSocket. A socket needs a WebSocket ticket, or the node's own access
  token (`T3.Web.token/0`) for local tools.
  """

  use Plug.Router

  @cors_headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, OPTIONS"},
    {"access-control-allow-headers",
     "authorization, b3, traceparent, content-type, dpop, x-t3-orchestration-protocol"},
    {"access-control-max-age", "600"}
  ]

  plug :cors
  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  # Clients reach a node from other origins (the hosted app, another dev server)
  # with bearer tokens rather than cookies, so any origin may call it.
  defp cors(%{method: "OPTIONS"} = conn, _opts),
    do: conn |> merge_resp_headers(@cors_headers) |> send_resp(204, "") |> halt()

  defp cors(conn, _opts), do: merge_resp_headers(conn, @cors_headers)

  get "/.well-known/t3/environment" do
    body =
      T3.Environment.descriptor()
      |> Map.put("node", Atom.to_string(node()))
      |> Map.put("cluster", cluster())
      |> JSON.encode_to_iodata!()

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # A pairing link opened in a browser lands here. The node serves no app, so the
  # page says where the link goes instead of answering "not found".
  get "/" do
    label = T3.Environment.descriptor()["label"]

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, """
    <!doctype html><meta charset="utf-8"><title>T3 node #{Plug.HTML.html_escape(label)}</title>
    <body style="font:15px system-ui;max-width:34em;margin:4em auto;padding:0 1em;line-height:1.5">
    <h1 style="font-size:1.3em">T3 node: #{Plug.HTML.html_escape(label)}</h1>
    <p>This is a pairing link for a T3 node. To connect, copy the full address from the
    address bar and paste it into <b>T3 Code → Settings → Connections → Add environment</b>.</p>
    <p>Pairing links work once and expire after 5 minutes.</p>
    </body>
    """)
  end

  # Pairing: exchange a one-time pairing token for a bearer access token.
  post "/oauth/token" do
    params = conn.body_params

    with "urn:ietf:params:oauth:grant-type:token-exchange" <- params["grant_type"],
         "urn:t3:params:oauth:token-type:environment-bootstrap" <- params["subject_token_type"],
         {:ok, access, expires_in, scopes} <-
           T3.Auth.exchange(params["subject_token"] || "", %{
             label: params["client_label"],
             device_type: params["client_device_type"],
             os: params["client_os"],
             user_agent: conn |> get_req_header("user-agent") |> List.first()
           }) do
      json(conn, 200, %{
        "access_token" => access,
        "issued_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "token_type" => "Bearer",
        "expires_in" => expires_in,
        "scope" => Enum.join(scopes, " ")
      })
    else
      _ -> json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  get "/api/auth/session" do
    auth = T3.Environment.server_config()["auth"]

    case bearer_session(conn) do
      {:ok, session} ->
        json(conn, 200, %{
          "authenticated" => true,
          "auth" => auth,
          "scopes" => session.scopes,
          "sessionMethod" => "bearer-access-token",
          "expiresAt" => iso(session.expires_at)
        })

      :error ->
        json(conn, 200, %{"authenticated" => false, "auth" => auth})
    end
  end

  post "/api/auth/websocket-ticket" do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, ticket, expires_at} <- T3.Auth.issue_ticket(token) do
      json(conn, 200, %{"ticket" => ticket, "expiresAt" => iso(expires_at)})
    else
      _ ->
        json(conn, 401, %{"_tag" => "EnvironmentAuthorizationError", "message" => "unauthorized"})
    end
  end

  # The `t3-code` MCP server for agents; each thread's agent has its own bearer.
  post "/mcp" do
    {:ok, body, conn} = read_body(conn, length: 10_000_000)
    authorization = conn |> get_req_header("authorization") |> List.first()

    case T3.Mcp.handle(authorization, body) do
      {status, nil} -> send_resp(conn, status, "")
      {status, reply} -> json(conn, status, reply)
    end
  end

  # No server-initiated stream: every answer comes back on its request.
  get "/mcp", do: send_resp(conn, 405, "")
  delete "/mcp", do: send_resp(conn, 200, "")

  # Settings → Connections: pairing links and the clients paired with this node.
  post "/api/auth/pairing-token" do
    with_scope(conn, "access:write", fn _session ->
      with {:ok, body} <- json_body(conn),
           {:ok, link} <- T3.Auth.create_pairing_link(body),
           do: {200, link}
    end)
  end

  get "/api/auth/pairing-links" do
    with_scope(conn, "access:read", fn _session -> {200, T3.Auth.pairing_links()} end)
  end

  post "/api/auth/pairing-links/revoke" do
    with_scope(conn, "access:write", fn _session ->
      with {:ok, %{"id" => id}} <- json_body(conn),
           do: {200, %{"revoked" => T3.Auth.revoke_pairing_link(id)}}
    end)
  end

  get "/api/auth/clients" do
    with_scope(conn, "access:read", fn session ->
      {200,
       for(
         client <- T3.Auth.clients(),
         do: %{client | "current" => client["sessionId"] == session.id}
       )}
    end)
  end

  post "/api/auth/clients/revoke" do
    with_scope(conn, "access:write", fn session ->
      case json_body(conn) do
        {:ok, %{"sessionId" => id}} when id == session.id ->
          {403,
           %{
             "_tag" => "EnvironmentOperationForbiddenError",
             "code" => "operation_forbidden",
             "reason" => "current_session_revoke_not_allowed",
             "traceId" => trace_id()
           }}

        {:ok, %{"sessionId" => id}} ->
          {200, %{"revoked" => T3.Auth.revoke_client(id)}}

        error ->
          error
      end
    end)
  end

  post "/api/auth/clients/revoke-others" do
    with_scope(conn, "access:write", fn session ->
      {200, %{"revokedCount" => T3.Auth.revoke_other_clients(session.id)}}
    end)
  end

  # A pull request's patch, which is large enough to want HTTP rather than the socket.
  post "/api/pull-requests/diff" do
    with_scope(conn, "orchestration:read", fn _session ->
      with {:ok, input} <- json_body(conn) do
        case T3.PullRequests.diff_on_project_node(input) do
          {:ok, result} ->
            {200, result}

          {:error, %{"_tag" => tag} = error} ->
            status = if tag == "PullRequestUnavailableError", do: 503, else: 502
            {status, Map.delete(error, "message")}
        end
      end
    end)
  end

  get "/ws" do
    conn = fetch_query_params(conn)

    case socket_session(conn.query_params) do
      {:ok, session} ->
        conn
        |> WebSockAdapter.upgrade(T3.Web.Socket, %{session: session}, timeout: 60_000)
        |> halt()

      :error ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  # Every node this one knows, so a client paired here can reach all of them.
  defp cluster do
    for {_node, descriptor} <- T3.Shell.environments(),
        do: Map.take(descriptor, ["environmentId", "label"])
  end

  # The session a socket opens for, or nil for one opened with the node's own token.
  defp socket_session(%{"wsTicket" => ticket}), do: T3.Auth.take_ticket(ticket)

  # The node's own access token, for local tools and development.
  defp socket_session(%{"token" => token}),
    do: if(Plug.Crypto.secure_compare(token, T3.Web.token()), do: {:ok, nil}, else: :error)

  defp socket_session(_), do: :error

  # Runs `fun.(session)` for a bearer whose session has `scope`; `fun` returns
  # `{status, body}` or `{:error, reason}`.
  defp with_scope(conn, scope, fun) do
    case bearer_session(conn) do
      {:ok, session} ->
        if scope in session.scopes do
          case fun.(session) do
            {status, body} when is_integer(status) ->
              json(conn, status, body)

            {:error, _} ->
              json(conn, 400, %{
                "_tag" => "EnvironmentRequestInvalidError",
                "traceId" => trace_id()
              })
          end
        else
          json(conn, 403, %{
            "_tag" => "EnvironmentScopeRequiredError",
            "code" => "insufficient_scope",
            "requiredScope" => scope,
            "traceId" => trace_id()
          })
        end

      :error ->
        reason =
          if get_req_header(conn, "authorization") == [],
            do: "missing_credential",
            else: "invalid_credential"

        json(conn, 401, %{
          "_tag" => "EnvironmentAuthInvalidError",
          "code" => "auth_invalid",
          "reason" => reason,
          "traceId" => trace_id()
        })
    end
  end

  defp json_body(conn) do
    with {:ok, body, _conn} <- read_body(conn),
         {:ok, %{} = decoded} <- JSON.decode(if(body == "", do: "{}", else: body)) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_body}
    end
  end

  defp trace_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp bearer_session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> T3.Auth.session(token)
      _ -> :error
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # Signed URLs are their own authorization. Each names the node that issued it,
  # which holds the file and checks the signature; this node only forwards.
  post "/api/attachments/upload/:token" do
    with {:ok, node} <- T3.Attachments.issuer(token),
         {:ok, body, conn} <- read_all(conn, 50 * 1024 * 1024 + 1, []) do
      case remote(node, T3.Attachments, :store, [token, body]) do
        :ok -> send_resp(conn, 204, "")
        {:error, status, message} -> send_resp(conn, status, message)
        _ -> send_resp(conn, 502, "The node holding this upload is unavailable.")
      end
    else
      :too_large -> send_resp(conn, 413, "The upload is too large.")
      _ -> send_resp(conn, 403, "The link is invalid or expired.")
    end
  end

  # A version's bundle, for a cluster peer holding a one-time link (`T3.Upgrade.Source`).
  get "/api/upgrade/:token" do
    case T3.Upgrade.Source.take(token) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("application/gzip", nil)
        |> send_file(200, path)

      :error ->
        send_resp(conn, 403, "The link is invalid or expired.")
    end
  end

  get "/api/assets/:token" do
    with {:ok, node} <- T3.Attachments.issuer(token),
         {:ok, bytes, mime, name, disposition} <- remote(node, T3.Attachments, :read, [token]) do
      conn
      |> put_resp_content_type(mime || "application/octet-stream", nil)
      |> put_resp_header(
        "content-disposition",
        ~s(#{disposition || "inline"}; filename="#{String.replace(name || "file", ~s("), "")}")
      )
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, bytes)
    else
      {:error, status, message} -> send_resp(conn, status, message)
      _ -> send_resp(conn, 403, "The link is invalid or expired.")
    end
  end

  defp read_all(conn, left, acc) do
    case read_body(conn, length: min(left, 8_000_000)) do
      {:ok, data, conn} ->
        if byte_size(data) >= left,
          do: :too_large,
          else: {:ok, IO.iodata_to_binary([acc, data]), conn}

      {:more, data, conn} ->
        if byte_size(data) >= left,
          do: :too_large,
          else: read_all(conn, left - byte_size(data), [acc, data])

      {:error, _} = error ->
        error
    end
  end

  defp remote(node, module, fun, args) do
    :erpc.call(node, module, fun, args, 60_000)
  catch
    _, _ -> {:error, 502, "The node holding this file is unavailable."}
  end

  # Every node's device hub, relayed to the node that owns it (`T3.Devices.Proxy`).
  match "/api/device-hub/*rest", do: T3.Devices.Proxy.serve(conn, rest)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
