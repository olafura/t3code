defmodule T3.AutoPullTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!(T3.Settings)
    start_supervised!({Registry, keys: :unique, name: T3.Vcs.Registry})

    origin = Path.join(dir, "origin.git")
    other = Path.join(dir, "other")
    repo = Path.join(dir, "repo")
    git(dir, ~w(init -q --bare -b main) ++ [origin])
    git(dir, ["clone", "-q", origin, other])
    commit(other, "first")
    git(other, ~w(push -q origin main))
    git(dir, ["clone", "-q", origin, repo])
    # Someone else pushes after this checkout was made.
    commit(other, "second")
    git(other, ~w(push -q origin main))

    :ok = T3.Shell.subscribe(self())

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Repo",
        "workspaceRoot" => repo
      })

    assert_receive {:t3_shell, {:rows, _, [{"p1", _}]}}, 2_000
    %{repo: repo}
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

  defp commit(cwd, message) do
    File.write!(Path.join(cwd, "#{message}.txt"), message)
    git(cwd, ~w(add .))
    git(cwd, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
  end

  defp head_message(repo) do
    {out, 0} = System.cmd("git", ~w(log -1 --format=%s), cd: repo)
    String.trim(out)
  end

  test "a project that asks for it is pulled at boot; others are left alone", %{repo: repo} do
    :ok = T3.Projects.auto_pull()
    assert head_message(repo) == "first"

    {_, version} = T3.Settings.get()

    {:ok, _} =
      T3.Settings.put(
        %{"projectSettingsOverrides" => %{"p1" => %{"defaultAutoPull" => true}}},
        version
      )

    # Local changes keep the checkout as it is.
    File.write!(Path.join(repo, "first.txt"), "edited")
    :ok = T3.Projects.auto_pull()
    assert head_message(repo) == "first"

    git(repo, ~w(checkout -q -- first.txt))
    :ok = T3.Projects.auto_pull()
    assert head_message(repo) == "second"
  end
end
