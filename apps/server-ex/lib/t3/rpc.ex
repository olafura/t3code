defmodule T3.Rpc do
  @moduledoc """
  Client RPCs a node serves, by the method names of `packages/contracts/src/rpc.ts`.
  Run on the node that owns the environment (`T3.Web.Socket` routes them).
  """

  @spec handle(String.t(), term) :: {:ok, term} | {:error, String.t()}
  def handle("orchestration." <> _ = method, payload),
    do: T3.Orchestration.handle(method, payload)

  def handle("projects.mutate", mutation), do: T3.Projects.mutate(mutation)
  def handle("filesystem.browse", input), do: T3.Projects.browse(input)
  def handle(method, _payload), do: {:error, "#{method} is not served by this node yet"}
end
