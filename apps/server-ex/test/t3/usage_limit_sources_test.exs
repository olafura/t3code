defmodule T3.UsageLimitSourcesTest do
  use ExUnit.Case, async: false

  alias T3.UsageLimitSources
  alias T3.UsageLimitSources.Cliproxy

  @moduletag :tmp_dir
  @marker "••••••"

  # A CLIProxyAPI hub: its management API, and the upstream answers `api-call` relays.
  defmodule Hub do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    def init(test), do: test

    def call(conn, test) do
      if get_req_header(conn, "authorization") != ["Bearer hub-key"] do
        send_resp(conn, 401, "")
      else
        {:ok, body, conn} = read_body(conn)
        request = if body == "", do: nil, else: JSON.decode!(body)
        send(test, {:hub, conn.request_path, request})
        route(conn, conn.request_path, request)
      end
    end

    defp route(conn, "/v0/management/auth-files", _) do
      json(conn, 200, %{
        "files" => [
          %{
            "id" => "codex-a",
            "auth_index" => "0",
            "provider" => "codex",
            "email" => "a@example.com",
            "id_token" => %{"chatgpt_account_id" => "acct-1", "chatgpt_plan_type" => "plus"}
          },
          %{
            "id" => "claude-b",
            "auth_index" => "1",
            "provider" => "claude",
            "email" => "b@example.com"
          },
          %{"id" => "codex-off", "auth_index" => "2", "provider" => "codex", "disabled" => true},
          %{"id" => "gemini-c", "auth_index" => "3", "provider" => "gemini"}
        ]
      })
    end

    defp route(conn, "/v0/management/reset-quota", _) do
      if :persistent_term.get({__MODULE__, :cooldown_fails}, false),
        do: send_resp(conn, 500, ""),
        else: json(conn, 200, %{})
    end

    defp route(conn, "/v0/management/api-call", %{"url" => url} = request) do
      json(conn, 200, %{"status_code" => 200, "body" => JSON.encode!(upstream(url, request))})
    end

    defp upstream("https://chatgpt.com/backend-api/wham/usage", _) do
      %{
        "plan_type" => "pro",
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 20,
            "reset_at" => 1_790_000_000,
            "limit_window_seconds" => 18_000
          },
          "secondary_window" => %{
            "used_percent" => 5,
            "reset_at" => 1_790_500_000,
            "limit_window_seconds" => 604_800
          }
        }
      }
    end

    defp upstream("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", _) do
      credit = &%{"id" => &1, "status" => &2, "reset_type" => &3, "expires_at" => &4}

      %{
        "credits" => [
          credit.("c2", "available", "codex_rate_limits", "2099-01-02T00:00:00Z"),
          credit.("c1", "available", "codex_rate_limits", "2099-01-01T00:00:00Z"),
          credit.("old", "available", "codex_rate_limits", "2000-01-01T00:00:00Z"),
          credit.("used", "redeemed", "codex_rate_limits", "2099-01-01T00:00:00Z"),
          credit.("other", "available", "something_else", "2099-01-01T00:00:00Z")
        ]
      }
    end

    defp upstream("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume", _),
      do: %{"code" => "reset"}

    defp upstream("https://api.anthropic.com/api/oauth/usage", _) do
      %{
        "five_hour" => %{"utilization" => 40, "resets_at" => "2026-09-24T15:00:00Z"},
        "seven_day" => %{"utilization" => 60, "resets_at" => nil},
        "limits" => [
          %{
            "kind" => "weekly_scoped",
            "percent" => 7,
            "resets_at" => nil,
            "scope" => %{"model" => %{"display_name" => "Fable"}}
          }
        ]
      }
    end

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
    end
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    :persistent_term.erase({Hub, :cooldown_fails})
    on_exit(fn -> :persistent_term.erase({Hub, :cooldown_fails}) end)
    server = start_supervised!({Bandit, plug: {Hub, self()}, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    start_supervised!(T3.Settings)
    :ok = T3.Settings.watch(self())
    start_supervised!(UsageLimitSources)
    %{url: "http://127.0.0.1:#{port}", port: port, dir: dir}
  end

  defp put_sources(sources) do
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(Map.put(settings, "usageLimitSources", sources), version)
  end

  defp source(url, key, extra \\ %{}),
    do: Map.merge(%{"kind" => "cliproxy", "url" => url, "managementKey" => key}, extra)

  test "a hub's accounts arrive as one snapshot per source, after each settings change", %{
    url: url,
    port: port
  } do
    put_sources(%{"hub" => source(url, "hub-key")})
    assert_receive {:t3_usage_limit_sources, _, [snapshot]}, 5_000
    assert UsageLimitSources.current() == [snapshot]

    host = "127.0.0.1:#{port}"
    assert %{"id" => "hub", "kind" => "cliproxy", "label" => ^host} = snapshot
    refute Map.has_key?(snapshot, "error")

    # Disabled and other providers' accounts are left out.
    assert [codex, claude] = snapshot["accounts"]

    assert %{
             "id" => "codex-a",
             "driver" => "codex",
             "email" => "a@example.com",
             "plan" => "ChatGPT Pro 20x Subscription"
           } = codex

    assert [
             %{
               "id" => "primary",
               "kind" => "session",
               "usedPercent" => 20,
               "windowDurationMins" => 300
             },
             %{"id" => "secondary", "kind" => "weekly", "windowDurationMins" => 10_080}
           ] = codex["usageLimits"]["windows"]

    # Only live, available Codex credits count; the next to expire is the one to redeem.
    assert codex["usageLimits"]["resetCredits"] == %{
             "availableCount" => 2,
             "nextCreditId" => "c1",
             "nextExpiresAt" => "2099-01-01T00:00:00.000Z"
           }

    assert %{"driver" => "claudeAgent", "plan" => "Claude Subscription"} = claude

    assert [
             %{
               "id" => "five_hour",
               "usedPercent" => 40,
               "resetsAt" => "2026-09-24T15:00:00.000Z"
             },
             %{"id" => "seven_day", "usedPercent" => 60},
             %{"id" => "seven_day_fable", "label" => "Weekly · Fable", "usedPercent" => 7}
           ] = claude["usageLimits"]["windows"]

    # Every account's usage went through the hub with that account's own token.
    assert_received {:hub, "/v0/management/api-call",
                     %{"auth_index" => "0", "header" => %{"Chatgpt-Account-Id" => "acct-1"}}}

    # A labelled source keeps its label; removing a source removes its row.
    put_sources(%{"hub" => source(url, @marker, %{"label" => "Team hub"})})

    assert_receive {:t3_usage_limit_sources, _, [%{"label" => "Team hub", "accounts" => [_, _]}]},
                   5_000

    put_sources(%{})
    assert_receive {:t3_usage_limit_sources, _, []}, 5_000
  end

  test "a source that cannot be read keeps its row with the reason", %{url: url} do
    put_sources(%{
      "a-no-key" => source(url, ""),
      "b-wrong-key" => source(url, "not-the-key"),
      "c-bad-url" => source("not a url", "hub-key"),
      "d-off" => source(url, "hub-key", %{"enabled" => false})
    })

    assert_receive {:t3_usage_limit_sources, _, sources}, 5_000

    assert [
             %{"id" => "a-no-key", "accounts" => [], "error" => "No management key configured."},
             %{
               "id" => "b-wrong-key",
               "accounts" => [],
               "error" => "The hub could not list accounts."
             },
             %{
               "id" => "c-bad-url",
               "label" => "c-bad-url",
               "error" => "The hub could not list accounts."
             }
           ] = sources
  end

  test "the management key lives in the secret store, never in settings", %{url: url, dir: dir} do
    put_sources(%{"hub" => source(url, "hub-key")})

    assert_receive {:t3_settings, _,
                    %{"usageLimitSources" => %{"hub" => %{"managementKey" => @marker}}}}

    path =
      Path.join([
        dir,
        "secrets",
        "usage-limit-source-#{Base.url_encode64("hub", padding: false)}.bin"
      ])

    assert File.read!(path) == "hub-key"
    assert %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.read!(Path.join(dir, "settings.json")) =~ "hub-key"

    # Sending the marker back keeps the key; a new key replaces it; removal forgets it.
    put_sources(%{"hub" => source(url, @marker, %{"label" => "x"})})
    assert File.read!(path) == "hub-key"
    put_sources(%{"hub" => source(url, "next-key")})
    assert File.read!(path) == "next-key"
    put_sources(%{})
    refute File.exists?(path)
  end

  test "a key written in plain text moves out when the node starts", %{url: url, dir: dir} do
    stop_supervised!(UsageLimitSources)
    stop_supervised!(T3.Settings)

    File.write!(
      Path.join(dir, "settings.json"),
      JSON.encode!(%{"usageLimitSources" => %{"hub" => source(url, "hub-key")}})
    )

    start_supervised!(T3.Settings)
    assert %{"hub" => %{"managementKey" => @marker}} = T3.Settings.settings()["usageLimitSources"]
    refute File.read!(Path.join(dir, "settings.json")) =~ "hub-key"
    assert UsageLimitSources.key("hub") == "hub-key"
  end

  test "a hub account's reset credit is redeemed through the hub, then its row re-read", %{
    url: url
  } do
    put_sources(%{"hub" => source(url, "hub-key")})
    assert_receive {:t3_usage_limit_sources, _, [_]}, 5_000

    input = %{"sourceId" => "hub", "accountId" => "codex-a", "creditId" => "c1"}
    assert {:ok, %{"outcome" => "reset"}} = UsageLimitSources.consume_reset_credit(input)

    request_id = Cliproxy.redeem_request_id("acct-1", "c1")

    assert_received {:hub, "/v0/management/api-call",
                     %{
                       "method" => "POST",
                       "url" =>
                         "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume",
                       "data" => data
                     }}

    assert JSON.decode!(data) == %{"redeem_request_id" => request_id, "credit_id" => "c1"}
    assert_received {:hub, "/v0/management/reset-quota", %{"auth_index" => "0"}}
    assert_receive {:t3_usage_limit_sources, _, [_]}, 5_000

    # A cooldown the hub would not clear is a warning on a redemption that happened.
    :persistent_term.put({Hub, :cooldown_fails}, true)

    assert {:ok,
            %{"outcome" => "reset", "warning" => "Credit redeemed, but the hub cooldown" <> _}} =
             UsageLimitSources.consume_reset_credit(input)

    assert {:error,
            %{
              "_tag" => "UsageLimitSourceError",
              "detail" => "The Codex hub account is missing or disabled."
            }} =
             UsageLimitSources.consume_reset_credit(%{input | "accountId" => "codex-off"})

    assert {:error, %{"detail" => "The usage limit source is missing or disabled."}} =
             T3.ProviderUsageLimits.consume_reset_credit(%{input | "sourceId" => "gone"})
  end

  test "request ids match the Node server's, so every environment redeems one attempt" do
    assert Cliproxy.redeem_request_id("acct-1", "credit-1") ==
             "2472b232-eb38-5124-a485-dc9b3151e444"
  end
end
