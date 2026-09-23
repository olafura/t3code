defmodule T3.Usage.Transcripts do
  @moduledoc """
  Reads usage records out of the provider CLIs' own transcripts (Claude Code's
  `projects/**/*.jsonl`, Codex's `sessions/**/*.jsonl`, Grok's
  `sessions/**/updates.jsonl`) for `T3.Usage`.

  A record is `{timestamp_ms, model, session_id, totals, reported_cost_usd, dedupe_key}`
  with `totals` as `{uncached_input, cached_input, cache_creation, output, reasoning}`;
  `reasoning` is a subset of `output`. Files stream line by line, and `read/3` reports
  the byte position it stopped at so a later read of a file that only grew resumes
  there and parses just the appended lines.
  """

  @guard_length 64
  @fork_copy_max_gap_ms 1000
  @grok_ticks_per_dollar 10_000_000_000

  @doc "`.jsonl` files (or files named `name`) under `root` modified at or after `since_ms`."
  def list(root, since_ms, name \\ nil) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          case File.lstat(path, time: :posix) do
            {:ok, %{type: :directory}} ->
              list(path, since_ms, name)

            {:ok, info} ->
              if wanted?(entry, name), do: file(path, info, since_ms), else: []

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp wanted?(entry, nil), do: String.ends_with?(entry, ".jsonl")
  defp wanted?(entry, name), do: entry == name

  defp file(path, %{type: :symlink}, since_ms) do
    case File.stat(path, time: :posix) do
      {:ok, info} -> file(path, info, since_ms)
      _ -> []
    end
  end

  defp file(path, %{type: :regular, size: size, mtime: mtime}, since_ms)
       when mtime * 1000 >= since_ms,
       do: [%{path: path, size: size, mtime_ms: mtime * 1000}]

  defp file(_path, _info, _since_ms), do: []

  @doc """
  Parses one transcript, or returns nil when it cannot be read. `resume` is a
  previous result's `position`; it is used only while the bytes before it are
  unchanged. Records of a trailing line without its newline land in `tail` and are
  read again next time, since the writer may still be appending to it.
  """
  def read(path, provider, resume \\ nil) do
    case :file.open(path, [:read, :binary, :raw, {:read_ahead, 65_536}]) do
      {:ok, io} ->
        try do
          {start, codex, resumed} =
            case resume do
              {offset, length, hash, codex}
              when offset > 0 and (provider != "codex" or codex != nil) ->
                if guard(io, offset) == {length, hash},
                  do: {offset, codex, true},
                  else: fresh()

              _ ->
                fresh()
            end

          {:ok, _} = :file.position(io, start)
          {records, tail, offset, codex} = lines(io, provider, start, codex, [])
          {length, hash} = guard(io, offset)

          %{
            records: records,
            tail: tail,
            position: {offset, length, hash, if(provider == "codex", do: codex)},
            resumed: resumed
          }
        after
          :file.close(io)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp fresh, do: {0, codex_state(), false}

  # A fingerprint of the bytes just before `offset`: a rewritten or replaced file
  # changes them, so a stale position is never resumed.
  defp guard(io, offset) do
    length = min(@guard_length, offset)

    hash =
      case length > 0 && :file.pread(io, offset - length, length) do
        {:ok, bytes} when byte_size(bytes) == length -> :erlang.phash2(bytes)
        false -> 0
        _ -> nil
      end

    {length, hash}
  end

  defp lines(io, provider, offset, codex, acc) do
    case :file.read_line(io) do
      {:ok, line} ->
        if :binary.last(line) == ?\n do
          {acc, codex} = parse(strip(line), provider, codex, acc)
          lines(io, provider, offset + byte_size(line), codex, acc)
        else
          {tail, _} = parse(strip(line), provider, codex, [])
          {Enum.reverse(acc), Enum.reverse(tail), offset, codex}
        end

      :eof ->
        {Enum.reverse(acc), [], offset, codex}
    end
  end

  defp strip(line) do
    line = if :binary.last(line) == ?\n, do: binary_part(line, 0, byte_size(line) - 1), else: line

    if line != "" and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  # Most lines are tool output; a substring check skips them before decoding.
  defp parse(line, "claude", codex, acc) do
    if String.contains?(line, ~s("usage")),
      do: {prepend(claude(decode(line)), acc), codex},
      else: {acc, codex}
  end

  defp parse(line, "grok", codex, acc) do
    if String.contains?(line, ~s("turn_completed")),
      do: {Enum.reverse(grok(decode(line)), acc), codex},
      else: {acc, codex}
  end

  defp parse(line, "codex", codex, acc) do
    if String.contains?(line, [~s("token_count"), ~s("turn_context"), ~s("session_meta")]) do
      {record, codex} = codex(decode(line), codex)
      {prepend(record, acc), codex}
    else
      {acc, codex}
    end
  end

  defp prepend(nil, acc), do: acc
  defp prepend(record, acc), do: [record | acc]

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = value} -> value
      _ -> nil
    end
  end

  @doc """
  One Claude Code transcript line. Every content block of a message repeats the
  message's full usage, so records share a `message:request` dedupe key.
  """
  def claude(%{"type" => "assistant", "message" => %{"usage" => %{} = usage} = message} = line) do
    with ts when is_integer(ts) <- timestamp(line["timestamp"]),
         model when is_binary(model) and model != "" <- message["model"] do
      id = string(message["id"])
      request = string(line["requestId"])
      cost = line["costUSD"]

      {ts, :binary.copy(model), copy(line["sessionId"]),
       {int(usage["input_tokens"]), int(usage["cache_read_input_tokens"]),
        int(usage["cache_creation_input_tokens"]), int(usage["output_tokens"]), 0},
       if(is_number(cost), do: cost), if(id || request, do: "#{id}:#{request}")}
    else
      _ -> nil
    end
  end

  def claude(_), do: nil

  @doc "A fresh Codex reducer state (`codex/2`)."
  def codex_state,
    do: %{model: "", session: "", signature: nil, meta: false, forked: false, anchor: 0}

  @doc """
  Feeds one Codex rollout line into `state`, returning `{record | nil, state}`.
  `token_count` events carry no model, so it comes from the last `turn_context`;
  unchanged consecutive events are re-emissions, and a forked rollout's leading
  burst of copied parent history is dropped (the parent's own file counts it).
  """
  def codex(%{"type" => "session_meta", "payload" => %{} = payload} = line, %{meta: false} = s) do
    s = %{s | meta: true}
    id = payload["id"] || payload["session_id"]
    s = if is_binary(id), do: %{s | session: :binary.copy(id)}, else: s
    ts = timestamp(line["timestamp"])

    if ts && forked?(payload),
      do: {nil, %{s | forked: true, anchor: ts}},
      else: {nil, s}
  end

  def codex(%{"type" => "turn_context", "payload" => %{} = payload}, state) do
    if model = string(payload["model"]),
      do: {nil, %{state | model: :binary.copy(model)}},
      else: {nil, state}
  end

  def codex(
        %{"type" => type, "payload" => %{"type" => "token_count", "info" => %{} = info}} = line,
        state
      )
      when type != "session_meta" do
    with %{} = last <- info["last_token_usage"],
         ts when is_integer(ts) <- timestamp(line["timestamp"]),
         true <- state.model != "",
         false <- last == state.signature do
      state = %{state | signature: last}

      cond do
        state.forked and ts - state.anchor < @fork_copy_max_gap_ms ->
          {nil, %{state | anchor: ts}}

        true ->
          {codex_record(last, ts, state), %{state | forked: false}}
      end
    else
      _ -> {nil, state}
    end
  end

  def codex(_line, state), do: {nil, state}

  defp codex_record(last, ts, state) do
    input = int(last["input_tokens"])
    cached = int(last["cached_input_tokens"])
    creation = int(last["cache_write_input_tokens"])
    output = int(last["output_tokens"])

    # Codex counts the cached portion inside input_tokens.
    totals =
      {max(0, input - cached - creation), cached, creation, output,
       min(output, int(last["reasoning_output_tokens"]))}

    if total(totals) > 0, do: {ts, state.model, state.session, totals, nil, nil}
  end

  defp forked?(payload) do
    is_binary(payload["forked_from_id"]) or
      is_binary(get_in(payload, ["source", "subagent", "thread_spawn", "parent_thread_id"]))
  rescue
    _ -> false
  end

  @doc """
  One Grok Build `updates.jsonl` line, as records: usage lands on `turn_completed`
  updates, one record per model under `usage.modelUsage` when present. Cost comes in
  ticks; aggregate cost not carried by a model is split by token share across the
  models without their own.
  """
  def grok(
        %{
          "params" =>
            %{"update" => %{"sessionUpdate" => "turn_completed", "usage" => %{} = usage} = update} =
              params
        } = line
      ) do
    session = copy(params["sessionId"])
    prompt = string(update["prompt_id"])

    ts =
      case {get_in(params, ["_meta", "agentTimestampMs"]), line["timestamp"]} do
        {ms, _} when is_number(ms) -> trunc(ms)
        {_, s} when is_number(s) and s > 1.0e12 -> trunc(s)
        {_, s} when is_number(s) -> trunc(s * 1000)
        _ -> nil
      end

    key = fn model -> if prompt, do: "#{session}:#{prompt}:#{model}" end

    entries =
      for {model, %{} = raw} <- map(usage["modelUsage"]),
          model != "",
          do: {:binary.copy(model), grok_totals(raw), grok_cost(raw["costUsdTicks"])}

    models = for {_, totals, _} = entry <- entries, total(totals) > 0, do: entry

    cond do
      ts == nil ->
        []

      entries == [] ->
        totals = grok_totals(usage)

        if total(totals) > 0,
          do: [{ts, "grok", session, totals, grok_cost(usage["costUsdTicks"]), key.("grok")}],
          else: []

      true ->
        aggregate = grok_cost(usage["costUsdTicks"])
        ticked = for {_, _, cost} <- models, cost != nil, do: cost
        unticked = for {_, totals, nil} <- models, do: total(totals)
        remaining = aggregate && max(0, aggregate - Enum.sum(ticked))
        denominator = Enum.sum(unticked)

        for {model, totals, cost} <- models do
          cost =
            cond do
              cost != nil -> cost
              remaining != nil and denominator > 0 -> remaining * total(totals) / denominator
              true -> nil
            end

          {ts, model, session, totals, cost, key.(model)}
        end
    end
  rescue
    _ -> []
  end

  def grok(_), do: []

  defp map(%{} = value), do: value
  defp map(_), do: %{}

  defp grok_totals(raw) do
    input = int(raw["inputTokens"])
    cached = int(raw["cachedReadTokens"])
    creation = int(raw["cacheCreationTokens"])
    output = int(raw["outputTokens"])

    {max(0, input - cached - creation), cached, creation, output,
     min(output, int(raw["reasoningTokens"]))}
  end

  defp grok_cost(ticks) when is_number(ticks) and ticks >= 0, do: ticks / @grok_ticks_per_dollar
  defp grok_cost(_), do: nil

  @doc "All tokens in `totals` (reasoning is already inside output)."
  def total({uncached, cached, creation, output, _reasoning}),
    do: uncached + cached + creation + output

  defp int(value) when is_number(value) and value > 0, do: trunc(value)
  defp int(_), do: 0

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  # Decoded strings can point into the whole line; records keep their own copy.
  defp copy(value) when is_binary(value), do: :binary.copy(value)
  defp copy(_), do: ""

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} ->
        DateTime.to_unix(at, :millisecond)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, at} -> at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
          _ -> nil
        end
    end
  end

  defp timestamp(_), do: nil
end
