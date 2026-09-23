defmodule T3.Search do
  @moduledoc """
  Thread search (`orchestration.searchThreads`): finished user and assistant
  messages whose text contains the query, one match per active thread, preferring
  what the user wrote. Messages are indexed in `T3.Store` as they finish; threads
  written before the index existed are indexed once at startup (`backfill/0`).
  """

  alias T3.{Store, StreamState}

  @roles ["user", "assistant"]
  @snippet 240

  @doc "Indexes the messages `events` finished, reading them from the committed `stream`."
  def index(stream_id, events, stream) do
    messages =
      for %{kind: "message", entity: id} <- events,
          message = StreamState.get(stream, "message")[id],
          message["role"] in @roles and message["streaming"] != true,
          uniq: true,
          do: {id, message["role"], message["text"] || "", message["createdAt"]}

    if messages != [], do: Store.index_messages(stream_id, messages)
    :ok
  end

  @doc "Indexes every thread's messages once, for logs written before the index existed."
  def backfill do
    path = Store.path()

    if Store.meta(path, "messages_indexed") != "1" do
      for %{id: id, kind: "thread"} <- Store.list_streams(path) do
        state = StreamState.load(path, id)

        messages =
          for message <- StreamState.list(state, "message"),
              message["role"] in @roles and message["streaming"] != true,
              do: {message["id"], message["role"], message["text"] || "", message["createdAt"]}

        if messages != [], do: Store.index_messages(id, messages)
      end

      Store.put_meta("messages_indexed", "1")
    end

    :ok
  end

  @spec threads(map) :: {:ok, map}
  def threads(%{"query" => query} = input) do
    limit = input["limit"] || 50
    pattern = "%" <> String.replace(query, ~r/[!%_]/, "!\\0") <> "%"

    active =
      for {{node, id}, {"thread", row}} <- T3.Shell.rows(),
          node == node() and row["archivedAt"] == nil and row["deletedAt"] == nil,
          into: %{},
          do: {id, row}

    matches =
      Store.path()
      |> Store.search_messages(pattern, 2_000)
      |> Enum.filter(fn {thread_id, _, _, _} -> Map.has_key?(active, thread_id) end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {thread_id, found} ->
        # Newest first already; a user message wins over an assistant one.
        {_, role, text, at} = Enum.find(found, &(elem(&1, 1) == "user")) || hd(found)
        thread = active[thread_id]

        {thread["updatedAt"] || "",
         %{
           "threadId" => thread_id,
           "projectId" => thread["projectId"],
           "source" => role,
           "snippet" => snippet(text, query),
           "messageCreatedAt" => at
         }}
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))

    {:ok, %{"matches" => matches}}
  end

  # The text around the first match, cut to fit.
  defp snippet(text, query) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= @snippet do
      text
    else
      body = @snippet - 4
      index = text |> String.downcase() |> :binary.match(String.downcase(query))

      match =
        case index do
          {byte, _} -> text |> binary_part(0, byte) |> String.length()
          :nomatch -> 0
        end

      start = min(max(match - 72, 0), String.length(text) - body)
      cut = String.slice(text, start, body)

      "#{if start > 0, do: "…"}#{cut}#{if start + body < String.length(text), do: "…"}"
    end
  end
end
