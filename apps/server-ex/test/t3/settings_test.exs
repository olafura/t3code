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

  test "a project's overrides apply over the environment's, except models on disabled providers" do
    settings = %{
      "enableAgentBrowserAccess" => true,
      "worktreeSubmodules" => "recursive",
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "providerInstances" => %{"claudeAgent" => %{"enabled" => false}},
      "projectSettingsOverrides" => %{
        "p1" => %{
          "enableAgentBrowserAccess" => false,
          "worktreeSubmodules" => "none",
          "textGenerationModelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"},
          "notScoped" => 1
        }
      }
    }

    resolved = T3.Settings.resolve(settings, "p1")
    assert resolved["enableAgentBrowserAccess"] == false
    assert resolved["worktreeSubmodules"] == "none"
    assert resolved["textGenerationModelSelection"]["instanceId"] == "codex"
    refute Map.has_key?(resolved, "notScoped")
    assert T3.Settings.resolve(settings, "p2") == settings
    assert T3.Settings.resolve(settings, nil) == settings
  end
end
