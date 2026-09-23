defmodule T3.Web.SocketTest do
  use ExUnit.Case, async: false

  alias T3.Test.WsClient

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, 0)
    :persistent_term.erase({T3.Web, :token})
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    %{port: port}
  end

  defp connect(port) do
    {:ok, client} = WsClient.connect(port, "/ws?token=#{T3.Web.token()}")
    {%{"t" => "hello", "protocol" => 3}, client} = WsClient.recv(client, 1_000)
    client
  end

  test "rejects connections without the access token", %{port: port} do
    assert {:error, 401} = WsClient.connect(port, "/ws?token=wrong")
  end

  test "shell lists threads and pushes changes", %{port: port} do
    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Streams.commit("th-1", :thread, [
        {"thread", "th-1", %{"s" => %{"id" => "th-1", "title" => "First"}}}
      ])

    assert_receive {:t3_shell, {:rows, _, [{"th-1", _}]}}, 1_000

    client =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}})

    {shell, client} = WsClient.recv(client, 1_000)
    me = Atom.to_string(node())

    assert %{
             "t" => "shell",
             "rows" => [[^me, "th-1", "thread", %{"title" => "First"}]],
             "nodes" => [
               %{"node" => ^me, "online" => true, "environment" => %{"environmentId" => _}}
             ]
           } = shell

    {:ok, _} =
      T3.Streams.commit("th-1", :thread, [{"thread", "th-1", %{"s" => %{"title" => "Renamed"}}}])

    assert {%{"t" => "shell.rows", "rows" => [["th-1", "thread", %{"title" => "Renamed"}]]}, _} =
             WsClient.recv(client, 1_000)
  end

  test "a stream snapshot, then live tokens, then a resume that merges what was missed", %{
    port: port
  } do
    {:ok, _} =
      T3.Streams.commit("th-2", :thread, [{"turn-item", "i1", %{"s" => %{"text" => ""}}}])

    me = Atom.to_string(node())
    shape = %{"type" => "stream", "node" => me, "stream" => "th-2"}
    client = connect(port) |> WsClient.send_json(%{"t" => "sub", "id" => 7, "shape" => shape})

    {%{"t" => "live", "offset" => offset}, [snapshot], client} =
      WsClient.recv_until(client, &(&1["t"] == "live"))

    assert %{
             "t" => "snapshot",
             "part" => 0,
             "done" => true,
             "rows" => [["turn-item", "i1", %{"text" => ""}]]
           } = snapshot

    last =
      Enum.reduce(~w(Hel lo , world), 0, fn tok, _ ->
        {:ok, seq} =
          T3.Streams.commit("th-2", :thread, [{"turn-item", "i1", %{"a" => %{"text" => tok}}}])

        seq
      end)

    {frames, _client} = collect_events(client, last, [])

    patches =
      for %{"events" => events} <- frames,
          [_seq, "turn-item", "i1", patch, _at] <- events,
          do: patch

    assert Enum.reduce(patches, %{"text" => ""}, &T3.Patch.apply(&2, &1))["text"] == "Hello,world"

    # A new connection resuming from the first offset gets only what it missed, merged.
    resumed =
      connect(port)
      |> WsClient.send_json(%{"t" => "sub", "id" => 1, "shape" => shape, "offset" => offset})

    {%{"t" => "live", "offset" => ^last}, skipped, _} =
      WsClient.recv_until(resumed, &(&1["t"] == "live"))

    assert [
             %{
               "t" => "events",
               "events" => [[^last, "turn-item", "i1", %{"a" => %{"text" => "Hello,world"}}, _at]]
             }
           ] = skipped
  end

  defp collect_events(client, last, acc) do
    {frame, client} = WsClient.recv(client, 1_000)
    acc = [frame | acc]

    if frame["offset"] == last,
      do: {Enum.reverse(acc), client},
      else: collect_events(client, last, acc)
  end
end
