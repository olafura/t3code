defmodule T3.Usage.Aggregator do
  @moduledoc """
  Folds transcript records (`T3.Usage.Transcripts`) into the contract's
  `(day, hourStart?, provider, model)` usage buckets, priced with
  `T3.Usage.Pricing`. Build one with `new/1`, `add/3` every record, then `finish/1`.

  De-duplication spans the whole scan, not one file: Claude Code copies a message's
  records forward when a session is resumed or forked, so one dedupe key shows up in
  several transcripts. Days are wall-clock days in the requested IANA zone (UTC when
  the zone is unknown).
  """

  alias T3.Usage.Pricing

  @hour_ms 60 * 60 * 1000
  # Every zone's offset and transitions fall on quarter hours, so days are cached per
  # quarter hour rather than resolved per record.
  @slot_ms 15 * 60 * 1000

  @doc """
  `opts`: `:time_zone`, `:since_day`, `:until_day` (ISO dates), `:rates` and
  `:overrides` (`T3.Usage.Pricing` tables), and for hourly buckets `:window` as
  `{since_ms, until_ms}`.
  """
  def new(opts) do
    zone = opts[:time_zone]

    zone =
      case DateTime.shift_zone(DateTime.utc_now(), zone, Tz.TimeZoneDatabase) do
        {:ok, _} -> zone
        _ -> "Etc/UTC"
      end

    %{
      zone: zone,
      since: opts[:since_day],
      until: opts[:until_day],
      window: opts[:window],
      rates: opts[:rates],
      overrides: opts[:overrides] || %{},
      days: %{},
      seen: MapSet.new(),
      buckets: %{}
    }
  end

  @doc "Folds one record in; `{contributed?, acc}`."
  def add(acc, provider, {ts, model, session, totals, reported, key}) do
    cond do
      key != nil and MapSet.member?(acc.seen, key) ->
        {false, acc}

      true ->
        acc = if key, do: %{acc | seen: MapSet.put(acc.seen, key)}, else: acc
        {day, acc} = day(acc, ts)

        case acc.window do
          _ when day == nil ->
            {false, acc}

          {since, until} when ts < since or ts >= until ->
            {false, acc}

          {since, _} ->
            hour = since + div(ts - since, @hour_ms) * @hour_ms
            {true, put(acc, {day, iso(hour), provider, model}, session, totals, model, reported)}

          nil when day < acc.since or day > acc.until ->
            {false, acc}

          nil ->
            {true, put(acc, {day, nil, provider, model}, session, totals, model, reported)}
        end
    end
  end

  defp put(acc, bucket_key, session, totals, model, reported) do
    {cost, source, savings} = Pricing.price(acc.rates, acc.overrides, model, totals, reported)

    bucket =
      Map.get(acc.buckets, bucket_key, %{
        totals: {0, 0, 0, 0, 0},
        cost: 0,
        savings: 0,
        records: 0,
        unpriced: 0,
        reported: 0,
        sessions: MapSet.new()
      })

    bucket = %{
      bucket
      | totals: add_totals(bucket.totals, totals),
        cost: bucket.cost + cost,
        savings: bucket.savings + savings,
        records: bucket.records + 1,
        unpriced: bucket.unpriced + if(source == "unpriced", do: 1, else: 0),
        reported: bucket.reported + if(source == "providerReported", do: 1, else: 0),
        sessions:
          if(session == "", do: bucket.sessions, else: MapSet.put(bucket.sessions, session))
    }

    %{acc | buckets: Map.put(acc.buckets, bucket_key, bucket)}
  end

  defp add_totals({a1, a2, a3, a4, a5}, {b1, b2, b3, b4, b5}),
    do: {a1 + b1, a2 + b2, a3 + b3, a4 + b4, a5 + b5}

  defp day(acc, ts) do
    slot = Integer.floor_div(ts, @slot_ms)

    case acc.days do
      %{^slot => day} ->
        {day, acc}

      days ->
        with {:ok, at} <- DateTime.from_unix(ts, :millisecond),
             {:ok, at} <- DateTime.shift_zone(at, acc.zone, Tz.TimeZoneDatabase) do
          day = at |> DateTime.to_date() |> Date.to_iso8601()
          {day, %{acc | days: Map.put(days, slot, day)}}
        else
          _ -> {nil, acc}
        end
    end
  end

  @doc "The contract's buckets, ordered by day, hour, provider, and model."
  def finish(acc) do
    acc.buckets
    |> Enum.sort_by(fn {{day, hour, provider, model}, _} ->
      {day, hour || "", provider, model}
    end)
    |> Enum.map(fn {{day, hour, provider, model}, b} ->
      {uncached, cached, creation, output, reasoning} = b.totals

      bucket = %{
        "day" => day,
        "provider" => provider,
        "model" => model,
        "totals" => %{
          "uncachedInputTokens" => uncached,
          "cachedInputTokens" => cached,
          "cacheCreationTokens" => creation,
          "outputTokens" => output,
          "reasoningTokens" => reasoning
        },
        "costUsd" => b.cost,
        "cacheSavingsUsd" => b.savings,
        # The weakest provenance in a bucket wins, so the page never overstates it.
        "costSource" =>
          cond do
            b.unpriced == b.records -> "unpriced"
            b.reported == b.records -> "providerReported"
            true -> "modelPriced"
          end,
        "records" => b.records,
        "unpricedRecords" => b.unpriced,
        "sessions" => MapSet.size(b.sessions)
      }

      if hour, do: Map.put(bucket, "hourStart", hour), else: bucket
    end)
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
