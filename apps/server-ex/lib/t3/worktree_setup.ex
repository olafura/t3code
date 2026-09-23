defmodule T3.WorktreeSetup do
  @moduledoc """
  Preparing a new thread's git worktree before its first turn (`subscribeWorktreeSetup`,
  `worktreeSetup.cancel`), as the Node server does.

  A thread launched with the `worktree` strategy gets a `preparing` run; a worker then
  fetches the base branch when asked, adds the worktree on a temporary
  `t3code/<hex>` branch (renamed in the background from the first message), runs
  the project's setup script in a terminal, and releases the run
  (`T3.Orchestration.release_prepared/2`). Its progress is a `WorktreeSetupSnapshot`
  that subscribers get on every change. Until the agent starts the setup can be
  cancelled, which removes the worktree and cancels the run.

  Snapshots live in memory: after a restart a thread shows no setup.
  """

  use GenServer

  require Logger

  alias T3.Orchestration

  @stages ~w(fetch checkout setup-script agent)
  @tail_lines 5

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- API -------------------------------------------------------------------------

  @doc """
  Starts preparing `thread_id`'s worktree for its `run_id`; `strategy` is the
  launch's `worktree` workspace strategy.
  """
  def start(thread_id, run_id, project, strategy, message_text) do
    GenServer.call(__MODULE__, {:start, thread_id, run_id, project, strategy, message_text})
  end

  @doc "Adds `pid` as a subscriber; returns the snapshot, or nil when none is tracked."
  def subscribe(thread_id, pid), do: GenServer.call(__MODULE__, {:subscribe, thread_id, pid})

  def unsubscribe(thread_id, pid), do: GenServer.cast(__MODULE__, {:unsubscribe, thread_id, pid})

  @doc "`worktreeSetup.cancel`: stops a setup that has not handed off to the agent."
  def cancel(%{"threadId" => thread_id}),
    do: {:ok, %{"cancelled" => GenServer.call(__MODULE__, {:cancel, thread_id}, 60_000)}}

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{setups: %{}, watchers: %{}}}
  end

  @impl true
  def handle_call({:start, thread_id, run_id, project, strategy, text}, _from, state) do
    at = now()

    snapshot = %{
      "threadId" => thread_id,
      "phase" => "running",
      "startedAt" => at,
      "endedAt" => nil,
      "branch" => strategy["branch"],
      "baseRef" => strategy["baseRef"],
      "worktreePath" => nil,
      "setupScript" => nil,
      "stages" => Enum.map(@stages, &stage/1),
      "error" => nil,
      "sequence" => 0
    }

    server = self()
    worker = spawn_link(fn -> run(server, thread_id, run_id, project, strategy, text) end)

    setup = %{
      snapshot: snapshot,
      worker: worker,
      run_id: run_id,
      root: project["workspaceRoot"],
      cancellable: true
    }

    state = put_in(state.setups[thread_id], setup)
    broadcast(state, thread_id)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, thread_id, pid}, _from, state) do
    Process.monitor(pid)
    watchers = Map.update(state.watchers, thread_id, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, get_in(state.setups, [thread_id, :snapshot]), %{state | watchers: watchers}}
  end

  def handle_call({:cancel, thread_id}, _from, state) do
    case state.setups[thread_id] do
      %{cancellable: true, worker: worker} = setup when is_pid(worker) ->
        Process.unlink(worker)
        Process.exit(worker, :kill)
        cleanup(thread_id, setup)
        state = update(state, thread_id, &finish(&1, "cancelled", nil))
        state = put_in(state.setups[thread_id].worker, nil)
        {:reply, true, state}

      _ ->
        {:reply, false, state}
    end
  end

  # Progress from the worker: snapshot changes, and notes on what to undo.
  def handle_call({:update, thread_id, fun}, _from, state),
    do: {:reply, :ok, update(state, thread_id, fun)}

  def handle_call({:uncancellable, thread_id}, _from, state) do
    state =
      if state.setups[thread_id],
        do: put_in(state.setups[thread_id].cancellable, false),
        else: state

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unsubscribe, thread_id, pid}, state) do
    {:noreply, update_in(state.watchers, &drop_watcher(&1, thread_id, pid))}
  end

  @impl true
  def handle_info({:EXIT, worker, reason}, state) do
    case Enum.find(state.setups, fn {_, setup} -> setup.worker == worker end) do
      {thread_id, setup} ->
        state = put_in(state.setups[thread_id].worker, nil)

        state =
          case reason do
            :normal ->
              state

            {:shutdown, {:failed, message}} ->
              Orchestration.fail_prepared(thread_id, setup.run_id, "failed")
              update(state, thread_id, &finish(&1, "failed", message))

            other ->
              Logger.warning("worktree setup for #{thread_id} crashed: #{inspect(other)}")
              Orchestration.fail_prepared(thread_id, setup.run_id, "failed")
              update(state, thread_id, &finish(&1, "failed", "Worktree setup failed."))
          end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    watchers = Map.new(state.watchers, fn {id, pids} -> {id, MapSet.delete(pids, pid)} end)
    {:noreply, %{state | watchers: watchers}}
  end

  defp update(state, thread_id, fun) do
    case state.setups[thread_id] do
      nil ->
        state

      setup ->
        snapshot = fun.(setup.snapshot) |> Map.update!("sequence", &(&1 + 1))
        state = put_in(state.setups[thread_id].snapshot, snapshot)
        broadcast(state, thread_id)
        state
    end
  end

  defp broadcast(state, thread_id) do
    snapshot = state.setups[thread_id].snapshot

    for pid <- Map.get(state.watchers, thread_id, []),
        do: send(pid, {:t3_worktree_setup, thread_id, snapshot})
  end

  defp drop_watcher(watchers, thread_id, pid),
    do: Map.update(watchers, thread_id, MapSet.new(), &MapSet.delete(&1, pid))

  # A cancelled setup leaves nothing behind: no worktree, no workspace on the thread.
  defp cleanup(thread_id, setup) do
    path = setup.snapshot["worktreePath"]

    if path do
      T3.Terminal.close(%{
        "threadId" => thread_id,
        "terminalId" => "setup",
        "deleteHistory" => true
      })

      T3.Vcs.remove_worktree(%{"cwd" => setup.root, "path" => path, "force" => true})

      Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => thread_id,
        "worktreePath" => nil,
        "branch" => nil
      })
    end

    Orchestration.fail_prepared(thread_id, setup.run_id, "cancelled")
  rescue
    error -> Logger.warning("worktree cleanup for #{thread_id}: #{Exception.message(error)}")
  end

  # --- the worker ------------------------------------------------------------------

  defp run(server, thread_id, run_id, project, strategy, text) do
    root = project["workspaceRoot"]
    set = fn fun -> GenServer.call(server, {:update, thread_id, fun}) end
    status = fn id, status, extra -> set.(&set_stage(&1, id, status, extra)) end

    # Fetch first when asked and the remote has the base branch.
    start_ref =
      if strategy["startFromOrigin"] == true and origin?(root) do
        status.("fetch", "running", %{})
        _ = T3.Git.run(root, ["fetch", "origin", strategy["baseRef"]])
        status.("fetch", "done", %{})

        if match?(
             {:ok, _},
             T3.Git.ok(root, ["rev-parse", "--verify", "origin/#{strategy["baseRef"]}"])
           ),
           do: "origin/#{strategy["baseRef"]}",
           else: strategy["baseRef"]
      else
        status.("fetch", "skipped", %{})
        strategy["baseRef"]
      end

    status.("checkout", "running", %{})
    temporary = "t3code/" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    branch = strategy["branch"] || temporary

    {path, branch} =
      case T3.Vcs.create_worktree(%{
             "cwd" => root,
             "refName" => start_ref,
             "newRefName" => branch
           }) do
        {:ok, %{"worktree" => %{"path" => path, "refName" => branch}}} -> {path, branch}
        {:error, error} -> fail("Could not create the worktree: #{message(error)}")
      end

    set.(&Map.merge(&1, %{"worktreePath" => path, "branch" => branch}))

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "threadId" => thread_id,
        "worktreePath" => path,
        "branch" => branch
      })

    status.("checkout", "done", %{})
    if branch == temporary, do: rename_later(thread_id, path, branch, text)

    setup = setup_script(project)

    wait =
      case setup do
        nil ->
          status.("setup-script", "skipped", %{})
          nil

        script ->
          status.("setup-script", "running", %{})
          start_script(thread_id, path, script, set)
      end

    # A blocking script finishes before the agent starts.
    if wait && setup["async"] == false, do: await_script(wait, status, set, fatal: true)

    GenServer.call(server, {:uncancellable, thread_id})
    status.("agent", "running", %{})

    case Orchestration.release_prepared(thread_id, run_id) do
      :ok -> status.("agent", "done", %{})
      {:error, reason} -> fail("The agent could not start: #{message(reason)}")
    end

    if wait && setup["async"] != false, do: await_script(wait, status, set, fatal: false)
    set.(&finish(&1, "done", nil))
  end

  defp origin?(root), do: match?({:ok, _}, T3.Git.ok(root, ~w(remote get-url origin)))

  # The project's script marked to run on a new worktree.
  defp setup_script(project),
    do: Enum.find(project["scripts"] || [], &(&1["runOnWorktreeCreate"] == true))

  # Runs the script in the thread's "setup" terminal; its exit code comes back as a
  # marker line the command prints after it.
  defp start_script(thread_id, path, script, set) do
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    input = %{
      "threadId" => thread_id,
      "terminalId" => "setup",
      "cwd" => path,
      "env" => %{"NO_COLOR" => "1", "FORCE_COLOR" => "0"}
    }

    with {:ok, _} <- T3.Terminal.open(input),
         {:ok, _} <- T3.Terminal.attach(input, self()),
         {:ok, _} <-
           T3.Terminal.write(%{
             "threadId" => thread_id,
             "terminalId" => "setup",
             "data" => "#{script["command"]}; printf '\\n__t3_setup_#{token}_%s\\n' $?\r"
           }) do
      set.(
        &Map.put(&1, "setupScript", %{
          "name" => script["name"],
          "command" => script["command"],
          "terminalId" => "setup"
        })
      )

      {thread_id, token}
    else
      _ -> fail("Could not start the setup script.")
    end
  end

  defp await_script({thread_id, token}, status, set, opts) do
    case collect({thread_id, "setup"}, Regex.compile!("__t3_setup_#{token}_(\\d+)"), "", set) do
      0 ->
        status.("setup-script", "done", %{"detail" => "exited with 0"})

      code ->
        status.("setup-script", "failed", %{"detail" => "exited with #{code}"})
        if opts[:fatal], do: fail("Setup script exited with #{code}.")
    end
  end

  # Reads the terminal until the marker, keeping the last lines as the stage's tail.
  defp collect(key, marker, buffer, set) do
    receive do
      {:t3_terminal, ^key, %{"type" => "output", "data" => data}} ->
        buffer = String.slice(buffer <> strip_ansi(data), -8_000..-1//1)

        case Regex.run(marker, buffer) do
          [_, code] ->
            String.to_integer(code)

          nil ->
            tail =
              buffer
              |> String.split(~r/\r?\n/, trim: true)
              |> Enum.reject(&String.contains?(&1, "__t3_setup_"))
              |> Enum.take(-@tail_lines)
              |> Enum.map(&String.slice(&1, 0, 200))

            set.(&set_stage(&1, "setup-script", "running", %{"tail" => tail}))
            collect(key, marker, buffer, set)
        end

      {:t3_terminal, ^key, %{"type" => "exited"}} ->
        1

      {:t3_terminal, ^key, _event} ->
        collect(key, marker, buffer, set)
    end
  end

  # The temporary branch gets a name from the first message, in the background.
  defp rename_later(thread_id, path, old, text) do
    Task.start(fn ->
      with {:ok, %{"branch" => generated}} <- T3.TextGeneration.branch_name(path, text || ""),
           new when new != "" <- available(path, sanitize(generated)),
           {:ok, _} <- T3.Git.ok(path, ["branch", "-m", old, new]) do
        T3.Vcs.Watch.refresh(path)

        Orchestration.dispatch(%{
          "type" => "thread.metadata.update",
          "threadId" => thread_id,
          "branch" => new,
          "worktreePath" => path
        })
      else
        {:error, reason} -> Logger.warning("branch name not generated: #{message(reason)}")
        _ -> :ok
      end
    end)
  end

  defp sanitize(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['"`]/, "")
    |> String.replace(~r/[^a-z0-9\/_-]+/, "-")
    |> String.replace(~r/\/+/, "/")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
  end

  defp available(path, name) do
    Enum.find([name | Enum.map(2..20, &"#{name}-#{&1}")], fn candidate ->
      match?({:error, _}, T3.Git.ok(path, ["rev-parse", "--verify", "refs/heads/#{candidate}"]))
    end) || ""
  end

  # --- snapshots -------------------------------------------------------------------

  defp stage(id),
    do: %{
      "id" => id,
      "status" => "pending",
      "startedAt" => nil,
      "endedAt" => nil,
      "percent" => nil,
      "detail" => nil,
      "tail" => []
    }

  defp set_stage(snapshot, id, status, extra) do
    at = now()

    stages =
      Enum.map(snapshot["stages"], fn
        %{"id" => ^id} = stage ->
          stage
          |> Map.merge(extra)
          |> Map.put("status", status)
          |> then(
            &if(status == "running" and &1["startedAt"] == nil,
              do: Map.put(&1, "startedAt", at),
              else: &1
            )
          )
          |> then(
            &if(status in ~w(done skipped failed warning),
              do: Map.put(&1, "endedAt", at),
              else: &1
            )
          )

        stage ->
          stage
      end)

    %{snapshot | "stages" => stages}
  end

  defp finish(snapshot, phase, error),
    do: Map.merge(snapshot, %{"phase" => phase, "endedAt" => now(), "error" => error})

  defp fail(message), do: exit({:shutdown, {:failed, message}})

  defp message(%{"message" => message}), do: message
  defp message(%{"detail" => detail}) when is_binary(detail), do: detail
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;?]*[a-zA-Z]/, "")

  defp now, do: T3.Orchestration.Entities.now()
end
