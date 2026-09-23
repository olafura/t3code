defmodule T3.ClusterTest do
  # Starts a second BEAM node with its own store and joins it to this one.
  use ExUnit.Case, async: false

  alias T3.Test.WsClient

  @moduletag :tmp_dir
  @moduletag :cluster

  setup %{tmp_dir: dir} do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      # Unique names, so the test never collides with nodes running on this machine.
      {:ok, _} = Node.start(:"t3test#{System.unique_integer([:positive])}@127.0.0.1", :longnames)
    end

    Application.put_env(:t3, :home, Path.join(dir, "a"))
    Application.put_env(:t3, :port, 0)
    :persistent_term.erase({T3.Web, :token})
    start_supervised!({T3.Store, path: Path.join([dir, "a", "t3.sqlite"])})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))

    {:ok, peer, b} =
      :peer.start_link(%{
        name: :"t3peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: code_path_args()
      })

    # A peer node does not read Mix config, so it gets the node settings directly.
    for {key, value} <- [start_node: true, home: Path.join(dir, "b"), port: 0],
        do: :ok = :erpc.call(b, Application, :put_env, [:t3, key, value])

    {:ok, _} = :erpc.call(b, Application, :ensure_all_started, [:t3])
    %{port: port, peer: peer, b: b}
  end

  defp code_path_args, do: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

  test "one socket sees and follows threads on every node", %{port: port, peer: peer, b: b} do
    b_name = Atom.to_string(b)
    {:ok, client} = WsClient.connect(port, "/ws?token=#{T3.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)

    # A thread created on node b shows up in node a's shell.
    {:ok, _} =
      :erpc.call(b, T3.Streams, :commit, [
        "remote-th",
        :thread,
        [{"thread", "remote-th", %{"s" => %{"id" => "remote-th", "title" => "On b"}}}]
      ])

    client =
      WsClient.send_json(client, %{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}})

    # Node b's row arrives in the first shell frame or, if b is still computing it, just after.
    has_remote_row? = fn
      %{"t" => "shell", "rows" => rows} ->
        Enum.any?(rows, &match?([^b_name, "remote-th", "thread", %{"title" => "On b"}], &1))

      %{"t" => "shell.rows", "node" => ^b_name, "rows" => rows} ->
        Enum.any?(rows, &match?(["remote-th", "thread", %{"title" => "On b"}], &1))

      _ ->
        false
    end

    {_, _, client} = WsClient.recv_until(client, has_remote_row?)

    # Following it from node a streams events committed on node b.
    shape = %{"type" => "stream", "node" => b_name, "stream" => "remote-th"}
    client = WsClient.send_json(client, %{"t" => "sub", "id" => 2, "shape" => shape})

    {%{"t" => "live"}, _, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == 2))

    {:ok, seq} =
      :erpc.call(b, T3.Streams, :commit, [
        "remote-th",
        :thread,
        [{"turn-item", "i1", %{"s" => %{"text" => "from b"}}}]
      ])

    {events, _, client} = WsClient.recv_until(client, &(&1["t"] == "events" and &1["id"] == 2))
    assert [[^seq, "turn-item", "i1", %{"s" => %{"text" => "from b"}}, _at]] = events["events"]

    # Node a describes the whole cluster and serves node b's config by environment id.
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(~c"http://127.0.0.1:#{port}/.well-known/t3/environment")

    b_env = :erpc.call(b, T3.Environment, :id, [])
    assert %{"cluster" => cluster} = JSON.decode!(to_string(body))
    assert Enum.any?(cluster, &(&1["environmentId"] == b_env))

    client =
      WsClient.send_json(client, %{
        "t" => "sub",
        "id" => 3,
        "shape" => %{"type" => "config", "environment" => b_env}
      })

    {config, _, client} = WsClient.recv_until(client, &(&1["t"] == "config"))

    assert %{"node" => ^b_name, "config" => %{"environment" => %{"environmentId" => ^b_env}}} =
             config

    :peer.stop(peer)
    {down, _, _client} = WsClient.recv_until(client, &(&1["t"] == "shell.node"), 5_000)
    assert down == %{"t" => "shell.node", "id" => 1, "node" => b_name, "online" => false}
    assert Enum.any?(T3.Shell.rows(), &match?({{^b, "remote-th"}, _}, &1))
  end
end
