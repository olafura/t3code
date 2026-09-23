defmodule T3.AuthTest do
  use ExUnit.Case, async: false

  alias T3.Test.WsClient

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, 0)
    :persistent_term.erase({T3.Web, :token})
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Auth)
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    {:ok, _} = Application.ensure_all_started(:inets)
    %{port: port, path: Path.join(dir, "t3.sqlite")}
  end

  # The same requests, in the same order, the client runtime makes when pairing.
  test "pairing token -> bearer token -> ws ticket -> socket", %{port: port, path: path} do
    pairing = T3.Auth.create_pairing_token(path)
    base = "http://127.0.0.1:#{port}"

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => pairing,
      "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
      "requested_token_type" => "urn:ietf:params:oauth:token-type:access_token",
      "client_label" => "test"
    }

    assert {200, %{"access_token" => access, "token_type" => "Bearer", "scope" => scope}} =
             post_form(base <> "/oauth/token", form)

    assert scope =~ "orchestration:read"
    # Pairing tokens are single use.
    assert {400, _} = post_form(base <> "/oauth/token", form)

    assert {200, %{"authenticated" => true, "sessionMethod" => "bearer-access-token"}} =
             request(:get, base <> "/api/auth/session", access)

    assert {200, %{"authenticated" => false}} = request(:get, base <> "/api/auth/session", nil)
    assert {401, _} = request(:post, base <> "/api/auth/websocket-ticket", "wrong")

    assert {200, %{"ticket" => ticket, "expiresAt" => _}} =
             request(:post, base <> "/api/auth/websocket-ticket", access)

    assert {:ok, client} = WsClient.connect(port, "/ws?wsTicket=#{ticket}")
    assert {%{"t" => "hello"}, _} = WsClient.recv(client, 1_000)
    # Tickets open one socket.
    assert {:error, 401} = WsClient.connect(port, "/ws?wsTicket=#{ticket}")
  end

  test "the desktop app's bootstrap token signs its window in, as often as needed", %{
    port: port
  } do
    :ok = stop_supervised(T3.Auth)
    :ok = T3.Desktop.apply_bootstrap(%{"desktopBootstrapToken" => "desk-token"})
    on_exit(fn -> Application.delete_env(:t3, :desktop_token) end)
    start_supervised!(T3.Auth)

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => "desk-token",
      "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
      "client_label" => "T3 Code Desktop"
    }

    base = "http://127.0.0.1:#{port}"
    assert {200, %{"scope" => scope}} = post_form(base <> "/oauth/token", form)
    assert scope =~ "access:write"
    # A reloaded window exchanges it again.
    assert {200, %{"access_token" => _}} = post_form(base <> "/oauth/token", form)
    assert {400, _} = post_form(base <> "/oauth/token", %{form | "subject_token" => "other"})
  end

  test "an administrator makes pairing links, and sees and revokes paired clients", %{port: port} do
    :ok = stop_supervised(T3.Auth)
    :ok = T3.Desktop.apply_bootstrap(%{"desktopBootstrapToken" => "desk-token"})
    on_exit(fn -> Application.delete_env(:t3, :desktop_token) end)
    start_supervised!(T3.Auth)
    base = "http://127.0.0.1:#{port}"

    exchange = fn token, label ->
      post_form(base <> "/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => token,
        "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
        "client_label" => label
      })
    end

    {200, %{"access_token" => admin}} = exchange.("desk-token", "T3 Code Desktop")

    assert {200, %{"id" => link_id, "credential" => credential, "label" => "Phone"}} =
             request(:post, base <> "/api/auth/pairing-token", admin, %{"label" => "Phone"})

    assert {200, [%{"id" => ^link_id, "label" => "Phone"}]} =
             request(:get, base <> "/api/auth/pairing-links", admin)

    # Using the link removes it and pairs a client with standard scopes.
    {200, %{"access_token" => phone}} = exchange.(credential, "Phone")
    assert {200, []} = request(:get, base <> "/api/auth/pairing-links", admin)

    assert {200, clients} = request(:get, base <> "/api/auth/clients", admin)
    assert [%{"current" => true}, %{"current" => false, "sessionId" => phone_session}] = clients

    # A standard client cannot manage access, and nobody can revoke themselves.
    assert {403, %{"_tag" => "EnvironmentScopeRequiredError"}} =
             request(:get, base <> "/api/auth/clients", phone)

    [%{"sessionId" => admin_session} | _] = clients

    assert {403, %{"reason" => "current_session_revoke_not_allowed"}} =
             request(:post, base <> "/api/auth/clients/revoke", admin, %{
               "sessionId" => admin_session
             })

    assert {200, %{"revoked" => true}} =
             request(:post, base <> "/api/auth/clients/revoke", admin, %{
               "sessionId" => phone_session
             })

    assert {200, %{"authenticated" => false}} = request(:get, base <> "/api/auth/session", phone)
  end

  test "a desktop bootstrap line sets where the node listens and keeps its state" do
    on_exit(fn -> Application.delete_env(:t3, :host) end)

    :ok =
      T3.Desktop.apply_bootstrap(%{
        "port" => 4123,
        "host" => "0.0.0.0",
        "t3Home" => "/home/me/.t3",
        "noBrowser" => true
      })

    assert Application.get_env(:t3, :port) == 4123
    assert Application.get_env(:t3, :host) == "0.0.0.0"
    assert Application.get_env(:t3, :home) == "/home/me/.t3/elixir"
  end

  test "browsers on other origins may call the node", %{port: port} do
    {:ok, {{_, 204, _}, headers, _}} =
      :httpc.request(:options, {"http://127.0.0.1:#{port}/oauth/token", []}, [], [])

    assert {~c"access-control-allow-origin", ~c"*"} in headers
    assert {_, allowed} = List.keyfind(headers, ~c"access-control-allow-headers", 0)
    assert to_string(allowed) =~ "authorization"
  end

  test "a pairing link opened in a browser explains where to paste it", %{port: port} do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(~c"http://127.0.0.1:#{port}/?token=abc")
    assert :binary.list_to_bin(body) =~ "Settings → Connections"
  end

  defp post_form(url, form) do
    body = URI.encode_query(form)

    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(:post, {url, [], ~c"application/x-www-form-urlencoded", body}, [], [])

    {status, JSON.decode!(to_string(resp))}
  end

  defp request(method, url, bearer, body \\ nil) do
    headers = if bearer, do: [{~c"authorization", ~c"Bearer " ++ to_charlist(bearer)}], else: []

    req =
      if method == :post,
        do: {url, headers, ~c"application/json", if(body, do: JSON.encode!(body), else: "")},
        else: {url, headers}

    {:ok, {{_, status, _}, _, resp}} = :httpc.request(method, req, [], [])
    {status, JSON.decode!(to_string(resp))}
  end
end
