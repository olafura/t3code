defmodule T3.TailscaleServe do
  @moduledoc """
  Tailscale Serve for a node the desktop app runs with network access over the
  tailnet (`tailscaleServeEnabled` in its bootstrap, `T3.Desktop`): while the node
  runs, HTTPS on the tailnet at `tailscaleServePort` proxies to its loopback port,
  as the Node server arranges it. Failing to set it up is logged, not fatal.
  """

  use GenServer
  require Logger

  @timeout 15_000

  def start_link(serve_port), do: GenServer.start_link(__MODULE__, serve_port, name: __MODULE__)

  @doc "`tailscale serve` arguments that proxy `serve_port` to the local port."
  def serve_args(serve_port, local_port),
    do: ["serve", "--bg", "--https=#{serve_port}", "http://127.0.0.1:#{local_port}"]

  @impl true
  def init(serve_port) do
    Process.flag(:trap_exit, true)
    {:ok, %{serve_port: serve_port, configured: false}, {:continue, :serve}}
  end

  @impl true
  def handle_continue(:serve, state) do
    local_port = Application.get_env(:t3, :port, 3780)

    case tailscale(serve_args(state.serve_port, local_port)) do
      :ok ->
        Logger.info("Tailscale Serve configured: https #{state.serve_port} -> #{local_port}")
        {:noreply, %{state | configured: true}}

      {:error, reason} ->
        Logger.warning("could not configure Tailscale Serve: #{reason}")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{configured: true, serve_port: port}),
    do: tailscale(["serve", "--https=#{port}", "off"])

  def terminate(_reason, _state), do: :ok

  defp tailscale(args) do
    case System.find_executable("tailscale") do
      nil ->
        {:error, "tailscale is not installed"}

      exe ->
        task = Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end)

        case Task.yield(task, @timeout) || Task.shutdown(task) do
          {:ok, {_, 0}} -> :ok
          {:ok, {out, _}} -> {:error, String.trim(out)}
          nil -> {:error, "tailscale did not answer in time"}
        end
    end
  end
end
