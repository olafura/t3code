defmodule T3.Secrets do
  @moduledoc """
  Small secrets kept owner-only in `<home>/secrets/<name>.bin`, named as the Node
  server names them, so a T3 home moved between the two keeps its T3 Connect link.
  """

  @doc "The secret's bytes, or nil."
  @spec get(String.t()) :: binary | nil
  def get(name) do
    case File.read(path(name)) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc "Stores `value`, replacing any earlier one."
  @spec put(String.t(), binary) :: :ok
  def put(name, value) do
    path = path(name)
    tmp = path <> ".tmp"
    File.write!(tmp, value)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  @doc "Stores `value` only when no secret of that name exists: `:ok` or `:exists`."
  @spec create(String.t(), binary) :: :ok | :exists
  def create(name, value) do
    path = path(name)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        IO.binwrite(file, value)
        File.close(file)
        File.chmod!(path, 0o600)
        :ok

      {:error, :eexist} ->
        :exists
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(name) do
    File.rm(path(name))
    :ok
  end

  defp path(name) do
    dir = Path.join(Application.fetch_env!(:t3, :home), "secrets")

    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    Path.join(dir, "#{name}.bin")
  end
end
