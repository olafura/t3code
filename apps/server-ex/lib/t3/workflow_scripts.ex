defmodule T3.WorkflowScripts do
  @moduledoc """
  `orchestration.getWorkflowScript`: the script a Claude workflow ran, for the
  Agents view's script button, as the Node server serves it. The path comes from
  the client and is only a hint: the real path must be a `.js` regular file under
  `~/.claude/projects`, where Claude keeps workflow scripts, and reads stop at
  256 KB.
  """

  @cap 256 * 1024

  def read(%{"scriptPath" => requested}) do
    with :ok <-
           check(
             Path.type(requested) == :absolute and Path.extname(requested) == ".js",
             "invalid-path",
             requested
           ),
         {:ok, root} <- T3.Paths.real(root()) |> or_fail("root-unavailable", requested),
         {:ok, path} <- T3.Paths.real(requested) |> or_fail("not-found", requested),
         :ok <- check(String.starts_with?(path, root <> "/"), "outside-root", path),
         :ok <- check(Path.extname(path) == ".js", "not-js", path),
         {:ok, %File.Stat{type: :regular, size: size}} <-
           File.stat(path) |> regular(path),
         {:ok, contents} <- head(path) |> or_fail("read-failed", path) do
      {:ok, %{"scriptPath" => path, "contents" => contents, "truncated" => size > @cap}}
    end
  end

  defp root,
    do:
      Application.get_env(:t3, :workflow_scripts_root) ||
        Path.join([System.user_home!(), ".claude", "projects"])

  defp head(path) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, @cap) do
        :eof -> ""
        data -> data
      end
    end)
  end

  defp regular({:ok, %File.Stat{type: :regular}} = ok, _path), do: ok
  defp regular({:ok, _}, path), do: fail("not-regular-file", path)
  defp regular({:error, _}, path), do: fail("read-failed", path)

  defp check(true, _reason, _path), do: :ok
  defp check(false, reason, path), do: fail(reason, path)

  defp or_fail({:ok, _} = ok, _reason, _path), do: ok
  defp or_fail(_error, reason, path), do: fail(reason, path)

  defp fail(reason, path) do
    {:error,
     %{"_tag" => "OrchestrationGetWorkflowScriptError", "reason" => reason, "scriptPath" => path}}
  end
end
