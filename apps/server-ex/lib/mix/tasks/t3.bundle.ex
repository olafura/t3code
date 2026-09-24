defmodule Mix.Tasks.T3.Bundle do
  @shortdoc "Packs the built release into an upgrade bundle"
  @moduledoc """
  Packs `_build/prod/rel/t3` (build it first with `MIX_ENV=prod mix release`) into
  the bundle nodes install to move to its version (`T3.Upgrade`):

      mix t3.bundle [OUT_DIR]

  Writes `t3-node-<version>-<platform>.tar.gz` and its `.sha256` to `OUT_DIR`
  (default `_build/prod`), the names release artifacts are published under.
  Prints the bundle's path.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.shell().info(bundle(List.first(args)))
  end

  @doc "Builds the bundle from the prod release; returns its path."
  def bundle(out_dir \\ nil) do
    root = Path.expand("_build/prod/rel/t3")

    [erts, version] =
      root |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    manifest = Path.join([root, "releases", version, "upgrade.json"])

    File.exists?(manifest) ||
      Mix.raise("#{manifest} is missing; build the release with MIX_ENV=prod mix release")

    platform = manifest |> File.read!() |> JSON.decode!() |> Map.fetch!("platform")
    out_dir = Path.expand(out_dir || "_build/prod")
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, T3.Upgrade.Source.file_name(version, platform))

    entries =
      [Path.join(root, "bin"), Path.join(root, "lib"), Path.join([root, "releases", version])] ++
        [Path.join(root, "erts-#{erts}")]

    files =
      for entry <- entries,
          do: {String.to_charlist(Path.relative_to(entry, root)), String.to_charlist(entry)}

    :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])

    sum = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    File.write!(path <> ".sha256", "#{sum}  #{Path.basename(path)}\n")
    path
  end
end
