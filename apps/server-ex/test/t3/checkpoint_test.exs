defmodule T3.CheckpointTest do
  use ExUnit.Case, async: true

  alias T3.Checkpoint

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git!(dir, ~w(init -q -b main))
    File.write!(Path.join(dir, "a.txt"), "one\n")
    git!(dir, ~w(add a.txt))
    git!(dir, ~w(-c user.name=t -c user.email=t@t commit -q -m init))
    %{dir: dir}
  end

  test "ids and refs match the Node server's" do
    scope = Checkpoint.scope_id("thread-1")
    assert scope == "checkpoint-scope:thread:thread-1:name:root"

    assert Checkpoint.checkpoint_id(scope, 2) ==
             "checkpoint:scope:checkpoint-scope%3Athread%3Athread-1%3Aname%3Aroot:name:2"

    # sha256(scope)[0..32] as hex, then base64url.
    assert Checkpoint.ref(scope, 0) =~
             ~r"^refs/t3/orchestration-v2/checkpoints/[A-Za-z0-9_-]{43}/ordinal/0$"
  end

  test "captures leave the user's index alone and summarize each run", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    File.write!(Path.join(dir, "staged.txt"), "staged\n")
    git!(dir, ~w(add staged.txt))

    assert :ok = Checkpoint.baseline(dir, scope, 0)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(dir, "new.txt"), "x\ny\n")

    checkpoint = Checkpoint.capture_run(dir, scope, 1, "run-1", "node-1", "t", nil)

    assert checkpoint["status"] == "ready"
    assert checkpoint["parentCheckpointId"] == Checkpoint.checkpoint_id(scope, 0)

    assert checkpoint["files"] == [
             %{"path" => "a.txt", "kind" => "modified", "additions" => 1, "deletions" => 0},
             %{"path" => "new.txt", "kind" => "modified", "additions" => 2, "deletions" => 0}
           ]

    assert git!(dir, ~w(diff --cached --name-only)) == "staged.txt\n"
  end

  test "turn diffs between checkpoints", %{dir: dir} do
    scope = Checkpoint.scope_id("t")
    :ok = Checkpoint.baseline(dir, scope, 0)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    first = Checkpoint.capture_run(dir, scope, 1, "run-1", "n", "t", nil)
    File.write!(Path.join(dir, "b.txt"), "b\n")
    second = Checkpoint.capture_run(dir, scope, 2, "run-2", "n", "t", nil)

    state = %T3.StreamState{
      entities: %{
        "run" => %{
          "run-1" => %{"id" => "run-1", "status" => "completed"},
          "run-2" => %{"id" => "run-2", "status" => "completed"}
        },
        "checkpoint" => %{first["id"] => first, second["id"] => second},
        "checkpoint-scope" => %{
          scope => Checkpoint.scope("t", "run-2", "n", "pt", dir, "2026-01-01T00:00:00Z")
        }
      }
    }

    assert {:ok, %{"diff" => whole}} = Checkpoint.turn_diff(state, "t", 0, 2)
    assert whole =~ "+++ b/a.txt"
    assert whole =~ "+++ b/b.txt"

    assert {:ok, %{"diff" => last}} = Checkpoint.turn_diff(state, "t", 1, 2)
    refute last =~ "a.txt"
    assert last =~ "+b"

    assert {:ok, %{"diff" => ""}} = Checkpoint.turn_diff(state, "t", 2, 2)
    assert {:error, _} = Checkpoint.turn_diff(state, "t", 0, 3)
  end

  test "outside a repository the checkpoint is missing" do
    # tmp_dir sits inside this repository's checkout, so use the system temp dir.
    outside = System.tmp_dir!() |> Path.join("t3-no-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    scope = Checkpoint.scope_id("t")
    assert Checkpoint.capture_run(outside, scope, 1, "r", "n", "t", nil)["status"] == "missing"
  end

  test "parses renames in numstat" do
    numstat = "3\t1\tsrc.ex\u00000\t0\t\u0000old.ex\u0000new.ex\u0000-\t-\timg.png\u0000"

    assert Checkpoint.numstat_files(numstat) == [
             %{"path" => "img.png", "kind" => "modified", "additions" => 0, "deletions" => 0},
             %{"path" => "new.ex", "kind" => "modified", "additions" => 0, "deletions" => 0},
             %{"path" => "src.ex", "kind" => "modified", "additions" => 3, "deletions" => 1}
           ]
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    out
  end
end
