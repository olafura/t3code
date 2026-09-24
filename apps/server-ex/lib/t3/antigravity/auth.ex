defmodule T3.Antigravity.Auth do
  @moduledoc """
  Antigravity sign-in and sign-out for `T3.ProviderAuth`.

  Sign-in runs the agent in a throwaway directory and calls `authenticate` with
  the instance's method. For a Google method the agent opens Google's page, which
  T3 catches (`T3.Antigravity.Profile`) and shows the client as a browser
  interaction that accepts a callback: on the same machine the page redirects to
  the agent's loopback server by itself; from anywhere else the user pastes the
  redirect URL (`provider.auth.complete`), which is checked against the pending
  request (`T3.Antigravity.Protocol.validate_callback/2`) and forwarded to that
  loopback server. Key-based methods authenticate without a page. Either way the
  sign-in ends by opening a session, whose models the provider then shows.

  Running Antigravity sessions of the instance are stopped first
  (`T3.Acp.ThreadRuntime.release/1`), so none keeps credentials from before.

  The worker keeps its pending Google request in its process dictionary; it is a
  process of its own, started for one sign-in.
  """

  alias T3.JsonRpc.Connection

  @forward_failed "Could not deliver the sign-in response. Start sign-in again."

  @doc "The one method a sign-in uses: the instance's configured `authMethod`."
  def methods(instance) do
    method = T3.Antigravity.config(instance)["authMethod"]

    {:ok,
     [
       %{
         "id" => method,
         "name" => T3.Antigravity.auth_label(method),
         "description" => nil,
         "type" => "agent"
       }
     ]}
  end

  @doc "Runs one sign-in; exits `:normal` on success (see `T3.ProviderAuth`)."
  def login(instance, _method_id, server, flow_id) do
    browser = T3.Antigravity.uses_browser?(T3.Antigravity.config(instance)["authMethod"])
    T3.Acp.ThreadRuntime.release(instance)

    result =
      T3.Antigravity.in_temp_dir(instance, "t3-antigravity-setup-", fn cwd ->
        sign_in(instance, cwd, server, flow_id, browser)
      end)

    case result do
      :ok -> :ok
      {:error, reason} -> exit({:shutdown, {:failed, failure(reason, browser)}})
    end
  end

  defp sign_in(instance, cwd, server, flow_id, browser) do
    worker = self()

    on_url = fn request ->
      case Process.get(:antigravity_sign_in) do
        nil ->
          Process.put(:antigravity_sign_in, request)

          interaction = %{
            "type" => "browser",
            "id" => flow_id,
            "url" => request.url,
            "requiresConsent" => false,
            "acceptsCallback" => true
          }

          send(
            server,
            {:auth_interaction, flow_id, interaction, worker,
             "Open the Google sign-in link. If you are remote, paste the redirect URL here."}
          )

          :ok

        %{url: url} when url == request.url ->
          :ok

        _other ->
          {:error, "Antigravity started more than one Google sign-in request."}
      end
    end

    handle = fn
      {:auth_callback, callback, from} ->
        callback(server, flow_id, worker, callback, from)
        :ok

      :antigravity_forward_failed ->
        {:error, @forward_failed}

      _other ->
        :ok
    end

    opts = [handle: handle] ++ if(browser, do: [on_url: on_url], else: [])

    with {:ok, conn, init} <- T3.Antigravity.start_agent(instance, cwd, opts) do
      send(server, {:auth_verifying, flow_id, "Checking Antigravity access and models."})

      try do
        case Connection.call(conn, "session/new", %{"cwd" => cwd, "mcpServers" => []}, 60_000) do
          {:ok, %{"sessionId" => session_id} = result} ->
            T3.Antigravity.session_started(instance, init, result, nil)
            T3.Antigravity.drain_updates(instance, conn)
            {:ok, session_id, :ok}

          {:error, reason} ->
            {:error, {:session, reason}}

          {:ok, _other} ->
            {:error, {:session, :unexpected}}
        end
      after
        Connection.stop(conn)
      end
    end
  end

  # A pasted redirect: checked against the pending request, then sent to the
  # agent's loopback server off this process, which keeps serving the agent.
  defp callback(server, flow_id, worker, callback, from) do
    pending = Process.get(:antigravity_sign_in)

    cond do
      pending == nil ->
        send(
          server,
          {:auth_complete, from,
           {:error, "Wait for the Google sign-in link before you send a redirect URL."}}
        )

      Process.get(:antigravity_callback_sent) ->
        send(
          server,
          {:auth_complete, from,
           {:error, "The sign-in response was already sent. Wait for Google to finish."}}
        )

      true ->
        case T3.Antigravity.Protocol.validate_callback(callback, pending) do
          :ok ->
            Process.put(:antigravity_callback_sent, true)
            send(server, {:auth_verifying, flow_id, "Waiting for Google to finish sign-in."})

            Task.start(fn ->
              result = forward(callback)
              send(server, {:auth_complete, from, result})
              if result != :ok, do: send(worker, :antigravity_forward_failed)
            end)

          {:error, _} = error ->
            send(server, {:auth_complete, from, error})
        end
    end
  end

  @doc "Sends the redirect to the agent's loopback server: no proxy, no redirects."
  def forward(callback) do
    case :httpc.request(
           :get,
           {String.to_charlist(callback), []},
           [timeout: 10_000, autoredirect: false],
           []
         ) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      _ -> {:error, @forward_failed}
    end
  end

  # What a failed sign-in tells the user; never the agent's raw error.
  defp failure(reason, browser) do
    message =
      case reason do
        {:session, %{"message" => message}} -> message
        %{"message" => message} -> message
        _ -> ""
      end

    code =
      case reason do
        {:session, %{"code" => code}} -> {:session, code}
        %{"code" => code} -> code
        _ -> nil
      end

    cond do
      is_binary(reason) and reason != T3.Antigravity.sign_in_required() ->
        reason

      String.contains?(message, "SUBSCRIPTION_REQUIRED") ->
        "Google requires an eligible Antigravity subscription for this account."

      Regex.match?(~r/access_denied|denied access|cancelled/i, message) ->
        "Google sign-in was not approved. Start sign-in again."

      code == {:session, -32603} ->
        "Antigravity authenticated, but could not initialize a session or load models."

      not browser and code == -32602 ->
        "Antigravity rejected the configured credentials. Check the provider settings."

      browser ->
        "Google sign-in failed. Start sign-in again."

      true ->
        "Antigravity could not authenticate with the configured credentials."
    end
  end

  @doc "Signs the instance out through the agent's own `logout`. `:ok` or `{:error, message}`."
  def logout(instance) do
    T3.Acp.ThreadRuntime.release(instance)

    T3.Antigravity.in_temp_dir(instance, "t3-antigravity-setup-", fn cwd ->
      with {:ok, conn, init} <- T3.Antigravity.start_agent(instance, cwd, authenticate: false) do
        try do
          cond do
            not is_map(get_in(init, ["agentCapabilities", "auth", "logout"])) ->
              {:error, "This Antigravity version does not support sign-out. Update the provider."}

            match?({:ok, _}, Connection.call(conn, "logout", %{}, 90_000)) ->
              T3.Antigravity.signed_out(instance)
              :ok

            true ->
              {:error, "Antigravity sign-out failed. Try again."}
          end
        after
          Connection.stop(conn)
        end
      end
    end)
  end
end
