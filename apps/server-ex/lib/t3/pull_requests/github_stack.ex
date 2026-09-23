defmodule T3.PullRequests.GitHubStack do
  @moduledoc """
  Actions on a whole GitHub stack of pull requests, as the Node server runs them:
  merging a layer merges every open layer below it in one request, and updating
  the stack rebases each open layer onto the one below, from the bottom up. Both
  change only GitHub, never the local checkout.

  The client names the stack and the head revision of every open layer it showed
  (`expectedStackHeads`); if GitHub's stack differs, nothing is done. A rebase that
  stops partway says how many layers it finished, since those stay updated.
  """

  alias T3.PullRequests.GitHub

  @merge_deadline_ms 5 * 60_000

  @doc "Runs `merge` or `update-branch` for the stack `input` names: `:ok` or `{:error, reason}`."
  def run(ctx, input) do
    action = input["action"]

    with :ok <- check(action in ["merge", "update-branch"], :unsupported, 0, ctx),
         {:ok, stack} <- GitHub.stack(ctx, false),
         {:ok, target_index, target} <- target(stack, ctx, input),
         open = open_layers(stack, target_index, action),
         :ok <- check(action != "merge" or target["state"] == "open", :unsupported, 0, ctx),
         :ok <- check(heads_match?(open, input["expectedStackHeads"]), :changed, 0, ctx),
         :ok <-
           check(open != [] and Enum.all?(open, &(&1["state"] == "open")), :unsupported, 0, ctx) do
      if action == "update-branch",
        do: rebase(ctx, open),
        else: merge(ctx, open, target, input["mergeMethod"])
    end
  end

  defp target(stack, ctx, input) do
    layers = (stack || %{})["layers"] || []
    index = Enum.find_index(layers, &(&1["number"] == ctx.number))

    cond do
      stack == nil or stack["number"] != input["stackNumber"] or index == nil ->
        failure(:changed, 0, ctx)

      # A stack is updated from its top layer only.
      input["action"] == "update-branch" and index != length(layers) - 1 ->
        failure(:changed, 0, ctx)

      true ->
        {:ok, index, Enum.at(layers, index)}
    end
  end

  defp open_layers(stack, target_index, action) do
    layers =
      if action == "merge",
        do: Enum.take(stack["layers"], target_index + 1),
        else: stack["layers"]

    Enum.reject(layers, &(&1["state"] == "merged"))
  end

  defp heads_match?(open, expected) when is_list(expected) do
    length(expected) == length(open) and
      length(Enum.uniq_by(expected, & &1["number"])) == length(open) and
      Enum.all?(open, fn layer ->
        layer["headSha"] != nil and
          Enum.any?(
            expected,
            &(&1["number"] == layer["number"] and &1["headSha"] == layer["headSha"])
          )
      end)
  end

  defp heads_match?(_open, _expected), do: false

  # --- rebase ------------------------------------------------------------------------

  @access """
  query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { %s } }
  """
  @read """
  query($owner: String!, $name: String!, $number: Int!, $sha: String!, $processed: [ID!]!) {
    processed: nodes(ids: $processed) { ... on PullRequest { headRefOid } }
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) { id headRefOid baseRef { compare(headRef: $sha) { behindBy } } }
    }
  }
  """
  @update """
  mutation($id: ID!, $sha: GitObjectID!) {
    updatePullRequestBranch(input: {pullRequestId: $id, expectedHeadOid: $sha, updateMethod: REBASE}) {
      pullRequest { headRefOid }
    }
  }
  """

  defp rebase(ctx, open) do
    [owner, name] = String.split(ctx.repository, "/", parts: 2)

    fields =
      Enum.map_join(open, " ", fn layer ->
        "pr#{layer["number"]}: pullRequest(number: #{layer["number"]}) { headRepository { viewerPermission } maintainerCanModify }"
      end)

    with {:ok, data} <-
           read(
             GitHub.graphql(ctx, String.replace(@access, "%s", fields), %{
               "owner" => owner,
               "name" => name
             }),
             ctx
           ),
         # Updating an already-current layer is not asked about; write access to every
         # branch is checked before any layer moves.
         :ok <- check(Enum.all?(open, &writable?(data, &1)), :permission, 0, ctx) do
      open
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {layer, index}, {:ok, done} ->
        case rebase_layer(ctx, owner, name, layer, index, done) do
          {:ok, head} -> {:cont, {:ok, done ++ [head]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp writable?(data, layer) do
    case get_in(data, ["repository", "pr#{layer["number"]}"]) do
      %{"headRepository" => %{"viewerPermission" => permission}} = pr ->
        pr["maintainerCanModify"] == true or permission in ~w(ADMIN MAINTAIN WRITE)

      _ ->
        false
    end
  end

  # `done` holds the layers already handled; a push to one of them since would make it
  # the next layer's base unnoticed, so it stops the rebase.
  defp rebase_layer(ctx, owner, name, layer, index, done) do
    variables = %{
      "owner" => owner,
      "name" => name,
      "number" => layer["number"],
      "sha" => layer["headSha"],
      "processed" => Enum.map(done, & &1.id)
    }

    with {:ok, data} <- GitHub.graphql(ctx, @read, variables) |> rebase_step(ctx, layer, index),
         %{"id" => id, "headRefOid" => head, "baseRef" => %{"compare" => %{"behindBy" => behind}}} <-
           get_in(data, ["repository", "pullRequest"]) || failure(:rebase, index, ctx, layer) do
      observed = data["processed"] || []

      moved =
        Enum.find(Enum.with_index(done), fn {earlier, i} ->
          get_in(Enum.at(observed, i) || %{}, ["headRefOid"]) != earlier.head
        end)

      cond do
        moved != nil -> failure(:changed, index, ctx, elem(moved, 0).number)
        head != layer["headSha"] -> failure(:changed, index, ctx, layer["number"])
        behind == 0 -> {:ok, %{id: id, number: layer["number"], head: head}}
        true -> update_layer(ctx, id, layer, index)
      end
    end
  end

  defp update_layer(ctx, id, layer, index) do
    case GitHub.graphql(ctx, @update, %{"id" => id, "sha" => layer["headSha"]})
         |> rebase_step(ctx, layer, index) do
      {:ok, %{"updatePullRequestBranch" => %{"pullRequest" => %{"headRefOid" => head}}}} ->
        {:ok, %{id: id, number: layer["number"], head: head}}

      {:ok, _} ->
        failure(:rebase, index, ctx, layer)

      error ->
        error
    end
  end

  defp rebase_step({:ok, _} = ok, _ctx, _layer, _index), do: ok
  defp rebase_step(_error, ctx, layer, index), do: failure(:rebase, index, ctx, layer)

  # --- merge ---------------------------------------------------------------------------

  defp merge(ctx, open, target, method) do
    with :ok <- check(not Enum.any?(open, &(&1["isDraft"] == true)), :unsupported, 0, ctx),
         {:ok, result} <-
           ctx
           |> GitHub.rest_api("pulls/#{ctx.number}/merge-async",
             method: "PUT",
             input:
               JSON.encode!(%{
                 "merge_method" => method || "merge",
                 "merge_action" => "default",
                 "sha" => target["headSha"]
               })
           )
           |> read(ctx) do
      await_merge(ctx, result, System.monotonic_time(:millisecond) + @merge_deadline_ms, 0)
    end
  end

  # GitHub merges a stack asynchronously; its status is polled with backoff.
  defp await_merge(ctx, %{"status" => "pending"} = result, deadline, attempt) do
    uuid = get_in(result, ["details", "uuid"])

    cond do
      not is_binary(uuid) ->
        failure(:invalid, 0, ctx)

      System.monotonic_time(:millisecond) >= deadline ->
        failure(:pending, 0, ctx)

      true ->
        base = Application.get_env(:t3, :stack_merge_backoff_ms, 1_000)
        Process.sleep(min(base * Integer.pow(2, attempt), 10_000))

        with {:ok, next} <-
               GitHub.rest_api(
                 ctx,
                 "pulls/#{ctx.number}/merge-async/#{URI.encode_www_form(uuid)}"
               )
               |> read(ctx),
             do: await_merge(ctx, next, deadline, attempt + 1)
    end
  end

  defp await_merge(_ctx, %{"status" => status}, _deadline, _attempt)
       when status in ["merged", "enqueued"],
       do: :ok

  defp await_merge(ctx, %{"status" => "failed"}, _deadline, _attempt),
    do: failure(:rejected, 0, ctx)

  defp await_merge(ctx, _other, _deadline, _attempt), do: failure(:invalid, 0, ctx)

  # --- errors ----------------------------------------------------------------------------

  defp read({:ok, %{} = value}, _ctx), do: {:ok, value}
  defp read({:ok, _}, ctx), do: failure(:invalid, 0, ctx)
  defp read(error, _ctx), do: error

  defp check(true, _kind, _completed, _ctx), do: :ok
  defp check(false, kind, completed, ctx), do: failure(kind, completed, ctx)

  defp failure(kind, completed, ctx, layer \\ nil) do
    number =
      case layer do
        %{"number" => n} -> n
        n when is_integer(n) -> n
        _ -> ctx.number
      end

    message =
      case kind do
        :changed when completed > 0 ->
          "The stack changed at PR ##{number} after #{completed} layers. Earlier updates remain on GitHub. Refresh it before trying again."

        :changed ->
          "The stack changed. Refresh it before trying again."

        :unsupported ->
          "This operation is not supported for this stack."

        :invalid ->
          "GitHub returned an unreadable stack operation response."

        :rejected ->
          "GitHub refused the stack merge. Check the stack's branch rules and merge requirements."

        :pending ->
          "The merge is still running on GitHub. Check its status there before submitting another request."

        :permission ->
          "You cannot update every branch in this stack. Check write access and fork maintainer permissions before retrying."

        :rebase ->
          "Stack rebase stopped at PR ##{number} after #{completed} layers. Earlier updates remain on GitHub; resolve the failing layer before retrying."
      end

    {:error, {:failed, message}}
  end
end
