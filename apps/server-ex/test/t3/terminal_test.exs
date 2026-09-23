defmodule T3.TerminalTest do
  use ExUnit.Case, async: false

  alias T3.Terminal
  alias T3.Terminal.History

  describe "history" do
    test "drops terminal queries and replies but keeps what draws" do
      colored = "\e[1;32mok\e[0m"
      queries = "\e[6n\e[12;5R\e[c\e[>0;276;0c\e]11;?\a\e]10;rgb:ffff/ffff/ffff\e\\\eP$qm\e\\"
      assert {^colored, ""} = History.sanitize("", queries <> colored)
      # A window title (OSC 2) and DECSCUSR stay.
      assert {"\e]2;title\a\e[2 q", ""} = History.sanitize("", "\e]2;title\a\e[2 q")
    end

    test "holds a sequence split across reads until it completes" do
      assert {"a", "\e[12;"} = History.sanitize("", "a\e[12;")
      assert {"b", ""} = History.sanitize("\e[12;", "5Rb")
      assert {"", "\e]11;?"} = History.sanitize("", "\e]11;?")
    end

    test "keeps the last lines and bytes" do
      history = History.new("", max_lines: 3, max_bytes: 1_000)
      history = Enum.reduce(1..5, history, &History.append(&2, "line #{&1}\n"))
      assert History.value(history) == "line 3\nline 4\nline 5\n"

      history = History.new("", max_lines: 100, max_bytes: 8)
      history = History.append(history, "ab€cdefgh")
      # Never cuts through a character.
      assert History.value(history) == "cdefgh"
    end

    test "PTY reads split inside a character are carried to the next read" do
      <<first::binary-size(2), rest::binary>> = "€x"
      assert {"", ^first} = History.utf8("", first)
      assert {"€x", ""} = History.utf8(first, rest)
      assert {"�a", ""} = History.utf8("", <<0xFF, ?a>>)
    end
  end

  describe "sessions" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      previous_shell = System.get_env("SHELL")
      System.put_env("SHELL", "/bin/sh")
      Application.put_env(:t3, :home, dir)

      on_exit(fn ->
        if previous_shell, do: System.put_env("SHELL", previous_shell)
      end)

      start_supervised!({Registry, keys: :unique, name: T3.Terminal.Registry})
      start_supervised!({DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one})
      start_supervised!(T3.Terminal.Hub)
      %{input: %{"threadId" => "thread-1", "terminalId" => "term-1", "cwd" => dir}}
    end

    test "a shell runs commands, resizes, clears, and reports its exit", %{input: input} do
      assert {:ok, %{"status" => "running", "pid" => pid, "label" => "Terminal 1"}} =
               Terminal.attach(Map.merge(input, %{"cols" => 80, "rows" => 24}), self())

      assert is_integer(pid)

      {:ok, nil} = Terminal.write(Map.put(input, "data", "stty size; echo hi-$((1+2))\n"))
      output = await_output("hi-3")
      assert output =~ "24 80"

      {:ok, nil} = Terminal.resize(Map.merge(input, %{"cols" => 100, "rows" => 30}))
      {:ok, nil} = Terminal.write(Map.put(input, "data", "stty size\n"))
      await_output("30 100")

      {:ok, snapshot} = Terminal.open(input)
      assert snapshot["history"] =~ "hi-3"

      {:ok, nil} = Terminal.clear(input)
      assert_receive {:t3_terminal, {"thread-1", "term-1"}, %{"type" => "cleared"}}
      assert {:ok, %{"history" => ""}} = Terminal.open(input)

      {:ok, nil} = Terminal.write(Map.put(input, "data", "exit 3\n"))

      assert_receive {:t3_terminal, _, %{"type" => "exited", "exitCode" => 3}}, 5_000

      assert {:error, %{"_tag" => "TerminalNotRunningError"}} =
               Terminal.write(Map.put(input, "data", "x"))

      # Opening an exited terminal starts a fresh shell.
      assert {:ok, %{"status" => "running"}} = Terminal.open(input)
      assert_receive {:t3_terminal, _, %{"type" => "snapshot"}}
    end

    test "scrollback survives the terminal closing, unless deleted", %{input: input} do
      {:ok, _} = Terminal.attach(input, self())
      {:ok, nil} = Terminal.write(Map.put(input, "data", "echo kept\n"))
      await_output("kept")

      {:ok, nil} = Terminal.close(input)
      assert_receive {:t3_terminal, _, %{"type" => "closed"}}

      assert {:error, %{"_tag" => "TerminalSessionLookupError"}} =
               Terminal.attach(Map.delete(input, "cwd"), self())

      assert {:ok, %{"history" => history}} = Terminal.open(input)
      assert history =~ "kept"

      {:ok, nil} = Terminal.close(Map.put(input, "deleteHistory", true))
      assert {:ok, %{"history" => ""}} = Terminal.open(input)
    end

    test "a missing cwd is a contract error", %{input: input} do
      assert {:error, %{"_tag" => "TerminalCwdNotFoundError"}} =
               Terminal.open(%{input | "cwd" => "/nope/not/here"})
    end

    test "watchers see terminals come and go, labelled by what runs in them", %{input: input} do
      assert [] = T3.Terminal.Hub.watch(self())
      {:ok, _} = Terminal.attach(input, self())

      assert_receive {:t3_terminals, _,
                      %{"type" => "upsert", "terminal" => %{"status" => "running"}}}

      {:ok, nil} = Terminal.write(Map.put(input, "data", "sleep 30\n"))

      assert_receive {:t3_terminals, _,
                      %{
                        "type" => "upsert",
                        "terminal" => %{"hasRunningSubprocess" => true, "label" => "sleep"}
                      }},
                     5_000

      assert_receive {:t3_terminal, _, %{"type" => "activity", "label" => "sleep"}}

      {:ok, nil} = Terminal.close(input)
      assert_receive {:t3_terminals, _, %{"type" => "remove", "terminalId" => "term-1"}}
    end
  end

  defp await_output(needle, acc \\ "") do
    receive do
      {:t3_terminal, _, %{"type" => "output", "data" => data}} ->
        acc = acc <> data
        if acc =~ needle, do: acc, else: await_output(needle, acc)
    after
      5_000 -> flunk("no #{inspect(needle)} in #{inspect(acc)}")
    end
  end
end
