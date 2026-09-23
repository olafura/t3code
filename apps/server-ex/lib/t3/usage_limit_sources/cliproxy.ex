defmodule T3.UsageLimitSources.Cliproxy do
  @moduledoc """
  A CLIProxyAPI hub's management API, used as the Node server's cliproxyApi.ts uses
  it: `auth-files` lists the pooled accounts, and `api-call` makes a request with one
  account's own token, which is how each account's usage and a Codex account's reset
  credits are read and redeemed. The hub makes the upstream request, not this node.

  Every failure is a short message fit for the source's `error` row.
  """

  alias T3.ProviderUsageLimits, as: Limits
  alias T3.ProviderUsageLimits.{Claude, Codex}

  @codex_base "https://chatgpt.com/backend-api/wham"
  @credit_url @codex_base <> "/rate-limit-reset-credits"
  @claude_usage "https://api.anthropic.com/api/oauth/usage"
  @outcomes %{
    "reset" => "reset",
    "nothing_to_reset" => "nothingToReset",
    "no_credit" => "noCredit",
    "already_redeemed" => "alreadyRedeemed"
  }
  # Makes a redemption's request id the same from every T3 environment.
  @redeem_namespace Base.decode16!("6f1c2a9e2d4b4c1e9a7f3b8d5e0c1a42", case: :lower)

  @doc "`UsageLimitSourceAccount`s for the hub's enabled Codex and Claude accounts."
  def read_accounts(config, key) do
    case auth_files(config, key) do
      {:ok, files} ->
        accounts =
          files
          |> Enum.filter(&(&1["disabled"] != true and &1["provider"] in ["codex", "claude"]))
          |> Task.async_stream(&read_account(config, key, &1),
            max_concurrency: 4,
            timeout: 60_000,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, account} -> [account]
            _ -> []
          end)

        {:ok, accounts}

      {:error, _} ->
        {:error, "The hub could not list accounts."}
    end
  end

  @doc """
  Redeems `credit_id` for a Codex account, then clears the hub's own cooldown for it
  so routing resumes; a cooldown that could not be cleared is a warning, not a failure.
  """
  def consume(config, key, account_id, credit_id) do
    with {:ok, files} <- auth_files(config, key),
         {:ok, account} <- codex_account(files, account_id),
         {:ok, body} <-
           api_call(config, key, account, @credit_url <> "/consume", %{
             "redeem_request_id" =>
               redeem_request_id(
                 get_in(account, ["id_token", "chatgpt_account_id"]) || account["id"],
                 credit_id
               ),
             "credit_id" => credit_id
           }),
         {:ok, outcome} <- outcome(body) do
      if outcome in ["reset", "alreadyRedeemed"] do
        case management(config, key, "reset-quota", %{"auth_index" => account["auth_index"]}) do
          {:ok, _} ->
            {:ok, %{"outcome" => outcome}}

          {:error, _} ->
            {:ok,
             %{
               "outcome" => outcome,
               "warning" =>
                 "Credit redeemed, but the hub cooldown could not be cleared. Routing may resume after its cooldown expires."
             }}
        end
      else
        {:ok, %{"outcome" => outcome}}
      end
    end
  end

  @doc "A UUIDv5-shaped id per account and credit, so retries anywhere are one attempt."
  def redeem_request_id(account_id, credit_id) do
    <<a::binary-size(6), b6, b7, b8, rest::binary-size(7), _::binary>> =
      :crypto.hash(:sha, [@redeem_namespace, "#{account_id}:#{credit_id}"])

    hex =
      <<a::binary, Bitwise.bor(Bitwise.band(b6, 0x0F), 0x50), b7,
        Bitwise.bor(Bitwise.band(b8, 0x3F), 0x80), rest::binary>>
      |> Base.encode16(case: :lower)

    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4),
      p5::binary-size(12)>> = hex

    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  defp codex_account(files, account_id) do
    case Enum.find(files, &(&1["id"] == account_id)) do
      %{"provider" => "codex", "disabled" => true} -> {:error, missing_account()}
      %{"provider" => "codex"} = account -> {:ok, account}
      _ -> {:error, missing_account()}
    end
  end

  defp missing_account, do: "The Codex hub account is missing or disabled."

  defp outcome(body) do
    case JSON.decode(body) do
      {:ok, %{"code" => code}} when is_map_key(@outcomes, code) -> {:ok, @outcomes[code]}
      _ -> {:error, "The hub returned an unexpected reset-credit response."}
    end
  end

  defp read_account(config, key, account) do
    checked_at = T3.Orchestration.Entities.now()

    base =
      %{"id" => account["id"], "driver" => driver(account)}
      |> Limits.put_present("email", present(account["email"]))

    case read_usage(config, key, account, checked_at) do
      {:ok, fields} ->
        Map.merge(base, fields)

      _ ->
        Map.put(
          base,
          "usageLimits",
          Limits.unavailable(
            checked_at,
            "probeFailed",
            "The hub could not read this account's usage."
          )
        )
    end
  end

  defp read_usage(config, key, %{"provider" => "claude"} = account, checked_at) do
    with {:ok, body} <- api_call(config, key, account, @claude_usage),
         {:ok, %{} = usage} <- JSON.decode(body) do
      scoped =
        for %{"kind" => "weekly_scoped", "percent" => percent} = limit <-
              List.wrap(usage["limits"]),
            is_number(percent),
            %{"display_name" => name} <- [get_in(limit, ["scope", "model"])],
            is_binary(name),
            do: %{
              "display_name" => name,
              "utilization" => percent,
              "resets_at" => limit["resets_at"]
            }

      {limits, _} =
        Claude.limits(
          %{
            "rate_limits_available" => true,
            "rate_limits" => %{
              "five_hour" => usage["five_hour"],
              "seven_day" => usage["seven_day"],
              "model_scoped" => scoped
            }
          },
          checked_at
        )

      {:ok, %{"plan" => "Claude Subscription", "usageLimits" => limits}}
    end
  end

  defp read_usage(config, key, account, checked_at) do
    with {:ok, body} <- api_call(config, key, account, @codex_base <> "/usage"),
         {:ok, %{} = usage} <- JSON.decode(body) do
      rate_limit = usage["rate_limit"] || %{}

      limits =
        Codex.limits(
          %{
            "rateLimits" => %{
              "planType" => usage["plan_type"],
              "primary" => codex_window(rate_limit["primary_window"]),
              "secondary" => codex_window(rate_limit["secondary_window"])
            }
          },
          checked_at
        )
        # A credits outage must not hide windows that were read.
        |> Limits.put_present("resetCredits", credits(config, key, account))

      plan =
        Codex.plan_label(usage["plan_type"] || get_in(account, ["id_token", "chatgpt_plan_type"]))

      {:ok, Limits.put_present(%{"usageLimits" => limits}, "plan", plan)}
    end
  end

  defp codex_window(%{"used_percent" => used} = window) do
    mins =
      case window["limit_window_seconds"] do
        s when is_integer(s) and rem(s, 60) == 0 -> div(s, 60)
        s when is_number(s) -> s / 60
        _ -> nil
      end

    %{"usedPercent" => used, "resetsAt" => window["reset_at"]}
    |> Limits.put_present("windowDurationMins", mins)
  end

  defp codex_window(_), do: nil

  defp credits(config, key, account) do
    now = DateTime.utc_now()

    with {:ok, body} <- api_call(config, key, account, @credit_url),
         {:ok, %{"credits" => credits}} when is_list(credits) <- JSON.decode(body) do
      available =
        for %{"id" => id, "status" => "available", "reset_type" => "codex_rate_limits"} = credit <-
              credits,
            {:ok, expires, _} <- [DateTime.from_iso8601(credit["expires_at"] || "")],
            DateTime.after?(expires, now) do
          {id, expires}
        end
        |> Enum.sort_by(&elem(&1, 1), DateTime)

      case available do
        [{id, expires} | _] ->
          %{
            "availableCount" => length(available),
            "nextCreditId" => id,
            "nextExpiresAt" => Limits.iso(DateTime.to_iso8601(expires))
          }

        [] ->
          %{"availableCount" => 0}
      end
    else
      _ -> nil
    end
  end

  defp driver(%{"provider" => "codex"}), do: "codex"
  defp driver(_), do: "claudeAgent"

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp auth_files(config, key) do
    case management(config, key, "auth-files") do
      {:ok, %{"files" => files}} when is_list(files) ->
        {:ok, Enum.filter(files, &(is_binary(&1["id"]) and is_binary(&1["auth_index"])))}

      {:ok, _} ->
        {:error, "The hub management request failed."}

      error ->
        error
    end
  end

  # A request made by the hub with the account's own token (`$TOKEN$`).
  defp api_call(config, key, account, url, data \\ nil) do
    header =
      case account["provider"] do
        "codex" ->
          %{
            "Authorization" => "Bearer $TOKEN$",
            "Content-Type" => "application/json",
            "OpenAI-Beta" => "codex-1",
            "Originator" => "Codex Desktop"
          }
          |> Limits.put_present(
            "Chatgpt-Account-Id",
            get_in(account, ["id_token", "chatgpt_account_id"])
          )

        _ ->
          %{"Authorization" => "Bearer $TOKEN$", "anthropic-beta" => "oauth-2025-04-20"}
      end

    request =
      %{
        "auth_index" => account["auth_index"],
        "method" => if(data == nil, do: "GET", else: "POST"),
        "url" => url,
        "header" => header
      }
      |> Limits.put_present("data", data && JSON.encode!(data))

    case management(config, key, "api-call", request) do
      {:ok, %{"status_code" => status, "body" => body}}
      when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{"status_code" => status}} when is_integer(status) ->
        {:error, "The provider refused the hub request (HTTP #{status})."}

      {:ok, _} ->
        {:error, "The hub management request failed."}

      error ->
        error
    end
  end

  defp management(config, key, path, body \\ nil) do
    with {:ok, url} <- url(config["url"], "/v0/management/" <> path) do
      headers = [{~c"authorization", ~c"Bearer " ++ to_charlist(key)}]

      request =
        if body == nil,
          do: {:get, {url, headers}},
          else: {:post, {url, headers, ~c"application/json", JSON.encode!(body)}}

      options = [
        timeout: 15_000,
        connect_timeout: 10_000,
        ssl: :httpc.ssl_verify_host_options(true)
      ]

      with {:ok, {{_, status, _}, _, response}} when status in 200..299 <-
             :httpc.request(elem(request, 0), elem(request, 1), options, body_format: :binary),
           {:ok, json} <- JSON.decode(response) do
        {:ok, json}
      else
        _ -> {:error, "The hub management request failed."}
      end
    end
  end

  defp url(base, path) when is_binary(base) do
    case URI.parse(base) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, uri |> URI.merge(path) |> URI.to_string() |> to_charlist()}

      _ ->
        {:error, "The hub URL is not valid."}
    end
  end

  defp url(_, _), do: {:error, "The hub URL is not valid."}
end
