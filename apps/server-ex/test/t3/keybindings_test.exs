defmodule T3.KeybindingsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:t3, :home)
    Application.put_env(:t3, :home, dir)
    on_exit(fn -> Application.put_env(:t3, :home, previous) end)
    %{path: Path.join(dir, "keybindings.json")}
  end

  test "rules are added, replaced, and removed in the user's file", %{path: path} do
    assert T3.Keybindings.rules() == []

    {:ok, _} = T3.Keybindings.upsert(%{"key" => "mod+j", "command" => "terminal.toggle"})

    {:ok, %{"rules" => rules}} =
      T3.Keybindings.upsert(%{
        "key" => "mod+shift+j",
        "command" => "terminal.toggle",
        "replace" => %{"key" => "mod+j", "command" => "terminal.toggle"}
      })

    assert rules == [%{"key" => "mod+shift+j", "command" => "terminal.toggle"}]
    assert JSON.decode!(File.read!(path)) == rules

    {:ok, %{"rules" => []}} =
      T3.Keybindings.remove(%{"key" => "mod+shift+j", "command" => "terminal.toggle"})
  end

  test "entries that are not rules are skipped", %{path: path} do
    File.write!(path, ~s([{"key": "mod+k", "command": "commandPalette.toggle"}, 3, {"key": 1}]))
    assert T3.Keybindings.rules() == [%{"key" => "mod+k", "command" => "commandPalette.toggle"}]
  end
end
