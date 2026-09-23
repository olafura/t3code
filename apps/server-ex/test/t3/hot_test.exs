defmodule T3.HotTest do
  # Reloads a module shared by the whole VM, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias T3.JsonRpc.Connection

  @peer Path.expand("../support/echo_rpc.py", __DIR__)
  @source Path.expand("../../lib/t3/json_rpc/connection.ex", __DIR__)

  @tag :tmp_dir
  test "upgrades a live connection in place without restarting its subprocess", %{tmp_dir: dir} do
    conn = start_supervised!({Connection, cmd: ["python3", "-u", @peer], handler: self()})
    assert {:ok, _} = Connection.call(conn, "echo", 1)
    os_pid = Connection.os_pid(conn)
    assert %{v: 1} = :sys.get_state(conn)

    # A call in flight across the upgrade must still be answered afterwards.
    in_flight = Task.async(fn -> Connection.call(conn, "ask", "mid-upgrade") end)
    assert_receive {:json_rpc, ^conn, {:request, srv_id, "approve", "mid-upgrade"}}

    v2 =
      compile_variant(dir, fn src ->
        String.replace(src, "@state_version 1", "@state_version 2")
      end)

    assert {:ok, report} = T3.Hot.reload(v2)
    assert report.changed == [Connection]
    assert conn in report.migrated

    assert %{v: 2} = :sys.get_state(conn)
    assert Connection.os_pid(conn) == os_pid
    Connection.respond(conn, srv_id, {:ok, "yes"})
    assert {:ok, %{"answer" => "yes"}} = Task.await(in_flight)
    assert {:ok, %{"params" => 2}} = Connection.call(conn, "echo", 2)

    # Reloading identical code is a no-op.
    assert {:ok, %{changed: []}} = T3.Hot.reload(v2)
  after
    # Put the original module back for any later test in this VM.
    T3.Hot.reload(T3.Hot.beams_from_dir(Application.app_dir(:t3, "ebin")))
  end

  defp compile_variant(dir, edit) do
    src = Path.join(dir, "connection.ex")
    File.write!(src, edit.(File.read!(@source)))
    # Compile in a separate VM so the new version is not loaded until reload/1.
    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", dir, src], stderr_to_stdout: true)

    dir |> T3.Hot.beams_from_dir() |> Enum.filter(fn {mod, _} -> mod == Connection end)
  end
end
