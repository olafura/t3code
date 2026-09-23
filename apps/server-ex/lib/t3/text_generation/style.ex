defmodule T3.TextGeneration.Style do
  @moduledoc """
  How generated commits and pull requests are written, from the project's
  `sourceControlWritingStyle` setting, as the Node server's `GitManager.ts`
  resolves it. `T3.GitActions` passes `policy/1` and `pr_template/2` to
  `T3.TextGeneration`.

  A policy is `%{kind:, commit:, change_request:}`, the instructions added to the
  commit and change request prompts: Conventional Commits, the user's own
  instructions, or the repository's conventions, read from its recent commit
  subjects, AGENTS.md, and, when Claude writes, CLAUDE.md.
  """

  alias T3.{Git, TextGeneration}

  @defaults %{
    "mode" => "repo_conventions",
    "customInstructions" => "",
    "followChangeRequestTemplates" => true
  }

  @doc "The writing style that applies to `cwd`'s project, with its defaults."
  def settings(cwd),
    do: Map.merge(@defaults, TextGeneration.settings(cwd)["sourceControlWritingStyle"] || %{})

  @doc "The policy for the writing style that applies to `cwd`."
  def policy(cwd) do
    style = settings(cwd)

    case style["mode"] do
      "conventional_commits" ->
        %{
          kind: "conventional_commits",
          commit:
            "Use Conventional Commits when generating commit subjects. Prefer the narrowest accurate type and include a scope only when it is obvious from the diff.",
          change_request:
            "Keep the change request title concise. Do not force Conventional Commit syntax into the title unless the repository already uses it."
        }

      "custom" ->
        case String.trim(style["customInstructions"] || "") do
          "" -> %{kind: "custom", commit: nil, change_request: nil}
          text -> %{kind: "custom", commit: text, change_request: text}
        end

      _ ->
        repo_conventions(cwd)
    end
  end

  defp repo_conventions(cwd) do
    commit =
      "Follow the repository's established commit message style when examples are available."

    change_request =
      "Follow the repository's established change request title and body style when examples are available."

    subjects =
      case Git.ok(cwd, ~w(log -n 20 --no-merges --pretty=format:%s)) do
        {:ok, out} ->
          out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end

    claude? = TextGeneration.driver(TextGeneration.model_selection(cwd, :writer)) == "claudeAgent"

    examples =
      [
        if(subjects != [],
          do: Enum.join(["Recent commit subjects from this repository:" | subjects], "\n")
        ),
        instructions(cwd, "AGENTS.md"),
        if(claude?, do: instructions(cwd, "CLAUDE.md"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if examples == "" do
      %{kind: "repo_conventions", commit: commit, change_request: change_request}
    else
      %{
        kind: "repo_conventions",
        commit: commit <> "\n\n" <> examples,
        change_request: change_request <> "\n\n" <> examples
      }
    end
  end

  # A regular file of at most 20 kB in the checkout itself; links are not followed.
  defp instructions(cwd, name) do
    path = Path.join(cwd, name)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 20_000 <- File.lstat(path),
         {:ok, text} <- File.read(path),
         text when text != "" <- String.trim(text) do
      "Local #{name}:\n#{text}"
    else
      _ -> nil
    end
  end

  @template_paths ~w(.github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md
                     pull_request_template.md PULL_REQUEST_TEMPLATE.md
                     docs/pull_request_template.md docs/PULL_REQUEST_TEMPLATE.md)
  @template_dirs ~w(.github/PULL_REQUEST_TEMPLATE PULL_REQUEST_TEMPLATE docs/PULL_REQUEST_TEMPLATE)

  @doc """
  The repository's pull request template in the base tree `ref` when the project
  follows templates: the first of GitHub's template paths, or the only template
  in a template folder. `nil` when there is none, or several to choose from.
  """
  def pr_template(cwd, ref) do
    if settings(cwd)["followChangeRequestTemplates"] != false, do: detect_template(cwd, ref)
  end

  # Read from the committed tree, so links and files changed in the checkout never count.
  defp detect_template(cwd, ref) do
    args = ["ls-tree", "-r", "-z", "--full-tree", ref, "--"] ++ @template_paths ++ @template_dirs

    with {:ok, %{status: 0, out: out, truncated: false}} <- Git.run(cwd, args, max_bytes: 100_000) do
      entries = tree_entries(out)
      by_path = Map.new(entries, &{&1.path, &1})

      Enum.find_value(@template_paths, &(by_path[&1] && blob(cwd, by_path[&1]))) ||
        Enum.reduce_while(@template_dirs, nil, fn dir, nil ->
          case dir_templates(cwd, entries, dir) do
            [] -> {:cont, nil}
            [template] -> {:halt, template}
            _ambiguous -> {:halt, nil}
          end
        end)
    else
      _ -> nil
    end
  end

  defp tree_entries(out) do
    for record <- String.split(out, "\0", trim: true),
        [meta, path] <- [String.split(record, "\t", parts: 2)],
        [mode, "blob", oid] <- [String.split(meta, " ")],
        mode in ["100644", "100755"] and Regex.match?(~r/^[0-9a-f]{40,64}$/, oid),
        do: %{oid: oid, path: path}
  end

  # Stops at the second template: a folder of several leaves the choice to the user.
  defp dir_templates(cwd, entries, dir) do
    entries
    |> Enum.filter(fn %{path: path} ->
      String.starts_with?(path, dir <> "/") and
        not String.contains?(String.replace_prefix(path, dir <> "/", ""), "/") and
        String.ends_with?(String.downcase(path), ".md")
    end)
    |> Enum.reduce_while([], fn entry, found ->
      case blob(cwd, entry) do
        nil -> {:cont, found}
        template when found == [] -> {:cont, [template]}
        template -> {:halt, [template | found]}
      end
    end)
  end

  defp blob(cwd, %{oid: oid}) do
    case Git.run(cwd, ["cat-file", "blob", oid], max_bytes: 8_000) do
      {:ok, %{status: 0, out: out, truncated: truncated}} ->
        case String.trim(out) do
          "" -> nil
          text -> if truncated, do: text <> "\n\n[truncated]", else: text
        end

      _ ->
        nil
    end
  end
end
