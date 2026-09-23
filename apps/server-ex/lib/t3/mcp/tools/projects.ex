defmodule T3.Mcp.Tools.Projects do
  @moduledoc """
  MCP tools that register, change and clone projects, and move the calling thread
  into a git worktree (`T3.Mcp.Tools`). Project changes reach the whole
  environment, so they need a live full-access/default caller.
  """

  import T3.Mcp.Tools,
    only: [
      command_id: 0,
      live: 1,
      project_row: 1,
      project_threads: 1,
      thread: 1,
      unrestricted: 2
    ]

  alias T3.Orchestration

  @tools ~w(t3_project_create t3_project_update t3_project_delete t3_project_clone
            t3_worktree_list t3_worktree_status t3_worktree_handoff)

  def tools, do: @tools

  def run("t3_project_create", args, caller) do
    root = Path.expand(args["workspaceRoot"] || "")

    with :ok <- mutation(caller),
         :ok <-
           if(Enum.any?(projects(), &(&1["workspaceRoot"] == root)),
             do: {:error, "invalid_request", "The workspace is already registered to a project."},
             else: :ok
           ) do
      args
      |> Map.take(~w(title createWorkspaceRootIfMissing defaultModelSelection scripts))
      |> Map.merge(%{
        "type" => "project.create",
        "projectId" => command_id(),
        "workspaceRoot" => root
      })
      |> T3.Projects.mutate()
      |> project_result()
    end
  end

  def run("t3_project_update", %{"projectId" => id} = args, caller) do
    with :ok <- mutation(caller),
         %{} <- project_row(id) || not_found() do
      args
      |> Map.take(
        ~w(title workspaceRoot defaultModelSelection autoPull projectIcon faviconPath defaultThreadEnvMode scripts)
      )
      |> Map.reject(fn {key, value} ->
        value == nil and key in ~w(title workspaceRoot scripts)
      end)
      |> Map.merge(%{"type" => "project.update", "projectId" => id})
      |> T3.Projects.mutate()
      |> project_result()
    end
  end

  # A project with threads goes only when forced, and takes its threads with it.
  def run("t3_project_delete", %{"projectId" => id} = args, caller) do
    with :ok <- mutation(caller),
         %{} <- project_row(id) || not_found() do
      threads = project_threads(id)

      if threads != [] and args["force"] != true do
        {:error, "invalid_request",
         "The project is not empty; force=true is required to delete it."}
      else
        for thread <- threads,
            do:
              {:ok, _} =
                Orchestration.dispatch(%{
                  "type" => "thread.delete",
                  "commandId" => command_id(),
                  "threadId" => thread["id"]
                })

        project_result(T3.Projects.mutate(%{"type" => "project.delete", "projectId" => id}))
      end
    end
  end

  def run("t3_project_clone", args, caller) do
    with :ok <- mutation(caller) do
      case T3.SourceControl.clone(args) do
        {:ok, result} -> {:ok, result}
        {:error, %{"detail" => detail}} -> {:error, "orchestration_error", detail}
        {:error, other} -> {:error, "orchestration_error", inspect(other)}
      end
    end
  end

  def run("t3_worktree_list", args, %{row: me}) do
    with %{} = project <- project_row(me["projectId"]) || not_found() do
      T3.Vcs.list_refs(Map.put(args, "cwd", me["worktreePath"] || project["workspaceRoot"]))
    end
  end

  def run("t3_worktree_status", _args, %{row: me}) do
    thread = thread(me["id"]) || me

    with %{} = project <- project_row(me["projectId"]) || project_not_found(me) do
      {:ok,
       %{
         "attached" => thread["worktreePath"] != nil,
         "worktreePath" => thread["worktreePath"],
         "branch" => thread["branch"],
         "projectWorkspaceRoot" => project["workspaceRoot"],
         "defaultStartFromOrigin" => start_from_origin_default()
       }}
    end
  end

  def run("t3_worktree_handoff", %{"branch" => branch} = args, %{row: me}) do
    thread = thread(me["id"]) || me

    with :ok <- unbound(thread),
         %{} = project <- project_row(me["projectId"]) || project_not_found(me),
         root = project["workspaceRoot"],
         :ok <-
           if(args["path"] && Path.type(args["path"]) != :absolute,
             do:
               {:error, "invalid_request",
                "path must be an absolute filesystem path, got '#{args["path"]}'."},
             else: :ok
           ),
         {:ok, status} <- repository(root),
         :ok <- new_branch(root, branch),
         {:ok, base_ref} <- base_ref(args["baseRef"] || status["refName"]),
         from_origin =
           if(is_boolean(args["startFromOrigin"]),
             do: args["startFromOrigin"],
             else: start_from_origin_default()
           ),
         {:ok, start} <- start_point(root, base_ref, from_origin),
         {:ok, %{"worktree" => worktree}} <-
           T3.Vcs.create_worktree(%{
             "cwd" => root,
             "refName" => start,
             "newRefName" => branch,
             "path" => args["path"]
           })
           |> operation("Unable to create the worktree"),
         :ok <- bind(me["id"], root, worktree) do
      {:ok,
       %{
         "worktreePath" => worktree["path"],
         "branch" => worktree["refName"],
         "baseRef" => base_ref,
         "startedFromOrigin" => from_origin,
         "setupScript" =>
           if(args["runSetupScript"] == false,
             do: %{"status" => "skipped"},
             else: setup_script(me["id"], project, worktree["path"])
           ),
         "continuation" => continuation(me, args["continuationPrompt"]),
         "note" =>
           if(args["continuationPrompt"],
             do:
               "Handoff recorded. The queued continuation prompt starts the next turn inside the worktree with the conversation preserved. The worktree is not removed automatically when the thread is deleted.",
             else:
               "Handoff recorded. The conversation continues inside the worktree when the thread receives its next message. Pass continuationPrompt to resume automatically. The worktree is not removed automatically when the thread is deleted."
           )
       }}
    end
  end

  # --- helpers ----------------------------------------------------------------------------

  defp mutation(caller) do
    with :ok <- live(caller),
         do:
           unrestricted(
             caller,
             "Project changes require a live full-access/default calling thread."
           )
  end

  defp projects do
    for {{node, _}, {"project", row}} <- T3.Shell.rows(),
        node == node() and row["deletedAt"] == nil,
        do: row
  end

  defp project_result({:ok, project}), do: {:ok, project}
  defp project_result({:error, message}), do: {:error, "invalid_request", message}

  defp not_found, do: {:error, "invalid_request", "The project was not found."}

  defp project_not_found(me),
    do:
      {:error, "project_not_found",
       "Project '#{me["projectId"]}' was not found for thread '#{me["id"]}'."}

  defp start_from_origin_default,
    do: Map.get(T3.Settings.settings(), "newWorktreesStartFromOrigin", true)

  defp unbound(thread) do
    cond do
      thread["worktreePath"] ->
        {:error, "already_in_worktree",
         "Thread '#{thread["id"]}' is already attached to worktree '#{thread["worktreePath"]}'."}

      thread["archivedAt"] ->
        {:error, "invalid_request",
         "Thread '#{thread["id"]}' is archived and cannot be handed off to a worktree."}

      true ->
        :ok
    end
  end

  defp repository(root) do
    case T3.Vcs.local_status(root) do
      %{"isRepo" => true} = status ->
        {:ok, status}

      _ ->
        {:error, "invalid_request", "Project workspace '#{root}' is not a git repository."}
    end
  end

  defp new_branch(root, branch) do
    case T3.Git.ok(root, ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch]) do
      {:ok, _} ->
        {:error, "invalid_request",
         "Branch '#{branch}' already exists. Choose a different branch name, or delete the existing branch first."}

      _ ->
        :ok
    end
  end

  defp base_ref(nil),
    do:
      {:error, "invalid_request",
       "Could not determine the current branch of the project workspace (detached HEAD?). Pass baseRef explicitly."}

  defp base_ref(ref), do: {:ok, ref}

  # The commit to branch from: origin's copy of the base when asked for.
  defp start_point(_root, base_ref, false), do: {:ok, base_ref}

  defp start_point(root, base_ref, true) do
    with {:ok, _} <- T3.Git.ok(root, ["fetch", "origin"]) |> operation("Unable to fetch origin"),
         {:ok, sha} <-
           T3.Git.ok(root, ["rev-parse", "--verify", "origin/#{base_ref}^{commit}"])
           |> operation("Unable to resolve the remote-tracking commit of '#{base_ref}'"),
         do: {:ok, String.trim(sha)}
  end

  # Points the thread at the new worktree, unless it was bound or archived meanwhile;
  # then the worktree goes again.
  defp bind(thread_id, root, worktree) do
    result =
      with :ok <- unbound(thread(thread_id)),
           {:ok, _} <-
             Orchestration.dispatch(%{
               "type" => "thread.metadata.update",
               "commandId" => command_id(),
               "threadId" => thread_id,
               "branch" => worktree["refName"],
               "worktreePath" => worktree["path"],
               "expectedWorktreePath" => nil
             })
             |> operation("Unable to re-point the thread at the worktree"),
           do: :ok

    if result != :ok do
      T3.Vcs.remove_worktree(%{"cwd" => root, "path" => worktree["path"], "force" => true})
      T3.Git.run(root, ["branch", "-D", worktree["refName"]])
    end

    result
  end

  # The project's script marked to run on a new worktree, in the thread's "setup" terminal.
  defp setup_script(thread_id, project, path) do
    case Enum.find(project["scripts"] || [], &(&1["runOnWorktreeCreate"] == true)) do
      nil ->
        %{"status" => "no-script"}

      script ->
        terminal = %{"threadId" => thread_id, "terminalId" => "setup", "cwd" => path}

        with {:ok, _} <- T3.Terminal.open(terminal),
             {:ok, _} <- T3.Terminal.write(Map.put(terminal, "data", script["command"] <> "\r")) do
          %{"status" => "started", "scriptName" => script["name"], "terminalId" => "setup"}
        else
          error -> %{"status" => "failed", "detail" => inspect(error)}
        end
    end
  rescue
    error -> %{"status" => "failed", "detail" => Exception.message(error)}
  end

  # The prompt that resumes the thread once its current turn ends, now in the worktree.
  defp continuation(_me, nil), do: %{"status" => "skipped"}

  defp continuation(me, prompt) do
    id = command_id()

    case Orchestration.dispatch(%{
           "type" => "message.dispatch",
           "commandId" => id,
           "threadId" => me["id"],
           "messageId" => id,
           "text" => prompt,
           "attachments" => [],
           "dispatchMode" => %{"type" => "queue_after_active"},
           "createdBy" => "agent",
           "creationSource" => "mcp"
         }) do
      {:ok, _} -> %{"status" => "scheduled", "delivery" => "queue_after_active"}
      {:error, reason} -> %{"status" => "failed", "detail" => inspect(reason)}
    end
  end

  defp operation({:ok, _} = ok, _prefix), do: ok

  defp operation({:error, error}, prefix) do
    detail =
      case error do
        %{"detail" => detail} -> detail
        {_status, detail} when is_binary(detail) -> detail
        detail when is_binary(detail) -> detail
        other -> inspect(other)
      end

    {:error, "operation_failed", "#{prefix}: #{detail}"}
  end
end
