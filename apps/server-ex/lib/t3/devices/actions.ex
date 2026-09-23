defmodule T3.Devices.Actions do
  @moduledoc """
  Device settings and one-shot actions (`device.detail`, `device.action`), run
  against the host's toolchain the way the Node server does: `xcrun simctl` and the
  helpers serve-sim bundles for iOS, `adb` for Android. Nothing goes through
  serve-sim's shell channel, which would hand any session command execution.

  Each platform supports only some actions; the others fail as
  `DeviceActionUnavailableError` and the panel hides them.
  """

  alias T3.Devices

  @ios_actions ~w(setAppearance setTextSize setToggle setLiquidGlass setColorFilter setLocation
                  clearLocation setPermission openUrl launchApp terminateApp sendPush)
  @android_actions ~w(setAppearance setTextSize setToggle setOrientation setLocation clearLocation
                      setPermission openUrl launchApp terminateApp)
  @ios_toggles ~w(reduceMotion increaseContrast reduceTransparency showBorders voiceOver)
  @android_toggles ~w(reduceMotion networkEnabled)

  # The four shared text sizes as iOS content-size categories and Android font scales.
  @ios_text_sizes %{
    "small" => "small",
    "default" => "large",
    "large" => "extra-extra-large",
    "extra-large" => "accessibility-large"
  }
  @android_text_sizes %{
    "small" => "0.85",
    "default" => "1.0",
    "large" => "1.15",
    "extra-large" => "1.3"
  }
  @ios_toggle_options %{
    "reduceMotion" => "reduce-motion",
    "increaseContrast" => "increase-contrast",
    "reduceTransparency" => "reduce-transparency",
    "showBorders" => "show-borders",
    "voiceOver" => "voiceover"
  }
  @ios_tcc_services Map.new(
                      ~w(camera microphone photos contacts calendar reminders motion media-library faceid),
                      &{&1, &1}
                    )
  @android_permissions %{
    "camera" => ["android.permission.CAMERA"],
    "microphone" => ["android.permission.RECORD_AUDIO"],
    "photos" => [
      "android.permission.READ_MEDIA_IMAGES",
      "android.permission.READ_EXTERNAL_STORAGE"
    ],
    "contacts" => ["android.permission.READ_CONTACTS", "android.permission.WRITE_CONTACTS"],
    "calendar" => ["android.permission.READ_CALENDAR", "android.permission.WRITE_CALENDAR"],
    "location" => [
      "android.permission.ACCESS_FINE_LOCATION",
      "android.permission.ACCESS_COARSE_LOCATION"
    ],
    "notifications" => ["android.permission.POST_NOTIFICATIONS"],
    "motion" => ["android.permission.ACTIVITY_RECOGNITION"]
  }
  # The emulator's gravity vector for each orientation, and the window-manager
  # rotation a physical device is locked to instead.
  @android_gravity %{
    "portrait" => "0:9.81:0",
    "landscape_left" => "9.81:0:0",
    "portrait_upside_down" => "0:-9.81:0",
    "landscape_right" => "-9.81:0:0"
  }
  @android_rotation %{
    "portrait" => "0",
    "landscape_left" => "1",
    "portrait_upside_down" => "2",
    "landscape_right" => "3"
  }
  @color_filters ~w(none grayscale red-green green-red blue-yellow)

  @doc "Runs one `DeviceActionInput` on a device of `platform`: `:ok` or `{:error, DeviceError}`."
  def run(hub, platform, %{"type" => type} = input) do
    actions = if platform == "ios", do: @ios_actions, else: @android_actions
    toggles = if platform == "ios", do: @ios_toggles, else: @android_toggles

    cond do
      type not in actions ->
        unavailable(type, platform, "unsupported")

      type == "setToggle" and input["setting"] not in toggles ->
        unavailable(type, platform, "unsupported")

      platform == "ios" ->
        ios(hub, input["deviceId"], input)

      true ->
        android(input["deviceId"], input)
    end
  end

  # --- iOS ---------------------------------------------------------------------------

  defp ios(_hub, udid, %{"type" => "setAppearance", "value" => value}),
    do: simctl(udid, ["ui", "appearance", value], "appearance")

  defp ios(_hub, udid, %{"type" => "setTextSize", "value" => value}),
    do: simctl(udid, ["ui", "content_size", @ios_text_sizes[value]], "text size")

  defp ios(_hub, udid, %{"type" => "setToggle", "setting" => "increaseContrast", "value" => on}),
    do:
      simctl(
        udid,
        ["ui", "increase_contrast", if(on, do: "enabled", else: "disabled")],
        "increase contrast"
      )

  defp ios(hub, udid, %{"type" => "setToggle", "setting" => setting, "value" => on}),
    do: ax(hub, udid, ["set", @ios_toggle_options[setting], if(on, do: "on", else: "off")])

  defp ios(hub, udid, %{"type" => "setLiquidGlass", "value" => value}),
    do: ax(hub, udid, ["set", "liquid-glass", value])

  defp ios(hub, udid, %{"type" => "setColorFilter", "value" => value}),
    do: ax(hub, udid, ["set", "color-filter", value])

  defp ios(_hub, udid, %{"type" => "setLocation", "latitude" => lat, "longitude" => lon}),
    do: simctl(udid, ["location", "set", "#{lat},#{lon}"], "location")

  defp ios(_hub, udid, %{"type" => "clearLocation"}),
    do: simctl(udid, ["location", "clear"], "location")

  # simctl has no notification permission verb; serve-sim's CLI edits the plist.
  defp ios(hub, udid, %{"type" => "setPermission", "permission" => "notifications"} = input) do
    case hub["helpers"]["serveSimCli"] do
      nil ->
        unavailable("permission", "ios", "helper_missing")

      cli ->
        Devices.run(hub["node"], [
          cli,
          "permissions",
          input["decision"],
          input["permission"],
          input["appId"],
          "-d",
          udid
        ])
        |> ok("permission")
    end
  end

  defp ios(_hub, udid, %{"type" => "setPermission", "permission" => permission} = input) do
    case if(permission == "location", do: "location", else: @ios_tcc_services[permission]) do
      nil ->
        unavailable("permission", "ios", "unsupported")

      service ->
        simctl(udid, ["privacy", input["decision"], service, input["appId"]], "permission")
    end
  end

  defp ios(_hub, udid, %{"type" => "openUrl", "url" => url}),
    do: simctl(udid, ["openurl", url], "open url")

  defp ios(_hub, udid, %{"type" => "launchApp", "appId" => app}),
    do: simctl(udid, ["launch", app], "launch")

  defp ios(_hub, udid, %{"type" => "terminateApp", "appId" => app}),
    do: simctl(udid, ["terminate", app], "terminate")

  defp ios(_hub, udid, %{"type" => "sendPush", "appId" => app, "payload" => payload}) do
    payload = if is_binary(payload), do: %{"aps" => %{"alert" => payload}}, else: payload

    Devices.run("xcrun", ["simctl", "push", udid, app, "-"], input: JSON.encode!(payload))
    |> ok("push")
  end

  defp ios(_hub, _udid, %{"type" => type}), do: unavailable(type, "ios", "unsupported")

  defp simctl(udid, [verb | rest], operation),
    do: Devices.run("xcrun", ["simctl", verb, udid | rest]) |> ok(operation)

  defp ax(hub, udid, args) do
    case hub["helpers"]["serveSimAxSettings"] do
      nil ->
        unavailable("accessibility", "ios", "helper_missing")

      helper ->
        Devices.run("xcrun", ["simctl", "spawn", udid, helper | args]) |> ok("accessibility")
    end
  end

  # --- Android -------------------------------------------------------------------------

  defp android(serial, %{"type" => "setAppearance", "value" => value}),
    do:
      shell(
        serial,
        ["cmd", "uimode", "night", if(value == "dark", do: "yes", else: "no")],
        "appearance"
      )

  defp android(serial, %{"type" => "setTextSize", "value" => value}),
    do:
      shell(
        serial,
        ["settings", "put", "system", "font_scale", @android_text_sizes[value]],
        "text size"
      )

  defp android(serial, %{"type" => "setToggle", "setting" => "networkEnabled", "value" => on}) do
    state = if on, do: "enable", else: "disable"

    with :ok <- shell(serial, ["svc", "wifi", state], "network"),
         do: shell(serial, ["svc", "data", state], "network")
  end

  defp android(serial, %{"type" => "setToggle", "setting" => "reduceMotion", "value" => on}) do
    scale = if on, do: "0", else: "1"

    Enum.reduce_while(
      ~w(animator_duration_scale transition_animation_scale window_animation_scale),
      :ok,
      fn key, :ok ->
        case shell(serial, ["settings", "put", "global", key, scale], "reduce motion") do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

  # `user-rotation lock` only rotates window content on recent images, so an
  # emulator is tilted through its accelerometer instead; a physical device is locked.
  defp android("emulator-" <> _ = serial, %{"type" => "setOrientation", "value" => value}) do
    with :ok <-
           shell(
             serial,
             ["settings", "put", "system", "accelerometer_rotation", "1"],
             "orientation"
           ),
         :ok <- shell(serial, ["cmd", "window", "user-rotation", "free"], "orientation") do
      adb(
        serial,
        ["emu", "sensor", "set", "acceleration", @android_gravity[value]],
        "orientation"
      )
    end
  end

  defp android(serial, %{"type" => "setOrientation", "value" => value}),
    do:
      shell(
        serial,
        ["cmd", "window", "user-rotation", "lock", @android_rotation[value]],
        "orientation"
      )

  defp android(serial, %{"type" => "setLocation", "latitude" => lat, "longitude" => lon}),
    do: adb(serial, ["emu", "geo", "fix", to_string(lon), to_string(lat)], "location")

  # The emulator cannot clear a fix; leaving it is the closest behavior.
  defp android(_serial, %{"type" => "clearLocation"}), do: :ok

  defp android(serial, %{"type" => "setPermission", "permission" => permission} = input) do
    case @android_permissions[permission] do
      nil ->
        unavailable("permission", "android", "unsupported")

      permissions ->
        verb = if input["decision"] == "grant", do: "grant", else: "revoke"
        # Not every app declares every permission of a group.
        for name <- permissions,
            do: shell(serial, ["pm", verb, input["appId"], name], "permission")

        :ok
    end
  end

  defp android(serial, %{"type" => "openUrl", "url" => url}),
    do: shell(serial, ["am", "start", "-a", "android.intent.action.VIEW", "-d", url], "open url")

  defp android(serial, %{"type" => "launchApp", "appId" => app}),
    do:
      shell(
        serial,
        ["monkey", "-p", app, "-c", "android.intent.category.LAUNCHER", "1"],
        "launch"
      )

  defp android(serial, %{"type" => "terminateApp", "appId" => app}),
    do: shell(serial, ["am", "force-stop", app], "terminate")

  defp android(_serial, %{"type" => type}), do: unavailable(type, "android", "unsupported")

  defp adb(serial, args, operation),
    do: Devices.run("adb", ["-s", serial | args]) |> ok(operation)

  defp shell(serial, args, operation), do: adb(serial, ["shell" | args], operation)

  # --- reading -------------------------------------------------------------------------

  @doc "A device's current settings and foreground app; what cannot be read is left out."
  def read(hub, "ios", udid) do
    [appearance, content_size, contrast, ax] =
      [
        fn -> ui_value(udid, "appearance") end,
        fn -> ui_value(udid, "content_size") end,
        fn -> ui_value(udid, "increase_contrast") end,
        fn -> ax_status(hub, udid) end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(30_000)

    on_off = fn
      "on" -> true
      "off" -> false
      _ -> nil
    end

    ax = ax || %{}

    settings =
      %{
        "appearance" => if(appearance in ["light", "dark"], do: appearance),
        "textSize" => content_size && text_size_from_ios(content_size),
        "increaseContrast" => contrast && contrast == "enabled",
        "reduceMotion" => on_off.(ax["reduce-motion"]),
        "reduceTransparency" => on_off.(ax["reduce-transparency"]),
        "showBorders" => on_off.(ax["show-borders"]),
        "voiceOver" => on_off.(ax["voiceover"]),
        "liquidGlass" => if(ax["liquid-glass"] in ["clear", "tinted"], do: ax["liquid-glass"]),
        "colorFilter" => if(ax["color-filter"] in @color_filters, do: ax["color-filter"])
      }
      |> compact()

    %{"settings" => settings, "foregroundApp" => nil}
  end

  def read(_hub, "android", serial) do
    [night, font_scale, animator, wifi, focus] =
      [
        ["cmd", "uimode", "night"],
        ["settings", "get", "system", "font_scale"],
        ["settings", "get", "global", "animator_duration_scale"],
        ["settings", "get", "global", "wifi_on"],
        # `dumpsys window windows` stopped printing the focus on API 36.
        ["dumpsys", "window"]
      ]
      |> Enum.map(fn args -> Task.async(fn -> quiet_shell(serial, args) end) end)
      |> Task.await_many(30_000)

    focused =
      focus && Regex.run(~r/m(?:CurrentFocus|FocusedApp)=\w+\{[^ ]+ u\d+ ([^\/ ]+)\//, focus)

    settings =
      %{
        "appearance" =>
          cond do
            night && String.contains?(night, "yes") -> "dark"
            night && String.contains?(night, "no") -> "light"
            true -> nil
          end,
        "textSize" => (scale = number(font_scale)) && text_size_from_android(scale),
        "reduceMotion" => (scale = number(animator)) && scale == 0,
        "networkEnabled" => if(wifi in ["0", "1"], do: wifi == "1")
      }
      |> compact()

    %{
      "settings" => settings,
      "foregroundApp" => if(focused, do: %{"id" => Enum.at(focused, 1)})
    }
  end

  defp ui_value(udid, option) do
    case Devices.run("xcrun", ["simctl", "ui", udid, option]) do
      %{code: 0, stdout: out} -> out |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp ax_status(hub, udid) do
    with helper when is_binary(helper) <- hub["helpers"]["serveSimAxSettings"],
         %{code: 0, stdout: out} <-
           Devices.run("xcrun", ["simctl", "spawn", udid, helper, "status"]),
         {:ok, %{} = status} <- JSON.decode(out) do
      status
    else
      _ -> nil
    end
  end

  defp quiet_shell(serial, args) do
    case Devices.run("adb", ["-s", serial, "shell" | args]) do
      %{code: 0, stdout: out} -> String.trim(out)
      _ -> nil
    end
  end

  defp number(text) when is_binary(text) do
    case Float.parse(text) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp number(_), do: nil

  defp text_size_from_ios(category) do
    case Enum.find(@ios_text_sizes, fn {_, value} -> value == category end) do
      {size, _} ->
        size

      nil ->
        cond do
          String.starts_with?(category, "accessibility") -> "extra-large"
          String.contains?(category, "extra") -> "large"
          category in ["extra-small", "small", "medium"] -> "small"
          true -> "default"
        end
    end
  end

  defp text_size_from_android(scale) do
    cond do
      scale <= 0.9 -> "small"
      scale >= 1.25 -> "extra-large"
      scale >= 1.1 -> "large"
      true -> "default"
    end
  end

  defp compact(map), do: for({key, value} <- map, value != nil, into: %{}, do: {key, value})

  # --- errors --------------------------------------------------------------------------

  defp ok(%{code: 0}, _operation), do: :ok

  defp ok(%{code: code} = result, operation),
    do: {:error, Devices.operation_error(operation, "command_failed", result, code)}

  defp unavailable(operation, platform, reason) do
    message =
      if reason == "helper_missing",
        do:
          "Device #{operation} requires a helper missing from this install. Set up device support again.",
        else: "Device #{operation} is not supported on #{platform}."

    {:error,
     %{
       "_tag" => "DeviceActionUnavailableError",
       "operation" => operation,
       "platform" => platform,
       "reason" => reason,
       "message" => message
     }}
  end
end
