defmodule T3.Terminal.Hub do
  @moduledoc """
  This node's terminals as a list (`subscribeTerminalMetadata`), and which command
  each shell is running.

  Terminals report their summary here; watchers (client sockets, possibly on other
  nodes) get the list once and then `{:t3_terminals, node, event}` messages shaped
  as `TerminalMetadataStreamEvent`. While any shell runs, one `ps` per second finds
  each shell's child process and tells the terminal when it changes, so its label
  can show the running command.
  """

  use GenServer

  @poll_ms 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Adds `pid` as a watcher; returns every terminal's summary."
  def watch(pid), do: GenServer.call(__MODULE__, {:watch, pid})

  def unwatch(pid), do: GenServer.cast(__MODULE__, {:unwatch, pid})

  @doc "Records a terminal's current summary; `session` is its process."
  def upsert(summary, session), do: GenServer.cast(__MODULE__, {:upsert, summary, session})

  def remove(thread_id, terminal_id),
    do: GenServer.cast(__MODULE__, {:remove, {thread_id, terminal_id}})

  @doc "Every terminal's summary, without watching."
  def summaries do
    GenServer.call(__MODULE__, :summaries)
  catch
    :exit, {:noproc, _} -> []
  end

  @impl true
  def init(nil) do
    {:ok, %{terminals: %{}, sessions: %{}, watchers: %{}, activity: %{}, polling: false}}
  end

  @impl true
  def handle_call(:summaries, _from, state),
    do: {:reply, for({_key, {summary, _session}} <- state.terminals, do: summary), state}

  def handle_call({:watch, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    summaries = for {_key, {summary, _session}} <- state.terminals, do: summary
    {:reply, summaries, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unwatch, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_cast({:upsert, summary, session}, state) do
    key = {summary["threadId"], summary["terminalId"]}

    sessions =
      if Map.has_key?(state.sessions, session),
        do: state.sessions,
        else: Map.put(state.sessions, session, {key, Process.monitor(session)})

    broadcast(state, %{"type" => "upsert", "terminal" => summary})

    state = %{
      state
      | terminals: Map.put(state.terminals, key, {summary, session}),
        sessions: sessions
    }

    {:noreply, maybe_poll(state)}
  end

  def handle_cast({:remove, key}, state), do: {:noreply, drop(state, key)}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    cond do
      match?(%{^pid => ^ref}, state.watchers) ->
        {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

      match?(%{^pid => {_, ^ref}}, state.sessions) ->
        {key, _} = state.sessions[pid]
        {:noreply, drop(%{state | sessions: Map.delete(state.sessions, pid)}, key)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:poll, state) do
    hub = self()
    Task.start(fn -> send(hub, {:processes, process_table()}) end)
    {:noreply, state}
  end

  def handle_info({:processes, table}, state) do
    activity =
      for {key, {%{"status" => "running", "pid" => pid}, session}} <- state.terminals,
          is_integer(pid),
          into: %{} do
        current = child(table, pid)

        if current != Map.get(state.activity, key, {false, nil}),
          do: send(session, {:activity, elem(current, 0), elem(current, 1)})

        {key, current}
      end

    {:noreply, maybe_poll(%{state | activity: activity, polling: false})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state, key) do
    case Map.pop(state.terminals, key) do
      {nil, _} ->
        state

      {_, terminals} ->
        {thread_id, terminal_id} = key

        broadcast(state, %{
          "type" => "remove",
          "threadId" => thread_id,
          "terminalId" => terminal_id
        })

        %{state | terminals: terminals, activity: Map.delete(state.activity, key)}
    end
  end

  defp broadcast(state, event) do
    for {pid, _} <- state.watchers, do: send(pid, {:t3_terminals, node(), event})
  end

  # Polls only while some shell is running.
  defp maybe_poll(%{polling: true} = state), do: state

  defp maybe_poll(state) do
    if Enum.any?(state.terminals, fn {_, {summary, _}} -> summary["status"] == "running" end) do
      Process.send_after(self(), :poll, @poll_ms)
      %{state | polling: true}
    else
      state
    end
  end

  # `{first child by parent pid, command by pid}` from `ps`, which lists by pid.
  defp process_table do
    ps = Enum.find(["/bin/ps", "/usr/bin/ps"], &File.exists?/1) || "ps"

    case System.cmd(ps, ["-eo", "pid=,ppid=,comm="], stderr_to_stdout: true) do
      {out, 0} ->
        for line <- String.split(out, "\n"),
            [_, pid, ppid, command] <- [Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.+)$/, line)],
            reduce: {%{}, %{}} do
          {children, commands} ->
            pid = String.to_integer(pid)
            ppid = String.to_integer(ppid)
            {Map.put_new(children, ppid, pid), Map.put(commands, pid, String.trim(command))}
        end

      _ ->
        {%{}, %{}}
    end
  rescue
    _ -> {%{}, %{}}
  end

  # The shell's first child and its command name, e.g. `{true, "vim"}`.
  defp child({children, commands}, shell_pid) do
    case Map.fetch(children, shell_pid) do
      {:ok, pid} -> {true, command_name(Map.get(commands, pid, ""))}
      :error -> {false, nil}
    end
  end

  defp command_name(raw) do
    raw = String.trim(raw)

    raw =
      if Regex.match?(~r/^(\[.*\]|\(.*\))$/, raw),
        do: raw |> String.slice(1..-2//1) |> String.trim(),
        else: raw

    case String.split(raw) do
      [first | _] -> first |> Path.basename() |> String.slice(0, 128)
      [] -> nil
    end
  end
end
