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
  def handle("filesystem.browse", input), do: T3.Projects.browse(input)
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
