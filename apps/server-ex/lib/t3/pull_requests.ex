defmodule T3.PullRequests do
  @moduledoc """
  Pull requests for this node's projects (`pullRequests.*`), as the Node server's
  `PullRequestService` serves them. A project's repository is its checkout's primary
  remote; GitHub repositories are read and changed through `gh`
  (`T3.PullRequests.GitHub`). Projects on other hosts are counted in the listing and
  otherwise answered with `PullRequestUnavailableError` (`provider-unsupported`).

  A reference names a project and a repository. The project's own repository is
  served through its checkout; one that also names a `host` may point at any
  repository on that host, served through a checkout there.

  Only who is signed in to each host is cached. Every change made here bumps
  `T3.PullRequests.Refreshes`, which clients follow to read again.
  """

  alias T3.PullRequests.{GitHub, Refreshes}

  @default_limit 99
  @viewer_ttl 600_000
  @viewers {__MODULE__, :viewers}

  @requirements %{
    missing:
      "GitHub CLI (`gh`) is required to browse change requests on this host. Install it from https://cli.github.com/ and reload.",
    unauthenticated: "GitHub CLI is not authenticated. Run `gh auth login` and retry."
  }

  @action_refusals %{
    "merge" => "You need write access on this repository to merge.",
    "ready" =>
      "You need write access on this repository, or to have opened this change request, to mark it ready for review.",
    "draft" =>
      "You need write access on this repository, or to have opened this change request, to return it to a draft.",
    "close" =>
      "You need write access on this repository, or to have opened this change request, to close it.",
    "update-branch" =>
      "You need write access on this repository, or to have opened this change request, to update its branch.",
    "reopen" =>
      "You need write access on this repository, or to have opened this change request, to reopen it.",
    "enable-auto-merge" =>
      "You need write access on this repository to have it merged for you once it is ready.",
    "disable-auto-merge" =>
      "You need write access on this repository to stop it being merged for you once it is ready.",
    "revert" => "You need write access on this repository to open a revert pull request.",
    "approve-workflows" =>
      "You need write access on this repository to approve workflows from a fork pull request."
  }

  @verdict_labels %{
    "comment" => "review",
    "approve" => "approve",
    "request-changes" => "request changes on"
  }

  @reviewer_refusal "You need write access on this repository to ask for a review."
  @label_refusal "You need triage access on this repository to change its labels."

  @methods %{
    "list" => :list,
    "listStats" => :list_stats,
    "summary" => :summary,
    "routing" => :routing,
    "routingIdentity" => :routing_identity,
    "stack" => :stack,
    "linkedThreads" => :linked_threads,
    "detail" => :detail,
    "preview" => :preview,
    "checks" => :checks,
    "activity" => :activity,
    "threadComments" => :thread_comments,
    "diffFileContents" => :diff_file_contents,
    "filesViewed" => :files_viewed,
    "setFilesViewed" => :set_files_viewed,
    "runAction" => :run_action,
    "update" => :update,
    "comment" => :comment,
    "updateComment" => :update_comment,
    "submitReview" => :submit_review,
    "replyToThread" => :reply_to_thread,
    "setThreadResolution" => :set_thread_resolution,
    "setReaction" => :set_reaction,
    "invalidate" => :invalidate,
    "reviewerCandidates" => :reviewer_candidates,
    "requestReviewers" => :request_reviewers,
    "labelCandidates" => :label_candidates,
    "setLabels" => :set_labels
  }

  @doc "Serves `pullRequests.<method>` (`T3.Rpc`)."
  def handle(method, input) do
    case @methods[method] do
      nil -> {:error, "pullRequests.#{method} is not served by this node yet"}
      fun -> apply(__MODULE__, fun, [input])
    end
  end

  # --- listing ----------------------------------------------------------------------

  @doc """
  `pullRequests.list`: each GitHub repository read at once, newest update first. A
  repository that could not be read is an entry in `errors` rather than a failure,
  unless no host the listing covers can be read at all.
  """
  def list(input) do
    with {:ok, cursors} <- decode_cursors(input["cursors"]) do
      {github, others} = input |> workspace() |> Enum.split_with(&(&1.kind == "github"))

      identities =
        github
        |> Enum.uniq_by(& &1.host)
        |> Task.async_stream(&{&1.host, identity(&1)}, timeout: :infinity)
        |> Map.new(fn {:ok, pair} -> pair end)

      viewers = for {host, {:ok, %{"login" => login}}} <- identities, into: %{}, do: {host, login}
      counts = Enum.frequencies_by(github, & &1.host)

      providers =
        for({host, identity} <- identities, do: provider(host, counts[host], identity)) ++
          for {host, [first | _] = on_host} <- Enum.group_by(others, & &1.host) do
            %{
              "host" => host,
              "kind" => first.kind,
              "searchesOnHost" => false,
              "projectCount" => length(on_host),
              "configured" => false,
              "detail" => "This host cannot be browsed here yet."
            }
          end

      selected =
        if cursors, do: Enum.filter(github, &Map.has_key?(cursors, key(&1))), else: github

      {readable, unreadable} = Enum.split_with(selected, &Map.has_key?(viewers, &1.host))
      result = %{"viewers" => viewers, "providers" => providers}

      if readable == [] do
        failures =
          for p <- Enum.uniq_by(selected, & &1.host), {:error, e} <- [identities[p.host]], do: e

        case Enum.find(failures, &(elem(&1, 0) in [:missing, :unauthenticated])) ||
               List.first(failures) do
          nil ->
            {:ok,
             Map.merge(result, %{
               "entries" => [],
               "errors" => [],
               "truncated" => false,
               "nextCursors" => %{}
             })}

          failure ->
            provider_error("list", failure)
        end
      else
        batches =
          readable
          |> Task.async_stream(
            &read_repository(&1, viewers[&1.host], input, cursors && cursors[key(&1)]),
            max_concurrency: 12,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, batch} -> batch end)

        {:ok,
         Map.merge(result, %{
           "entries" =>
             batches |> Enum.flat_map(& &1.entries) |> Enum.sort_by(& &1["updatedAt"], :desc),
           "errors" => Enum.map(unreadable, &unreadable/1) ++ Enum.flat_map(batches, & &1.errors),
           "truncated" => Enum.any?(batches, & &1.truncated),
           "nextCursors" => for(b <- batches, b.next, into: %{}, do: {b.key, b.next})
         })}
      end
    end
  end

  defp provider(host, count, identity) do
    %{
      "host" => host,
      "kind" => "github",
      "searchesOnHost" => true,
      "projectCount" => count,
      "configured" => match?({:ok, _}, identity),
      "detail" =>
        case identity do
          {:ok, _} -> nil
          {:error, {reason, detail}} -> @requirements[reason] || detail
        end
    }
  end

  defp read_repository(project, viewer, input, cursor) do
    opts = %{
      state: input["state"] || "open",
      involvement: input["involvement"] || "all",
      viewer: viewer,
      limit: input["limit"] || @default_limit,
      query: input["query"],
      filters: input["filters"],
      cursor: cursor
    }

    case GitHub.list(ctx(project, nil), opts) do
      {:ok, page} ->
        at = System.system_time(:millisecond)

        # The boundary instant is asked for inclusively, so the rows already sent at
        # it come back and are dropped here.
        items =
          if cursor,
            do:
              Enum.reject(
                page.items,
                &(&1["updatedAt"] == cursor.boundary and &1["number"] in cursor.seen)
              ),
            else: page.items

        %{
          key: key(project),
          entries:
            for(
              item <- items,
              GitHub.row_match?(item, input["filters"], viewer, false),
              do: entry(project, item, viewer, at)
            ),
          errors: [],
          truncated: page.truncated,
          next:
            if(page.sorted and page.truncated, do: next_cursor(cursor, page.items, length(items)))
        }

      {:error, _} ->
        %{
          key: key(project),
          entries: [],
          errors: [unreadable(project)],
          truncated: false,
          next: nil
        }
    end
  end

  defp unreadable(project),
    do: %{
      "projectId" => project.id,
      "projectTitle" => project.title,
      "message" => "#{project.repository} could not be read."
    }

  defp entry(project, item, viewer, at) do
    me = String.downcase(viewer)
    author = item["author"] && String.downcase(item["author"]["login"])

    item
    |> Map.take(
      ~w(number title url headBranch baseBranch state isDraft mergeability additions deletions createdAt updatedAt labels)
    )
    |> Map.merge(%{
      "provider" => "github",
      "host" => project.host,
      "projectId" => project.id,
      "projectTitle" => project.title,
      "repository" => project.repository,
      "author" => GitHub.with_avatar(item["author"], project.host),
      "observedAt" => at,
      "viewerReviewRequested" =>
        author != me and Enum.any?(item["reviewRequestLogins"], &(String.downcase(&1) == me))
    })
    |> put_present("reviewDecision", item["reviewDecision"])
    |> put_present("checksState", item["checksState"])
  end

  # A continuation is `<instant>|<rows delivered>|<numbers already sent at it>`: the
  # next slice reads that instant and everything older.
  @cursor ~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2}))\|(\d{1,9})\|(\d{1,9}(?:,\d{1,9})*)?$/

  defp decode_cursors(nil), do: {:ok, nil}

  defp decode_cursors(cursors) do
    Enum.reduce_while(cursors, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case Regex.run(@cursor, raw) do
        [_, boundary, delivered | seen] ->
          seen = seen |> List.first("") |> String.split(",", trim: true)

          cursor = %{
            boundary: boundary,
            delivered: String.to_integer(delivered),
            seen: Enum.map(seen, &String.to_integer/1)
          }

          {:cont, {:ok, Map.put(acc, key, cursor)}}

        nil ->
          {:halt, refuse("list", "The list could not be carried on from where it left off.")}
      end
    end)
  end

  defp next_cursor(_previous, [], _count), do: nil

  defp next_cursor(previous, fetched, count) do
    boundary = fetched |> Enum.map(& &1["updatedAt"]) |> Enum.min()
    kept = if previous && previous.boundary == boundary, do: previous.seen, else: []
    seen = kept ++ for(item <- fetched, item["updatedAt"] == boundary, do: item["number"])
    "#{boundary}|#{((previous && previous.delivered) || 0) + count}|#{Enum.join(seen, ",")}"
  end

  @doc """
  `pullRequests.listStats`: line counts for rows on the page, one aliased read per
  host. A row that cannot be answered for is left out.
  """
  def list_stats(%{"refs" => refs}) do
    by_id = Map.new(projects(), &{&1.id, &1})

    wanted =
      for ref <- refs,
          project = by_id[ref["projectId"]],
          project.kind == "github",
          same?(project.repository, ref["repository"]),
          uniq: true,
          do: {project, ref["number"]}

    stats =
      wanted
      |> Enum.group_by(fn {project, _} -> project.host end)
      |> Enum.flat_map(fn {_host, [{first, _} | _] = group} ->
        owners = Map.new(group, fn {p, n} -> {{String.downcase(p.repository), n}, p} end)
        refs = Enum.map(group, fn {p, n} -> {p.repository, n} end)

        for {repository, number, additions, deletions} <- GitHub.stats(ctx(first, nil), refs),
            project = owners[{String.downcase(repository), number}] do
          %{
            "projectId" => project.id,
            "repository" => project.repository,
            "number" => number,
            "additions" => additions,
            "deletions" => deletions
          }
        end
      end)

    {:ok, %{"stats" => stats}}
  end

  # --- one pull request ----------------------------------------------------------------

  def summary(ref) do
    read(ref, "summary", fn project, ctx ->
      at = System.system_time(:millisecond)

      with {:ok, summary} <- GitHub.summary(ctx) do
        {:ok,
         Map.merge(summary, %{
           "provider" => "github",
           "projectId" => project.id,
           "repository" => project.repository,
           "observedAt" => at
         })}
      end
    end)
  end

  def detail(ref) do
    read(ref, "detail", fn project, ctx ->
      at = System.system_time(:millisecond)

      [detail, identity] =
        Task.await_many(
          [Task.async(fn -> GitHub.detail(ctx) end), Task.async(fn -> identity(project) end)],
          :infinity
        )

      with {:ok, detail, _head} <- detail do
        {:ok,
         detail
         |> Map.merge(%{
           "provider" => "github",
           "capabilities" => GitHub.capabilities(),
           "projectId" => project.id,
           "projectTitle" => project.title,
           "workspaceRoot" => project.root,
           "repository" => project.repository,
           "observedAt" => at
         })
         |> put_present("viewer", login_of(identity))}
      end
    end)
  end

  def preview(ref) do
    read(ref, "preview", fn project, ctx ->
      with {:ok, preview} <- GitHub.preview(ctx),
           do:
             {:ok,
              Map.merge(preview, %{"projectId" => project.id, "repository" => project.repository})}
    end)
  end

  def checks(ref) do
    read(ref, "checks", fn _project, ctx ->
      with {:ok, detail, _head} <- GitHub.detail(ctx),
           do: {:ok, %{"state" => detail["state"], "checks" => detail["checks"]}}
    end)
  end

  def activity(ref), do: read(ref, "activity", fn _project, ctx -> GitHub.activity(ctx) end)

  def thread_comments(input),
    do:
      read(input, "threadComments", fn _project, ctx ->
        GitHub.thread_comments(ctx, input["threadId"], input["cursor"])
      end)

  def diff_file_contents(input),
    do: read(input, "diffFileContents", fn _project, ctx -> GitHub.file_contents(ctx, input) end)

  def files_viewed(ref),
    do: read(ref, "filesViewed", fn _project, ctx -> GitHub.files_viewed(ctx) end)

  # Ticking a file says nothing about the pull request, so nobody is told to read again.
  def set_files_viewed(input),
    do:
      read(input, "setFilesViewed", fn _project, ctx ->
        GitHub.set_files_viewed(ctx, input["files"] || [])
      end)

  @doc "The host-native stack a pull request is in, or nil."
  def stack(ref), do: read(ref, "stack", fn _project, ctx -> GitHub.stack(ctx) end)

  # --- changes ----------------------------------------------------------------------

  @doc """
  `pullRequests.runAction`: refused when GitHub cannot do it or this account may not,
  asked of the host fresh. Stack actions are not served.
  """
  def run_action(input) do
    change(input, "runAction", fn _project, ctx ->
      action = input["action"]
      capabilities = GitHub.capabilities()

      cond do
        input["stackNumber"] != nil ->
          refuse(
            "runAction",
            "This stack action is not supported or has no expected head revision."
          )

        action not in capabilities["actions"] ->
          refuse("runAction", "This host cannot #{action} a change request.")

        input["mergeMethod"] && input["mergeMethod"] not in capabilities["mergeMethods"] ->
          refuse("runAction", "This host cannot merge with the #{input["mergeMethod"]} strategy.")

        input["updateMethod"] && input["updateMethod"] not in capabilities["updateMethods"] ->
          refuse("runAction", "This host cannot update a branch by #{input["updateMethod"]}.")

        true ->
          with {:ok, viewer} <- GitHub.viewer_permissions(ctx, action == "update-branch") do
            cond do
              action not in viewer["actions"] ->
                refuse("runAction", @action_refusals[action])

              input["updateMethod"] &&
                  input["updateMethod"] not in (viewer["updateMethods"] || []) ->
                refuse("runAction", @action_refusals["update-branch"])

              true ->
                GitHub.action(ctx, action, input["mergeMethod"], input["updateMethod"])
            end
          end
      end
    end)
  end

  # Rewriting is left to the host to allow: whoever wrote something may rewrite it,
  # and no host reports that as a permission.
  def update(input) do
    change(input, "update", fn _project, ctx ->
      case Map.take(input, ["title", "body"]) do
        fields when fields == %{} -> refuse("update", "Nothing was changed.")
        fields -> GitHub.update(ctx, fields)
      end
    end)
  end

  def comment(input) do
    unless_blank(input["body"], "comment", "A comment cannot be empty.", fn ->
      change(input, "comment", fn _project, ctx -> GitHub.comment(ctx, input["body"]) end)
    end)
  end

  def update_comment(input) do
    unless_blank(input["body"], "updateComment", "A comment cannot be empty.", fn ->
      change(input, "updateComment", fn _project, ctx ->
        GitHub.update_comment(ctx, input["commentId"], input["kind"], input["body"])
      end)
    end)
  end

  def submit_review(input) do
    change(input, "submitReview", fn _project, ctx ->
      verdict = input["verdict"]
      comments = input["comments"] || []

      if verdict != "approve" and String.trim(input["body"] || "") == "" and comments == [] do
        refuse("submitReview", "A review needs a summary or at least one comment.")
      else
        with {:ok, viewer} <- GitHub.viewer_permissions(ctx) do
          if verdict in viewer["verdicts"],
            do: GitHub.submit_review(ctx, verdict, input["body"] || "", comments),
            else:
              refuse(
                "submitReview",
                "You need write access on this repository to #{@verdict_labels[verdict]} a change request."
              )
        end
      end
    end)
  end

  def reply_to_thread(input) do
    unless_blank(input["body"], "replyToThread", "A reply cannot be empty.", fn ->
      change(input, "replyToThread", fn _project, ctx ->
        GitHub.reply(ctx, input["threadId"], input["body"])
      end)
    end)
  end

  def set_thread_resolution(input) do
    change(input, "setThreadResolution", fn _project, ctx ->
      with {:ok, viewer} <- GitHub.viewer_permissions(ctx) do
        if viewer["resolve"],
          do: GitHub.resolve(ctx, input["threadId"], input["resolved"]),
          else:
            refuse(
              "setThreadResolution",
              "You need write access on this repository, or to have opened this change request, to resolve a review conversation."
            )
      end
    end)
  end

  # Anyone who can read a pull request may react to it.
  def set_reaction(input) do
    change(input, "setReaction", fn _project, ctx ->
      GitHub.react(ctx, input["subjectId"], input["content"], input["reacted"])
    end)
  end

  @doc "Who a review may be asked of, only for someone who may ask."
  def reviewer_candidates(ref) do
    read(ref, "reviewerCandidates", fn _project, ctx ->
      permitted(ctx, "reviewerCandidates", "requestReviewers", @reviewer_refusal, fn ->
        GitHub.reviewer_candidates(ctx)
      end)
    end)
  end

  def request_reviewers(input) do
    change(input, "requestReviewers", fn _project, ctx ->
      permitted(ctx, "requestReviewers", "requestReviewers", @reviewer_refusal, fn ->
        GitHub.request_reviewers(ctx, input["reviewers"], input["requested"])
      end)
    end)
  end

  def label_candidates(ref) do
    read(ref, "labelCandidates", fn _project, ctx ->
      permitted(ctx, "labelCandidates", "labels", @label_refusal, fn ->
        GitHub.label_candidates(ctx)
      end)
    end)
  end

  def set_labels(input) do
    change(input, "setLabels", fn _project, ctx ->
      permitted(ctx, "setLabels", "labels", @label_refusal, fn ->
        GitHub.set_labels(ctx, input["labels"], input["applied"] == true)
      end)
    end)
  end

  @doc """
  `pullRequests.invalidate`: nothing is cached but who is signed in, which a
  refresh of the whole listing forgets. Readers are told to read again, except for a
  refresh of review marks alone.
  """
  def invalidate(input) do
    if input["filesViewedOnly"] != true do
      if input["reference"] == nil, do: :persistent_term.erase(@viewers)
      Refreshes.bump()
    end

    {:ok, nil}
  end

  # --- routing ----------------------------------------------------------------------

  @doc "`pullRequests.routing`: the account and checkout a reference is served through."
  def routing(ref) do
    read(ref, "routeIdentity", fn project, _ctx ->
      with {:ok, %{"id" => id, "login" => login}} <- identity(project) do
        {:ok,
         %{
           "accountId" => id,
           "viewer" => login,
           "host" => project.host,
           "provider" => "github",
           "projectTitle" => project.title,
           "workspaceRoot" => project.root
         }}
      end
    end)
  end

  @doc "`pullRequests.routingIdentity`: who `gh` is signed in as on a host this node has."
  def routing_identity(%{"host" => host}) do
    host = host |> String.trim() |> String.downcase()

    case Enum.find(projects(), &(&1.kind == "github" and &1.host == host)) do
      nil ->
        unavailable("provider-unsupported", nil)

      project ->
        case identity(project) do
          {:ok, %{"id" => id, "login" => login}} ->
            {:ok, %{"accountId" => id, "viewer" => login, "host" => host, "provider" => "github"}}

          {:error, failure} ->
            provider_error("routeIdentity", failure)
        end
    end
  end

  @doc "`pullRequests.linkedThreads`: this node's threads linked to the pull request."
  def linked_threads(ref) do
    repository = String.downcase(String.trim(ref["repository"] || ""))

    host =
      cond do
        is_binary(ref["host"]) -> String.downcase(ref["host"])
        project = Enum.find(projects(), &(&1.id == ref["projectId"])) -> project.host
        true -> nil
      end

    threads =
      for {{node, _}, {"thread", row}} <- T3.Shell.rows(),
          host != nil and node == node() and row["deletedAt"] == nil,
          Enum.any?(row["pullRequests"] || [], &linked?(&1, host, repository, ref["number"])) do
        row
      end
      |> Enum.sort_by(& &1["id"])
      |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
      |> Enum.map(
        &%{
          "id" => &1["id"],
          "projectId" => &1["projectId"],
          "title" => &1["title"] || "",
          "archivedAt" => &1["archivedAt"]
        }
      )

    {:ok, %{"threads" => threads}}
  end

  defp linked?(link, host, repository, number) do
    link["source"] != "stack-dismissed" and link["number"] == number and
      String.downcase(link["host"] || "") == host and
      String.downcase(link["repository"] || "") == repository
  end

  # --- projects -----------------------------------------------------------------------

  # This node's projects whose checkout has a remote, as
  # `%{id, title, root, host, repository, kind}`.
  defp projects do
    for {{node, id}, {"project", %{"workspaceRoot" => root} = project}} <- T3.Shell.rows(),
        node == node() and is_binary(root) and project["deletedAt"] == nil,
        remote = remote(root) do
      Map.merge(remote, %{
        id: project["id"] || id,
        title: project["title"] || Path.basename(root),
        root: root
      })
    end
    |> Enum.sort_by(& &1.id)
  end

  # Worktrees of one repository are separate projects; each repository is read once.
  defp workspace(input) do
    host = input["host"] && String.downcase(input["host"])

    projects()
    |> Enum.filter(fn p ->
      (input["projectId"] == nil or p.id == input["projectId"]) and
        (input["projectIds"] == nil or p.id in input["projectIds"]) and
        (host == nil or p.host == host)
    end)
    |> Enum.uniq_by(&key/1)
  end

  # How a listing tells repositories apart: the same `owner/repo` can live on two hosts.
  defp key(project), do: "#{project.host} #{String.downcase(project.repository)}"

  defp remote(root) do
    with {:ok, out} <- T3.Git.ok(root, ~w(remote -v)),
         remotes =
           for(
             line <- String.split(out, "\n"),
             [name, url | _] <- [String.split(line)],
             do: {name, url}
           ),
         {_, url} <- List.keyfind(remotes, "origin", 0) || List.first(remotes) do
      parse_remote(url)
    else
      _ -> nil
    end
  end

  @doc "A git remote URL's host, repository path and host kind, or nil."
  def parse_remote(url) do
    url = String.trim(url)

    {host, path} =
      cond do
        String.contains?(url, "://") ->
          case URI.new(url) do
            {:ok, %URI{host: host, path: path}} when is_binary(host) and host != "" ->
              {host, path || ""}

            _ ->
              {nil, ""}
          end

        match = Regex.run(~r/^[A-Za-z0-9._-]+@([^:\/]+):(.+)$/, url) ->
          {Enum.at(match, 1), Enum.at(match, 2)}

        true ->
          {nil, ""}
      end

    repository = path |> String.trim("/") |> String.replace_suffix(".git", "")

    if host && repository != "" do
      host = String.downcase(host)
      kind = kind(host)

      # GitHub names a repository `owner/name`; anything else is not addressable there.
      if kind != "github" or Regex.match?(~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/, repository),
        do: %{host: host, repository: repository, kind: kind}
    end
  end

  defp kind(host) do
    labels = String.split(host, ".")

    cond do
      host == "codeberg.org" or "forgejo" in labels or "gitea" in labels ->
        "forgejo"

      host == "github.com" or "github" in labels ->
        "github"

      host == "gitlab.com" or "gitlab" in labels ->
        "gitlab"

      host == "dev.azure.com" or String.ends_with?(host, [".dev.azure.com", ".visualstudio.com"]) ->
        "azure-devops"

      host == "bitbucket.org" or "bitbucket" in labels ->
        "bitbucket"

      true ->
        "unknown"
    end
  end

  # The project that serves a reference: its own when the repository is its own,
  # else, for a reference that names a host, a checkout on that host.
  defp project_for(ref) do
    all = projects()
    own = Enum.find(all, &(&1.id == ref["projectId"]))
    repository = String.trim(ref["repository"] || "")
    host = ref["host"] && ref["host"] |> String.trim() |> String.downcase()

    project =
      cond do
        own && same?(own.repository, repository) && host in [nil, own.host] ->
          {:ok, own}

        host == nil and own == nil ->
          unavailable("provider-unsupported", nil)

        host == nil ->
          refuse(
            "resolveRepository",
            "The change request does not belong to the selected project."
          )

        true ->
          on_host = Enum.filter(all, &(&1.host == host))

          case Enum.find(on_host, &same?(&1.repository, repository)) || List.first(on_host) do
            nil -> unavailable("provider-unsupported", nil)
            route -> {:ok, %{route | repository: repository}}
          end
      end

    with {:ok, project} <- project do
      cond do
        project.kind != "github" ->
          unavailable("provider-unsupported", project.kind)

        not Regex.match?(~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/, project.repository) ->
          refuse("resolveRepository", "The repository cannot be addressed on GitHub.")

        true ->
          verified(project, ref)
      end
    end
  end

  # A routed operation names the account it expects to act as; anything else is refused.
  defp verified(project, %{"expectedAccountId" => expected} = ref) when is_binary(expected) do
    host = ref["host"] && String.downcase(ref["host"])

    case host == project.host && identity(project) do
      {:ok, %{"id" => ^expected}} ->
        {:ok, project}

      _ ->
        refuse(
          "routeIdentity",
          "The GitHub account could not be verified before starting the operation."
        )
    end
  end

  defp verified(project, _ref), do: {:ok, project}

  defp same?(left, right), do: String.downcase(left) == String.downcase(String.trim(right || ""))

  defp ctx(project, number),
    do: %{cwd: project.root, host: project.host, repository: project.repository, number: number}

  # Who is signed in to the project's host, believed for ten minutes.
  defp identity(%{host: host, root: root}) do
    now = System.monotonic_time(:millisecond)
    held = :persistent_term.get(@viewers, %{})

    case held[host] do
      {at, identity} when now - at < @viewer_ttl ->
        {:ok, identity}

      _ ->
        with {:ok, identity} <- GitHub.viewer(root, host) do
          :persistent_term.put(@viewers, Map.put(held, host, {now, identity}))
          {:ok, identity}
        end
    end
  end

  # --- plumbing -----------------------------------------------------------------------

  defp read(ref, operation, fun) do
    with {:ok, project} <- project_for(ref) do
      case fun.(project, ctx(project, ref["number"])) do
        :ok ->
          {:ok, nil}

        {:error, {reason, detail}} when is_atom(reason) ->
          provider_error(operation, {reason, detail})

        other ->
          other
      end
    end
  end

  defp change(ref, operation, fun) do
    with {:ok, _} = done <- read(ref, operation, fun) do
      Refreshes.bump()
      done
    end
  end

  defp permitted(ctx, operation, permission, refusal, fun) do
    with {:ok, viewer} <- GitHub.viewer_permissions(ctx) do
      if viewer[permission] == false, do: refuse(operation, refusal), else: fun.()
    end
  end

  # Markdown keeps its whitespace, so a body of nothing but whitespace is refused here.
  defp unless_blank(body, operation, detail, fun) do
    if String.trim(body || "") == "", do: refuse(operation, detail), else: fun.()
  end

  defp provider_error(_operation, {:missing, _}), do: unavailable("cli-missing", "github")

  defp provider_error(_operation, {:unauthenticated, _}),
    do: unavailable("cli-unauthenticated", "github")

  defp provider_error(operation, {_reason, detail}), do: refuse(operation, detail)

  defp unavailable(reason, provider) do
    message =
      case reason do
        "cli-missing" -> @requirements.missing
        "cli-unauthenticated" -> @requirements.unauthenticated
        _ -> "Change requests cannot be browsed for this project's host yet."
      end

    {:error,
     %{"_tag" => "PullRequestUnavailableError", "reason" => reason, "message" => message}
     |> put_present("provider", provider)}
  end

  defp refuse(operation, detail),
    do:
      {:error,
       %{
         "_tag" => "PullRequestOperationError",
         "operation" => operation,
         "detail" => detail,
         "message" => "Pull request operation #{operation} failed: #{detail}"
       }}

  defp login_of({:ok, %{"login" => login}}), do: login
  defp login_of(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
