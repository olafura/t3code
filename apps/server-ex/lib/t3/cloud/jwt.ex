defmodule T3.Cloud.Jwt do
  @moduledoc """
  Ed25519-signed JWTs between a node and the T3 Connect relay, as
  `@t3tools/shared/relayJwt` makes and checks them. Keys are PEM: PKCS#8 for
  private keys, SPKI for public ones.
  """

  @spki_prefix <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>>
  @pkcs8_prefix <<0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04,
                  0x22, 0x04, 0x20>>
  @clock_tolerance 60
  @max_age 5 * 60

  @doc "A new key pair: `%{\"privateKey\" => pem, \"publicKey\" => pem}`."
  def generate_key_pair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      "privateKey" => pem("PRIVATE KEY", @pkcs8_prefix <> private),
      "publicKey" => pem("PUBLIC KEY", @spki_prefix <> public)
    }
  end

  @doc "Whether `pem` is an Ed25519 public key."
  def public_key?(pem), do: match?({:ok, _}, public_key(pem))

  @doc "Signs `payload` as a compact JWT with header `typ`."
  def sign(private_pem, typ, payload) do
    {:ok, private} = key(private_pem, "PRIVATE KEY", @pkcs8_prefix)
    input = segment(%{"alg" => "EdDSA", "typ" => typ}) <> "." <> segment(payload)
    signature = :crypto.sign(:eddsa, :none, input, [private, :ed25519])
    input <> "." <> Base.url_encode64(signature, padding: false)
  end

  @doc """
  The payload of `token` when it is signed by `public_pem`, of type `typ`, from
  `issuer` to `audience`, and current at `now` (seconds): issued at most five
  minutes ago, with a minute of clock tolerance. `{:ok, payload}` or `:error`.
  """
  def verify(public_pem, token, typ, issuer, audience, now) do
    with {:ok, public} <- public_key(public_pem),
         [header64, payload64, signature64] <- String.split(token, "."),
         {:ok, header} <- decode_segment(header64),
         %{"alg" => "EdDSA", "typ" => ^typ} <- header,
         {:ok, payload} <- decode_segment(payload64),
         {:ok, signature} <- Base.url_decode64(signature64, padding: false),
         true <-
           :crypto.verify(:eddsa, :none, header64 <> "." <> payload64, signature, [
             public,
             :ed25519
           ]),
         true <- current?(payload, issuer, audience, now) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  @doc "A relay URL as an issuer or audience: no trailing slashes."
  def normalize_issuer(value), do: value |> String.trim() |> String.trim_trailing("/")

  defp current?(payload, issuer, audience, now) do
    audiences = List.wrap(payload["aud"])

    with iat when is_integer(iat) <- payload["iat"],
         true <- payload["iss"] == issuer,
         true <- audience in audiences,
         true <- iat <= now + @clock_tolerance,
         true <- now - iat - @clock_tolerance <= @max_age,
         true <- not is_integer(payload["exp"]) or now - @clock_tolerance < payload["exp"],
         true <- not is_integer(payload["nbf"]) or payload["nbf"] <= now + @clock_tolerance do
      true
    else
      _ -> false
    end
  end

  defp public_key(pem), do: key(pem, "PUBLIC KEY", @spki_prefix)

  defp key(pem, label, prefix) do
    body =
      pem
      |> String.replace("\\n", "\n")
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&String.starts_with?(&1, "-----"))
      |> Enum.join()

    with true <- String.contains?(pem, "BEGIN #{label}"),
         {:ok, der} <- Base.decode64(body),
         true <- byte_size(der) == byte_size(prefix) + 32 and String.starts_with?(der, prefix) do
      {:ok, binary_part(der, byte_size(prefix), 32)}
    else
      _ -> :error
    end
  end

  defp pem(label, der) do
    lines = der |> Base.encode64() |> chunks()
    Enum.join(["-----BEGIN #{label}-----" | lines] ++ ["-----END #{label}-----", ""], "\n")
  end

  defp chunks(<<line::binary-size(64), rest::binary>>), do: [line | chunks(rest)]
  defp chunks(""), do: []
  defp chunks(rest), do: [rest]

  defp segment(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)

  defp decode_segment(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, %{} = map} <- JSON.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end
end
