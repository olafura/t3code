defmodule T3.Acp.CatalogTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  defmodule Files do
    @moduledoc false
    @behaviour Plug

    def init(dir), do: dir

    def call(%{request_path: "/" <> name} = conn, dir) do
      case File.read(Path.join(dir, name)) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, Path.join(dir, "home"))
    :persistent_term.erase({T3.Acp.Catalog, :index})
    start_supervised!(T3.Settings)

    served = Path.join(dir, "served")
    File.mkdir_p!(served)
    server = start_supervised!({Bandit, plug: {Files, served}, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:t3, :acp_registry_url, "#{base}/registry.json")

    on_exit(fn ->
      Application.delete_env(:t3, :acp_registry_url)
      :persistent_term.erase({T3.Acp.Catalog, :index})
    end)

    # An agent archive holding bin/fake, a script that runs the fake ACP agent.
    script = Path.join(dir, "fake")
    File.write!(script, "#!/bin/sh\nexec python3 -u #{@fake_acp} \"$@\"\n")
    File.chmod!(script, 0o755)
    archive = Path.join(served, "fake.tar.gz")

    :ok =
      :erl_tar.create(to_charlist(archive), [{~c"bin/fake", to_charlist(script)}], [:compressed])

    sha = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    %{served: served, base: base, sha: sha}
  end

  defp publish(served, agents),
    do:
      File.write!(
        Path.join(served, "registry.json"),
        JSON.encode!(%{"version" => "1.0.0", "agents" => agents})
      )

  defp fake(base, sha, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "fake-agent",
        "name" => "Fake Agent",
        "version" => "1.2.3",
        "description" => "A test agent",
        "authors" => ["Tests"],
        "distribution" => %{
          "binary" => %{
            T3.Acp.Catalog.platform() => %{
              "archive" => "#{base}/fake.tar.gz",
              "cmd" => "./bin/fake",
              "args" => ["--acp"],
              "env" => %{"FAKE_MODE" => "1"},
              "sha256" => sha
            }
          }
        }
      },
      extra
    )
  end

  test "search ranks agents and describes their distribution", %{
    served: served,
    base: base,
    sha: sha
  } do
    publish(served, [
      fake(base, sha),
      %{
        "id" => "other",
        "name" => "Other",
        "version" => "1.0.0",
        "description" => "mentions fake in passing",
        "distribution" => %{"npx" => %{"package" => "other@1.0.0"}}
      },
      # Unsafe entries are dropped.
      fake(base, sha, %{"id" => "../escape"})
    ])

    assert {:ok, %{"agents" => [first, second]}} = T3.Acp.Catalog.search(%{"query" => "fake"})
    assert %{"id" => "fake-agent", "distribution" => "binary", "integrity" => "sha256"} = first
    assert %{"id" => "other", "distribution" => "npx", "integrity" => "registry"} = second
  end

  test "an agent installs, runs from its instance, and uninstalls when unused",
       %{served: served, base: base, sha: sha} do
    publish(served, [fake(base, sha)])

    assert {:ok, %{"agentId" => "fake-agent", "version" => "1.2.3", "distribution" => "binary"}} =
             T3.Acp.Catalog.prepare(%{"agentId" => "fake-agent"})

    instance = %{
      "driver" => "acpRegistry",
      "displayName" => "My Fake",
      "environment" => [%{"name" => "FAKE_KEY", "value" => "secret"}],
      "config" => %{"agentId" => "fake-agent"}
    }

    {:ok, 1} = T3.Settings.put(%{"providerInstances" => %{"acpRegistry_fake" => instance}}, 0)

    assert T3.Acp.agent?("acpRegistry_fake")
    assert {:ok, [exe, "--acp"], env} = T3.Acp.command("acpRegistry_fake")
    assert exe =~ ~r{/tools/fake-agent/1\.2\.3/[^/]+/bin/fake$}
    assert {"FAKE_MODE", "1"} in env and {"FAKE_KEY", "secret"} in env

    # The provider entry reads the agent's models from a throwaway session.
    :ok = T3.Settings.watch(self())

    assert %{"driver" => "acpRegistry", "displayName" => "My Fake", "enabled" => true} =
             T3.Acp.entry("acpRegistry_fake")

    assert_receive {:t3_providers_changed, _}, 5_000

    assert %{"version" => "9.9", "models" => [%{"slug" => "fake/one"}, _]} =
             T3.Acp.entry("acpRegistry_fake")

    assert {:ok, %{"removed" => false}} = T3.Acp.Catalog.uninstall(%{"agentId" => "fake-agent"})
    {:ok, 2} = T3.Settings.put(%{"providerInstances" => %{}}, 1)
    assert {:ok, %{"removed" => true}} = T3.Acp.Catalog.uninstall(%{"agentId" => "fake-agent"})
    refute File.exists?(Path.dirname(Path.dirname(Path.dirname(exe))))
  end

  test "an archive that does not match its checksum is not installed",
       %{served: served, base: base} do
    publish(served, [fake(base, String.duplicate("0", 64))])

    assert {:error, %{"_tag" => "AcpRegistryOperationError", "reason" => "checksum_mismatch"}} =
             T3.Acp.Catalog.prepare(%{"agentId" => "fake-agent"})

    home = Application.fetch_env!(:t3, :home)
    assert Path.wildcard(Path.join(home, "tools/fake-agent/**/bin/fake")) == []
  end

  test "the cached index serves when the registry is unreachable",
       %{served: served, base: base, sha: sha} do
    publish(served, [fake(base, sha)])
    assert {:ok, %{"agents" => [_]}} = T3.Acp.Catalog.search(%{"query" => ""})

    File.rm!(Path.join(served, "registry.json"))
    :persistent_term.erase({T3.Acp.Catalog, :index})

    assert {:ok, %{"agents" => [%{"id" => "fake-agent"}]}} =
             T3.Acp.Catalog.search(%{"query" => ""})
  end
end
