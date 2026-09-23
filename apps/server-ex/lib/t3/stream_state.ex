defmodule T3.StreamState do
  @moduledoc """
  The folded state of one stream: every entity by kind and id, plus the last `seq`
  applied. It is plain data, so it can be snapshotted with `term_to_binary` and
  migrated by a pure function when its shape changes.

  `created` records the seq at which each entity first appeared, which is the order
  lists such as runs and turn items are presented in. `updated_at` is the time of the
  latest event that was activity (unix ms); quiet patches such as visits do not move it.
  """

  alias T3.Patch

  @version 2

  defstruct v: @version, seq: 0, updated_at: nil, entities: %{}, created: %{}

  @type t :: %__MODULE__{
          v: pos_integer,
          seq: non_neg_integer,
          updated_at: integer | nil,
          entities: %{String.t() => %{String.t() => Patch.entity()}},
          created: %{{String.t(), String.t()} => non_neg_integer}
        }

  @spec new() :: t
  def new, do: %__MODULE__{}

  @spec apply_event(t, T3.Store.event()) :: t
  def apply_event(
        %__MODULE__{} = state,
        %{seq: seq, kind: kind, entity: id, patch: patch} = event
      ) do
    by_id = Map.get(state.entities, kind, %{})
    updated_at = if patch["q"] == true, do: state.updated_at, else: event[:at] || state.updated_at
    state = %{state | seq: seq, updated_at: updated_at}

    case Patch.apply(Map.get(by_id, id), patch) do
      nil ->
        # A deleted entity that comes back is appended again, as in the Node projection.
        %{
          state
          | entities: put_kind(state.entities, kind, Map.delete(by_id, id)),
            created: Map.delete(state.created, {kind, id})
        }

      entity ->
        %{
          state
          | entities: Map.put(state.entities, kind, Map.put(by_id, id, entity)),
            created: Map.put_new(state.created, {kind, id}, seq)
        }
    end
  end

  defp put_kind(entities, kind, by_id) when map_size(by_id) == 0, do: Map.delete(entities, kind)
  defp put_kind(entities, kind, by_id), do: Map.put(entities, kind, by_id)

  @doc "Every entity as `{kind, id, entity}`, in the order they were created."
  @spec rows(t) :: [{String.t(), String.t(), Patch.entity()}]
  def rows(state) do
    for({kind, by_id} <- state.entities, {id, entity} <- by_id, do: {kind, id, entity})
    |> Enum.sort_by(fn {kind, id, _} -> Map.get(state.created, {kind, id}, 0) end)
  end

  @doc "A kind's entities in the order they were created."
  @spec list(t, String.t()) :: [Patch.entity()]
  def list(state, kind) do
    state
    |> get(kind)
    |> Enum.sort_by(fn {id, _} -> Map.get(state.created, {kind, id}, 0) end)
    |> Enum.map(&elem(&1, 1))
  end

  @spec get(t, String.t()) :: %{String.t() => Patch.entity()}
  def get(state, kind), do: Map.get(state.entities, kind, %{})

  @doc "Folds a stream from its snapshot (if any) plus the events after it."
  @spec load(String.t(), String.t()) :: t
  def load(path, stream_id) do
    {after_seq, state} =
      case T3.Store.get_snapshot(path, stream_id) do
        {seq, %__MODULE__{} = snapshot} -> {seq, migrate(snapshot)}
        nil -> {0, new()}
      end

    T3.Store.reduce_stream(path, stream_id, after_seq, state, &apply_event(&2, &1))
  end

  @doc "Brings a snapshot written by an older version up to the current shape."
  @spec migrate(t) :: t
  def migrate(%__MODULE__{v: @version} = state), do: state

  # v1 had no creation order; fall back to entity id order.
  def migrate(%__MODULE__{v: 1} = state),
    do: migrate(%{struct(__MODULE__, Map.from_struct(state)) | v: 2, created: %{}})
end
