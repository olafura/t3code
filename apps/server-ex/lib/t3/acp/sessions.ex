defmodule T3.Acp.Sessions do
  @moduledoc """
  An ACP agent's own sessions and model providers, managed from a project: the
  `server.*AcpRegistry*` session, provider, and logout RPCs. Each request starts the
  agent in the project's root (`T3.Acp.with_agent/3`), makes one call, and stops it.

  Importing a session creates a thread whose provider thread points at the session,
  as the Node server does, so the first message resumes or loads it; the history
  stays with the agent. The thread id derives from the instance and session id, so
  importing twice finds the same thread.
  """

  alias T3.JsonRpc.Connection
  alias T3.Orchestration.Entities
  alias T3.{Patch, StreamState}

  @timeout 60_000

  @doc "`server.listAcpRegistrySessions`: the agent's sessions for a project."
  def list(%{"instanceId" => instance, "projectId" => project_id} = input) do
    params = if is_binary(input["cursor"]), do: %{"cursor" => input["cursor"]}, else: %{}

    with {:ok, root} <- project_root(project_id),
         {:ok, {result, caps}} <-
           call(instance, root, "session/list", Map.put(params, "cwd", root), :list) do
      {:ok,
       %{
         "sessions" =>
           for(
             %{"sessionId" => id, "cwd" => cwd} = session <-
               Enum.take(result["sessions"] || [], 256),
             is_binary(id) and is_binary(cwd),
             do: session_row(instance, session)
           ),
         "nextCursor" => text(result["nextCursor"], 2048),
         "canLoad" => caps["loadSession"] == true,
         "canResume" => is_map(get_in(caps, ["sessionCapabilities", "resume"])),
         "canDelete" => is_map(get_in(caps, ["sessionCapabilities", "delete"]))
       }}
    end
  end

  defp session_row(instance, session) do
    thread_id = thread_id(instance, session["sessionId"])

    %{
      "sessionId" => session["sessionId"],
      "cwd" => session["cwd"],
      "additionalDirectories" =>
        (session["additionalDirectories"] || []) |> Enum.filter(&is_binary/1) |> Enum.take(32),
      "title" => text(session["title"], 1024),
      "updatedAt" => text(session["updatedAt"], 128),
      "importedThreadId" => if(thread?(thread_id), do: thread_id)
    }
  end

  @doc "`server.importAcpRegistrySession`: a thread that continues the session."
  def import(
        %{"instanceId" => instance, "projectId" => project_id, "sessionId" => session_id} = input
      ) do
    thread_id = thread_id(instance, session_id)
    caps = T3.Acp.capabilities(instance) || %{}

    cond do
      not T3.Acp.agent?(instance) ->
        error("instance_not_found", "#{instance} is not an ACP agent on this node.")

      match?({:error, _}, project_root(project_id)) ->
        error("project_not_found", "The project is not on this node.")

      caps != %{} and caps["loadSession"] != true and
          not is_map(get_in(caps, ["sessionCapabilities", "resume"])) ->
        error("session_resume_unsupported", "The ACP agent cannot load or resume sessions.")

      true ->
        write_thread(thread_id, instance, project_id, session_id, input)
    end
  end

  defp write_thread(thread_id, instance, project_id, session_id, input) do
    at = Entities.now()
    provider_thread_id = "provider-thread:#{instance}:#{thread_id}"

    thread =
      Entities.thread(
        %{
          "threadId" => thread_id,
          "projectId" => project_id,
          "title" => input["title"] || "Imported ACP session",
          "modelSelection" => %{"instanceId" => instance, "model" => default_model(instance)},
          "runtimeMode" => "approval-required",
          "interactionMode" => "default"
        },
        at
      )

    provider_thread =
      Entities.provider_thread(provider_thread_id, thread_id, nil, nil, at, instance, instance)
      |> Map.merge(%{
        "nativeThreadRef" => Entities.provider_ref(session_id, instance),
        "nativeMetadata" =>
          Map.reject(
            %{
              "itemIdentityVersion" => 2,
              "title" => input["title"],
              "updatedAt" => input["updatedAt"]
            },
            fn {_, v} -> is_nil(v) end
          )
      })

    T3.Streams.transact(thread_id, :thread, fn state ->
      if StreamState.get(state, "thread")[thread_id] do
        {[], {:ok, %{"threadId" => thread_id, "imported" => false}}}
      else
        {[
           {"thread", thread_id, Patch.diff(nil, thread)},
           {"provider-thread", provider_thread_id, Patch.diff(nil, provider_thread)}
         ], {:ok, %{"threadId" => thread_id, "imported" => true}}}
      end
    end)
  end

  defp default_model(instance) do
    models = (T3.Acp.entry(instance) || %{})["models"] || []
    model = Enum.find(models, & &1["isDefault"]) || List.first(models)
    (model || %{})["slug"] || "default"
  end

  @doc "`server.deleteAcpRegistrySession`: deletes a session that was not imported."
  def delete(%{"instanceId" => instance, "projectId" => project_id, "sessionId" => session_id}) do
    with {:ok, root} <- project_root(project_id) do
      if thread?(thread_id(instance, session_id)) do
        error(
          "session_delete_failed",
          "Delete the imported T3 thread before deleting its native ACP session."
        )
      else
        with {:ok, _} <-
               call(instance, root, "session/delete", %{"sessionId" => session_id}, :delete),
             do: {:ok, %{"deleted" => true}}
      end
    end
  end

  @doc "`server.listAcpRegistryProviders`: the model providers the agent can use."
  def providers(%{"instanceId" => instance, "projectId" => project_id}) do
    with {:ok, root} <- project_root(project_id),
         {:ok, {result, _}} <- call(instance, root, "providers/list", %{}, :providers) do
      {:ok,
       %{
         "providers" =>
           for %{"providerId" => id} = provider <- Enum.take(result["providers"] || [], 64),
               is_binary(id) do
             current = provider["current"]

             %{
               "providerId" => id,
               "supported" =>
                 (provider["supported"] || []) |> Enum.filter(&is_binary/1) |> Enum.take(16),
               "required" => provider["required"] == true,
               "current" =>
                 if(
                   is_map(current) and is_binary(current["apiType"]) and
                     is_binary(current["baseUrl"]),
                   do: Map.take(current, ["apiType", "baseUrl"])
                 )
             }
           end
       }}
    end
  end

  @doc "`server.setAcpRegistryProvider`: points one of the agent's providers at an API."
  def set_provider(%{"instanceId" => instance, "projectId" => project_id} = input) do
    params = Map.take(input, ["providerId", "apiType", "baseUrl", "headers"])

    with {:ok, root} <- project_root(project_id),
         {:ok, _} <- call(instance, root, "providers/set", params, :providers) do
      T3.Acp.forget(instance)
      {:ok, %{"configured" => true}}
    end
  end

  @doc "`server.disableAcpRegistryProvider`."
  def disable_provider(%{"instanceId" => instance, "projectId" => project_id} = input) do
    with {:ok, root} <- project_root(project_id),
         {:ok, _} <-
           call(instance, root, "providers/disable", Map.take(input, ["providerId"]), :providers) do
      T3.Acp.forget(instance)
      {:ok, %{"disabled" => true}}
    end
  end

  @doc "`server.logoutAcpRegistry`: signs the agent out; it is probed again."
  def logout(%{"instanceId" => instance}) do
    with {:ok, _} <- call(instance, System.tmp_dir!(), "logout", %{}, :logout) do
      T3.Acp.forget(instance)
      T3.Settings.notify_providers()
      {:ok, %{"loggedOut" => true}}
    end
  end

  # --- helpers ---------------------------------------------------------------------

  @doc "The thread an imported session becomes, as the Node server derives it."
  def thread_id(instance, session_id) do
    parts = [
      "provider",
      "acpRegistry",
      "provider-instance",
      instance,
      "native-thread",
      session_id
    ]

    Enum.join(["thread" | Enum.map(parts, &encode_part/1)], ":")
  end

  # JavaScript's encodeURIComponent.
  defp encode_part(part), do: URI.encode(part, &(URI.char_unreserved?(&1) or &1 in ~c"!'()*"))

  defp thread?(thread_id) do
    case T3.Shell.row(node(), thread_id) do
      {"thread", row} -> row["deletedAt"] == nil
      _ -> false
    end
  end

  defp project_root(project_id) do
    case T3.Shell.row(node(), project_id) do
      # Deleted projects leave the shell.
      {"project", %{"workspaceRoot" => root}} when is_binary(root) ->
        {:ok, root}

      _ ->
        error("project_not_found", "The project is not on this node.")
    end
  end

  # The capability each operation needs, and the failure it reports.
  @needs %{
    list: {["sessionCapabilities", "list"], "session_list_unsupported", "session_import_failed"},
    delete:
      {["sessionCapabilities", "delete"], "session_delete_unsupported", "session_delete_failed"},
    providers: {["providers"], "providers_unsupported", "provider_configuration_failed"},
    logout: {["auth", "logout"], "logout_unsupported", "logout_failed"}
  }

  defp call(instance, cwd, method, params, op) do
    {path, unsupported, failed} = @needs[op]

    result =
      T3.Acp.with_agent(instance, cwd, fn conn, init ->
        caps = init["agentCapabilities"] || %{}

        if is_map(get_in(caps, path)) do
          with {:ok, result} <- Connection.call(conn, method, params, @timeout),
               do: {:ok, {result || %{}, caps}}
        else
          {:unsupported, "The ACP agent does not support #{method}."}
        end
      end)

    case result do
      {:ok, _} = ok -> ok
      {:unsupported, message} -> error(unsupported, message)
      {:error, %{"_tag" => _} = detail} -> {:error, detail}
      {:error, reason} -> error(reason_for(reason, failed), message(reason))
    end
  end

  # ACP reports a missing sign-in as error -32000.
  defp reason_for(%{"code" => -32000}, _failed), do: "authentication_failed"
  defp reason_for(_reason, failed), do: failed

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp text(value, max) when is_binary(value) and value != "", do: String.slice(value, 0, max)
  defp text(_, _), do: nil

  defp error(reason, message),
    do:
      {:error, %{"_tag" => "AcpRegistryOperationError", "reason" => reason, "message" => message}}
end
