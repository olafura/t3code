defmodule T3.Mcp.Devices do
  @moduledoc """
  The `device_*` MCP tools: an agent lists, opens, screenshots and closes this
  node's simulators and emulators (`T3.Devices`), as on the Node server.

  `device_open` shows the device in the user's Device panel and returns the
  agent-device command pinned to it, which is how the agent drives it; a screenshot
  comes back as image content (`{:ok, structured, content}`). Agents get the tools
  only where the user allowed it: `enableAgentDeviceAccess`, or the thread's
  project override of it, as Node grants its `device` capability.
  """

  @tools ~w(device_list device_open device_screenshot device_close)
  @local "local"

  def names, do: @tools

  def call(name, args, caller) do
    if allowed?(caller.thread_id) do
      case run(name, args || %{}, caller) do
        {:error, %{"_tag" => tag} = error} -> {:error, tag, error["message"] || tag}
        {:error, tag, message} -> {:error, tag, message}
        result -> result
      end
    else
      unavailable("Agent device access is turned off for this environment.")
    end
  end

  defp run("device_list", args, caller) do
    with {:ok, state} <- listed() do
      host = args["hostId"]
      mine = &(host == nil or &1 == host)

      {:ok,
       %{
         "hostStatuses" => Map.filter(state["hostStatuses"], fn {id, _} -> mine.(id) end),
         "hosts" => Enum.filter(state["hosts"], &mine.(&1["id"])),
         "devices" => Enum.filter(state["devices"], &mine.(&1["hostId"])),
         "open" =>
           for(
             session <- state["sessions"],
             session["threadId"] == caller.thread_id,
             do: Map.take(session, ~w(hostId deviceId))
           )
       }}
    end
  end

  # Agent access is checked before anything boots or a session is recorded.
  defp run("device_open", args, caller) do
    with {:ok, state} <- listed(),
         {:ok, target} <- pick(state["devices"], args),
         {:ok, agent_args, command} <-
           T3.Devices.agent_target(caller.thread_id, target["hostId"], target["id"]),
         {:ok, session} <-
           T3.Devices.open(%{
             "threadId" => caller.thread_id,
             "hostId" => target["hostId"],
             "deviceId" => target["id"],
             "platform" => target["platform"]
           }) do
      device =
        Enum.find(T3.Devices.state()["devices"], &(&1["id"] == session["deviceId"])) || target

      target_args = target_args(device) ++ agent_args

      {:ok,
       %{
         "device" => device,
         "agentDevice" => %{"command" => command, "targetArgs" => target_args},
         "quickStart" => quick_start(device, target_args, command)
       }}
    end
  end

  defp run("device_screenshot", args, caller) do
    target =
      if args["deviceId"] do
        %{"hostId" => args["hostId"] || @local, "deviceId" => args["deviceId"]}
      else
        T3.Devices.state()["sessions"]
        |> Enum.filter(
          &(&1["threadId"] == caller.thread_id and args["hostId"] in [nil, &1["hostId"]])
        )
        |> List.last()
      end

    if target do
      with {:ok, device, png} <- T3.Devices.screenshot(target) do
        {width, height} = png_size(png)
        metadata = %{"mimeType" => "image/png", "width" => width, "height" => height}
        structured = %{"device" => device, "screenshot" => metadata}

        {:ok, structured,
         [
           %{"type" => "text", "text" => JSON.encode!(structured)},
           %{"type" => "image", "data" => Base.encode64(png), "mimeType" => "image/png"}
         ]}
      end
    else
      unavailable("No device is open in this thread. Call device_open first.")
    end
  end

  defp run("device_close", args, caller) do
    input =
      args
      |> Map.take(~w(hostId deviceId shutdown))
      |> Map.put("threadId", caller.thread_id)

    with {:ok, _} <- T3.Devices.close(input), do: {:ok, %{}}
  end

  defp listed do
    with {:ok, state} <- T3.Devices.list(%{}) do
      if state["hostStatus"] == "disabled",
        do:
          unavailable(
            "Device support is off. Ask the user to enable it in the Device panel before installing or starting device tools."
          ),
        else: {:ok, state}
    end
  end

  defp pick(devices, %{"deviceId" => id} = args) when is_binary(id) do
    host = args["hostId"] || @local

    case Enum.find(devices, &(&1["hostId"] == host and &1["id"] == id)) do
      nil -> unavailable("No device #{id} on host #{host}. Call device_list for current ids.")
      device -> {:ok, device}
    end
  end

  defp pick(devices, args) do
    host = args["hostId"] || @local
    platform = args["platform"]

    candidates =
      Enum.filter(devices, &(&1["hostId"] == host and platform in [nil, &1["platform"]]))

    cond do
      candidates == [] and platform == nil ->
        unavailable("No simulators or emulators were found. Call device_list to see why.")

      candidates == [] ->
        unavailable(
          "No #{platform} devices were found on host #{host}. Call device_list to see why."
        )

      platform == nil and length(Enum.uniq_by(candidates, & &1["platform"])) > 1 ->
        unavailable("Both iOS and Android devices are available; pass platform or deviceId.")

      true ->
        {:ok, Enum.find(candidates, & &1["booted"]) || hd(candidates)}
    end
  end

  defp target_args(%{"platform" => "ios", "id" => id}), do: ["--platform", "ios", "--udid", id]
  defp target_args(%{"id" => id}), do: ["--platform", "android", "--serial", id]

  # The one place the agent learns how to drive the device, so threads that never
  # open one never pay for it.
  defp quick_start(device, target_args, command) do
    executable = shell_word(command)
    target = Enum.map_join(target_args, " ", &shell_word/1)

    notes =
      if device["platform"] == "ios",
        do:
          "First use builds an XCTest runner and can take a couple of minutes; later commands are fast.",
        else: "The Android snapshot helper installs itself on first use."

    Enum.join(
      [
        "The user is watching #{device["name"]} (#{device["version"]}) in the Device panel.",
        "Drive it with #{executable}. Use this exact executable path; login shells may reset PATH. Always pass #{target}.",
        "Typical loop:",
        "  #{executable} open <bundle-or-package-id> #{target}     # or: open <app> <deep-link-url>",
        "  #{executable} snapshot -i #{target}                     # accessibility tree with @eN refs",
        "  #{executable} click @e3 #{target}",
        "  #{executable} fill @e5 \"text\" #{target}",
        "  #{executable} screenshot /tmp/shot.png #{target}        # or call device_screenshot",
        "  #{executable} install <app> <path-to-.app-or-.apk> #{target}",
        "Prefer snapshot refs over coordinates. Run #{executable} help for workflow guides and #{executable} <command> --help for flags.",
        "Do not call simctl, adb, xcrun, or serve-sim directly while these tools are attached; use agent-device.",
        "For remote hosts, arrange builds, app installation, and any Metro reverse forwarding yourself. T3 provides discovery, streaming, and control only.",
        "Keep the returned --config and --session flags on every command. Other hosts can be used concurrently; opening one does not switch these commands.",
        notes
      ],
      "\n"
    )
  end

  defp shell_word(word) do
    if word =~ ~r/^[a-zA-Z0-9_.\/:-]+$/,
      do: word,
      else: "'" <> String.replace(word, "'", ~S('"'"')) <> "'"
  end

  # Width and height from the IHDR chunk; anything else reports 0×0.
  defp png_size(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::32, "IHDR", w::32, h::32, _::binary>>),
    do: {w, h}

  defp png_size(_), do: {0, 0}

  # A project's own setting wins over the environment's, as in `resolveProjectSettings`.
  defp allowed?(thread_id) do
    settings = T3.Settings.settings()

    override =
      with {"thread", %{"projectId" => project}} <- thread_row(thread_id),
           %{"enableAgentDeviceAccess" => value} when is_boolean(value) <-
             get_in(settings, ["projectSettingsOverrides", project]) do
        value
      else
        _ -> nil
      end

    if is_boolean(override), do: override, else: settings["enableAgentDeviceAccess"] == true
  end

  defp thread_row(thread_id) do
    T3.Shell.row(node(), thread_id)
  rescue
    ArgumentError -> nil
  end

  defp unavailable(reason), do: {:error, "DeviceToolUnavailableError", reason}
end
