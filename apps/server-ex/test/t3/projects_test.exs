defmodule T3.ProjectsTest do
  use ExUnit.Case, async: false

  alias T3.Projects

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    :ok
  end

  test "a project is created, renamed, and deleted, and its sidebar row follows", %{tmp_dir: dir} do
    :ok = T3.Shell.subscribe(self())
    root = Path.join(dir, "app")

    assert {:error, _} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "p1",
               "workspaceRoot" => root
             })

    assert {:ok, %{"id" => "p1", "title" => "app", "deletedAt" => nil}} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "p1",
               "workspaceRoot" => root,
               "createWorkspaceRootIfMissing" => true
             })

    assert File.dir?(root)
    assert_receive {:t3_shell, {:rows, _, [{"p1", {"project", %{"title" => "app"}}}]}}, 1_000

    # Results are complete `Project`s, null fields included.
    assert {:ok, %{"title" => "Renamed", "deletedAt" => nil, "scripts" => []}} =
             Projects.mutate(%{
               "type" => "project.update",
               "projectId" => "p1",
               "title" => "Renamed"
             })

    assert_receive {:t3_shell, {:rows, _, [{"p1", {"project", %{"title" => "Renamed"}}}]}}, 1_000

    assert {:ok, %{"deletedAt" => deleted}} =
             Projects.mutate(%{"type" => "project.delete", "projectId" => "p1"})

    assert deleted

    assert_receive {:t3_shell, {:rows, _, [{"p1", {"project", %{"deletedAt" => ^deleted}}}]}},
                   1_000
  end

  test "browse lists matching folders, hiding dot-folders unless asked", %{tmp_dir: dir} do
    for name <- ~w(alpha alps beta .hidden), do: File.mkdir_p!(Path.join(dir, name))
    File.write!(Path.join(dir, "alpine.txt"), "")

    assert {:ok, %{"entries" => entries}} =
             Projects.browse(%{"partialPath" => Path.join(dir, "al")})

    assert Enum.map(entries, & &1["name"]) == ~w(alpha alps)

    assert {:ok, %{"entries" => all}} = Projects.browse(%{"partialPath" => dir <> "/"})
    assert ".hidden" in Enum.map(all, & &1["name"])
  end
end
