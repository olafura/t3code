defmodule T3.Orchestration.TurnWriterTest do
  use ExUnit.Case, async: false

  alias T3.Orchestration.TurnWriter
  alias T3.StreamState

  @moduletag :tmp_dir

  test "only whole paragraphs and closed code fences are ready" do
    assert TurnWriter.split_ready("First") == {"", "First"}
    assert TurnWriter.split_ready("First\n\nSec") == {"First\n\n", "Sec"}
    assert TurnWriter.split_ready("Intro\n\n```ts\nx()\n\n") == {"Intro\n\n", "```ts\nx()\n\n"}
    assert TurnWriter.split_ready("```ts\nx()\n```\nrest") == {"```ts\nx()\n```\n", "rest"}
    # A no-break space is content, not a blank line.
    assert TurnWriter.split_ready("a\n \nb") == {"", "a\n \nb"}
  end

  describe "timed flushes" do
    setup %{tmp_dir: dir} do
      start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
      start_supervised!(T3.Streams)

      {:ok, _} =
        T3.Streams.commit("t1", :thread, [
          {"turn-item", "i1", %{"s" => %{"id" => "i1", "text" => ""}}},
          {"turn-item", "i2", %{"s" => %{"id" => "i2", "output" => ""}}}
        ])

      :ok
    end

    defp state(mode) do
      %{
        thread_id: "t1",
        turn: %{streaming_mode: mode},
        items: %{
          "a" => %{id: "i1", message: nil, kind: :assistant},
          "c" => %{id: "i2", message: nil, kind: :command}
        },
        buffer: %{},
        flush_timer: nil
      }
    end

    defp text(id) do
      StreamState.get(T3.Streams.Server.state(T3.Streams.ensure("t1")), "turn-item")[id]
    end

    test "paragraph mode writes finished paragraphs; the rest waits for the item's end" do
      state =
        state("paragraph")
        |> TurnWriter.buffer("a", "text", "First\n\nSec")
        |> TurnWriter.buffer("c", "output", "$ ls\n")
        |> TurnWriter.flush(:timer)

      assert text("i1")["text"] == "First\n\n"
      # Tool output is not held back.
      assert text("i2")["output"] == "$ ls\n"

      state = state |> TurnWriter.buffer("a", "text", "ond\n\nThi") |> TurnWriter.flush(:timer)
      # Within 400 ms of the last paragraph nothing more is written.
      assert text("i1")["text"] == "First\n\n"

      _ = TurnWriter.flush(state)
      assert text("i1")["text"] == "First\n\nSecond\n\nThi"
    end

    test "turn mode writes assistant text only at a boundary" do
      state =
        state("turn") |> TurnWriter.buffer("a", "text", "One\n\nTwo") |> TurnWriter.flush(:timer)

      assert text("i1")["text"] == ""
      _ = TurnWriter.flush(state)
      assert text("i1")["text"] == "One\n\nTwo"
    end
  end
end
