defmodule Mix.Tasks.T3.Pair do
  @shortdoc "Prints a one-time pairing URL for this node"
  @moduledoc """
  Mints a pairing token (valid 5 minutes, single use) and prints the URL a client
  opens or pastes to pair with this node:

      mix t3.pair [--admin] [BASE_URL]

  `BASE_URL` defaults to the local listener, `http://127.0.0.1:3780`. `--admin` gives
  the client the administrative scopes: pairing others, and linking T3 Connect.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:exqlite)
    home = Application.fetch_env!(:t3, :home)
    {opts, args} = OptionParser.parse!(args, strict: [admin: :boolean])
    base = List.first(args) || "http://127.0.0.1:#{Application.get_env(:t3, :port, 3780)}"
    token = T3.Auth.create_pairing_token(Path.join(home, "t3.sqlite"), opts[:admin] == true)
    Mix.shell().info("#{String.trim_trailing(base, "/")}/pair#token=#{token}")
  end
end
