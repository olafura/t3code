defmodule T3.ProviderUsageLimits.Codex do
  @moduledoc """
  Codex subscription usage, as the Node server shapes it (codexUsageLimits.ts).

  `account/rateLimits/read` and the `account/rateLimits/updated` notification carry
  the same snapshot, so `windows/1` serves the probe (`probe/1`) and a turn's update
  alike, and both land on the rows `primary` and `secondary`. `consume/1` redeems a
  reset credit (`account/rateLimitResetCredit/consume`). Each opens its own
  short-lived `codex app-server`.
  """

  alias T3.JsonRpc.Connection
  alias T3.ProviderUsageLimits, as: Limits

  @session 5 * 60
  @week 7 * 24 * 60
  @month 30 * 24 * 60

  def command, do: Application.get_env(:t3, :codex_command, ["codex", "app-server"])

  def installed? do
    case command() do
      [executable | _] -> System.find_executable(executable) != nil
      _ -> false
    end
  end

  @doc """
  The main allowance's windows in a rate-limit snapshot. `primary` and `secondary`
  are positions, not durations: without `windowDurationMins`, paid plans have the
  five-hour and weekly pair and Free/Go one monthly allowance. Model-specific
  snapshots (such as Spark) describe another allowance and yield nothing.
  """
  def windows(%{} = snapshot) do
    if snapshot["limitId"] not in [nil, "", "codex"] do
      []
    else
      monthly = snapshot["planType"] in ["free", "go"]

      for {id, fallback} <- [
            {"primary", if(monthly, do: @month, else: @session)},
            {"secondary", @week}
          ],
          %{"usedPercent" => used} = window <- [snapshot[id]],
          is_number(used) do
        mins =
          if is_number(window["windowDurationMins"]),
            do: window["windowDurationMins"],
            else: fallback

        kind = kind(mins)

        %{
          "id" => id,
          "kind" => kind,
          "label" => label(kind),
          "usedPercent" => Limits.clamp(used),
          "windowDurationMins" => mins
        }
        |> Limits.put_present("resetsAt", Limits.iso_from_seconds(window["resetsAt"]))
      end
    end
  end

  def windows(_), do: []

  @doc "The `account/rateLimits/read` response as `ServerProviderUsageLimits`."
  def limits(response, checked_at) do
    snapshot = get_in(response, ["rateLimitsByLimitId", "codex"]) || response["rateLimits"]

    checked_at
    |> Limits.limits(windows(snapshot))
    |> Limits.put_present("resetCredits", reset_credits(response["rateLimitResetCredits"]))
  end

  defp reset_credits(%{"availableCount" => count} = summary) when is_integer(count) do
    expiries =
      for %{"status" => "available", "expiresAt" => at} <- summary["credits"] || [],
          is_number(at),
          do: at

    %{"availableCount" => max(0, count)}
    |> Limits.put_present(
      "nextExpiresAt",
      Limits.iso_from_seconds(Enum.min(expiries, fn -> nil end))
    )
  end

  defp reset_credits(_), do: nil

  @doc "The plan as the Codex provider labels it (`ChatGPT Pro 20x Subscription`), or nil."
  def plan_label(plan) do
    case plan do
      "free" ->
        "ChatGPT Free Subscription"

      "go" ->
        "ChatGPT Go Subscription"

      "plus" ->
        "ChatGPT Plus Subscription"

      "pro" ->
        "ChatGPT Pro 20x Subscription"

      "prolite" ->
        "ChatGPT Pro 5x Subscription"

      "team" ->
        "ChatGPT Team Subscription"

      p when p in ~w(self_serve_business_prolite self_serve_business_usage_based business) ->
        "ChatGPT Business Subscription"

      p when p in ~w(ent26 enterprise_cbp_automation enterprise_cbp_usage_based enterprise) ->
        "ChatGPT Enterprise Subscription"

      p when p in ~w(edu edu_plus edu_pro) ->
        "ChatGPT Edu Subscription"

      "unknown" ->
        "ChatGPT Subscription"

      _ ->
        nil
    end
  end

  defp kind(mins) when mins >= @month, do: "monthly"
  defp kind(mins) when mins >= @week, do: "weekly"
  defp kind(_), do: "session"

  defp label("session"), do: "Session"
  defp label("weekly"), do: "Weekly"
  defp label("monthly"), do: "Monthly"

  @doc """
  Reads the signed-in account's limits. An API key account has none (`unsupported`);
  a failed read is `probeFailed` with a short reason clients may show.
  """
  def probe(checked_at) do
    with_app_server(fn conn ->
      read = call(conn, "account/read", %{}, 10_000)

      with {:ok, %{"account" => %{} = account}} <- read,
           do: Limits.remember_account("codex", account(account))

      case read do
        {:ok, %{"account" => %{"type" => "apiKey"}}} ->
          Limits.unavailable(checked_at, "unsupported")

        {:ok, %{"account" => nil, "requiresOpenaiAuth" => true}} ->
          Limits.unavailable(checked_at, "probeFailed")

        {:ok, _} ->
          # Usage is an enrichment with its own short deadline, as on the Node server.
          case call(conn, "account/rateLimits/read", nil, 3_000) do
            {:ok, %{} = response} -> limits(response, checked_at)
            failure -> Limits.unavailable(checked_at, "probeFailed", failure(failure))
          end

        failure ->
          Limits.unavailable(checked_at, "probeFailed", failure(failure))
      end
    end) ||
      Limits.unavailable(checked_at, "probeFailed", "Codex could not be started to read usage.")
  end

  @doc false
  # `auth` fields for the signed-in account, as the Node server labels it.
  def account(%{"type" => "apiKey"}), do: %{"type" => "apiKey", "label" => "OpenAI API Key"}

  def account(%{"type" => "amazonBedrock"}),
    do: %{"type" => "amazonBedrock", "label" => "Amazon Bedrock"}

  def account(%{"type" => "chatgpt"} = account) do
    %{"type" => "chatgpt"}
    |> Limits.put_present("label", plan_label(account["planType"]))
    |> Limits.put_present("email", account["email"])
  end

  def account(_), do: %{}

  @doc "Redeems one reset credit; `key` names the attempt, so a retry reuses it."
  def consume(key) do
    with_app_server(fn conn ->
      case call(conn, "account/rateLimitResetCredit/consume", %{"idempotencyKey" => key}, 20_000) do
        {:ok, %{"outcome" => outcome}}
        when outcome in ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"] ->
          {:ok, outcome}

        other ->
          {:error, other}
      end
    end) || {:error, :spawn}
  end

  # Runs `fun` against a fresh, initialized app-server; nil when it cannot start.
  defp with_app_server(fun) do
    Process.flag(:trap_exit, true)

    case Connection.start_link(cmd: command(), handler: self()) do
      {:ok, conn} ->
        try do
          with {:ok, _} <-
                 call(
                   conn,
                   "initialize",
                   %{
                     "clientInfo" => %{"name" => "t3code_elixir", "version" => "0.1.0"},
                     "capabilities" => %{"experimentalApi" => true}
                   },
                   15_000
                 ) do
            Connection.notify(conn, "initialized", nil)
            fun.(conn)
          else
            _ -> nil
          end
        after
          stop(conn)
        end

      _ ->
        nil
    end
  end

  defp stop(conn) do
    Connection.stop(conn)
  catch
    :exit, _ -> :ok
  end

  defp call(conn, method, params, timeout) do
    Connection.call(conn, method, params, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  defp failure({:error, %{"code" => code}}), do: "Codex could not read usage (JSON-RPC #{code})."
  defp failure({:error, :closed}), do: "Codex exited before it could report usage."
  defp failure(_), do: "Codex did not answer the usage request."
end
