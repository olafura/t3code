defmodule T3.Projection.ThreadError do
  @moduledoc """
  The error a thread shows, ported from the Node server's
  `orchestrationV2ThreadError.ts`.

  Only a failed root turn of the latest run owns the thread's failure; a provider
  session error that says something different supersedes its classification.
  """

  import T3.Projection.JS, only: [get: 2, json: 1, epoch_ms: 1]

  @doc "The `failure` of the latest failed root error item of `run`, if it failed."
  @spec latest_root_provider_failure(map | nil, [map]) :: map | nil
  def latest_root_provider_failure(run, turn_items) do
    if get(run, "status") == "failed" do
      turn_items
      |> Enum.filter(fn item ->
        get(item, "type") == "error" and get(item, "status") == "failed" and
          get(item, "runId") == get(run, "id") and get(item, "nodeId") == get(run, "rootNodeId")
      end)
      |> Enum.reduce(nil, fn item, latest ->
        if latest == nil or later?(item, latest), do: item, else: latest
      end)
      |> get("failure")
      |> json()
    end
  end

  defp later?(item, latest) do
    {epoch_ms(get(item, "updatedAt")), get(item, "ordinal"), get(item, "id")} >
      {epoch_ms(get(latest, "updatedAt")), get(latest, "ordinal"), get(latest, "id")}
  end

  @doc "The shell's `usageLimitResetAt`, `lastError` and `lastErrorClass`."
  @spec summary(map | nil, String.t() | nil) :: map
  def summary(failure, session_error) do
    current =
      if session_error != nil and session_error != get(failure, "message"), do: nil, else: failure

    %{
      "usageLimitResetAt" =>
        if(get(current, "class") == "usage_limit", do: get(current, "resetAt")),
      "lastError" => session_error || get(failure, "message"),
      "lastErrorClass" => get(current, "class")
    }
  end
end
