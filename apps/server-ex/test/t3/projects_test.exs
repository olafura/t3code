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

  test "a project in a clone carries its repository identity", %{tmp_dir: dir} do
    root = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(root, "src"))
    {_, 0} = System.cmd("git", ["init", "-q", root])

    for {name, url} <- [
          {"origin", "git@github.com:me/Fork.git"},
          {"upstream", "https://gitlab.example.com/Acme/Widget.git"}
        ],
        do: {_, 0} = System.cmd("git", ["-C", root, "remote", "add", name, url])

    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "workspaceRoot" => Path.join(root, "src")
      })

    assert_receive {:t3_shell,
                    {:rows, _, [{"p1", {"project", %{"repositoryIdentity" => identity}}}]}},
                   5_000

    assert identity == %{
             "canonicalKey" => "gitlab.example.com/acme/widget",
             "locator" => %{
               "source" => "git-remote",
               "remoteName" => "upstream",
               "remoteUrl" => "https://gitlab.example.com/Acme/Widget.git"
             },
             "rootPath" => identity["rootPath"],
             "displayName" => "acme/widget",
             "provider" => "gitlab",
             "owner" => "acme",
             "name" => "widget"
           }

    assert Path.basename(identity["rootPath"]) == "repo"
  end

  test "remote hosts name their provider kind" do
    assert T3.Repository.provider("git@gitlab.example.com:group/sub/app.git") == "gitlab"
    assert T3.Repository.provider("git@ssh.dev.azure.com:v3/org/proj/repo") == "azure-devops"
    assert T3.Repository.provider("https://codeberg.org/me/app") == "forgejo"
    assert T3.Repository.provider("https://git.example.com/me/app") == "unknown"
    assert T3.Repository.provider("not a url") == nil
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
