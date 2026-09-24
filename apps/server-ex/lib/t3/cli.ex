defmodule T3.CLI do
  @moduledoc """
  The node's command line, `bin/t3ctl` in a release, after the Node server's `t3`:

      t3ctl pair [--admin] [--base-url URL]         a one-time pairing URL
      t3ctl auth pairing create [--label L] [--admin]
      t3ctl auth pairing list | revoke ID
      t3ctl auth session list | revoke ID
      t3ctl project list | add PATH [--title T] | remove ID | rename ID TITLE
      t3ctl connect status | publish on|off | unlink
      t3ctl service install | uninstall | status | restart

  `pair` works with the node stopped. The rest call the running node over HTTP with
  a five-minute administrative session made in its store. `service` runs the
  release's `bin/t3-service` as a launchd agent (macOS) or systemd user unit (Linux).
  """

  @label "codes.t3.node"
  @unit "t3-node"

  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc "Runs one command; `:ok` or `{:error, message}`."
  def run(["pair" | args]) do
    {opts, _} = OptionParser.parse!(args, strict: [admin: :boolean, base_url: :string])
    token = T3.Auth.create_pairing_token(store(), opts[:admin] == true)
    IO.puts("#{String.trim_trailing(opts[:base_url] || local_url(), "/")}/pair#token=#{token}")
  end

  def run(["auth", "pairing", "create" | args]) do
    {opts, _} = OptionParser.parse!(args, strict: [admin: :boolean, label: :string])
    scopes = if opts[:admin], do: T3.Auth.admin_scopes(), else: T3.Auth.standard_scopes()

    with {:ok, link} <-
           api(:post, "/api/auth/pairing-token", %{"label" => opts[:label], "scopes" => scopes}) do
      IO.puts("Pairing URL: #{local_url()}/pair#token=#{link["credential"]}")
      IO.puts("Expires: #{link["expiresAt"]}")
    end
  end

  def run(["auth", "pairing", "list"]) do
    with {:ok, links} <- api(:get, "/api/auth/pairing-links") do
      for link <- links,
          do: IO.puts("#{link["id"]}  #{link["label"] || "-"}  expires #{link["expiresAt"]}")

      :ok
    end
  end

  def run(["auth", "pairing", "revoke", id]) do
    with {:ok, %{"revoked" => revoked}} <-
           api(:post, "/api/auth/pairing-links/revoke", %{"id" => id}),
         do: IO.puts(if(revoked, do: "Revoked #{id}.", else: "No pairing link #{id}."))
  end

  def run(["auth", "session", "list"]) do
    with {:ok, clients} <- api(:get, "/api/auth/clients") do
      for client <- clients do
        state = if client["connected"], do: "connected", else: "offline"
        label = client["client"]["label"] || client["client"]["deviceType"]
        IO.puts("#{client["sessionId"]}  #{label}  #{state}  expires #{client["expiresAt"]}")
      end

      :ok
    end
  end

  def run(["auth", "session", "revoke", id]) do
    with {:ok, %{"revoked" => revoked}} <-
           api(:post, "/api/auth/clients/revoke", %{"sessionId" => id}),
         do: IO.puts(if(revoked, do: "Revoked #{id}.", else: "No session #{id}."))
  end

  def run(["project", "list"]) do
    with {:ok, %{"projects" => projects}} <- api(:get, "/api/projects") do
      for p <- projects, do: IO.puts("#{p["id"]}  #{p["title"]}  #{p["workspaceRoot"]}")
      :ok
    end
  end

  def run(["project", "add", path | args]) do
    {opts, _} = OptionParser.parse!(args, strict: [title: :string])

    mutate(%{
      "type" => "project.create",
      "projectId" => T3.Environment.uuid4(),
      "workspaceRoot" => Path.expand(path),
      "title" => opts[:title] || Path.basename(Path.expand(path))
    })
  end

  def run(["project", "remove", id]),
    do: mutate(%{"type" => "project.delete", "projectId" => id})

  def run(["project", "rename", id, title]),
    do: mutate(%{"type" => "project.update", "projectId" => id, "title" => title})

  def run(["connect", "status"]) do
    with {:ok, state} <- api(:get, "/api/connect/link-state") do
      if state["linked"] do
        IO.puts("Linked to #{state["cloudUserId"]} through #{state["relayUrl"]}.")
        IO.puts("Managed tunnel: #{if state["managedTunnelActive"], do: "on", else: "off"}")

        IO.puts(
          "Agent activity: #{if state["publishAgentActivity"], do: "published", else: "not published"}"
        )
      else
        IO.puts("Not linked. Link it from Settings → Connections in the app this node serves.")
      end

      :ok
    end
  end

  def run(["connect", "publish", on_off]) when on_off in ["on", "off"] do
    with {:ok, _} <-
           api(:post, "/api/connect/preferences", %{"publishAgentActivity" => on_off == "on"}),
         do: IO.puts("Agent activity #{if on_off == "on", do: "is", else: "is not"} published.")
  end

  def run(["connect", "unlink"]) do
    with {:ok, _} <- api(:post, "/api/connect/unlink", %{}), do: IO.puts("Unlinked.")
  end

  def run(["service", command]) when command in ~w(install uninstall status restart) do
    case :os.type() do
      {:unix, :darwin} -> launchd(command)
      {:unix, _} -> systemd(command)
      _ -> {:error, "Running as a service is supported on macOS and Linux."}
    end
  end

  def run(_argv), do: {:error, @moduledoc |> String.split("\n\n") |> Enum.at(1)}

  defp mutate(mutation) do
    with {:ok, project} <-
           api(
             :post,
             "/api/projects/mutate",
             Map.put(mutation, "commandId", T3.Environment.uuid4())
           ) do
      IO.puts("#{project["id"]}  #{project["title"]}  #{project["workspaceRoot"]}")
    end
  end

  # --- the running node ------------------------------------------------------------

  defp api(method, path, body \\ nil) do
    {:ok, _} = Application.ensure_all_started(:inets)
    token = T3.Auth.create_cli_session(store())
    url = String.to_charlist(local_url() <> path)
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}]

    request =
      if method == :post,
        do: {url, headers, ~c"application/json", JSON.encode!(body)},
        else: {url, headers}

    case :httpc.request(method, request, [timeout: 30_000], []) do
      {:ok, {{_, status, _}, _, response}} when status in 200..299 ->
        {:ok, JSON.decode!(to_string(response))}

      {:ok, {{_, _status, _}, _, response}} ->
        {:error, error_message(to_string(response))}

      {:error, _} ->
        {:error, "The node is not running at #{local_url()}."}
    end
  end

  defp error_message(body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} -> message
      {:ok, %{"_tag" => tag}} -> tag
      _ -> body
    end
  end

  defp local_url, do: "http://127.0.0.1:#{Application.get_env(:t3, :port, 3780)}"
  defp store, do: Path.join(Application.fetch_env!(:t3, :home), "t3.sqlite")

  # --- the service ---------------------------------------------------------------

  @doc "The launchd agent running the release at `root` with state in `home`."
  def launchd_plist(root, home) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{@label}</string>
      <key>ProgramArguments</key><array><string>#{xml(Path.join(root, "bin/t3-service"))}</string></array>
      <key>EnvironmentVariables</key><dict><key>T3_HOME</key><string>#{xml(home)}</string></dict>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
      <key>StandardOutPath</key><string>#{xml(Path.join(home, "logs/service.log"))}</string>
      <key>StandardErrorPath</key><string>#{xml(Path.join(home, "logs/service.log"))}</string>
    </dict>
    </plist>
    """
  end

  @doc "The systemd user unit running the release at `root` with state in `home`."
  def systemd_unit(root, home) do
    """
    [Unit]
    Description=T3 node
    After=network-online.target

    [Service]
    ExecStart=#{Path.join(root, "bin/t3-service")}
    Environment=T3_HOME=#{home}
    Restart=on-failure

    [Install]
    WantedBy=default.target
    """
  end

  defp launchd(command) do
    plist = Path.expand("~/Library/LaunchAgents/#{@label}.plist")
    domain = "gui/#{uid()}"

    case command do
      "install" ->
        with {:ok, root} <- release_root() do
          home = Application.fetch_env!(:t3, :home)
          File.mkdir_p!(Path.join(home, "logs"))
          File.mkdir_p!(Path.dirname(plist))
          System.cmd("launchctl", ["bootout", "#{domain}/#{@label}"], stderr_to_stdout: true)
          File.write!(plist, launchd_plist(root, home))
          sh("launchctl", ["bootstrap", domain, plist], "Installed and started #{@label}.")
        end

      "uninstall" ->
        System.cmd("launchctl", ["bootout", "#{domain}/#{@label}"], stderr_to_stdout: true)
        File.rm(plist)
        IO.puts("Uninstalled #{@label}.")

      "status" ->
        case System.cmd("launchctl", ["print", "#{domain}/#{@label}"], stderr_to_stdout: true) do
          {out, 0} ->
            state = Regex.run(~r/state = (\w+)/, out, capture: :all_but_first) || ["loaded"]
            IO.puts("#{@label}: #{hd(state)}")

          _ ->
            IO.puts("#{@label}: not installed")
        end

      "restart" ->
        sh("launchctl", ["kickstart", "-k", "#{domain}/#{@label}"], "Restarted #{@label}.")
    end
  end

  defp systemd(command) do
    unit = Path.expand("~/.config/systemd/user/#{@unit}.service")

    case command do
      "install" ->
        with {:ok, root} <- release_root() do
          File.mkdir_p!(Path.dirname(unit))
          File.write!(unit, systemd_unit(root, Application.fetch_env!(:t3, :home)))
          System.cmd("systemctl", ["--user", "daemon-reload"], stderr_to_stdout: true)

          sh(
            "systemctl",
            ["--user", "enable", "--now", @unit],
            "Installed and started #{@unit}. Run `loginctl enable-linger` to keep it running after logout."
          )
        end

      "uninstall" ->
        System.cmd("systemctl", ["--user", "disable", "--now", @unit], stderr_to_stdout: true)
        File.rm(unit)
        System.cmd("systemctl", ["--user", "daemon-reload"], stderr_to_stdout: true)
        IO.puts("Uninstalled #{@unit}.")

      "status" ->
        {out, _} = System.cmd("systemctl", ["--user", "is-active", @unit], stderr_to_stdout: true)
        IO.puts("#{@unit}: #{String.trim(out)}")

      "restart" ->
        sh("systemctl", ["--user", "restart", @unit], "Restarted #{@unit}.")
    end
  end

  defp sh(command, args, done) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_, 0} -> IO.puts(done)
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp release_root do
    case System.get_env("RELEASE_ROOT") do
      nil -> {:error, "Install the service from a release (bin/t3ctl), not a checkout."}
      root -> {:ok, root}
    end
  end

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()

  defp xml(value), do: value |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
end
