defmodule T3.Rpc do
  @moduledoc """
  Client RPCs a node serves, by the method names of `packages/contracts/src/rpc.ts`.
  Run on the node that owns the environment (`T3.Web.Socket` routes them).
  """

  @doc """
  Handles one RPC. An error is a message, or a map with a `"message"` plus the
  contract error's `"_tag"` and fields, which the client decodes.
  """
  @spec handle(String.t(), term) :: {:ok, term} | {:error, String.t() | map}
  def handle("orchestration." <> _ = method, payload),
    do: T3.Orchestration.handle(method, payload)

  def handle("projects.mutate", mutation), do: T3.Projects.mutate(mutation)
  def handle("server.getSettings", _input), do: {:ok, T3.Settings.settings()}

  # A client applies settings patches itself and writes the whole document back
  # with the version it read (see `T3.Settings`).
  def handle("t3.readSettings", _input) do
    {settings, version} = T3.Settings.get()
    {:ok, %{"settings" => settings, "version" => version}}
  end

  def handle("t3.writeSettings", %{"settings" => %{} = settings, "version" => version}) do
    case T3.Settings.put(settings, version) do
      {:ok, version} -> {:ok, %{"version" => version}}
      {:error, :stale} -> {:error, %{"_tag" => "StaleSettings", "message" => "settings changed"}}
    end
  end

  # One thread's entities at once, for a client that needs its projection without
  # subscribing (a socket holds one subscription per stream).
  def handle("t3.threadRows", %{"threadId" => thread_id}) do
    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))

    {:ok,
     %{
       "rows" => for({kind, id, entity} <- T3.StreamState.rows(state), do: [kind, id, entity]),
       "offset" => state.seq,
       "at" => state.updated_at
     }}
  end

  def handle("filesystem.browse", input), do: T3.Projects.browse(input)
  def handle("shell.openInEditor", input), do: T3.Editors.open(input)
  def handle("server.discoverSourceControl", input), do: T3.SourceControl.discover(input)
  def handle("sourceControl.lookupRepository", input), do: T3.SourceControl.lookup(input)
  def handle("sourceControl.cloneRepository", input), do: T3.SourceControl.clone(input)
  def handle("sourceControl.publishRepository", input), do: T3.SourceControl.publish(input)
  def handle("projectClone.start", input), do: T3.ProjectClones.start(input)
  def handle("projectClone.retry", input), do: T3.ProjectClones.retry(input)
  def handle("projectClone.cancel", input), do: T3.ProjectClones.cancel(input)
  def handle("scheduledTasks.list", input), do: T3.ScheduledTasks.list(input)
  def handle("scheduledTasks.upsert", input), do: T3.ScheduledTasks.upsert(input)
  def handle("scheduledTasks.delete", input), do: T3.ScheduledTasks.delete(input)
  def handle("scheduledTasks.setEnabled", input), do: T3.ScheduledTasks.set_enabled(input)
  def handle("scheduledTasks.runNow", input), do: T3.ScheduledTasks.run_now(input)
  def handle("server.refreshProviders", input), do: T3.Environment.refresh_providers(input)
  def handle("t3.upsertKeybinding", input), do: T3.Keybindings.upsert(input)
  def handle("t3.removeKeybinding", input), do: T3.Keybindings.remove(input)
  def handle("projects.searchEntries", input), do: T3.Workspace.search_entries(input)
  def handle("attachments.createUploadUrl", input), do: T3.Attachments.create_upload_url(input)
  def handle("attachments.delete", input), do: T3.Attachments.delete(input)
  def handle("assets.createUrl", input), do: T3.Attachments.create_url(input)
  def handle("worktreeSetup.cancel", input), do: T3.WorktreeSetup.cancel(input)
  def handle("assets.persistChatAttachments", input), do: T3.Attachments.persist(input)
  def handle("projects.listEntries", input), do: T3.Workspace.list_entries(input)
  def handle("projects.readFile", input), do: T3.Workspace.read_file(input)
  def handle("projects.writeFile", input), do: T3.Workspace.write_file(input)
  def handle("projects.searchContents", input), do: T3.Workspace.search_contents(input)
  def handle("server.searchAcpRegistry", input), do: T3.Acp.Catalog.search(input)
  def handle("server.prepareAcpRegistryAgent", input), do: T3.Acp.Catalog.prepare(input)

  def handle("server.uninstallAcpRegistryManagedBinary", input),
    do: T3.Acp.Catalog.uninstall(input)

  def handle("server.listAcpRegistrySessions", input), do: T3.Acp.Sessions.list(input)
  def handle("server.importAcpRegistrySession", input), do: T3.Acp.Sessions.import(input)
  def handle("server.deleteAcpRegistrySession", input), do: T3.Acp.Sessions.delete(input)
  def handle("server.listAcpRegistryProviders", input), do: T3.Acp.Sessions.providers(input)
  def handle("server.setAcpRegistryProvider", input), do: T3.Acp.Sessions.set_provider(input)

  def handle("server.disableAcpRegistryProvider", input),
    do: T3.Acp.Sessions.disable_provider(input)

  def handle("server.logoutAcpRegistry", input), do: T3.Acp.Sessions.logout(input)
  def handle("provider.auth.start", input), do: T3.ProviderAuth.start(input)
  def handle("provider.auth.respond", input), do: T3.ProviderAuth.respond(input)
  def handle("provider.auth.cancel", input), do: T3.ProviderAuth.cancel(input)
  def handle("provider.auth.logout", input), do: T3.ProviderAuth.logout(input)
  def handle("provider.auth.complete", input), do: T3.ProviderAuth.complete(input)

  def handle("agentSessions.scan", input), do: T3.AgentSessions.scan(input)
  def handle("agentSessions.import", input), do: T3.AgentSessions.import_project(input)
  def handle("review.getDiffPreview", input), do: T3.Review.diff_preview(input)
  def handle("review.getDiffFileContents", input), do: T3.Review.file_contents(input)
  def handle("vcs.refreshStatus", input), do: T3.Vcs.refresh_status(input)
  def handle("vcs.listRefs", input), do: T3.Vcs.list_refs(input)
  def handle("vcs.switchRef", input), do: T3.Vcs.switch_ref(input)
  def handle("vcs.createRef", input), do: T3.Vcs.create_ref(input)
  def handle("vcs.init", input), do: T3.Vcs.init(input)
  def handle("vcs.pull", input), do: T3.Vcs.pull(input)
  def handle("vcs.createWorktree", input), do: T3.Vcs.create_worktree(input)
  def handle("vcs.removeWorktree", input), do: T3.Vcs.remove_worktree(input)
  def handle("terminal.open", input), do: T3.Terminal.open(input)
  def handle("terminal.write", input), do: T3.Terminal.write(input)
  def handle("terminal.resize", input), do: T3.Terminal.resize(input)
  def handle("terminal.clear", input), do: T3.Terminal.clear(input)
  def handle("terminal.restart", input), do: T3.Terminal.restart(input)
  def handle("terminal.close", input), do: T3.Terminal.close(input)
  def handle(method, _payload), do: {:error, "#{method} is not served by this node yet"}
end
