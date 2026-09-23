defmodule T3.EnvironmentThemesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :theme_check_ms, nil)
    on_exit(fn -> Application.delete_env(:t3, :theme_check_ms) end)
    themes = Path.join(dir, "themes")
    File.mkdir_p!(themes)
    %{themes: themes}
  end

  defp write(dir, name, content),
    do:
      File.write!(
        Path.join(dir, name),
        if(is_binary(content), do: content, else: JSON.encode!(content))
      )

  test "only small, well-formed, colored themes under their filename's id are published",
       %{themes: dir} do
    write(dir, "desk.json", %{
      "id" => "someone-else",
      "name" => "Desk",
      "appearance" => "dark",
      "canvas" => "#101010",
      "accent" => "#ff8800",
      "extra" => true
    })

    write(dir, "palette.json", %{
      "version" => 1,
      "name" => "Palette",
      "appearance" => "light",
      "colors" => %{"background" => "oklch(0.98 0 0)"}
    })

    # Colorless, a reserved id, a bad color, broken JSON, too big, and a symlink.
    write(dir, "plain.json", %{"name" => "Plain", "appearance" => "dark"})

    write(dir, "dark.json", %{
      "name" => "D",
      "appearance" => "dark",
      "canvas" => "#000",
      "accent" => "#fff"
    })

    write(dir, "bad.json", %{
      "name" => "B",
      "appearance" => "dark",
      "canvas" => "red",
      "accent" => "#fff"
    })

    write(dir, "broken.json", "{")
    write(dir, "huge.json", String.duplicate(" ", 40_000) <> "{}")
    File.ln_s!(Path.join(dir, "desk.json"), Path.join(dir, "link.json"))

    assert [
             %{"id" => "desk", "name" => "Desk", "canvas" => "#101010"} = desk,
             %{"id" => "palette", "colors" => %{"background" => _}}
           ] = T3.EnvironmentThemes.read()

    refute Map.has_key?(desk, "extra")
  end

  test "watchers of the node's settings hear about a change", %{themes: dir} do
    start_supervised!(T3.Settings)
    start_supervised!(T3.EnvironmentThemes)
    :ok = T3.Settings.watch(self())
    assert T3.EnvironmentThemes.current() == []

    write(dir, "desk.json", %{
      "name" => "Desk",
      "appearance" => "dark",
      "canvas" => "#101010",
      "accent" => "#f80"
    })

    send(T3.EnvironmentThemes, :check)

    assert_receive {:t3_themes, _, [%{"id" => "desk"}]}, 1_000
  end
end
