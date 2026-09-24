defmodule Mix.Tasks.T3.Upgrade do
  @shortdoc "Moves running nodes to this checkout's code"
  @moduledoc """
  Upgrades running nodes from this checkout, in place where the change allows
  (`T3.Upgrade`):

      mix t3.upgrade NODE [NODE ...] [--cookie COOKIE]
      mix t3.upgrade --dev NODE [NODE ...] [--cookie COOKIE]

  Without `--dev`, builds the prod release and its bundle, sends the bundle to the
  first node, and has each named node update to it; the others fetch it from the
  first over HTTP. Nodes must run a release under `bin/t3-service` for changes that
  need a restart.

  With `--dev`, compiles and has nodes started from this checkout (`mix run`)
  load what changed.

  Clustered nodes use TLS distribution: run the task with the cluster's flags,
  `elixir --erl "$(mix t3.cluster vm-args)" -S mix t3.upgrade ...`. Otherwise a
  hidden short-name node is started with `--cookie`.
  """

  use Mix.Task

  @chunk 256 * 1024

  @impl true
  def run(args) do
    {opts, nodes} = OptionParser.parse!(args, strict: [dev: :boolean, cookie: :string])
    nodes = Enum.map(nodes, &String.to_atom/1)
    nodes != [] || Mix.raise("Name the nodes to upgrade, e.g. t3a@my-mac")

    if opts[:dev], do: Mix.Task.run("compile"), else: build()
    connect(nodes, opts[:cookie])

    if opts[:dev], do: dev(nodes), else: release(nodes)
  end

  defp build do
    {_, 0} =
      System.cmd("mix", ~w(release --overwrite),
        env: [{"MIX_ENV", "prod"}],
        into: IO.stream(),
        stderr_to_stdout: true
      )
  end

  defp dev(nodes) do
    for node <- nodes do
      case :erpc.call(node, T3.Upgrade, :reload_checkout, [], 60_000) do
        {:ok, %{changed: changed, needs_restart: restart}} ->
          Mix.shell().info("#{node}: loaded #{length(changed)} modules")

          if restart != [],
            do:
              Mix.shell().info("#{node}: restart for #{Enum.map_join(restart, ", ", &inspect/1)}")

        {:error, reason} ->
          Mix.shell().error("#{node}: #{inspect(reason)}")
      end
    end
  end

  defp release([first | _] = nodes) do
    path = Mix.Tasks.T3.Bundle.bundle()
    manifest = path |> manifest()
    version = manifest["version"]
    platform = manifest["platform"]
    send_bundle(first, version, platform, path)

    for node <- nodes do
      case :erpc.call(
             node,
             T3.Upgrade,
             :update,
             [%{"targetVersion" => version}],
             :timer.minutes(15)
           ) do
        {:ok, result} -> Mix.shell().info("#{node}: #{result["method"]} to #{version}")
        {:error, %{"reason" => reason}} -> Mix.shell().error("#{node}: #{reason}")
      end
    end
  end

  defp send_bundle(node, version, platform, path) do
    :ok = :erpc.call(node, T3.Upgrade.Source, :receive_part, [version, platform, :begin])

    path
    |> File.stream!(@chunk)
    |> Enum.each(fn data ->
      :ok =
        :erpc.call(node, T3.Upgrade.Source, :receive_part, [version, platform, {:chunk, data}])
    end)

    sum = (path <> ".sha256") |> File.read!() |> String.split() |> List.first()
    :ok = :erpc.call(node, T3.Upgrade.Source, :receive_part, [version, platform, {:finish, sum}])
  end

  defp manifest(path) do
    {:ok, files} = :erl_tar.extract(String.to_charlist(path), [:compressed, :memory])

    Enum.find_value(files, fn {name, data} ->
      if String.ends_with?(to_string(name), "upgrade.json"), do: JSON.decode!(data)
    end)
  end

  defp connect(nodes, cookie) do
    unless Node.alive?() do
      name = :"t3upgrade#{System.unique_integer([:positive])}"
      {:ok, _} = Node.start(name, name_domain: :shortnames, hidden: true)
    end

    if cookie, do: Node.set_cookie(String.to_atom(cookie))

    for node <- nodes, do: Node.connect(node) || Mix.raise("Could not reach #{node}")
  end
end
