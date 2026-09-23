defmodule Mix.Tasks.T3.Server do
  @shortdoc "Runs the node and prints its client URL"
  @moduledoc """
  Starts the node in the foreground and prints the WebSocket URL with its token.

      mix t3.server
      elixir --name t3@HOST -S mix t3.server   # as a named, clusterable node
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    port = Application.get_env(:t3, :port, 3780)
    Mix.shell().info("T3 node #{node()} ws://127.0.0.1:#{port}/ws?token=#{T3.Web.token()}")
    Process.sleep(:infinity)
  end
end
