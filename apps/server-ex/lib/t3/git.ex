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

  defp exit_code({:status, code}), do: code
  defp exit_code(other), do: other
end
