defmodule T3.AcpTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    start_supervised!(T3.Settings)
    :ok
  end

  test "agent commands follow the runtime mode and the configured binary" do
    assert {:ok, ["opencode", "acp"], []} = T3.Acp.command("opencode", "full-access")

    assert {:ok, ["grok", "agent", "--always-approve", "stdio"], []} =
             T3.Acp.command("grok", "full-access")

    assert {:ok, ["grok", "--permission-mode", "default", "agent", "stdio"], []} =
             T3.Acp.command("grok", "approval-required")

    {:ok, _} =
      T3.Settings.put(
        %{
          "providerInstances" => %{
            "opencode" => %{
              "driver" => "opencode",
              "enabled" => true,
              "config" => %{"binaryPath" => "/opt/oc"}
            }
          }
        },
        0
      )

    assert {:ok, ["/opt/oc", "acp"], []} = T3.Acp.command("opencode")
    assert T3.Acp.enabled?("opencode")
    refute T3.Acp.enabled?("grok")
    assert {:error, _} = T3.Acp.command("nope")
  end
end
