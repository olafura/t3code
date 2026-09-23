defmodule T3.Claude.Session do
  @moduledoc """
  Owns one `claude` CLI process speaking the stream-json control protocol.

  The session sends `initialize` on start. Transcript messages go to the `:handler`
  as `{:claude, session, {:message, map}}`. Tool permission prompts arrive as
  `{:claude, session, {:permission, request_id, tool_name, input, context}}` and are
  answered with `answer_permission/3`. `control/3` sends any control request
  (`"interrupt"`, `"set_model"`, `"set_permission_mode"`, ...) and waits for its reply.
  """

  use GenServer

  alias T3.Claude.Protocol
  alias T3.Subprocess

  @state_version 1

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, hibernate_after: 15_000)

  @spec send_message(GenServer.server(), String.t() | [map]) :: :ok
  def send_message(session, content), do: GenServer.cast(session, {:user_message, content})

  @spec answer_permission(
          GenServer.server(),
          String.t(),
          :allow | {:allow, map} | {:deny, String.t()}
        ) :: :ok
  def answer_permission(session, request_id, decision),
    do: GenServer.cast(session, {:answer_permission, request_id, decision})

  @spec control(GenServer.server(), String.t(), map, timeout) :: {:ok, map} | {:error, term}
  def control(session, subtype, params \\ %{}, timeout \\ 30_000),
    do: GenServer.call(session, {:control, subtype, params}, timeout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cmd = [Keyword.get(opts, :executable, "claude") | Protocol.cli_args(opts)]

    with {:ok, sub} <- Subprocess.start(cmd, Keyword.take(opts, [:cd, :env])),
         :ok <- Subprocess.write_line(sub, Protocol.control_request("init", "initialize", %{})) do
      {:ok,
       %{
         v: @state_version,
         sub: sub,
         handler: Keyword.fetch!(opts, :handler),
         next_id: 1,
         pending: %{},
         # Tool input is echoed back on "allow", so keep it until the prompt is answered.
         permissions: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:control, subtype, params}, from, state) do
    id = "t3-#{state.next_id}"
    :ok = Subprocess.write_line(state.sub, Protocol.control_request(id, subtype, params))
    {:noreply, %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_cast({:user_message, content}, state) do
    :ok = Subprocess.write_line(state.sub, Protocol.user_message(content))
    {:noreply, state}
  end

  def handle_cast({:answer_permission, id, decision}, state) do
    case Map.pop(state.permissions, id) do
      {nil, _} ->
        {:noreply, state}

      {input, permissions} ->
        :ok = Subprocess.write_line(state.sub, Protocol.permission_reply(id, decision, input))
        {:noreply, %{state | permissions: permissions}}
    end
  end

  @impl true
  def handle_info({:subprocess_lines, _reader, lines}, state) do
    state = Enum.reduce(lines, state, &handle_line/2)
    Subprocess.ack(state.sub)
    {:noreply, state}
  end

  def handle_info({:subprocess_eof, _reader}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :closed})
    Subprocess.stop(state.sub)
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, Map.put(state, :v, @state_version)}

  defp handle_line(line, state) do
    case Protocol.decode(line) do
      {:control_response, "init", _reply} ->
        state

      {:control_response, id, reply} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, reply)
        %{state | pending: pending}

      {:permission, id, tool, input, context} ->
        notify(state, {:permission, id, tool, input, context})
        %{state | permissions: Map.put(state.permissions, id, input)}

      {:control_cancel, id} ->
        notify(state, {:permission_cancelled, id})
        %{state | permissions: Map.delete(state.permissions, id)}

      {:control_request, id, request} ->
        # Hooks and MCP-over-control are not wired yet; refuse rather than hang the turn.
        Subprocess.write_line(
          state.sub,
          JSON.encode_to_iodata!(%{
            "type" => "control_response",
            "response" => %{
              "subtype" => "error",
              "request_id" => id,
              "error" => "unsupported: #{request["subtype"]}"
            }
          })
        )

        state

      {:message, message} ->
        notify(state, {:message, message})
        state

      {:invalid, _} ->
        state
    end
  end

  defp notify(state, event), do: send(state.handler, {:claude, self(), event})
end
