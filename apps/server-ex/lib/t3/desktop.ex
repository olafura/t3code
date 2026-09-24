defmodule T3.Desktop do
  @moduledoc """
  Running as the T3 Code desktop app's own node.

  The desktop app starts the release with `T3_BOOTSTRAP_STDIN=1` and writes one
  JSON line to its stdin: the bootstrap it gives the Node server (`port`, bind
  `host`, `t3Home`, and `desktopBootstrapToken`). Its window exchanges that token at
  `/oauth/token` for a bearer session (`T3.Auth`), so the local machine needs no
  pairing. The token never appears in argv or the environment.

  Node state goes to `<t3Home>/elixir`, apart from the Node server's.
  """

  @doc "Reads the bootstrap and applies it to the app env; a no-op outside the desktop app."
  def configure do
    with "1" <- System.get_env("T3_BOOTSTRAP_STDIN"),
         line when is_binary(line) <- IO.read(:stdio, :line) do
      apply_bootstrap(JSON.decode!(line))
    end

    :ok
  end

  @doc false
  def apply_bootstrap(bootstrap) do
    if home = bootstrap["t3Home"], do: Application.put_env(:t3, :home, Path.join(home, "elixir"))
    if port = bootstrap["port"], do: Application.put_env(:t3, :port, port)
    if host = bootstrap["host"], do: Application.put_env(:t3, :host, host)

    if token = bootstrap["desktopBootstrapToken"],
      do: Application.put_env(:t3, :desktop_token, token)

    if url = bootstrap["otlpTracesUrl"], do: Application.put_env(:t3, :otlp_traces_url, url)

    if bootstrap["tailscaleServeEnabled"] == true,
      do: Application.put_env(:t3, :tailscale_serve, bootstrap["tailscaleServePort"] || 443)

    # The app's telemetry channel (`T3.Desktop.Channel`), inherited descriptors.
    with telemetry when is_integer(telemetry) <- bootstrap["desktopTelemetryFd"],
         control when is_integer(control) <- bootstrap["desktopTelemetryControlFd"],
         do: Application.put_env(:t3, :desktop_channel, {telemetry, control})

    :ok
  end
end
