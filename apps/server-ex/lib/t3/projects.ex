defmodule T3.Projects do
  @moduledoc """
  Projects on this node (`projects.mutate`) and the folder browser used to pick a
  project's workspace root (`filesystem.browse`).

  A project is its own stream holding one `project` entity in the shape of the
  contracts' `Project`; its sidebar row follows from it (`T3.Projection`).
  Deleting sets `deletedAt`, which removes it from clients' sidebars.
  """

  alias T3.{Patch, StreamState}
  alias T3.Orchestration.Entities

  @spec mutate(map) :: {:ok, map} | {:error, String.t()}
  def mutate(%{"type" => "project.create", "projectId" => id} = m) do
    root = expand(m["workspaceRoot"] || "")

    cond do
      root == "" ->
        {:error, "a workspace folder is required"}

      not File.dir?(root) and m["createWorkspaceRootIfMissing"] != true ->
        {:error, "#{root} does not exist on this machine"}

      true ->
        File.mkdir_p!(root)
        at = Entities.now()

        project = %{
          "id" => id,
          "title" => m["title"] || Path.basename(root),
          "workspaceRoot" => root,
          "defaultModelSelection" => m["defaultModelSelection"],
          "scripts" => m["scripts"] || [],
          "createdAt" => at,
          "updatedAt" => at,
          "deletedAt" => nil
        }

        {:ok, _} = T3.Streams.commit(id, :project, [{"project", id, Patch.diff(nil, project)}])
        {:ok, contract(project)}
    end
  end

  def mutate(%{"type" => "project.update", "projectId" => id} = m) do
    fields =
      m
      |> Map.take(
        ~w(title defaultModelSelection scripts autoPull projectIcon faviconPath defaultThreadEnvMode)
      )
      |> then(
        &if(m["workspaceRoot"],
          do: Map.put(&1, "workspaceRoot", expand(m["workspaceRoot"])),
          else: &1
        )
      )

    update(id, &Map.merge(&1, Map.put(fields, "updatedAt", Entities.now())))
  end

  def mutate(%{"type" => "project.delete", "projectId" => id}),
    do:
      update(id, &Map.merge(&1, %{"deletedAt" => Entities.now(), "updatedAt" => Entities.now()}))

  def mutate(%{"type" => type}), do: {:error, "#{type} is not supported"}

  defp update(id, fun) do
    T3.Streams.transact(id, :project, fn state ->
      case StreamState.get(state, "project")[id] do
        nil ->
          {[], {:error, "unknown project #{id}"}}

        current ->
          next = fun.(current)

          case Patch.diff(current, next) do
            :unchanged -> {[], {:ok, contract(next)}}
            patch -> {[{"project", id, patch}], {:ok, contract(next)}}
          end
      end
    end)
  end

  # The contracts' `Project`: stored entities drop null fields, and projects
  # imported from the Node log name their id `projectId`.
  defp contract(project) do
    optional =
      Map.take(
        project,
        ~w(repositoryIdentity faviconPath projectIcon defaultThreadEnvMode autoPull)
      )

    Map.merge(optional, %{
      "id" => project["id"] || project["projectId"],
      "title" => project["title"],
      "workspaceRoot" => project["workspaceRoot"],
      "defaultModelSelection" => project["defaultModelSelection"],
      "scripts" => project["scripts"] || [],
      "createdAt" => project["createdAt"],
      "updatedAt" => project["updatedAt"],
      "deletedAt" => project["deletedAt"]
    })
  end

  @doc """
  Brings projects whose settings say `defaultAutoPull` up to date at boot, as the
  Node server does: only a clean checkout on its default branch with an upstream,
  nothing of its own to push, and something new to pull. Each checkout is pulled
  once however many projects share it; a failure is logged and skipped.
  """
  def auto_pull do
    roots =
      for {{node, _id}, {"project", project}} <- T3.Shell.rows(),
          node == node(),
          project["deletedAt"] == nil,
          T3.Settings.for_project(project["id"])["defaultAutoPull"] == true,
          uniq: true,
          do: project["workspaceRoot"]

    for root <- roots do
      local = T3.Vcs.local_status(root)

      with %{"isRepo" => true, "isDefaultRef" => true, "hasWorkingTreeChanges" => false} <-
             local,
           %{"hasUpstream" => true, "aheadCount" => 0, "behindCount" => behind} when behind > 0 <-
             T3.Vcs.remote_status(root, fetch: true),
           {:error, error} <- T3.Vcs.pull(%{"cwd" => root}) do
        require Logger
        Logger.warning("automatic pull of #{root} failed: #{inspect(error)}")
      end
    end

    :ok
  end

  @doc """
  The id of this node's project a directory belongs to: a thread's worktree, or
  the project whose workspace holds it (the deepest one). Nil when none does.
  """
  def at(path) when is_binary(path) do
    path = Path.expand(path)
    rows = for {{node, _id}, row} <- T3.Shell.rows(), node == node(), do: row

    worktree =
      Enum.find_value(rows, fn
        {"thread", %{"worktreePath" => root, "projectId" => id}} when is_binary(root) ->
          if within?(path, root), do: id

        _ ->
          nil
      end)

    worktree ||
      rows
      |> Enum.flat_map(fn
        {"project", %{"workspaceRoot" => root, "id" => id} = row} when is_binary(root) ->
          if row["deletedAt"] == nil and within?(path, root), do: [{root, id}], else: []

        _ ->
          []
      end)
      |> Enum.max_by(fn {root, _} -> byte_size(root) end, fn -> {nil, nil} end)
      |> elem(1)
  end

  def at(_path), do: nil

  defp within?(path, root) do
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  @doc """
  Folders matching a partly typed path: the folders in its parent whose names start
  with its last segment, or every folder inside it when it ends with a separator.
  Hidden folders show only when asked for.
  """
  @spec browse(map) :: {:ok, map} | {:error, String.t()}
  def browse(%{"partialPath" => partial} = input) do
    resolved = partial |> expand() |> Path.expand(input["cwd"] || System.user_home!())
    whole_dir? = String.ends_with?(partial, "/") or partial == "~"
    parent = if whole_dir?, do: resolved, else: Path.dirname(resolved)
    prefix = if whole_dir?, do: "", else: Path.basename(resolved)
    show_hidden = whole_dir? or String.starts_with?(prefix, ".")

    case File.ls(parent) do
      {:ok, names} ->
        entries =
          for name <- Enum.sort(names),
              String.starts_with?(String.downcase(name), String.downcase(prefix)),
              show_hidden or not String.starts_with?(name, "."),
              File.dir?(Path.join(parent, name)),
              do: %{"name" => name, "fullPath" => Path.join(parent, name)}

        {:ok, %{"parentPath" => parent, "entries" => entries}}

      {:error, reason} when reason in [:eacces, :eperm] ->
        {:ok, %{"parentPath" => parent, "entries" => []}}

      {:error, reason} ->
        {:error, "cannot read #{parent}: #{:file.format_error(reason)}"}
    end
  end

  defp expand("~"), do: System.user_home!()
  defp expand("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand(path), do: path
end
