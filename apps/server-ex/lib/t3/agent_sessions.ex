defmodule T3.AgentSessions do
  @moduledoc """
  Projects and history from the coding agents already used on this machine, for the
  setup wizard (`agentSessions.scan` and `agentSessions.import`).

  Claude Code and Codex keep one JSONL transcript per session
  (`~/.claude/projects/*/*.jsonl`, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`),
  and each records the directory it ran in. A scan groups the newest transcripts
  by that directory into project candidates. An import turns a project's
  transcripts from the last 30 days into settled threads holding their visible user
  and assistant messages, each tied to the native session so a follow-up resumes it.

  Everything is bounded: transcripts per source, bytes read for a directory, line
  length (huge tool results such as screenshots are skipped unread), and messages
  per thread.
  """

  alias T3.{Patch, StreamState}
  alias T3.Orchestration.Entities

  @max_transcripts 5_000
  @cwd_scan_bytes 1024 * 1024
  @max_line 4 * 1024 * 1024
  @window_ms 30 * 24 * 60 * 60 * 1000
  @max_imports 100
  @max_messages 200
  @default_models %{"codex" => "gpt-6-astra", "claudeAgent" => "claude-fable-5-1"}
  @claude_session ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  # --- scan -----------------------------------------------------------------------

  @doc "`agentSessions.scan`: `AgentSessionScanResult`, newest first."
  def scan(_input \\ %{}) do
    {transcripts, truncated} = transcripts()
    projects = projects_by_root()

    candidates =
      transcripts
      |> with_cwds()
      |> Enum.group_by(& &1.cwd)
      |> Enum.flat_map(fn {cwd, group} -> candidate(cwd, group, projects) end)
      |> Enum.sort_by(&{&1["lastActiveAt"], &1["path"]}, fn {a, pa}, {b, pb} ->
        if a == b, do: pa <= pb, else: a >= b
      end)

    {:ok,
     %{"candidates" => candidates, "scannedAt" => Entities.now()}
     |> then(&if(truncated, do: Map.put(&1, "truncated", true), else: &1))}
  end

  defp candidate(cwd, group, projects) do
    path = Path.expand(cwd)

    with false <- excluded?(path),
         true <- File.dir?(path),
         {:ok, git} <- git_identity(path) do
      project = projects[path]
      last = group |> Enum.map(& &1.mtime) |> Enum.max()

      [
        %{
          "path" => path,
          "title" => Path.basename(path),
          "sources" => group |> Enum.map(& &1.source) |> Enum.uniq(),
          "threadCount" => length(group),
          "lastActiveAt" => iso(last),
          "alreadyImported" => project != nil,
          "git" => git
        }
        |> then(&if(project, do: Map.put(&1, "projectId", project), else: &1))
      ]
    else
      _ -> []
    end
  end

  # Transcripts of both agents, newest first, capped per source.
  defp transcripts do
    for {source, files} <- [{"claudeAgent", claude_files()}, {"codex", codex_files()}],
        reduce: {[], false} do
      {acc, truncated} ->
        newest =
          files
          |> Enum.flat_map(&stat(source, &1))
          |> Enum.sort_by(& &1.mtime, :desc)

        {acc ++ Enum.take(newest, @max_transcripts),
         truncated or length(newest) > @max_transcripts}
    end
  end

  defp claude_files do
    home = System.get_env("CLAUDE_CONFIG_DIR") || Path.join(System.user_home!(), ".claude")
    Path.wildcard(Path.join([Path.expand(home), "projects", "*", "*.jsonl"]))
  end

  defp codex_files do
    home = System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
    Path.wildcard(Path.join([Path.expand(home), "sessions", "*", "*", "*", "rollout-*.jsonl"]))
  end

  defp stat(source, path) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        [%{source: source, path: path, size: size, mtime: mtime * 1000}]

      _ ->
        []
    end
  end

  # Reads each transcript's working directory, a few files at a time.
  defp with_cwds(transcripts) do
    transcripts
    |> Task.async_stream(&Map.put(&1, :cwd, read_cwd(&1.path)),
      max_concurrency: 16,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.flat_map(fn
      {:ok, %{cwd: cwd} = transcript} when is_binary(cwd) -> [transcript]
      _ -> []
    end)
  end

  @doc false
  def read_cwd(path) do
    each_record(path, nil, @cwd_scan_bytes, fn record, _ ->
      case cwd(record) do
        nil -> {:cont, nil}
        cwd -> {:halt, cwd}
      end
    end)
  end

  defp cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: cwd
  defp cwd(%{"payload" => %{"cwd" => cwd}}) when is_binary(cwd) and cwd != "", do: cwd
  defp cwd(_), do: nil

  # The user's home, temp folders, downloads, Codex scratch folders, and T3's own
  # worktrees are never projects.
  defp excluded?(path) do
    home = System.user_home!()
    t3_home = Path.expand(Application.get_env(:t3, :home, Path.join(home, ".t3")))

    path in [home, Path.expand(System.tmp_dir!()), "/tmp", "/private/tmp"] or
      Enum.any?(
        [Path.join(home, "Downloads"), Path.join([home, "Documents", "Codex"]), t3_home],
        &(path == &1 or String.starts_with?(path, &1 <> "/"))
      ) or String.contains?(path <> "/", "/.t3/worktrees/")
  end

  # `{:ok, git}` with the origin's normalized key, or `{:ok, nil}` outside a
  # repository. A linked worktree is skipped: its history belongs to the main one.
  defp git_identity(dir) do
    dot_git = Path.join(dir, ".git")

    git_dir =
      case File.stat(dot_git) do
        {:ok, %{type: :directory}} ->
          {:ok, dot_git}

        {:ok, _} ->
          with {:ok, text} <- File.read(dot_git),
               [_, target] <- Regex.run(~r/^gitdir:\s*(.+)$/m, text) do
            target = Path.expand(String.trim(target), dir)
            if Regex.match?(~r{/worktrees/[^/]+/?$}, target), do: :worktree, else: {:ok, target}
          else
            _ -> :none
          end

        _ ->
          :none
      end

    case git_dir do
      :worktree ->
        :worktree

      :none ->
        {:ok, nil}

      {:ok, git_dir} ->
        url =
          case File.read(Path.join(git_dir, "config")) do
            {:ok, config} -> origin_url(config)
            _ -> nil
          end

        {:ok, %{"remoteKey" => url && remote_key(url), "repository" => github_repository(url)}}
    end
  end

  @doc "The origin's URL in a `.git/config`, else the first remote's."
  def origin_url(config) do
    config
    |> String.replace(~r/\\\r?\n[ \t]*/, "")
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, nil, nil}, fn raw, {section, origin, first} ->
      case {config_line(String.trim(raw)), section} do
        {{:section, name}, _} -> {name, origin, first}
        {{:url, _}, nil} -> {section, origin, first}
        {{:url, ""}, _} -> {section, origin, first}
        {{:url, url}, "origin"} -> {section, origin || url, first}
        {{:url, url}, _} -> {section, origin, first || url}
        {:other, _} -> {section, origin, first}
      end
    end)
    |> then(fn {_, origin, first} -> origin || first end)
  end

  # A `.git/config` line: a remote section header (both `[remote "x"]` and the
  # legacy `[remote.x]`), another section (`nil` name), a url, or anything else.
  defp config_line(line) do
    cond do
      line == "" or String.starts_with?(line, ["#", ";"]) ->
        :other

      header = Regex.run(~r/^\[\s*remote(?:\s+"([^"]+)"|\.([^\]\s]+))\s*\](?:\s*[#;].*)?$/i, line) ->
        case header do
          [_, quoted] -> {:section, quoted}
          [_, "", dotted] -> {:section, String.downcase(dotted)}
        end

      String.starts_with?(line, "[") ->
        {:section, nil}

      url = Regex.run(~r/^url\s*=\s*(.*)$/i, line) ->
        {:url, config_value(Enum.at(url, 1))}

      true ->
        :other
    end
  end

  defp config_value(raw) do
    raw
    |> String.graphemes()
    |> Enum.reduce_while({"", false, false}, fn
      char, {out, quoted, true} -> {:cont, {out <> char, quoted, false}}
      "\\", {out, quoted, false} -> {:cont, {out, quoted, true}}
      "\"", {out, quoted, false} -> {:cont, {out, not quoted, false}}
      char, {out, false, false} when char in ["#", ";"] -> {:halt, {out, false, false}}
      char, {out, quoted, false} -> {:cont, {out <> char, quoted, false}}
    end)
    |> elem(0)
    |> String.trim()
  end

  @doc "A remote URL as `host/owner/repo`, shared by every clone of it."
  def remote_key(url) do
    normalized =
      url
      |> String.trim()
      |> String.replace(~r{/+$}, "")
      |> String.replace(~r/\.git$/i, "")
      |> String.downcase()

    cond do
      Regex.match?(~r{^(ssh|https?|git)://}i, normalized) ->
        uri = URI.parse(normalized)
        segments = String.split(uri.path || "", "/", trim: true)

        if uri.host && length(segments) > 1,
          do: azure_key(uri.host, segments) || "#{uri.host}/#{Enum.join(segments, "/")}",
          else: normalized

      match = Regex.run(~r{^[a-zA-Z0-9._-]+@([^:/\s]+):([^/\s]+(?:/[^/\s]+)+)$}i, normalized) ->
        [_, host, path] = match
        azure_key(host, String.split(path, "/")) || "#{host}/#{path}"

      true ->
        normalized
    end
  end

  defp azure_key("ssh.dev.azure.com", ["v3", org, project, repo]),
    do: "dev.azure.com/#{org}/#{project}/_git/#{repo}"

  defp azure_key("vs-ssh.visualstudio.com", ["v3", org, project, repo]),
    do: "#{org}.visualstudio.com/#{project}/_git/#{repo}"

  defp azure_key(_, _), do: nil

  defp github_repository(nil), do: nil

  defp github_repository(url) do
    case Regex.run(
           ~r{^(?:git@github\.com:|ssh://(?:git@)?github\.com/|https://github\.com/|git://github\.com/)([^/\s]+/[^/\s]+?)(?:\.git)?/?$}i,
           String.trim(url)
         ) do
      [_, name] -> name
      _ -> nil
    end
  end

  # Active projects on this node by root.
  defp projects_by_root do
    for {{node, id}, {"project", project}} <- T3.Shell.rows(),
        node == node() and project["deletedAt"] == nil and is_binary(project["workspaceRoot"]),
        into: %{},
        do: {Path.expand(project["workspaceRoot"]), project["id"] || id}
  end

  # --- import ---------------------------------------------------------------------

  @doc """
  `agentSessions.import`: threads for a project from its transcripts of the last 30
  days. Sessions already imported count as imported; unreadable ones as skipped.
  """
  def import_project(%{"projectId" => project_id} = input) do
    # Read from the project's own stream: the wizard imports right after creating
    # the project, before its sidebar row exists.
    project =
      project_id
      |> T3.Streams.ensure()
      |> T3.Streams.Server.state()
      |> StreamState.get("project")
      |> Map.get(project_id)

    active = if project && project["deletedAt"] == nil, do: project["workspaceRoot"]

    case active do
      root when is_binary(root) ->
        root = Path.expand(root)
        expected = input["expectedWorkspaceRoot"]

        if expected && Path.expand(expected) != root,
          do: {:error, project_error("AgentSessionImportProjectChangedError", project_id)},
          else: {:ok, import_root(project_id, root)}

      nil ->
        {:error, project_error("AgentSessionImportProjectNotFoundError", project_id)}
    end
  end

  defp project_error(tag, project_id),
    do: %{
      "_tag" => tag,
      "projectId" => project_id,
      "message" =>
        if(tag == "AgentSessionImportProjectNotFoundError",
          do: "Project '#{project_id}' does not exist.",
          else: "Project '#{project_id}' changed directories. Scan for projects again."
        )
    }

  defp import_root(project_id, root) do
    cutoff = System.os_time(:millisecond) - @window_ms
    {transcripts, _} = transcripts()

    recent =
      transcripts
      |> Enum.filter(&(&1.mtime >= cutoff))
      |> with_cwds()
      |> Enum.filter(&(Path.expand(&1.cwd) == root))
      |> Enum.sort_by(& &1.mtime, :desc)

    {eligible, over_budget} = Enum.split(recent, @max_imports)

    {imported, skipped, _seen} =
      Enum.reduce(eligible, {0, length(over_budget), MapSet.new()}, fn transcript,
                                                                       {imported, skipped, seen} ->
        case parse(transcript) do
          nil ->
            {imported, skipped + 1, seen}

          thread ->
            thread_id = "import:#{thread.source}:#{thread.session_id}"

            cond do
              MapSet.member?(seen, thread_id) ->
                {imported, skipped, seen}

              write_thread(thread_id, project_id, thread) == :ok ->
                {imported + 1, skipped, MapSet.put(seen, thread_id)}

              true ->
                {imported, skipped + 1, seen}
            end
        end
      end)

    %{"importedCount" => imported, "skippedCount" => skipped}
  end

  # Creates the thread unless it exists; an existing import counts as done.
  defp write_thread(thread_id, project_id, thread) do
    driver = thread.source
    at = iso(thread.updated_ms)
    created = hd(thread.messages).created_at
    provider_thread_id = "provider-thread:#{driver}:#{thread_id}"
    model = thread.model || @default_models[driver]

    app_thread =
      %{
        "threadId" => thread_id,
        "projectId" => project_id,
        "title" => thread.title,
        "creationSource" => "server",
        "modelSelection" => %{"instanceId" => driver, "model" => model}
      }
      |> Entities.thread(created)
      |> Map.merge(%{
        "createdBy" => "system",
        # Left unset: clients read a provider thread with no run as idle background
        # work ("Waiting"). Runs find the provider thread by its derived id.
        "activeProviderThreadId" => nil,
        "historyOrigin" => "v1_import",
        "settledOverride" => "settled",
        "settledAt" => at,
        "updatedAt" => at
      })

    provider_thread =
      Entities.provider_thread(provider_thread_id, thread_id, nil, nil, created, driver, driver)
      |> Map.merge(%{
        "nativeThreadRef" => Entities.provider_ref(thread.session_id, driver),
        "status" => "idle",
        "firstRunOrdinal" => nil,
        "lastRunOrdinal" => nil,
        "updatedAt" => at
      })

    # Each change carries the session's own time, so the thread's row sorts by when
    # the session was active rather than when it was imported.
    changes =
      [{"thread", thread_id, Patch.diff(nil, app_thread), ms(created)}] ++
        (thread.messages
         |> Enum.with_index()
         |> Enum.flat_map(fn {message, index} ->
           for {kind, id, patch} <- message_changes(thread_id, index, message),
               do: {kind, id, patch, ms(message.created_at)}
         end)) ++
        [
          {"provider-thread", provider_thread_id, Patch.diff(nil, provider_thread),
           thread.updated_ms}
        ]

    # A session imported into another project stays there.
    T3.Streams.transact(thread_id, :thread, fn state ->
      case StreamState.get(state, "thread")[thread_id] do
        nil -> {changes, :ok}
        %{"projectId" => ^project_id} -> {[], :ok}
        _other_project -> {[], :conflict}
      end
    end)
  catch
    _, _ -> :error
  end

  defp message_changes(thread_id, index, message) do
    suffix = index |> Integer.to_string() |> String.pad_leading(6, "0")
    message_id = "#{thread_id}:#{suffix}"
    item_id = "agent-session-import:turn-item:#{thread_id}:#{suffix}"
    at = message.created_at

    entity = %{
      "createdBy" => if(message.role == "user", do: "user", else: "agent"),
      "creationSource" => "server",
      "id" => message_id,
      "threadId" => thread_id,
      "runId" => nil,
      "nodeId" => nil,
      "role" => message.role,
      "text" => message.text,
      "attachments" => [],
      "streaming" => false,
      "createdAt" => at,
      "updatedAt" => at
    }

    base = %{
      "id" => item_id,
      "threadId" => thread_id,
      "runId" => nil,
      "nodeId" => nil,
      "providerThreadId" => nil,
      "providerTurnId" => nil,
      "nativeItemRef" => nil,
      "parentItemId" => nil,
      "ordinal" => index + 1,
      "status" => "completed",
      "title" => nil,
      "startedAt" => at,
      "completedAt" => at,
      "updatedAt" => at,
      "messageId" => message_id,
      "text" => message.text
    }

    item =
      if message.role == "user",
        do:
          Map.merge(base, %{
            "type" => "user_message",
            "createdBy" => "user",
            "creationSource" => "server",
            "inputIntent" => "turn_start",
            "attachments" => []
          }),
        else: Map.merge(base, %{"type" => "assistant_message", "streaming" => false})

    [
      {"message", message_id, Patch.diff(nil, entity)},
      {"turn-item", item_id, Patch.diff(nil, item)}
    ]
  end

  # --- transcripts ----------------------------------------------------------------

  @doc """
  A transcript's thread: session id, title, model, and its visible user and
  assistant messages (the last #{@max_messages}, keeping the first prompt), or nil
  when it has no resumable session or no prompt.
  """
  def parse(%{source: source, path: path, mtime: mtime}) do
    fallback = iso(mtime)

    initial = %{
      session_id: if(source == "claudeAgent", do: Path.basename(path, ".jsonl"), else: nil),
      title: nil,
      model: nil,
      messages: [],
      count: 0,
      first_user: nil,
      first_prompt: nil,
      codex_events: false
    }

    acc = each_record(path, initial, :infinity, &{:cont, record(source, &1, &2, fallback)})

    # Codex writes each prompt as an event and again, with setup text, as a
    # response item; the events are the prompts the user typed.
    typed_only = source == "codex" and acc.codex_events

    messages =
      acc.messages
      |> Enum.reverse()
      |> Enum.reject(&(typed_only and &1.codex_response_user))
      |> Enum.map(&Map.delete(&1, :codex_response_user))

    first_user =
      case if(typed_only, do: acc.first_prompt, else: acc.first_user) do
        nil -> nil
        message -> Map.delete(message, :codex_response_user)
      end

    cond do
      acc.session_id in [nil, ""] or first_user == nil ->
        nil

      source == "claudeAgent" and not Regex.match?(@claude_session, acc.session_id) ->
        nil

      true ->
        kept =
          case Enum.take(messages, -@max_messages) do
            [^first_user | _] = kept -> kept
            kept -> [first_user | Enum.take(kept, 1 - @max_messages)]
          end

        derived =
          first_user.text
          |> String.trim()
          |> String.split("\n")
          |> hd()
          |> String.slice(0, 100)
          |> String.trim()

        %{
          source: source,
          session_id: acc.session_id,
          title: acc.title || if(derived == "", do: "Imported thread", else: derived),
          model: acc.model,
          updated_ms: mtime,
          messages: kept
        }
    end
  end

  defp record("claudeAgent", %{} = r, acc, fallback) do
    if r["isSidechain"] == true or r["isMeta"] == true or r["isCompactSummary"] == true do
      acc
    else
      acc =
        acc
        |> put_if(:session_id, trimmed(r["sessionId"]))
        |> put_if(:title, trimmed(r["aiTitle"]))
        |> put_if(:model, claude_model(get_in(r, ["message", "model"])))

      with type when type in ["user", "assistant"] <- r["type"],
           text when text != "" <- text(get_in(r, ["message", "content"])) do
        add_message(acc, type, text, r["timestamp"], fallback)
      else
        _ -> acc
      end
    end
  end

  defp record("codex", %{"type" => "session_meta", "payload" => p}, acc, _) when is_map(p) do
    id = trimmed(p["id"]) || trimmed(p["session_id"])
    if acc.session_id == nil and id, do: %{acc | session_id: id}, else: acc
  end

  defp record("codex", %{"type" => "turn_context", "payload" => %{"model" => m}}, acc, _),
    do: put_if(acc, :model, trimmed(m))

  defp record(
         "codex",
         %{"type" => "event_msg", "payload" => %{"type" => "user_message"} = p} = r,
         acc,
         fallback
       ) do
    case p["message"] do
      text when is_binary(text) and text != "" ->
        %{add_message(acc, "user", text, r["timestamp"], fallback) | codex_events: true}

      _ ->
        acc
    end
  end

  defp record(
         "codex",
         %{"type" => "response_item", "payload" => %{"type" => "message", "role" => role} = p} = r,
         acc,
         fallback
       )
       when role in ["user", "assistant"] do
    case text(p["content"]) do
      "" -> acc
      text -> add_message(acc, role, text, r["timestamp"], fallback, role == "user")
    end
  end

  defp record(_source, _record, acc, _fallback), do: acc

  # Keeps a bounded tail of messages, plus the first prompt: the first user message,
  # and for Codex the first one typed (an event rather than a response item).
  defp add_message(acc, role, text, timestamp, fallback, codex_response_user \\ false) do
    message = %{
      role: role,
      text: text,
      created_at: timestamp(timestamp, fallback),
      codex_response_user: codex_response_user
    }

    {messages, count} =
      if acc.count >= 2 * @max_messages,
        do: {[message | Enum.take(acc.messages, @max_messages)], @max_messages + 1},
        else: {[message | acc.messages], acc.count + 1}

    user? = role == "user"

    %{
      acc
      | messages: messages,
        count: count,
        first_user: acc.first_user || if(user?, do: message),
        first_prompt: acc.first_prompt || if(user? and not codex_response_user, do: message)
    }
  end

  # Claude marks its own local error replies with a model that cannot be resumed.
  defp claude_model(model) do
    case trimmed(model) do
      "<synthetic>" -> nil
      model -> model
    end
  end

  defp put_if(acc, _key, nil), do: acc
  defp put_if(acc, key, value), do: Map.put(acc, key, value)

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_), do: nil

  defp text(content) when is_binary(content), do: String.trim(content)

  defp text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] in ["text", "input_text", "output_text"]))
    |> Enum.map(&String.trim(&1["text"] || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text(_), do: ""

  defp timestamp(value, fallback) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      _ -> fallback
    end
  end

  defp timestamp(_, fallback), do: fallback

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp ms(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end

  # Folds `fun` over a JSONL file's decodable records, reading at most `max_bytes`.
  # Lines longer than @max_line are skipped without being held in memory.
  defp each_record(path, acc, max_bytes, fun) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          read_records(file, "", false, 0, max_bytes, acc, fun)
        after
          File.close(file)
        end

      _ ->
        acc
    end
  end

  defp read_records(file, buffer, skipping, read, max, acc, fun) do
    if max != :infinity and read >= max do
      acc
    else
      case IO.binread(file, 64 * 1024) do
        data when is_binary(data) ->
          {lines, rest} = split_lines(buffer <> data)

          {lines, skipping} =
            if skipping, do: {Enum.drop(lines, 1), lines == []}, else: {lines, false}

          {rest, skipping} =
            if byte_size(rest) > @max_line, do: {"", true}, else: {rest, skipping}

          case fold_lines(lines, acc, fun) do
            {:halt, acc} ->
              acc

            {:cont, acc} ->
              read_records(file, rest, skipping, read + byte_size(data), max, acc, fun)
          end

        _ ->
          if skipping or buffer == "", do: acc, else: elem(fold_lines([buffer], acc, fun), 1)
      end
    end
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp fold_lines([], acc, _fun), do: {:cont, acc}

  defp fold_lines([line | rest], acc, fun) do
    result =
      if byte_size(line) > @max_line do
        {:cont, acc}
      else
        case JSON.decode(line) do
          {:ok, %{} = record} -> fun.(record, acc)
          _ -> {:cont, acc}
        end
      end

    case result do
      {:halt, _} = halt -> halt
      {:cont, acc} -> fold_lines(rest, acc, fun)
    end
  end
end
