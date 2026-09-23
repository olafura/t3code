defmodule Mix.Tasks.T3.Import do
  @shortdoc "Imports a Node server state.sqlite into this node's store"
  @moduledoc """
  Imports the event log of a Node T3 server into the Elixir node's store.

      mix t3.import PATH/TO/state.sqlite

  The source is opened read-only, but it must not be a database a running server has
  open for writing: snapshot it first with `VACUUM INTO` (see AGENTS.md, Test data).
  """

  use Mix.Task

  @impl true
  def run([source]) do
    Mix.Task.run("app.config")
    home = Application.fetch_env!(:t3, :home)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = T3.Store.start_link(path: Path.join(home, "t3.sqlite"))

    {us, {:ok, report}} = :timer.tc(fn -> T3.Import.V2.run(Path.expand(source)) end)

    Mix.shell().info("""
    Imported #{report.streams} streams in #{div(us, 1000)} ms into #{home}
      events:  #{report.source_events} -> #{report.events}
      payload: #{mb(report.source_bytes)} MB -> #{mb(report.bytes)} MB
    """)
  end

  def run(_), do: Mix.raise("usage: mix t3.import PATH/TO/state.sqlite")

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
end
