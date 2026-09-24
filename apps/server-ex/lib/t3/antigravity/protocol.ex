defmodule T3.Antigravity.Protocol do
  @moduledoc """
  Pure rules for talking to Google's Antigravity ACP agent, as the Node server's
  Antigravity adapter applies them: permission modes, which model a turn runs on,
  the model list, approval choices and native questions, bounding its tool
  payloads, and reading the Google sign-in URL it prints.
  """

  @default_alias "antigravity-default"
  # The model manifest's Antigravity entry: its current models and chat default.
  @current_models ~w(gemini-3.8-flash-high gemini-3.8-flash-medium gemini-3.8-flash-low)
  @default_model "gemini-3.8-flash-high"

  @tool_text_limit 8_000
  @truncated "[Earlier output truncated]\n\n"
  @question_label_limit 512
  @warning_limit 512
  @auth_prefix "Open the following link to authenticate the ACP server: "
  @max_url 16_384

  @doc "The provider-default model alias, which never reaches the agent."
  def default_alias, do: @default_alias

  @doc "The model the default alias selects when the account offers it."
  def default_model, do: @default_model

  @doc "The agent's permission mode for a thread's runtime mode."
  def permission_mode("full-access"), do: "yolo"
  def permission_mode("auto-accept-edits"), do: "auto_edit"
  def permission_mode(_approval_or_auto), do: "default"

  # --- models ----------------------------------------------------------------------

  @doc "The values of the session's `model` select option, groups flattened."
  def model_options(config_options) do
    case Enum.find(config_options || [], &(&1["id"] == "model")) do
      %{"options" => options} when is_list(options) ->
        Enum.flat_map(options, fn
          %{"value" => _} = entry -> [entry]
          %{"options" => group} when is_list(group) -> group
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp current_model(config_options) do
    case Enum.find(config_options || [], &(&1["id"] == "model")) do
      %{"currentValue" => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  @doc """
  What a turn does about the model: `:keep` the agent's, `{:set, slug}`, or
  `{:error, message}`. A chosen model is always reapplied (a cold resume may report
  the default). The default alias selects `default` when the account offers it,
  and otherwise leaves the agent's current model.
  """
  def resolve_model(config_options, requested, default \\ @default_model) do
    current = current_model(config_options)
    values = for %{"value" => value} <- model_options(config_options), do: value
    explicit = is_binary(requested) and requested != "" and requested != @default_alias

    resolved =
      cond do
        explicit -> requested
        is_binary(default) and default in values -> default
        true -> current
      end

    cond do
      resolved == nil or (not explicit and resolved == current) ->
        :keep

      resolved not in values ->
        {:error,
         "Antigravity model '#{resolved}' is unavailable for this Google account. Select an available model."}

      true ->
        {:set, resolved}
    end
  end

  @doc """
  `ServerProviderModel`s from a session's setup result (its `model` option, or the
  older `models` field), native ids kept; the current one is the default.
  """
  def models(setup) do
    option =
      Enum.find(setup["configOptions"] || [], &(&1["id"] == "model" or &1["category"] == "model"))

    {entries, current} =
      cond do
        is_map(option) and is_list(option["options"]) ->
          {model_options([Map.put(option, "id", "model")]), option["currentValue"]}

        option == nil and is_map(setup["models"]) ->
          {for(
             %{"modelId" => id} = m <- setup["models"]["availableModels"] || [],
             do: %{"value" => id, "name" => m["name"] || id}
           ), setup["models"]["currentModelId"]}

        true ->
          {[], nil}
      end

    entries
    |> Enum.filter(&(is_binary(&1["value"]) and String.trim(&1["value"]) != ""))
    |> Enum.uniq_by(& &1["value"])
    |> Enum.map(fn %{"value" => slug} = entry ->
      name =
        if is_binary(entry["name"]) and String.trim(entry["name"]) != "",
          do: entry["name"],
          else: slug

      %{
        "slug" => slug,
        "name" => name,
        "isCustom" => false,
        "capabilities" => %{"optionDescriptors" => []}
      }
      |> then(
        &if(slug == current,
          do: Map.merge(&1, %{"isDefault" => true, "aliases" => [@default_alias]}),
          else: &1
        )
      )
    end)
  end

  @doc """
  Marks models the manifest does not name as current `isLegacy`, and moves the
  default (with its aliases) to the manifest's default when the account has it.
  """
  def classify(models) do
    models =
      Enum.map(models, fn model ->
        cond do
          model["isCustom"] -> model
          model["slug"] in @current_models -> Map.delete(model, "isLegacy")
          true -> Map.put(model, "isLegacy", true)
        end
      end)

    previous = Enum.find(models, &(&1["isDefault"] && &1["slug"] != @default_model))

    if previous && Enum.any?(models, &(&1["slug"] == @default_model)) do
      previous_slug = previous["slug"]

      Enum.map(models, fn
        %{"slug" => ^previous_slug} = model ->
          Map.drop(model, ["isDefault", "aliases"])

        %{"slug" => @default_model} = model ->
          aliases = Enum.uniq((model["aliases"] || []) ++ (previous["aliases"] || []))
          model = Map.put(model, "isDefault", true)
          if aliases == [], do: model, else: Map.put(model, "aliases", aliases)

        model ->
          model
      end)
    else
      models
    end
  end

  @doc "`ServerProviderSlashCommand`s from the agent's `available_commands_update`."
  def slash_commands(commands) do
    commands
    |> Enum.filter(&(is_binary(&1["name"]) and String.trim(&1["name"]) != ""))
    |> Enum.uniq_by(& &1["name"])
    |> Enum.map(fn command ->
      description = String.trim(command["description"] || "")
      hint = String.trim(get_in(command, ["input", "hint"]) || "")

      %{"name" => command["name"]}
      |> then(&if(description != "", do: Map.put(&1, "description", description), else: &1))
      |> then(&if(hint != "", do: Map.put(&1, "input", %{"hint" => hint}), else: &1))
    end)
  end

  # --- permissions and questions ---------------------------------------------------

  @doc "Native questions share `session/request_permission`; their ids say so."
  def question?(params), do: String.starts_with?(tool_call_id(params), "interaction_")

  defp tool_call_id(params), do: get_in(params, ["toolCall", "toolCallId"]) || ""

  @doc "The option id a decision picks, or `nil` to cancel."
  def option_for(params, decision) do
    kind =
      case decision do
        "accept" -> "allow_once"
        "decline" -> "reject_once"
        "cancel" -> nil
        _ -> "allow_always"
      end

    with false <- question?(params),
         kind when kind != nil <- kind,
         %{"optionId" => id} <- Enum.find(params["options"] || [], &(&1["kind"] == kind)),
         true <- String.trim(id) != "" do
      id
    else
      _ -> nil
    end
  end

  @doc """
  The `ProviderApprovalOption`s the request can honour; "Allow for this thread"
  carries the agent's prompt-injection warning when it gives one.
  """
  def approval_options(params) do
    options = params["options"] || []

    find = fn kind ->
      Enum.find(options, &(&1["kind"] == kind and String.trim(&1["optionId"] || "") != ""))
    end

    if question?(params) do
      []
    else
      [
        find.("allow_once") && %{"decision" => "accept", "label" => "Allow once"},
        case find.("allow_always") do
          nil ->
            nil

          always ->
            %{"decision" => "acceptForSession", "label" => "Allow for this thread"}
            |> then(fn option ->
              case warning(always) do
                nil -> option
                text -> Map.put(option, "warning", text)
              end
            end)
        end,
        find.("reject_once") && %{"decision" => "decline", "label" => "Deny"},
        %{"decision" => "cancel", "label" => "Cancel"}
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp warning(option) do
    case get_in(option, ["_meta", "agy.security.warning"]) do
      %{} = warning ->
        text =
          String.trim(to_string(warning["message"] || ""))
          |> then(&if(&1 == "", do: String.trim(to_string(warning["title"] || "")), else: &1))

        cond do
          text == "" ->
            nil

          String.length(text) > @warning_limit ->
            String.slice(text, 0, @warning_limit - 3) <> "..."

          true ->
            text
        end

      _ ->
        nil
    end
  end

  @doc "A native question as an `OrchestrationV2UserInputQuestion`, or `nil`."
  def question(params) do
    options = params["options"] || []
    ids = Enum.map(options, & &1["optionId"])

    if question?(params) and options != [] and
         Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) and
         length(Enum.uniq(ids)) == length(ids) do
      text = String.trim(get_in(params, ["toolCall", "title"]) || "")
      text = if text == "", do: "Choose an option.", else: bound_label(text, @tool_text_limit)

      %{
        "id" => tool_call_id(params),
        "header" => "Question",
        "question" => text,
        "options" =>
          for(
            option <- options,
            label = label(option),
            do: %{"label" => label, "description" => label}
          ),
        "multiSelect" => false
      }
    end
  end

  defp label(option) do
    name = String.trim(option["name"] || "")
    bound_label(if(name == "", do: option["optionId"], else: name), @question_label_limit)
  end

  defp bound_label(text, limit),
    do: if(String.length(text) > limit, do: String.slice(text, 0, limit - 3) <> "...", else: text)

  @doc """
  The agent's answer to a native question from the user's `answers` (keyed by
  question id; an option id or its label), or `nil` when it matches no one option.
  """
  def question_response(params, answers) do
    with %{} <- question(params),
         value when is_binary(value) <- single(answers[tool_call_id(params)]) do
      options = params["options"]

      case Enum.find(options, &(&1["optionId"] == value)) do
        %{"optionId" => id} ->
          %{"outcome" => %{"outcome" => "selected", "optionId" => id}}

        nil ->
          case Enum.filter(options, &(label(&1) == value)) do
            [%{"optionId" => id}] -> %{"outcome" => %{"outcome" => "selected", "optionId" => id}}
            _ -> nil
          end
      end
    else
      _ -> nil
    end
  end

  defp single([value]) when is_binary(value), do: value
  defp single(value) when is_binary(value), do: value
  defp single(_), do: nil

  # --- tool payloads ---------------------------------------------------------------

  @doc """
  Bounds a tool update before it is kept (long text keeps its tail, inline images
  go), and maps the agent's native command fields (`CommandLine`,
  `combinedOutput`, …) onto the `command` and `output` the runtime reads.
  Other updates pass through.
  """
  def normalize_update(%{"sessionUpdate" => kind} = update)
      when kind in ["tool_call", "tool_call_update"] do
    budget = %{nodes: 512, text: 64_000}
    {input, budget} = sanitize(update["rawInput"], budget, 0)
    {output, budget} = sanitize(update["rawOutput"], budget, 0)
    {meta, _} = sanitize(update["_meta"], budget, 0)

    content =
      case update["content"] do
        list when is_list(list) -> list |> sanitize(%{nodes: 512, text: 32_000}, 0) |> elem(0)
        other -> other
      end

    command =
      first_string([input, output], ~w(CommandLine command_line commandLine command))

    combined = first_string([output], ~w(combinedOutput combined_output))

    input =
      if command != nil and (is_map(input) or input == nil),
        do: Map.put(input || %{}, "command", bound(String.trim(command))),
        else: input

    output =
      if combined != nil and is_map(output),
        do: Map.put(output, "output", bound(combined)),
        else: output

    update
    |> put_present("rawInput", input)
    |> put_present("rawOutput", output)
    |> put_present("content", content)
    |> put_present("_meta", meta)
    |> then(&if(is_binary(&1["title"]), do: Map.put(&1, "title", bound(&1["title"])), else: &1))
    |> then(
      &if(&1["kind"] == nil and command != nil, do: Map.put(&1, "kind", "execute"), else: &1)
    )
  end

  def normalize_update(update), do: update

  defp put_present(map, key, value),
    do: if(Map.has_key?(map, key), do: Map.put(map, key, value), else: map)

  defp first_string(maps, keys) do
    Enum.find_value(maps, fn
      %{} = map ->
        Enum.find_value(keys, fn key ->
          case map[key] do
            value when is_binary(value) -> if String.trim(value) != "", do: value
            _ -> nil
          end
        end)

      _ ->
        nil
    end)
  end

  defp bound(text) when byte_size(text) <= @tool_text_limit, do: text

  defp bound(text) do
    if String.length(text) <= @tool_text_limit,
      do: text,
      else: @truncated <> String.slice(text, -@tool_text_limit, @tool_text_limit)
  end

  # Nodes and text are budgeted across the whole payload; images never stay.
  defp sanitize(_value, %{nodes: nodes} = budget, depth) when depth > 12 or nodes <= 0,
    do: {nil, %{budget | nodes: nodes - 1}}

  defp sanitize(value, budget, _depth) when is_binary(value) do
    budget = %{budget | nodes: budget.nodes - 1}

    cond do
      Regex.match?(~r/^data:image\//i, value) or budget.text <= 0 ->
        {nil, budget}

      true ->
        limit = min(@tool_text_limit, budget.text)

        text =
          if String.length(value) <= limit,
            do: value,
            else: @truncated <> String.slice(value, -limit, limit)

        {text, %{budget | text: budget.text - String.length(text)}}
    end
  end

  defp sanitize(list, budget, depth) when is_list(list) do
    {items, budget} =
      Enum.reduce(list, {[], %{budget | nodes: budget.nodes - 1}}, fn item, {acc, budget} ->
        if budget.nodes <= 0 do
          {acc, budget}
        else
          case sanitize(item, budget, depth + 1) do
            {nil, budget} -> {acc, budget}
            {value, budget} -> {[value | acc], budget}
          end
        end
      end)

    {Enum.reverse(items), budget}
  end

  defp sanitize(%{} = map, budget, depth) do
    image? = map["type"] == "image"
    image_mime? = is_binary(map["mimeType"]) and String.starts_with?(map["mimeType"], "image/")
    combined = [map["combinedOutput"], map["combined_output"]]

    Enum.reduce(map, {%{}, %{budget | nodes: budget.nodes - 1}}, fn {key, value}, {acc, budget} ->
      skip =
        budget.nodes <= 0 or (image? and key in ["data", "blob"]) or
          (key == "blob" and image_mime?) or
          (key in ["formatted_output", "formattedOutput"] and value != nil and value in combined)

      if skip do
        {acc, budget}
      else
        case sanitize(value, budget, depth + 1) do
          {nil, budget} when not is_nil(value) -> {acc, budget}
          {sanitized, budget} -> {Map.put(acc, key, sanitized), budget}
        end
      end
    end)
  end

  defp sanitize(value, budget, _depth), do: {value, %{budget | nodes: budget.nodes - 1}}

  # --- sign-in URLs ----------------------------------------------------------------

  @doc "The prefix before the sign-in URL the agent prints on stdout (and stderr)."
  def auth_prefix, do: @auth_prefix

  @doc """
  The Google sign-in URL in a line the agent wrote: `{:ok, url}`, `:none` for any
  other line, or `{:error, message}` for a sign-in line with a URL that is not
  Google's authorization request to a loopback redirect. `marker` is the browser
  helper's (`T3.Antigravity.Profile.auth_marker/0`), which only stderr carries.
  """
  def auth_line(line, marker \\ nil) do
    line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

    url =
      cond do
        String.starts_with?(line, @auth_prefix) ->
          String.replace_prefix(line, @auth_prefix, "")

        is_binary(marker) and String.starts_with?(line, marker) ->
          String.replace_prefix(line, marker, "")

        true ->
          nil
      end

    case url && parse_authorization_url(url) do
      nil -> :none
      {:ok, request} -> {:ok, request}
      :error -> {:error, "Antigravity returned an invalid Google sign-in URL."}
    end
  end

  @doc """
  Checks a Google authorization URL: `{:ok, %{url, redirect_uri, state}}` with its
  loopback redirect on an unprivileged port, or `:error`.
  """
  def parse_authorization_url(url) when is_binary(url) and byte_size(url) <= @max_url do
    with false <- Regex.match?(~r/\s/, url),
         %URI{
           scheme: "https",
           host: "accounts.google.com",
           port: 443,
           path: "/o/oauth2/v2/auth",
           userinfo: nil,
           fragment: nil,
           query: query
         }
         when is_binary(query) <- URI.parse(url),
         params = Enum.to_list(URI.query_decoder(query)),
         [state] <- values(params, "state"),
         [redirect] <- values(params, "redirect_uri"),
         ["code"] <- values(params, "response_type"),
         true <- state != "" and String.length(state) <= 512 and not Regex.match?(~r/\s/, state),
         [_, port] <- Regex.run(~r"^http://127\.0\.0\.1:([1-9][0-9]{0,4})/$", redirect),
         true <- String.to_integer(port) in 1024..65_535 do
      {:ok, %{url: url, redirect_uri: redirect, state: state}}
    else
      _ -> :error
    end
  end

  def parse_authorization_url(_url), do: :error

  defp values(params, key), do: for({^key, value} <- params, do: value)

  @doc """
  Checks the redirect URL a user pasted from Google's page against the pending
  sign-in: same loopback origin and path, its state, one code or error, Google as
  the issuer. `:ok` or `{:error, message}`.
  """
  def validate_callback(callback, %{redirect_uri: redirect, state: state})
      when is_binary(callback) do
    expected = URI.parse(redirect)

    with true <-
           byte_size(callback) <= @max_url || {:error, "The sign-in response URL is too long."},
         %URI{scheme: "http", host: "127.0.0.1"} = uri <- URI.parse(callback),
         true <-
           (uri.port == expected.port and uri.path == expected.path and uri.userinfo == nil and
              uri.fragment == nil) || mismatch(),
         params = Enum.to_list(URI.query_decoder(uri.query || "")),
         true <- values(params, "state") == [state] || mismatch(),
         true <-
           one_response?(values(params, "code"), values(params, "error")) ||
             {:error, "The redirect URL must contain one Google sign-in response."},
         true <-
           values(params, "iss") in [[], ["https://accounts.google.com"]] ||
             {:error, "The redirect URL is not a Google sign-in response."} do
      :ok
    else
      {:error, _} = error -> error
      %URI{scheme: scheme} when scheme != nil -> mismatch()
      _ -> {:error, "Paste the complete redirect URL from the Google sign-in page."}
    end
  end

  defp one_response?([code], []) when code != "", do: true
  defp one_response?([], [error]) when error != "", do: true
  defp one_response?(_, _), do: false

  defp mismatch, do: {:error, "This redirect URL does not belong to the current sign-in."}
end
