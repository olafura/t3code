defmodule T3.Antigravity.ClientFiles do
  @moduledoc """
  The ACP client file system (`fs/read_text_file`, `fs/write_text_file`) T3 offers
  Antigravity in chat sessions. The agent then reads and writes the workspace
  through T3, asking `session/request_permission` (with the new content) before
  each edit, so only containment is checked here: a path must resolve, symlinks
  followed, inside one of the session's roots (its cwd and the attachments folder).
  Results are JSON-RPC results or errors.
  """

  alias T3.Antigravity.Files

  @max_bytes 8 * 1024 * 1024

  @doc "`fs/read_text_file`: the file's text, or its `line` (1-based) and `limit` lines."
  def read(roots, %{"path" => requested} = params) when is_binary(requested) do
    with {:ok, path} <- resolve(roots, requested) do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
          case File.read(path) do
            {:ok, text} -> {:ok, %{"content" => slice(text, params["line"], params["limit"])}}
            _ -> {:error, %{"code" => -32603, "message" => "Could not read '#{requested}'."}}
          end

        {:ok, _} ->
          invalid("File '#{requested}' is not a readable text file under #{@max_bytes} bytes.")

        _ ->
          {:error, %{"code" => -32002, "message" => "File '#{requested}' not found."}}
      end
    end
  end

  def read(_roots, _params), do: invalid("A path is required.")

  @doc "`fs/write_text_file`: writes `content`, creating directories as needed."
  def write(roots, %{"path" => requested, "content" => content} = _params)
      when is_binary(requested) and is_binary(content) do
    with {:ok, path} <- resolve(roots, requested) do
      with :ok <- File.mkdir_p(Path.dirname(path)), :ok <- File.write(path, content) do
        {:ok, %{}}
      else
        _ -> {:error, %{"code" => -32603, "message" => "Could not write '#{requested}'."}}
      end
    end
  end

  def write(_roots, _params), do: invalid("A path and content are required.")

  # The parent's symlinks are followed, so a link cannot lead out of the workspace.
  defp resolve(roots, requested) do
    expanded = Path.expand(requested)

    parent =
      case Files.realpath(Path.dirname(expanded)) do
        {:ok, real} -> real
        _ -> Path.dirname(expanded)
      end

    real = Path.join(parent, Path.basename(expanded))

    roots =
      for root <- roots,
          do:
            (case Files.realpath(root) do
               {:ok, real} -> real
               _ -> Path.expand(root)
             end)

    if Enum.any?(roots, &Files.inside?(real, &1)),
      do: {:ok, real},
      else: invalid("Path '#{requested}' is outside the session workspace.")
  end

  defp slice(text, nil, nil), do: text

  defp slice(text, line, limit) do
    lines = String.split(text, "\n")
    start = max(0, if(is_integer(line), do: line, else: 1) - 1)

    lines
    |> Enum.drop(start)
    |> then(&if(is_integer(limit), do: Enum.take(&1, limit), else: &1))
    |> Enum.join("\n")
  end

  defp invalid(message), do: {:error, %{"code" => -32602, "message" => message}}
end
