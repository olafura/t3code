defmodule T3.Streams do
  @moduledoc """
  Runs one `T3.Streams.Server` per active stream on this node.

  A stream process starts on first use and stops after it has been idle with no
  subscribers, so inactive threads cost nothing but a row in the shell index.
  """

  use Supervisor

  alias T3.Streams.Server

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: T3.Streams.Registry},
        {DynamicSupervisor, name: T3.Streams.Supervisor, strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end

  @doc "The stream's server, started if needed."
  @spec ensure(String.t()) :: pid
  def ensure(stream_id) do
    case Registry.lookup(T3.Streams.Registry, stream_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(T3.Streams.Supervisor, {Server, stream_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @doc """
  Subscribes `pid` to a stream. Delivers either the full state or, when `offset` is
  recent enough, only the events after it; see `T3.Streams.Server.subscribe/3`.
  """
  defdelegate subscribe(stream_id, pid, offset), to: Server
  defdelegate unsubscribe(stream_id, pid), to: Server

  @doc "Commits changes to a stream and fans them out to its subscribers."
  @spec commit(String.t(), T3.Store.stream_kind(), [T3.Store.change()]) :: {:ok, non_neg_integer}
  def commit(stream_id, stream_kind, changes),
    do: stream_id |> ensure() |> Server.commit(stream_kind, changes)
end
