defmodule T3.Mcp.Tools.Threads do
  @moduledoc """
  MCP tools that create threads and change a thread's configuration, metadata and
  place in the sidebar (`T3.Mcp.Tools`): launching and batch-creating threads,
  forks and merges, attachments, and what providers a new thread can use.
  """

  import T3.Mcp.Tools,
    only: [
      command_id: 0,
      live: 1,
      message_run: 2,
      mode: 3,
      orchestration: 1,
      project_row: 1,
      project_thread: 2,
      stream: 1,
      thread: 1,
      unrestricted: 2,
      writable: 2
    ]

  alias T3.{Orchestration, StreamState}

  @tools ~w(t3_thread_launch create_threads t3_thread_fork t3_thread_merge_back t3_thread_update
            t3_thread_configure t3_thread_configuration t3_thread_organize t3_thread_transfers
            t3_thread_send_attachments t3_attachment_prepare_upload t3_attachment_discard
            orchestrator_capabilities)

  def tools, do: @tools

  def run("t3_thread_launch", args, %{row: me} = caller) do
    attachments = args["attachments"] || []
    project_id = args["projectId"] || me["projectId"]

    with :ok <- live(caller),
         :ok <-
           unrestricted(caller, "Project launches require a full-access/default calling thread."),
         :ok <-
           if(Enum.all?(attachments, &pending?/1),
             do: :ok,
             else:
               {:error, "invalid_request",
                "A new thread accepts only pending attachment uploads."}
           ),
         %{} <-
           project_row(project_id) || {:error, "invalid_request", "The project was not found."} do
      id = command_id()

      input = %{
        "commandId" => id,
        "threadId" => id,
        "projectId" => project_id,
        "title" => args["title"],
        "modelSelection" => args["modelSelection"] || me["modelSelection"],
        "runtimeMode" => args["runtimeMode"] || me["runtimeMode"],
        "interactionMode" => args["interactionMode"] || me["interactionMode"],
        "workspaceStrategy" => args["workspaceStrategy"] || %{"type" => "root"},
        "createdBy" => "agent",
        "creationSource" => "mcp"
      }

      input =
        if args["message"] == nil and attachments == [],
          do: input,
          else:
            Map.put(input, "initialMessage", %{
              "messageId" => id,
              "text" => args["message"] || "",
              "attachments" => attachments
            })

      with {:ok, _} <- orchestration(Orchestration.launch_thread(input)) do
        thread = thread(id)
        run = Enum.find(StreamState.list(stream(id), "run"), &(&1["userMessageId"] == id))

        {:ok,
         %{
           "threadId" => id,
           "projectId" => thread["projectId"],
           "modelSelection" => thread["modelSelection"],
           "runId" => run && run["id"],
           "status" => run && run["status"]
         }}
      end
    end
  end

  # Ordinary top-level threads beside the caller's, in its workspace.
  def run("create_threads", args, %{row: me} = caller) do
    with :ok <- live(caller) do
      parent = thread(me["id"])
      providers = T3.Environment.providers()
      key = args["clientRequestId"] || T3.Environment.uuid4()

      args["threads"]
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {request, index}, {:ok, created} ->
        case create_thread(parent, providers, key, request, index) do
          {:ok, thread} -> {:cont, {:ok, [thread | created]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, created} -> {:ok, %{"threads" => Enum.reverse(created)}}
        error -> error
      end
    end
  end

  def run("t3_thread_fork", args, %{row: me} = caller) do
    with {:ok, _} <- writable(caller, nil) do
      id = command_id()
      target = id <> ":fork"

      command = %{
        "type" => "thread.fork",
        "commandId" => id,
        "sourceThreadId" => me["id"],
        "targetThreadId" => target,
        "sourcePoint" => args["sourcePoint"],
        "title" => args["title"],
        "createdBy" => "agent",
        "creationSource" => "mcp"
      }

      with {:ok, %{"sequence" => sequence}} <- orchestration(Orchestration.dispatch(command)),
           do: {:ok, %{"sequence" => sequence, "targetThreadId" => target}}
    end
  end

  def run("t3_thread_merge_back", %{"targetThreadId" => target} = args, %{row: me} = caller) do
    with {:ok, _} <- writable(caller, target),
         {:ok, %{"sequence" => sequence}} <-
           orchestration(
             Orchestration.dispatch(%{
               "type" => "thread.merge_back",
               "commandId" => command_id(),
               "sourceThreadId" => me["id"],
               "targetThreadId" => target,
               "sourcePoint" => args["sourcePoint"],
               "createdBy" => "agent",
               "creationSource" => "mcp"
             })
           ),
         do: {:ok, %{"sequence" => sequence, "targetThreadId" => target}}
  end

  def run("t3_thread_update", %{"action" => action} = args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]),
         {:ok, command} <- metadata_command(action, args, row) do
      id = "command:mcp:thread-update:#{action}:" <> (args["clientRequestId"] || command_id())

      with {:ok, %{"sequence" => sequence}} <-
             orchestration(
               Orchestration.dispatch(
                 Map.merge(command, %{
                   "type" => "thread.metadata.update",
                   "commandId" => id,
                   "threadId" => row["id"]
                 })
               )
             ) do
        if action == "regenerate_title",
          do: Orchestration.generate_title(row["id"], first_message(row["id"]))

        thread = thread(row["id"])

        {:ok,
         %{
           "threadId" => row["id"],
           "action" => action,
           "commandId" => id,
           "sequence" => sequence,
           "title" => thread["title"],
           "titleRegeneration" => nil,
           "linkedPullRequest" => thread["linkedPullRequest"],
           "updatedAt" => thread["updatedAt"]
         }}
      end
    end
  end

  def run("t3_thread_configure", %{"modelSelection" => selection}, %{row: me} = caller) do
    with {:ok, _} <- writable(caller, nil) do
      type =
        if selection["instanceId"] in [nil, me["providerInstanceId"]],
          do: "thread.model-selection.set",
          else: "provider.switch"

      with {:ok, %{"sequence" => sequence}} <-
             orchestration(
               Orchestration.dispatch(%{
                 "type" => type,
                 "commandId" => command_id(),
                 "threadId" => me["id"],
                 "modelSelection" =>
                   Map.put_new(selection, "instanceId", me["providerInstanceId"])
               })
             ),
           do: {:ok, %{"sequence" => sequence}}
    end
  end

  def run("t3_thread_configuration", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      thread = thread(row["id"]) || row

      {:ok,
       %{
         "threadId" => row["id"],
         "modelSelection" => thread["modelSelection"],
         "runtimeMode" => thread["runtimeMode"],
         "interactionMode" => thread["interactionMode"]
       }}
    end
  end

  def run("t3_thread_organize", %{"action" => action} = args, caller) do
    with {:ok, row} <- writable(caller, args["threadId"]),
         {:ok, command} <- organize_command(action, args),
         {:ok, %{"sequence" => sequence}} <-
           command
           |> Map.merge(%{"commandId" => command_id(), "threadId" => row["id"]})
           |> Orchestration.dispatch()
           |> orchestration(),
         do: {:ok, %{"sequence" => sequence}}
  end

  def run("t3_thread_transfers", args, %{row: me}) do
    with {:ok, row} <- project_thread(me, args["threadId"]) do
      transfers =
        for transfer <- StreamState.list(stream(row["id"]), "context-transfer"),
            do: Map.take(transfer, ~w(id sourceThreadId targetThreadId status))

      {:ok, %{"transfers" => transfers}}
    end
  end

  def run("t3_thread_send_attachments", args, caller) do
    with {:ok, row} <- writable(caller, args["threadId"]),
         :ok <-
           if(thread(row["id"])["archivedAt"],
             do:
               {:error, "invalid_request",
                "Unarchive the target thread before sending attachments."},
             else: :ok
           ),
         {:ok, attachments} <- owned_attachments(row["id"], args["attachments"] || []) do
      id = command_id()

      command = %{
        "type" => "message.dispatch",
        "commandId" => id,
        "threadId" => row["id"],
        "messageId" => id,
        "senderThreadId" => caller.row["id"],
        "text" => args["message"] || "",
        "attachments" => attachments,
        "createdBy" => "agent",
        "creationSource" => "mcp"
      }

      with {:ok, _} <- orchestration(Orchestration.dispatch(command)) do
        run = message_run(row["id"], id)

        {:ok,
         %{
           "threadId" => row["id"],
           "messageId" => id,
           "runId" => run && run["id"],
           "status" => (run && run["status"]) || "queued"
         }}
      end
    end
  end

  def run("t3_attachment_prepare_upload", %{"upload" => upload}, caller) do
    with :ok <- live(caller) do
      case T3.Attachments.create_upload_url(upload) do
        {:ok, result} -> {:ok, result}
        {:error, message} -> {:error, "invalid_request", message}
      end
    end
  end

  def run("t3_attachment_discard", %{"attachmentId" => id}, caller) do
    with :ok <- live(caller) do
      {:ok, _} = T3.Attachments.delete(%{"attachmentId" => id})
      {:ok, %{}}
    end
  end

  def run("orchestrator_capabilities", _args, %{row: me}) do
    parent = thread(me["id"]) || me

    {:ok,
     %{
       "parentThreadId" => me["id"],
       "inheritedProviderInstanceId" => get_in(parent, ["modelSelection", "instanceId"]),
       "inheritedModel" => get_in(parent, ["modelSelection", "model"]),
       "runtimeMode" => parent["runtimeMode"],
       "interactionMode" => parent["interactionMode"],
       "providers" =>
         for provider <- T3.Environment.providers() do
           constraints = constraints(provider)

           %{
             "providerInstanceId" => provider["instanceId"],
             "driverKind" => provider["driver"],
             "displayName" => provider["displayName"],
             "models" =>
               for model <- provider["models"] || [] do
                 options = get_in(model, ["capabilities", "optionDescriptors"])

                 %{"id" => model["slug"], "label" => model["name"]}
                 |> then(&if(options, do: Map.put(&1, "options", options), else: &1))
               end,
             "canRunChildTask" => constraints == [],
             "canRunCrossProviderChildTask" => constraints == [],
             "constraints" => constraints
           }
         end,
       "features" => %{
         "appOwnedSubagents" => true,
         "asyncPolling" => true,
         "cancellation" => true,
         "batchThreadCreation" => true,
         "threadManagement" => true,
         "incrementalThreadRead" => true,
         "scheduledTasks" => true,
         "maxBatchThreads" => 20
       }
     }}
  end

  # --- helpers ----------------------------------------------------------------------------

  defp create_thread(parent, providers, key, request, index) do
    with {:ok, selection} <- target(parent, providers, request["target"]),
         {:ok, runtime_mode} <- mode(:runtime, parent, request["runtimeMode"]),
         {:ok, interaction_mode} <- mode(:interaction, parent, request["interactionMode"]) do
      thread_id = "thread:mcp:#{parent["id"]}:#{key}:#{index}"
      prompt = request["prompt"]

      created =
        Orchestration.dispatch(%{
          "type" => "thread.create",
          "commandId" => "command:mcp:create-thread:#{key}:#{index}",
          "threadId" => thread_id,
          "projectId" => parent["projectId"],
          "title" => title(parent["title"], prompt, request["title"], index),
          "modelSelection" => selection,
          "runtimeMode" => runtime_mode,
          "interactionMode" => interaction_mode,
          "branch" => parent["branch"],
          "worktreePath" => parent["worktreePath"],
          "createdBy" => "agent",
          "creationSource" => "mcp"
        })

      started =
        with {:ok, _} <- created do
          if prompt,
            do:
              Orchestration.dispatch(%{
                "type" => "message.dispatch",
                "commandId" => "command:mcp:dispatch-thread:#{key}:#{index}",
                "threadId" => thread_id,
                "senderThreadId" => parent["id"],
                "messageId" => "message:mcp:#{parent["id"]}:#{key}:#{index}",
                "text" => prompt,
                "attachments" => [],
                "modelSelection" => selection,
                "dispatchMode" => %{"type" => "start_immediately"},
                "createdBy" => "agent",
                "creationSource" => "mcp"
              }),
            else: created
        end

      case started do
        {:ok, _} ->
          thread = thread(thread_id)
          run = stream(thread_id) |> StreamState.list("run") |> List.last()

          {:ok,
           %{
             "threadId" => thread_id,
             "runId" => run && run["id"],
             "status" => (run && run["status"]) || "idle",
             "title" => thread["title"],
             "createdBy" => thread["createdBy"],
             "creationSource" => thread["creationSource"],
             "providerInstanceId" => selection["instanceId"],
             "model" => selection["model"]
           }}

        {:error, message} ->
          {:error, "orchestration_error",
           "Unable to create thread #{index + 1}: #{if is_binary(message), do: message, else: inspect(message)}"}
      end
    end
  end

  defp title(parent_title, prompt, title, index) do
    detail = [title, prompt] |> Enum.map(&String.trim(&1 || "")) |> Enum.find(&(&1 != ""))

    cond do
      detail == nil -> "#{parent_title} thread #{index + 1}"
      String.length(detail) > 80 -> String.slice(detail, 0, 77) <> "..."
      true -> detail
    end
  end

  # The provider and model a new thread runs on: the caller's unless the target
  # names another, which must be one this node can run.
  defp target(parent, providers, target) do
    target = target || %{}
    inherited = parent["modelSelection"] || %{}

    instance =
      target["providerInstanceId"] ||
        (target["driverKind"] &&
           Enum.find_value(
             Enum.sort_by(providers, &(&1["instanceId"] != inherited["instanceId"])),
             &(&1["driver"] == target["driverKind"] and constraints(&1) == [] and
                 &1["instanceId"])
           )) ||
        if(target["driverKind"], do: :none, else: inherited["instanceId"])

    provider = Enum.find(providers, &(&1["instanceId"] == instance))

    model =
      target["model"] ||
        if instance == inherited["instanceId"],
          do: inherited["model"],
          else: get_in(provider || %{}, ["models", Access.at(0), "slug"])

    models = for model <- (provider && provider["models"]) || [], do: model["slug"]

    cond do
      instance == :none ->
        {:error, "provider_unavailable",
         "No available provider instance for driver #{target["driverKind"]}."}

      provider == nil ->
        {:error, "provider_unavailable", "Provider instance #{instance} is not registered."}

      target["driverKind"] not in [nil, provider["driver"]] ->
        {:error, "invalid_request",
         "Provider instance #{instance} uses driver #{provider["driver"]}, not #{target["driverKind"]}."}

      constraints(provider) != [] ->
        {:error, "provider_unavailable",
         "Provider #{instance} cannot run a child task: #{Enum.join(constraints(provider), " ")}"}

      model == nil ->
        {:error, "model_unavailable", "Provider #{instance} has no model available."}

      target["model"] != nil and models != [] and target["model"] not in models ->
        {:error, "model_unavailable",
         "Model #{target["model"]} is not advertised by provider #{instance}."}

      instance == inherited["instanceId"] and model == inherited["model"] and
          target["options"] == nil ->
        {:ok, inherited}

      target["options"] == nil ->
        {:ok, %{"instanceId" => instance, "model" => model}}

      true ->
        {:ok, %{"instanceId" => instance, "model" => model, "options" => target["options"]}}
    end
  end

  # Why a provider cannot run a thread now; empty when it can.
  defp constraints(provider) do
    [
      provider["enabled"] == false && "Provider instance is disabled.",
      provider["installed"] == false && "Provider executable is not installed.",
      provider["availability"] == "unavailable" &&
        (provider["unavailableReason"] || "Provider driver is unavailable."),
      provider["status"] in ["error", "disabled"] &&
        (provider["message"] || "Provider status is #{provider["status"]}."),
      get_in(provider, ["auth", "status"]) == "unauthenticated" &&
        "Provider is not authenticated."
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp metadata_command("rename", %{"title" => title}, _row)
       when is_binary(title) and title != "",
       do: {:ok, %{"title" => title}}

  defp metadata_command("rename", _args, _row),
    do: {:error, "invalid_request", "rename requires title."}

  # The new title comes from the thread's first message, in the background.
  defp metadata_command("regenerate_title", _args, row) do
    if first_message(row["id"]),
      do: {:ok, %{}},
      else: {:error, "invalid_request", "The thread has no message to take a title from."}
  end

  defp metadata_command("link_pull_request", %{"pullRequest" => %{} = pull_request}, row),
    do:
      {:ok,
       %{
         "linkedPullRequest" =>
           pull_request
           |> Map.take(~w(repository number url))
           |> Map.put("projectId", row["projectId"])
       }}

  defp metadata_command("link_pull_request", _args, _row),
    do: {:error, "invalid_request", "link_pull_request requires pullRequest."}

  defp metadata_command("unlink_pull_request", _args, _row),
    do: {:ok, %{"linkedPullRequest" => nil}}

  defp metadata_command(action, _args, _row),
    do: {:error, "invalid_request", "Unknown action #{action}."}

  defp organize_command("snooze", %{"snoozedUntil" => until}) when is_binary(until),
    do: {:ok, %{"type" => "thread.snooze", "snoozedUntil" => until}}

  defp organize_command("snooze", _args),
    do: {:error, "invalid_request", "snooze requires snoozedUntil."}

  defp organize_command("mark_unread", _args), do: {:ok, %{"type" => "thread.mark-unread"}}

  defp organize_command(action, _args)
       when action in ~w(pin unpin settle unsettle unsnooze archive unarchive),
       do: {:ok, %{"type" => "thread." <> action}}

  defp organize_command(action, _args),
    do: {:error, "invalid_request", "Unknown action #{action}."}

  defp first_message(thread_id) do
    stream(thread_id)
    |> StreamState.list("message")
    |> Enum.find_value(&(&1["role"] == "user" and (&1["text"] || "") != "" and &1["text"]))
  end

  defp pending?(%{"id" => "pending-" <> _}), do: true
  defp pending?(_attachment), do: false

  # Pending uploads, or attachments the target thread already has (as it stored them).
  defp owned_attachments(thread_id, requested) do
    owned =
      for message <- StreamState.list(stream(thread_id), "message"),
          attachment <- message["attachments"] || [],
          into: %{},
          do: {attachment["id"], attachment}

    Enum.reduce_while(requested, {:ok, []}, fn attachment, {:ok, acc} ->
      case if(pending?(attachment), do: attachment, else: owned[attachment["id"]]) do
        nil ->
          {:halt,
           {:error, "invalid_request",
            "Attachments must be pending uploads or already belong to the target thread."}}

        canonical ->
          {:cont, {:ok, acc ++ [canonical]}}
      end
    end)
  end
end
