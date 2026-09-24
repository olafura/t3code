defmodule T3.Dpop do
  @moduledoc """
  DPoP proofs (RFC 9449) as `@t3tools/shared/dpop` checks them: an ES256 JWT of
  type `dpop+jwt` carrying the client's P-256 public key, bound to the request's
  method and URL (without query or fragment), and to the access token by its
  SHA-256 hash (`ath`) when it presents one. Clients reaching a node through
  T3 Connect prove their key this way; the node remembers each key's proof ids so
  none is used twice (`T3.Auth.consume_proof/2`).
  """

  @max_age 300
  @future_skew 5

  @doc """
  Checks `proof` for a request: `{:ok, %{thumbprint, jti, iat}}` or
  `{:error, reason}`, the reason one of the contracts' `DpopFailureReason`s.
  Options: `:thumbprint` (the key it must be), `:access_token` (the token it must
  be bound to), `:now` (seconds).
  """
  def verify(proof, method, url, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, proof} <- present(proof),
         [header64, payload64, signature64] <- String.split(proof, "."),
         {:ok, header} <- decode(header64),
         {:ok, payload} <- decode(payload64),
         %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk} <- header,
         %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} when not is_map_key(jwk, "d") <-
           jwk,
         %{"htm" => htm, "htu" => htu, "jti" => jti, "iat" => iat}
         when is_binary(htm) and is_binary(htu) and is_binary(jti) and jti != "" and
                is_integer(iat) <- payload,
         thumbprint = thumbprint(jwk),
         :ok <- check(opts[:thumbprint] in [nil, thumbprint], :key_mismatch),
         :ok <- check(String.upcase(htm) == String.upcase(method), :request_mismatch),
         :ok <- check(htu == normalize_htu(url), :request_mismatch),
         :ok <- check(token_bound?(payload, opts[:access_token]), :token_mismatch),
         :ok <- check(signed?(header64 <> "." <> payload64, signature64, x, y), :invalid_proof),
         :ok <- check(iat <= now + @future_skew and now - iat <= @max_age, :time_window) do
      {:ok, %{thumbprint: thumbprint, jti: jti, iat: iat}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "invalid_proof"}
    end
  end

  @doc "A P-256 JWK's thumbprint, as clients compute it."
  def thumbprint(%{"x" => x, "y" => y}) do
    ~s({"crv":"P-256","kty":"EC","x":#{JSON.encode!(x)},"y":#{JSON.encode!(y)}})
    |> sha256()
  end

  @doc "A URL as a proof's `htu`: no query or fragment, the path at least `/`."
  def normalize_htu(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(scheme) and is_binary(host) ->
        %URI{uri | query: nil, fragment: nil, path: uri.path || "/", userinfo: nil}
        |> Map.update!(:scheme, &String.downcase/1)
        |> Map.update!(:host, &String.downcase/1)
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp present(proof) when is_binary(proof) and proof != "", do: {:ok, String.trim(proof)}
  defp present(_), do: {:error, "invalid_proof"}

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, Atom.to_string(reason)}

  defp token_bound?(_payload, nil), do: true
  defp token_bound?(payload, token), do: payload["ath"] == sha256(token)

  defp signed?(input, signature64, x64, y64) do
    with {:ok, <<r::binary-size(32), s::binary-size(32)>>} <-
           Base.url_decode64(signature64, padding: false),
         {:ok, <<_::binary-size(32)>> = x} <- Base.url_decode64(x64, padding: false),
         {:ok, <<_::binary-size(32)>> = y} <- Base.url_decode64(y64, padding: false) do
      der =
        :public_key.der_encode(
          :"ECDSA-Sig-Value",
          {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
        )

      :crypto.verify(:ecdsa, :sha256, input, der, [<<4>> <> x <> y, :secp256r1])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp decode(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, %{} = map} <- JSON.decode(json),
         do: {:ok, map},
         else: (_ -> :error)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
end
