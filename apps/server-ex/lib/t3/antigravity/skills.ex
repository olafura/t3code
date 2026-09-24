defmodule T3.Antigravity.Skills do
  @moduledoc """
  The skills Antigravity loads for a workspace, as `ServerProviderSkill`s, found
  the way the agent finds them: in order, `~/.gemini/config/skills`,
  `<cwd>/.gemini/skills`, `~/.gemini/antigravity-cli/skills`, `<cwd>/.agents/skills`
  and `<cwd>/.agent/skills`. Each root holds a `SKILL.md` or folders with one; the
  first skill of a name wins. The frontmatter's `name` (else the file name) and
  `description` describe it. Scans are bounded; one that runs out fails rather than
  report a partial list.
  """

  @max_skill_bytes 1_000_000
  @max_scan_bytes 8_000_000
  @max_entries 10_000

  @doc "`{:ok, skills}` sorted by name, or `{:error, message}`."
  def discover(cwd, user_home \\ System.user_home!()) do
    [config, cli] = T3.Antigravity.Profile.user_skill_dirs(Path.join(user_home, ".gemini"))

    roots = [
      {config, "user"},
      {Path.expand(".gemini/skills", cwd), "project"},
      {cli, "user"},
      {Path.expand(".agents/skills", cwd), "project"},
      {Path.expand(".agent/skills", cwd), "project"}
    ]

    budget = %{bytes: @max_scan_bytes, entries: @max_entries}

    roots
    |> Enum.reduce_while({:ok, %{}, budget}, fn {dir, scope}, {:ok, found, budget} ->
      case scan(dir, scope, true, found, budget) do
        {:ok, found, budget} -> {:cont, {:ok, found, budget}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, found, _} -> {:ok, found |> Map.values() |> Enum.sort_by(& &1["name"])}
      {:error, _} = error -> error
    end
  end

  defp scan(dir, scope, children?, found, budget) do
    with {:ok, %File.Stat{type: :directory}} <- File.stat(dir),
         {:ok, entries} <- File.ls(dir) do
      if length(entries) > budget.entries do
        {:error, "Antigravity skill discovery exceeded its scan limit at '#{dir}'."}
      else
        budget = %{budget | entries: budget.entries - length(entries)}
        entries = Enum.sort(entries)

        case Enum.find(entries, &(String.downcase(&1) == "skill.md")) do
          nil when children? ->
            entries
            |> Enum.sort_by(&sort_key/1)
            |> Enum.reduce_while({:ok, found, budget}, fn entry, {:ok, found, budget} ->
              case scan(Path.join(dir, entry), scope, false, found, budget) do
                {:ok, _, _} = ok -> {:cont, ok}
                error -> {:halt, error}
              end
            end)

          nil ->
            {:ok, found, budget}

          file ->
            if String.ends_with?(file, ".md"),
              do: read_skill(Path.join(dir, file), file, scope, found, budget),
              else: {:ok, found, budget}
        end
      end
    else
      _ -> {:ok, found, budget}
    end
  end

  defp read_skill(path, file, scope, found, budget) do
    limit = min(@max_skill_bytes, budget.bytes)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > limit ->
        {:error, "Antigravity skill discovery exceeded its scan limit at '#{path}'."}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, text} when byte_size(text) <= limit ->
            budget = %{budget | bytes: budget.bytes - byte_size(text)}

            case frontmatter(text, file) do
              %{"name" => name} = skill when not is_map_key(found, name) ->
                skill = Map.merge(skill, %{"path" => path, "scope" => scope, "enabled" => true})
                {:ok, Map.put(found, name, skill), budget}

              _ ->
                {:ok, found, budget}
            end

          {:ok, _} ->
            {:error, "Antigravity skill discovery exceeded its scan limit at '#{path}'."}

          _ ->
            {:ok, found, budget}
        end

      _ ->
        {:ok, found, budget}
    end
  end

  # Go's URL.EscapedPath order, which the agent sorts child folders by.
  defp sort_key(entry) do
    URI.encode(entry)
    |> String.replace(~r/[!'()*?#]/, fn <<c>> ->
      "%" <> String.upcase(Integer.to_string(c, 16))
    end)
  end

  @doc false
  # The `name` and `description` between the first two `---`. A name with outer
  # spaces is refused rather than renamed.
  def frontmatter(text, file) do
    with [_, rest] <- String.split(text, "---", parts: 2),
         [yaml, _] <- String.split(rest, "---", parts: 2) do
      fields = yaml_fields(yaml)
      name = non_empty(fields["name"]) || String.slice(file, 0..-4//1)
      description = non_empty(fields["description"] && String.trim(fields["description"]))

      if name != "" and name == String.trim(name) do
        if description,
          do: %{"name" => name, "description" => description},
          else: %{"name" => name}
      end
    else
      _ -> nil
    end
  end

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil

  # Top-level `key: value` scalars, quoted or plain, and `>`/`|` block scalars.
  defp yaml_fields(yaml) do
    lines = String.split(yaml, ~r/\r?\n/)

    {fields, _} =
      Enum.reduce(lines, {%{}, nil}, fn line, {fields, block} ->
        case {block, Regex.run(~r/^([A-Za-z0-9_-]+):\s*(.*)$/, line)} do
          {{key, style, parts}, nil} when line == "" or binary_part(line, 0, 1) in [" ", "\t"] ->
            {fields, {key, style, parts ++ [String.trim(line)]}}

          {block, match} ->
            fields = close_block(fields, block)

            case match do
              [_, key, value] when value in [">", "|", ">-", "|-", ">+", "|+"] ->
                {fields, {key, String.first(value), []}}

              [_, key, value] ->
                {Map.put(fields, key, scalar(String.trim(value))), nil}

              nil ->
                {fields, nil}
            end
        end
      end)
      |> then(fn {fields, block} -> {close_block(fields, block), nil} end)

    fields
  end

  defp close_block(fields, nil), do: fields

  defp close_block(fields, {key, style, parts}) do
    parts =
      Enum.drop_while(parts, &(&1 == ""))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    Map.put(fields, key, Enum.join(parts, if(style == ">", do: " ", else: "\n")))
  end

  defp scalar("\"" <> rest),
    do: rest |> String.trim_trailing("\"") |> String.replace("\\\"", "\"")

  defp scalar("'" <> rest), do: rest |> String.trim_trailing("'") |> String.replace("''", "'")
  defp scalar("~"), do: nil
  defp scalar("null"), do: nil
  defp scalar(value), do: value |> String.split(" #", parts: 2) |> hd() |> String.trim()
end
