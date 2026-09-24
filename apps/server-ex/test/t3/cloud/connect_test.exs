defmodule T3.Cloud.ConnectTest do
  use ExUnit.Case, async: false

  alias T3.Cloud.Jwt
  alias T3.Test.DpopClient

  @moduletag :tmp_dir
  @relay "https://relay.test"

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, 0)
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Auth)
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!(T3.Cloud.Tunnel)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, admin} =
      T3.Auth.create_pairing_link(%{
        "scopes" => ~w(orchestration:read relay:read relay:write access:read)
      })

    {:ok, token, _, _} = T3.Auth.exchange(admin["credential"])
    %{port: port, token: token, relay: Jwt.generate_key_pair(), id: T3.Environment.id()}
  end

  test "a client links the node, and the relay reaches it and mints credentials", ctx do
    %{port: port, token: token, relay: relay, id: id} = ctx
    bearer = [{"authorization", "Bearer " <> token}]

    # The link proof is signed by the node's key for the relay, from its loopback origin.
    request = %{
      "challenge" => "c1",
      "relayIssuer" => @relay <> "/",
      "endpoint" => %{
        "httpBaseUrl" => "http://127.0.0.1:#{port}",
        "wsBaseUrl" => "ws://127.0.0.1:#{port}",
        "providerKind" => "manual"
      },
      "origin" => %{"localHttpHost" => "127.0.0.1", "localHttpPort" => port}
    }

    assert {200, proof, headers} = http(port, :post, "/api/connect/link-proof", bearer, request)
    assert {"cache-control", "no-store"} in headers

    assert {:ok, %{"challenge" => "c1", "scopes" => ["agent_activity_notifications"]}} =
             Jwt.verify(
               T3.Cloud.key_pair()["publicKey"],
               proof,
               "t3-env-link+jwt",
               "t3-env:#{id}",
               @relay,
               System.os_time(:second)
             )

    assert {400, _, _} =
             http(
               port,
               :post,
               "/api/connect/link-proof",
               bearer ++ [{"x-forwarded-host", "evil"}],
               request
             )

    wrong_port = put_in(request, ["origin", "localHttpPort"], port + 1)
    assert {400, _, _} = http(port, :post, "/api/connect/link-proof", bearer, wrong_port)

    # The relay's answer, passed back by the client.
    config = %{
      "relayUrl" => @relay,
      "cloudUserId" => "user_1",
      "environmentCredential" => "env-cred",
      "cloudMintPublicKey" => relay["publicKey"],
      "endpointRuntime" => nil
    }

    assert {200, %{"ok" => true, "endpointRuntimeStatus" => %{"status" => "disabled"}}, _} =
             http(port, :post, "/api/connect/relay-config", bearer, config)

    assert {409, %{"_tag" => "EnvironmentHttpConflictError"}, _} =
             http(port, :post, "/api/connect/relay-config", bearer, %{
               config
               | "cloudUserId" => "user_2"
             })

    assert {200, %{"linked" => true, "cloudUserId" => "user_1", "publishAgentActivity" => false},
            _} = http(port, :get, "/api/connect/link-state", bearer)

    assert {200, %{"publishAgentActivity" => true}, _} =
             http(port, :post, "/api/connect/preferences", bearer, %{
               "publishAgentActivity" => true
             })

    assert T3.Cloud.publishing?()

    # Health: signed by the relay's mint key, answered with a proof bound to its nonce.
    health = relay_proof(relay, "t3-cloud-health+jwt", id, %{"scope" => ["environment:status"]})

    assert {200, %{"status" => "online", "proof" => answer}, _} =
             http(port, :post, "/api/t3-connect/health", [], %{"proof" => health})

    assert {:ok, %{"requestNonce" => nonce}} =
             Jwt.verify(
               T3.Cloud.key_pair()["publicKey"],
               answer,
               "t3-env-health+jwt",
               "t3-env:#{id}",
               @relay,
               System.os_time(:second)
             )

    assert nonce ==
             JSON.decode!(
               Base.url_decode64!(Enum.at(String.split(health, "."), 1), padding: false)
             )["nonce"]

    assert {409, _, _} = http(port, :post, "/api/t3-connect/health", [], %{"proof" => health})

    forged =
      relay_proof(Jwt.generate_key_pair(), "t3-cloud-health+jwt", id, %{
        "scope" => ["environment:status"]
      })

    assert {401, _, _} = http(port, :post, "/api/t3-connect/health", [], %{"proof" => forged})

    # Mint: a one-time credential only the client's DPoP key can redeem.
    client = DpopClient.new()
    thumbprint = DpopClient.thumbprint(client)

    mint =
      relay_proof(relay, "t3-cloud-mint+jwt", id, %{
        "scope" => ["environment:connect"],
        "clientProofKeyThumbprint" => thumbprint,
        "cnf" => %{"jkt" => thumbprint}
      })

    assert {200, %{"credential" => credential, "proof" => _}, _} =
             http(port, :post, "/api/t3-connect/mint-credential", [], %{"proof" => mint})

    token_url = "http://127.0.0.1:#{port}/oauth/token"
    form = exchange_form(credential)

    # Not without a proof, nor with another key's.
    assert {400, _, _} = post_form(port, [], form)
    other = DpopClient.new()

    assert {400, _, _} =
             post_form(port, [{"dpop", DpopClient.proof(other, "POST", token_url)}], form)

    assert {200, %{"token_type" => "DPoP", "access_token" => access, "expires_in" => 3600}, _} =
             post_form(port, [{"dpop", DpopClient.proof(client, "POST", token_url)}], form)

    # Each request presents the token as DPoP with a fresh proof bound to it.
    session_url = "http://127.0.0.1:#{port}/api/auth/session"
    proof = DpopClient.proof(client, "GET", session_url, access_token: access)
    dpop = [{"authorization", "DPoP " <> access}, {"dpop", proof}]

    assert {200, %{"authenticated" => true, "sessionMethod" => "dpop-access-token"}, _} =
             http(port, :get, "/api/auth/session", dpop)

    assert {200, %{"authenticated" => false}, _} = http(port, :get, "/api/auth/session", dpop)

    assert {200, %{"authenticated" => false}, _} =
             http(port, :get, "/api/auth/session", [{"authorization", "Bearer " <> access}])

    ticket_url = "http://127.0.0.1:#{port}/api/auth/websocket-ticket"

    assert {200, %{"ticket" => _}, _} =
             http(port, :post, "/api/auth/websocket-ticket", [
               {"authorization", "DPoP " <> access},
               {"dpop", DpopClient.proof(client, "POST", ticket_url, access_token: access)}
             ])

    # Unlinking forgets the link; the relay's requests fail from then on.
    assert {200, %{"ok" => true}, _} = http(port, :post, "/api/connect/unlink", bearer)
    assert {200, %{"linked" => false}, _} = http(port, :get, "/api/connect/link-state", bearer)
    refute T3.Cloud.publishing?()
    health = relay_proof(relay, "t3-cloud-health+jwt", id, %{"scope" => ["environment:status"]})
    assert {401, _, _} = http(port, :post, "/api/t3-connect/health", [], %{"proof" => health})
  end

  test "a managed link runs its tunnel until unlinked", %{
    port: port,
    token: token,
    relay: relay,
    tmp_dir: dir
  } do
    # Stands in for cloudflared: reports its token's presence and stays up.
    fake = Path.join(dir, "cloudflared")

    File.write!(fake, """
    #!/bin/sh
    [ -n "$TUNNEL_TOKEN" ] && echo "INF Registered tunnel connection"
    exec sleep 60
    """)

    File.chmod!(fake, 0o755)
    System.put_env("T3CODE_CLOUDFLARED_PATH", fake)
    on_exit(fn -> System.delete_env("T3CODE_CLOUDFLARED_PATH") end)
    bearer = [{"authorization", "Bearer " <> token}]

    config = %{
      "relayUrl" => @relay,
      "cloudUserId" => "user_1",
      "environmentCredential" => "env-cred",
      "cloudMintPublicKey" => relay["publicKey"],
      "endpointRuntime" => %{
        "providerKind" => "cloudflare_tunnel",
        "connectorToken" => "secret-token",
        "tunnelId" => "t1"
      }
    }

    assert {200,
            %{
              "endpointRuntimeStatus" => %{
                "status" => "running",
                "pid" => pid,
                "tunnelId" => "t1"
              }
            }, _} =
             http(port, :post, "/api/connect/relay-config", bearer, config)

    assert alive?(pid)

    assert {200, %{"managedTunnelActive" => true}, _} =
             http(port, :get, "/api/connect/link-state", bearer)

    assert {200, %{"endpointRuntimeStatus" => %{"status" => "disabled"}}, _} =
             http(port, :post, "/api/connect/unlink", bearer)

    refute alive?(pid)
  end

  test "the relay client installs from its pinned release after checking it", %{tmp_dir: dir} do
    System.delete_env("T3CODE_CLOUDFLARED_PATH")
    www = Path.join(dir, "www")
    File.mkdir_p!(www)
    binary = "#!/bin/sh\necho cloudflared version 2026.5.2\n"
    File.write!(Path.join(www, "cloudflared"), binary)
    sha = Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

    {:ok, httpd} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"relay-client",
        server_root: String.to_charlist(dir),
        document_root: String.to_charlist(www),
        bind_address: {127, 0, 0, 1}
      )

    on_exit(fn -> :inets.stop(:httpd, httpd) end)
    url = "http://127.0.0.1:#{:httpd.info(httpd)[:port]}/cloudflared"
    platform = T3.Upgrade.platform()
    on_exit(fn -> Application.delete_env(:t3, :relay_client_assets) end)

    # The pinned checksum refuses any other download.
    Application.put_env(:t3, :relay_client_assets, %{
      platform => {url, String.duplicate("0", 64), :binary}
    })

    assert {:error, %{"reason" => "invalid_checksum"}} = T3.Cloud.RelayClient.install()
    refute File.exists?(T3.Cloud.RelayClient.managed_path())

    Application.put_env(:t3, :relay_client_assets, %{platform => {url, sha, :binary}})
    {:ok, stages} = Agent.start_link(fn -> [] end)
    report = fn stage -> Agent.update(stages, &(&1 ++ [stage])) end

    if System.find_executable("cloudflared") do
      assert {:ok, %{"status" => "available", "source" => "path"}} =
               T3.Cloud.RelayClient.install(report)
    else
      assert %{"status" => "missing"} = T3.Cloud.RelayClient.status()

      assert {:ok, %{"status" => "available", "source" => "managed"}} =
               T3.Cloud.RelayClient.install(report)

      assert Agent.get(stages, & &1) ==
               ~w(checking waiting_for_lock downloading verifying installing validating activating)
    end
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp relay_proof(keys, typ, id, claims) do
    now = System.os_time(:second)

    payload =
      Map.merge(
        %{
          "iss" => @relay,
          "aud" => "t3-env:#{id}",
          "sub" => "user_1",
          "jti" => Base.encode16(:crypto.strong_rand_bytes(8)),
          "iat" => now,
          "exp" => now + 120,
          "environmentId" => id,
          "nonce" => Base.encode16(:crypto.strong_rand_bytes(8))
        },
        claims
      )

    Jwt.sign(keys["privateKey"], typ, payload)
  end

  defp exchange_form(credential) do
    %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => credential,
      "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
      "requested_token_type" => "urn:ietf:params:oauth:token-type:access_token"
    }
  end

  defp post_form(port, headers, form) do
    request =
      {~c"http://127.0.0.1:#{port}/oauth/token", charlist_headers(headers),
       ~c"application/x-www-form-urlencoded", URI.encode_query(form)}

    response(:httpc.request(:post, request, [], []))
  end

  defp http(port, method, path, headers, body \\ nil) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    request =
      if method == :post,
        do: {url, charlist_headers(headers), ~c"application/json", JSON.encode!(body || %{})},
        else: {url, charlist_headers(headers)}

    response(:httpc.request(method, request, [], []))
  end

  defp charlist_headers(headers),
    do: for({k, v} <- headers, do: {to_charlist(k), to_charlist(v)})

  defp response({:ok, {{_, status, _}, headers, body}}) do
    decoded =
      case JSON.decode(to_string(body)) do
        {:ok, value} -> value
        _ -> to_string(body)
      end

    {status, decoded, for({k, v} <- headers, do: {to_string(k), to_string(v)})}
  end
end
