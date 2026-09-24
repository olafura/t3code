defmodule T3.Test.DpopClient do
  @moduledoc "A client's P-256 proof key, making DPoP proofs as the client runtime does."

  def new do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public

    %{
      private: private,
      jwk: %{
        "kty" => "EC",
        "crv" => "P-256",
        "x" => Base.url_encode64(x, padding: false),
        "y" => Base.url_encode64(y, padding: false)
      }
    }
  end

  def thumbprint(key), do: T3.Dpop.thumbprint(key.jwk)

  @doc "A proof for `method url`, bound to `access_token` when given."
  def proof(key, method, url, opts \\ []) do
    header = %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => key.jwk}

    payload =
      %{
        "htm" => method,
        "htu" => url,
        "jti" =>
          Keyword.get_lazy(opts, :jti, fn -> Base.encode16(:crypto.strong_rand_bytes(8)) end),
        "iat" => Keyword.get_lazy(opts, :iat, fn -> System.os_time(:second) end)
      }
      |> then(fn payload ->
        case opts[:access_token] do
          nil ->
            payload

          token ->
            Map.put(
              payload,
              "ath",
              :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
            )
        end
      end)

    input = segment(header) <> "." <> segment(payload)
    der = :crypto.sign(:ecdsa, :sha256, input, [key.private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    signature = <<r::unsigned-big-256, s::unsigned-big-256>>
    input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp segment(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)
end
