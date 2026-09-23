defmodule T3.Subprocess do
  @moduledoc """
  Line-framed subprocess I/O for a GenServer that owns an external program.

  The calling process owns the program and its stdin. A linked reader process owns
  stdout, splits it into lines and sends them to the owner as
  `{:subprocess_lines, reader, lines}`. It does not read again until the owner calls
  `ack/1`, so a flood of output backs up in the OS pipe instead of the mailbox. When
  stdout closes the owner receives `{:subprocess_eof, reader}`; the exit status then
  arrives through Exile as `{exit_ref, {:ok, status}}`.

  Reader loops recurse through fully qualified calls, so a hot code load moves them
  onto the new module version at the next chunk.
  """

  alias Exile.Process, as: Proc

  @enforce_keys [:proc, :reader]
  defstruct [:proc, :reader]

  @type t :: %__MODULE__{proc: Proc.t(), reader: pid}

  @read_size 65_535

  @spec start([String.t()], keyword) :: {:ok, t} | {:error, term}
  def start(cmd, opts \\ []) do
    with {:ok, proc} <- Proc.start_link(cmd, Keyword.put_new(opts, :stderr, :disable)) do
      owner = self()
      reader = spawn_link(fn -> reader_init(proc, owner) end)
      :ok = Proc.change_pipe_owner(proc, :stdout, reader)
      send(reader, :owned)
      {:ok, %__MODULE__{proc: proc, reader: reader}}
    end
  end

  @spec write_line(t, iodata) :: :ok | {:error, term}
  def write_line(%__MODULE__{proc: proc}, line), do: Proc.write(proc, [line, ?\n])

  @spec ack(t) :: :ok
  def ack(%__MODULE__{reader: reader}) do
    send(reader, :ack)
    :ok
  end

  @spec os_pid(t) :: pos_integer
  def os_pid(%__MODULE__{proc: proc}) do
    {:ok, pid} = Proc.os_pid(proc)
    pid
  end

  @doc "Closes stdin and waits for the program to exit, escalating to signals after `timeout`."
  @spec stop(t, timeout) :: {:ok, non_neg_integer} | term
  def stop(%__MODULE__{proc: proc}, timeout \\ 2_000) do
    Proc.close_stdin(proc)
    Proc.await_exit(proc, timeout)
  end

  @doc false
  def reader_init(proc, owner) do
    receive do: (:owned -> :ok)
    __MODULE__.reader_loop(proc, owner, "")
  end

  @doc false
  def reader_loop(proc, owner, partial) do
    case Proc.read(proc, @read_size) do
      {:ok, data} ->
        {lines, rest} = split_lines(partial <> IO.iodata_to_binary(data))

        if lines != [] do
          send(owner, {:subprocess_lines, self(), lines})
          receive do: (:ack -> :ok)
        end

        __MODULE__.reader_loop(proc, owner, rest)

      _eof_or_error ->
        if partial != "", do: send(owner, {:subprocess_lines, self(), [partial]})
        send(owner, {:subprocess_eof, self()})
    end
  end

  # Lines are copied so a retained line never pins the whole read chunk.
  @doc false
  def split_lines(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [rest] ->
        {[], rest}

      parts ->
        {lines, [rest]} = Enum.split(parts, -1)
        {for(l <- lines, l != "", do: :binary.copy(l)), :binary.copy(rest)}
    end
  end
end
