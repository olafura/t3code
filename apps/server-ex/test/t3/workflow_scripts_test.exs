defmodule T3.WorkflowScriptsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "projects")
    File.mkdir_p!(Path.join(root, "p"))
    Application.put_env(:t3, :workflow_scripts_root, root)
    on_exit(fn -> Application.delete_env(:t3, :workflow_scripts_root) end)
    %{root: root, dir: dir}
  end

  defp read(path), do: T3.WorkflowScripts.read(%{"scriptPath" => path})

  test "a script under the root is served, a big one cut short", %{root: root} do
    script = Path.join([root, "p", "run.js"])
    File.write!(script, "export default 1\n")
    assert {:ok, %{"contents" => "export default 1\n", "truncated" => false}} = read(script)

    File.write!(script, String.duplicate("x", 300 * 1024))
    assert {:ok, %{"contents" => contents, "truncated" => true}} = read(script)
    assert byte_size(contents) == 256 * 1024
  end

  test "paths outside the root, symlinks out of it, and other files are refused",
       %{root: root, dir: dir} do
    outside = Path.join(dir, "secret.js")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join([root, "p", "link.js"]))

    assert {:error, %{"reason" => "outside-root"}} = read(outside)
    assert {:error, %{"reason" => "outside-root"}} = read(Path.join([root, "p", "link.js"]))
    assert {:error, %{"reason" => "invalid-path"}} = read("relative/run.js")
    assert {:error, %{"reason" => "invalid-path"}} = read(Path.join([root, "p", "notes.txt"]))
    assert {:error, %{"reason" => "not-found"}} = read(Path.join([root, "p", "gone.js"]))
  end
end
