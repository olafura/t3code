defmodule T3.Mcp do
  @moduledoc """
  The `t3-code` MCP server that agents get in their provider sessions, so an agent
  can work with T3 itself: read and message threads, launch new ones, and manage
  the queue, projects, and schedule (`T3.Mcp.Tools`).

  It is served at `POST /mcp` on the node, as JSON-RPC over HTTP (MCP's
  streamable HTTP transport, answered with plain JSON). Each thread has its own
  bearer credential (`server/2`), given to that thread's agent, so every tool call
  acts as the thread that made it. Credentials last as long as the node runs.

  Tool definitions and the instructions agents get come from the Node server
  (`scripts/export-mcp-tools.ts`), so both servers advertise the same tools.
  """

  use GenServer

  @table __MODULE__.Credentials
  @protocol "2025-06-18"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The MCP server for the agent of `thread_id` running on `instance`:
  `%{url: url, authorization: "Bearer ..."}`.
  """
  def server(thread_id, instance) do
    token =
      case :ets.match(@table, {:"$1", %{thread_id: thread_id, instance: instance}}) do
        [[token] | _] -> token
        [] -> GenServer.call(__MODULE__, {:credential, thread_id, instance})
      end

    port = Application.get_env(:t3, :port, 3780)
    %{url: "http://127.0.0.1:#{port}/mcp", authorization: "Bearer " <> token}
  end

  @doc """
  The MCP server to give the agent of `thread_id`, or nil when the user keeps T3's
  tools from agents (`enableAgentBrowserAccess`, which gates the whole server).
  """
  def for_agent(thread_id, instance) do
    allowed =
      Process.whereis(T3.Settings) == nil or
        T3.Settings.settings()["enableAgentBrowserAccess"] != false

    if Process.whereis(__MODULE__) && allowed, do: server(thread_id, instance)
  end

  @doc "What agents are told about the tools, for their system or developer prompt."
  def instructions do
    case :persistent_term.get({__MODULE__, :instructions}, nil) do
      nil ->
        text = File.read!(Application.app_dir(:t3, "priv/mcp_instructions.md"))
        :persistent_term.put({__MODULE__, :instructions}, text)
        text

      text ->
        text
    end
  end

  @doc """
  Answers one MCP request: `{status, body}` where `body` is JSON or nil. `authorization`
  is the request's Authorization header.
  """
  def handle(authorization, body) do
    with "Bearer " <> token <- authorization || :missing,
         [{_, caller}] <- :ets.lookup(@table, token) do
      case JSON.decode(body) do
        {:ok, %{"method" => method} = request} -> answer(request, method, caller)
        _ -> {400, rpc_error(nil, -32700, "Parse error")}
      end
    else
      _ ->
        {401,
         %{
           "error" => "invalid_mcp_credential",
           "message" => "A valid provider-scoped MCP bearer credential is required."
         }}
    end
  end

  # Notifications have no id and get no answer.
  defp answer(request, _method, _caller) when not is_map_key(request, "id"), do: {202, nil}

  defp answer(%{"id" => id} = request, method, caller) do
    case method do
      "initialize" ->
        {200,
         result(id, %{
           "protocolVersion" => get_in(request, ["params", "protocolVersion"]) || @protocol,
           "capabilities" => %{"tools" => %{"listChanged" => false}},
           "serverInfo" => %{"name" => "t3-code", "version" => "0.1.0"},
           "instructions" => instructions()
         })}

      "ping" ->
        {200, result(id, %{})}

      "tools/list" ->
        {200, result(id, %{"tools" => T3.Mcp.Tools.list()})}

      "tools/call" ->
        %{"name" => name} = params = request["params"] || %{}
        {200, result(id, call(name, params["arguments"] || %{}, caller))}

      _ ->
        {200, rpc_error(id, -32601, "Method not found: #{method}")}
    end
  end

  # A tool's answer as MCP content; a failure is an error result the agent can read.
  defp call(name, arguments, caller) do
    case T3.Mcp.Tools.call(name, arguments, caller) do
      {:ok, value} ->
        %{
          "content" => [%{"type" => "text", "text" => JSON.encode!(value)}],
          "structuredContent" => value
        }

      {:error, code, message} ->
        failure = %{"_tag" => "OrchestratorMcpFailure", "code" => code, "message" => message}
        %{"content" => [%{"type" => "text", "text" => JSON.encode!(failure)}], "isError" => true}
    end
  end

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp rpc_error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:credential, thread_id, instance}, _from, state) do
    caller = %{thread_id: thread_id, instance: instance}

    token =
      case :ets.match(@table, {:"$1", caller}) do
        [[token] | _] ->
          token

        [] ->
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          :ets.insert(@table, {token, caller})
          token
      end

    {:reply, token, state}
  end
end
