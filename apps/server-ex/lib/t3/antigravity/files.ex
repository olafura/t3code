defmodule T3.Antigravity.Files do
  @moduledoc "Path helpers for the Antigravity modules: symlink-free paths and containment."

  @doc """
  The path with every symlink resolved, like `realpath(3)`: `{:ok, path}`, or
  `{:error, reason}` when a component is missing or links loop.
  """
  def realpath(path), do: resolve(Path.split(Path.expand(path)), [], 0)

  defp resolve([], acc, _depth), do: {:ok, Path.join(Enum.reverse(acc))}
  defp resolve(_segments, _acc, depth) when depth > 40, do: {:error, :eloop}

  defp resolve([segment | rest], acc, depth) do
    current = Path.join(Enum.reverse([segment | acc]))

    case File.read_link(current) do
      {:ok, target} ->
        parent = if acc == [], do: "/", else: Path.join(Enum.reverse(acc))
        resolve(Path.split(Path.expand(target, parent)) ++ rest, [], depth + 1)

      {:error, :einval} ->
        resolve(rest, [segment | acc], depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether `path` is `root` or inside it (both already absolute and resolved)."
  def inside?(path, root),
    do: path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")
end
