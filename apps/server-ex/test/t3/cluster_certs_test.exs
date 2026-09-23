defmodule T3.ClusterCertsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "invited members trust each other and reject a foreign cluster", %{tmp_dir: dir} do
    [a, b, stranger] = for n <- ~w(a b stranger), do: Path.join(dir, n)
    :ok = T3.Cluster.init(a, "127.0.0.1")
    :ok = T3.Cluster.join(b, T3.Cluster.invite(a, "127.0.0.2"))
    :ok = T3.Cluster.init(stranger, "127.0.0.1")

    assert T3.Cluster.address(b) == "127.0.0.2"
    refute File.exists?(Path.join(T3.Cluster.dir(b), "ca.key"))
    assert T3.Cluster.vm_args(b) =~ "-proto_dist inet_tls"

    # The generated dist config is what the VM will read; handshake with it directly.
    assert {{:ok, _}, {:ok, _}} = handshake(server: a, client: b)
    assert {_, {:error, _}} = handshake(server: a, client: stranger)
  end

  # Returns {client_result, server_result}. The server side is where a client
  # certificate from another CA is rejected.
  defp handshake(server: server_home, client: client_home) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    {:ok, listen} =
      :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ dist_opts(server_home, :server))

    {:ok, {_, port}} = :ssl.sockname(listen)

    acceptor =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listen, 5_000)
        :ssl.handshake(socket, 5_000)
      end)

    client =
      :ssl.connect(
        ~c"127.0.0.1",
        port,
        [:binary, active: false] ++ dist_opts(client_home, :client),
        5_000
      )

    server = Task.await(acceptor)
    :ssl.close(listen)
    {client, server}
  end

  defp dist_opts(home, side) do
    {:ok, [conf]} = :file.consult(to_charlist(Path.join(T3.Cluster.dir(home), "ssl_dist.conf")))
    Keyword.fetch!(conf, side)
  end
end
