defmodule T3.Antigravity.Profile do
  @moduledoc """
  The private Google profile each Antigravity instance runs with, and the command
  and environment that start the agent in it.

  A profile lives in `<home>/providers/antigravity/<sha256 of the instance id>` (so
  instance ids that differ only by case stay apart on case-insensitive disks) and
  is the agent's `GEMINI_HOME`: its sign-in token (`antigravity-acp/acp_token.json`,
  never read here), `antigravity-acp/settings.json` naming the sign-in method and
  GCP project, and `tmp/`, where the one-file bundle unpacks about 1 GB per launch.
  The user's global skill folders under `~/.gemini` are linked in so they still load.

  The agent opens Google sign-in through Python's `webbrowser`, which honours
  `BROWSER`: it points at a helper script that prints the URL to stderr behind a
  marker instead of opening a browser (`T3.Antigravity.Auth` reads it). Variables
  that would pick another credential source are removed from the environment; only
  the configured method's API key goes in.
  """

  @auth_marker "__T3_ANTIGRAVITY_AUTH_URL__"
  @preflight_url "https://example.invalid/t3-antigravity-browser-preflight"

  # Variables that select credentials, homes, or browsers the agent must not see.
  @removed ~w(GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT
    GOOGLE_CLOUD_LOCATION GOOGLE_CLOUD_QUOTA_PROJECT GOOGLE_GENAI_USE_VERTEXAI GCLOUD_PROJECT
    CLOUDSDK_CORE_PROJECT AGY_ACP_CCPA_PROJECT AGY_ACP_ENABLE_OAUTH GEMINI_HOME
    AGY_ACP_FORCE_FILE_STORAGE ANTIGRAVITY_HARNESS_PATH BROWSER PYTHONUNBUFFERED
    ELECTRON_RUN_AS_NODE)

  @doc "The marker the browser helper prints before a sign-in URL on stderr."
  def auth_marker, do: @auth_marker

  @doc "An instance's profile directory."
  def dir(instance) do
    hash = :crypto.hash(:sha256, instance) |> Base.encode16(case: :lower)
    Path.join([Application.fetch_env!(:t3, :home), "providers", "antigravity", hash])
  end

  @doc "Where the agent unpacks itself; swept when the node starts (`sweep_temp/1`)."
  def temp_dir(profile), do: Path.join([profile, "antigravity-acp", "tmp"])

  @doc """
  Makes the profile ready for a launch: private directories, the sign-in method's
  `settings.json` (rewritten every time, so a settings edit takes effect), the
  browser helper, and links to the user's skills. `{:ok, profile_dir}` or
  `{:error, message}`.
  """
  def prepare(instance, config, user_home \\ System.user_home!()),
    do: prepare_dir(dir(instance), config, user_home)

  @doc "`prepare/3` for a profile at any directory (a throwaway one, when checking an install)."
  def prepare_dir(profile, config, user_home \\ System.user_home!()) do
    acp = Path.join(profile, "antigravity-acp")
    helper = helper_path(profile)

    with :ok <- private_dirs([profile, acp, temp_dir(profile)]),
         :ok <- write(Path.join(acp, "settings.json"), settings_json(config)),
         :ok <- write_helper(helper),
         :ok <- preflight(helper) do
      link_user_skills(profile, user_home)
      {:ok, profile}
    end
  end

  defp private_dirs(dirs) do
    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "The Antigravity profile directory could not be created."}}
      end
    end)
  end

  defp write(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      _ -> {:error, "The Antigravity profile settings could not be written."}
    end
  end

  @doc """
  `settings.json` for the agent: `auth.type` names the method, so a native sign-out
  clears only its credentials; the GCP block serves Enterprise and Agent Platform.
  Never holds a credential.
  """
  def settings_json(config) do
    gcp =
      %{"project" => config["gcpProject"], "location" => config["gcpLocation"]}
      |> Map.reject(fn {_, v} -> v in [nil, ""] end)

    settings = %{"auth" => %{"type" => config["authMethod"]}}
    settings = if gcp == %{}, do: settings, else: Map.put(settings, "gcp", gcp)
    JSON.encode!(settings) <> "\n"
  end

  defp helper_path(profile), do: Path.join([profile, "antigravity-acp", "t3-browser"])

  # Python splits BROWSER on the path separator, so its path must not hold one.
  defp write_helper(path) do
    script = """
    #!/bin/sh
    trap '' PIPE
    printf '%s%s\\n' '#{@auth_marker}' "$1" >&2 2>/dev/null
    exit 0
    """

    cond do
      String.contains?(path, [":", "'", "\n", "%s"]) ->
        {:error, "The T3 home path cannot be used to suppress Antigravity browser launches."}

      File.write(path, script) == :ok and File.chmod(path, 0o700) == :ok ->
        :ok

      true ->
        {:error, "Antigravity browser suppression could not be set up."}
    end
  end

  defp preflight(helper) do
    case System.cmd(helper, [@preflight_url], stderr_to_stdout: true) do
      {out, 0} when out == @auth_marker <> @preflight_url <> "\n" -> :ok
      _ -> {:error, "Antigravity browser suppression could not be verified."}
    end
  rescue
    _ -> {:error, "Antigravity browser suppression could not be verified."}
  end

  @doc """
  The agent's user-global skill folders under a Gemini home: `config/skills`
  (shared with the IDE and CLI) and `antigravity-cli/skills` (where `agy` installs).
  """
  def user_skill_dirs(gemini_home),
    do: [
      Path.join([gemini_home, "config", "skills"]),
      Path.join([gemini_home, "antigravity-cli", "skills"])
    ]

  # Best effort: a link that cannot be made costs global skills, never the session.
  # A real directory at the link path is the user's own and stays.
  defp link_user_skills(profile, user_home) do
    targets = user_skill_dirs(Path.join(user_home, ".gemini"))

    for {link, target} <- Enum.zip(user_skill_dirs(profile), targets) do
      case File.read_link(link) do
        {:ok, ^target} ->
          :ok

        {:ok, _other} ->
          File.rm(link)
          File.ln_s(target, link)

        {:error, :enoent} ->
          File.mkdir_p(Path.dirname(link))
          File.ln_s(target, link)

        {:error, _not_a_link} ->
          :ok
      end
    end

    :ok
  end

  @doc """
  The command and environment that start `executable` (`%{path, harness}`) with
  the profile: `{argv, env}`. `base_env` is the instance's own variables. Removed
  variables the node itself has are unset through `env -u`, since a child inherits
  the node's environment.
  """
  def command(executable, profile, config, base_env \\ []) do
    credential =
      case config do
        %{"authMethod" => "gemini-api-key", "apiKey" => key} when key != "" ->
          [{"GEMINI_API_KEY", key}]

        %{"authMethod" => "agent-platform", "apiKey" => key} when key != "" ->
          [{"GOOGLE_API_KEY", key}]

        _ ->
          []
      end

    tmp = temp_dir(profile)

    env =
      Enum.reject(base_env, fn {k, _} -> String.upcase(k) in @removed end) ++
        credential ++
        [
          {"GEMINI_HOME", profile},
          {"AGY_ACP_FORCE_FILE_STORAGE", "1"},
          {"BROWSER", "'#{helper_path(profile)}' %s"},
          {"PYTHONUNBUFFERED", "1"},
          {"ANTIGRAVITY_HARNESS_PATH", executable.harness},
          {"TMPDIR", tmp}
        ]

    set = MapSet.new(env, &elem(&1, 0))

    unset =
      for {key, _} <- System.get_env(),
          String.upcase(key) in @removed,
          not MapSet.member?(set, key),
          do: key

    args = if match?({:unix, :linux}, :os.type()), do: ["--uid="], else: []
    argv = [executable.path | args]

    argv =
      if unset == [],
        do: argv,
        else:
          [System.find_executable("env") || "/usr/bin/env" | Enum.flat_map(unset, &["-u", &1])] ++
            argv

    {argv, env}
  end

  @doc """
  Removes the unpacked runtimes left in a profile. Only when no process of the
  instance runs: at node start, before any launch.
  """
  def sweep_temp(instance) do
    File.rm_rf(temp_dir(dir(instance)))
    :ok
  end

  @doc """
  Removes the agent's files for a session a helper opened in its own temporary
  `cwd` (sign-in, model refresh, text generation), once its process has exited.
  The session's recorded cwd proves it is the helper's.
  """
  def remove_session_files(instance, session_id, cwd) when is_binary(session_id) do
    acp = Path.join(dir(instance), "antigravity-acp")
    base = Path.join([acp, "conversations", session_id])

    with true <-
           Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
             session_id
           ),
         {:ok, text} <- File.read(base <> ".meta"),
         {:ok, %{"cwd" => ^cwd}} <- JSON.decode(text) do
      for suffix <- ~w(.db .db-wal .db-shm .db-journal .meta), do: File.rm(base <> suffix)
      File.rm_rf(Path.join([acp, "brain", session_id]))
    end

    :ok
  end

  def remove_session_files(_instance, _session_id, _cwd), do: :ok

  @doc """
  Whether text generation may run on the profile: global hooks or MCP servers in
  `config/` would run before a helper could refuse a tool.
  """
  def text_generation_available?(instance) do
    config = Path.join(dir(instance), "config")

    Enum.all?([{"hooks.json", "hooks"}, {"mcp_config.json", "mcpServers"}], fn {name, key} ->
      path = Path.join(config, name)

      case File.stat(path) do
        {:error, :enoent} ->
          true

        {:ok, %File.Stat{type: :regular, size: size}} when size <= 64_000 ->
          with {:ok, text} <- File.read(path),
               {:ok, %{} = doc} <- JSON.decode(text),
               %{} = entries <- Map.get(doc, key, doc) do
            map_size(entries) == 0
          else
            _ -> false
          end

        _ ->
          false
      end
    end)
  end
end
