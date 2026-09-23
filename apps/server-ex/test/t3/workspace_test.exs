defmodule T3.WorkspaceTest do
  use ExUnit.Case, async: false

  alias T3.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "repo")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(Path.join(root, "src/deep"))
    File.mkdir_p!(outside)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: root)
    File.write!(Path.join(root, ".gitignore"), "ignored.log\n")
    File.write!(Path.join(root, "ignored.log"), "noise")
    File.write!(Path.join(root, "README.md"), "Hello World\nhello again\n")
    File.write!(Path.join(root, "src/app.ex"), "defmodule App do\n  def hello, do: :world\nend\n")
    File.write!(Path.join(root, "src/deep/notes.txt"), "applesauce\n")
    File.write!(Path.join(root, "logo.png"), <<137, 80, 78, 71, 0, 0, 1>>)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "link.txt"))
    start_supervised!(Workspace)
    %{root: root}
  end

  test "entries rank by name, filter by kind and images, and skip ignored files", %{root: root} do
    search = &Workspace.search_entries(Map.merge(%{"cwd" => root, "limit" => 10}, &1))

    assert {:ok, %{"entries" => [%{"path" => "src/app.ex"} | _]}} = search.(%{"query" => "@app"})
    assert {:ok, %{"entries" => entries}} = search.(%{"query" => "", "kind" => "directory"})
    assert Enum.map(entries, & &1["path"]) == ["src", "src/deep"]

    assert {:ok, %{"entries" => [%{"path" => "logo.png"}]}} =
             search.(%{"query" => "", "imageOnly" => true})

    # Letters in order match too.
    assert {:ok, %{"entries" => [%{"path" => "src/deep/notes.txt"}]}} =
             search.(%{"query" => "sdnt"})

    assert {:ok, %{"entries" => all}} = search.(%{"query" => "ignored"})
    assert all == []
  end

  test "a directory's children say which are ignored", %{root: root} do
    assert {:ok, %{"entries" => entries}} =
             Workspace.list_entries(%{"cwd" => root, "directoryPath" => ""})

    by_path = Map.new(entries, &{&1["path"], &1})
    refute Map.has_key?(by_path, ".git")
    assert %{"kind" => "directory"} = by_path["src"]
    assert %{"ignored" => true} = by_path["ignored.log"]
    refute Map.has_key?(by_path["README.md"], "ignored")

    assert {:ok, %{"entries" => [%{"path" => "src/deep/notes.txt"}]}} =
             Workspace.list_entries(%{"cwd" => root, "directoryPath" => "src/deep"})
  end

  test "files are read and written inside the root only", %{root: root} do
    assert {:ok, %{"contents" => "Hello World\nhello again\n", "truncated" => false}} =
             Workspace.read_file(%{"cwd" => root, "relativePath" => "./README.md"})

    for {path, failure} <- [
          {"logo.png", "binary_file"},
          {"src", "path_not_file"},
          {"../outside/secret.txt", "workspace_path_outside_root"},
          {"link.txt", "resolved_path_outside_root"}
        ] do
      assert {:error, %{"_tag" => "ProjectReadFileError", "failure" => ^failure}} =
               Workspace.read_file(%{"cwd" => root, "relativePath" => path})
    end

    assert {:ok, %{"relativePath" => "docs/new/guide.md"}} =
             Workspace.write_file(%{
               "cwd" => root,
               "relativePath" => "docs/new/guide.md",
               "contents" => "# Guide"
             })

    assert File.read!(Path.join(root, "docs/new/guide.md")) == "# Guide"

    assert {:error, %{"failure" => "workspace_path_outside_root"}} =
             Workspace.write_file(%{
               "cwd" => root,
               "relativePath" => "../escape.txt",
               "contents" => "x"
             })
  end

  for ripgrep <- ["rg", nil] do
    @tag ripgrep: ripgrep
    test "contents search literally or by regex, falling back from a bad regex (#{ripgrep || "git grep"})",
         %{root: root, ripgrep: ripgrep} do
      Application.put_env(:t3, :ripgrep, ripgrep)
      on_exit(fn -> Application.delete_env(:t3, :ripgrep) end)
      contents_search(root)
    end
  end

  defp contents_search(root) do
    search = fn query, opts ->
      Workspace.search_contents(
        Map.merge(
          %{
            "cwd" => root,
            "query" => query,
            "limit" => 50,
            "caseSensitive" => false,
            "wholeWord" => false,
            "useRegex" => false
          },
          opts
        )
      )
    end

    assert {:ok, %{"matches" => matches}} = search.("hello", %{})
    paths = matches |> Enum.map(&{&1["path"], &1["lineNumber"]}) |> Enum.sort()
    assert paths == [{"README.md", 1}, {"README.md", 2}, {"src/app.ex", 2}]

    readme = Enum.find(matches, &(&1["path"] == "README.md" and &1["lineNumber"] == 1))
    assert readme["matchRanges"] == [%{"start" => 0, "end" => 5}]

    assert {:ok, %{"matches" => [%{"path" => "README.md", "lineNumber" => 1}]}} =
             search.("hello", %{"caseSensitive" => true, "useRegex" => true, "query" => "^Hel+o"})

    assert {:ok, %{"matches" => [], "regexFallbackError" => error}} =
             search.("(unclosed", %{"useRegex" => true})

    assert is_binary(error)
  end
end
