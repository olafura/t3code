defmodule T3.Cloud.SigningTest do
  use ExUnit.Case, async: true

  alias T3.Cloud.Jwt
  alias T3.Test.DpopClient

  @url "https://env.example.com/api/auth/websocket-ticket"

  test "relay JWTs verify only for their key, type, issuer, audience and time" do
    keys = Jwt.generate_key_pair()
    other = Jwt.generate_key_pair()
    now = System.os_time(:second)
    payload = %{"iss" => "t3-env:e1", "aud" => "https://relay", "iat" => now, "exp" => now + 300}
    token = Jwt.sign(keys["privateKey"], "t3-env-link+jwt", payload)

    assert {:ok, %{"iss" => "t3-env:e1"}} =
             Jwt.verify(
               keys["publicKey"],
               token,
               "t3-env-link+jwt",
               "t3-env:e1",
               "https://relay",
               now
             )

    assert :error =
             Jwt.verify(
               other["publicKey"],
               token,
               "t3-env-link+jwt",
               "t3-env:e1",
               "https://relay",
               now
             )

    assert :error =
             Jwt.verify(
               keys["publicKey"],
               token,
               "t3-cloud-mint+jwt",
               "t3-env:e1",
               "https://relay",
               now
             )

    assert :error =
             Jwt.verify(
               keys["publicKey"],
               token,
               "t3-env-link+jwt",
               "t3-env:e2",
               "https://relay",
               now
             )

    assert :error =
             Jwt.verify(
               keys["publicKey"],
               token,
               "t3-env-link+jwt",
               "t3-env:e1",
               "https://other",
               now
             )

    assert :error =
             Jwt.verify(
               keys["publicKey"],
               token,
               "t3-env-link+jwt",
               "t3-env:e1",
               "https://relay",
               now + 400
             )

    assert :error =
             Jwt.verify(
               keys["publicKey"],
               token,
               "t3-env-link+jwt",
               "t3-env:e1",
               "https://relay",
               now - 120
             )

    assert Jwt.public_key?(keys["publicKey"])
    refute Jwt.public_key?(keys["privateKey"])
    assert Jwt.normalize_issuer(" https://relay.t3.codes// ") == "https://relay.t3.codes"
  end

  # Signed by `jose` in Node with a key from `generateKeyPairSync("ed25519")`,
  # as the relay signs its requests.
  @jose_public_key "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAOyjgekW0cJ4yQ2s4/7zFfZ4ZTKVpTUylTgjo9JLgdAU=\n-----END PUBLIC KEY-----\n"
  @jose_token "eyJhbGciOiJFZERTQSIsInR5cCI6InQzLWNsb3VkLW1pbnQrand0In0.eyJpc3MiOiJ0My1jbG91ZCIsImF1ZCI6InQzLWVudjplMSIsImlhdCI6MTc5MDAwMDAwMCwiZXhwIjoxNzkwMDAwMzAwLCJub25jZSI6Im4xIn0.mblY_azb8qGEL4fMepmlUsTVYKZY-oMHbDqfBTcR_YuC99FvBDdN7USNOcY64Da6KLeOGxFumZ8HI0Ag22U3Dw"

  test "a token jose signed in Node verifies here" do
    assert {:ok, %{"nonce" => "n1"}} =
             Jwt.verify(
               @jose_public_key,
               @jose_token,
               "t3-cloud-mint+jwt",
               "t3-cloud",
               "t3-env:e1",
               1_790_000_000
             )
  end

  test "DPoP proofs bind a key to a request and an access token" do
    key = DpopClient.new()
    thumbprint = DpopClient.thumbprint(key)
    proof = DpopClient.proof(key, "POST", @url)

    assert {:ok, %{thumbprint: ^thumbprint}} = T3.Dpop.verify(proof, "POST", @url <> "?x=1")
    assert {:ok, _} = T3.Dpop.verify(proof, "post", @url, thumbprint: thumbprint)
    assert {:error, "key_mismatch"} = T3.Dpop.verify(proof, "POST", @url, thumbprint: "other")
    assert {:error, "request_mismatch"} = T3.Dpop.verify(proof, "GET", @url)

    assert {:error, "request_mismatch"} =
             T3.Dpop.verify(proof, "POST", "https://env.example.com/ws")

    assert {:error, "token_mismatch"} = T3.Dpop.verify(proof, "POST", @url, access_token: "t")

    bound = DpopClient.proof(key, "POST", @url, access_token: "t")
    assert {:ok, _} = T3.Dpop.verify(bound, "POST", @url, access_token: "t")

    old = DpopClient.proof(key, "POST", @url, iat: System.os_time(:second) - 400)
    assert {:error, "time_window"} = T3.Dpop.verify(old, "POST", @url)

    [h, p, _] = String.split(proof, ".")
    [_, _, s] = String.split(DpopClient.proof(DpopClient.new(), "POST", @url), ".")
    assert {:error, "invalid_proof"} = T3.Dpop.verify(Enum.join([h, p, s], "."), "POST", @url)
    assert {:error, "invalid_proof"} = T3.Dpop.verify(nil, "POST", @url)
  end
end
