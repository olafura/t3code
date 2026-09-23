defmodule T3.ProviderUsageLimits.Claude do
  @moduledoc """
  Claude Code subscription usage, as the Node server shapes it (claudeUsageLimits.ts).

  Two sources produce windows with the same ids, so a turn's update lands on the row
  the probe drew:

    * `get_usage` (the probe, `probe/1`) reports every window at once as 0–100
      percentages with ISO reset times, plus model-scoped weeklies.
    * `rate_limit_event` (streamed in a turn, `event_window/2`) names one window
      with a 0–1 utilization and an epoch-seconds reset.

  The event names the model-scoped bucket by type (`seven_day_overage_included`)
  while `get_usage` names it by the model, so the probe hands back the name it saw
  for events to reuse; until a probe has named it, such events are dropped.
  """

  alias T3.Claude.Session
  alias T3.ProviderUsageLimits, as: Limits

  @session 5 * 60
  @week 7 * 24 * 60
  @windows %{
    "five_hour" => {"session", "Session", @session},
    "seven_day" => {"weekly", "Weekly", @week}
  }

  def command, do: Application.get_env(:t3, :claude_command, ["claude"])

  def installed? do
    case command() do
      [executable | _] -> System.find_executable(executable) != nil
      _ -> false
    end
  end

  @doc """
  The `get_usage` response as `{ServerProviderUsageLimits, overage_name}`. An account
  without plan limits (API key, Bedrock, Vertex) is `unsupported`.
  """
  def limits(%{"rate_limits_available" => true, "rate_limits" => %{} = rate_limits}, checked_at) do
    windows =
      for {id, _} <- @windows,
          %{"utilization" => used} = window <- [rate_limits[id]],
          is_number(used),
          do: window(id, used, Limits.iso(window["resets_at"]))

    scoped =
      for %{"display_name" => name, "utilization" => used} = entry <-
            List.wrap(rate_limits["model_scoped"]),
          is_binary(name) and is_number(used),
          do: {name, scoped_window(name, used, Limits.iso(entry["resets_at"]))}

    names = with [{name, _} | _] <- scoped, do: name, else: (_ -> nil)
    {Limits.limits(checked_at, windows ++ Enum.map(scoped, &elem(&1, 1))), names}
  end

  def limits(_response, checked_at), do: {Limits.unavailable(checked_at, "unsupported"), nil}

  @doc "The window a `rate_limit_event`'s `rate_limit_info` names, or nil."
  def event_window(%{"rateLimitType" => type, "utilization" => used} = info, overage_name)
      when is_number(used) do
    resets_at = Limits.iso_from_seconds(info["resetsAt"])

    cond do
      Map.has_key?(@windows, type) ->
        window(type, used * 100, resets_at)

      type == "seven_day_overage_included" and overage_name != nil ->
        scoped_window(overage_name, used * 100, resets_at)

      true ->
        nil
    end
  end

  def event_window(_info, _overage_name), do: nil

  defp window(id, used, resets_at) do
    {kind, label, mins} = @windows[id]

    %{
      "id" => id,
      "kind" => kind,
      "label" => label,
      "windowDurationMins" => mins,
      "usedPercent" => Limits.clamp(used)
    }
    |> Limits.put_present("resetsAt", resets_at)
  end

  defp scoped_window(name, used, resets_at) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    %{
      "id" => "seven_day_" <> slug,
      "kind" => "weekly",
      "label" => "Weekly · " <> name,
      "windowDurationMins" => @week,
      "usedPercent" => Limits.clamp(used)
    }
    |> Limits.put_present("resetsAt", resets_at)
  end

  @doc """
  Asks a short-lived `claude` session for `get_usage`. The session never gets a
  prompt, so nothing reaches the model, and it runs without the user's hooks or MCP
  servers since it recurs every few minutes.
  """
  def probe(checked_at) do
    Process.flag(:trap_exit, true)

    opts = [
      handler: self(),
      command: command() ++ ["--settings", ~s({"disableAllHooks":true}), "--strict-mcp-config"],
      persist_session: false,
      env: [
        {"ENABLE_CLAUDEAI_MCP_SERVERS", "false"},
        {"CLAUDE_CODE_AUTO_CONNECT_IDE", "0"},
        {"CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL", "1"}
      ]
    ]

    with {:ok, session} <- Session.start_link(opts) do
      try do
        result =
          case Session.control(session, "get_usage", %{}, 20_000) do
            {:ok, response} -> limits(response, checked_at)
            _ -> {Limits.unavailable(checked_at, "probeFailed"), nil}
          end

        # The initialize reply came first; it names the account.
        receive do
          {:claude, ^session, {:initialized, {:ok, init}}} ->
            Limits.remember_account("claudeAgent", account(init["account"]))
        after
          1_000 -> :ok
        end

        result
      catch
        :exit, _ -> {Limits.unavailable(checked_at, "probeFailed"), nil}
      after
        stop(session)
      end
    else
      _ -> {Limits.unavailable(checked_at, "probeFailed"), nil}
    end
  end

  @doc false
  # `auth` fields for the account `initialize` reports, as the Node server labels them.
  def account(%{} = account) do
    method = String.downcase(String.replace(account["tokenSource"] || "", ~r/[\s_-]+/, ""))
    subscription = account["subscriptionType"]

    auth =
      cond do
        method in ~w(apikey anthropicapikey anthropicauthtoken) ->
          %{"type" => "apiKey", "label" => "Claude API Key"}

        is_binary(subscription) and subscription != "" ->
          %{"type" => subscription, "label" => subscription_label(subscription)}

        account["apiProvider"] == "bedrock" ->
          %{"type" => "bedrock", "label" => "Amazon Bedrock"}

        true ->
          %{}
      end

    Limits.put_present(auth, "email", account["email"])
  end

  def account(_), do: %{}

  @plans %{
    "claudemaxsubscription" => "Max",
    "claudemax5xsubscription" => "Max 5x",
    "claudemax20xsubscription" => "Max 20x",
    "claudeenterprisesubscription" => "Enterprise",
    "claudeteamsubscription" => "Team",
    "claudeprosubscription" => "Pro",
    "claudefreesubscription" => "Free",
    "max" => "Max",
    "maxplan" => "Max",
    "max5" => "Max 5x",
    "max20" => "Max 20x",
    "enterprise" => "Enterprise",
    "team" => "Team",
    "pro" => "Pro",
    "free" => "Free"
  }

  defp subscription_label(type) do
    plan = @plans[String.downcase(String.replace(type, ~r/[\s_-]+/, ""))] || title_case(type)
    squashed = String.downcase(String.replace(plan, ~r/[\s_-]+/, ""))

    cond do
      String.starts_with?(squashed, "claude") and String.ends_with?(squashed, "subscription") ->
        plan

      String.starts_with?(squashed, "claude") ->
        "#{plan} Subscription"

      String.ends_with?(squashed, "subscription") ->
        "Claude #{plan}"

      true ->
        "Claude #{plan} Subscription"
    end
  end

  defp title_case(value) do
    value
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.map_join(
      " ",
      &(String.upcase(String.first(&1)) <> String.downcase(String.slice(&1, 1..-1//1)))
    )
  end

  defp stop(session) do
    GenServer.stop(session)
  catch
    :exit, _ -> :ok
  end
end
