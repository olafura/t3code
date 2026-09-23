defmodule T3.Workspace do
  @moduledoc """
  A project's files for clients (`projects.searchEntries`, `listEntries`, `readFile`,
  `searchContents`, `writeFile`): the composer's @-mentions, the file tree and
  viewer, and search.

  Entries come from git where the root is a repository (tracked and untracked files
  that are not ignored), else from a bounded walk; at most 25,000, kept a few seconds
  (`invalidate/1` drops them when a turn ends). Content search runs ripgrep, or git
  grep where ripgrep is missing. Reads and writes stay inside the workspace root,
  symlinks included.
  """

  use GenServer

  @table __MODULE__
  @max_entries 25_000
  @ttl_ms 10_000
  @read_max_bytes 1_048_576
  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg .bmp .ico .avif .tiff)
  @walk_skip ~w(.git node_modules .hg .svn _build deps target dist .next)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Forgets a root's cached entries (a turn may have changed its files)."
  def invalidate(root) do
    :ets.delete(@table, Path.expand(root))
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- RPCs ------------------------------------------------------------------------

  @doc "`projects.searchEntries`: files and folders matching a fuzzy query."
  def search_entries(%{"cwd" => cwd} = input) do
    limit = input["limit"] || 50

    with {:ok, root} <- root(cwd, "ProjectSearchEntriesError"),
         {:ok, {entries, _truncated}} <- index(root, "ProjectSearchEntriesError") do
      query =
        input["query"]
        |> to_string()
        |> String.trim()
        |> String.trim_leading("@")
        |> trim_leading_dots()

      matches =
        entries
        |> Enum.filter(&(input["kind"] in [nil, &1["kind"]]))
        |> Enum.filter(&(input["imageOnly"] != true or image?(&1["path"])))
        |> rank(String.downcase(query))

      {:ok, %{"entries" => Enum.take(matches, limit), "truncated" => length(matches) > limit}}
    end
  end

  @doc "`projects.listEntries`: the whole index, or one directory's children."
  def list_entries(%{"cwd" => cwd} = input) do
    with {:ok, root} <- root(cwd, "ProjectListEntriesError") do
      case input["directoryPath"] do
        nil ->
          with {:ok, {entries, truncated}} <- index(root, "ProjectListEntriesError"),
               do: {:ok, %{"entries" => entries, "truncated" => truncated}}

        directory ->
          list_directory(root, directory)
      end
    end
  end

  @doc "`projects.readFile`: up to 1 MB of a text file inside the root."
  def read_file(%{"cwd" => cwd, "relativePath" => relative} = input) do
    error = &file_error("ProjectReadFileError", input, &1, &2)

    with {:ok, root} <- root(cwd, "ProjectReadFileError"),
         {:ok, path} <- inside(root, relative, error),
         {:ok, %File.Stat{type: :regular, size: size}} <- stat(path, error),
         {:ok, contents} <- read_head(path, error) do
      if String.valid?(contents) and not String.contains?(contents, <<0>>) do
        {:ok,
         %{
           "relativePath" => normalize(relative),
           "contents" => contents,
           "byteLength" => size,
           "truncated" => size > @read_max_bytes
         }}
      else
        error.("binary_file", "'#{relative}' is not a text file.")
      end
    else
      {:ok, %File.Stat{}} -> error.("path_not_file", "'#{relative}' is not a file.")
      {:error, _} = failure -> failure
    end
  end

  @doc "`projects.writeFile`: writes a file inside the root, creating its folders."
  def write_file(%{"cwd" => cwd, "relativePath" => relative, "contents" => contents} = input) do
    error = &file_error("ProjectWriteFileError", input, &1, &2)

    with {:ok, root} <- root(cwd, "ProjectWriteFileError"),
         {:ok, path} <- inside(root, relative, error),
         :ok <- mkdir(Path.dirname(path), error),
         {:ok, path} <- inside(root, relative, error),
         :ok <- write(path, contents, error) do
      invalidate(root)
      {:ok, %{"relativePath" => normalize(relative)}}
    end
  end

  @doc "`projects.searchContents`: lines matching a literal or a regex."
  def search_contents(%{"cwd" => cwd, "query" => query} = input) do
    limit = input["limit"] || 100

    with {:ok, root} <- root(cwd, "ProjectSearchContentsError") do
      regex = input["useRegex"] == true

      case grep(root, query, regex, input) do
        {:ok, matches} ->
          {:ok, %{"matches" => Enum.take(matches, limit), "truncated" => length(matches) > limit}}

        # A regex that does not compile is searched for literally, as the Node server does.
        {:regex_error, message} ->
          with {:ok, matches} <- grep(root, query, false, input) do
            {:ok,
             %{
               "matches" => Enum.take(matches, limit),
               "truncated" => length(matches) > limit,
               "regexFallbackError" => message
             }}
          end

        {:error, message} ->
          entries_error("ProjectSearchContentsError", cwd, "search_index_search_failed", message)
      end
    end
  end

  # --- the index -------------------------------------------------------------------

  defp index(root, tag) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, root) do
      [{^root, at, value}] when now - at < @ttl_ms ->
        {:ok, value}

      _ ->
        value = scan(root)
        :ets.insert(@table, {root, now, value})
        {:ok, value}
    end
  rescue
    error -> entries_error(tag, root, "search_index_create_failed", Exception.message(error))
  end

  defp scan(root) do
    files =
      case T3.Git.run(
             root,
             ~w(-c core.fsmonitor=false ls-files -z --cached --others --exclude-standard)
           ) do
        {:ok, %{status: 0, out: out}} -> out |> String.split(<<0>>, trim: true) |> Enum.uniq()
        _ -> walk(root)
      end

    files = Enum.reject(files, &String.starts_with?(&1, ".git/"))

    directories =
      files
      |> Enum.flat_map(fn file -> file |> Path.dirname() |> ancestors() end)
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(directories, &%{"path" => &1, "kind" => "directory"}) ++
        Enum.map(Enum.sort(files), &%{"path" => &1, "kind" => "file"})

    {Enum.take(entries, @max_entries), length(entries) > @max_entries}
  end

  defp ancestors("."), do: []
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]

  # Outside git: the tree minus the usual build and dependency folders.
  defp walk(root), do: root |> walk("", {[], 0}) |> elem(0)

  # Stops one past the limit, so the index can tell it was cut short.
  defp walk(root, relative, acc) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} ->
        Enum.reduce(Enum.sort(names), acc, fn name, {files, count} = acc ->
          path = if relative == "", do: name, else: "#{relative}/#{name}"
          full = Path.join(root, path)

          cond do
            count > @max_entries -> acc
            name in @walk_skip -> acc
            File.dir?(full) and not symlink?(full) -> walk(root, path, acc)
            File.regular?(full) -> {[path | files], count + 1}
            true -> acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  # Fuzzy ranking: a name that starts with the query, then one that contains it, then
  # a path containing it, then the query's letters in order; shorter paths first.
  defp rank(entries, ""), do: entries

  defp rank(entries, query) do
    entries
    |> Enum.flat_map(fn entry ->
      path = String.downcase(entry["path"])
      name = Path.basename(path)

      score =
        cond do
          String.starts_with?(name, query) -> 0
          String.contains?(name, query) -> 1
          String.contains?(path, query) -> 2
          subsequence?(path, query) -> 3
          true -> nil
        end

      if score, do: [{score, String.length(path), entry}], else: []
    end)
    |> Enum.sort_by(fn {score, length, entry} -> {score, length, entry["path"]} end)
    |> Enum.map(&elem(&1, 2))
  end

  defp subsequence?(_text, ""), do: true
  defp subsequence?("", _query), do: false

  defp subsequence?(<<c::utf8, text::binary>>, <<c::utf8, query::binary>>),
    do: subsequence?(text, query)

  defp subsequence?(<<_::utf8, text::binary>>, query), do: subsequence?(text, query)

  defp image?(path), do: String.downcase(Path.extname(path)) in @image_extensions

  defp trim_leading_dots(query), do: String.replace(query, ~r{^[./]+}, "")

  # --- one directory ---------------------------------------------------------------

  defp list_directory(root, directory) do
    error = fn message ->
      entries_error("ProjectListEntriesError", root, "directory_list_failed", message)
    end

    relative = normalize(directory)

    with {:ok, path} <- inside(root, relative, fn _, message -> error.(message) end),
         :ok <-
           if(".git" in Path.split(relative),
             do: error.("The .git folder is not listed."),
             else: :ok
           ),
         {:ok, names} <- File.ls(path) do
      entries =
        for name <- Enum.sort(names),
            name != ".git",
            full = Path.join(path, name),
            File.dir?(full) or File.regular?(full) do
          %{
            "path" => if(relative in ["", "."], do: name, else: "#{relative}/#{name}"),
            "kind" => if(File.dir?(full), do: "directory", else: "file")
          }
        end

      ignored = ignored(root, Enum.map(entries, & &1["path"]))

      {:ok,
       %{
         "entries" =>
           Enum.map(
             entries,
             &if(&1["path"] in ignored, do: Map.put(&1, "ignored", true), else: &1)
           ),
         "truncated" => false
       }}
    else
      {:error, reason} when is_atom(reason) -> error.("Could not list '#{directory}': #{reason}")
      {:error, _} = failure -> failure
    end
  end

  # What git would ignore; nothing outside a repository.
  defp ignored(_root, []), do: MapSet.new()

  defp ignored(root, paths) do
    input = Enum.map_join(paths, "", &(&1 <> <<0>>))

    case T3.Git.run(root, ~w(-c core.fsmonitor=false check-ignore -z --stdin), input: input) do
      {:ok, %{status: status, out: out}} when status in [0, 1] ->
        out |> String.split(<<0>>, trim: true) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # --- content search --------------------------------------------------------------

  defp grep(root, query, regex, input) do
    # `:ripgrep` names the executable; nil searches with git grep (tests).
    rg = Application.get_env(:t3, :ripgrep, "rg")

    if rg = rg && System.find_executable(rg),
      do: ripgrep(rg, root, query, regex, input),
      else: git_grep(root, query, regex, input)
  end

  defp ripgrep(rg, root, query, regex, input) do
    args =
      ["--json", "--max-count", "100", "--max-filesize", "1M"] ++
        if(input["caseSensitive"] == true, do: ["--case-sensitive"], else: ["--ignore-case"]) ++
        if(input["wholeWord"] == true, do: ["--word-regexp"], else: []) ++
        if(regex, do: [], else: ["--fixed-strings"]) ++ ["-e", query, "."]

    case run([rg | args], root) do
      {:ok, 2, _out, err} ->
        if regex, do: {:regex_error, String.trim(err)}, else: {:error, String.trim(err)}

      {:ok, _status, out, _err} ->
        {:ok,
         for line <- String.split(out, "\n", trim: true),
             %{"type" => "match", "data" => data} <- [JSON.decode!(line)],
             text = get_in(data, ["lines", "text"]),
             is_binary(text) do
           content = String.trim_trailing(text, "\n")

           %{
             "path" => data |> get_in(["path", "text"]) |> String.trim_leading("./"),
             "lineNumber" => data["line_number"],
             "lineContent" => content,
             "matchRanges" =>
               for %{"start" => s, "end" => e} <- data["submatches"] || [] do
                 # ripgrep counts bytes; clients count characters.
                 %{"start" => chars(text, s), "end" => chars(text, e)}
               end
           }
         end}

      {:error, message} ->
        {:error, message}
    end
  end

  defp git_grep(root, query, regex, input) do
    in_repo = match?({:ok, _}, T3.Git.ok(root, ~w(rev-parse --git-dir)))

    args =
      ["grep", "-n", "-I", "--untracked"] ++
        if(in_repo, do: [], else: ["--no-index"]) ++
        if(input["caseSensitive"] == true, do: [], else: ["-i"]) ++
        if(input["wholeWord"] == true, do: ["-w"], else: []) ++
        if(regex, do: ["-E"], else: ["-F"]) ++ ["-e", query]

    case T3.Git.run(root, args, max_bytes: 10_000_000) do
      {:ok, %{status: status, out: out}} when status in [0, 1] ->
        pattern = match_pattern(query, regex, input)

        {:ok,
         for line <- String.split(out, "\n", trim: true),
             [path, number, content] <- [String.split(line, ":", parts: 3)] do
           ranges =
             for [{start, length}] <- Regex.scan(pattern, content, return: :index),
                 do: %{
                   "start" => chars(content, start),
                   "end" => chars(content, start + length)
                 }

           %{
             "path" => path,
             "lineNumber" => String.to_integer(number),
             "lineContent" => content,
             "matchRanges" => ranges
           }
         end}

      {:ok, %{err: err}} ->
        if regex, do: {:regex_error, String.trim(err)}, else: {:error, String.trim(err)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp match_pattern(query, regex, input) do
    source = if regex, do: query, else: Regex.escape(query)
    source = if input["wholeWord"] == true, do: "\\b#{source}\\b", else: source
    opts = if input["caseSensitive"] == true, do: "u", else: "iu"
    Regex.compile!(source, opts)
  rescue
    _ -> Regex.compile!(Regex.escape(query), "iu")
  end

  defp chars(text, bytes),
    do: text |> binary_part(0, min(bytes, byte_size(text))) |> String.length()

  defp run(cmd, cd) do
    {out, err, status} =
      Exile.stream(cmd, cd: cd, stderr: :consume, ignore_epipe: true)
      |> Enum.reduce_while({[], [], nil}, fn
        {:stdout, data}, {out, err, status} ->
          # Enough for the limit many times over; the rest is dropped.
          if IO.iodata_length(out) > 20_000_000,
            do: {:halt, {out, err, status}},
            else: {:cont, {[out, data], err, status}}

        {:stderr, data}, {out, err, status} ->
          {:cont, {out, [err, data], status}}

        {:exit, {:status, status}}, {out, err, _} ->
          {:cont, {out, err, status}}

        {:exit, other}, {out, err, _} ->
          {:cont, {out, err, other}}
      end)

    {:ok, status, IO.iodata_to_binary(out), IO.iodata_to_binary(err)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # --- paths -----------------------------------------------------------------------

  defp root(cwd, tag) do
    root = Path.expand(cwd)

    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, root}

      {:ok, _} ->
        entries_error(tag, cwd, "workspace_root_not_directory", "'#{cwd}' is not a folder.")

      {:error, _} ->
        entries_error(tag, cwd, "workspace_root_not_found", "'#{cwd}' does not exist.")
    end
  end

  # A path under the root, which must stay under it once symlinks resolve.
  defp inside(root, relative, error) do
    relative = normalize(relative)

    cond do
      Path.type(relative) != :relative or ".." in Path.split(relative) ->
        error.("workspace_path_outside_root", "'#{relative}' is outside the workspace.")

      not within?(real(root), real(Path.join(root, relative))) ->
        error.("resolved_path_outside_root", "'#{relative}' resolves outside the workspace.")

      true ->
        {:ok, Path.join(root, relative)}
    end
  end

  defp within?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  # The real path of `path`, or of its nearest existing ancestor joined with the rest.
  defp real(path), do: real(Path.split(Path.expand(path)), "/", 0)

  # A link loop resolves no further than this.
  defp real(parts, acc, links) when links > 40, do: Path.join([acc | parts])
  defp real([], acc, _links), do: acc
  defp real(["/" | rest], acc, links), do: real(rest, acc, links)

  defp real([part | rest], acc, links) do
    next = Path.join(acc, part)

    case File.read_link(next) do
      {:ok, target} -> real(Path.split(Path.expand(target, acc)) ++ rest, "/", links + 1)
      {:error, _} -> real(rest, next, links)
    end
  end

  defp normalize(relative) do
    relative
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp stat(path, error) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> error.("operation_failed", "Could not read '#{path}': #{reason}")
    end
  end

  defp read_head(path, error) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @read_max_bytes)) do
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:ok, :eof} -> {:ok, ""}
      _ -> error.("operation_failed", "Could not read '#{path}'.")
    end
  end

  defp mkdir(dir, error) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> error.("operation_failed", "Could not create '#{dir}': #{reason}")
    end
  end

  defp write(path, contents, error) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> error.("operation_failed", "Could not write '#{path}': #{reason}")
    end
  end

  defp file_error(tag, input, failure, message) do
    {:error,
     %{
       "_tag" => tag,
       "cwd" => input["cwd"],
       "relativePath" => input["relativePath"],
       "failure" => failure,
       "message" => message
     }}
  end

  defp entries_error(tag, cwd, failure, message) do
    {:error, %{"_tag" => tag, "cwd" => cwd, "failure" => failure, "message" => message}}
  end
end
