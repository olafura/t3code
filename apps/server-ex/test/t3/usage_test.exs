defmodule T3.UsageTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @window %{"sinceDay" => "2026-07-31", "untilDay" => "2026-08-02", "timeZone" => "UTC"}

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:t3, :home)
    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    Application.put_env(:t3, :home, home)
    on_exit(fn -> Application.put_env(:t3, :home, previous) end)

    claude = Path.join([dir, "claude", "projects", "proj"])
    codex = Path.join([dir, "codex", "sessions", "2026", "08", "01"])
    File.mkdir_p!(claude)
    File.mkdir_p!(codex)

    settings = %{
      "providers" => %{
        "claudeAgent" => %{"homePath" => Path.join(dir, "claude")},
        "codex" => %{"homePath" => Path.join(dir, "codex")}
      },
      "providerInstances" => %{
        "grok" => %{
          "driver" => "grok",
          "environment" => [%{"name" => "GROK_HOME", "value" => Path.join(dir, "grok")}]
        }
      }
    }

    %{home: home, claude: claude, codex: codex, settings: settings}
  end

  defp start(home, settings) do
    File.write!(Path.join(home, "settings.json"), JSON.encode!(settings))
    start_supervised!(T3.Settings)
    start_supervised!(T3.Usage)
    :ok
  end

  defp restart_usage do
    :ok = stop_supervised(T3.Usage)
    start_supervised!(T3.Usage)
  end

  defp claude_line(id, output, opts \\ []) do
    JSON.encode!(%{
      "type" => "assistant",
      "timestamp" => opts[:at] || "2026-08-01T10:00:00Z",
      "requestId" => "req_#{id}",
      "sessionId" => opts[:session] || "session-1",
      "costUSD" => opts[:cost],
      "message" => %{
        "id" => "msg_#{id}",
        "model" => opts[:model] || "claude-fable-5",
        "content" => [%{"type" => opts[:block] || "text"}],
        "usage" => %{
          "input_tokens" => 10,
          "cache_read_input_tokens" => opts[:cached] || 0,
          "output_tokens" => output
        }
      }
    }) <> "\n"
  end

  defp codex_lines(session, outputs) do
    meta = %{"type" => "session_meta", "payload" => %{"id" => session}}
    context = %{"type" => "turn_context", "payload" => %{"model" => "gpt-5.6-sol"}}

    counts =
      for output <- outputs do
        %{
          "type" => "event_msg",
          "timestamp" => "2026-08-01T10:00:00Z",
          "payload" => %{
            "type" => "token_count",
            "info" => %{
              "last_token_usage" => %{
                "input_tokens" => 100,
                "cached_input_tokens" => 40,
                "output_tokens" => output
              }
            }
          }
        }
      end

    Enum.map_join([meta, context | counts], &(JSON.encode!(&1) <> "\n"))
  end

  defp summary(input \\ @window) do
    {:ok, summary} = T3.Usage.summary(input)
    summary
  end

  defp output_tokens(summary),
    do: summary["buckets"] |> Enum.map(& &1["totals"]["outputTokens"]) |> Enum.sum()

  test "repeated records count once, within and across transcripts", ctx do
    # Every content block of a message repeats its usage, and a resumed session
    # copies earlier messages into its own transcript.
    File.write!(
      Path.join(ctx.claude, "a.jsonl"),
      claude_line(1, 5) <> claude_line(1, 5, block: "tool_use") <> claude_line(2, 7)
    )

    File.write!(
      Path.join(ctx.claude, "b.jsonl"),
      claude_line(1, 5, session: "session-2") <> claude_line(3, 11, session: "session-2")
    )

    # A-B-A keeps both As; an immediate repeat is a re-emission. The moved copy of
    # the rollout adds nothing.
    rollout = codex_lines("codex-1", [11, 12, 12, 11])
    File.write!(Path.join(ctx.codex, "rollout-a.jsonl"), rollout)
    File.write!(Path.join(ctx.codex, "rollout-copy.jsonl"), rollout)

    start(ctx.home, ctx.settings)
    summary = summary()

    [claude] = for b <- summary["buckets"], b["provider"] == "claude", do: b
    assert claude["records"] == 3
    assert claude["totals"]["outputTokens"] == 5 + 7 + 11
    assert claude["sessions"] == 2

    [codex] = for b <- summary["buckets"], b["provider"] == "codex", do: b
    assert codex["records"] == 3
    assert codex["totals"]["outputTokens"] == 11 + 12 + 11
    assert codex["totals"]["uncachedInputTokens"] == 3 * 60
    assert codex["totals"]["cachedInputTokens"] == 3 * 40

    sources = Map.new(summary["sources"], &{&1["fingerprint"]["provider"], &1})
    assert sources["claude"]["scannedFiles"] == 2
    assert sources["claude"]["distinctSessions"] == 2
    assert sources["codex"]["distinctSessions"] == 1
    assert sources["grok"]["status"] == "missing"

    assert %{"volumeId" => volume, "resolvedHomePath" => path} = sources["claude"]["fingerprint"]
    {:ok, stat} = File.stat(path)
    assert volume == "#{stat.major_device}:#{stat.inode}"
    assert path == ctx.claude |> Path.dirname() |> real()
  end

  test "days are the requested zone's wall-clock days", ctx do
    File.write!(
      Path.join(ctx.claude, "a.jsonl"),
      claude_line(1, 5, at: "2026-08-01T03:30:00Z") <>
        claude_line(2, 7, at: "2026-08-01T12:00:00Z")
    )

    start(ctx.home, ctx.settings)

    days = fn summary -> for b <- summary["buckets"], do: {b["day"], b["records"]} end
    assert days.(summary()) == [{"2026-08-01", 2}]

    la = %{@window | "timeZone" => "America/Los_Angeles"}
    assert days.(summary(la)) == [{"2026-07-31", 1}, {"2026-08-01", 1}]

    # The window is in the zone's days too.
    assert days.(summary(%{la | "sinceDay" => "2026-08-01"})) == [{"2026-08-01", 1}]

    # An unknown zone falls back to UTC rather than failing the page.
    assert days.(summary(%{@window | "timeZone" => "Nowhere/Special"})) == [{"2026-08-01", 2}]
  end

  test "costs come from the rate table, custom prices, or the transcript", ctx do
    rates = Path.join(ctx.tmp_dir, "rates.json")

    File.write!(
      rates,
      JSON.encode!(%{
        "anthropic/claude-fable-5" => %{
          "input_cost_per_token" => 0.001,
          "output_cost_per_token" => 0.01,
          "cache_read_input_token_cost" => 0.0001
        },
        "sample_spec" => %{"input_cost_per_token" => "per token"}
      })
    )

    previous = Application.get_env(:t3, :usage_rates_url)
    Application.put_env(:t3, :usage_rates_url, rates)
    on_exit(fn -> Application.put_env(:t3, :usage_rates_url, previous) end)

    File.write!(
      Path.join(ctx.claude, "a.jsonl"),
      # Priced by the bare-name alias; the [1m] variant prices at the base tier.
      claude_line(1, 100, cached: 1000) <>
        claude_line(2, 100, model: "claude-fable-5[1m]") <>
        claude_line(3, 100, model: "<synthetic>") <>
        claude_line(4, 100, model: "claude-reported", cost: 0.5) <>
        claude_line(5, 100, model: "claude-custom", cost: 0.5)
    )

    settings =
      Map.put(ctx.settings, "usagePriceOverrides", %{
        "claude-custom" => %{
          "inputCostPerMillionTokens" => 1.0e6,
          "outputCostPerMillionTokens" => 0
        }
      })

    start(ctx.home, settings)
    summary = summary()
    buckets = Map.new(summary["buckets"], &{&1["model"], &1})

    assert %{"status" => "fresh", "knownModels" => 2, "source" => ^rates} = summary["pricing"]

    fable = buckets["claude-fable-5"]
    assert fable["costSource"] == "modelPriced"
    assert_in_delta fable["costUsd"], 10 * 0.001 + 1000 * 0.0001 + 100 * 0.01, 1.0e-9
    assert_in_delta fable["cacheSavingsUsd"], 1000 * (0.001 - 0.0001), 1.0e-9
    assert_in_delta buckets["claude-fable-5[1m]"]["costUsd"], 10 * 0.001 + 100 * 0.01, 1.0e-9

    assert %{"costSource" => "unpriced", "costUsd" => 0, "unpricedRecords" => 1} =
             buckets["<synthetic>"]

    assert %{"costSource" => "providerReported", "costUsd" => 0.5} = buckets["claude-reported"]
    assert %{"costSource" => "modelPriced"} = buckets["claude-custom"]
    assert_in_delta buckets["claude-custom"]["costUsd"], 10.0, 1.0e-9

    # Offline, the snapshot on disk still prices.
    Application.put_env(:t3, :usage_rates_url, Path.join(ctx.tmp_dir, "missing.json"))
    restart_usage()
    assert %{"status" => "cached", "knownModels" => 2} = summary()["pricing"]
    assert {:ok, %{"status" => "cached"}} = T3.Usage.refresh_rates(%{})
  end

  test "hourly windows bucket by the hour from their start", ctx do
    File.write!(
      Path.join(ctx.claude, "a.jsonl"),
      claude_line(1, 1, at: "2026-08-01T09:00:00Z") <>
        claude_line(2, 2, at: "2026-08-01T10:05:00Z") <>
        claude_line(3, 3, at: "2026-08-01T10:55:00Z") <>
        claude_line(4, 4, at: "2026-08-01T11:10:00Z") <>
        claude_line(5, 5, at: "2026-08-02T09:30:00Z")
    )

    start(ctx.home, ctx.settings)

    hourly =
      Map.merge(@window, %{
        "resolution" => "hour",
        "sinceTime" => "2026-08-01T09:30:00.000Z",
        "untilTime" => "2026-08-02T09:30:00.000Z"
      })

    assert for(b <- summary(hourly)["buckets"], do: {b["hourStart"], b["totals"]["outputTokens"]}) ==
             [{"2026-08-01T09:30:00.000Z", 2}, {"2026-08-01T10:30:00.000Z", 7}]

    assert {:error, %{"_tag" => "UsageReadError", "reason" => "invalidWindow"}} =
             T3.Usage.summary(%{hourly | "untilTime" => "2026-08-02T09:30:01.000Z"})

    assert {:error, %{"_tag" => "UsageReadError", "reason" => "invalidWindow"}} =
             T3.Usage.summary(%{@window | "sinceDay" => "2026-08-03"})
  end

  test "a transcript that grows counts its new lines once, even across restarts", ctx do
    path = Path.join(ctx.claude, "a.jsonl")
    File.write!(path, claude_line(1, 1))
    start(ctx.home, ctx.settings)
    assert output_tokens(summary()) == 1

    # A line the writer has not finished counts now and is not counted again.
    line = claude_line(2, 2)
    File.write!(path, binary_part(line, 0, byte_size(line) - 1), [:append])
    assert output_tokens(summary()) == 3
    File.write!(path, "\n" <> claude_line(3, 4), [:append])
    assert output_tokens(summary()) == 7

    # The parse survives a restart, and outlives the transcript's cleanup.
    restart_usage()
    File.rm!(path)
    assert output_tokens(summary()) == 7
  end

  defp real(path) do
    {out, 0} = System.cmd("realpath", [path])
    String.trim(out)
  end
end
