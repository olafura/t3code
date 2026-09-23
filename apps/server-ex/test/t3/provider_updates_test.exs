defmodule T3.ProviderUpdatesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    # The latest release, as if already read from the registry.
    for driver <- ["codex", "claudeAgent"],
        do:
          :persistent_term.put(
            {T3.ProviderUpdates, driver},
            {"9.9.9", System.monotonic_time(:millisecond)}
          )

    on_exit(fn ->
      for driver <- ["codex", "claudeAgent"],
          do: :persistent_term.erase({T3.ProviderUpdates, driver})
    end)
  end

  # An executable at `real`, found through a symlink at `link`.
  defp install(dir, real, link) do
    real = Path.join(dir, real)
    link = Path.join(dir, link)
    File.mkdir_p!(Path.dirname(real))
    File.mkdir_p!(Path.dirname(link))
    File.write!(real, "")
    File.ln_s!(real, link)
    link
  end

  test "a Homebrew install updates with brew", %{tmp_dir: dir} do
    path = install(dir, "Cellar/codex/0.1.0/bin/codex", "bin/codex")

    assert %{
             "status" => "behind_latest",
             "latestVersion" => "9.9.9",
             "canUpdate" => true,
             "updateCommand" => "brew upgrade codex"
           } = T3.ProviderUpdates.advisory("codex", path, "0.1.0")
  end

  test "a global npm install updates its own prefix", %{tmp_dir: dir} do
    path = install(dir, "lib/node_modules/@openai/codex/bin/codex.js", "bin/codex")
    advisory = T3.ProviderUpdates.advisory("codex", path, "9.9.9")

    assert advisory["status"] == "current"
    assert advisory["updateCommand"] == "npm install -g --prefix #{dir} @openai/codex@latest"
  end

  test "an install nothing here owns is reported without an update", %{tmp_dir: dir} do
    path = install(dir, "opt/codex", "bin/codex")

    assert %{"canUpdate" => false, "updateCommand" => nil, "status" => "unknown"} =
             T3.ProviderUpdates.advisory("codex", path, "unknown")
  end
end
