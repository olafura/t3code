defmodule T3.Editors do
  @moduledoc """
  Editors this host can open a workspace in (`availableEditors`), and opening one
  (`shell.openInEditor`). The ids and launch styles mirror `EDITORS` in
  `packages/contracts/src/editor.ts`.
  """

  # {id, commands, base args, how a `path:line:column` target is passed}
  @editors [
    {"cursor", ["cursor"], ["--classic"], :goto},
    {"trae", ["trae"], [], :goto},
    {"kiro", ["kiro"], ["ide"], :goto},
    {"vscode", ["code"], [], :goto},
    {"vscode-insiders", ["code-insiders"], [], :goto},
    {"vscodium", ["codium"], [], :goto},
    {"zed", ["zed", "zeditor"], [], :direct_path},
    {"antigravity", ["agy"], [], :goto},
    {"idea", ["idea"], [], :line_column},
    {"aqua", ["aqua"], [], :line_column},
    {"clion", ["clion"], [], :line_column},
    {"datagrip", ["datagrip"], [], :line_column},
    {"dataspell", ["dataspell"], [], :line_column},
    {"goland", ["goland"], [], :line_column},
    {"phpstorm", ["phpstorm"], [], :line_column},
    {"pycharm", ["pycharm"], [], :line_column},
    {"rider", ["rider"], [], :line_column},
    {"rubymine", ["rubymine"], [], :line_column},
    {"rustrover", ["rustrover"], [], :line_column},
    {"webstorm", ["webstorm"], [], :line_column}
  ]

  @doc "The ids of the editors installed here, the file manager last."
  def available do
    installed =
      for {id, commands, _, _} <- @editors, Enum.any?(commands, &System.find_executable/1), do: id

    if file_manager(), do: installed ++ ["file-manager"], else: installed
  end

  @doc "Opens `cwd` (optionally `path:line[:column]`) in an editor, without waiting for it."
  def open(%{"cwd" => target, "editor" => "file-manager"} = input) do
    case {file_manager(), input["reveal"]} do
      {nil, _} ->
        {:error,
         %{"_tag" => "ExternalLauncherUnsupportedEditorError", "editor" => "file-manager"}}

      {"open", true} ->
        launch("open", ["-R", target])

      {command, _} ->
        launch(command, [target])
    end
  end

  def open(%{"cwd" => target, "editor" => id}) do
    case List.keyfind(@editors, id, 0) do
      nil ->
        {:error, %{"_tag" => "ExternalLauncherUnknownEditorError", "editor" => id}}

      {_, commands, base, style} ->
        case Enum.find_value(commands, &System.find_executable/1) do
          nil ->
            {:error,
             %{
               "_tag" => "ExternalLauncherCommandNotFoundError",
               "editor" => id,
               "command" => hd(commands)
             }}

          command ->
            launch(command, base ++ args(style, target))
        end
    end
  end

  defp args(style, target) do
    case {style, Regex.run(~r/^(.*?):(\d+)(?::(\d+))?$/, target)} do
      {:goto, [_ | _]} -> ["--goto", target]
      {:line_column, [_, path, line]} -> ["--line", line, path]
      {:line_column, [_, path, line, column]} -> ["--line", line, "--column", column, path]
      _ -> [target]
    end
  end

  defp file_manager do
    case :os.type() do
      {:unix, :darwin} ->
        "open"

      {:win32, _} ->
        "explorer"

      _ ->
        if (System.get_env("DISPLAY") || System.get_env("WAYLAND_DISPLAY")) &&
             System.find_executable("xdg-open"),
           do: "xdg-open"
    end
  end

  # Editor CLIs hand off to the app and return; nothing waits on them.
  defp launch(command, args) do
    Task.start(fn -> System.cmd(command, args, stderr_to_stdout: true) end)
    {:ok, nil}
  end
end
