defmodule T3.TextGeneration do
  @moduledoc """
  Short structured text from a coding agent: commit messages and pull request
  content for `T3.GitActions`, branch names for `T3.WorktreeSetup`, and thread
  titles for `T3.Orchestration`, with the Node server's prompts
  (`T3.TextGeneration.Prompts`).

  Commits, pull requests, and branch names are written by the project's source
  control writer model when its provider is usable, otherwise by its text
  generation model, which also writes titles (`model_selection/2`). A selection
  whose provider is disabled, not installed, or has no runner here falls back to
  the first usable provider, with that provider's default model, as Node does.

  Claude runs `claude -p` with a JSON schema and no tools; Codex runs `codex exec`
  in a read-only sandbox; Grok, OpenCode, and Cursor answer one ACP prompt in an
  empty directory, with every tool and permission request refused; Antigravity
  does the same with its own rules (`T3.Antigravity.TextGeneration`), once a
  session has shown it signed in.
  """

  alias T3.JsonRpc.Connection
  alias T3.TextGeneration.Prompts

  @timeout 180_000

  # Node's text generation defaults: the selection, and each provider's model.
  @default_selection %{
    "instanceId" => "codex",
    "model" => "gpt-6-luna",
    "options" => [%{"id" => "reasoningEffort", "value" => "low"}]
  }
  @default_models %{
    "codex" => "gpt-6-luna",
    "claudeAgent" => "claude-haiku-4-5",
    "cursor" => "composer-2",
    "grok" => "grok-build",
    "opencode" => "openai/gpt-5",
    "antigravity" => "antigravity-default"
  }
  # The order Node falls back through when the selected provider cannot be used.
  @fallback_order ~w(codex claudeAgent cursor grok pi opencode antigravity)
  @acp_drivers ~w(grok opencode cursor)

  @doc """
  A commit message for the staged changes: `%{"subject", "body"}`, and a
  `feature/…` `"branch"` when asked for. Options: `:policy` (`T3.TextGeneration.Style`).
  """
  def commit_message(
        cwd,
        branch,
        staged_summary,
        staged_patch,
        include_branch \\ false,
        opts \\ []
      ) do
    prompt =
      Prompts.commit(branch, staged_summary, staged_patch, include_branch, opts[:policy] || %{})

    keys = if include_branch, do: ~w(subject body branch), else: ~w(subject body)

    with {:ok, out} <- generate(cwd, :writer, prompt, Map.new(keys, &{&1, :string})) do
      result = %{"subject" => commit_subject(out["subject"]), "body" => String.trim(out["body"])}

      {:ok,
       if(include_branch,
         do: Map.put(result, "branch", "feature/" <> feature_fragment(out["branch"])),
         else: result
       )}
    end
  end

  @doc """
  A pull request's `%{"title", "body"}` for a branch's commits and diff. Options:
  `:policy` and `:template`, the repository's pull request template.
  """
  def pr_content(cwd, base, head, commits, diff_stat, diff_patch, opts \\ []) do
    prompt =
      Prompts.pr(
        base,
        head,
        commits,
        diff_stat,
        diff_patch,
        opts[:template],
        opts[:policy] || %{}
      )

    with {:ok, out} <- generate(cwd, :writer, prompt, %{"title" => :string, "body" => :string}) do
      title =
        case out["title"] |> String.trim() |> String.split(~r/\r?\n/) |> hd() |> String.trim() do
          "" -> "Update project changes"
          title -> title
        end

      {:ok, %{"title" => title, "body" => String.trim(out["body"])}}
    end
  end

  @doc "A short branch name fragment for the work a message asks for: `%{\"branch\"}`."
  def branch_name(cwd, message, attachments \\ []) do
    prompt = Prompts.branch(message, attachments)

    with {:ok, out} <-
           generate(cwd, :writer, prompt, %{"branch" => :string}, images: images(attachments)),
         do: {:ok, %{"branch" => branch_fragment(out["branch"])}}
  end

  @doc """
  A thread title: `%{"title", "needsRefinement"}`. From the first message, or,
  with `:previous_title`, from the thread's contents (`Prompts.thread_context/1`).
  Options: `:previous_title`, `:attachments`. GitHub pull requests and issues
  linked in the message are looked up for the model.
  """
  def thread_title(cwd, message, opts \\ []) do
    attachments = opts[:attachments] || []
    schema = %{"title" => :string, "needsRefinement" => :boolean}

    with {:ok, selection} <- usable_selection(cwd, :text),
         linked = linked_context(cwd, message),
         prompt = Prompts.thread_title(message, opts[:previous_title], linked, attachments),
         # Titles need only the prompt, not the checkout's configuration.
         {:ok, out} <-
           run(selection, cwd, prompt, schema, isolate: true, images: images(attachments)) do
      {:ok,
       %{"title" => title(out["title"]), "needsRefinement" => out["needsRefinement"] == true}}
    end
  end

  # --- model selection ---------------------------------------------------------------

  @doc "The settings that apply to `cwd`: its project's, when it is in one."
  def settings(cwd), do: T3.Settings.for_project(T3.Projects.at(cwd))

  @doc """
  The model that writes for `cwd`: `:writer` for commits, pull requests, and
  branch names (the source control writer when its provider is usable), `:text`
  for titles. Falls back as the moduledoc says.
  """
  def model_selection(cwd, kind) do
    settings = settings(cwd)
    text = settings["textGenerationModelSelection"] || @default_selection
    writer = settings["sourceControlWriterModelSelection"]

    cond do
      kind == :writer and is_map(writer) and usable?(settings, writer) -> writer
      usable?(settings, text) -> text
      true -> fallback(settings) || text
    end
  end

  defp fallback(settings) do
    Enum.find_value(@fallback_order, fn driver ->
      selection = %{"instanceId" => driver, "model" => @default_models[driver]}
      if usable?(settings, selection), do: selection
    end)
  end

  @doc "The provider driver of a model selection or an instance id."
  def driver(%{"instanceId" => id}), do: driver(id)

  def driver(id),
    do: get_in(T3.Settings.settings(), ["providerInstances", id, "driver"]) || id

  defp usable?(settings, %{"instanceId" => id}) when is_binary(id) do
    case driver(id) do
      "codex" ->
        enabled?(settings, id) and executable?(codex_command())

      "claudeAgent" ->
        enabled?(settings, id) and executable?(claude_command())

      driver when driver in @acp_drivers ->
        T3.Acp.enabled?(id) and acp_installed?(id)

      "antigravity" ->
        match?(%{"enabled" => true, "supportsTextGeneration" => true}, T3.Acp.entry(id))

      _ ->
        false
    end
  end

  defp usable?(_settings, _selection), do: false

  # Codex and Claude are on unless turned off.
  defp enabled?(settings, id) do
    case get_in(settings, ["providerInstances", id]) do
      %{} = instance -> instance["enabled"] != false
      _ -> get_in(settings, ["providers", id, "enabled"]) != false
    end
  end

  defp acp_installed?(id) do
    case T3.Acp.command(id) do
      {:ok, [executable | _], _env} -> executable?(executable)
      _ -> false
    end
  end

  defp executable?(command), do: System.find_executable(command) != nil

  defp usable_selection(cwd, kind) do
    selection = model_selection(cwd, kind)

    if usable?(settings(cwd), selection),
      do: {:ok, selection},
      else:
        {:error,
         "No text generation provider is available. Install Claude Code or Codex, or enable another provider."}
  end

  # --- running ----------------------------------------------------------------------

  defp generate(cwd, kind, prompt, schema, opts \\ []) do
    with {:ok, selection} <- usable_selection(cwd, kind),
         do: run(selection, cwd, prompt, schema, opts)
  end

  defp run(selection, cwd, prompt, schema, opts) do
    json_schema = %{
      "type" => "object",
      "properties" => Map.new(schema, fn {key, type} -> {key, %{"type" => to_string(type)}} end),
      "required" => Map.keys(schema),
      "additionalProperties" => false
    }

    {label, result} =
      case driver(selection) do
        "claudeAgent" ->
          {"Claude", claude(cwd, prompt, json_schema, selection, opts[:isolate])}

        "codex" ->
          {"Codex", codex(cwd, prompt, json_schema, selection, opts[:images] || [])}

        _ ->
          label = T3.Acp.label(selection["instanceId"])
          {label, acp(selection, prompt, label)}
      end

    with {:ok, out} <- result do
      if valid?(out, schema),
        do: {:ok, out},
        else: {:error, "#{label} returned invalid structured output."}
    end
  end

  defp valid?(%{} = out, schema) do
    Enum.all?(schema, fn
      {key, :string} -> is_binary(out[key])
      {key, :boolean} -> out[key] in [true, false, nil]
    end)
  end

  defp valid?(_out, _schema), do: false

  defp option(selection, id) do
    Enum.find_value(selection["options"] || [], fn
      %{"id" => ^id, "value" => value} -> value
      _ -> nil
    end)
  end

  defp claude(cwd, prompt, schema, selection, isolate) do
    thinking = option(selection, "thinking")

    settings =
      %{"disableAllHooks" => true}
      |> then(
        &if(is_boolean(thinking), do: Map.put(&1, "alwaysThinkingEnabled", thinking), else: &1)
      )
      |> then(
        &if(option(selection, "fastMode") == true, do: Map.put(&1, "fastMode", true), else: &1)
      )

    effort = option(selection, "effort")

    args =
      ~w(-p --output-format json --json-schema) ++
        [JSON.encode!(schema), "--model", selection["model"] || @default_models["claudeAgent"]] ++
        if(is_binary(effort), do: ["--effort", effort], else: []) ++
        ["--settings", JSON.encode!(settings), "--tools", ""] ++
        ["--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk"]

    in_dir(if(isolate, do: nil, else: cwd), fn dir ->
      with {:ok, out} <- run_cli([claude_command() | args], dir, prompt),
           {:ok, decoded} <- JSON.decode(out),
           %{} = result <- structured(decoded) do
        {:ok, result}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        _ -> {:error, "Claude returned invalid structured output."}
      end
    end)
  end

  # `--output-format json` is one result object, or a list of messages ending in one.
  defp structured(%{"structured_output" => %{} = out}), do: out

  defp structured(list) when is_list(list),
    do: list |> Enum.reverse() |> Enum.find_value(&structured/1)

  defp structured(_), do: nil

  defp codex(cwd, prompt, schema, selection, images) do
    effort = option(selection, "reasoningEffort") || "low"

    tier =
      option(selection, "serviceTier") || if(option(selection, "fastMode") == true, do: "fast")

    in_dir(nil, fn dir ->
      schema_path = Path.join(dir, "schema.json")
      output_path = Path.join(dir, "output.json")
      File.write!(schema_path, JSON.encode!(schema))

      args =
        ~w(exec --ephemeral --skip-git-repo-check -s read-only) ++
          ["--model", selection["model"] || @default_models["codex"]] ++
          ["--config", ~s(model_reasoning_effort="#{effort}")] ++
          if(is_binary(tier), do: ["--config", ~s(service_tier="#{tier}")], else: []) ++
          ["--output-schema", schema_path, "--output-last-message", output_path] ++
          Enum.flat_map(images, &["--image", &1]) ++ ["-"]

      with {:ok, _} <- run_cli([codex_command() | args], cwd, prompt),
           {:ok, text} <- File.read(output_path),
           {:ok, %{} = result} <- JSON.decode(text) do
        {:ok, result}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        _ -> {:error, "Codex returned invalid structured output."}
      end
    end)
  end

  # Runs `fun` in `dir`, or in a new temporary directory it removes afterwards.
  defp in_dir(dir, fun) when is_binary(dir), do: fun.(dir)

  defp in_dir(nil, fun) do
    dir = Path.join(System.tmp_dir!(), "t3-text-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  # The images a Codex prompt takes by path.
  defp images(attachments) do
    for %{"type" => "image", "id" => id} = attachment <- attachments,
        is_binary(id),
        path = T3.Attachments.path(attachment),
        is_binary(path) and File.regular?(path),
        do: path
  end

  # One ACP prompt in its own process, which outlives neither the agent nor the timeout.
  defp acp(selection, prompt, label) do
    id = selection["instanceId"]

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        try do
          in_dir(nil, fn dir ->
            cond do
              driver(id) == "antigravity" ->
                T3.Antigravity.TextGeneration.run(id, selection["model"], prompt)

              driver(id) == "cursor" and
                  File.exists?(Path.join(System.user_home!(), ".cursor/sandbox.json")) ->
                # Cursor's own sandbox settings could widen what the agent may write.
                {:error,
                 "Cursor text generation cannot enforce workspace isolation with a custom ~/.cursor/sandbox.json. Use another text-generation provider."}

              true ->
                T3.Acp.with_agent(id, dir, fn conn, _init ->
                  acp_prompt(conn, dir, selection["model"], prompt)
                end)
            end
          end)
        catch
          _kind, reason -> {:error, reason}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} ->
        case JSON.decode(json_object(text)) do
          {:ok, %{} = out} -> {:ok, out}
          _ -> {:error, "#{label} returned invalid structured output."}
        end

      {:ok, {:error, reason}} when is_binary(reason) ->
        {:error, reason}

      {:ok, {:error, %{"message" => message}}} ->
        {:error, "#{label} request failed: #{message}"}

      {:ok, {:error, reason}} ->
        {:error, "#{label} request failed: #{inspect(reason)}"}

      nil ->
        {:error, "#{label} request timed out."}
    end
  end

  defp acp_prompt(conn, dir, model, prompt) do
    with {:ok, %{"sessionId" => session_id} = session} <-
           Connection.call(conn, "session/new", %{"cwd" => dir, "mcpServers" => []}, 60_000),
         :ok <- acp_model(conn, session_id, session, model) do
      params = %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}
      task = Task.async(fn -> Connection.call(conn, "session/prompt", params, :infinity) end)
      acp_collect(conn, task.ref, [])
    end
  end

  # Picks the model when the agent offers it; an alias such as `grok-build` keeps the session's.
  defp acp_model(conn, session_id, session, model) do
    option = Enum.find(session["configOptions"] || [], &(&1["id"] == "model")) || %{}
    offered = for %{"value" => value} <- option["options"] || [], do: value

    if model in offered and model != option["currentValue"] do
      params = %{"sessionId" => session_id, "configId" => "model", "value" => model}

      case Connection.call(conn, "session/set_config_option", params) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp acp_collect(conn, ref, text) do
    receive do
      {:json_rpc, ^conn,
       {:notification, "session/update",
        %{
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => chunk}
          }
        }}} ->
        acp_collect(conn, ref, [text, chunk])

      {:json_rpc, ^conn, {:request, id, "session/request_permission", _params}} ->
        Connection.respond(conn, id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})
        acp_collect(conn, ref, text)

      {:json_rpc, ^conn, {:request, id, method, _params}} ->
        Connection.respond(
          conn,
          id,
          {:error, %{"code" => -32601, "message" => "#{method} is disabled for text generation"}}
        )

        acp_collect(conn, ref, text)

      {^ref, reply} ->
        Process.demonitor(ref, [:flush])

        case {reply, text |> IO.iodata_to_binary() |> String.trim()} do
          {{:ok, %{"stopReason" => "cancelled"}}, _} -> {:error, "The request was cancelled."}
          {{:ok, _}, ""} -> {:error, "The agent returned empty output."}
          {{:ok, _}, output} -> {:ok, output}
          {error, _} -> error
        end

      _other ->
        acp_collect(conn, ref, text)
    end
  end

  # The first balanced `{…}` in an agent's reply, which may wrap it in prose or a fence.
  defp json_object(text) do
    case :binary.match(text, "{") do
      :nomatch -> text
      {start, _} -> scan(text, start, start, 0, false, false)
    end
  end

  defp scan(text, start, index, depth, in_string, escaping) when index < byte_size(text) do
    char = :binary.at(text, index)
    next = index + 1

    cond do
      in_string and escaping -> scan(text, start, next, depth, true, false)
      in_string and char == ?\\ -> scan(text, start, next, depth, true, true)
      in_string -> scan(text, start, next, depth, char != ?", false)
      char == ?" -> scan(text, start, next, depth, true, false)
      char == ?{ -> scan(text, start, next, depth + 1, false, false)
      char == ?} and depth == 1 -> binary_part(text, start, next - start)
      char == ?} -> scan(text, start, next, depth - 1, false, false)
      true -> scan(text, start, next, depth, false, false)
    end
  end

  defp scan(text, start, _index, _depth, _in_string, _escaping),
    do: binary_part(text, start, byte_size(text) - start)

  defp run_cli([command | args], cwd, input) do
    task =
      Task.async(fn ->
        [command | args]
        |> Exile.stream(cd: cwd, input: [input], stderr: :consume, ignore_epipe: true)
        |> Enum.reduce({[], [], nil}, fn
          {:stdout, data}, {out, err, status} -> {[out, data], err, status}
          {:stderr, data}, {out, err, status} -> {out, [err, data], status}
          {:exit, status}, {out, err, _} -> {out, err, status}
        end)
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, _err, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:ok, {_out, err, status}} ->
        {:error, "#{Path.basename(command)} failed (#{inspect(status)}): #{failure(err)}"}

      nil ->
        {:error, "#{Path.basename(command)} timed out"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # CLIs print a banner first and the reason last; keep the error lines when there are any.
  defp failure(err) do
    lines = err |> IO.iodata_to_binary() |> String.split("\n", trim: true)
    errors = Enum.filter(lines, &String.starts_with?(&1, "ERROR"))

    if(errors == [], do: lines, else: Enum.uniq(errors))
    |> Enum.join("\n")
    |> String.slice(-500, 500)
  end

  defp claude_command, do: Application.get_env(:t3, :text_claude_command, "claude")
  defp codex_command, do: Application.get_env(:t3, :text_codex_command, "codex")

  # --- linked pull requests and issues -----------------------------------------------

  # What the first two GitHub pull request or issue links in a message are about:
  # each link with its title and body, or marked unavailable.
  defp linked_context(cwd, message) do
    links =
      Regex.scan(~r{https://[^\s<>"')\]`]+}, message)
      |> Enum.map(fn [url] -> URI.parse(String.replace(url, ~r/[.,;!?]+$/, "")) end)
      |> Enum.flat_map(fn uri ->
        with %URI{host: "github.com", userinfo: nil, path: path} when is_binary(path) <- uri,
             [_, owner, repo, number] <-
               Regex.run(~r{^/([\w.-]+)/([\w.-]+)/(?:pull|issues)/([1-9]\d*)(?:/.*)?$}, path) do
          [
            {URI.to_string(%{uri | query: nil, fragment: nil}),
             "repos/#{owner}/#{repo}/issues/#{number}"}
          ]
        else
          _ -> []
        end
      end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.take(2)

    subjects =
      links
      |> Task.async_stream(fn {url, endpoint} -> subject(cwd, url, endpoint) end,
        timeout: 3_000,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, subject} -> subject
        {:exit, {{url, _}, _}} -> "#{url}: unavailable"
      end)

    if subjects != [], do: Enum.join(subjects, "\n\n")
  end

  # Only github.com: ambient `gh` credentials never go to a host named in message text.
  defp subject(cwd, url, endpoint) do
    gh = System.find_executable(Application.get_env(:t3, :gh_command, "gh"))

    with true <- gh != nil,
         {out, 0} <-
           System.cmd(
             gh,
             ["api", "--hostname", "github.com", endpoint, "--jq", "{title, body}"],
             cd: cwd,
             env: [{"GH_PROMPT_DISABLED", "1"}],
             stderr_to_stdout: false
           ),
         {:ok, %{"title" => title} = subject} when is_binary(title) <- JSON.decode(out) do
      body = if is_binary(subject["body"]), do: subject["body"], else: ""

      "#{url}\n" <>
        ~s({"title":#{JSON.encode!(String.slice(title, 0, 300))},"body":#{JSON.encode!(String.slice(body, 0, 1_200))}})
    else
      _ -> "#{url}: unavailable"
    end
  rescue
    _ -> "#{url}: unavailable"
  end

  # --- output ----------------------------------------------------------------------

  defp commit_subject(raw) do
    subject =
      raw
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> hd()
      |> String.trim()
      |> String.replace(~r/\.+$/, "")
      |> String.trim()

    if subject == "",
      do: "Update project files",
      else: subject |> String.slice(0, 72) |> String.trim_trailing()
  end

  @doc "A git branch name fragment from free text (`update` when nothing is left)."
  def branch_fragment(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['"`]/, "")
    |> String.replace(~r{^[./\s_-]+|[./\s_-]+$}, "")
    |> String.replace(~r{[^a-z0-9/_-]+}, "-")
    |> String.replace(~r{/+}, "/")
    |> String.replace(~r/-+/, "-")
    |> String.replace(~r{^[./_-]+|[./_-]+$}, "")
    |> String.slice(0, 64)
    |> String.replace(~r{[./_-]+$}, "")
    |> then(&if(&1 == "", do: "update", else: &1))
  end

  # A fragment for `feature/…`, keeping a `feature/` prefix the model already gave.
  defp feature_fragment(raw),
    do: raw |> branch_fragment() |> String.replace_prefix("feature/", "")

  # Prompts ask for under 40 characters; 120 only stops a runaway model.
  defp title(raw) do
    title =
      case JSON.decode(raw) do
        {:ok, %{"title" => title}} when is_binary(title) -> title
        _ -> raw
      end

    normalized =
      title
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> hd()
      |> String.trim()
      |> String.replace(~r/^['"`]+|['"`]+$/, "")
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    cond do
      normalized == "" -> "New thread"
      String.length(normalized) <= 120 -> normalized
      true -> (normalized |> String.slice(0, 117) |> String.trim_trailing()) <> "..."
    end
  end
end
