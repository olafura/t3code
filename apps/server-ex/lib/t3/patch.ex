defmodule T3.Patch do
  @moduledoc """
  Entity patches, the unit of the event log and of client sync.

  An entity is a JSON-shaped map. A patch records only what changed between two
  versions of it:

    * `"s"` (set) - fields whose value changed or appeared
    * `"a"` (append) - string fields that grew by a suffix; only the suffix is stored
    * `"u"` (unset) - fields that disappeared
    * `"d"` (delete) - the entity is removed first; with nothing else in the patch
      the entity is gone, with `"s"` it is replaced
    * `"q"` (quiet) - a read-state change such as a visit, not activity: it does not
      move the stream's `updated_at`

  Streaming assistant text, reasoning, and command output therefore cost their new
  bytes, not their whole length, on every update. `diff/2` returns `:unchanged` when
  nothing changed, so identical re-emits never reach the log.
  """

  @type entity :: %{optional(String.t()) => term}
  @type t :: %{optional(String.t()) => map | [String.t()] | true}

  @doc "The patch that removes an entity."
  @spec delete() :: t
  def delete, do: %{"d" => true}

  @spec diff(entity | nil, entity) :: t | :unchanged
  def diff(nil, next), do: %{"s" => next}

  def diff(prev, next) do
    {set, append} =
      Enum.reduce(next, {%{}, %{}}, fn {field, value}, {set, append} ->
        case Map.fetch(prev, field) do
          {:ok, ^value} ->
            {set, append}

          {:ok, old}
          when is_binary(old) and is_binary(value) and byte_size(value) > byte_size(old) ->
            size = byte_size(old)

            case value do
              <<^old::binary-size(^size), suffix::binary>> ->
                {set, Map.put(append, field, suffix)}

              _ ->
                {Map.put(set, field, value), append}
            end

          _ ->
            {Map.put(set, field, value), append}
        end
      end)

    unset = for {field, _} <- prev, not Map.has_key?(next, field), do: field

    %{"s" => set, "a" => append, "u" => unset}
    |> Map.reject(fn {_, v} -> v == %{} or v == [] end)
    |> case do
      empty when map_size(empty) == 0 -> :unchanged
      patch -> patch
    end
  end

  @doc """
  Merges two consecutive patches into one, so that
  `apply(apply(e, p1), p2) == apply(e, compose(p1, p2))` for any entity `e`. Socket
  processes use it to collapse a burst of streaming updates before sending.
  """
  @spec compose(t, t) :: t
  def compose(p1, p2) when is_map_key(p1, "q") or is_map_key(p2, "q") do
    # A merged patch is quiet only if every part of it was.
    quiet? = Map.get(p1, "q") == true and Map.get(p2, "q") == true
    merged = compose(Map.delete(p1, "q"), Map.delete(p2, "q"))
    if quiet?, do: Map.put(merged, "q", true), else: merged
  end

  def compose(_p1, %{"d" => true} = p2), do: p2
  def compose(%{"d" => true}, p2), do: Map.put(p2, "d", true)

  def compose(p1, p2) do
    {s1, a1, u1} = parts(p1)
    {s2, a2, u2} = parts(p2)

    # p2's unsets and sets override whatever p1 did to those fields.
    s = s1 |> Map.drop(u2) |> Map.merge(s2)
    a = a1 |> Map.drop(u2) |> Map.drop(Map.keys(s2))
    u = Enum.uniq((u1 -- Map.keys(s2)) ++ u2)

    # p2 appends extend p1's set value or p1's pending append for the same field.
    {s, a} =
      Enum.reduce(a2, {s, a}, fn {field, suffix}, {s, a} ->
        if Map.has_key?(s, field),
          do: {Map.update!(s, field, &(&1 <> suffix)), a},
          else: {s, Map.update(a, field, suffix, &(&1 <> suffix))}
      end)

    %{"s" => s, "a" => a, "u" => u} |> Map.reject(fn {_, v} -> v == %{} or v == [] end)
  end

  defp parts(patch),
    do: {Map.get(patch, "s", %{}), Map.get(patch, "a", %{}), Map.get(patch, "u", [])}

  @doc """
  Applies a patch, returning `nil` when it deletes the entity. Appended strings are
  copied so they never pin a decoded row.
  """
  @spec apply(entity | nil, t) :: entity | nil
  def apply(_entity, %{"d" => true} = patch) when map_size(patch) == 1, do: nil
  def apply(_entity, %{"d" => true} = patch), do: __MODULE__.apply(nil, Map.delete(patch, "d"))

  def apply(entity, %{"q" => true} = patch), do: __MODULE__.apply(entity, Map.delete(patch, "q"))

  def apply(entity, patch) do
    entity = Map.merge(entity || %{}, Map.get(patch, "s", %{}))
    entity = Map.drop(entity, Map.get(patch, "u", []))

    Enum.reduce(Map.get(patch, "a", %{}), entity, fn {field, suffix}, acc ->
      Map.update(acc, field, :binary.copy(suffix), &(&1 <> suffix))
    end)
  end
end
