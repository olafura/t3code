defmodule T3.TextGeneration do
  @moduledoc """
  Short structured text from a coding agent's CLI: commit messages and pull request
  titles and bodies for `T3.GitActions`, with the prompts the Node server uses.

  Runs the agent chosen in the node's `textGenerationModelSelection` setting when
  there is one; otherwise `claude -p` (Haiku) with a JSON schema and no tools, or
  `codex exec` in a read-only sandbox when Claude Code is not installed.
  """

  @timeout 180_000

  @doc "A commit message for the staged changes: `%{\"subject\", \"body\"}` (and `\"branch\"`)."
  def commit_message(cwd, branch, staged_summary, staged_patch, include_branch \\ false) do
    prompt =
      Enum.join(
        [
          "You write concise git commit messages.",
          if(include_branch,
            do: "Return a JSON object with keys: subject, body, branch.",
            else: "Return a JSON object with keys: subject, body."
          ),
          "Rules:",
          "- subject must be imperative, <= 72 chars, and no trailing period",
          "- body can be empty string or short bullet points"
        ] ++
          if(include_branch,
            do: ["- branch must be a short semantic git branch fragment for this change"],
            else: []
          ) ++
          [
            "- capture the primary user-visible or developer-visible change",
            "",
            "Branch: #{branch || "(detached)"}",
            "",
            "Staged files:",
            limit(staged_summary, 6_000),
            "",
            "Staged patch:",
            limit(staged_patch, 40_000)
          ],
        "\n"
      )

    keys = if include_branch, do: ~w(subject body branch), else: ~w(subject body)
    generate(cwd, prompt, keys)
  end

  @doc "A pull request's `%{\"title\", \"body\"}` for a branch's commits and diff."
  def pr_content(cwd, base, head, commits, diff_stat, diff_patch) do
    prompt =
      Enum.join(
        [
          "You write source control change request content.",
          "Return a JSON object with keys: title, body.",
          "Rules:",
          "- title should be concise and specific",
          "- body must be markdown and include headings '## Summary' and '## Testing'",
          "- under Summary, provide short bullet points",
          "- under Testing, include bullet points with concrete checks or 'Not run' where appropriate",
          "",
          "Base branch: #{base}",
          "Head branch: #{head}",
          "",
          "Commits:",
          limit(commits, 12_000),
          "",
          "Diff stat:",
          limit(diff_stat, 12_000),
          "",
          "Diff patch:",
          limit(diff_patch, 40_000)
        ],
        "\n"
      )

    generate(cwd, prompt, ~w(title body))
  end

  @doc "A short branch name for the work a message asks for: `%{\"branch\"}`."
  def branch_name(cwd, message) do
    prompt =
      Enum.join(
        [
          "You generate concise git branch names.",
          "Return a JSON object with key: branch.",
          "Rules:",
          "- Branch should describe the requested work from the user message.",
          "- Keep it short and specific (2-6 words).",
          "- Use plain words only, no issue prefixes and no punctuation-heavy text.",
          "",
          "User message:",
          limit(message, 8_000)
        ],
        "\n"
      )

    generate(cwd, prompt, ~w(branch))
  end

  @doc "A title for a new thread from its first message: `%{\"title\"}`."
  def thread_title(cwd, message) do
    prompt =
      Enum.join(
        [
          "Generate a title that will help the user recognize this T3 Code thread weeks later.",
          "Return JSON with key title.",
          "Title the subject and the outcome the user wants, not how the agent should work.",
          "Editorial rules:",
          "- 3-8 words, fewer than 40 characters.",
          "- Use a compact noun phrase or clear action phrase.",
          "- Name the product change, not the mock, plan, report, branch, or PR used to produce it.",
          "- Do not claim the work is complete, and do not copy and truncate the user's message.",
          "- Avoid quotes, labels, filler, and trailing punctuation.",
          "",
          "User message:",
          limit(message, 8_000)
        ],
        "\n"
      )

    generate(cwd, prompt, ~w(title))
  end

  defp limit(text, max) do
    text = String.trim(text || "")
    if String.length(text) > max, do: String.slice(text, 0, max) <> "\n[truncated]", else: text
  end

  defp generate(cwd, prompt, keys) do
    schema = %{
      "type" => "object",
      "properties" => Map.new(keys, &{&1, %{"type" => "string"}}),
      "required" => keys,
      "additionalProperties" => false
    }

    selection =
      T3.Settings.for_project(T3.Projects.at(cwd))["textGenerationModelSelection"] || %{}

    model = selection["model"]

    cond do
      selection["instanceId"] == "codex" and System.find_executable(codex_command()) ->
        codex(cwd, prompt, schema, model, option(selection, "reasoningEffort") || "low")

      selection["instanceId"] == "claudeAgent" and System.find_executable(claude_command()) ->
        claude(cwd, prompt, schema, model || "haiku", option(selection, "effort"))

      System.find_executable(claude_command()) ->
        claude(cwd, prompt, schema, "haiku", nil)

      System.find_executable(codex_command()) ->
        codex(cwd, prompt, schema, nil, "low")

      true ->
        {:error, "Install Claude Code or Codex to generate this text."}
    end
  end

  defp option(selection, id) do
    Enum.find_value(selection["options"] || [], fn
      %{"id" => ^id, "value" => value} when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp claude(cwd, prompt, schema, model, effort) do
    args =
      ~w(-p --output-format json --json-schema) ++
        [JSON.encode!(schema), "--model", model] ++
        if(effort, do: ["--effort", effort], else: []) ++
        ["--settings", ~s({"disableAllHooks":true}), "--tools", ""] ++
        ["--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk"]

    with {:ok, out} <- run([claude_command() | args], cwd, prompt),
         {:ok, decoded} <- JSON.decode(out),
         %{} = result <- structured(decoded) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, "Claude returned no structured output."}
    end
  end

  # `--output-format json` is one result object, or a list of messages ending in one.
  defp structured(%{"structured_output" => %{} = out}), do: out

  defp structured(list) when is_list(list),
    do: list |> Enum.reverse() |> Enum.find_value(&structured/1)

  defp structured(_), do: nil

  defp codex(cwd, prompt, schema, model, effort) do
    dir = Path.join(System.tmp_dir!(), "t3-text-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    schema_path = Path.join(dir, "schema.json")
    output_path = Path.join(dir, "output.json")
    File.write!(schema_path, JSON.encode!(schema))

    args =
      ~w(exec --ephemeral --skip-git-repo-check -s read-only) ++
        if(model, do: ["--model", model], else: []) ++
        ["--config", ~s(model_reasoning_effort="#{effort}")] ++
        ["--output-schema", schema_path, "--output-last-message", output_path, "-"]

    try do
      with {:ok, _} <- run([codex_command() | args], cwd, prompt),
           {:ok, text} <- File.read(output_path),
           {:ok, %{} = result} <- JSON.decode(text) do
        {:ok, result}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        _ -> {:error, "Codex returned no structured output."}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp run([command | args], cwd, input) do
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
end
