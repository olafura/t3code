defmodule T3.Paths do
  @moduledoc "Path helpers that must agree across modules that guard the filesystem."

  @doc """
  The path with every symlink resolved, `{:ok, real}` when it exists, or
  `{:error, reason}`. For containment checks: compare real paths, never the
  requested ones.
  """
  def real(path), do: resolve(Path.split(Path.expand(path)), "/", 0)

  defp resolve(_parts, _acc, links) when links > 40, do: {:error, :eloop}

  defp resolve([], acc, _links) do
    if File.exists?(acc), do: {:ok, acc}, else: {:error, :enoent}
  end

  defp resolve(["/" | rest], acc, links), do: resolve(rest, acc, links)

  defp resolve([part | rest], acc, links) do
    next = Path.join(acc, part)

    case :file.read_link_all(next) do
      {:ok, target} ->
        resolve(Path.split(Path.expand(to_string(target), acc)) ++ rest, "/", links + 1)

      {:error, :einval} ->
        resolve(rest, next, links)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
