defmodule T3.DesktopTest do
  use ExUnit.Case, async: false

  test "the desktop bootstrap opens the telemetry channel and Tailscale Serve" do
    on_exit(fn ->
      for key <- [:desktop_channel, :tailscale_serve, :desktop_token, :otlp_traces_url],
          do: Application.delete_env(:t3, key)
    end)

    :ok =
      T3.Desktop.apply_bootstrap(%{
        "desktopTelemetryFd" => 4,
        "desktopTelemetryControlFd" => 5,
        "tailscaleServeEnabled" => true,
        "tailscaleServePort" => 8443,
        "otlpTracesUrl" => "http://127.0.0.1:4318/v1/traces"
      })

    assert Application.get_env(:t3, :desktop_channel) == {4, 5}
    assert Application.get_env(:t3, :tailscale_serve) == 8443
    assert Application.get_env(:t3, :otlp_traces_url) == "http://127.0.0.1:4318/v1/traces"

    assert T3.TailscaleServe.serve_args(8443, 3773) ==
             ["serve", "--bg", "--https=8443", "http://127.0.0.1:3773"]

    # Without network access over the tailnet nothing is served.
    Application.delete_env(:t3, :tailscale_serve)
    :ok = T3.Desktop.apply_bootstrap(%{"tailscaleServeEnabled" => false})
    assert Application.get_env(:t3, :tailscale_serve) == nil
  end
end
