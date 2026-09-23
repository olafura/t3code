defmodule T3.Projection.JS do
  @moduledoc """
  The JavaScript value semantics that projections ported from the Node server rely on.

  Entities come from `:json.decode`, so JSON `null` is the atom `:null`. Read fields
  with `get/2`, which returns `nil` for both a missing field and `null`, and pass any
  value copied into output through `json/1`. Dates are compared as `epoch_ms/1`
  (Effect's `DateTime.toEpochMillis`) and written by `iso/1` (`Date#toISOString`).
  """

  # String.prototype.trim: WhiteSpace and LineTerminator, which differ from
  # Unicode White_Space (no U+0085, plus U+FEFF).
  @ws "\\t\\n\\v\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
  @trim Regex.compile!("\\A[#{@ws}]+|[#{@ws}]+\\z", "u")

  @doc "A field of a JSON object, with `null` read as `nil`."
  @spec get(map | nil, String.t()) :: term
  def get(nil, _key), do: nil

  def get(map, key) do
    case Map.get(map, key) do
      :null -> nil
      value -> value
    end
  end

  @doc "A decoded JSON value with every `null` as `nil`."
  @spec json(term) :: term
  def json(:null), do: nil
  def json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, json(v)} end)
  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value), do: value

  @spec trim(String.t()) :: String.t()
  def trim(string), do: String.replace(string, @trim, "")

  @doc "Unix milliseconds of an ISO-8601 string, or `nil` when it does not parse."
  @spec epoch_ms(String.t() | nil) :: integer | nil
  def epoch_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      {:error, _} -> nil
    end
  end

  def epoch_ms(_), do: nil

  @doc ~S|Unix milliseconds as the Node encoding writes them: `"2026-09-10T09:13:16.387Z"`.|
  @spec iso(integer) :: String.t()
  def iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
