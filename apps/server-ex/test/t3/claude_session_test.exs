defmodule T3.Claude.SessionTest do
  # Drives the real `claude` CLI with Haiku; each test costs a few cents.
  use ExUnit.Case, async: true

  alias T3.Claude.Session

  @moduletag :claude
  @moduletag timeout: 180_000

  defp start_session(dir) do
    start_supervised!(
      {Session,
       handler: self(),
       cd: dir,
       model: "haiku",
       permission_mode: "default",
       persist_session: false}
    )
  end

  @tag :tmp_dir
  test "a denied tool permission reaches the model and nothing is written", %{tmp_dir: dir} do
    session = start_session(dir)

    Session.send_message(
      session,
      "Use the Write tool to create the file probe.txt containing hi. If you cannot, reply BLOCKED."
    )

    assert_receive {:claude, ^session, {:permission, id, "Write", %{"file_path" => path}, _}},
                   60_000

    assert Path.basename(path) == "probe.txt"
    Session.answer_permission(session, id, {:deny, "The user declined this write."})

    result = await_result(session)
    assert result["subtype"] == "success"
    refute File.exists?(Path.join(dir, "probe.txt"))
  end

  @tag :tmp_dir
  test "interrupt ends a running turn", %{tmp_dir: dir} do
    session = start_session(dir)
    Session.send_message(session, "Use the Write tool to create the file slow.txt containing hi.")

    # Hold the permission prompt open, then interrupt while the turn is waiting on us.
    assert_receive {:claude, ^session, {:permission, _id, "Write", _, _}}, 60_000
    assert {:ok, _} = Session.control(session, "interrupt")
    assert %{"type" => "result"} = await_result(session)
  end

  defp await_result(session) do
    receive do
      {:claude, ^session, {:message, %{"type" => "result"} = result}} -> result
      {:claude, ^session, _other} -> await_result(session)
    after
      90_000 -> flunk("no result message")
    end
  end
end
