defmodule T3.Devices do
  @moduledoc """
  iOS Simulators and Android Emulators on this node's machine (`device.*` RPCs and
  the `devices` shape), as on the Node server.

  Discovery, boot and streaming go through expo-device-hub, which the node installs
  on first use under `<home>/tools` and runs with the system Node on a loopback
  port; clients reach it through `T3.Devices.Proxy`. Agents drive devices with the
  agent-device CLI (`T3.Mcp.Devices`), whose daemon starts once the user grants
  agents access. Nothing is installed or started until device support is enabled.

  The node keeps which thread has which device open, so the Device panel and the
  agent tools agree. Watchers get `{:t3_devices, node, DeviceServiceState}` on every
  change. Every machine is its own host: SSH hosts configured for the Node server
  are reported unavailable, since in a cluster a remote machine runs its own node.
  Long work (installs, boots, hub requests) runs in the caller; the server only
  keeps the state and starts the helper processes.
  """

  use GenServer

  require Logger

  alias T3.Devices.Actions

  @local "local"
  @tools %{
    "hub" => %{name: "expo-device-hub", version: "0.10.1", entry: ~w(dist server cli.mjs)},
    "agent" => %{name: "agent-device", version: "0.21.12", entry: ~w(bin agent-device.mjs)}
  }
  @hub_ready_timeout 30_000
  @daemon_ready_timeout 30_000
  @boot_timeout 180_000
  @screenshot_timeout 20_000
  @install_timeout 600_000
  @agent_unavailable "Agent device access requires enabled device support, agent access, and an available simulator platform on this host."

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Adds a watcher; returns the current `DeviceServiceState`."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "The running hub's loopback origin, or nil. Never starts it."
  def hub_origin, do: GenServer.call(__MODULE__, :hub_origin)

  @doc "The path clients prefix to hub routes: the proxy on any node forwards it here."
  def hub_base_path,
    do: "/api/device-hub/nodes/" <> URI.encode_www_form(Atom.to_string(node()))

  # --- RPCs ------------------------------------------------------------------------

  @doc """
  `device.list`: refreshes devices once support is enabled. `updateTool` installs
  the pinned tool, `inspectOnly` only rereads what is installed, and `retryHostId`
  starts one host again, agent tools included when agents have access.
  """
  def list(%{"updateTool" => tool}) when is_map_key(@tools, tool) do
    case ensure_tool(tool, fn _, _ -> :ok end) do
      {:ok, _} -> inspect_hosts()
      {:error, error} -> {:error, operation_error("update device tool", "command_failed", error)}
    end
  end

  def list(%{"inspectOnly" => true}), do: inspect_hosts()

  # An SSH host stays unavailable however often it is retried.
  def list(%{"retryHostId" => host}) when is_binary(host) do
    case local_host(host) do
      :ok ->
        agent_if_supported()
        refresh_all()

      {:error, %{"reason" => "Unknown host."}} = error ->
        error

      {:error, _} ->
        {:ok, state()}
    end
  end

  def list(_input), do: refresh_all()

  @doc "`device.configure`: stores the device settings, then lists."
  def configure(input) do
    changes =
      %{
        "enableDeviceSupport" => input["enabled"],
        "enableAgentDeviceAccess" => input["agentAccessEnabled"],
        "deviceOnboardingCompleted" => input["onboardingCompleted"]
      }
      |> Map.reject(fn {_, value} -> not is_boolean(value) end)

    settings = update_settings(changes)
    GenServer.call(__MODULE__, {:settings, settings}, 30_000)

    case if(input["agentAccessEnabled"] == true, do: agent_if_supported()) do
      {:error, _} = error -> error
      _ -> list(%{})
    end
  end

  @doc "`device.testHost`: SSH hosts are not served by nodes."
  def test_host(%{"id" => id} = config),
    do: host_unavailable(id, ssh_reason(config))

  @doc "`device.open`: boots the device if asked and records it as open in the thread."
  def open(%{"threadId" => thread, "deviceId" => id, "platform" => platform} = input) do
    with :ok <- local_host(input["hostId"]),
         :ok <- platform_available(platform),
         {:ok, hub} <- ready(),
         {:ok, view} <- refresh(hub),
         {:ok, device} <- find(view, id),
         {:ok, device} <- bring_up(hub, device, thread, input["boot"] != false) do
      session = %{
        "threadId" => thread,
        "hostId" => @local,
        "deviceId" => device["id"],
        "platform" => device["platform"],
        "openedAt" => now()
      }

      GenServer.call(__MODULE__, {:open, session})
    end
  end

  @doc "`device.close`: closes the thread's sessions (one device, or all), optionally powering off."
  def close(%{"threadId" => _} = input) do
    closing = GenServer.call(__MODULE__, {:close, input})

    if input["shutdown"] == true do
      Enum.reduce_while(closing, {:ok, nil}, fn session, _ ->
        case shutdown_device(session["deviceId"], session["platform"]) do
          :ok -> {:cont, {:ok, nil}}
          error -> {:halt, error}
        end
      end)
    else
      {:ok, nil}
    end
  end

  @doc "`device.shutdown`: powers a device off, closing it in every thread."
  def shutdown(%{"deviceId" => id, "platform" => platform} = input) do
    with :ok <- local_host(input["hostId"]),
         :ok <- shutdown_device(id, platform),
         do: {:ok, nil}
  end

  @doc "`device.detail`: a device's settings and foreground app."
  def detail(input) do
    with {:ok, hub, device} <- resolve(input), do: {:ok, read_detail(hub, device)}
  end

  @doc "`device.action`: runs one action, then reads the device again."
  def action(input) do
    with {:ok, hub, device} <- resolve(input),
         :ok <- Actions.run(hub, device["platform"], Map.put(input, "deviceId", device["id"])),
         do: {:ok, read_detail(hub, device)}
  end

  @doc "A PNG of a device's screen: `{:ok, DeviceSummary, png}`."
  def screenshot(input) do
    with {:ok, hub, device} <- resolve(input) do
      path =
        "#{vendor(device["platform"])}/api/screenshot?device=#{URI.encode_www_form(device["id"])}"

      case http(:post, hub["origin"] <> path, nil, @screenshot_timeout) do
        {:ok, 200, png} -> {:ok, device, png}
        other -> {:error, operation_error("screenshot", "request_failed", other)}
      end
    end
  end

  @doc """
  Readies agent-device for a thread's device: `{:ok, target_args, command}`, where
  `command` is the launcher that runs the pinned CLI and `target_args` pin every
  command to the thread's daemon session.
  """
  def agent_target(thread, host, device_id) do
    with :ok <- local_host(host),
         {:ok, agent} <- agent_if_supported(),
         {:ok, config} <- write_agent_config(agent),
         {:ok, command} <- write_shim(agent) do
      {:ok, ["--config", config, "--session", session_name(thread, host || @local, device_id)],
       command}
    else
      :unsupported -> host_unavailable(@local, @agent_unavailable)
      error -> error
    end
  end

  # --- discovery and lifecycle ---------------------------------------------------------

  defp refresh_all do
    if settings().enabled and supported?() do
      with {:ok, hub} <- ready(), {:ok, _} <- refresh(hub) do
        :ok
      else
        {:error, error} -> GenServer.cast(__MODULE__, {:status, "failed", reason(error)})
      end
    end

    {:ok, state()}
  end

  defp inspect_hosts, do: {:ok, GenServer.call(__MODULE__, :refresh_hosts)}

  # The hub normalizes both platforms; AVDs that are not running come from the SDK.
  defp refresh(hub) do
    with {:ok, list} <- hub_json(hub, :get, "/api/devices", nil, "list"),
         {:ok, avds} <- avds() do
      devices = Enum.map((list["simulators"] || []) ++ (list["emulators"] || []), &summary/1)

      devices =
        devices ++
          for name <- avds,
              not Enum.any?(devices, &(&1["platform"] == "android" and &1["name"] == name)),
              do: summary(%{"id" => name, "name" => name, "platform" => "android"})

      detail =
        case list["errors"] do
          [_ | _] = errors -> Enum.map_join(errors, "\n", & &1["message"])
          _ -> nil
        end

      {:ok, GenServer.call(__MODULE__, {:devices, devices, detail})}
    end
  end

  defp summary(device),
    do: %{
      "hostId" => @local,
      "id" => device["id"],
      "platform" => device["platform"],
      "name" => device["name"],
      "version" => device["version"] || "Android",
      "booted" => device["booted"] == true,
      "physical" => device["physical"] == true
    }

  defp avds do
    if platform_reason("android") do
      {:ok, []}
    else
      case run("emulator", ["-list-avds"]) do
        %{code: 0, stdout: out} ->
          {:ok,
           out |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

        result ->
          {:error, operation_error("list", "command_failed", result, result.code)}
      end
    end
  end

  # Android AVDs change id when they boot (name to emulator serial), so the id the
  # hub answers with is the one to look for afterwards.
  defp bring_up(hub, %{"booted" => false} = device, thread, true) do
    GenServer.cast(__MODULE__, {:booting, Map.put(device, "threadId", thread)})
    result = boot(hub, device)
    GenServer.cast(__MODULE__, {:booted, device})

    with {:ok, id} <- result, {:ok, view} <- refresh(hub) do
      with {:error, _} <- find(view, id), do: find(view, device["id"])
    end
  end

  # A simulator booted outside T3 has no stream helper attached yet.
  defp bring_up(hub, %{"booted" => true, "platform" => "ios"} = device, _thread, _boot) do
    with :ok <- attach_ios(hub, device["id"], "attach stream"), do: {:ok, device}
  end

  defp bring_up(_hub, device, _thread, _boot), do: {:ok, device}

  defp boot(hub, device) do
    body = Map.take(device, ~w(platform id name))

    case hub_json(hub, :post, "/api/devices/boot", body, "boot", @boot_timeout) do
      {:ok, %{"ok" => true} = result} ->
        id = result["serial"] || result["id"] || device["id"]

        if device["platform"] == "ios",
          do: with(:ok <- attach_ios(hub, device["id"], "attach stream"), do: {:ok, id}),
          else: {:ok, id}

      {:ok, result} ->
        {:error, boot_error(device["id"], result)}

      error ->
        error
    end
  end

  # The grid start boots serve-sim's helper for the simulator; it is idempotent.
  defp attach_ios(hub, udid, operation) do
    case hub_json(
           hub,
           :post,
           "/vendor/serve-sim/grid/api/start",
           %{"udid" => udid},
           operation,
           @boot_timeout
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp shutdown_device(id, platform) do
    with {:ok, hub} <- ready(),
         :ok <- post_shutdown(hub, id, platform) do
      GenServer.call(__MODULE__, {:powered_off, id})
      # Discovery can stall while an emulator saves its snapshot; the shutdown stands.
      refresh(hub)
      :ok
    end
  end

  # serve-sim's own shutdown also closes its capture session, but fails for a
  # simulator that is already off; that failure counts only for a running one.
  defp post_shutdown(hub, udid, "ios") do
    with {:error, _} = error <-
           shutdown_request(hub, "/vendor/serve-sim/grid/api/shutdown", %{"udid" => udid}) do
      case hub_json(hub, :get, "/api/devices", nil, "list") do
        {:ok, list} ->
          off = Enum.find(list["simulators"] || [], &(&1["id"] == udid))
          if off && off["booted"] == false, do: :ok, else: error

        _ ->
          error
      end
    end
  end

  defp post_shutdown(hub, id, platform),
    do: shutdown_request(hub, "/api/devices/shutdown", %{"platform" => platform, "id" => id})

  defp shutdown_request(hub, path, body) do
    case hub_json(hub, :post, path, body, "shutdown") do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, result} -> {:error, operation_error("shutdown", "hub_rejected", result)}
      error -> error
    end
  end

  defp resolve(input) do
    with :ok <- local_host(input["hostId"]),
         {:ok, hub} <- ready(),
         {:ok, device} <-
           with(
             {:error, _} <- find(state(), input["deviceId"]),
             do: with({:ok, view} <- refresh(hub), do: find(view, input["deviceId"]))
           ),
         do: {:ok, hub, device}
  end

  defp find(view, id) do
    case Enum.find(view["devices"], &(&1["hostId"] == @local and &1["id"] == id)) do
      nil ->
        {:error,
         %{
           "_tag" => "DeviceNotFoundError",
           "hostId" => @local,
           "deviceId" => id,
           "message" => "Device #{id} was not found on host #{@local}."
         }}

      device ->
        {:ok, device}
    end
  end

  defp read_detail(hub, device) do
    read = Actions.read(hub, device["platform"], device["id"])

    Map.merge(read, %{"hostId" => @local, "deviceId" => device["id"], "readAt" => now()})
  end

  defp ready, do: GenServer.call(__MODULE__, :ensure_hub, :infinity)

  defp agent_ready do
    with {:ok, _hub} <- ready(), do: GenServer.call(__MODULE__, :ensure_agent, :infinity)
  end

  # Agent tools start only where some simulator platform could run.
  defp agent_if_supported do
    settings = settings()

    if settings.enabled and settings.agent and supported?(),
      do: with({:ok, agent} <- agent_ready(), do: {:ok, agent}),
      else: :unsupported
  end

  defp local_host(nil), do: :ok
  defp local_host(@local), do: :ok

  defp local_host(host) do
    case Enum.find(settings().ssh, &(&1["id"] == host)) do
      nil -> host_unavailable(host, "Unknown host.")
      config -> host_unavailable(host, ssh_reason(config))
    end
  end

  defp ssh_reason(config) do
    "SSH device hosts are not served by T3 nodes. Run T3 on #{config["target"] || "that machine"} " <>
      "and add it to this cluster as a node; its simulators and emulators then appear under its own environment."
  end

  defp platform_available(platform) do
    case platform_reason(platform) do
      nil ->
        :ok

      reason ->
        {:error,
         %{
           "_tag" => "DevicePlatformUnavailableError",
           "hostId" => @local,
           "platform" => platform,
           "reason" => reason,
           "message" => "#{platform} devices are unavailable on host #{@local}: #{reason}"
         }}
    end
  end

  defp supported?, do: platform_reason("ios") == nil or platform_reason("android") == nil

  @doc false
  def platform_reason("ios") do
    cond do
      :os.type() != {:unix, :darwin} -> "iOS Simulators need macOS with Xcode."
      System.find_executable("xcrun") == nil -> "Xcode command line tools were not found."
      true -> nil
    end
  end

  def platform_reason("android") do
    case android_sdk() do
      %{root: nil} ->
        "Android SDK was not found. Install it with Android Studio or set ANDROID_HOME to your SDK directory."

      %{root: root, adb: false} ->
        "Android SDK Platform-Tools are missing from #{root}. Install them in Android Studio's SDK Manager."

      %{root: root, emulator: false} ->
        "Android Emulator is missing from #{root}. Install it in Android Studio's SDK Manager."

      %{root: root, avdmanager: false} ->
        "Android SDK Command-line Tools (latest) are missing from #{root}. Install them in Android Studio's SDK Manager."

      _ ->
        nil
    end
  end

  defp android_sdk do
    home = System.user_home() || ""

    explicit =
      Enum.find_value(["ANDROID_HOME", "ANDROID_SDK_ROOT"], fn name ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> String.trim(value)
          _ -> nil
        end
      end)

    on_path =
      case System.find_executable("adb") do
        nil -> []
        adb -> [adb |> resolve_link() |> Path.dirname() |> Path.dirname()]
      end

    candidates =
      if explicit,
        do: [explicit],
        else:
          [Path.join([home, "Library", "Android", "sdk"]), Path.join([home, "Android", "Sdk"])] ++
            on_path

    Enum.find_value(candidates, %{root: nil}, fn root ->
      adb = File.exists?(Path.join([root, "platform-tools", "adb"]))
      emulator = File.exists?(Path.join([root, "emulator", "emulator"]))

      if explicit || adb || emulator do
        avdmanager =
          File.exists?(Path.join([root, "cmdline-tools", "latest", "bin", "avdmanager"]))

        %{root: root, adb: adb, emulator: emulator, avdmanager: avdmanager}
      end
    end)
  end

  defp resolve_link(path) do
    case File.read_link(path) do
      {:ok, target} -> resolve_link(Path.expand(target, Path.dirname(path)))
      _ -> path
    end
  end

  # --- host commands -----------------------------------------------------------------

  @doc """
  Runs a host command (`xcrun`, `adb`, `emulator`, or a helper) with the Android SDK
  on its PATH: `%{code, stdout, stderr}`, code 127 when it cannot start. Options:
  `:input` (stdin) and `:timeout` (ms, default 20 s).
  """
  def run(command, args, opts \\ []) do
    case executable(command) do
      nil ->
        %{code: 127, stdout: "", stderr: "#{command} was not found"}

      path ->
        exile_opts =
          [env: host_env(), stderr: :consume, ignore_epipe: true] ++
            if(input = opts[:input], do: [input: [input]], else: [])

        task =
          Task.async(fn ->
            try do
              Exile.stream([path | args], exile_opts)
              |> Enum.reduce(%{code: 1, stdout: [], stderr: []}, fn
                {:stdout, data}, acc -> %{acc | stdout: [acc.stdout, data]}
                {:stderr, data}, acc -> %{acc | stderr: [acc.stderr, data]}
                {:exit, {:status, code}}, acc -> %{acc | code: code}
                _, acc -> acc
              end)
              |> then(
                &%{
                  &1
                  | stdout: IO.iodata_to_binary(&1.stdout),
                    stderr: IO.iodata_to_binary(&1.stderr)
                }
              )
            rescue
              error -> %{code: 127, stdout: "", stderr: Exception.message(error)}
            end
          end)

        case Task.yield(task, opts[:timeout] || 20_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> %{code: 124, stdout: "", stderr: "#{command} timed out"}
        end
    end
  end

  defp executable(command) do
    sdk = android_sdk().root

    cond do
      Path.type(command) == :absolute -> command
      sdk && command == "adb" -> Path.join([sdk, "platform-tools", "adb"])
      sdk && command == "emulator" -> Path.join([sdk, "emulator", "emulator"])
      true -> System.find_executable(command)
    end
  end

  defp host_env do
    case android_sdk().root do
      nil ->
        []

      root ->
        path = [
          Path.join(root, "platform-tools"),
          Path.join(root, "emulator"),
          System.get_env("PATH", "")
        ]

        [{"ANDROID_HOME", root}, {"PATH", Enum.join(path, ":")}]
    end
  end

  # --- hub HTTP ------------------------------------------------------------------------

  defp hub_json(hub, method, path, body, operation, timeout \\ 15_000) do
    with {:ok, 200, response} <-
           http(method, hub["origin"] <> path, body && JSON.encode!(body), timeout),
         {:ok, decoded} <- JSON.decode(response) do
      {:ok, decoded}
    else
      other -> {:error, operation_error(operation, "request_failed", other)}
    end
  end

  defp http(method, url, body, timeout) do
    request =
      if method == :get,
        do: {String.to_charlist(url), []},
        else: {String.to_charlist(url), [], ~c"application/json", body || ""}

    case :httpc.request(method, request, [timeout: timeout, connect_timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp vendor("ios"), do: "/vendor/serve-sim"
  defp vendor(_), do: "/vendor/serve-emu"

  # --- tools -------------------------------------------------------------------------

  defp tool_paths(tool, version \\ nil) do
    spec = @tools[tool]
    dir = Path.join([home(), "tools", spec.name, version || spec.version])

    %{
      dir: dir,
      entry: Path.join([dir, "node_modules", spec.name | spec.entry]),
      sentinel: Path.join(dir, ".install-complete")
    }
  end

  defp installed?(tool, version \\ nil) do
    paths = tool_paths(tool, version)

    File.exists?(paths.entry) and
      match?({:ok, _}, File.read(paths.sentinel)) and
      String.trim(File.read!(paths.sentinel)) == (version || @tools[tool].version)
  end

  # npm writes files before it finishes, so the install is staged and published by
  # rename only after npm exits 0; the sentinel marks a complete tree.
  defp ensure_tool(tool, on_phase) do
    paths = tool_paths(tool)
    spec = @tools[tool]

    if installed?(tool) do
      {:ok, paths}
    else
      on_phase.("installing", install_message(tool))
      parent = Path.dirname(paths.dir)
      staging = Path.join(parent, ".staging-" <> Base.url_encode64(:crypto.strong_rand_bytes(6)))
      File.rm_rf(paths.dir)
      File.mkdir_p!(staging)

      try do
        npm = System.find_executable("npm")

        result =
          npm &&
            run(
              npm,
              [
                "install",
                "--prefix",
                staging,
                "--no-fund",
                "--no-audit",
                "#{spec.name}@#{spec.version}"
              ], timeout: @install_timeout)

        staged = Path.join([staging, "node_modules", spec.name | spec.entry])

        cond do
          npm == nil ->
            {:error, "npm was not found; install Node.js with npm to add device support."}

          result.code != 0 ->
            {:error,
             "npm install #{spec.name} failed: #{String.slice(result.stderr, -1000, 1000)}"}

          not File.exists?(staged) ->
            {:error, "#{spec.name} installed without its entry point"}

          true ->
            File.write!(Path.join(staging, ".install-complete"), spec.version <> "\n")

            case File.rename(staging, paths.dir) do
              :ok ->
                {:ok, paths}

              _ ->
                if installed?(tool),
                  do: {:ok, paths},
                  else: {:error, "could not publish #{spec.name}"}
            end
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  defp tool_version(tool, running) do
    spec = @tools[tool]

    installed =
      case File.ls(Path.join([home(), "tools", spec.name])) do
        {:ok, names} ->
          names
          |> Enum.filter(
            &(&1 =~ ~r/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/ and installed?(tool, &1))
          )
          |> Enum.sort()

        _ ->
          []
      end

    %{
      "requiredVersion" => spec.version,
      "installedVersions" => installed,
      "runningVersion" => running
    }
  end

  defp install_message(tool) do
    %{"requiredVersion" => required, "installedVersions" => installed} = tool_version(tool, nil)
    name = if tool == "hub", do: "device hub", else: "agent tools"

    case List.last(installed) do
      nil -> "Installing #{name} #{required}…"
      previous -> "Updating #{name} from #{previous} to #{required}…"
    end
  end

  defp node_executable do
    case System.find_executable("node") do
      nil ->
        host_unavailable(
          @local,
          "Local device support requires Node.js. Install Node.js and make sure node is on PATH, then retry."
        )

      path ->
        {:ok, path}
    end
  end

  # --- jobs (run in tasks the server starts) --------------------------------------------

  defp hub_job do
    phase = fn status, detail -> GenServer.cast(__MODULE__, {:status, status, detail}) end

    with {:ok, node} <- node_executable(),
         {:ok, tool} <- tool_result(ensure_tool("hub", phase), "installing device support") do
      phase.("starting", nil)

      with {:ok, origin} <- GenServer.call(__MODULE__, {:spawn_hub, node, tool.entry}),
           :ok <- await_hub(origin, System.monotonic_time(:millisecond) + @hub_ready_timeout) do
        serve_sim =
          Path.join([tool.dir, "node_modules", "expo-device-hub", "vendor", "serve-sim", "dist"])

        helper = fn path -> if File.exists?(path), do: path end

        {:ok,
         %{
           "origin" => origin,
           "node" => node,
           "helpers" => %{
             "serveSimAxSettings" =>
               helper.(Path.join([serve_sim, "simax", "serve-sim-ax-settings"])),
             "serveSimCli" => helper.(Path.join(serve_sim, "serve-sim.js"))
           }
         }}
      else
        _ -> host_unavailable(@local, "Device support failed while starting the device hub.")
      end
    end
  end

  defp await_hub(origin, deadline) do
    case http(:get, origin <> "/readyz", nil, 1_000) do
      {:ok, 200, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(100)
          await_hub(origin, deadline)
        end
    end
  end

  defp agent_job(node) do
    phase = fn status, detail -> GenServer.cast(__MODULE__, {:status, status, detail}) end

    with {:ok, tool} <- tool_result(ensure_tool("agent", phase), "installing agent tools") do
      phase.("starting", nil)

      case start_daemon(node, tool.entry) do
        {:ok, endpoint} ->
          {:ok, Map.merge(endpoint, %{"entry" => tool.entry, "node" => node})}

        :timeout ->
          host_unavailable(
            @local,
            "Agent tools did not start within #{@daemon_ready_timeout} ms."
          )
      end
    end
  end

  defp tool_result({:ok, tool}, _step), do: {:ok, tool}

  defp tool_result({:error, detail}, step) do
    Logger.warning("device tools: #{detail}")
    host_unavailable(@local, "Device support failed during #{step}.")
  end

  # agent-device has no `daemon start`: the first command in a state directory
  # starts the daemon, whose endpoint lands in daemon.json.
  defp start_daemon(node, entry) do
    file = Path.join(agent_state_dir(), "daemon.json")
    File.mkdir_p!(agent_state_dir())

    with {:ok, text} <- File.read(file),
         {:ok, %{"httpPort" => port, "token" => token}} <- JSON.decode(text),
         {:ok, 200, _} <- http(:get, "http://127.0.0.1:#{port}/health", nil, 2_000) do
      {:ok, %{"baseUrl" => "http://127.0.0.1:#{port}", "token" => token}}
    else
      _ ->
        File.rm(file)

        Exile.stream([node, entry, "devices", "--json"],
          env: daemon_env(),
          stderr: :consume,
          ignore_epipe: true
        )
        |> Stream.run()

        await_daemon(file, System.monotonic_time(:millisecond) + @daemon_ready_timeout)
    end
  rescue
    _ -> :timeout
  end

  defp await_daemon(file, deadline) do
    with {:ok, text} <- File.read(file),
         {:ok, %{"httpPort" => port, "token" => token}} <- JSON.decode(text) do
      {:ok, %{"baseUrl" => "http://127.0.0.1:#{port}", "token" => token}}
    else
      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(100)
          await_daemon(file, deadline)
        end
    end
  end

  defp daemon_env do
    host_env() ++
      [
        {"AGENT_DEVICE_STATE_DIR", agent_state_dir()},
        {"AGENT_DEVICE_DAEMON_SERVER_MODE", "http"},
        # The node owns the daemon's lifetime and stops it explicitly.
        {"AGENT_DEVICE_DAEMON_IDLE_TIMEOUT_MS", "0"},
        {"AGENT_DEVICE_NO_UPDATE_NOTIFIER", "1"},
        {"FORCE_COLOR", "0"},
        {"NO_COLOR", "1"}
      ]
  end

  defp stop_daemon(%{"node" => node, "entry" => entry}) do
    Task.start(fn ->
      run(node, [entry, "daemon", "stop", "--state-dir", agent_state_dir()], timeout: 10_000)
    end)
  end

  defp agent_state_dir, do: Path.join([home(), "device", "agent-device"])

  # One endpoint file per host, so a restarted daemon never retargets other commands.
  defp write_agent_config(agent) do
    file = Path.join([home(), "device", "hosts", key(@local) <> ".json"])

    content =
      JSON.encode!(%{"daemonBaseUrl" => agent["baseUrl"], "daemonAuthToken" => agent["token"]})

    if File.read(file) != {:ok, content} do
      File.mkdir_p!(Path.dirname(file))
      tmp = file <> ".tmp"
      File.write!(tmp, "")
      File.chmod!(tmp, 0o600)
      File.write!(tmp, content)
      File.rename!(tmp, file)
    end

    {:ok, file}
  end

  defp session_name(thread, host, device), do: "t3-" <> key(JSON.encode!([thread, host, device]))

  defp key(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 24)

  # A launcher for the pinned CLI that refuses commands not pinned to a device_open
  # session, so an agent never drives the user's other devices by accident.
  defp write_shim(%{"node" => node, "entry" => entry}) do
    dir = Path.join([home(), "device", "bin"])
    File.mkdir_p!(dir)
    launcher = Path.join(dir, "agent-device-launcher.mjs")

    File.write!(launcher, """
    import { spawn } from "node:child_process";
    const args = process.argv.slice(2);
    const informational = args.length === 1 && ["help", "--help", "-h", "--version", "version"].includes(args[0]);
    const hasValue = flag => { const index = args.indexOf(flag); return index >= 0 && !!args[index + 1] && !args[index + 1].startsWith("--"); };
    if (!informational && !(hasValue("--config") && hasValue("--session"))) {
      console.error("Call device_open first and include its --config and --session flags.");
      process.exit(1);
    }
    const env = { ...process.env };
    delete env.AGENT_DEVICE_DAEMON_BASE_URL;
    delete env.AGENT_DEVICE_DAEMON_AUTH_TOKEN;
    delete env.AGENT_DEVICE_CONFIG;
    const child = spawn(#{JSON.encode!(node)}, [#{JSON.encode!(entry)}, ...args], { stdio: "inherit", env });
    child.on("error", error => { console.error(error.message); process.exitCode = 1; });
    child.on("exit", code => { process.exitCode = code ?? 1; });
    """)

    shim = Path.join(dir, "agent-device")
    quote = fn value -> "'" <> String.replace(value, "'", ~S('"'"')) <> "'" end
    File.write!(shim, "#!/bin/sh\nexec #{quote.(node)} #{quote.(launcher)} \"$@\"\n")
    File.chmod!(shim, 0o755)
    {:ok, shim}
  end

  # --- settings --------------------------------------------------------------------------

  defp settings, do: read_settings(T3.Settings.settings())

  defp read_settings(settings),
    do: %{
      enabled: settings["enableDeviceSupport"] == true,
      agent: settings["enableAgentDeviceAccess"] == true,
      onboarding: settings["deviceOnboardingCompleted"] == true,
      ssh: Enum.filter(settings["deviceHosts"] || [], &is_map/1)
    }

  defp update_settings(changes) do
    {settings, version} = T3.Settings.get()
    next = Map.merge(settings, changes)

    case T3.Settings.put(next, version) do
      {:ok, _} -> next
      {:error, :stale} -> update_settings(changes)
    end
  end

  # --- errors ----------------------------------------------------------------------------

  defp host_unavailable(host, reason),
    do:
      {:error,
       %{
         "_tag" => "DeviceHostUnavailableError",
         "hostId" => host,
         "reason" => reason,
         "message" => "Device host #{host} is unavailable: #{reason}"
       }}

  @doc false
  def operation_error(operation, reason, cause, exit_code \\ nil) do
    explanation =
      case reason do
        "command_failed" ->
          "The device command failed#{if exit_code, do: " (exit code #{exit_code})"}."

        "request_failed" ->
          "Could not communicate with device support. Try refreshing devices."

        "invalid_payload" ->
          "The device request could not be encoded."

        "settings_failed" ->
          "Could not read or save device settings."

        "hub_rejected" ->
          "The device hub could not complete the request."
      end

    %{
      "_tag" => "DeviceOperationError",
      "operation" => operation,
      "reason" => reason,
      "cause" => cause_text(cause),
      "message" => "Device #{operation} failed: #{explanation}"
    }
    |> then(&if(exit_code, do: Map.put(&1, "exitCode", exit_code), else: &1))
  end

  defp cause_text(%{stderr: stderr}), do: String.slice(stderr, 0, 2000)
  defp cause_text(%{} = map), do: map
  defp cause_text(text) when is_binary(text), do: text
  defp cause_text(other), do: inspect(other)

  defp boot_error(id, result) do
    error = result["error"] || ""

    reason =
      cond do
        error =~ ~r/insufficient.*(?:disk|space)|not enough.*(?:disk|space)|no space left/i ->
          "disk_space"

        error =~ ~r/timed? out|timeout/i ->
          "timeout"

        true ->
          "launch_failed"
      end

    explanation =
      %{
        "disk_space" => "There is not enough free disk space on the environment server.",
        "timeout" => "The device did not become ready in time.",
        "launch_failed" =>
          "The simulator or emulator could not start. Check its configuration on the environment server."
      }[reason]

    %{
      "_tag" => "DeviceBootError",
      "hostId" => @local,
      "deviceId" => id,
      "reason" => reason,
      "cause" => result,
      "message" => "Device #{id} failed to boot: #{explanation}"
    }
  end

  defp reason(%{"reason" => reason, "_tag" => "DeviceHostUnavailableError"}), do: reason
  defp reason(%{"message" => message}), do: message

  defp home, do: Application.fetch_env!(:t3, :home)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  # --- server ------------------------------------------------------------------------------

  @impl true
  def init(nil) do
    # The hub is linked through Exile; its exit arrives as a message, not a crash.
    Process.flag(:trap_exit, true)
    T3.Settings.watch(self())
    settings = settings()

    view =
      %{
        "supportsHostRetry" => true,
        "supportsToolUpdate" => true,
        "supportsToolInspection" => true,
        "hosts" => [],
        "hostStatus" => if(settings.enabled, do: "idle", else: "disabled"),
        "hostStatuses" => %{},
        "devices" => [],
        "sessions" => [],
        "bootingDevices" => [],
        "onboardingCompleted" => settings.onboarding,
        "agentAccessEnabled" => settings.agent,
        "hubBasePath" => hub_base_path(),
        "revision" => 0
      }

    state = %{
      view: view,
      settings: settings,
      watchers: %{},
      hub: nil,
      hub_process: nil,
      agent: nil,
      jobs: %{}
    }

    {:ok, %{state | view: with_hosts(view, state)}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, state.view}, %{state | watchers: watchers}}
  end

  def handle_call(:state, _from, state), do: {:reply, state.view, state}

  def handle_call(:hub_origin, _from, state),
    do: {:reply, state.hub && state.hub["origin"], state}

  def handle_call(:refresh_hosts, _from, state) do
    state = publish(state, &with_hosts(&1, state))
    {:reply, state.view, state}
  end

  def handle_call({:settings, settings}, _from, state) do
    state = apply_settings(state, read_settings(settings))
    {:reply, :ok, state}
  end

  def handle_call(:ensure_hub, from, state) do
    cond do
      not state.settings.enabled ->
        {:reply,
         host_unavailable(
           @local,
           "Device support is off. Enable it in the Device panel before installing or starting device tools."
         ), state}

      state.hub ->
        {:reply, {:ok, state.hub}, state}

      true ->
        {:noreply, await_job(state, :hub, from, &hub_job/0)}
    end
  end

  def handle_call(:ensure_agent, from, state) do
    cond do
      state.agent ->
        {:reply, {:ok, state.agent}, state}

      state.hub == nil ->
        {:reply, host_unavailable(@local, "The device hub is not running."), state}

      true ->
        {:noreply, await_job(state, :agent, from, fn -> agent_job(state.hub["node"]) end)}
    end
  end

  def handle_call({:spawn_hub, node, entry}, _from, state) do
    port = free_port()

    cmd = [
      node,
      entry,
      "--port",
      "#{port}",
      "--host",
      "127.0.0.1",
      "--hide-sidebar",
      "--hide-boot-device"
    ]

    case T3.Subprocess.start(cmd, env: host_env() ++ [{"FORCE_COLOR", "0"}, {"NO_COLOR", "1"}]) do
      {:ok, sub} ->
        stop_hub(state.hub_process)
        {:reply, {:ok, "http://127.0.0.1:#{port}"}, %{state | hub_process: sub}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:devices, devices, detail}, _from, state) do
    if state.settings.enabled do
      state =
        publish(state, fn view ->
          view
          |> with_hosts(state)
          |> Map.put(
            "devices",
            Enum.reject(view["devices"], &(&1["hostId"] == @local)) ++ devices
          )
          |> put_status("ready", detail)
        end)

      {:reply, state.view, state}
    else
      {:reply, state.view, state}
    end
  end

  def handle_call({:open, session}, _from, state) do
    if state.settings.enabled do
      state =
        publish(state, fn view ->
          sessions =
            Enum.reject(
              view["sessions"],
              &(Map.take(&1, ~w(threadId hostId deviceId)) ==
                  Map.take(session, ~w(threadId hostId deviceId)))
            )

          %{view | "sessions" => sessions ++ [session]}
        end)

      {:reply, {:ok, session}, state}
    else
      {:reply,
       host_unavailable(@local, "Device support was turned off while the device was opening."),
       state}
    end
  end

  def handle_call({:close, input}, _from, state) do
    {closing, kept} =
      Enum.split_with(state.view["sessions"], fn session ->
        session["threadId"] == input["threadId"] and input["hostId"] in [nil, session["hostId"]] and
          input["deviceId"] in [nil, session["deviceId"]]
      end)

    state = if closing == [], do: state, else: publish(state, &%{&1 | "sessions" => kept})
    {:reply, closing, state}
  end

  # Sessions on a powered-off device are stale in every thread.
  def handle_call({:powered_off, id}, _from, state) do
    state =
      publish(state, fn view ->
        %{
          view
          | "devices" =>
              Enum.map(
                view["devices"],
                &if(&1["id"] == id, do: %{&1 | "booted" => false}, else: &1)
              ),
            "sessions" => Enum.reject(view["sessions"], &(&1["deviceId"] == id))
        }
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_cast({:status, status, detail}, state) do
    if state.settings.enabled,
      do: {:noreply, publish(state, &put_status(&1, status, detail))},
      else: {:noreply, state}
  end

  def handle_cast({:booting, device}, state) do
    {:noreply,
     publish(state, &%{&1 | "bootingDevices" => [device | without(&1["bootingDevices"], device)]})}
  end

  def handle_cast({:booted, device}, state),
    do:
      {:noreply,
       publish(state, &%{&1 | "bootingDevices" => without(&1["bootingDevices"], device)})}

  @impl true
  def handle_info({:t3_settings, _node, settings}, state),
    do: {:noreply, apply_settings(state, read_settings(settings))}

  def handle_info({:subprocess_lines, _reader, _lines}, %{hub_process: sub} = state)
      when sub != nil do
    T3.Subprocess.ack(sub)
    {:noreply, state}
  end

  def handle_info({:subprocess_eof, reader}, %{hub_process: %{reader: reader} = sub} = state) do
    stop_hub(sub)
    state = %{state | hub: nil, hub_process: nil}

    state =
      if state.settings.enabled,
        do:
          publish(
            state,
            &put_status(
              &1,
              "failed",
              "The device hub stopped. Refresh devices to start it again."
            )
          ),
        else: state

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_job(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if Map.has_key?(state.watchers, pid) do
      {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}
    else
      Logger.warning("device job failed: #{inspect(reason)}")

      {:noreply,
       finish_job(state, ref, host_unavailable(@local, "Device support failed unexpectedly."))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_hub(state.hub_process)
    if state.agent, do: stop_daemon(state.agent)
    :ok
  end

  defp await_job(state, kind, from, fun) do
    case state.jobs[kind] do
      {ref, waiters} ->
        put_in(state.jobs[kind], {ref, [from | waiters]})

      nil ->
        %Task{ref: ref} = Task.async(fun)
        put_in(state.jobs[kind], {ref, [from]})
    end
  end

  defp finish_job(state, ref, result) do
    case Enum.find(state.jobs, fn {_, {job, _}} -> job == ref end) do
      nil ->
        state

      {kind, {_, waiters}} ->
        state = %{state | jobs: Map.delete(state.jobs, kind)}

        {state, result} =
          case {kind, result, state.settings.enabled} do
            {_, {:ok, _}, false} ->
              {shut_down(state),
               host_unavailable(@local, "Device support was turned off while it was starting.")}

            {:hub, {:ok, hub}, _} ->
              {publish(%{state | hub: hub}, &put_status(&1, "ready", nil)), result}

            {:agent, {:ok, agent}, _} ->
              state = %{state | agent: agent}
              {publish(state, &(&1 |> with_hosts(state) |> put_status("ready", nil))), result}

            {:hub, {:error, error}, _} ->
              stop_hub(state.hub_process)
              state = %{state | hub_process: nil}
              {publish(state, &put_status(&1, "failed", reason(error))), result}

            {:agent, {:error, error}, _} ->
              {publish(state, &put_status(&1, "failed", reason(error))), result}
          end

        for waiter <- waiters, do: GenServer.reply(waiter, result)
        state
    end
  end

  defp apply_settings(state, settings) when settings == state.settings, do: state

  defp apply_settings(state, settings) do
    previous = state.settings

    state =
      cond do
        not settings.enabled -> shut_down(state)
        previous.agent and not settings.agent -> stop_agent(state)
        true -> state
      end

    state = %{state | settings: settings}

    publish(state, fn view ->
      view =
        if settings.enabled == previous.enabled do
          view
        else
          view
          |> Map.merge(%{
            "hostStatus" => if(settings.enabled, do: "idle", else: "disabled"),
            "hostStatuses" => %{},
            "devices" => if(settings.enabled, do: view["devices"], else: []),
            "sessions" => if(settings.enabled, do: view["sessions"], else: []),
            "bootingDevices" => if(settings.enabled, do: view["bootingDevices"], else: [])
          })
          |> Map.delete("hostStatusDetail")
        end

      view
      |> Map.merge(%{
        "agentAccessEnabled" => settings.agent,
        "onboardingCompleted" => settings.onboarding
      })
      |> with_hosts(state)
    end)
  end

  defp shut_down(state) do
    stop_hub(state.hub_process)
    %{stop_agent(state) | hub: nil, hub_process: nil}
  end

  defp stop_agent(state) do
    if state.agent, do: stop_daemon(state.agent)
    %{state | agent: nil}
  end

  defp stop_hub(nil), do: :ok
  defp stop_hub(sub), do: T3.Subprocess.stop(sub)

  # This machine, then each configured SSH host, reported unavailable.
  defp with_hosts(view, state) do
    unavailable = fn config ->
      reason = ssh_reason(config)

      %{
        "id" => config["id"],
        "kind" => "ssh",
        "label" => config["label"] || config["id"],
        "platforms" =>
          for(
            platform <- ~w(ios android),
            do: %{"platform" => platform, "available" => false, "reason" => reason}
          ),
        "hubInstalled" => false,
        "agentDeviceInstalled" => false
      }
    end

    local = %{
      "id" => @local,
      "kind" => "local",
      "label" => "This machine",
      "platforms" =>
        for platform <- ~w(ios android) do
          case platform_reason(platform) do
            nil -> %{"platform" => platform, "available" => true}
            reason -> %{"platform" => platform, "available" => false, "reason" => reason}
          end
        end,
      "tools" => %{
        "hub" => tool_version("hub", if(state.hub, do: @tools["hub"].version)),
        "agent" => tool_version("agent", if(state.agent, do: @tools["agent"].version))
      },
      "hubInstalled" => installed?("hub"),
      "agentDeviceInstalled" => installed?("agent")
    }

    ssh_statuses =
      if state.settings.enabled,
        do:
          for(
            config <- state.settings.ssh,
            into: %{},
            do: {config["id"], %{"status" => "failed", "detail" => ssh_reason(config)}}
          ),
        else: %{}

    %{
      view
      | "hosts" => [local | Enum.map(state.settings.ssh, unavailable)],
        "hostStatuses" =>
          view["hostStatuses"]
          |> Map.take([@local])
          |> Map.merge(ssh_statuses)
    }
  end

  defp put_status(view, status, detail) do
    entry = if detail, do: %{"status" => status, "detail" => detail}, else: %{"status" => status}

    view = %{
      view
      | "hostStatus" => status,
        "hostStatuses" => Map.put(view["hostStatuses"], @local, entry)
    }

    if detail,
      do: Map.put(view, "hostStatusDetail", detail),
      else: Map.delete(view, "hostStatusDetail")
  end

  defp without(devices, device), do: Enum.reject(devices, &(&1["id"] == device["id"]))

  defp publish(state, fun) do
    view = state.view |> fun.() |> Map.put("revision", state.view["revision"] + 1)
    for {pid, _} <- state.watchers, do: send(pid, {:t3_devices, node(), view})
    %{state | view: view}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
