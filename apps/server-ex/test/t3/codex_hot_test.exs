defmodule T3.CodexHotTest do
  use ExUnit.Case, async: false

  alias T3.JsonRpc.Connection

  @moduletag :codex
  @source Path.expand("../../lib/t3/json_rpc/connection.ex", __DIR__)

  @tag :tmp_dir
  test "a real codex app-server survives a hot upgrade of its connection", %{tmp_dir: dir} do
    conn = start_supervised!({Connection, cmd: ["codex", "app-server"], handler: self()})

    assert {:ok, %{"userAgent" => _}} =
             Connection.call(conn, "initialize", %{
               "clientInfo" => %{"name" => "t3code_elixir_spike", "version" => "0.0.0"}
             })

    Connection.notify(conn, "initialized", nil)
    assert {:ok, %{"data" => [_ | _] = models}} = Connection.call(conn, "model/list", %{})
    os_pid = Connection.os_pid(conn)

    src = Path.join(dir, "connection.ex")
    File.write!(src, String.replace(File.read!(@source), "@state_version 1", "@state_version 2"))

    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", dir, src], stderr_to_stdout: true)

    assert {:ok, %{migrated: [^conn]}} = T3.Hot.reload(T3.Hot.beams_from_dir(dir))

    assert %{v: 2} = :sys.get_state(conn)
    assert Connection.os_pid(conn) == os_pid
    assert {:ok, %{"data" => ^models}} = Connection.call(conn, "model/list", %{})
  after
    T3.Hot.reload(T3.Hot.beams_from_dir(Application.app_dir(:t3, "ebin")))
  end
end
