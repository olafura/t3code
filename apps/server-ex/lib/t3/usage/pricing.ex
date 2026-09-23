defmodule T3.Usage.Pricing do
  @moduledoc """
  Model rates and cost arithmetic for `T3.Usage`.

  Rates come from LiteLLM's `model_prices_and_context_window.json` (the table
  `ccusage` prices against), fetched at most daily and kept in
  `<home>/usage-model-rates.json` so the page still prices offline. A rate is
  `{input, output, cache_read, cache_creation}` in USD per token, at the base tier:
  transcripts do not record which tier served a request. The table URL is
  `config :t3, :usage_rates_url`; a value that is not an http(s) URL is read as a file.
  """

  @litellm "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  @ttl_ms 24 * 60 * 60 * 1000
  @refresh_floor_ms 60 * 1000

  # Locally generated messages, and bare family names that span generations.
  @unpriceable MapSet.new(~w(<synthetic> synthetic opus sonnet haiku fable))

  @doc "No rates yet."
  def empty, do: %{table: %{}, fetched_at_ms: nil, status: "unavailable"}

  @doc "The contract's `UsagePricing` for `rates`."
  def describe(rates) do
    %{
      "status" => rates.status,
      "source" => url(),
      "fetchedAt" => rates.fetched_at_ms && iso(rates.fetched_at_ms),
      "knownModels" => map_size(rates.table)
    }
  end

  @doc """
  Loads the table when it is older than the TTL (or than a minute, when `force`d),
  preferring a fresh copy and falling back to the snapshot on disk. With neither,
  every model reports as unpriced.
  """
  def load(rates, force) do
    now = System.system_time(:millisecond)
    max_age = if force, do: @refresh_floor_ms, else: @ttl_ms
    path = Path.join(Application.fetch_env!(:t3, :home), "usage-model-rates.json")

    rates =
      with nil <- rates.fetched_at_ms,
           {:ok, text} <- File.read(path),
           {:ok, %{"fetchedAtMs" => at, "document" => document}} when is_number(at) <-
             JSON.decode(text),
           table when map_size(table) > 0 <- parse(document) do
        %{table: table, fetched_at_ms: at, status: "cached"}
      else
        _ -> rates
      end

    if rates.fetched_at_ms != nil and now - rates.fetched_at_ms < max_age do
      rates
    else
      with {:ok, document} <- fetch(),
           table when map_size(table) > 0 <- parse(document) do
        snapshot = JSON.encode_to_iodata!(%{"fetchedAtMs" => now, "document" => document})
        _ = File.mkdir_p(Path.dirname(path))
        _ = File.write(path, snapshot)
        %{table: table, fetched_at_ms: now, status: "fresh"}
      else
        # What we serve is now past its TTL and must not claim to be fresh.
        _ -> if map_size(rates.table) > 0, do: %{rates | status: "cached"}, else: rates
      end
    end
  end

  defp url, do: Application.get_env(:t3, :usage_rates_url, @litellm)

  defp fetch do
    case url() do
      "http" <> _ = url ->
        case :httpc.request(
               :get,
               {String.to_charlist(url), []},
               [timeout: 10_000, ssl: :httpc.ssl_verify_host_options(true)],
               body_format: :binary
             ) do
          {:ok, {{_, 200, _}, _, body}} -> JSON.decode(body)
          other -> {:error, other}
        end

      path ->
        with {:ok, text} <- File.read(path), do: JSON.decode(text)
    end
  rescue
    exception -> {:error, exception}
  end

  @doc """
  Projects a LiteLLM document into `%{normalized_name => rate}`. Entries without both
  an input and an output rate are dropped (half-pricing would under-report). A bare
  name (`gpt-5` for `openai/gpt-5`) is added when no entry has it and every qualified
  entry agrees on its rate.
  """
  def parse(%{} = document) do
    table =
      for {name, %{"input_cost_per_token" => input, "output_cost_per_token" => output} = entry} <-
            document,
          is_number(input) and is_number(output),
          key = normalize(name),
          key != "",
          into: %{} do
        {key,
         {input, output, number(entry["cache_read_input_token_cost"], input),
          number(entry["cache_creation_input_token_cost"], input)}}
      end

    aliases =
      Enum.reduce(table, %{}, fn {key, rate}, aliases ->
        alias = bare(key)

        cond do
          alias == "" or alias == key or Map.has_key?(table, alias) -> aliases
          Map.get(aliases, alias, rate) == rate -> Map.put(aliases, alias, rate)
          true -> Map.put(aliases, alias, :conflict)
        end
      end)

    for {alias, rate} <- aliases, rate != :conflict, into: table, do: {alias, rate}
  end

  def parse(_), do: %{}

  defp number(value, _default) when is_number(value), do: value
  defp number(_, default), do: default

  @doc "`usagePriceOverrides` from settings, keyed by exact model id."
  def overrides(settings) do
    for {model,
         %{"inputCostPerMillionTokens" => input, "outputCostPerMillionTokens" => output} =
           prices} <- settings["usagePriceOverrides"] || %{},
        is_number(input) and is_number(output),
        into: %{} do
      {String.trim(model),
       {input / 1_000_000, output / 1_000_000,
        number(prices["cacheReadCostPerMillionTokens"], input) / 1_000_000,
        number(prices["cacheWriteCostPerMillionTokens"], input) / 1_000_000}}
    end
  end

  @doc "The rate for `model`, if it is priceable."
  def lookup(table, model) do
    key = model |> normalize() |> String.split("[", parts: 2) |> hd()
    bare = bare(key)
    if bare != "" and not MapSet.member?(@unpriceable, bare), do: Map.get(table, key)
  end

  @doc """
  `{cost_usd, cost_source, cache_savings_usd}` for one record. A reported cost wins
  unless the model has a custom price; reasoning is inside output, so it is not
  charged again.
  """
  def price(table, overrides, model, {uncached, cached, creation, output, _}, reported) do
    override = Map.get(overrides, String.trim(model))
    rate = override || lookup(table, model)

    savings =
      case rate do
        {input, _, cache_read, _} -> cached * (input - cache_read)
        nil -> 0
      end

    cond do
      override == nil and is_number(reported) ->
        {reported, "providerReported", savings}

      rate == nil ->
        {0, "unpriced", savings}

      true ->
        {input, out, cache_read, cache_creation} = rate

        {uncached * input + cached * cache_read + creation * cache_creation + output * out,
         "modelPriced", savings}
    end
  end

  defp normalize(model), do: model |> String.trim() |> String.downcase()

  defp bare(key), do: key |> String.split("/") |> List.last()

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
