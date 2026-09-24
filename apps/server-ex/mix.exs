defmodule T3.MixProject do
  use Mix.Project

  def project do
    [
      app: :t3,
      # Nodes carry the T3 version, so clients compare them like any server.
      version: t3_version(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      releases: [
        t3: [
          include_executables_for: [:unix],
          strip_beams: true,
          steps: [:assemble, &stage_cursor_acp/1, &write_upgrade_manifest/1]
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
      {:mint_web_socket, "~> 1.0"},
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

  # `T3_VERSION` names a build apart from the package's release (nightlies, local builds).
  defp t3_version do
    System.get_env("T3_VERSION") || package_version()
  end

  defp package_version do
    Path.expand("../server/package.json", __DIR__)
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("version")
  end

  # What a running node compares with a new release to decide whether it can load
  # the new code in place (`T3.Upgrade`): the runtime, applications, native
  # libraries and configuration, each of which only a restart can change.
  defp write_upgrade_manifest(release) do
    lib = Path.join(release.path, "lib")
    rel = Path.join([release.path, "releases", release.version])

    digest = fn paths ->
      paths
      |> Enum.sort()
      # sys.config names its own release directory, which changes with every version.
      |> Enum.map(
        &{Path.relative_to(&1, release.path) |> String.replace(release.version, "{version}"),
         &1 |> File.read!() |> String.replace(release.version, "{version}")}
      )
      |> :erlang.term_to_binary()
      |> then(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
    end

    # From the release itself: `lib/` can hold other versions' directories.
    apps =
      for {name, properties} <- release.applications,
          into: %{},
          do: {to_string(name), to_string(properties[:vsn])}

    manifest = %{
      "version" => release.version,
      "otpRelease" => to_string(:erlang.system_info(:otp_release)),
      "erts" => release.erts_version |> to_string(),
      "platform" => platform(),
      "applications" => apps,
      "nifs" =>
        for {name, vsn} <- apps, into: %{} do
          libs =
            Path.wildcard(Path.join([lib, "#{name}-#{vsn}", "priv", "**", "*.{so,dylib,dll}"]))

          {name, digest.(libs)}
        end,
      "config" =>
        [
          app_config(Path.join(rel, "sys.config")),
          digest.(
            for f <- ~w(runtime.exs vm.args),
                File.exists?(Path.join(rel, f)),
                do: Path.join(rel, f)
          )
        ]
        |> :erlang.term_to_binary()
        |> then(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
    }

    File.write!(Path.join(rel, "upgrade.json"), JSON.encode!(manifest))
    release
  end

  # The applications' configuration in sys.config, as terms in a fixed order. The
  # release's own config-provider setup is left out: it names the release
  # directory and lists compile-time checks in no stable order.
  defp app_config(path) do
    {:ok, [config]} = :file.consult(String.to_charlist(path))

    config
    |> Enum.map(fn
      {:elixir, env} -> {:elixir, Keyword.delete(env, :config_provider_init)}
      entry -> entry
    end)
    |> Enum.map(fn {app, env} -> {app, Enum.sort(env)} end)
    |> Enum.sort()
  end

  defp platform do
    os = :os.type() |> elem(1) |> to_string()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    arch =
      cond do
        arch =~ ~r/aarch64|arm64/ -> "arm64"
        arch =~ ~r/x86_64|amd64/ -> "x64"
        true -> arch
      end

    "#{os}-#{arch}"
  end

  defp run!(command, args, cd) do
    {_, 0} = System.cmd(command, args, cd: cd, into: IO.stream(), stderr_to_stdout: true)
  end
end
