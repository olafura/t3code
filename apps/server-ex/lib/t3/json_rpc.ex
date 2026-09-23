defmodule T3.JsonRpc do
  @moduledoc """
  Pure JSON-RPC framing shared by the Codex app-server and ACP agents.

  Codex omits the `"jsonrpc": "2.0"` marker and ACP requires it, so encoders take a
  `dialect` of `:bare` or `:v2`.
  """

  @type dialect :: :bare | :v2
  @type id :: integer | String.t()
  @type message ::
          {:response, id, {:ok, term} | {:error, map}}
          | {:request, id, String.t(), term}
          | {:notification, String.t(), term}
          | {:invalid, term}

  @spec request(dialect, id, String.t(), term) :: iodata
  def request(dialect, id, method, params),
    do: encode(dialect, %{"id" => id, "method" => method, "params" => params})

  @spec notification(dialect, String.t(), term) :: iodata
  def notification(dialect, method, params),
    do: encode(dialect, %{"method" => method, "params" => params})

  @spec response(dialect, id, {:ok, term} | {:error, map}) :: iodata
  def response(dialect, id, {:ok, result}), do: encode(dialect, %{"id" => id, "result" => result})
  def response(dialect, id, {:error, error}), do: encode(dialect, %{"id" => id, "error" => error})

  @spec decode(binary) :: message
  def decode(line) do
    line |> JSON.decode!() |> classify()
  rescue
    _ -> {:invalid, line}
  end

  defp classify(%{"id" => id, "method" => method} = m), do: {:request, id, method, m["params"]}
  defp classify(%{"method" => method} = m), do: {:notification, method, m["params"]}
  defp classify(%{"id" => id, "error" => error}), do: {:response, id, {:error, error}}
  defp classify(%{"id" => id} = m), do: {:response, id, {:ok, m["result"]}}
  defp classify(other), do: {:invalid, other}

  defp encode(:bare, map), do: JSON.encode_to_iodata!(drop_nil_params(map))

  defp encode(:v2, map),
    do: JSON.encode_to_iodata!(map |> drop_nil_params() |> Map.put("jsonrpc", "2.0"))

  defp drop_nil_params(%{"params" => nil} = map), do: Map.delete(map, "params")
  defp drop_nil_params(map), do: map
end
