defmodule T3.Cloud do
  @moduledoc """
  The node's side of T3 Connect, wire-compatible with the Node server
  (`apps/server/src/cloud/http.ts`; the reasoning is in `docs/internals/t3-connect.md`).

  A client with `relay:write` links the node: it asks for a link proof (signed with
  the node's Ed25519 key, `key_pair/0`) to hand the relay, then passes the relay's
  answer back as the relay configuration: the linked account, the relay's
  credential for this node, the relay's mint key, and the managed tunnel to run
  (`T3.Cloud.Tunnel`). After that the relay reaches the node through its tunnel to
  check it is up (`health/1`) and to mint one-time credentials bound to a client's
  DPoP key (`mint/1`); each request is a JWT signed by the relay's mint key, used
  once. State lives in `T3.Secrets` under the Node server's names.
  """

  alias T3.Cloud.Jwt

  @key_pair "cloud-link-ed25519-key-pair"
  @mint_public_key "cloud-mint-ed25519-public-key"
  @endpoint_runtime "cloud-endpoint-runtime-config"
  @linked_user "cloud-linked-user-id"
  @relay_url "cloud-relay-url"
  @relay_issuer "cloud-relay-issuer"
  @relay_credential "cloud-relay-environment-credential"
  @publish_activity "cloud-publish-agent-activity"

  @proof_max_lifetime 5 * 60
  @proof_clock_skew 60
  @loopback ~w(127.0.0.1 ::1 localhost)

  @link_proof_typ "t3-env-link+jwt"
  @mint_request_typ "t3-cloud-mint+jwt"
  @health_request_typ "t3-cloud-health+jwt"
  @mint_response_typ "t3-env-mint+jwt"
  @health_response_typ "t3-env-health+jwt"
  @activity_typ "t3-env-activity+jwt"

  @doc "The node's Ed25519 key pair, made on first use."
  def key_pair do
    with value when is_binary(value) <- T3.Secrets.get(@key_pair),
         {:ok, %{"privateKey" => _, "publicKey" => _} = pair} <- JSON.decode(value) do
      pair
    else
      _ ->
        pair = Jwt.generate_key_pair()

        case T3.Secrets.create(@key_pair, JSON.encode!(pair)) do
          :ok -> pair
          :exists -> JSON.decode!(T3.Secrets.get(@key_pair))
        end
    end
  end

  @doc """
  `POST /api/connect/link-proof`: the proof a client hands the relay to link this
  node. `url` is the address the request reached, which must be the loopback
  origin the managed tunnel will serve.
  """
  def link_proof(request, url) do
    origin = request["origin"] || %{}
    endpoint = request["endpoint"] || %{}

    if endpoint["providerKind"] in ["cloudflare_tunnel", "manual"] and
         loopback_origin?(origin, url) and is_binary(request["challenge"]) and
         is_binary(request["relayIssuer"]) do
      descriptor = T3.Environment.descriptor()
      id = descriptor["environmentId"]
      now = System.os_time(:second)

      scopes =
        if endpoint["providerKind"] == "cloudflare_tunnel",
          do: ["agent_activity_notifications", "managed_tunnels"],
          else: ["agent_activity_notifications"]

      payload = %{
        "iss" => "t3-env:#{id}",
        "aud" => Jwt.normalize_issuer(request["relayIssuer"]),
        "sub" => id,
        "jti" => uuid(),
        "iat" => now,
        "exp" => now + 300,
        "challenge" => request["challenge"],
        "descriptor" => descriptor,
        "environmentId" => id,
        "environmentPublicKey" => String.trim(key_pair()["publicKey"]),
        "endpoint" => endpoint,
        "origin" => origin,
        "scopes" => scopes
      }

      {:ok, Jwt.sign(key_pair()["privateKey"], @link_proof_typ, payload)}
    else
      {:error, 400, "Invalid managed endpoint origin."}
    end
  end

  @doc "`POST /api/connect/relay-config`: records the link the relay made and starts its tunnel."
  def apply_relay_config(config) do
    with :ok <- validate_relay_config(config),
         :ok <- same_account(config["cloudUserId"]),
         :ok <-
           if(Jwt.public_key?(config["cloudMintPublicKey"] || ""),
             do: :ok,
             else: {:error, 400, "Cloud mint public key must be a valid Ed25519 public key."}
           ) do
      runtime = config["endpointRuntime"]
      status = T3.Cloud.Tunnel.apply(runtime)

      if status["status"] in ["disabled", "running"] do
        T3.Secrets.put(@relay_url, config["relayUrl"])
        T3.Secrets.put(@relay_issuer, config["relayIssuer"] || config["relayUrl"])
        T3.Secrets.put(@linked_user, config["cloudUserId"])
        T3.Secrets.put(@relay_credential, config["environmentCredential"])
        T3.Secrets.put(@mint_public_key, config["cloudMintPublicKey"])

        if runtime,
          do: T3.Secrets.put(@endpoint_runtime, JSON.encode!(runtime)),
          else: T3.Secrets.delete(@endpoint_runtime)

        {:ok, %{"ok" => true, "endpointRuntimeStatus" => status}}
      else
        {:error, 503,
         %{
           "_tag" => "EnvironmentCloudEndpointUnavailableError",
           "message" => "Managed endpoint runtime could not be started.",
           "endpointRuntimeStatus" => status
         }}
      end
    end
  end

  @doc "`GET /api/connect/link-state`."
  def link_state do
    user = T3.Secrets.get(@linked_user)

    %{
      "linked" => user != nil,
      "cloudUserId" => user,
      "relayUrl" => T3.Secrets.get(@relay_url),
      "relayIssuer" => T3.Secrets.get(@relay_issuer),
      "managedTunnelActive" => T3.Secrets.get(@endpoint_runtime) != nil,
      "publishAgentActivity" => T3.Secrets.get(@publish_activity) == "true"
    }
  end

  @doc "`POST /api/connect/unlink`: stops the tunnel and forgets the link."
  def unlink do
    status = T3.Cloud.Tunnel.apply(nil)

    for name <- [
          @linked_user,
          @relay_url,
          @relay_issuer,
          @relay_credential,
          @mint_public_key,
          @endpoint_runtime,
          @publish_activity
        ],
        do: T3.Secrets.delete(name)

    %{"ok" => true, "endpointRuntimeStatus" => status}
  end

  @doc "`POST /api/connect/preferences`: whether agent activity is published."
  def set_preferences(%{"publishAgentActivity" => publish}) when is_boolean(publish) do
    T3.Secrets.put(@publish_activity, to_string(publish))
    {:ok, link_state()}
  end

  def set_preferences(_), do: {:error, 400, "publishAgentActivity must be a boolean."}

  @doc """
  Whether agent activity leaves this node: publishing is on and the link's relay
  credentials exist.
  """
  def publishing? do
    T3.Secrets.get(@publish_activity) == "true" and
      T3.Secrets.get(@relay_url) not in [nil, ""] and
      T3.Secrets.get(@relay_credential) not in [nil, ""]
  end

  @doc "The link's relay: `%{url, issuer, credential}`, or nil when unlinked."
  def relay do
    url = T3.Secrets.get(@relay_url)
    credential = T3.Secrets.get(@relay_credential)

    if url not in [nil, ""] and credential not in [nil, ""],
      do: %{url: url, issuer: T3.Secrets.get(@relay_issuer) || url, credential: credential}
  end

  @doc "The managed tunnel the link asks for, restarted at boot."
  def stored_endpoint_runtime do
    with value when is_binary(value) <- T3.Secrets.get(@endpoint_runtime),
         {:ok, %{} = config} <- JSON.decode(value),
         do: config,
         else: (_ -> nil)
  end

  @doc "Signs an agent-activity publish for the relay (`T3.Cloud.Activity`)."
  def sign_activity(payload), do: Jwt.sign(key_pair()["privateKey"], @activity_typ, payload)

  @doc """
  `POST /api/t3-connect/health`: the relay checking the node is up. Answers with
  the descriptor, signed and bound to the request's nonce.
  """
  def health(%{"proof" => proof}) when is_binary(proof) do
    with {:ok, claims, context} <- relay_request(proof, @health_request_typ, "environment:status"),
         :ok <- once("cloud-health", claims) do
      checked_at = DateTime.utc_now() |> DateTime.to_iso8601()
      descriptor = T3.Environment.descriptor()

      response_proof =
        sign_response(@health_response_typ, context, %{
          "requestNonce" => claims["nonce"],
          "status" => "online",
          "descriptor" => descriptor,
          "checkedAt" => checked_at
        })

      {:ok,
       %{
         "environmentId" => context.id,
         "status" => "online",
         "descriptor" => descriptor,
         "checkedAt" => checked_at,
         "proof" => response_proof
       }}
    end
  end

  def health(_), do: {:error, 401, "Invalid cloud health request."}

  @doc """
  `POST /api/t3-connect/mint-credential`: a one-time credential for a client the
  relay vouches for, usable only with the client's DPoP key.
  """
  def mint(%{"proof" => proof}) when is_binary(proof) do
    with {:ok, claims, context} <- relay_request(proof, @mint_request_typ, "environment:connect"),
         thumbprint when is_binary(thumbprint) and thumbprint != "" <-
           claims["clientProofKeyThumbprint"],
         %{"jkt" => ^thumbprint} <- claims["cnf"],
         :ok <- once("cloud-mint", claims) do
      %{"credential" => credential, "expiresAt" => expires_at} =
        T3.Auth.create_connect_credential(thumbprint)

      {:ok, expires, _} = DateTime.from_iso8601(expires_at)

      response_proof =
        sign_response(
          @mint_response_typ,
          context,
          %{
            "clientProofKeyThumbprint" => thumbprint,
            "requestNonce" => claims["nonce"],
            "credential" => credential
          },
          DateTime.to_unix(expires)
        )

      {:ok, %{"credential" => credential, "expiresAt" => expires_at, "proof" => response_proof}}
    else
      {:error, _, _} = error -> error
      _ -> {:error, 401, "Invalid cloud mint request."}
    end
  end

  def mint(_), do: {:error, 401, "Invalid cloud mint request."}

  # A request the relay signed with its mint key for this node and its linked
  # account, short-lived and carrying exactly `scope`.
  defp relay_request(proof, typ, scope) do
    mint_key = T3.Secrets.get(@mint_public_key)
    issuer = T3.Secrets.get(@relay_issuer) || T3.Secrets.get(@relay_url)
    user = T3.Secrets.get(@linked_user)
    id = T3.Environment.id()
    now = System.os_time(:second)

    with true <- is_binary(mint_key) and is_binary(issuer) and is_binary(user),
         {:ok, claims} <-
           Jwt.verify(mint_key, proof, typ, Jwt.normalize_issuer(issuer), "t3-env:#{id}", now),
         %{"environmentId" => ^id, "sub" => ^user, "scope" => [^scope], "jti" => jti} <-
           claims,
         nonce when is_binary(nonce) and nonce != "" <- claims["nonce"],
         true <- is_binary(jti) and jti != "",
         true <- bounded?(claims, now) do
      {:ok, claims, %{id: id, issuer: Jwt.normalize_issuer(issuer), now: now}}
    else
      _ -> {:error, 401, invalid_message(typ)}
    end
  end

  defp invalid_message(@health_request_typ), do: "Invalid cloud health request."
  defp invalid_message(_), do: "Invalid cloud mint request."

  defp bounded?(%{"iat" => iat, "exp" => exp}, now) when is_integer(iat) and is_integer(exp),
    do: exp > iat and exp - iat <= @proof_max_lifetime and iat <= now + @proof_clock_skew

  defp bounded?(_, _), do: false

  defp once(kind, %{"jti" => jti, "nonce" => nonce}) do
    if T3.Auth.consume_once(["#{kind}-jti-#{jti}", "#{kind}-nonce-#{nonce}"], :timer.minutes(10)),
      do: :ok,
      else:
        {:error, 409, "Cloud #{String.replace(kind, "cloud-", "")} request was already consumed."}
  end

  defp sign_response(typ, context, claims, exp \\ nil) do
    payload =
      Map.merge(claims, %{
        "iss" => "t3-env:#{context.id}",
        "aud" => context.issuer,
        "sub" => context.id,
        "jti" => uuid(),
        "iat" => context.now,
        "exp" => exp || context.now + 300,
        "environmentId" => context.id
      })

    Jwt.sign(key_pair()["privateKey"], typ, payload)
  end

  defp validate_relay_config(config) do
    cond do
      not secure_url?(config["relayUrl"]) ->
        {:error, 400, "Relay URL must be a secure absolute HTTPS URL."}

      config["relayIssuer"] != nil and not secure_url?(config["relayIssuer"]) ->
        {:error, 400, "Relay issuer must be a secure absolute HTTPS URL."}

      String.trim(config["environmentCredential"] || "") == "" ->
        {:error, 400, "Relay environment credential is required."}

      String.trim(config["cloudUserId"] || "") == "" ->
        {:error, 400, "Cloud user id is required."}

      true ->
        :ok
    end
  end

  defp same_account(user) do
    case T3.Secrets.get(@linked_user) do
      nil ->
        :ok

      ^user ->
        :ok

      _ ->
        {:error, 409,
         "This environment is already linked to a different cloud account. Unlink it before switching accounts."}
    end
  end

  @doc "An absolute `https:` origin with no credentials, query, fragment or path."
  def secure_url?(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when is_binary(host) and host != "" ->
        Regex.match?(~r{^/*$}, uri.path || "")

      _ ->
        false
    end
  end

  def secure_url?(_), do: false

  # The request reached a loopback address on the port the tunnel will serve,
  # which is the origin the relay is asked to route to.
  defp loopback_origin?(%{"localHttpHost" => host, "localHttpPort" => port}, url)
       when is_binary(host) and is_integer(port) do
    with {:ok, %URI{host: request_host, port: request_port}} <- URI.new(url) do
      loopback?(host) and loopback?(request_host) and request_port == port
    else
      _ -> false
    end
  end

  defp loopback_origin?(_, _), do: false

  defp loopback?(host) when is_binary(host),
    do:
      (host |> String.trim() |> String.downcase() |> String.trim("[") |> String.trim("]")) in @loopback

  defp loopback?(_), do: false

  defp uuid, do: T3.Environment.uuid4()
end
