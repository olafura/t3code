defmodule T3.DevicesTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @moduletag :tmp_dir
  @support Path.expand("../support", __DIR__)

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)

    # The pinned tools, already installed: the hub and agent-device fakes run
    # with the system Node exactly as the real ones would.
    install(dir, "expo-device-hub", "0.10.1", ~w(dist server cli.mjs), "fake_device_hub.mjs")
    install(dir, "agent-device", "0.21.12", ~w(bin agent-device.mjs), "fake_agent_device.mjs")

    sdk = Path.join(dir, "sdk")
    tool(Path.join([sdk, "platform-tools", "adb"]), "fake_adb.sh")
    tool(Path.join([sdk, "emulator", "emulator"]), "fake_emulator.sh")
    tool(Path.join([sdk, "cmdline-tools", "latest", "bin", "avdmanager"]), "fake_emulator.sh")

    previous = System.get_env("ANDROID_HOME")
    System.put_env("ANDROID_HOME", sdk)

    on_exit(fn ->
      if previous,
        do: System.put_env("ANDROID_HOME", previous),
        else: System.delete_env("ANDROID_HOME")
    end)

    start_supervised!(T3.Settings)
    start_supervised!(T3.Devices)
    {:ok, _} = T3.Devices.subscribe(self())
    :ok
  end

  test "devices list once enabled, and a thread opens and closes one" do
    assert {:ok, %{"hostStatus" => "disabled", "devices" => []}} = T3.Devices.list(%{})

    {:ok, state} = T3.Devices.configure(%{"enabled" => true})
    assert %{"hostStatus" => "ready", "hubBasePath" => "/api/device-hub/nodes/" <> _} = state

    assert [%{"id" => "Pixel_9", "booted" => false}, %{"id" => "Broken"}] =
             Enum.filter(state["devices"], &(&1["platform"] == "android"))

    assert {:ok, %{"deviceId" => "emulator-5554", "threadId" => "t1"}} =
             T3.Devices.open(%{
               "threadId" => "t1",
               "deviceId" => "Pixel_9",
               "platform" => "android"
             })

    # The AVD boots under the thread, then shows up by its serial as open there.
    next_state(&match?([%{"id" => "Pixel_9", "threadId" => "t1"}], &1["bootingDevices"]))
    opened = next_state(&(&1["sessions"] != []))

    assert [%{"threadId" => "t1", "deviceId" => "emulator-5554", "platform" => "android"}] =
             opened["sessions"]

    assert Enum.any?(opened["devices"], &match?(%{"id" => "emulator-5554", "booted" => true}, &1))

    assert {:ok, nil} = T3.Devices.close(%{"threadId" => "t1"})
    assert %{"sessions" => []} = next_state(&(&1["sessions"] == []))

    # A boot that fails for disk space says so.
    assert {:error, %{"_tag" => "DeviceBootError", "reason" => "disk_space"}} =
             T3.Devices.open(%{
               "threadId" => "t1",
               "deviceId" => "Broken",
               "platform" => "android"
             })

    assert {:error, %{"_tag" => "DeviceNotFoundError"}} =
             T3.Devices.open(%{"threadId" => "t1", "deviceId" => "nope", "platform" => "android"})
  end

  test "SSH hosts are unavailable, with the reason" do
    {settings, version} = T3.Settings.get()

    hosts = [%{"id" => "mini", "label" => "Mac mini", "target" => "me@mini"}]
    {:ok, _} = T3.Settings.put(Map.put(settings, "deviceHosts", hosts), version)
    {:ok, state} = T3.Devices.configure(%{"enabled" => true})

    assert %{"kind" => "ssh", "platforms" => [%{"available" => false, "reason" => reason} | _]} =
             Enum.find(state["hosts"], &(&1["id"] == "mini"))

    assert reason =~ "Run T3 on me@mini"
    assert %{"mini" => %{"status" => "failed"}} = state["hostStatuses"]

    assert {:error, %{"_tag" => "DeviceHostUnavailableError", "hostId" => "mini"}} =
             T3.Devices.test_host(%{"id" => "mini", "label" => "Mac mini", "target" => "me@mini"})

    assert {:error, %{"_tag" => "DeviceHostUnavailableError", "reason" => ^reason}} =
             T3.Devices.open(%{
               "threadId" => "t1",
               "hostId" => "mini",
               "deviceId" => "x",
               "platform" => "android"
             })
  end

  test "actions run adb and map its failures" do
    {:ok, _} = T3.Devices.configure(%{"enabled" => true})

    assert {:ok, %{"settings" => %{"appearance" => "light", "textSize" => "large"}}} =
             T3.Devices.action(%{
               "deviceId" => "Pixel_9",
               "type" => "setTextSize",
               "value" => "large"
             })

    assert {:error,
            %{
              "_tag" => "DeviceOperationError",
              "operation" => "appearance",
              "reason" => "command_failed",
              "exitCode" => 3,
              "cause" => "adb: device offline\n"
            }} =
             T3.Devices.action(%{
               "deviceId" => "Pixel_9",
               "type" => "setAppearance",
               "value" => "dark"
             })

    assert {:error,
            %{
              "_tag" => "DeviceActionUnavailableError",
              "platform" => "android",
              "reason" => "unsupported"
            }} =
             T3.Devices.action(%{"deviceId" => "Pixel_9", "type" => "shake"})
  end

  test "the hub proxy forwards a request to the node that owns the hub" do
    {:ok, _} = T3.Devices.configure(%{"enabled" => true})
    base = T3.Devices.hub_base_path()

    conn =
      conn(:get, "#{base}/api/devices?hostId=local&token=#{T3.Web.token()}")
      |> T3.Web.Router.call([])

    assert conn.status == 200
    # Credentials and the host stay on this side.
    assert Plug.Conn.get_resp_header(conn, "x-fake-hub-url") == ["/api/devices"]
    assert %{"simulators" => [], "emulators" => []} = JSON.decode!(conn.resp_body)

    assert (conn(:get, "#{base}/api/devices") |> T3.Web.Router.call([])).status == 401

    assert (conn(:get, "#{base}/vendor/serve-sim/exec?token=#{T3.Web.token()}")
            |> T3.Web.Router.call([])).status == 404
  end

  test "a stream's WebSocket is relayed to the hub frame by frame" do
    Application.put_env(:t3, :port, 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    {:ok, _} = T3.Devices.configure(%{"enabled" => true})

    # The WebSocket client reads every message this process gets.
    T3.Devices.unsubscribe(self())
    T3.Devices.state()
    flush_states()

    path =
      "#{T3.Devices.hub_base_path()}/vendor/serve-emu/ws?device=emulator-5554&token=#{T3.Web.token()}"

    {:ok, client} = T3.Test.WsClient.connect(port, path)

    assert {%{"hello" => "/vendor/serve-emu/ws?device=emulator-5554"}, client} =
             T3.Test.WsClient.recv(client, 5_000)

    client = T3.Test.WsClient.send_json(client, %{"tap" => [10, 20]})
    assert {%{"echo" => %{"tap" => [10, 20]}}, _} = T3.Test.WsClient.recv(client, 5_000)
  end

  test "an agent opens a device and sees its screen through the MCP server" do
    start_supervised!(T3.Mcp)
    %{authorization: auth} = T3.Mcp.server("thread-1", "codex")

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             tool(auth, "device_list", %{})

    assert text =~ "Agent device access is turned off"

    {:ok, _} = T3.Devices.configure(%{"enabled" => true, "agentAccessEnabled" => true})

    assert %{"structuredContent" => opened} =
             tool(auth, "device_open", %{"platform" => "android"})

    assert %{
             "device" => %{"id" => "emulator-5554", "booted" => true},
             "agentDevice" => %{"command" => command, "targetArgs" => args}
           } = opened

    assert [
             "--platform",
             "android",
             "--serial",
             "emulator-5554",
             "--config",
             config,
             "--session",
             "t3-" <> _
           ] =
             args

    assert File.exists?(command)
    assert %{"daemonAuthToken" => "fake-token"} = config |> File.read!() |> JSON.decode!()

    assert %{"structuredContent" => shot, "content" => [_, image]} =
             tool(auth, "device_screenshot", %{})

    assert %{"screenshot" => %{"mimeType" => "image/png", "width" => 390, "height" => 844}} = shot
    assert %{"type" => "image", "mimeType" => "image/png", "data" => data} = image
    assert <<0x89, "PNG", _::binary>> = Base.decode64!(data)

    assert %{"structuredContent" => %{"open" => [%{"deviceId" => "emulator-5554"}]}} =
             tool(auth, "device_list", %{})

    assert %{"structuredContent" => %{}} = tool(auth, "device_close", %{})
    assert %{"structuredContent" => %{"open" => []}} = tool(auth, "device_list", %{})
  end

  defp tool(auth, name, arguments) do
    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    {200, %{"result" => result}} = T3.Mcp.handle(auth, body)
    result
  end

  # Receives device states until one matches.
  defp next_state(fun) do
    receive do
      {:t3_devices, _, state} -> if fun.(state), do: state, else: next_state(fun)
    after
      5_000 -> flunk("no matching device state")
    end
  end

  defp flush_states do
    receive do
      {:t3_devices, _, _} -> flush_states()
    after
      0 -> :ok
    end
  end

  defp install(dir, name, version, entry, fake) do
    root = Path.join([dir, "tools", name, version])
    tool(Path.join([root, "node_modules", name | entry]), fake)
    File.write!(Path.join(root, ".install-complete"), version <> "\n")
  end

  defp tool(path, fake) do
    File.mkdir_p!(Path.dirname(path))
    File.cp!(Path.join(@support, fake), path)
    File.chmod!(path, 0o755)
  end
end
