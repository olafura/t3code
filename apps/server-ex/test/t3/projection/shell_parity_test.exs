defmodule T3.Projection.ShellParityTest do
  @moduledoc """
  Compares `thread_shell/1` with shells the Node server produced for the same log.

      T3_PARITY_DB=node-state.sqlite T3_PARITY_GOLDEN=shells.json \\
        mix test --include parity test/t3/projection/shell_parity_test.exs

  The golden file maps thread id to the encoded `OrchestrationV2ThreadShell`. Both
  files hold real user data and stay outside the repository.
  """

  use ExUnit.Case, async: true

  @moduletag :parity
  @moduletag :tmp_dir
  @moduletag timeout: :infinity

  alias T3.Projection.JS
  alias T3.Projection.Shell

  test "shells match the Node server's", %{tmp_dir: dir} do
    db = System.fetch_env!("T3_PARITY_DB")

    golden = JSON.decode!(File.read!(System.fetch_env!("T3_PARITY_GOLDEN")))

    store = start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite"), name: nil})
    {:ok, _report} = T3.Import.V2.run(db, store, only: Map.keys(golden))
    path = T3.Store.path(store)

    mismatches =
      for {id, expected} <- Enum.sort(golden),
          diff = diff(expected, Shell.thread_shell(T3.StreamState.load(path, id))),
          diff != [],
          do: "#{id}:\n" <> Enum.map_join(diff, "\n", &("  " <> &1))

    assert mismatches == [],
           "#{length(mismatches)}/#{map_size(golden)} threads differ:\n\n" <>
             Enum.join(mismatches, "\n\n")
  end

  defp diff(expected, actual) do
    keys = Enum.uniq(Map.keys(expected) ++ Map.keys(actual)) |> Enum.sort()

    for key <- keys, not same?(key, Map.fetch(expected, key), Map.fetch(actual, key)) do
      "#{key}: expected #{show(Map.fetch(expected, key))}, got #{show(Map.fetch(actual, key))}"
    end
  end

  # Dropped byte-identical re-emits can leave our latest event earlier than Node's.
  defp same?("updatedAt", {:ok, expected}, {:ok, actual}),
    do: JS.epoch_ms(actual) <= JS.epoch_ms(expected)

  defp same?(_key, expected, actual), do: expected == actual

  defp show(:error), do: "(absent)"
  defp show({:ok, value}), do: inspect(value, printable_limit: 80, limit: 8)
end
