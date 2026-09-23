defmodule T3.Orchestration.Handoff do
  @moduledoc """
  Carries a conversation into a provider thread that has not seen it.

  A fork's first run continues the source provider's own thread when the fork
  runs on the same provider (`fork`). Otherwise, and whenever a run starts a
  provider thread while the thread already has history (a switch to another
  provider, or an agent session lost to a rewind), the provider gets a
  transcript of that history ahead of the message. Work merged back from a fork
  arrives the same way, as a transcript prepared when it was merged.
  """

  alias T3.Orchestration
  alias T3.StreamState

  @native_forks ~w(codex claudeAgent)
  @finished ~w(completed interrupted failed)
  # Keeps a transcript well inside any provider's context; the newest part wins.
  @max_chars 60_000

  @doc """
  How run `ordinal` starts in `provider_thread` (nil when the run creates it):
  `%{fork: %{thread: native_id, turn: native_turn_id} | nil, context: text | nil,
  changes: [...]}`, where `changes` settle the transfers the run consumes.
  """
  def plan(state, provider_thread, driver, run_id, ordinal, at) do
    transfers =
      state
      |> StreamState.list("context-transfer")
      |> Enum.filter(&(&1["status"] == "pending"))

    {fork, fork_context, fork_changes} =
      case Enum.find(transfers, &(&1["type"] == "fork")) do
        nil -> {nil, nil, []}
        transfer -> resolve_fork(state, transfer, driver, run_id, ordinal, at)
      end

    fresh =
      provider_thread == nil or get_in(provider_thread, ["nativeThreadRef", "nativeId"]) == nil

    history =
      cond do
        fork != nil -> nil
        fork_context != nil -> fork_context
        fresh -> transcript(state, ordinal)
        true -> nil
      end

    {merged, merge_changes} = merge_backs(state, transfers, driver, run_id, at)

    %{
      fork: fork,
      context: wrap(history, merged),
      changes: Enum.reject(fork_changes ++ merge_changes, &is_nil/1)
    }
  end

  # Same provider: the run forks the source's native thread at the fork point.
  defp resolve_fork(state, transfer, driver, run_id, ordinal, at) do
    point = transfer["sourcePoint"]
    thread_ref = point["providerThreadRef"]
    turn_ref = point["providerTurnRef"]

    if driver in @native_forks and thread_ref["driver"] == driver and turn_ref != nil do
      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "native_fork", "providerThreadRef" => thread_ref}
        })

      {%{thread: thread_ref["nativeId"], turn: turn_ref["nativeId"]}, nil, [settled]}
    else
      history = transcript(state, ordinal)
      handoff_id = "context-handoff:#{transfer["id"]}"

      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "portable_context", "contextHandoffId" => handoff_id}
        })

      handoff =
        handoff(
          handoff_id,
          transfer,
          run_id,
          driver,
          {1, ordinal - 1},
          "full_thread_summary",
          history,
          at
        )

      {nil, history, [settled, handoff]}
    end
  end

  # Each merge-back brings the fork's work since the fork point, read from the fork.
  defp merge_backs(state, transfers, driver, run_id, at) do
    transfers
    |> Enum.filter(&(&1["type"] == "merge_back"))
    |> Enum.reduce({[], []}, fn transfer, {texts, changes} ->
      fork_id = transfer["sourceThreadId"]
      fork = T3.Streams.Server.state(T3.Streams.ensure(fork_id))
      runs = StreamState.get(fork, "run")
      to = get_in(runs, [transfer["sourcePoint"]["runId"], "ordinal"]) || 0
      from = get_in(runs, [get_in(transfer, ["basePoint", "runId"]), "ordinal"]) || 0
      text = transcript(fork, to + 1, from)
      title = get_in(StreamState.get(fork, "thread"), [fork_id, "title"]) || fork_id
      handoff_id = "context-handoff:#{transfer["id"]}"

      settled =
        settle(state, transfer, run_id, at, %{
          "status" => "consumed",
          "resolution" => %{"strategy" => "portable_context", "contextHandoffId" => handoff_id}
        })

      handoff =
        handoff(
          handoff_id,
          transfer,
          run_id,
          driver,
          {from + 1, to},
          "fork_delta_summary",
          text,
          at
        )

      {texts ++ List.wrap(text && "From the fork \"#{title}\":\n\n#{text}"),
       changes ++ [settled, handoff]}
    end)
    |> then(fn {texts, changes} -> {Enum.join(texts, "\n\n"), changes} end)
  end

  defp handoff(id, transfer, run_id, driver, {from, to}, strategy, text, at) do
    Orchestration.create("context-handoff", id, %{
      "id" => id,
      "transferId" => transfer["id"],
      "threadId" => transfer["targetThreadId"],
      "targetRunId" => run_id,
      "fromProviderThreadIds" => [],
      "toProviderThreadId" => "provider-thread:#{driver}:#{transfer["targetThreadId"]}",
      "coveredRunOrdinals" => %{"from" => max(from, 1), "to" => max(to, max(from, 1))},
      "strategy" => strategy,
      "status" => "ready",
      "summaryMessageId" => nil,
      "summaryText" => text || "",
      "createdByProviderInstanceId" => nil,
      "createdAt" => at,
      "updatedAt" => at
    })
  end

  defp settle(state, transfer, run_id, at, fields) do
    Orchestration.upsert(state, "context-transfer", transfer["id"], fn entity ->
      Map.merge(
        entity,
        Map.merge(fields, %{"targetRunId" => run_id, "updatedAt" => at, "consumedAt" => at})
      )
    end)
  end

  @doc """
  The conversation of the runs before `ordinal` that finished, as `User:` and
  `Assistant:` turns, trimmed from the start to fit; nil when there is none.
  """
  def transcript(state, ordinal, after_ordinal \\ 0) do
    runs =
      state
      |> StreamState.list("run")
      |> Enum.filter(
        &(&1["ordinal"] < ordinal and &1["ordinal"] > after_ordinal and &1["status"] in @finished)
      )
      |> Enum.sort_by(& &1["ordinal"])

    messages = StreamState.list(state, "message") |> Enum.group_by(& &1["runId"])

    lines =
      for run <- runs,
          message <- Map.get(messages, run["id"], []),
          text = String.trim(message["text"] || ""),
          text != "" do
        "#{if message["role"] == "user", do: "User", else: "Assistant"}: #{text}"
      end

    case lines do
      [] -> nil
      lines -> lines |> Enum.join("\n\n") |> tail()
    end
  end

  defp tail(text) do
    if String.length(text) > @max_chars,
      do: "[earlier messages omitted]\n\n" <> String.slice(text, -@max_chars, @max_chars),
      else: text
  end

  defp wrap(nil, ""), do: nil

  defp wrap(history, merged) do
    [
      history &&
        "<conversation_history>\nThis conversation started in another agent session. Continue from it.\n\n#{history}\n</conversation_history>",
      merged != "" &&
        "<merged_work>\nWork done in a fork of this thread, merged back here:\n\n#{merged}\n</merged_work>"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  @doc "The message a provider receives: the handed-off context, then the user's text."
  def prompt(nil, text), do: text
  def prompt(context, text), do: context <> "\n\n" <> text
end
