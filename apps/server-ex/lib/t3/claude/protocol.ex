defmodule T3.Claude.Protocol do
  @moduledoc """
  Pure encoding for the Claude Code CLI's stream-json protocol, the same wire the
  official Agent SDKs speak (`claude -p --input-format stream-json --output-format
  stream-json --permission-prompt-tool stdio`).

  Both directions carry `control_request` / `control_response` envelopes correlated
  by `request_id`. The CLI asks for tool permission with a `can_use_tool` control
  request; we send `initialize`, `interrupt`, `set_model`, `set_permission_mode`, and
  so on. Everything else (system, assistant, user, result, rate_limit_event, ...) is
  a transcript message.
  """

  @type incoming ::
          {:control_response, String.t(), {:ok, map} | {:error, String.t()}}
          | {:permission, String.t(), String.t(), map, map}
          | {:control_request, String.t(), map}
          | {:control_cancel, String.t()}
          | {:message, map}
          | {:invalid, binary}

  @spec cli_args(keyword) :: [String.t()]
  def cli_args(opts) do
    base = [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-prompt-tool",
      "stdio"
    ]

    base ++
      flag("--model", opts[:model]) ++
      flag("--permission-mode", opts[:permission_mode]) ++
      flag("--resume", opts[:resume]) ++
      if(opts[:persist_session] == false, do: ["--no-session-persistence"], else: []) ++
      if(opts[:partial_messages] == true, do: ["--include-partial-messages"], else: [])
  end

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, to_string(value)]

  @spec control_request(String.t(), String.t(), map) :: iodata
  def control_request(request_id, subtype, params),
    do:
      JSON.encode_to_iodata!(%{
        "type" => "control_request",
        "request_id" => request_id,
        "request" => Map.put(params, "subtype", subtype)
      })

  @spec user_message(String.t() | [map]) :: iodata
  def user_message(content, opts \\ []) do
    message = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => content},
      "parent_tool_use_id" => nil,
      "session_id" => ""
    }

    # "now" steers the running turn instead of waiting for it to end.
    message = if opts[:priority], do: Map.put(message, "priority", opts[:priority]), else: message
    JSON.encode_to_iodata!(message)
  end

  @spec permission_reply(String.t(), :allow | {:allow, map} | {:deny, String.t()}, map) :: iodata
  def permission_reply(request_id, decision, original_input) do
    body =
      case decision do
        :allow -> %{"behavior" => "allow", "updatedInput" => original_input}
        {:allow, input} -> %{"behavior" => "allow", "updatedInput" => input}
        {:deny, message} -> %{"behavior" => "deny", "message" => message}
      end

    control_success(request_id, body)
  end

  @spec control_success(String.t(), map) :: iodata
  def control_success(request_id, body),
    do:
      JSON.encode_to_iodata!(%{
        "type" => "control_response",
        "response" => %{"subtype" => "success", "request_id" => request_id, "response" => body}
      })

  @spec decode(binary) :: incoming
  def decode(line) do
    line |> JSON.decode!() |> classify()
  rescue
    _ -> {:invalid, line}
  end

  defp classify(%{
         "type" => "control_response",
         "response" => %{"request_id" => id, "subtype" => "success"} = r
       }),
       do: {:control_response, id, {:ok, r["response"] || %{}}}

  defp classify(%{"type" => "control_response", "response" => %{"request_id" => id} = r}),
    do: {:control_response, id, {:error, r["error"] || "control request failed"}}

  defp classify(%{
         "type" => "control_request",
         "request_id" => id,
         "request" => %{"subtype" => "can_use_tool"} = r
       }),
       do:
         {:permission, id, r["tool_name"], r["input"] || %{},
          Map.drop(r, ["subtype", "tool_name", "input"])}

  defp classify(%{"type" => "control_request", "request_id" => id, "request" => r}),
    do: {:control_request, id, r}

  defp classify(%{"type" => "control_cancel_request", "request_id" => id}),
    do: {:control_cancel, id}

  defp classify(%{"type" => _} = message), do: {:message, message}
  defp classify(other), do: {:invalid, other}
end
