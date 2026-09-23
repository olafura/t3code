defmodule T3.Git do
  @moduledoc """
  Runs git for checkpoints and review diffs. Output past `:max_bytes` is dropped
  and reported as truncated, so a huge diff never lands in memory whole.
  """

  @type result :: %{status: integer | term, out: binary, err: binary, truncated: boolean}

  @doc """
  Runs `git args` in `cwd`. Options: `:env` (`[{name, value}]`), `:input` (stdin),
  and `:max_bytes` (default 50 MB). Fails only when git cannot be started.
  """
  @spec run(Path.t(), [String.t()], keyword) :: {:ok, result} | {:error, String.t()}
  def run(cwd, args, opts \\ []) do
    max = Keyword.get(opts, :max_bytes, 50_000_000)

    exile_opts =
      [cd: cwd, env: Keyword.get(opts, :env, []), stderr: :consume, ignore_epipe: true] ++
        if(input = opts[:input], do: [input: [input]], else: [])

    {out, err, size, status} =
      ["git" | args]
      |> Exile.stream(exile_opts)
      |> Enum.reduce({[], [], 0, nil}, fn
        {:stdout, data}, {out, err, size, status} when size < max ->
          {[out, data], err, size + IO.iodata_length(data), status}

        {:stdout, data}, {out, err, size, status} ->
          {out, err, size + IO.iodata_length(data), status}

        {:stderr, data}, {out, err, size, status} ->
          {out, [err, data], size, status}

        {:exit, status}, {out, err, size, _} ->
          {out, err, size, status}
      end)

    out = IO.iodata_to_binary(out)

    {:ok,
     %{
       status: exit_code(status),
       out: binary_part(out, 0, min(byte_size(out), max)),
       err: IO.iodata_to_binary(err),
       truncated: size > max
     }}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Runs git and returns its stdout when it exits 0."
  @spec ok(Path.t(), [String.t()], keyword) :: {:ok, binary} | {:error, term}
  def ok(cwd, args, opts \\ []) do
    case run(cwd, args, opts) do
      {:ok, %{status: 0, out: out}} -> {:ok, out}
      {:ok, %{status: status, err: err}} -> {:error, {status, String.trim(err)}}
      error -> error
    end
  end

  @doc "The checked-out branch, or nil when HEAD is detached."
  def current_branch(root) do
    case ok(root, ~w(symbolic-ref --short -q HEAD)) do
      {:ok, branch} -> String.trim(branch) |> then(&if(&1 == "", do: nil, else: &1))
      _ -> nil
    end
  end

  @doc """
  The branch this one merges into: its gh-merge-base, the remote's default
  branch, then main or master; remote-tracking refs preferred.
  """
  def base_branch(root, branch) do
    configured = git_line(root, ["config", "--get", "branch.#{branch}.gh-merge-base"])
    remote = primary_remote(root)

    default =
      remote &&
        case git_line(root, ["symbolic-ref", "refs/remotes/#{remote}/HEAD"]) do
          "refs/remotes/" <> rest -> String.replace_prefix(rest, "#{remote}/", "")
          _ -> nil
        end

    [configured, default, "main", "master"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(fn candidate ->
      candidate
      |> String.replace_prefix("origin/", "")
      |> then(
        &if(remote && remote != "origin",
          do: String.replace_prefix(&1, "#{remote}/", ""),
          else: &1
        )
      )
    end)
    |> Enum.reject(&(&1 == "" or &1 == branch))
    |> Enum.find_value(fn candidate ->
      cond do
        remote && ref?(root, "refs/remotes/#{remote}/#{candidate}") -> "#{remote}/#{candidate}"
        ref?(root, "refs/heads/#{candidate}") -> candidate
        true -> nil
      end
    end)
  end

  @doc "`origin` when it exists, else the first remote, or nil."
  def primary_remote(root) do
    case ok(root, ["remote"]) do
      {:ok, out} ->
        remotes = String.split(out, "\n", trim: true)
        if "origin" in remotes, do: "origin", else: List.first(remotes)

      _ ->
        nil
    end
  end

  defp ref?(root, ref),
    do: match?({:ok, _}, ok(root, ["show-ref", "--verify", "--quiet", ref]))

  defp git_line(root, args) do
    case ok(root, args) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  defp exit_code({:status, code}), do: code
  defp exit_code(other), do: other
end
