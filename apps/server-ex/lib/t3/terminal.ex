defmodule T3.Terminal do
  @moduledoc """
  A thread's terminal: one shell in a PTY (via erlexec), its scrollback, and the
  clients attached to it. Serves the `terminal.*` RPCs of
  `packages/contracts/src/terminal.ts` on the node that owns the thread.

  Each terminal is a process registered by `{thread_id, terminal_id}`; it outlives
  its shell, so an exited terminal can still be attached and read. Output is sent
  to attached clients in batches of `@output_ms`, and the scrollback is written to
  `<home>/terminals/` after `@persist_ms` of quiet so it survives a restart.
  `T3.Terminal.Hub` lists every terminal for the metadata stream and polls which
  command each shell is running.

  Attached processes receive `{:t3_terminal, {thread_id, terminal_id}, event}`, with
  events shaped as `TerminalAttachStreamEvent`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias T3.Terminal.{History, Hub}

  @registry T3.Terminal.Registry
  @supervisor T3.Terminal.Supervisor
  @default_cols 120
  @default_rows 30
  @output_ms 8
  @persist_ms 500
  @excluded_env ~w(PORT ELECTRON_RENDERER_PORT ELECTRON_RUN_AS_NODE BINDIR ROOTDIR EMU PROGNAME)
  @excluded_env_prefixes ~w(T3CODE_ VITE_ T3_ RELEASE_ ERL_)

  # --- API ------------------------------------------------------------------------

  @doc "`terminal.open`: starts the shell unless it is already running; returns its snapshot."
  def open(%{"threadId" => _, "terminalId" => _, "cwd" => cwd} = input) do
    with :ok <- check_cwd(cwd), do: call(ensure(input), {:open, input})
  end

  @doc """
  `terminal.attach`: sends `subscriber` the terminal's events from now on and
  returns its snapshot. A terminal that does not exist yet is opened when the
  input has a `cwd`.
  """
  def attach(%{"threadId" => thread_id, "terminalId" => terminal_id} = input, subscriber) do
    case {lookup(thread_id, terminal_id), input["cwd"]} do
      {nil, nil} ->
        {:error, lookup_error(thread_id, terminal_id)}

      {nil, cwd} ->
        with :ok <- check_cwd(cwd), do: call(ensure(input), {:attach, input, subscriber})

      {pid, _} ->
        call(pid, {:attach, input, subscriber})
    end
  end

  @doc "Stops sending a terminal's events to `subscriber`."
  def detach(thread_id, terminal_id, subscriber) do
    if pid = lookup(thread_id, terminal_id), do: GenServer.cast(pid, {:detach, subscriber})
    :ok
  end

  def write(%{"data" => data} = input), do: with_session(input, &call(&1, {:write, data}))

  def resize(%{"cols" => cols, "rows" => rows} = input),
    do: with_session(input, &call(&1, {:resize, cols, rows}))

  def clear(input), do: with_session(input, &call(&1, :clear))

  @doc "`terminal.restart`: a fresh shell with the given launch context and empty scrollback."
  def restart(%{"cwd" => cwd} = input) do
    with :ok <- check_cwd(cwd), do: call(ensure(input), {:restart, input})
  end

  @doc "`terminal.close`: one terminal, or every terminal of the thread without a `terminalId`."
  def close(%{"threadId" => thread_id} = input) do
    delete = input["deleteHistory"] == true

    pids =
      case input["terminalId"] do
        nil -> Registry.select(@registry, [{{{thread_id, :_}, :"$1", :_}, [], [:"$1"]}])
        terminal_id -> List.wrap(lookup(thread_id, terminal_id))
      end

    Enum.each(pids, &call(&1, {:close, delete}))

    # Scrollback of terminals that are not running is on disk only.
    if delete do
      pattern = history_path(thread_id, input["terminalId"] || "*")
      Enum.each(Path.wildcard(pattern), &File.rm/1)
    end

    {:ok, nil}
  end

  def start_link({thread_id, terminal_id}),
    do:
      GenServer.start_link(__MODULE__, {thread_id, terminal_id},
        name: via(thread_id, terminal_id)
      )

  defp with_session(%{"threadId" => thread_id, "terminalId" => terminal_id}, fun) do
    case lookup(thread_id, terminal_id) do
      nil -> {:error, lookup_error(thread_id, terminal_id)}
      pid -> fun.(pid)
    end
  end

  defp ensure(%{"threadId" => thread_id, "terminalId" => terminal_id}) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {thread_id, terminal_id}}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp lookup(thread_id, terminal_id) do
    case Registry.lookup(@registry, {thread_id, terminal_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(thread_id, terminal_id), do: {:via, Registry, {@registry, {thread_id, terminal_id}}}

  # A terminal that just closed is not an error to a caller that raced it.
  defp call(pid, message) do
    GenServer.call(pid, message, 15_000)
  catch
    :exit, {:noproc, _} ->
      {:error, %{"_tag" => "TerminalSessionLookupError", "message" => "terminal closed"}}

    :exit, {:normal, _} ->
      {:ok, nil}
  end

  defp check_cwd(cwd) do
    case File.stat(cwd) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _} ->
        {:error,
         %{
           "_tag" => "TerminalCwdNotDirectoryError",
           "cwd" => cwd,
           "message" => "Terminal cwd is not a directory: #{cwd}"
         }}

      {:error, :enoent} ->
        {:error,
         %{
           "_tag" => "TerminalCwdNotFoundError",
           "cwd" => cwd,
           "message" => "Terminal cwd does not exist: #{cwd}"
         }}

      {:error, reason} ->
        {:error,
         %{
           "_tag" => "TerminalCwdStatError",
           "cwd" => cwd,
           "message" => "Failed to access terminal cwd: #{cwd} (#{reason})"
         }}
    end
  end

  defp lookup_error(thread_id, terminal_id),
    do: %{
      "_tag" => "TerminalSessionLookupError",
      "threadId" => thread_id,
      "terminalId" => terminal_id,
      "message" => "Unknown terminal thread: #{thread_id}, terminal: #{terminal_id}"
    }

  defp not_running_error(state),
    do: %{
      "_tag" => "TerminalNotRunningError",
      "threadId" => state.thread_id,
      "terminalId" => state.terminal_id,
      "message" =>
        "Terminal is not running for thread: #{state.thread_id}, terminal: #{state.terminal_id}"
    }

  # --- session --------------------------------------------------------------------

  @impl true
  def init({thread_id, terminal_id}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       thread_id: thread_id,
       terminal_id: terminal_id,
       cwd: nil,
       worktree_path: nil,
       env: nil,
       cols: @default_cols,
       rows: @default_rows,
       status: "starting",
       os_pid: nil,
       exit_code: nil,
       exit_signal: nil,
       history: History.new(read_history(thread_id, terminal_id)),
       carry: "",
       output: [],
       output_timer: nil,
       persist_timer: nil,
       subprocess: false,
       child_label: nil,
       seq: 0,
       updated_at: now(),
       subscribers: %{}
     }}
  end

  @impl true
  def handle_call({:open, input}, _from, state) do
    state = open_session(state, input)
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:attach, input, subscriber}, _from, state) do
    state =
      cond do
        state.cwd == nil and input["cwd"] ->
          open_session(state, input)

        (state.os_pid == nil and input["cwd"]) && input["restartIfNotRunning"] == true ->
          open_session(state, input)

        true ->
          resize_to(state, input["cols"] || state.cols, input["rows"] || state.rows)
      end

    subscribers =
      Map.put_new_lazy(state.subscribers, subscriber, fn -> Process.monitor(subscriber) end)

    {:reply, {:ok, snapshot(state)}, %{state | subscribers: subscribers}}
  end

  def handle_call({:write, _data}, _from, %{os_pid: nil} = state),
    do: {:reply, {:error, not_running_error(state)}, state}

  def handle_call({:write, data}, _from, state) do
    :ok = :exec.send(state.os_pid, data)
    {:reply, {:ok, nil}, state}
  end

  def handle_call({:resize, cols, rows}, _from, state),
    do: {:reply, {:ok, nil}, resize_to(state, cols, rows)}

  def handle_call(:clear, _from, state) do
    state = %{state | history: History.clear(state.history)} |> schedule_persist()
    {:reply, {:ok, nil}, emit(state, %{"type" => "cleared"})}
  end

  def handle_call({:restart, input}, _from, state) do
    state =
      state
      |> launch_context(input)
      |> Map.update!(:history, &History.clear/1)
      |> start_shell("restarted")

    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:close, delete_history}, _from, state) do
    state = stop_shell(state) |> emit(%{"type" => "closed"})
    Hub.remove(state.thread_id, state.terminal_id)
    unless delete_history, do: persist(state)
    {:stop, :normal, {:ok, nil}, %{state | persist_timer: nil, cwd: nil}}
  end

  @impl true
  def handle_cast({:detach, subscriber}, state) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _} ->
        {:noreply, state}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    {text, carry} = History.utf8(state.carry, data)

    state = %{
      state
      | carry: carry,
        history: History.append(state.history, text),
        output: [state.output, text]
    }

    state =
      if state.output_timer,
        do: state,
        else: %{state | output_timer: Process.send_after(self(), :output, @output_ms)}

    {:noreply, schedule_persist(state)}
  end

  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %{os_pid: os_pid} = state) do
    {code, signal} =
      case reason do
        :normal ->
          {0, nil}

        {:exit_status, status} ->
          case :exec.status(status) do
            {:status, code} -> {code, nil}
            {:signal, signal, _core} -> {nil, signal_number(signal)}
          end

        _ ->
          {nil, nil}
      end

    state =
      %{
        flush_output(state)
        | status: "exited",
          os_pid: nil,
          exit_code: code,
          exit_signal: signal,
          subprocess: false,
          child_label: nil
      }
      |> emit(%{"type" => "exited", "exitCode" => code, "exitSignal" => signal})

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.subscribers do
      %{^pid => ^ref} -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(:output, state), do: {:noreply, flush_output(state)}

  def handle_info(:persist, state) do
    persist(state)
    {:noreply, %{state | persist_timer: nil}}
  end

  # From `T3.Terminal.Hub`: the command running in the shell changed.
  def handle_info({:activity, subprocess, label}, state) do
    if {subprocess, label} == {state.subprocess, state.child_label} or state.os_pid == nil do
      {:noreply, state}
    else
      state = %{state | subprocess: subprocess, child_label: label}

      {:noreply,
       emit(state, %{
         "type" => "activity",
         "hasRunningSubprocess" => subprocess,
         "label" => label(state)
       })}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_shell(state)
    if state.persist_timer, do: persist(state)
    :ok
  end

  # Starts the shell, or updates a running one, the way `terminal.open` does: a new
  # cwd, worktree, or env replaces the shell and its scrollback; an exited shell is
  # started again with empty scrollback.
  defp open_session(state, input) do
    worktree = Map.get(input, "worktreePath", state.worktree_path)

    changed =
      state.cwd != nil and
        (state.cwd != input["cwd"] or state.env != env_input(input) or
           state.worktree_path != worktree)

    state =
      cond do
        changed or state.status in ["exited", "error"] ->
          state
          |> stop_shell()
          |> launch_context(input)
          |> Map.update!(:history, &History.clear/1)
          |> schedule_persist()

        state.cwd == nil ->
          launch_context(state, input)

        true ->
          state
      end

    if state.os_pid,
      do: resize_to(state, input["cols"] || state.cols, input["rows"] || state.rows),
      else:
        start_shell(
          %{state | cols: input["cols"] || state.cols, rows: input["rows"] || state.rows},
          "started"
        )
  end

  defp launch_context(state, input),
    do: %{
      state
      | cwd: input["cwd"],
        worktree_path: Map.get(input, "worktreePath", state.worktree_path),
        env: env_input(input),
        cols: input["cols"] || state.cols,
        rows: input["rows"] || state.rows
    }

  defp env_input(input) do
    case input["env"] do
      env when is_map(env) and map_size(env) > 0 -> env
      _ -> nil
    end
  end

  defp start_shell(state, event) do
    state = stop_shell(state)

    options = [
      :stdin,
      :stdout,
      :pty,
      :monitor,
      {:winsz, {state.rows, state.cols}},
      {:cd, String.to_charlist(state.cwd)},
      {:env, [:clear | spawn_env(state.env)]},
      {:kill_timeout, 1}
    ]

    case Enum.find(shells(), &File.exists?(hd(&1))) do
      nil ->
        failed(state, "No shell found (tried #{Enum.map_join(shells(), ", ", &hd/1)})")

      shell ->
        case :exec.run(shell, options) do
          {:ok, _pid, os_pid} ->
            state = %{
              state
              | status: "running",
                os_pid: os_pid,
                exit_code: nil,
                exit_signal: nil,
                subprocess: false,
                child_label: nil,
                carry: ""
            }

            state = advance(state)
            event = %{"type" => event, "snapshot" => snapshot(state)}
            emit(state, event, advance: false)

          {:error, reason} ->
            failed(state, "Could not start #{hd(shell)}: #{inspect(reason)}")
        end
    end
  end

  defp failed(state, message) do
    Logger.warning("terminal #{state.terminal_id}: #{message}")
    emit(%{state | status: "error", os_pid: nil}, %{"type" => "error", "message" => message})
  end

  defp stop_shell(%{os_pid: nil} = state), do: state

  defp stop_shell(state) do
    :exec.stop(state.os_pid)
    %{flush_output(state) | os_pid: nil}
  end

  defp resize_to(state, cols, rows) do
    if state.os_pid && {cols, rows} != {state.cols, state.rows},
      do: :exec.winsz(state.os_pid, rows, cols)

    %{state | cols: cols, rows: rows}
  end

  defp flush_output(%{output: []} = state), do: state

  defp flush_output(state) do
    if state.output_timer, do: Process.cancel_timer(state.output_timer)
    data = IO.iodata_to_binary(state.output)
    state = %{state | output: [], output_timer: nil}
    if data == "", do: state, else: emit(state, %{"type" => "output", "data" => data})
  end

  # Sends an event to attached clients (the `started` snapshot goes out as
  # `snapshot`) and keeps the hub's summary current.
  defp emit(state, event, opts \\ []) do
    state = if Keyword.get(opts, :advance, true), do: advance(state), else: state

    event =
      Map.merge(event, %{
        "threadId" => state.thread_id,
        "terminalId" => state.terminal_id,
        "sequence" => state.seq
      })

    attach_event =
      if event["type"] == "started",
        do: %{"type" => "snapshot", "snapshot" => event["snapshot"]},
        else: event

    key = {state.thread_id, state.terminal_id}
    for {pid, _} <- state.subscribers, do: send(pid, {:t3_terminal, key, attach_event})

    if event["type"] in ~w(started restarted exited error activity),
      do: Hub.upsert(summary(state), self())

    state
  end

  defp advance(state), do: %{state | seq: state.seq + 1, updated_at: now()}

  defp snapshot(state) do
    state
    |> summary()
    |> Map.drop(["hasRunningSubprocess"])
    |> Map.merge(%{"history" => History.value(state.history), "sequence" => state.seq})
  end

  defp summary(state),
    do: %{
      "threadId" => state.thread_id,
      "terminalId" => state.terminal_id,
      "cwd" => state.cwd,
      "worktreePath" => state.worktree_path,
      "status" => state.status,
      "pid" => state.os_pid,
      "exitCode" => state.exit_code,
      "exitSignal" => state.exit_signal,
      "hasRunningSubprocess" => state.subprocess,
      "label" => label(state),
      "updatedAt" => state.updated_at
    }

  defp label(%{subprocess: true, child_label: label}) when is_binary(label) and label != "",
    do: String.slice(label, 0, 128)

  defp label(%{terminal_id: terminal_id}) do
    case Regex.run(~r/^term(?:inal)?-(\d+)$/i, terminal_id) do
      [_, n] -> "Terminal #{n}"
      nil -> String.slice(terminal_id, 0, 128)
    end
  end

  # --- shell and env --------------------------------------------------------------

  # The user's shell first, then common ones. zsh must not print its partial-line
  # marker into a fresh terminal.
  defp shells do
    requested = System.get_env("SHELL", "") |> String.split() |> List.first()

    [requested, "/bin/zsh", "/bin/bash", "/bin/sh"]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(fn shell ->
      if Path.basename(shell) == "zsh", do: [shell, "-o", "nopromptsp"], else: [shell]
    end)
  end

  defp spawn_env(runtime_env) do
    base =
      for {key, value} <- System.get_env(),
          upper = String.upcase(key),
          upper not in @excluded_env,
          not String.starts_with?(upper, @excluded_env_prefixes),
          into: %{},
          do: {key, value}

    env =
      base
      |> Map.merge(runtime_env || %{})
      |> Map.put("TERM", "xterm-256color")
      |> Map.put_new("COLORTERM", "truecolor")

    for {key, value} <- env, value != "" or key == "COLORTERM", do: {key, value}
  end

  # --- history on disk ------------------------------------------------------------

  defp schedule_persist(%{persist_timer: nil} = state),
    do: %{state | persist_timer: Process.send_after(self(), :persist, @persist_ms)}

  defp schedule_persist(state), do: state

  defp persist(state) do
    path = history_path(state.thread_id, state.terminal_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, History.value(state.history))
  rescue
    error -> Logger.warning("terminal history not saved: #{Exception.message(error)}")
  end

  defp read_history(thread_id, terminal_id) do
    path = history_path(thread_id, terminal_id)
    max = %History{}.max_bytes

    case File.stat(path) do
      {:ok, %{size: size}} when size > max ->
        {:ok, file} = File.open(path, [:read, :binary])
        {:ok, data} = :file.pread(file, size - max, max)
        File.close(file)
        data

      {:ok, _} ->
        File.read!(path)

      {:error, _} ->
        ""
    end
  end

  # `terminal_id` "*" gives a wildcard pattern for all of a thread's terminals.
  defp history_path(thread_id, terminal_id) do
    home = Application.fetch_env!(:t3, :home)

    terminal =
      if terminal_id == "*", do: "*", else: Base.url_encode64(terminal_id, padding: false)

    name = "terminal_#{Base.url_encode64(thread_id, padding: false)}_#{terminal}.log"
    Path.join([home, "terminals", name])
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @signals %{sighup: 1, sigint: 2, sigquit: 3, sigkill: 9, sigsegv: 11, sigpipe: 13, sigterm: 15}
  defp signal_number(signal) when is_integer(signal), do: signal
  defp signal_number(signal), do: Map.get(@signals, signal)
end
