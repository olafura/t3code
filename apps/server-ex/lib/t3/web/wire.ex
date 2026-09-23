defmodule T3.Web.Wire do
  @moduledoc """
  Thread entities as they go to clients. The node keeps the whole of a command's
  output, a file change's diff, and a handoff's history, but clients never show
  them, so they stay off the socket, as they do on the Node server
  (`WireProjection.ts`). A failed command keeps the fact that it failed. Subagent
  text and dynamic tool values past their limits are cut or summarized.

  Events carry patches, not entities, so a turn item's type is learned from the
  snapshot and from the patch that creates it (`types`), and later patches are
  trimmed by it.
  """

  @max_detail 32_768
  @max_dynamic 16_384
  @dropped %{
    "command_execution" => ~w(output),
    "file_change" => ~w(diffStr oldStr newStr)
  }

  @doc "A snapshot row's entity, trimmed."
  def entity("turn-item", item), do: turn_item(item)
  def entity("context-handoff", handoff), do: handoff(handoff)
  def entity(_kind, entity), do: entity

  @doc "The turn item types in snapshot rows (`[kind, id, entity]`), by item id."
  def types(rows, types \\ %{}) do
    for [kind, id, %{"type" => type}] <- rows, kind == "turn-item", into: types, do: {id, type}
  end

  @doc """
  An event's patch, trimmed: `{patch | nil, types}`, nil when nothing the client
  would use is left.
  """
  def patch("turn-item", id, patch, types) do
    type = get_in(patch, ["s", "type"]) || types[id]
    types = if type, do: Map.put(types, id, type), else: types
    {turn_item_patch(type, patch) |> nonempty(), types}
  end

  def patch("context-handoff", _id, patch, types),
    do: {patch |> drop(~w(history delivery)) |> set("summaryText", "") |> nonempty(), types}

  def patch(_kind, _id, patch, types), do: {patch, types}

  # --- turn items ----------------------------------------------------------------

  defp turn_item(%{"type" => "command_execution"} = item) do
    item |> Map.delete("output") |> failed(item["exitCode"], item["outputIndicatesFailure"])
  end

  defp turn_item(%{"type" => "file_change"} = item), do: Map.drop(item, @dropped["file_change"])

  defp turn_item(%{"type" => "subagent"} = item) do
    Enum.reduce(~w(prompt progress result), item, fn key, item ->
      if is_binary(item[key]), do: Map.put(item, key, cut(item[key])), else: item
    end)
  end

  defp turn_item(%{"type" => "dynamic_tool"} = item) do
    Enum.reduce(~w(input output), item, fn key, item ->
      if Map.has_key?(item, key), do: Map.put(item, key, summarize(item[key])), else: item
    end)
  end

  defp turn_item(item), do: item

  defp turn_item_patch(type, patch) when is_map_key(@dropped, type) do
    patch = drop(patch, @dropped[type])

    if type == "command_execution",
      do: failed_patch(patch),
      else: patch
  end

  defp turn_item_patch("subagent", patch),
    do: map_set(patch, ~w(prompt progress result), &if(is_binary(&1), do: cut(&1), else: &1))

  defp turn_item_patch("dynamic_tool", patch), do: map_set(patch, ~w(input output), &summarize/1)
  defp turn_item_patch(_type, patch), do: patch

  # A command that failed says so without its output.
  defp failed(item, exit_code, flagged) do
    if flagged == true or (is_integer(exit_code) and exit_code != 0),
      do: Map.put(item, "outputIndicatesFailure", true),
      else: item
  end

  defp failed_patch(%{"s" => %{"exitCode" => code}} = patch) when is_integer(code) and code != 0,
    do: set(patch, "outputIndicatesFailure", true)

  defp failed_patch(patch), do: patch

  defp handoff(handoff),
    do: handoff |> Map.drop(~w(history delivery)) |> Map.put("summaryText", "")

  # --- values ----------------------------------------------------------------------

  defp cut(text) when byte_size(text) <= @max_detail, do: text

  defp cut(text) do
    prefix = binary_part(text, 0, @max_detail)
    # Never end mid-character.
    prefix = String.replace_invalid(prefix, "") |> String.trim_trailing(<<0xFFFD::utf8>>)
    prefix <> "\n… output truncated for transport"
  end

  # A value past the limit becomes the first line of it, marked as cut.
  defp summarize(value) do
    json = if is_binary(value), do: value, else: JSON.encode!(value)

    if byte_size(json) <= @max_dynamic do
      value
    else
      line =
        json
        |> String.trim_leading()
        |> String.split("\n", parts: 2)
        |> hd()
        |> String.slice(0, 160)

      %{"summary" => if(line == "", do: "Large tool output", else: line), "truncated" => true}
    end
  end

  # --- patches -----------------------------------------------------------------------

  defp drop(patch, keys) do
    patch
    |> Map.update("s", nil, &Map.drop(&1, keys))
    |> Map.update("a", nil, &Map.drop(&1, keys))
    |> Map.reject(fn {key, value} -> key in ["s", "a"] and value in [nil, %{}] end)
  end

  defp set(patch, key, value),
    do: Map.update(patch, "s", %{key => value}, &Map.put(&1, key, value))

  defp map_set(%{"s" => set} = patch, keys, fun) do
    %{
      patch
      | "s" =>
          Map.new(set, fn {key, value} -> {key, if(key in keys, do: fun.(value), else: value)} end)
    }
  end

  defp map_set(patch, _keys, _fun), do: patch

  defp nonempty(patch) when map_size(patch) == 0, do: nil
  defp nonempty(patch), do: patch
end
