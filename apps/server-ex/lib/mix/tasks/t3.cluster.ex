defmodule Mix.Tasks.T3.Cluster do
  @shortdoc "Creates, invites to, and joins a cluster of your machines"
  @moduledoc """
      mix t3.cluster init ADDRESS         # first machine: new cluster CA + its own cert
      mix t3.cluster invite ADDRESS FILE  # on a member: write a join bundle for ADDRESS
      mix t3.cluster join FILE            # on the new machine: install the bundle
      mix t3.cluster vm-args              # flags to boot this node clustered

  ADDRESS is how other members reach the machine, usually its Tailscale IP. A join
  bundle contains the new machine's private key: move it privately and delete it.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    home = Application.fetch_env!(:t3, :home)

    case args do
      ["init", address] ->
        case T3.Cluster.init(home, address) do
          :ok ->
            Mix.shell().info("Created cluster CA and certificate for #{address}")

          {:error, :already_initialized} ->
            Mix.raise("#{T3.Cluster.dir(home)} already has a cluster")
        end

      ["invite", address, file] ->
        File.write!(file, T3.Cluster.invite(home, address))
        File.chmod!(file, 0o600)
        Mix.shell().info("Wrote join bundle for #{address} to #{file}")

      ["join", file] ->
        :ok = T3.Cluster.join(home, File.read!(file))
        Mix.shell().info("Joined as t3@#{T3.Cluster.address(home)}")

      ["vm-args"] ->
        IO.puts(T3.Cluster.vm_args(home) || Mix.raise("not in a cluster yet"))

      _ ->
        Mix.raise("see `mix help t3.cluster`")
    end
  end
end
