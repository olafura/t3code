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
      JSON.encode_to_iodata!(Map.put(T3.Environment.descriptor(), "node", Atom.to_string(node())))

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # Pairing: exchange a one-time pairing token for a bearer access token.
  post "/oauth/token" do
    params = conn.body_params

    with "urn:ietf:params:oauth:grant-type:token-exchange" <- params["grant_type"],
         "urn:t3:params:oauth:token-type:environment-bootstrap" <- params["subject_token_type"],
         {:ok, access, expires_in, scopes} <-
           T3.Auth.exchange(params["subject_token"] || "", params["client_label"]) do
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

  get "/ws" do
    conn = fetch_query_params(conn)

    if authorized_socket?(conn.query_params) do
      conn |> WebSockAdapter.upgrade(T3.Web.Socket, [], timeout: 60_000) |> halt()
    else
      send_resp(conn, 401, "unauthorized")
    end
  end

  defp authorized_socket?(%{"wsTicket" => ticket}), do: T3.Auth.take_ticket(ticket) == :ok

  # The node's own access token, for local tools and development.
  defp authorized_socket?(%{"token" => token}),
    do: Plug.Crypto.secure_compare(token, T3.Web.token())

  defp authorized_socket?(_), do: false

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

  match _ do
    send_resp(conn, 404, "not found")
  end
end
