defmodule T3.Keybindings do
  @moduledoc """
  The user's keybinding rules (`<home>/keybindings.json`), as written: `key`,
  `command`, and optional `when`. Clients merge them with the defaults and
  compile them (`@t3tools/shared/keybindings`), so the node only stores rules and
  says when they change (`{:t3_keybindings, node, rules}` to settings watchers).
  """

  @max 256

  @doc "The stored rules, skipping entries that are not rules."
  def rules do
    with {:ok, text} <- File.read(path()),
         {:ok, list} when is_list(list) <- JSON.decode(text) do
      for %{"key" => key, "command" => command} = rule <- list,
          is_binary(key) and is_binary(command) and
            (rule["when"] == nil or is_binary(rule["when"])),
          do: Map.take(rule, ~w(key command when))
    else
      _ -> []
    end
  end

  @doc "`server.upsertKeybinding`: adds a rule, replacing an equal one or `replace`."
  def upsert(input) do
    rule = rule(input)
    replace = input["replace"] && rule(input["replace"])

    rules()
    |> Enum.reject(&(&1 == rule or &1 == replace))
    |> Kernel.++([rule])
    |> Enum.take(-@max)
    |> save()
  end

  @doc "`server.removeKeybinding`: removes a rule."
  def remove(input) do
    target = rule(input)
    rules() |> Enum.reject(&(&1 == target)) |> save()
  end

  defp rule(input),
    do: input |> Map.take(~w(key command when)) |> Map.reject(fn {_, v} -> v == nil end)

  defp save(rules) do
    file = path()
    tmp = file <> ".tmp"
    File.mkdir_p!(Path.dirname(file))
    File.write!(tmp, JSON.encode!(rules))
    File.rename!(tmp, file)
    T3.Settings.notify_keybindings(rules)
    {:ok, %{"rules" => rules}}
  end

  defp path, do: Path.join(Application.fetch_env!(:t3, :home), "keybindings.json")
end
