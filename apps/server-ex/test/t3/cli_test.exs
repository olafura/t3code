defmodule T3.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, 0)
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Auth)
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    # The command line finds the node where it listens.
    Application.put_env(:t3, :port, port)
    on_exit(fn -> Application.put_env(:t3, :port, 0) end)
    %{port: port}
  end

  test "pairing works with the node stopped too", %{port: port} do
    out = capture_io(fn -> assert :ok = T3.CLI.run(["pair", "--admin"]) end)
    assert out =~ ~r{^http://127\.0\.0\.1:#{port}/pair#token=\S+\n$}
    [_, token] = Regex.run(~r/token=(\S+)/, out)
    assert {:ok, _, _, scopes} = T3.Auth.exchange(token)
    assert "relay:write" in scopes
  end

  test "projects are listed, added, renamed and removed on the running node", %{tmp_dir: dir} do
    root = Path.join(dir, "app")
    File.mkdir_p!(root)
    :ok = T3.Shell.subscribe(self())

    added =
      capture_io(fn -> assert :ok = T3.CLI.run(["project", "add", root, "--title", "App"]) end)

    [id | _] = String.split(added)
    assert added =~ "App"
    assert_receive {:t3_shell, {:rows, _, [{^id, {"project", _}}]}}, 1_000

    assert capture_io(fn -> T3.CLI.run(["project", "list"]) end) =~ "#{id}  App  #{root}"

    capture_io(fn -> assert :ok = T3.CLI.run(["project", "rename", id, "Renamed"]) end)
    assert_receive {:t3_shell, {:rows, _, [{^id, {"project", %{"title" => "Renamed"}}}]}}, 1_000
    assert capture_io(fn -> T3.CLI.run(["project", "list"]) end) =~ "Renamed"

    capture_io(fn -> assert :ok = T3.CLI.run(["project", "remove", id]) end)

    assert_receive {:t3_shell, {:rows, _, [{^id, {"project", %{"deletedAt" => deleted}}}]}}
                   when deleted != nil,
                   1_000

    refute capture_io(fn -> T3.CLI.run(["project", "list"]) end) =~ id

    assert {:error, message} = T3.CLI.run(["project", "rename", "nope", "x"])
    assert message =~ "unknown project"
  end

  test "sessions and T3 Connect state are read from the running node" do
    assert capture_io(fn -> T3.CLI.run(["auth", "session", "list"]) end) =~ "t3 command line"
    assert capture_io(fn -> T3.CLI.run(["connect", "status"]) end) =~ "Not linked"
    assert {:error, usage} = T3.CLI.run(["bogus"])
    assert usage =~ "t3ctl pair"
  end

  test "a node prints an administrative pairing URL when it starts", %{port: port} do
    out = capture_io(fn -> assert :ok = T3.Web.announce() end)

    assert [_, token] =
             Regex.run(~r{Pairing URL: http://127\.0\.0\.1:#{port}/pair#token=(\S+)}, out)

    assert {:ok, _, _, scopes} = T3.Auth.exchange(token)
    assert "access:write" in scopes

    # The desktop app signs its own window in instead.
    Application.put_env(:t3, :desktop_token, "t")
    on_exit(fn -> Application.delete_env(:t3, :desktop_token) end)
    assert capture_io(fn -> T3.Web.announce() end) == ""
  end

  test "the service runs the release's service script with the node's home" do
    plist = T3.CLI.launchd_plist("/opt/t3", "/Users/me/.t3/elixir")
    assert plist =~ "<string>/opt/t3/bin/t3-service</string>"
    assert plist =~ "<key>T3_HOME</key><string>/Users/me/.t3/elixir</string>"

    unit = T3.CLI.systemd_unit("/opt/t3", "/home/me/.t3/elixir")
    assert unit =~ "ExecStart=/opt/t3/bin/t3-service\n"
    assert unit =~ "Environment=T3_HOME=/home/me/.t3/elixir\n"
  end
end
