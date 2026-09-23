defmodule T3.ProjectClones do
  @moduledoc """
  Clones that back freshly added projects (`projectClone.*`). Starting one adds
  the project right away, then clones into its empty folder while clients follow
  git's own progress (`ProjectCloneSnapshot`). Progress is kept in memory only: a
  finished clone is dropped after a short while, a failed one stays until it is
  retried, and a restart forgets them (the project keeps its folder).

  Watchers (client sockets) get `{:t3_project_clones, node, snapshots}` on changes.
  """

  use GenServer

  @forget_done_after 30_000
  @detail_max 200
  @error_max 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`projectClone.start`: adds the project, then clones into it in the background."
  def start(input) do
    dest = Path.expand(input["destinationPath"])

    with {:ok, url, repository} <- T3.SourceControl.remote(input),
         {:ok, _} <-
           T3.Projects.mutate(%{
             "type" => "project.create",
             "projectId" => input["projectId"],
             "title" => input["title"],
             "workspaceRoot" => dest,
             "createWorkspaceRootIfMissing" => true
           }) do
      clone = %{project_id: input["projectId"], url: url, dest: dest, repository: repository}
      :ok = GenServer.call(__MODULE__, {:start, clone})

      {:ok,
       %{
         "projectId" => input["projectId"],
         "cwd" => dest,
         "remoteUrl" => url,
         "repository" => repository
       }}
    end
  end

  def retry(%{"projectId" => id}), do: GenServer.call(__MODULE__, {:retry, id})
  def cancel(%{"projectId" => id}), do: GenServer.call(__MODULE__, {:cancel, id})
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    # A cancelled clone's worker is killed; its exit must not take this down.
    Process.flag(:trap_exit, true)
    {:ok, %{clones: %{}, workers: %{}, watchers: %{}, sequence: 0}}
  end

  @impl true
  def handle_call({:start, clone}, _from, state) do
    {:reply, :ok, state |> run(clone) |> changed()}
  end

  def handle_call({:retry, id}, _from, state) do
    case state.clones[id] do
      %{"phase" => phase} = snapshot when phase in ["failed", "cancelled"] ->
        clone = %{
          project_id: id,
          url: snapshot["remoteUrl"],
          dest: snapshot["destinationPath"],
          repository: snapshot["repository"]
        }

        {:reply, {:ok, %{"applied" => true}}, state |> run(clone) |> changed()}

      _ ->
        {:reply, {:ok, %{"applied" => false}}, state}
    end
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.pop(state.workers, id) do
      {nil, _} ->
        {:reply, {:ok, %{"applied" => false}}, state}

      {pid, workers} ->
        Process.exit(pid, :kill)

        state =
          update(%{state | workers: workers}, id, %{"phase" => "cancelled", "endedAt" => now()})

        {:reply, {:ok, %{"applied" => true}}, changed(state)}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, snapshots(state)}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:clone_progress, id, fields}, state) do
    if Map.has_key?(state.workers, id),
      do: {:noreply, state |> update(id, fields) |> changed()},
      else: {:noreply, state}
  end

  # A cancelled clone may still report; it stays cancelled.
  def handle_info({:clone_finished, id, _result}, state)
      when not is_map_key(state.workers, id),
      do: {:noreply, state}

  def handle_info({:clone_finished, id, result}, state) do
    state = %{state | workers: Map.delete(state.workers, id)}

    fields =
      case result do
        :ok ->
          Process.send_after(self(), {:forget, id}, @forget_done_after)
          %{"phase" => "done", "stage" => "checkout", "percent" => 100, "endedAt" => now()}

        {:error, message} ->
          %{
            "phase" => "failed",
            "error" => String.slice(message, 0, @error_max),
            "endedAt" => now()
          }
      end

    {:noreply, state |> update(id, fields) |> changed()}
  end

  def handle_info({:forget, id}, state) do
    case state.clones[id] do
      %{"phase" => "done"} -> {:noreply, changed(%{state | clones: Map.delete(state.clones, id)})}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  # --- clones ------------------------------------------------------------------

  defp run(state, clone) do
    server = self()
    id = clone.project_id

    pid =
      spawn_link(fn ->
        send(server, {:clone_finished, id, clone(server, id, clone.url, clone.dest)})
      end)

    snapshot = %{
      "projectId" => id,
      "remoteUrl" => clone.url,
      "destinationPath" => clone.dest,
      "repository" => clone.repository,
      "phase" => "running",
      "stage" => "connecting",
      "percent" => nil,
      "detail" => nil,
      "error" => nil,
      "startedAt" => now(),
      "endedAt" => nil,
      "sequence" => 0
    }

    %{
      state
      | clones: Map.put(state.clones, id, snapshot),
        workers: Map.put(state.workers, id, pid)
    }
  end

  # `git clone --progress`, reporting each stage it prints on stderr.
  defp clone(server, id, url, dest) do
    {last, status} =
      ["git", "clone", "--progress", url, dest]
      |> Exile.stream(cd: Path.dirname(dest), stderr: :consume, ignore_epipe: true)
      |> Enum.reduce({"", nil}, fn
        {:stderr, data}, {_last, status} ->
          lines = data |> String.split(~r/[\r\n]+/, trim: true)

          for line <- lines,
              fields = progress(line),
              do: send(server, {:clone_progress, id, fields})

          {List.last(lines) || "", status}

        {:exit, status}, {last, _} ->
          {last, status}

        _, acc ->
          acc
      end)

    if status == {:status, 0}, do: :ok, else: {:error, String.trim(last) |> fallback()}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp fallback(""), do: "git clone failed."
  defp fallback(message), do: message

  @stages [
    {~r/^(?:remote: )?(?:Enumerating|Counting|Compressing) objects:\s+(\d+)%\s*(.*)$/,
     "counting"},
    {~r/^Receiving objects:\s+(\d+)%\s*(.*)$/, "receiving"},
    {~r/^Resolving deltas:\s+(\d+)%\s*(.*)$/, "resolving"},
    {~r/^Updating files:\s+(\d+)%\s*(.*)$/, "checkout"}
  ]

  @doc false
  # A git progress line as snapshot fields, or nil.
  def progress(line) do
    Enum.find_value(@stages, fn {pattern, stage} ->
      case Regex.run(pattern, String.trim(line)) do
        [_, percent, rest] ->
          detail =
            rest |> String.replace(~r/^\(\d+\/\d+\),?\s*/, "") |> String.replace(", done.", "")

          %{
            "stage" => stage,
            "percent" => min(String.to_integer(percent), 100),
            "detail" => if(detail == "", do: nil, else: String.slice(detail, 0, @detail_max))
          }

        _ ->
          nil
      end
    end)
  end

  defp update(state, id, fields) do
    case state.clones[id] do
      nil ->
        state

      snapshot ->
        sequence = state.sequence + 1
        snapshot = snapshot |> Map.merge(fields) |> Map.put("sequence", sequence)
        %{state | clones: Map.put(state.clones, id, snapshot), sequence: sequence}
    end
  end

  defp changed(state) do
    list = snapshots(state)
    for {pid, _} <- state.watchers, do: send(pid, {:t3_project_clones, node(), list})
    state
  end

  defp snapshots(state), do: state.clones |> Map.values() |> Enum.sort_by(& &1["startedAt"])

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
