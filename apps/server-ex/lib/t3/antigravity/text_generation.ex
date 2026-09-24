defmodule T3.Antigravity.TextGeneration do
  @moduledoc """
  One text-generation prompt on Antigravity for `T3.TextGeneration`: a new
  session in an empty temporary directory, in the `default` permission mode, on
  the selected model (default-alias rules of `T3.Antigravity.Protocol`), told to
  use only the input. Any tool work, permission, file or user-input request, or a
  file left in the directory, fails the generation instead of being allowed. The
  session's files are removed afterwards.

  The instance offers text generation only while its profile has no global hooks
  or MCP servers (`T3.Antigravity.Profile.text_generation_available?/1`), which
  would run before a request could be refused.
  """

  alias T3.Antigravity.Protocol
  alias T3.JsonRpc.Connection

  @max_output 128_000
  @instructions "Use only the input below. Do not use tools, read or write files, run commands, or ask questions.\nReturn only the requested JSON object.\n\n"

  @doc "The agent's text for `prompt`: `{:ok, text}` or `{:error, message}`."
  def run(id, model, prompt) do
    if T3.Antigravity.Profile.text_generation_available?(id) do
      T3.Antigravity.in_temp_dir(id, "t3-antigravity-text-", fn dir ->
        with {:ok, conn, _init} <- T3.Antigravity.start_agent(id, dir) do
          try do
            generate(id, conn, dir, model, prompt)
          after
            Connection.stop(conn)
          end
        end
      end)
    else
      {:error,
       "Antigravity text generation is unavailable for profiles with global hooks or MCP configuration. Select another system model."}
    end
  end

  defp generate(id, conn, dir, model, prompt) do
    case Connection.call(conn, "session/new", %{"cwd" => dir, "mcpServers" => []}, 60_000) do
      {:ok, %{"sessionId" => session_id} = session} ->
        result =
          with :ok <- option(conn, session_id, "mode", "default"),
               :ok <- select_model(conn, session_id, session, model),
               {:ok, text} <- prompt(conn, session_id, prompt) do
            case File.ls(dir) do
              {:ok, []} -> {:ok, text}
              _ -> {:error, "Antigravity wrote files during text generation."}
            end
          end

        {:ok, session_id, result}

      {:error, %{"code" => -32000}} ->
        T3.Antigravity.auth_required(id)
        {:error, T3.Antigravity.sign_in_required()}

      _ ->
        {:error, "Antigravity text generation failed."}
    end
  end

  defp select_model(conn, session_id, session, model) do
    case Protocol.resolve_model(session["configOptions"] || [], model) do
      :keep -> :ok
      {:set, slug} -> option(conn, session_id, "model", slug)
      {:error, _} -> {:error, "Could not select the Antigravity model for text generation."}
    end
  end

  defp option(conn, session_id, config_id, value) do
    params = %{"sessionId" => session_id, "configId" => config_id, "value" => value}

    case Connection.call(conn, "session/set_config_option", params) do
      {:ok, _} -> :ok
      _ -> {:error, "Could not prepare the Antigravity text generation session."}
    end
  end

  defp prompt(conn, session_id, prompt) do
    params = %{
      "sessionId" => session_id,
      "prompt" => [%{"type" => "text", "text" => @instructions <> prompt}]
    }

    task = Task.async(fn -> Connection.call(conn, "session/prompt", params, :infinity) end)
    collect(conn, session_id, task, [])
  end

  defp collect(conn, session_id, task, text) do
    receive do
      {:json_rpc, ^conn,
       {:notification, "session/update", %{"sessionId" => ^session_id, "update" => update}}} ->
        case update do
          %{"sessionUpdate" => kind} when kind in ["tool_call", "tool_call_update"] ->
            refuse(
              conn,
              session_id,
              task,
              "Antigravity attempted tool work during text generation."
            )

          %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => chunk}
          } ->
            if IO.iodata_length(text) + byte_size(chunk) > @max_output,
              do:
                refuse(
                  conn,
                  session_id,
                  task,
                  "Antigravity text generation exceeded the output limit."
                ),
              else: collect(conn, session_id, task, [text, chunk])

          _ ->
            collect(conn, session_id, task, text)
        end

      {:json_rpc, ^conn, {:request, id, "session/request_permission", _params}} ->
        Connection.respond(conn, id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})

        refuse(
          conn,
          session_id,
          task,
          "Antigravity text generation requested a tool permission or user input."
        )

      {:json_rpc, ^conn, {:request, id, method, _params}} ->
        Connection.respond(
          conn,
          id,
          {:error, %{"code" => -32601, "message" => "#{method} is disabled for text generation"}}
        )

        refuse(
          conn,
          session_id,
          task,
          "Antigravity text generation requested a tool or user input."
        )

      {ref, reply} when ref == task.ref ->
        Process.demonitor(ref, [:flush])

        case {reply, text |> IO.iodata_to_binary() |> String.trim()} do
          {{:ok, %{"stopReason" => "cancelled"}}, _} ->
            {:error, "Antigravity text generation was cancelled."}

          {{:ok, _}, ""} ->
            {:error, "Antigravity returned empty text generation output."}

          {{:ok, _}, output} ->
            {:ok, output}

          _ ->
            {:error, "Antigravity text generation failed."}
        end

      {:json_rpc, ^conn, _other} ->
        collect(conn, session_id, task, text)
    end
  end

  defp refuse(conn, session_id, task, message) do
    Connection.notify(conn, "session/cancel", %{"sessionId" => session_id})
    Task.shutdown(task, :brutal_kill)
    {:error, message}
  end
end
