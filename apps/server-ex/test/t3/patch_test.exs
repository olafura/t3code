defmodule T3.PatchTest do
  use ExUnit.Case, async: true

  alias T3.Patch

  test "streaming text stores only the new suffix" do
    v1 = %{"id" => "i", "text" => "Hello", "status" => "running"}
    v2 = %{"id" => "i", "text" => "Hello, world", "status" => "running"}
    assert Patch.diff(v1, v2) == %{"a" => %{"text" => ", world"}}
    assert Patch.apply(v1, Patch.diff(v1, v2)) == v2
  end

  test "identical re-emits are dropped" do
    v = %{"id" => "i", "text" => "same"}
    assert Patch.diff(v, v) == :unchanged
  end

  test "rewritten text, changed fields and removed fields round-trip" do
    v1 = %{"id" => "i", "text" => "draft", "tokenUsage" => %{"in" => 1}, "status" => "running"}
    v2 = %{"id" => "i", "text" => "final answer", "status" => "completed"}
    patch = Patch.diff(v1, v2)
    assert patch["u"] == ["tokenUsage"]
    assert Patch.apply(v1, patch) == v2
  end

  test "a shorter string is a set, not an append" do
    assert Patch.diff(%{"t" => "abc"}, %{"t" => "ab"}) == %{"s" => %{"t" => "ab"}}
  end

  test "compose/2 is equivalent to applying both patches, for random versions" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..2_000 do
      [v0, v1, v2] = Enum.scan(1..3, random_entity(), fn _, prev -> mutate(prev) end)
      p1 = Patch.diff(v0, v1)
      p2 = Patch.diff(v1, v2)

      unless p1 == :unchanged or p2 == :unchanged do
        assert Patch.apply(v0, Patch.compose(p1, p2)) == v2
      end
    end
  end

  defp random_entity, do: Map.new(Enum.take_random(~w(a b c d), 3), &{&1, random_value()})
  defp random_value, do: Enum.random(["", "x", "xy", "hello", 1, 2, nil])

  # Grow strings (streaming), replace values, add and remove fields.
  defp mutate(entity) do
    Enum.reduce(~w(a b c d), entity, fn field, acc ->
      case {:rand.uniform(5), Map.get(acc, field)} do
        {1, v} when is_binary(v) -> Map.put(acc, field, v <> Enum.random(["z", "zz", "!"]))
        {2, _} -> Map.put(acc, field, random_value())
        {3, _} -> Map.delete(acc, field)
        _ -> acc
      end
    end)
  end

  test "folding a sequence of patches reproduces the last version" do
    versions =
      Enum.scan(1..50, %{"id" => "i", "text" => "", "n" => 0}, fn n, acc ->
        acc
        |> Map.update!("text", &(&1 <> "chunk#{n} "))
        |> Map.put("n", n)
        |> then(&if(rem(n, 7) == 0, do: Map.delete(&1, "n"), else: &1))
      end)

    {state, _} =
      Enum.reduce(versions, {nil, nil}, fn v, {state, prev} ->
        case Patch.diff(prev, v) do
          :unchanged -> {state, v}
          patch -> {Patch.apply(state, patch), v}
        end
      end)

    assert state == List.last(versions)
  end
end
