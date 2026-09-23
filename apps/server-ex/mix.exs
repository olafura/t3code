defmodule T3.MixProject do
  use Mix.Project

  def project do
    [
      app: :t3,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      releases: [
        t3: [
          include_executables_for: [:unix],
          strip_beams: true,
          steps: [:assemble, &stage_cursor_acp/1]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {T3.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:erlexec, "~> 2.5"},
      {:exile, "~> 0.15"},
      {:exqlite, "~> 0.41"},
      {:libcluster, "~> 3.5"},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:tz, "~> 0.28"},
      {:websock_adapter, "~> 0.6"},
      {:x509, "~> 0.9"}
    ]
  end

  # The Cursor sidecar (packages/cursor-acp) ships in the release's priv/, bundled to
  # plain JavaScript so any Node 22+ runs it, including an Electron binary. Its SDK is
  # installed flat by npm (no symlinks, this platform's native package only), so the
  # tree survives copying into an app bundle and code signing.
  defp stage_cursor_acp(release) do
    root = Path.expand("../..", __DIR__)
    package = Path.join(root, "packages/cursor-acp")
    target = Path.join([release.path, "lib", "t3-#{release.version}", "priv", "cursor-acp"])
    File.rm_rf!(target)
    File.mkdir_p!(target)

    %{"dependencies" => deps} =
      package |> Path.join("package.json") |> File.read!() |> JSON.decode!()

    manifest = %{"private" => true, "type" => "module", "dependencies" => deps}
    File.write!(Path.join(target, "package.json"), JSON.encode!(manifest))
    run!("npm", ~w(install --omit=dev --no-audit --no-fund --no-bin-links), target)

    run!(
      Path.join(root, "node_modules/.bin/esbuild"),
      ~w(src/main.ts --bundle --platform=node --format=esm --external:@cursor/sdk) ++
        ["--outfile=#{target}/main.mjs"],
      package
    )

    release
  end

  defp run!(command, args, cd) do
    {_, 0} = System.cmd(command, args, cd: cd, into: IO.stream(), stderr_to_stdout: true)
  end
end
