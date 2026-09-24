defmodule T3.Antigravity.InstallationTest do
  use ExUnit.Case, async: false

  alias T3.Antigravity.Installation

  @moduletag :tmp_dir
  @fake Path.expand("../support/fake_antigravity.py", __DIR__)

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    Application.put_env(:t3, :home, home)
    on_exit(fn -> Application.delete_env(:t3, :antigravity_release) end)
    start_supervised!(T3.Settings)
    {:ok, home: home, release: release(dir)}
  end

  # A zip of the fake agent and a harness, pinned like Google's release.
  defp release(dir, extra \\ []) do
    src = Path.join(dir, "release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    File.cp!(@fake, Path.join(src, "agy_acp_server.par"))
    File.write!(Path.join(src, "localharness_external"), "#!/bin/sh\nexit 0\n")
    for {name, body} <- extra, do: File.write!(Path.join(src, name), body)

    names = ["agy_acp_server.par", "localharness_external"] ++ Enum.map(extra, &elem(&1, 0))
    archive = Path.join(dir, "#{Path.basename(src)}.zip")

    {:ok, _} =
      :zip.create(String.to_charlist(archive), Enum.map(names, &String.to_charlist/1),
        cwd: String.to_charlist(src)
      )

    bytes = File.read!(archive)

    %{
      url: "file://" <> archive,
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      archive_bytes: byte_size(bytes),
      executable: {"agy_acp_server.par", File.stat!(Path.join(src, "agy_acp_server.par")).size},
      harness: {"localharness_external", File.stat!(Path.join(src, "localharness_external")).size}
    }
  end

  defp install(release) do
    Application.put_env(:t3, :antigravity_release, release)
    start_supervised!(Installation)
    {:ok, _} = Installation.subscribe("antigravity", self())
    assert {:ok, %{"phase" => "downloading", "operationId" => op}} = Installation.start()
    op
  end

  defp await_phase(phases) do
    receive do
      {:t3_provider_install, "antigravity", %{"phase" => phase} = state} ->
        if phase in phases, do: state, else: await_phase(phases)
    after
      30_000 -> flunk("no install state in #{inspect(phases)}")
    end
  end

  test "installs a verified release, resolves it, and removes it", %{release: release} do
    assert {:error, "Antigravity is not installed" <> _} = Installation.resolve(nil, "")
    install(release)

    assert %{
             "phase" => "succeeded",
             "installedVersion" => "agy_acp_server_1.1.1",
             "canRemove" => true
           } =
             await_phase(~w(succeeded failed))

    assert {:ok, %{source: "managed", version: "agy_acp_server_1.1.1", dir: dir, path: path}} =
             Installation.resolve(nil, "")

    assert Path.basename(dir) == release.sha256
    assert File.regular?(path)
    assert Path.wildcard(Path.join(Path.dirname(dir), ".install-*"), match_dot: true) == []

    # A second install reuses the published release.
    assert {:ok, _} = Installation.start()
    assert %{"phase" => "succeeded"} = await_phase(~w(succeeded failed))

    # A running agent holds the release.
    holder = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Installation.lease(holder, %{dir: dir})
    assert {:error, %{detail: "Stop Antigravity sessions" <> _}} = Installation.remove()
    Process.exit(holder, :kill)
    Process.sleep(50)

    # So does a custom path inside it.
    assert {:error, %{detail: "A provider instance has a custom path" <> _}} =
             Installation.remove([path])

    assert :ok = Installation.remove()

    assert %{"phase" => "idle", "installedVersion" => nil, "canRemove" => false} =
             Installation.state()

    assert {:error, _} = Installation.resolve(nil, "")
  end

  test "a download that fails its SHA-256 check installs nothing", %{release: release} do
    install(%{release | sha256: String.duplicate("0", 64)})

    assert %{"phase" => "failed", "message" => "The Antigravity download failed its size" <> _} =
             await_phase(~w(succeeded failed))

    assert {:error, _} = Installation.resolve(nil, "")
    versions = Path.join(Installation.managed_dir(), "versions")
    assert Path.wildcard(Path.join(versions, "*"), match_dot: true) == []
  end

  test "an archive with more than the two runtime files is refused", %{tmp_dir: dir} do
    install(release(dir, [{"extra.txt", "surprise"}]))

    assert %{"phase" => "failed", "message" => "The archive must contain exactly" <> _} =
             await_phase(~w(succeeded failed))
  end

  test "a runtime that is not the pinned release fails verification", %{release: release} do
    install(Map.put(release, :version, "agy_acp_server_9.9.9"))

    assert %{"phase" => "failed", "message" => "The downloaded runtime did not identify" <> _} =
             await_phase(~w(succeeded failed))

    assert {:error, _} = Installation.resolve(nil, "")
  end

  test "cancelling a download leaves nothing installed", %{release: release} do
    # A server that accepts the download and never answers.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, _socket} = :gen_tcp.accept(listen)
      Process.sleep(:infinity)
    end)

    op = install(%{release | url: "http://127.0.0.1:#{port}/agy.zip"})

    assert {:ok, %{"phase" => "cancelled", "message" => "Installation cancelled" <> _}} =
             Installation.cancel(op)

    assert {:error, %{detail: "This installation is no longer current" <> _}} =
             Installation.cancel("other")

    assert {:error, _} = Installation.resolve(nil, "")
  end

  test "a custom executable is found with its harness, on PATH or by path", %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    exe = Path.join(bin, "agy_acp_server.par")
    File.cp!(@fake, exe)
    File.chmod!(exe, 0o755)

    assert {:error, "The custom Antigravity executable" <> _} = Installation.resolve(exe, "")

    File.write!(Path.join(bin, "localharness_external"), "#!/bin/sh\n")
    File.chmod!(Path.join(bin, "localharness_external"), 0o755)

    assert {:ok, %{source: "override", version: nil, dir: nil, harness: harness}} =
             Installation.resolve(exe, "")

    assert Path.basename(harness) == "localharness_external"
    assert {:ok, %{source: "path"}} = Installation.resolve(nil, bin)
    assert {:ok, %{source: "override"}} = Installation.resolve("agy_acp_server.par", bin)
  end

  test "only managed Antigravity instances install", %{release: release} do
    Application.put_env(:t3, :antigravity_release, release)
    start_supervised!(Installation)

    assert {:error,
            %{"_tag" => "ProviderSetupError", "detail" => "Managed installation is not" <> _}} =
             T3.Antigravity.install_start(%{"instanceId" => "grok"})

    {:ok, _} =
      T3.Settings.put(%{"providers" => %{"antigravity" => %{"binaryPath" => "/opt/agy"}}}, 0)

    assert {:error,
            %{"operation" => "install", "detail" => "This instance uses a custom executable" <> _}} =
             T3.Antigravity.install_start(%{"instanceId" => "antigravity"})

    assert {:ok, %{"phase" => "idle"}} = T3.Antigravity.install_subscribe("antigravity", self())
  end
end
