defmodule T3.Desktop.Channel do
  @moduledoc """
  The desktop app's telemetry channel, as the Node server speaks it: JSON lines in
  on one inherited file descriptor (`desktopTelemetryFd`) and control lines out on
  another (`desktopTelemetryControlFd`), both named in the desktop bootstrap
  (`T3.Desktop`).

  In: the Electron process's pid, periodic telemetry (its processes' CPU and
  memory, and the host's power state), and the app's update state. Out: whether
  diagnostics want Electron metrics, and requests to update the desktop app.

  A node the desktop app runs is updated by updating the app, whose bundle carries
  the node: `update/1` asks the app to check and download (progress goes to
  `report`), and `commit/1` has it quit and install, which stops this node.
  """

  # Ends when the app closes the channel; nothing reopens it.
  use GenServer, restart: :transient
  require Logger

  @update_timeout :timer.minutes(20)
  @install_timeout :timer.minutes(2)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the desktop app's channel is open."
  def available?, do: Process.whereis(__MODULE__) != nil

  @doc "The latest `DesktopHostTelemetrySnapshot`, or nil."
  def telemetry, do: if(available?(), do: GenServer.call(__MODULE__, :telemetry))

  @doc "Asks for Electron metrics only while diagnostics are watched."
  def set_diagnostics_demand(enabled) do
    if available?(), do: GenServer.cast(__MODULE__, {:demand, enabled})
    :ok
  end

  @doc """
  Updates the desktop app through its own updater: `{:ok, ServerSelfUpdateResult}`
  once the update is downloaded and ready to install, or `{:error, reason}`.
  `report.(stage)` hears `downloading` and `installing`.
  """
  def update(report) do
    if available?(),
      do: GenServer.call(__MODULE__, {:update, report}, @update_timeout + 5_000),
      else:
        {:error,
         "This node was not started by the T3 Code desktop app, so it cannot drive a desktop update."}
  end

  @doc "Installs the update `update/1` prepared; returns only if installing fails."
  def commit(request_id) do
    if available?(),
      do: GenServer.call(__MODULE__, {:commit, request_id}, @install_timeout + 5_000),
      else: {:error, "This node cannot commit a desktop app update."}
  end

  # --- server --------------------------------------------------------------------

  @impl true
  def init(opts) do
    port =
      case Keyword.fetch!(opts, :transport) do
        {:fd, input, output} ->
          Port.open({:fd, input, output}, [:binary, :eof, {:line, 4_194_304}])

        {:test, pid} ->
          {:test, pid}
      end

    {:ok,
     %{
       port: port,
       partial: "",
       telemetry: nil,
       electron_pid: nil,
       waiter: nil
     }}
  end

  @impl true
  def handle_call(:telemetry, _from, state), do: {:reply, state.telemetry, state}

  def handle_call({:update, _report}, _from, %{waiter: waiter} = state) when waiter != nil,
    do: {:reply, {:error, "A desktop app update is already in progress."}, state}

  def handle_call({:update, report}, from, state) do
    request_id = T3.Environment.uuid4()
    control(state, %{"type" => "requestDesktopUpdate", "requestId" => request_id})
    timer = Process.send_after(self(), {:timeout, request_id}, @update_timeout)

    {:noreply,
     %{
       state
       | waiter: %{
           kind: :update,
           id: request_id,
           from: from,
           report: report,
           stage: nil,
           timer: timer
         }
     }}
  end

  def handle_call({:commit, request_id}, from, state) do
    control(state, %{"type" => "commitDesktopUpdate", "requestId" => request_id})
    timer = Process.send_after(self(), {:timeout, request_id}, @install_timeout)
    {:noreply, %{state | waiter: %{kind: :commit, id: request_id, from: from, timer: timer}}}
  end

  @impl true
  def handle_cast({:demand, enabled}, state) do
    control(state, %{"type" => "setDiagnosticsDemand", "enabled" => enabled})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | partial: state.partial <> part}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state),
    do: {:noreply, receive_line(%{state | partial: ""}, state.partial <> line)}

  def handle_info({:desktop_line, line}, state), do: {:noreply, receive_line(state, line)}

  def handle_info({port, :eof}, %{port: port} = state) do
    Logger.info("the desktop app closed its telemetry channel")
    {:stop, :normal, state}
  end

  def handle_info({:timeout, id}, %{waiter: %{id: id} = waiter} = state) do
    message =
      if waiter.kind == :update,
        do: "The desktop app did not finish the update in time.",
        else: "The desktop app did not report an install result in time."

    if waiter.kind == :update,
      do: control(state, %{"type" => "cancelDesktopUpdate", "requestId" => id})

    GenServer.reply(waiter.from, {:error, message})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp receive_line(state, line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "desktopTelemetryHello", "electronPid" => pid}} ->
        %{state | electron_pid: pid}

      {:ok, %{"type" => "desktopTelemetry"} = telemetry} ->
        if power = telemetry["power"], do: T3.BackgroundPolicy.report_host_power(power)
        %{state | telemetry: telemetry}

      {:ok, %{"type" => "desktopUpdateStatus"} = report} ->
        update_report(state, report)

      _ ->
        state
    end
  end

  defp update_report(
         %{waiter: %{kind: :update, id: id} = waiter} = state,
         %{"requestId" => id} = report
       ) do
    status = get_in(report, ["state", "status"])

    case report["outcome"] do
      nil ->
        stage =
          cond do
            status in ~w(checking available downloading) -> "downloading"
            status == "downloaded" -> "installing"
            true -> nil
          end

        if stage && stage != waiter.stage, do: waiter.report.(stage)
        %{state | waiter: %{waiter | stage: stage || waiter.stage}}

      "ready-to-install" ->
        if waiter.stage != "installing", do: waiter.report.("installing")
        update_state = report["state"] || %{}

        target =
          update_state["downloadedVersion"] || update_state["availableVersion"] ||
            update_state["currentVersion"]

        finish(
          state,
          {:ok,
           %{"targetVersion" => target, "method" => "desktop-app", "desktopUpdateToken" => id}}
        )

      "up-to-date" ->
        finish(
          state,
          {:error,
           "The T3 Code desktop app on this machine is already up to date on #{get_in(report, ["state", "currentVersion"])}."}
        )

      _failed ->
        finish(state, {:error, reason(report, "The desktop app update failed.")})
    end
  end

  defp update_report(
         %{waiter: %{kind: :commit, id: id}} = state,
         %{"requestId" => id, "outcome" => "failed"} = report
       ),
       do:
         finish(state, {:error, reason(report, "The desktop app failed to install the update.")})

  defp update_report(state, _report), do: state

  defp finish(%{waiter: waiter} = state, reply) do
    Process.cancel_timer(waiter.timer)
    GenServer.reply(waiter.from, reply)
    %{state | waiter: nil}
  end

  defp reason(report, fallback),
    do: report["reason"] || get_in(report, ["state", "message"]) || fallback

  defp control(%{port: {:test, pid}}, message),
    do: send(pid, {:desktop_control, Map.put(message, "version", 1)})

  defp control(%{port: port}, message),
    do: Port.command(port, [JSON.encode!(Map.put(message, "version", 1)), ?\n])
end
