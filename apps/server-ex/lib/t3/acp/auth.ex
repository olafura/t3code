defmodule T3.Acp.Auth do
  @moduledoc """
  ACP sign-in for `T3.ProviderAuth`. Credentials stay in the agent's own store.

  An agent lists its methods in `initialize`: `agent` methods sign in through
  `authenticate`, during which the agent may ask the client to open a URL
  (`elicitation/create`); `terminal` methods run the agent's login command in a
  PTY whose output the client shows and types into; `env_var` methods read
  variables set on the instance, so there is nothing to run. Every method ends by
  opening a session, which only works once the agent is signed in.
  """

  alias T3.JsonRpc.Connection

  @login_timeout 300_000
  @transcript_bytes 16_384

  @doc "The instance's sign-in methods as `ProviderAuthMethod`s."
  def methods(instance) do
    result =
      T3.Acp.with_agent(instance, System.tmp_dir!(), fn _conn, init ->
        {:ok,
         for %{"id" => id, "name" => name} = method <- Enum.take(init["authMethods"] || [], 32),
             is_binary(id) and is_binary(name) and byte_size(id) <= 128 do
           %{
             "id" => id,
             "name" => name,
             "description" => method["description"],
             "type" =>
               case method["type"] do
                 "terminal" -> "terminal"
                 "env_var" -> "credentials"
                 _ -> "agent"
               end
           }
         end}
      end)

    case result do
      {:ok, methods} ->
        {:ok, methods}

      {:error, reason} ->
        {:error, "Could not discover this agent's sign-in methods: #{message(reason)}"}
    end
  end

  @doc "Runs one sign-in; exits `:normal` on success (see `T3.ProviderAuth`)."
  def login(instance, method_id, server, flow_id) do
    cwd = System.tmp_dir!()

    with {:ok, command, env} <- T3.Acp.command(instance),
         {:ok, conn} <- start(command, env, cwd),
         {:ok, init} <- Connection.call(conn, "initialize", T3.Acp.initialize_params()) do
      case Enum.find(init["authMethods"] || [], &(&1["id"] == method_id)) do
        nil ->
          fail("The agent no longer advertises this sign-in method.")

        %{"type" => "terminal"} = method ->
          Connection.stop(conn)
          terminal(command, env, method, cwd, server, flow_id)
          {:ok, conn} = start(command, env, cwd)
          {:ok, _} = Connection.call(conn, "initialize", T3.Acp.initialize_params())
          verify(conn, cwd, server, flow_id)

        %{"type" => "env_var"} ->
          verify(conn, cwd, server, flow_id)

        _agent ->
          authenticate(conn, method_id, server, flow_id)
          verify(conn, cwd, server, flow_id)
      end
    else
      {:error, reason} -> fail("Could not start the agent: #{message(reason)}")
    end
  end

  defp start(command, env, cwd),
    do: Connection.start_link(cmd: command, handler: self(), cd: cwd, env: env, dialect: :v2)

  # `authenticate` runs off this process, which answers the agent's requests meanwhile.
  defp authenticate(conn, method_id, server, flow_id) do
    task =
      Task.async(fn ->
        Connection.call(conn, "authenticate", %{"methodId" => method_id}, @login_timeout)
      end)

    await_authenticate(conn, task, server, flow_id)
  end

  defp await_authenticate(conn, task, server, flow_id) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, _} -> :ok
          {:error, reason} -> fail("The agent could not complete sign-in: #{message(reason)}")
        end

      {:json_rpc, ^conn, {:request, id, "elicitation/create", params}} ->
        Connection.respond(conn, id, {:ok, elicit(params, server, flow_id)})
        await_authenticate(conn, task, server, flow_id)

      {:json_rpc, ^conn, {:request, id, method, _params}} ->
        Connection.respond(conn, id, {:error, %{"code" => -32601, "message" => method}})
        await_authenticate(conn, task, server, flow_id)

      {:json_rpc, ^conn, _notification} ->
        await_authenticate(conn, task, server, flow_id)
    end
  end

  # The client opens the URL after the user consents; the agent watches for the result.
  defp elicit(
         %{"mode" => "url", "url" => "https://" <> _ = url, "elicitationId" => id},
         server,
         flow_id
       )
       when is_binary(id) and byte_size(id) <= 128 do
    interaction = %{"type" => "browser", "id" => id, "url" => url, "requiresConsent" => true}
    send(server, {:auth_interaction, flow_id, interaction, self()})

    receive do
      {:auth_response, %{"type" => "browser", "action" => "accept"}} -> %{"action" => "accept"}
      {:auth_response, %{"type" => "browser"}} -> %{"action" => "decline"}
    end
  end

  defp elicit(_params, _server, _flow_id), do: %{"action" => "decline"}

  # The agent's login command, in a PTY the client sees and types into.
  defp terminal(command, env, method, cwd, server, flow_id) do
    # erlexec runs an argv as is, without a PATH lookup.
    [program | args] = command ++ Enum.filter(method["args"] || [], &is_binary/1)
    argv = [System.find_executable(program) || program | args]
    method_env = for {k, v} <- method["env"] || %{}, is_binary(v), do: {k, v}

    # Linked, so a cancelled sign-in (this worker killed) takes the command down too.
    Process.flag(:trap_exit, true)

    options = [
      :stdin,
      :stdout,
      :pty,
      :link,
      :monitor,
      {:winsz, {24, 80}},
      {:cd, String.to_charlist(cwd)},
      {:env, env ++ method_env},
      {:kill_timeout, 1}
    ]

    case :exec.run(argv, options) do
      {:ok, exec_pid, os_pid} ->
        try do
          show(server, flow_id, "", 0)
          terminal_loop({exec_pid, os_pid}, server, flow_id, "", 0)
        after
          :exec.stop(os_pid)
          Process.flag(:trap_exit, false)
        end

      {:error, reason} ->
        fail("Could not open the sign-in terminal: #{inspect(reason)}")
    end
  end

  defp terminal_loop({exec_pid, os_pid} = process, server, flow_id, transcript, offset) do
    receive do
      {:stdout, ^os_pid, data} ->
        transcript = binary_tail(transcript <> data, @transcript_bytes)
        offset = offset + byte_size(data)
        show(server, flow_id, transcript, offset)
        terminal_loop(process, server, flow_id, transcript, offset)

      {:auth_response, %{"type" => "terminal"} = response} ->
        case response["size"] do
          %{"cols" => cols, "rows" => rows} -> :exec.winsz(os_pid, rows, cols)
          _ -> :ok
        end

        if is_binary(response["data"]) and response["data"] != "",
          do: :exec.send(os_pid, response["data"])

        terminal_loop(process, server, flow_id, transcript, offset)

      # Linked, the command's exit arrives as a signal rather than a monitor message.
      {tag, ^os_pid, :process, _pid, reason} when tag == :DOWN ->
        exited(reason)

      {:EXIT, ^exec_pid, reason} ->
        exited(reason)
    end
  end

  defp exited(:normal), do: :ok
  defp exited(_reason), do: fail("The provider login command did not finish successfully.")

  defp show(server, flow_id, transcript, offset) do
    interaction = %{
      "type" => "terminal",
      "id" => "terminal",
      "output" => transcript,
      "outputOffset" => offset
    }

    send(server, {:auth_interaction, flow_id, interaction, self()})
  end

  # Keeps the last `max` bytes without splitting a UTF-8 character.
  defp binary_tail(text, max) when byte_size(text) <= max, do: text

  defp binary_tail(text, max) do
    tail = binary_part(text, byte_size(text) - max, max)
    if String.valid?(tail), do: tail, else: binary_tail(tail, max - 1)
  end

  defp verify(conn, cwd, server, flow_id) do
    send(server, {:auth_verifying, flow_id})

    case Connection.call(conn, "session/new", %{"cwd" => cwd, "mcpServers" => []}, 60_000) do
      {:ok, _} ->
        Connection.stop(conn)
        :ok

      {:error, reason} ->
        fail("The provider could not open a session after sign-in: #{message(reason)}")
    end
  end

  defp fail(message), do: exit({:shutdown, {:failed, message}})

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
