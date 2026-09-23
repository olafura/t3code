defmodule T3.SettingsTest do
  use ExUnit.Case, async: false

  alias T3.Settings

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    start_supervised!(Settings)
    %{path: Path.join(dir, "settings.json")}
  end

  test "writes need the version they read; the document survives a restart", %{path: path} do
    assert {%{}, 0} = Settings.get()
    :ok = Settings.watch(self())

    doc = %{"enableAssistantStreaming" => false}
    assert {:ok, 1} = Settings.put(doc, 0)
    assert_receive {:t3_settings, _, ^doc}

    # Another client's write from the same starting point is refused.
    assert {:error, :stale} = Settings.put(%{"other" => true}, 0)
    assert {^doc, 1} = Settings.get()

    assert %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    :ok = stop_supervised(Settings)
    start_supervised!(Settings)
    assert {^doc, 0} = Settings.get()
  end
end
