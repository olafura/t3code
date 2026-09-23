defmodule T3.LocalServers do
  @moduledoc """
  Web servers listening on this host (`subscribeDiscoveredLocalServers`), for the
  preview panel's suggestions. While anyone watches, `lsof` lists listening TCP
  ports every few seconds and each new one is asked for a page; those answering
  with HTML are the list. Watchers get `{:t3_local_servers, node, list}` when it
  changes.
  """

  use GenServer

  @interval 3_000
  @probe_timeout 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  @impl true
  def init(nil) do
    # Its own HTTP client profile, which also reaches servers bound to IPv6 only.
    case :inets.start(:httpc, profile: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok = :httpc.set_options([ipfamily: :inet6fb4], __MODULE__)
    {:ok, %{watchers: %{}, list: nil, probes: %{}, timer: nil}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    state = %{state | watchers: watchers}
    state = if state.list, do: state, else: scan(state)
    {:reply, {:ok, state.list}, schedule(state)}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info(:scan, state) do
    state = %{state | timer: nil}

    if state.watchers == %{} do
      {:noreply, %{state | list: nil, probes: %{}}}
    else
      previous = state.list && state.list["servers"]
      state = scan(state)

      if state.list["servers"] != previous,
        do:
          for({pid, _} <- state.watchers, do: send(pid, {:t3_local_servers, node(), state.list}))

      {:noreply, schedule(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :scan, @interval)}

  defp schedule(state), do: state

  defp scan(state) do
    listeners = listeners()

    # A port answers the same way while the same process holds it; new ones are
    # asked at once.
    known = Map.take(state.probes, listeners)

    probes =
      listeners
      |> Enum.reject(&Map.has_key?(known, &1))
      |> Task.async_stream(fn {port, _, _, ipv6} = key -> {key, web?(port, ipv6)} end,
        timeout: @probe_timeout * 2,
        on_timeout: :kill_task
      )
      |> Enum.reduce(known, fn
        {:ok, {key, web}}, probes -> Map.put(probes, key, web)
        _, probes -> probes
      end)

    servers =
      for {port, pid, name, _} = key <- listeners, probes[key] do
        %{
          "host" => "localhost",
          "port" => port,
          "url" => "http://localhost:#{port}",
          "processName" => name,
          "pid" => pid,
          "terminal" => nil
        }
      end
      |> Enum.sort_by(& &1["port"])

    %{state | probes: probes, list: %{"servers" => servers, "scannedAt" => now()}}
  end

  # `{port, pid, command, ipv6_only}` for every loopback or wildcard TCP listener.
  defp listeners do
    with path when is_binary(path) <- System.find_executable("lsof"),
         {out, _} <-
           System.cmd(path, ~w(-iTCP -sTCP:LISTEN -P -n -F pcn), stderr_to_stdout: false) do
      out
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, nil, []}, fn
        "p" <> pid, {_, _, acc} -> {String.to_integer(pid), nil, acc}
        "c" <> name, {pid, _, acc} -> {pid, name, acc}
        "n" <> address, {pid, name, acc} -> {pid, name, [{address, pid, name} | acc]}
        _, acc -> acc
      end)
      |> elem(2)
      |> Enum.flat_map(fn {address, pid, name} ->
        case Regex.run(~r/^(\*|127\.0\.0\.1|\[::1\]|\[::\]|localhost):(\d+)$/, address) do
          [_, _host, port] -> [{String.to_integer(port), pid, name, ipv6?(address)}]
          _ -> []
        end
      end)
      # This node's own port is not a suggestion.
      |> Enum.reject(fn {port, _, _, _} -> port == Application.get_env(:t3, :port, 3780) end)
      |> Enum.group_by(&elem(&1, 0))
      # A port bound on both stacks is asked over IPv4.
      |> Enum.map(fn {port, [{_, pid, name, _} | _] = entries} ->
        {port, pid, name, Enum.all?(entries, &elem(&1, 3))}
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp ipv6?(address), do: String.starts_with?(address, "[")

  defp web?(port, ipv6) do
    host = if ipv6, do: "[::1]", else: "127.0.0.1"

    case :httpc.request(
           :get,
           {~c"http://#{host}:#{port}/", []},
           [timeout: @probe_timeout, autoredirect: false],
           [ipv6_host_with_brackets: true],
           __MODULE__
         ) do
      {:ok, {{_, status, _}, headers, _}} when status in 200..399 and status not in [204, 205] ->
        status >= 300 or
          Enum.any?(headers, fn {key, value} ->
            key == ~c"content-type" and String.contains?(to_string(value), "html")
          end)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
