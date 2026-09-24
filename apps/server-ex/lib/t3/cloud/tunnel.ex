defmodule T3.Cloud.Tunnel do
  @moduledoc """
  Runs the managed tunnel a T3 Connect link asks for: `cloudflared tunnel run` with
  the relay's connector token, serving this node's loopback port. It starts again
  when it exits, at once after a stable run and with a backoff (1 s doubling to
  60 s) while it keeps failing within 30 s, as the Node server does. A node that
  boots with a stored link starts its tunnel again (`T3.Cloud.stored_endpoint_runtime/0`).

  `apply/1` answers with the contracts' managed endpoint status: `disabled`,
  `unsupported` (not a Cloudflare tunnel), `failed` (no relay client), or
  `running` with the connector's OS pid.
  """

  use GenServer
  require Logger

  @stable_uptime 30_000
  @backoff_base 1_000
  @backoff_max 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Runs the tunnel `config` describes, or none for nil; returns its status."
  def apply(config), do: GenServer.call(__MODULE__, {:apply, config}, 30_000)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{config: nil, sub: nil, started_at: nil, backoff: 0}, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state) do
    case T3.Cloud.stored_endpoint_runtime() do
      nil -> {:noreply, state}
      config -> {:noreply, reconcile(state, config) |> elem(1)}
    end
  end

  @impl true
  def handle_call({:apply, config}, _from, state) do
    {status, state} = reconcile(state, config)
    {:reply, status, state}
  end

  @impl true
  def handle_info({:subprocess_lines, _reader, lines}, %{sub: sub} = state) when sub != nil do
    for line <- lines, line = String.trim(line), line != "" do
      output = String.replace(line, state.config["connectorToken"], "<redacted>")

      cond do
        line =~ ~r/\bRegistered tunnel connection\b/i ->
          Logger.info("relay client tunnel connection registered: #{output}")

        line =~ ~r/\b(?:ERR|WRN|FTL|PNC)\b/ ->
          Logger.warning("relay client: #{output}")

        true ->
          Logger.debug("relay client: #{output}")
      end
    end

    T3.Subprocess.ack(sub)
    {:noreply, state}
  end

  def handle_info({:subprocess_eof, reader}, %{sub: %{reader: reader} = sub} = state) do
    T3.Subprocess.stop(sub)
    uptime = System.monotonic_time(:millisecond) - state.started_at

    backoff =
      cond do
        uptime >= @stable_uptime -> 0
        state.backoff == 0 -> @backoff_base
        true -> min(state.backoff * 2, @backoff_max)
      end

    Logger.warning("relay client exited after #{uptime} ms; restarting in #{backoff} ms")
    Process.send_after(self(), {:restart, state.config}, backoff)
    {:noreply, %{state | sub: nil, backoff: backoff}}
  end

  def handle_info({:restart, config}, %{config: config, sub: nil} = state),
    do: {:noreply, reconcile(state, config) |> elem(1)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop(state)

  defp reconcile(
         state,
         %{"providerKind" => "cloudflare_tunnel", "connectorToken" => token} = config
       )
       when is_binary(token) do
    if state.sub != nil and same?(state.config, config) do
      {running(state), state}
    else
      state = stop(state)

      case T3.Cloud.RelayClient.status() do
        %{"status" => "available", "executablePath" => path} ->
          start(%{state | config: config}, path)

        relay_client ->
          reason =
            if relay_client["status"] == "unsupported",
              do:
                "Relay client is unsupported on #{relay_client["platform"]}-#{relay_client["arch"]}.",
              else: "The relay client is not installed."

          {status(config, %{"status" => "failed", "reason" => reason}), %{state | config: config}}
      end
    end
  end

  defp reconcile(state, nil), do: {%{"status" => "disabled"}, %{stop(state) | config: nil}}

  defp reconcile(state, config),
    do:
      {%{"status" => "unsupported", "providerKind" => config["providerKind"]},
       %{stop(state) | config: nil}}

  defp start(state, path) do
    case T3.Subprocess.start([path, "tunnel", "run"],
           env: [{"TUNNEL_TOKEN", state.config["connectorToken"]}],
           stderr: :redirect_to_stdout
         ) do
      {:ok, sub} ->
        state = %{state | sub: sub, started_at: System.monotonic_time(:millisecond)}
        Logger.info("relay client started; waiting for the tunnel connection")
        {running(state), state}

      {:error, reason} ->
        {status(state.config, %{"status" => "failed", "reason" => inspect(reason)}), state}
    end
  end

  defp stop(%{sub: nil} = state), do: state

  defp stop(%{sub: sub} = state) do
    T3.Subprocess.stop(sub)
    %{state | sub: nil, backoff: 0}
  end

  defp running(state),
    do:
      status(state.config, %{
        "status" => "running",
        "pid" => T3.Subprocess.os_pid(state.sub)
      })

  defp status(config, fields) do
    Map.merge(
      %{"providerKind" => "cloudflare_tunnel"},
      Map.take(config, ["tunnelId", "tunnelName"])
    )
    |> Map.merge(fields)
  end

  defp same?(nil, _), do: false

  defp same?(a, b),
    do:
      Map.take(a, ~w(providerKind connectorToken tunnelId tunnelName)) ==
        Map.take(b, ~w(providerKind connectorToken tunnelId tunnelName))
end
