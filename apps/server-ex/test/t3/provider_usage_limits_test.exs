defmodule T3.ProviderUsageLimitsTest do
  use ExUnit.Case, async: false

  alias T3.ProviderUsageLimits, as: Limits
  alias T3.ProviderUsageLimits.{Claude, Codex}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :codex_command, ["python3", @fake_codex])
    Application.put_env(:t3, :claude_command, ["python3", @fake_claude])
    System.put_env("FAKE_CODEX_CONSUME_LOG", Path.join(dir, "consumed"))

    on_exit(fn ->
      Application.delete_env(:t3, :codex_command)
      Application.delete_env(:t3, :claude_command)

      for var <-
            ~w(FAKE_CODEX_CONSUME_LOG FAKE_CODEX_CONSUME_FAIL FAKE_CODEX_ACCOUNT FAKE_CLAUDE_USAGE),
          do: System.delete_env(var)
    end)

    start_supervised!(T3.Settings)
    %{dir: dir}
  end

  defp start do
    start_supervised!(T3.ProviderUsageLimits)
    # Waits for the boot probe.
    :ok = Limits.refresh([])
  end

  test "probes shape Codex windows and credits and Claude's session, weekly and model weeklies" do
    :ok = T3.Settings.watch(self())
    start()
    assert_received {:t3_providers_changed, _}

    codex = Limits.get("codex")

    # The main bucket wins over the legacy snapshot naming Spark; `secondary` without a
    # duration is the weekly one on a paid plan.
    assert codex["windows"] == [
             %{
               "id" => "primary",
               "kind" => "session",
               "label" => "Session",
               "usedPercent" => 42,
               "windowDurationMins" => 300,
               "resetsAt" => "2026-09-21T14:13:20.000Z"
             },
             %{
               "id" => "secondary",
               "kind" => "weekly",
               "label" => "Weekly",
               "usedPercent" => 10.5,
               "windowDurationMins" => 7 * 24 * 60,
               "resetsAt" => "2026-09-27T09:06:40.000Z"
             }
           ]

    assert codex["resetCredits"] == %{
             "availableCount" => 2,
             "nextExpiresAt" => "2026-11-18T11:06:40.000Z"
           }

    claude = Limits.get("claudeAgent")

    assert [
             %{"id" => "five_hour", "kind" => "session", "usedPercent" => 30} = five,
             %{"id" => "seven_day", "kind" => "weekly", "usedPercent" => 55.5} = week,
             %{"id" => "seven_day_fable_1", "label" => "Weekly · Fable 1", "usedPercent" => 12} =
               scoped
           ] = claude["windows"]

    assert five["resetsAt"] == "2026-09-24T15:00:00.123Z"
    refute Map.has_key?(week, "resetsAt")
    assert scoped["resetsAt"] == "2026-09-30T00:00:00.000Z"

    entries = T3.Environment.providers()
    assert %{"usageLimits" => ^codex} = Enum.find(entries, &(&1["instanceId"] == "codex"))
  end

  test "a turn's updates merge by window id onto what the probe drew" do
    start()

    # The overage-included bucket takes the model name the probe saw; a window sent
    # without its reset keeps the known one.
    Limits.claude_event(%{
      "rateLimitType" => "seven_day_overage_included",
      "utilization" => 0.2,
      "resetsAt" => 1_790_000_000
    })

    Limits.claude_event(%{"rateLimitType" => "five_hour", "utilization" => 0.5})
    Limits.claude_event(%{"rateLimitType" => "overage", "utilization" => 0.9})
    :sys.get_state(Limits)

    windows = Map.new(Limits.get("claudeAgent")["windows"], &{&1["id"], &1})
    assert windows["seven_day_fable_1"]["usedPercent"] == 20.0
    assert windows["seven_day_fable_1"]["resetsAt"] == "2026-09-21T14:13:20.000Z"
    assert windows["five_hour"]["usedPercent"] == 50.0
    assert windows["five_hour"]["resetsAt"] == "2026-09-24T15:00:00.123Z"
    assert map_size(windows) == 3

    # Codex's notification is partial: Spark's allowance never lands on the main rows,
    # and credits the probe read stay.
    before = Limits.get("codex")

    Limits.update(
      "codex",
      Codex.windows(%{"limitId" => "codex_spark", "primary" => %{"usedPercent" => 1}})
    )

    Limits.update("codex", Codex.windows(%{"primary" => %{"usedPercent" => 43}}))
    :sys.get_state(Limits)

    after_update = Limits.get("codex")
    assert [%{"id" => "primary", "usedPercent" => 43} = primary, _] = after_update["windows"]
    assert primary["resetsAt"] == hd(before["windows"])["resetsAt"]
    assert after_update["resetCredits"] == before["resetCredits"]
  end

  test "a provider's auth names the account its probe saw, so clients can merge it" do
    start()
    # The account arrives as a cast after the probe; a call after it has been handled.
    _ = :sys.get_state(Limits)

    assert %{
             "auth" => %{
               "status" => "authenticated",
               "email" => "me@example.com",
               "label" => "ChatGPT Pro 20x Subscription"
             }
           } =
             Limits.put(%{"instanceId" => "codex", "auth" => %{"status" => "authenticated"}})

    assert %{
             "auth" => %{
               "email" => "me@example.com",
               "type" => "max",
               "label" => "Claude Max Subscription"
             }
           } =
             Limits.put(%{
               "instanceId" => "claudeAgent",
               "auth" => %{"status" => "authenticated"}
             })
  end

  test "API key accounts are unsupported and ignore turn updates" do
    System.put_env("FAKE_CODEX_ACCOUNT", "apiKey")
    System.put_env("FAKE_CLAUDE_USAGE", "unsupported")
    start()

    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} = Limits.get("codex")
    assert %{"unavailable" => %{"reason" => "unsupported"}} = Limits.get("claudeAgent")

    Limits.update("codex", Codex.windows(%{"primary" => %{"usedPercent" => 43}}))
    :sys.get_state(Limits)
    assert %{"windows" => []} = Limits.get("codex")
  end

  test "a failed probe keeps the last good windows, and says why when there are none", %{
    dir: dir
  } do
    Application.put_env(:t3, :codex_command, ["python3", Path.join(dir, "missing.py")])
    start()

    assert %{
             "unavailable" => %{
               "reason" => "probeFailed",
               "message" => "Codex could not be started to read usage."
             }
           } = Limits.get("codex")

    Application.put_env(:t3, :codex_command, ["python3", @fake_codex])
    :ok = Limits.refresh(["codex"])
    good = Limits.get("codex")
    assert [_, _] = good["windows"]

    Application.put_env(:t3, :codex_command, ["python3", Path.join(dir, "missing.py")])
    :ok = Limits.refresh(["codex"])
    assert Limits.get("codex") == good
  end

  @tag :capture_log
  test "a Codex reset credit redeems once per attempt and confirms the new limits", %{dir: dir} do
    start()
    flag = Path.join(dir, "fail-once")
    File.write!(flag, "")
    System.put_env("FAKE_CODEX_CONSUME_FAIL", flag)

    assert {:error,
            %{
              "_tag" => "ProviderSetupError",
              "detail" => "Codex could not redeem the reset credit."
            }} =
             Limits.consume_reset_credit(%{"instanceId" => "codex"})

    assert {:ok, %{"outcome" => "reset"}} =
             Limits.consume_reset_credit(%{"instanceId" => "codex"})

    assert {:ok, %{"outcome" => "reset"}} =
             Limits.consume_reset_credit(%{"instanceId" => "codex"})

    # The retry after the failure is the same attempt; the next redemption is a new one.
    assert [first, retry, next] = dir |> Path.join("consumed") |> File.read!() |> String.split()
    assert first == retry
    assert next != first

    assert {:error, %{"detail" => "This provider does not bank reset credits."}} =
             Limits.consume_reset_credit(%{"instanceId" => "claudeAgent"})

    assert {:error, %{"detail" => "Provider instance not found."}} =
             Limits.consume_reset_credit(%{"instanceId" => "nope"})
  end

  test "shaping without a probe" do
    # Free and Go plans have one monthly allowance.
    assert [%{"id" => "primary", "kind" => "monthly", "label" => "Monthly"}] =
             Codex.windows(%{"planType" => "free", "primary" => %{"usedPercent" => 150}})
             |> Enum.map(&Map.take(&1, ~w(id kind label)))

    assert [%{"usedPercent" => 100}] =
             Codex.windows(%{"planType" => "go", "primary" => %{"usedPercent" => 150}})

    assert {%{"unavailable" => %{"reason" => "unsupported"}}, nil} =
             Claude.limits(%{"rate_limits_available" => true, "rate_limits" => nil}, "t")

    # An overage event before any probe named the bucket draws nothing.
    assert Claude.event_window(
             %{"rateLimitType" => "seven_day_overage_included", "utilization" => 0.5},
             nil
           ) == nil
  end
end
