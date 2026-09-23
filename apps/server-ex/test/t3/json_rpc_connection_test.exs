defmodule T3.JsonRpc.ConnectionTest do
  use ExUnit.Case, async: true

  alias T3.JsonRpc.Connection

  @peer Path.expand("../support/echo_rpc.py", __DIR__)

  setup do
    conn = start_supervised!({Connection, cmd: ["python3", "-u", @peer], handler: self()})
    %{conn: conn}
  end

  test "correlates responses with calls", %{conn: conn} do
    tasks = for i <- 1..20, do: Task.async(fn -> Connection.call(conn, "echo", %{"n" => i}) end)

    for {task, i} <- Enum.with_index(tasks, 1) do
      assert {:ok, %{"method" => "echo", "params" => %{"n" => ^i}}} = Task.await(task)
    end
  end

  test "forwards notifications to the handler", %{conn: conn} do
    assert {:ok, _} = Connection.call(conn, "notify_me", %{"step" => 1})
    assert_received {:json_rpc, ^conn, {:notification, "progress", %{"step" => 1}}}
  end

  test "server-to-client requests are answered by the handler", %{conn: conn} do
    call = Task.async(fn -> Connection.call(conn, "ask", %{"q" => "run ls?"}) end)
    assert_receive {:json_rpc, ^conn, {:request, id, "approve", %{"q" => "run ls?"}}}
    Connection.respond(conn, id, {:ok, "allow"})
    assert {:ok, %{"answer" => "allow"}} = Task.await(call)
  end

  test "stops and fails pending calls when the subprocess exits", %{conn: conn} do
    ref = Process.monitor(conn)
    System.cmd("kill", [to_string(Connection.os_pid(conn))])
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 2_000
  end
end
