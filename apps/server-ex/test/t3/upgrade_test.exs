defmodule T3.UpgradeTest do
  use ExUnit.Case, async: false

  alias T3.Upgrade
  alias T3.Upgrade.Source

  @moduletag :tmp_dir

  @manifest %{
    "version" => "2.0.0",
    "otpRelease" => "29",
    "erts" => "17.0.5",
    "platform" => "darwin-arm64",
    "applications" => %{"t3" => "2.0.0", "kernel" => "11.0.3"},
    "nifs" => %{"t3" => "a", "kernel" => "b"},
    "config" => "c"
  }

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    # The tests load several versions of the same module.
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, false) end)
    :ok
  end

  # A bundle holding `modules` ({new source, running source}) compiled into
  # lib/t3-2.0.0/ebin; the running version stays loaded.
  defp bundle(dir, manifest, modules) do
    root = Path.join(dir, "bundle")
    ebin = Path.join([root, "lib", "t3-2.0.0", "ebin"])
    rel = Path.join([root, "releases", manifest["version"]])
    File.mkdir_p!(ebin)
    File.mkdir_p!(rel)
    File.write!(Path.join(rel, "upgrade.json"), JSON.encode!(manifest))

    for {source, running} <- modules do
      for {mod, bin} <- Code.compile_string(source),
          do: File.write!(Path.join(ebin, "#{mod}.beam"), bin)

      Code.compile_string(running)
    end

    root
  end

  test "a change to plain modules loads in place; a supervisor or runtime change restarts",
       %{tmp_dir: dir} do
    running_plain = "defmodule T3.UpgradeTest.Plain do def v, do: 1 end"

    running_tree =
      "defmodule T3.UpgradeTest.Tree do use Supervisor; def init(_), do: Supervisor.init([], strategy: :one_for_one) end"

    Code.compile_string(running_plain)
    Code.compile_string(running_tree)

    plain = {"defmodule T3.UpgradeTest.Plain do def v, do: 2 end", running_plain}

    assert {:hot, [T3.UpgradeTest.Plain]} =
             Upgrade.plan(bundle(dir, @manifest, [plain]), @manifest)

    File.rm_rf!(Path.join(dir, "bundle"))

    tree =
      {"defmodule T3.UpgradeTest.Tree do use Supervisor; def init(_), do: Supervisor.init([{Task, fn -> :ok end}], strategy: :one_for_one) end",
       running_tree}

    assert {:restart, [reason]} = Upgrade.plan(bundle(dir, @manifest, [plain, tree]), @manifest)
    assert reason =~ "T3.UpgradeTest.Tree supervises processes"

    File.rm_rf!(Path.join(dir, "bundle"))
    newer_runtime = Map.put(@manifest, "erts", "18.0")
    assert {:restart, reasons} = Upgrade.plan(bundle(dir, newer_runtime, [plain]), @manifest)
    assert "the Erlang runtime changes" in reasons

    assert {:restart, ["the running release has no upgrade manifest"]} =
             Upgrade.plan(Path.join(dir, "bundle"), nil)
  end

  test "a node run from a checkout does not install versions" do
    start_supervised!(Upgrade)

    assert {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} =
             Upgrade.update(%{"targetVersion" => "9.9.9"})

    assert reason =~ "mix t3.upgrade"
    assert Upgrade.capability() == nil
  end

  test "a bundle arrives in pieces, is checked, and is offered to peers once", %{tmp_dir: dir} do
    archive = Path.join(dir, "b.tar.gz")
    File.write!(archive, :crypto.strong_rand_bytes(600_000))
    sum = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

    :ok = Source.receive_part("2.0.0", "darwin-arm64", :begin)

    archive
    |> File.stream!(256 * 1024)
    |> Enum.each(&(:ok = Source.receive_part("2.0.0", "darwin-arm64", {:chunk, &1})))

    assert :ok = Source.receive_part("2.0.0", "darwin-arm64", {:finish, sum})

    assert %{"sha256" => ^sum, "path" => "/api/upgrade/" <> token} =
             Source.offer("2.0.0", "darwin-arm64")

    assert {:ok, path} = Source.take(token)
    assert File.read!(path) == File.read!(archive)
    # A link works once.
    assert Source.take(token) == :error

    :ok = Source.receive_part("2.0.0", "darwin-arm64", :begin)
    :ok = Source.receive_part("2.0.0", "darwin-arm64", {:chunk, "damaged"})
    assert {:error, _} = Source.receive_part("2.0.0", "darwin-arm64", {:finish, sum})
  end

  test "a socket opened before an upgrade keeps its subscriptions" do
    # Its state as the previous version kept it: one id per watched config.
    old = %{
      session: nil,
      subs: %{1 => {:config, node()}},
      by_stream: %{},
      by_terminal: %{{:settings, node()} => 1},
      buffers: %{},
      item_types: %{},
      flush_scheduled: false
    }

    assert {:push, [{:text, frame}], state} =
             T3.Web.Socket.handle_info({:t3_keybindings, node(), []}, old)

    assert %{"t" => "config.keybindings", "id" => 1} = JSON.decode!(IO.iodata_to_binary(frame))
    assert state.v == 1
    assert state.by_terminal[{:settings, node()}] == [1]
  end
end
