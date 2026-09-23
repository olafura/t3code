defmodule T3.Projection do
  @moduledoc """
  Sidebar rows for streams: a thread's `OrchestrationV2ThreadShell` or a project's
  `OrchestrationProjectShell`, as JSON-shaped maps.
  """

  alias T3.{Store, StreamState}
  alias T3.Projection.JS

  @doc """
  The sidebar row for a stream, as `{"thread" | "project", row}`, or `nil` while the
  stream has no thread or project entity yet. Fork sources are read from the store
  at `path`.
  """
  @spec row(String.t(), String.t(), StreamState.t()) :: {String.t(), map} | nil
  def row(path, stream_id, %StreamState{} = state) do
    cond do
      Map.has_key?(StreamState.get(state, "thread"), stream_id) ->
        {"thread", T3.Projection.Shell.thread_shell(state, &StreamState.load(path, &1))}

      project = StreamState.get(state, "project")[stream_id] ->
        {"project", project_shell(project)}

      true ->
        nil
    end
  end

  @doc "Computes and stores the row for a stream from its log."
  @spec rebuild(GenServer.server(), String.t()) :: {String.t(), map} | nil
  def rebuild(store \\ Store, stream_id) do
    path = Store.path(store)
    state = StreamState.load(path, stream_id)

    with {_kind, _row} = kind_row <- row(path, stream_id, state) do
      :ok = Store.put_shell(store, stream_id, state.seq, kind_row)
      kind_row
    end
  end

  # Projects imported from the Node log carry `projectId`; newer ones carry `id`.
  defp project_shell(project) do
    base = %{
      "id" => JS.get(project, "id") || JS.get(project, "projectId"),
      "title" => JS.get(project, "title"),
      "workspaceRoot" => JS.get(project, "workspaceRoot"),
      "defaultModelSelection" => JS.json(JS.get(project, "defaultModelSelection")),
      "scripts" => JS.json(JS.get(project, "scripts") || []),
      "createdAt" => JS.get(project, "createdAt"),
      "updatedAt" => JS.get(project, "updatedAt")
    }

    optional =
      for field <-
            ~w(repositoryIdentity defaultThreadEnvMode autoPull faviconPath projectIcon deletedAt),
          (value = JS.get(project, field)) != nil,
          into: %{},
          do: {field, JS.json(value)}

    Map.merge(base, optional)
  end
end
