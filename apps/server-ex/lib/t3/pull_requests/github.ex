defmodule T3.PullRequests.GitHub do
  @moduledoc """
  GitHub pull requests through the `gh` CLI, for `T3.PullRequests`: reads and writes
  in the shapes of `packages/contracts/src/pullRequest.ts`, ported from the Node
  server's `GitHubPullRequestCli.ts`, `gitHubPullRequestJson.ts` and
  `GitHubPullRequestProvider.ts`.

  Calls take a context `%{cwd:, host:, repository:, number:}`: `owner/name` on
  `host`, read through the checkout at `cwd`. Failures are `{:error, {reason,
  detail}}` with `reason` one of `:missing`, `:unauthenticated`, `:not_found` or
  `:failed`. Words a reader wrote travel over stdin rather than argv, which process
  listings show. The executable is `Application.get_env(:t3, :gh_command, "gh")`.
  """

  @timeout 30_000
  @page 100
  @thread_pages 10
  @files_viewed_pages 5
  @approval_limit 1_000

  @list_fields "number,title,url,author,headRefName,baseRefName,state,isDraft,mergeable,reviewDecision,additions,deletions,createdAt,updatedAt,mergedAt,reviewRequests,latestReviews,labels,statusCheckRollup"
  @detail_fields @list_fields <>
                   ",body,changedFiles,closedAt,isCrossRepository,headRepositoryOwner,headRefOid,autoMergeRequest"

  @actions ~w(merge ready draft close reopen update-branch enable-auto-merge disable-auto-merge revert approve-workflows)
  @verdicts ~w(comment approve request-changes)

  @doc "What GitHub can do, as `PullRequestCapabilities`. Stack actions are not served."
  def capabilities,
    do: %{
      "diff" => true,
      "comment" => true,
      "actions" => @actions,
      "mergeMethods" => ~w(merge squash rebase),
      "updateMethods" => ~w(merge rebase),
      "search" => true,
      "reactions" => true,
      "viewedFiles" => "host",
      "review" => %{
        "inlineComment" => true,
        "reply" => true,
        "resolve" => true,
        "verdicts" => @verdicts
      },
      "reviewers" => %{"request" => true, "listCandidates" => true},
      "edit" => %{"changeRequest" => true, "comment" => true},
      "stacks" => true,
      "stackActions" => false,
      "labels" => true
    }

  # --- queries ----------------------------------------------------------------------

  @reaction_groups """
  reactionGroups {
    content
    viewerHasReacted
    reactors(first: 10) {
      totalCount
      nodes { ... on User { login } ... on Bot { login } ... on Organization { login } ... on Mannequin { login } }
    }
  }
  """

  @core_query """
  query($owner: String!, $name: String!, $number: Int!, $headRef: String!) {
    repository(owner: $owner, name: $name) {
      mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerPermission
      pullRequest(number: $number) {
        number title url body state isDraft mergeable reviewDecision
        additions deletions changedFiles createdAt updatedAt mergedAt closedAt
        headRefName baseRefName headRefOid isCrossRepository
        headRepositoryOwner { login }
        author { login avatarUrl ... on User { id name } }
        autoMergeRequest { mergeMethod }
        viewerCanUpdate viewerDidAuthor viewerCanUpdateBranch
        baseRef { compare(headRef: $headRef) { behindBy } }
        reviewRequests(first: 100) {
          nodes { requestedReviewer { ... on User { login name } ... on Bot { login } ... on Team { slug name } } }
        }
        labels(first: 100) { nodes { name color } }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { contexts(first: 100) {
            nodes {
              __typename
              ... on StatusContext { context state targetUrl createdAt description }
              ... on CheckRun {
                name status conclusion startedAt completedAt detailsUrl
                checkSuite { workflowRun { workflow { name } } }
              }
            }
            pageInfo { hasNextPage }
          } } } }
        }
      }
    }
  }
  """

  @preview_query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        number title url state isDraft createdAt
        author { login avatarUrl ... on User { name } }
      }
    }
  }
  """

  @threads_query """
  query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    viewer { login }
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: #{@page}, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id isResolved isOutdated path line diffSide
            comments(first: 10) {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes { id author { __typename login avatarUrl } body createdAt url #{@reaction_groups} }
            }
          }
        }
        viewerCanUpdate viewerDidAuthor
        author { __typename login avatarUrl }
        #{@reaction_groups}
        comments(first: #{@page}) { nodes { id author { __typename login avatarUrl } #{@reaction_groups} } }
        reviews(first: #{@page}) { nodes { id author { __typename login avatarUrl } #{@reaction_groups} } }
        reviewRequests(first: 50) {
          nodes { requestedReviewer { ... on User { login name avatarUrl } ... on Bot { __typename login avatarUrl } } }
        }
        latestReviews(first: 50) { nodes { state author { __typename login avatarUrl } } }
        reviewDismissals: timelineItems(itemTypes: [REVIEW_DISMISSED_EVENT], first: #{@page}) {
          nodes { ... on ReviewDismissedEvent { dismissalMessage review { id } } }
        }
        commits(last: #{@page}) {
          nodes { commit {
            oid messageHeadline committedDate additions deletions
            parents(first: 1) { totalCount }
            authors(first: 3) { nodes { name avatarUrl user { login } } }
          } }
        }
      }
    }
  }
  """

  @thread_comments_query """
  query($owner: String!, $name: String!, $number: Int!, $threadId: ID!, $cursor: String) {
    viewer { login }
    repository(owner: $owner, name: $name) { pullRequest(number: $number) { id } }
    node(id: $threadId) {
      ... on PullRequestReviewThread {
        pullRequest { id }
        comments(first: #{@page}, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id author { __typename login avatarUrl } body createdAt url #{@reaction_groups} }
        }
      }
    }
  }
  """

  @node_id_query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) { id } }
  }
  """

  @subject_query """
  query($owner: String!, $name: String!, $number: Int!, $subjectId: ID!) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) { id } }
    node(id: $subjectId) {
      id
      ... on IssueComment { pullRequest { id } }
      ... on PullRequestReviewComment { pullRequest { id } }
      ... on PullRequestReview { pullRequest { id } }
    }
  }
  """

  @permissions_query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerPermission
      pullRequest(number: $number) { viewerCanUpdate viewerDidAuthor }
    }
  }
  """

  @reviewer_candidates_query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      assignableUsers(first: #{@page}) { pageInfo { hasNextPage } nodes { login name avatarUrl } }
      pullRequest(number: $number) {
        author { login }
        reviewRequests(first: #{@page}) {
          nodes { requestedReviewer {
            ... on User { login name avatarUrl }
            ... on Team { slug name avatarUrl }
            ... on Bot { login avatarUrl }
          } }
        }
      }
    }
  }
  """

  @label_candidates_query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      labels(first: #{@page}, orderBy: { field: NAME, direction: ASC }) {
        pageInfo { hasNextPage }
        nodes { name color description }
      }
      pullRequest(number: $number) { labels(first: #{@page}) { nodes { name } } }
    }
  }
  """

  @files_viewed_query """
  query($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        files(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { path viewerViewedState }
        }
      }
    }
  }
  """

  @reply_mutation """
  mutation($threadId: ID!, $body: String!) {
    addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) { comment { id } }
  }
  """

  @reaction_mutations %{
    true => """
    mutation($subjectId: ID!, $content: ReactionContent!) {
      addReaction(input: { subjectId: $subjectId, content: $content }) { reaction { content } }
    }
    """,
    false => """
    mutation($subjectId: ID!, $content: ReactionContent!) {
      removeReaction(input: { subjectId: $subjectId, content: $content }) { reaction { content } }
    }
    """
  }

  @resolution_mutations %{
    true => """
    mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }
    """,
    false => """
    mutation($threadId: ID!) { unresolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }
    """
  }

  @update_mutation """
  mutation($pullRequestId: ID!, $title: String, $body: String) {
    updatePullRequest(input: { pullRequestId: $pullRequestId, title: $title, body: $body }) { pullRequest { id } }
  }
  """

  @revert_mutation """
  mutation($pullRequestId: ID!) {
    revertPullRequest(input: { pullRequestId: $pullRequestId }) { revertPullRequest { id } }
  }
  """

  @comment_mutations %{
    "issue-comment" => """
    mutation($commentId: ID!, $body: String!) {
      updateIssueComment(input: { id: $commentId, body: $body }) { issueComment { id } }
    }
    """,
    "review-comment" => """
    mutation($commentId: ID!, $body: String!) {
      updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $commentId, body: $body }) {
        pullRequestReviewComment { id }
      }
    }
    """
  }

  @reactions %{
    "THUMBS_UP" => "thumbs-up",
    "THUMBS_DOWN" => "thumbs-down",
    "LAUGH" => "laugh",
    "HOORAY" => "hooray",
    "CONFUSED" => "confused",
    "HEART" => "heart",
    "ROCKET" => "rocket",
    "EYES" => "eyes"
  }

  # --- gh --------------------------------------------------------------------------

  @doc "Runs `gh args` in `cwd`: `{:ok, stdout}` when it exits 0."
  def gh(cwd, args, opts \\ []) do
    case System.find_executable(Application.get_env(:t3, :gh_command, "gh")) do
      nil -> {:error, {:missing, "gh is not installed."}}
      path -> run(path, cwd, args, opts)
    end
  end

  defp run(path, cwd, args, opts) do
    exile =
      [stderr: :consume, ignore_epipe: true, env: [{"GH_PROMPT_DISABLED", "1"}]] ++
        if(cwd && File.dir?(cwd), do: [cd: cwd], else: []) ++
        if(opts[:input], do: [input: [opts[:input]]], else: [])

    max = opts[:max_bytes] || :infinity

    # Output past `:max_bytes` is dropped rather than held, and the answer refused.
    task =
      Task.async(fn ->
        [path | args]
        |> Exile.stream(exile)
        |> Enum.reduce({[], [], 0, nil}, fn
          {:stdout, data}, {out, err, size, status} when size < max ->
            {[out, data], err, size + byte_size(data), status}

          {:stdout, data}, {out, err, size, status} ->
            {out, err, size + byte_size(data), status}

          {:stderr, data}, {out, err, size, status} ->
            {out, [err, data], size, status}

          {:exit, status}, {out, err, size, _} ->
            {out, err, size, status}
        end)
      end)

    case Task.yield(task, opts[:timeout] || @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_, _, size, {:status, 0}}} when size > max ->
        {:error, {:too_large, "gh answered with more than #{max} bytes."}}

      {:ok, {out, _, _, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:ok, {out, err, _, _}} ->
        {:error, failure(IO.iodata_to_binary(err), IO.iodata_to_binary(out))}

      nil ->
        {:error, {:failed, "gh did not answer in time."}}
    end
  rescue
    error -> {:error, {:failed, Exception.message(error)}}
  end

  defp failure(err, out) do
    said = String.downcase(err <> "\n" <> out)

    detail =
      (first_line(err) || first_line(out) || "gh failed.") |> String.replace_prefix("gh: ", "")

    cond do
      String.contains?(said, [
        "gh auth login",
        "not logged in",
        "authentication failed",
        "no oauth token",
        "bad credentials",
        "http 401"
      ]) ->
        {:unauthenticated, detail}

      String.contains?(said, ["http 404", "could not resolve to a pullrequest", "not found"]) ->
        {:not_found, detail}

      true ->
        {:failed, detail}
    end
  end

  defp gh_json(cwd, args, opts \\ []) do
    with {:ok, out} <- gh(cwd, args, opts) do
      case String.trim(out) do
        "" -> {:ok, nil}
        text -> decoded(JSON.decode(text))
      end
    end
  end

  defp decoded({:ok, value}), do: {:ok, value}
  defp decoded(_), do: {:error, {:failed, "GitHub answered in an unexpected shape."}}

  @doc "A GraphQL document and its variables, sent over stdin; the answer's `data`."
  def graphql(ctx, query, variables \\ %{}) do
    input = JSON.encode!(%{"query" => query, "variables" => variables})

    case gh_json(ctx.cwd, ["api", "graphql", "--hostname", ctx.host, "--input", "-"],
           input: input
         ) do
      {:ok, %{"data" => %{} = data}} -> {:ok, data}
      {:ok, _} -> decoded(:error)
      error -> error
    end
  end

  # A REST call against the repository's own API root.
  defp rest(ctx, path, opts \\ []) do
    {owner, name} = split(ctx.repository)

    args =
      ["api", "--hostname", ctx.host] ++
        if(opts[:method], do: ["--method", opts[:method]], else: []) ++
        ["repos/#{owner}/#{name}/#{path}"] ++
        if(opts[:input], do: ["--input", "-"], else: [])

    gh_json(ctx.cwd, args, Keyword.take(opts, [:input, :timeout]))
  end

  # `gh` resolves a bare `owner/repo` against github.com; naming the host keeps an
  # Enterprise repository on its own install.
  defp repo_args(ctx), do: ["--repo", "#{ctx.host}/#{ctx.repository}"]

  defp vars(ctx) do
    {owner, name} = split(ctx.repository)
    %{"owner" => owner, "name" => name, "number" => ctx.number}
  end

  defp split(repository) do
    [owner, name] = String.split(repository, "/", parts: 2)
    {owner, name}
  end

  # --- identity ----------------------------------------------------------------------

  @doc "Who `gh` is signed in as on `host`: `%{\"id\" => id, \"login\" => login}`."
  def viewer(cwd, host) do
    case gh_json(cwd, ["api", "user", "--hostname", host]) do
      {:ok, %{"id" => id, "login" => login}} when is_integer(id) and is_binary(login) ->
        {:ok, %{"id" => Integer.to_string(id), "login" => login}}

      {:ok, _} ->
        decoded(:error)

      error ->
        error
    end
  end

  # --- listing ----------------------------------------------------------------------

  @doc """
  One repository's pull requests. `opts`: state, involvement, viewer, limit, query,
  filters, cursor (`%{boundary: iso}` or nil). The first read is a search sorted by
  update, which a cursor carries on from; GitHub leaves some repositories out of its
  search index, so an empty first answer with no text to match is read again the way
  `gh pr list` lists without one, narrowed here, and cannot be continued.
  """
  def list(ctx, opts) do
    case list_read(ctx, opts, true, opts.limit + 1) do
      {:ok, %{items: []}} = empty ->
        if opts.cursor == nil and String.trim(opts.query || "") == "",
          do: list_read(ctx, opts, false, opts.limit + 1),
          else: empty

      other ->
        other
    end
  end

  defp list_read(ctx, opts, sorted, rows) do
    args =
      ["pr", "list"] ++
        repo_args(ctx) ++
        list_args(opts, sorted) ++
        ["--state", opts.state, "--limit", "#{rows}", "--json", @list_fields]

    with {:ok, raw} <- gh_json(ctx.cwd, args) do
      raw = raw || []
      items = Enum.flat_map(raw, &list_item/1)
      most = max(opts.limit + 1, 1_000)

      if sorted do
        truncated = length(raw) > opts.limit
        {:ok, %{items: Enum.take(items, opts.limit), truncated: truncated, sorted: true}}
      else
        kept = Enum.filter(items, &unsorted_match?(&1, opts))

        if length(kept) < opts.limit and length(raw) >= rows and rows < most do
          list_read(ctx, opts, false, min(rows * 2, most))
        else
          truncated = length(kept) > opts.limit or length(raw) >= rows
          {:ok, %{items: Enum.take(kept, opts.limit), truncated: truncated, sorted: false}}
        end
      end
    end
  end

  # `--state closed` includes merged pull requests, so Closed also excludes them;
  # `gh` takes one `--search`, so the reader's text joins the qualifiers.
  defp list_args(opts, sorted) do
    query = String.trim(opts.query || "")

    terms =
      if sorted do
        if(opts.involvement == "reviewing", do: ["review-requested:#{opts.viewer}"], else: []) ++
          if(opts.state == "closed", do: ["is:unmerged"], else: []) ++
          if(query == "", do: [], else: [phrase(query)]) ++
          if(opts.cursor, do: ["updated:<=#{opts.cursor.boundary}"], else: []) ++
          qualifiers(opts.filters, opts.viewer) ++ ["sort:updated-desc"]
      else
        []
      end

    if(opts.involvement == "authored", do: ["--author", opts.viewer], else: []) ++
      if(terms == [], do: [], else: ["--search", Enum.join(terms, " ")])
  end

  # The reader's words as one quoted phrase, so `is:merged` typed into the box stays text.
  defp phrase(query) do
    escaped = query |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  # A label or login holds no double quote, so one is dropped rather than escaped.
  defp qualifier(value), do: "\"" <> (value |> String.replace("\"", "") |> String.trim()) <> "\""

  @review_qualifiers %{
    "approved" => "approved",
    "changes-requested" => "changes_requested",
    "review-required" => "required",
    "none" => "none"
  }

  defp qualifiers(nil, _viewer), do: []

  defp qualifiers(filters, viewer) do
    for(
      group <- filters["labels"] || [],
      group != [],
      do: "label:" <> Enum.map_join(group, ",", &qualifier/1)
    ) ++
      for(label <- filters["excludedLabels"] || [], do: "-label:" <> qualifier(label)) ++
      if(filters["author"],
        do: ["author:" <> qualifier(author_filter(filters["author"], viewer))],
        else: []
      ) ++
      if(filters["draft"], do: ["draft:#{filters["draft"] == "only"}"], else: []) ++
      if(filters["review"], do: ["review:#{@review_qualifiers[filters["review"]]}"], else: []) ++
      if(filters["checks"],
        do: ["status:#{if filters["checks"] == "passing", do: "success", else: "failure"}"],
        else: []
      )
  end

  @doc "`author:me` names whoever is signed in, as `resolvePullRequestAuthorFilter` does."
  def author_filter(author, viewer) do
    author = String.trim(author)
    if Regex.match?(~r/^@?me$/i, author) and viewer not in [nil, ""], do: viewer, else: author
  end

  # The fallback read is wider than the request, so it is narrowed here.
  defp unsorted_match?(item, opts) do
    viewer = String.downcase(opts.viewer)

    involved? =
      case opts.involvement do
        "authored" ->
          login(item["author"]) == viewer

        "reviewing" ->
          item["hasTeamReviewRequest"] or
            Enum.any?(item["reviewRequestLogins"], &(String.downcase(&1) == viewer))

        _ ->
          true
      end

    (opts.state == "all" or item["state"] == opts.state) and involved? and
      row_match?(item, opts.filters, opts.viewer, true)
  end

  @doc """
  Whether a row satisfies the filters a row can be judged by. `checks` is judged only
  on the fallback read (`checks?`), since search already narrowed the rest.
  """
  def row_match?(_item, nil, _viewer, _checks?), do: true

  def row_match?(item, filters, viewer, checks?) do
    labels = MapSet.new(item["labels"], &String.downcase(&1["name"]))
    holds? = &MapSet.member?(labels, String.downcase(String.trim(&1)))

    (filters["draft"] == nil or item["isDraft"] == (filters["draft"] == "only")) and
      (filters["review"] == nil or
         if(filters["review"] == "none",
           do: item["reviewDecision"] == nil,
           else: item["reviewDecision"] == filters["review"]
         )) and
      (not checks? or filters["checks"] == nil or item["checksState"] == filters["checks"]) and
      Enum.all?(filters["labels"] || [], &Enum.any?(&1, holds?)) and
      not Enum.any?(filters["excludedLabels"] || [], holds?) and
      (filters["author"] == nil or
         login(item["author"]) == String.downcase(author_filter(filters["author"], viewer)))
  end

  defp login(nil), do: nil
  defp login(actor), do: String.downcase(actor["login"])

  # A malformed row is skipped rather than failing the listing.
  defp list_item(
         %{
           "number" => number,
           "title" => title,
           "url" => url,
           "headRefName" => head,
           "baseRefName" => base,
           "createdAt" => created,
           "updatedAt" => updated
         } = raw
       )
       when is_integer(number) and is_binary(title) and is_binary(url) and is_binary(head) and
              is_binary(base) and is_binary(created) and is_binary(updated) do
    requests = raw["reviewRequests"] || []

    [
      %{
        "number" => number,
        "title" => title,
        "url" => url,
        "author" => actor(raw["author"]),
        "headBranch" => head,
        "baseBranch" => base,
        "state" => state(raw),
        "isDraft" => raw["isDraft"] == true,
        "mergeability" => mergeability(raw["mergeable"]),
        "reviewDecision" => review_decision(raw["reviewDecision"], raw["latestReviews"]),
        "additions" => raw["additions"] || 0,
        "deletions" => raw["deletions"] || 0,
        "createdAt" => created,
        "updatedAt" => updated,
        "reviewRequestLogins" => for(r <- requests, login = trimmed(r["login"]), do: login),
        "hasTeamReviewRequest" =>
          Enum.any?(
            requests,
            &(trimmed(&1["login"]) == nil and (trimmed(&1["slug"]) || trimmed(&1["name"])) != nil)
          ),
        "labels" => labels(raw["labels"]),
        "checksState" => rollup(raw["statusCheckRollup"])
      }
    ]
  end

  defp list_item(_raw), do: []

  @doc "Line counts for pull requests on one host, as `[{repository, number, additions, deletions}]`."
  def stats(ctx, refs) do
    refs
    |> Enum.chunk_every(25)
    |> Task.async_stream(&stats_chunk(ctx, &1), max_concurrency: 4, timeout: :infinity)
    |> Enum.flat_map(fn
      {:ok, {:ok, stats}} -> stats
      _ -> []
    end)
  end

  # Aliased lookups, one per row; owner, name and number are checked before they are
  # written into the document.
  defp stats_chunk(ctx, chunk) do
    selections =
      for {{repository, number}, index} <- Enum.with_index(chunk),
          {owner, name} = split(repository),
          Regex.match?(~r/^[A-Za-z0-9._-]+$/, owner) and Regex.match?(~r/^[A-Za-z0-9._-]+$/, name),
          is_integer(number) and number > 0 do
        ~s[s#{index}: repository(owner: "#{owner}", name: "#{name}") { pullRequest(number: #{number}) { additions deletions } }]
      end

    with true <- selections != [],
         {:ok, data} <- graphql(ctx, "query {\n#{Enum.join(selections, "\n")}\n}") do
      {:ok,
       for {{repository, number}, index} <- Enum.with_index(chunk),
           pr = get_in(data, ["s#{index}", "pullRequest"]) do
         {repository, number, pr["additions"] || 0, pr["deletions"] || 0}
       end}
    else
      false -> {:ok, []}
      error -> error
    end
  end

  # --- one pull request ----------------------------------------------------------------

  @doc "`PullRequestSummary`'s host fields, from `gh pr view`."
  def summary(ctx) do
    with {:ok, %{} = raw} <- view(ctx, @detail_fields), [item] <- list_item(raw) do
      {:ok,
       item
       |> Map.take(
         ~w(number title url state isDraft headBranch baseBranch updatedAt additions deletions reviewDecision checksState mergeability)
       )
       |> Map.merge(%{
         "closedAt" => trimmed(raw["closedAt"]),
         "mergedAt" => trimmed(raw["mergedAt"]),
         "author" => with_avatar(item["author"], ctx.host),
         "changedFiles" => raw["changedFiles"] || 0
       })}
    else
      {:error, _} = error -> error
      _ -> decoded(:error)
    end
  end

  defp view(ctx, fields),
    do: gh_json(ctx.cwd, ["pr", "view", "#{ctx.number}"] ++ repo_args(ctx) ++ ["--json", fields])

  @doc "`PullRequestPreview`'s host fields."
  def preview(ctx) do
    with {:ok, data} <- graphql(ctx, @preview_query, vars(ctx)),
         %{"number" => _} = pr <- get_in(data, ["repository", "pullRequest"]) do
      {:ok,
       pr
       |> Map.take(~w(number title url isDraft createdAt))
       |> Map.merge(%{"author" => actor(pr["author"]), "state" => state(pr)})}
    else
      {:error, _} = error -> error
      _ -> not_found(ctx)
    end
  end

  @doc """
  The detail read: `PullRequestDetail`'s host fields, with fork workflows waiting on
  approval added to the checks. `{:ok, detail, head}`, where `head` is what an
  approval is checked against.
  """
  def detail(ctx) do
    variables = Map.put(vars(ctx), "headRef", "refs/pull/#{ctx.number}/head")

    with {:ok, data} <- graphql(ctx, @core_query, variables),
         %{"pullRequest" => %{"number" => _} = pr} = repo <- data["repository"],
         {:ok, raw_checks} <- core_checks(ctx, pr),
         [item] <-
           list_item(
             Map.merge(pr, %{
               "reviewRequests" => nodes(pr, ["reviewRequests", "nodes"], "requestedReviewer"),
               "labels" => get_in(pr, ["labels", "nodes"])
             })
           ) do
      comparison =
        if pr["state"] == "OPEN" and is_map(get_in(pr, ["baseRef", "compare"])),
          do: pr["baseRef"]["compare"]["behindBy"]

      access =
        repo
        |> access(pr["viewerCanUpdate"], pr["viewerDidAuthor"])
        |> Map.put(:can_update_branch, comparison != nil and pr["viewerCanUpdateBranch"] == true)

      method = merge_method(get_in(pr, ["autoMergeRequest", "mergeMethod"]))
      {checks, approvals} = with_approvals(ctx, pr, checks(raw_checks))

      detail =
        item
        |> Map.take(
          ~w(number title url state isDraft mergeability additions deletions headBranch baseBranch createdAt updatedAt labels)
        )
        |> Map.merge(%{
          "body" => pr["body"] || "",
          "author" => with_avatar(item["author"], ctx.host),
          "changedFiles" => pr["changedFiles"] || 0,
          "mergedAt" => trimmed(pr["mergedAt"]),
          "closedAt" => trimmed(pr["closedAt"]),
          "reviewers" =>
            for(
              l <- item["reviewRequestLogins"],
              do: %{"login" => l, "name" => nil, "avatarUrl" => nil}
            ),
          "checks" => checks,
          "mergeCapabilities" => merge_capabilities(repo),
          "viewerPermissions" => permissions(access),
          "baseComparison" =>
            cond do
              comparison == nil -> "unknown"
              comparison > 0 -> "behind"
              true -> "up-to-date"
            end,
          "autoMergeEnabled" => pr["autoMergeRequest"] != nil
        })
        |> put_present("behindBy", comparison)
        |> put_present("autoMergeMethod", method)
        |> put_present("workflowApprovalsRequired", approvals)

      {:ok, detail, pr}
    else
      {:error, _} = error -> error
      _ -> not_found(ctx)
    end
  end

  # `gh` pages check contexts itself, so a suite past the first hundred is read through it.
  defp core_checks(ctx, pr) do
    first = List.first(get_in(pr, ["commits", "nodes"]) || []) || %{}
    contexts = get_in(first, ["commit", "statusCheckRollup", "contexts"]) || %{}

    nodes =
      for n <- contexts["nodes"] || [],
          do:
            Map.put(
              n,
              "workflowName",
              get_in(n, ["checkSuite", "workflowRun", "workflow", "name"])
            )

    head = pr["headRefOid"]

    if get_in(contexts, ["pageInfo", "hasNextPage"]) == true do
      case view(ctx, "statusCheckRollup,headRefOid") do
        {:ok, %{"headRefOid" => ^head} = raw} ->
          {:ok, raw["statusCheckRollup"] || []}

        {:ok, _} ->
          {:error, {:failed, "Pull request head changed while reading checks."}}

        error ->
          error
      end
    else
      {:ok, nodes}
    end
  end

  # An open pull request from a fork may have workflow runs waiting on a maintainer;
  # they are listed as checks, with a warning check when they could not be read.
  defp with_approvals(ctx, pr, checks) do
    if pr["state"] != "OPEN" or pr["isCrossRepository"] != true do
      {checks, 0}
    else
      case approval_runs(ctx, pr) do
        {:ok, runs} ->
          shown =
            for c <- checks,
                c["status"] == "action-required",
                [_, id] <- [Regex.run(~r{/actions/runs/(\d+)(?:/|$)}, c["url"] || "")],
                into: MapSet.new(),
                do: String.to_integer(id)

          added =
            for run <- runs,
                not MapSet.member?(shown, run.id),
                do: %{
                  "name" => run.name,
                  "status" => "action-required",
                  "description" => "A maintainer must approve this workflow before it can run.",
                  "url" => run.url
                }

          {checks ++ added, length(runs)}

        {:error, _} ->
          unavailable = %{
            "name" => "Workflow approval status",
            "status" => "action-required",
            "description" =>
              "GitHub could not determine whether workflows are awaiting approval.",
            "url" => nil
          }

          {checks ++ [unavailable], nil}
      end
    end
  end

  # Runs of the head commit waiting on approval. Refused unless the head names this
  # pull request alone, so a run belonging to another one is never approved.
  defp approval_runs(ctx, pr) do
    sha = trimmed(pr["headRefOid"])
    owner = String.downcase(get_in(pr, ["headRepositoryOwner", "login"]) || "")
    branch = pr["headRefName"]
    limit = "#{@approval_limit + 1}"

    heads =
      ["pr", "list"] ++
        repo_args(ctx) ++
        ~w(--state open --head) ++
        [
          branch,
          "--limit",
          limit,
          "--json",
          "number,headRefOid,isCrossRepository,headRepositoryOwner"
        ]

    runs =
      ["run", "list"] ++
        repo_args(ctx) ++
        ["--commit", sha || "", "--branch", branch] ++
        ~w(--event pull_request --status action_required --limit) ++
        [limit, "--json", "databaseId,workflowName,url"]

    with true <- sha != nil and owner != "",
         {:ok, heads} when length(heads) <= @approval_limit <- gh_json(ctx.cwd, heads),
         [%{"number" => number}] when number == ctx.number <-
           Enum.filter(heads, fn head ->
             head["headRefOid"] == sha and head["isCrossRepository"] == true and
               String.downcase(get_in(head, ["headRepositoryOwner", "login"]) || "") == owner
           end),
         {:ok, runs} when length(runs) <= @approval_limit <- gh_json(ctx.cwd, runs) do
      {:ok,
       for %{"databaseId" => id} = run <- runs, is_integer(id) do
         %{
           id: id,
           name: trimmed(run["workflowName"]) || "Workflow run #{id}",
           url: trimmed(run["url"])
         }
       end}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         {:failed,
          "The workflow runs awaiting approval could not be matched to this pull request."}}
    end
  end

  defp access(repo, can_update, did_author) do
    permission = up(repo["viewerPermission"])
    can_write = permission in ~w(ADMIN MAINTAIN WRITE)

    %{
      can_write: can_write,
      can_triage: can_write or permission == "TRIAGE",
      can_update: can_update != false,
      did_author: did_author == true,
      can_update_branch: false
    }
  end

  defp merge_capabilities(repo),
    do: %{
      "merge" => repo["mergeCommitAllowed"] == true,
      "squash" => repo["squashMergeAllowed"] == true,
      "rebase" => repo["rebaseMergeAllowed"] == true
    }

  @doc """
  `PullRequestViewerPermissions`. Merging needs write; the author may also close,
  reopen and move a draft; anyone may comment; an author may not approve their own.
  """
  def permissions(access) do
    %{
      "actions" =>
        if(access.can_write,
          do: ~w(merge enable-auto-merge disable-auto-merge revert approve-workflows),
          else: []
        ) ++
          if(access.can_update, do: ~w(ready draft close reopen), else: []) ++
          if(access.can_update_branch, do: ["update-branch"], else: []),
      "comment" => true,
      "resolve" => access.can_write or access.did_author,
      "verdicts" => if(access.did_author, do: ["comment"], else: @verdicts),
      "requestReviewers" => access.can_write,
      "labels" => access.can_triage
    }
    |> put_present("stackRebase", if(access.can_write, do: true))
    |> put_present("updateMethods", if(access.can_update_branch, do: ~w(merge rebase)))
  end

  @doc """
  What the signed-in account may do here, asked fresh. Updating the branch is only
  known from the base comparison, which the detail read carries (`update_branch?`).
  """
  def viewer_permissions(ctx, update_branch? \\ false) do
    if update_branch? do
      with {:ok, detail, _} <- detail(ctx), do: {:ok, detail["viewerPermissions"]}
    else
      with {:ok, data} <- graphql(ctx, @permissions_query, vars(ctx)),
           %{} = repo <- data["repository"] do
        pr = repo["pullRequest"] || %{}
        {:ok, permissions(access(repo, pr["viewerCanUpdate"], pr["viewerDidAuthor"]))}
      else
        {:error, _} = error -> error
        _ -> not_found(ctx)
      end
    end
  end

  @doc "The host-native stack the pull request is in, or nil; a host without stacks answers 404."
  def stack(ctx, details? \\ true) do
    with {:ok, stacks} <- rest(ctx, "stacks?pull_request=#{ctx.number}"),
         [%{"number" => number} = found | _] when is_integer(number) <- stacks || [],
         {:ok, found} <-
           if(details?, do: rest(ctx, "stacks/#{number}"), else: {:ok, found}) do
      base = if is_map(found["base"]), do: found["base"]["ref"], else: found["base"]

      {:ok,
       %{
         "id" =>
           if(found["id"] == nil,
             do: trimmed(found["node_id"]) || "#{number}",
             else: "#{found["id"]}"
           ),
         "number" => number,
         "url" => trimmed(found["html_url"]) || found["url"],
         "base" => base,
         "layers" =>
           for pr <- found["pull_requests"] || [] do
             %{
               "number" => pr["number"],
               "headBranch" => get_in(pr, ["head", "ref"]),
               "state" => state(%{"state" => pr["state"], "mergedAt" => pr["merged_at"]})
             }
             |> put_present("title", pr["title"])
             |> put_present("isDraft", pr["draft"])
             |> put_present("headSha", get_in(pr, ["head", "sha"]))
           end
       }}
    else
      {:error, {:not_found, _}} -> {:ok, nil}
      {:error, _} = error -> error
      _ -> {:ok, nil}
    end
  end

  # --- activity ---------------------------------------------------------------------

  @doc """
  `PullRequestActivity`: the conversation from `gh pr view`, with the review threads,
  reactions, avatars, reviewers and commit stats that only GraphQL reaches. A failed
  thread read leaves a conversation marked truncated rather than none.
  """
  def activity(ctx) do
    [view, threads] =
      Task.await_many(
        [
          Task.async(fn -> view(ctx, "author,comments,reviews,commits") end),
          Task.async(fn -> review_threads(ctx) end)
        ],
        :infinity
      )

    with {:ok, %{} = raw} <- view do
      t =
        case threads do
          {:ok, t} -> t
          _ -> empty_threads()
        end

      avatar = &with_avatar(&1, ctx.host, t.avatars, t.bots)

      comments =
        (view_comments(raw) ++ conversation(t.threads))
        |> Enum.map(fn comment ->
          body =
            if comment["kind"] == "review" and up(comment["reviewState"]) == "DISMISSED" and
                 renders_empty?(comment["body"]),
               do: t.dismissals[comment["id"]] || comment["body"],
               else: comment["body"]

          Map.merge(comment, %{
            "body" => body,
            "author" => avatar.(comment["author"]),
            "reactions" => comment["reactions"] || t.reactions_by_id[comment["id"]] || []
          })
        end)
        |> Enum.sort_by(& &1["createdAt"])

      commits =
        for commit <- if(t.commits != [], do: t.commits, else: view_commits(raw["commits"])) do
          commit
          |> Map.merge(t.stats[commit["oid"]] || %{})
          |> Map.update!("authors", &Enum.map(&1, fn author -> avatar.(author) end))
        end

      {:ok,
       %{
         "author" => avatar.(actor(raw["author"])),
         "reviewers" => t.reviewers,
         "reactions" => t.reactions,
         "commits" => commits,
         "comments" => comments,
         "commentCount" => length(view_comments(raw)) + t.count,
         "commentsTruncated" => t.truncated,
         "reviewThreads" =>
           for thread <- t.threads do
             Map.update!(thread, "comments", fn comments ->
               Enum.map(comments, &Map.update!(&1, "author", avatar))
             end)
           end
       }}
    else
      {:error, _} = error -> error
      _ -> decoded(:error)
    end
  end

  # A review with no words is kept only when its state is the event itself: GitHub
  # also opens an empty COMMENTED review around line comments, read from the threads.
  defp view_comments(raw) do
    issue =
      for c <- raw["comments"] || [] do
        %{
          "id" => c["id"],
          "kind" => "issue-comment",
          "author" => actor(c["author"]),
          "body" => c["body"] || "",
          "createdAt" => c["createdAt"],
          "url" => trimmed(c["url"]),
          "path" => nil,
          "reviewState" => nil
        }
      end

    reviews =
      for r <- raw["reviews"] || [],
          at = trimmed(r["submittedAt"]),
          String.trim(r["body"] || "") != "" or
            up(r["state"]) in ~w(APPROVED CHANGES_REQUESTED DISMISSED) do
        %{
          "id" => r["id"],
          "kind" => "review",
          "author" => actor(r["author"]),
          "body" => r["body"] || "",
          "createdAt" => at,
          "url" => trimmed(r["url"]),
          "path" => nil,
          "reviewState" => trimmed(r["state"])
        }
      end

    Enum.sort_by(issue ++ reviews, & &1["createdAt"])
  end

  defp view_commits(commits) do
    for c <- commits || [] do
      %{
        "oid" => c["oid"],
        "messageHeadline" => c["messageHeadline"] || "",
        "committedDate" => c["committedDate"],
        "authors" =>
          for(
            a <- c["authors"] || [],
            login = trimmed(a["login"]) || trimmed(a["name"]) || trimmed(a["email"]),
            do: %{"login" => login, "name" => trimmed(a["name"]), "avatarUrl" => nil}
          )
      }
    end
  end

  defp renders_empty?(body),
    do: body |> String.replace(~r/<!--[\s\S]*?-->/, "") |> String.trim() == ""

  defp conversation(threads) do
    for thread <- threads, comment <- thread["comments"] do
      %{
        "id" => comment["id"],
        "kind" => "review-comment",
        "author" => comment["author"],
        "body" => comment["body"],
        "createdAt" => comment["createdAt"],
        "url" => comment["url"],
        "path" => thread["path"],
        "reviewState" => nil,
        "reactions" => comment["reactions"]
      }
    end
  end

  defp empty_threads,
    do: %{
      threads: [],
      count: 0,
      truncated: true,
      reactions: [],
      reactions_by_id: %{},
      reviewers: [],
      avatars: %{},
      bots: MapSet.new(),
      stats: %{},
      commits: [],
      dismissals: %{}
    }

  # Review threads, up to ten pages of them; everything else rides on the first page.
  defp review_threads(ctx) do
    Enum.reduce_while(1..@thread_pages, {:more, nil, nil}, fn _, {:more, cursor, acc} ->
      case graphql(ctx, @threads_query, Map.put(vars(ctx), "cursor", cursor)) do
        {:ok, %{"repository" => %{"pullRequest" => %{} = pr}} = data} ->
          acc = threads_page(acc, pr, trimmed(get_in(data, ["viewer", "login"])))
          next = next_cursor(get_in(pr, ["reviewThreads", "pageInfo"]))
          if next, do: {:cont, {:more, next, acc}}, else: {:halt, {:ok, acc}}

        {:ok, _} ->
          {:halt, not_found(ctx)}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:more, _, acc} -> {:ok, %{acc | truncated: true}}
      done -> done
    end
  end

  defp threads_page(acc, pr, viewer) do
    threads =
      for t <- get_in(pr, ["reviewThreads", "nodes"]) || [],
          path = trimmed(t["path"]),
          id = trimmed(t["id"]),
          comments = get_in(t, ["comments", "nodes"]) || [],
          comments != [] do
        %{
          "id" => id,
          "path" => path,
          "line" => if(is_integer(t["line"]) and t["line"] > 0, do: t["line"]),
          "side" => if(up(t["diffSide"]) == "LEFT", do: "left", else: "right"),
          "isResolved" => t["isResolved"] == true,
          "isOutdated" => t["isOutdated"] == true,
          "comments" => Enum.map(comments, &thread_comment(&1, viewer)),
          "commentCount" => get_in(t, ["comments", "totalCount"]) || length(comments)
        }
        |> put_present("nextCommentsCursor", next_cursor(get_in(t, ["comments", "pageInfo"])))
      end

    raw_actors =
      [pr["author"]] ++
        nodes(pr, ["comments", "nodes"], "author") ++
        nodes(pr, ["reviews", "nodes"], "author") ++
        nodes(pr, ["reviewRequests", "nodes"], "requestedReviewer") ++
        nodes(pr, ["latestReviews", "nodes"], "author") ++
        for(
          t <- get_in(pr, ["reviewThreads", "nodes"]) || [],
          c <- get_in(t, ["comments", "nodes"]) || [],
          do: c["author"]
        )

    avatars =
      for a <- raw_actors,
          l = a && trimmed(a["login"]),
          u = trimmed(a["avatarUrl"]),
          into: %{},
          do: {l, u}

    bots =
      for a <- raw_actors,
          actor = actor(a),
          actor["isBot"],
          into: MapSet.new(),
          do: actor["login"]

    page = %{
      threads: threads,
      count: Enum.sum_by(threads, & &1["commentCount"]),
      truncated: Enum.any?(threads, &Map.has_key?(&1, "nextCommentsCursor")),
      avatars: avatars,
      bots: bots
    }

    case acc do
      nil ->
        Map.merge(page, first_page(pr, viewer))

      acc ->
        %{
          acc
          | threads: acc.threads ++ page.threads,
            count: acc.count + page.count,
            truncated: acc.truncated or page.truncated,
            avatars: Map.merge(acc.avatars, page.avatars),
            bots: MapSet.union(acc.bots, page.bots)
        }
    end
  end

  defp first_page(pr, viewer) do
    reviewers =
      (nodes(pr, ["reviewRequests", "nodes"], "requestedReviewer") ++
         nodes(pr, ["latestReviews", "nodes"], "author"))
      |> Enum.flat_map(&List.wrap(actor(&1)))
      |> Enum.uniq_by(& &1["login"])

    commit_nodes = nodes(pr, ["commits", "nodes"], "commit")

    %{
      reviewers: reviewers,
      reactions: reactions(pr["reactionGroups"], viewer),
      reactions_by_id:
        for(
          n <-
            (get_in(pr, ["comments", "nodes"]) || []) ++ (get_in(pr, ["reviews", "nodes"]) || []),
          id = trimmed(n["id"]),
          r = reactions(n["reactionGroups"], viewer),
          r != [],
          into: %{},
          do: {id, r}
        ),
      # A merge commit measured against its first parent would count the base's changes.
      stats:
        for(
          c <- commit_nodes,
          (get_in(c, ["parents", "totalCount"]) || 1) <= 1,
          is_integer(c["additions"]) and is_integer(c["deletions"]),
          into: %{},
          do:
            {c["oid"],
             %{"additions" => max(c["additions"], 0), "deletions" => max(c["deletions"], 0)}}
        ),
      commits: Enum.flat_map(commit_nodes, &graphql_commit/1),
      dismissals:
        for(
          n <- get_in(pr, ["reviewDismissals", "nodes"]) || [],
          id = trimmed(get_in(n, ["review", "id"])),
          message = trimmed(n["dismissalMessage"]),
          into: %{},
          do: {id, message}
        )
    }
  end

  defp graphql_commit(c) do
    with oid when is_binary(oid) <- trimmed(c["oid"]),
         date when is_binary(date) <- trimmed(c["committedDate"]) do
      authors =
        for a <- get_in(c, ["authors", "nodes"]) || [],
            login = trimmed(get_in(a, ["user", "login"])) || trimmed(a["name"]) do
          %{
            "login" => login,
            "name" => trimmed(a["name"]),
            "avatarUrl" => trimmed(a["avatarUrl"])
          }
        end

      [
        %{
          "oid" => oid,
          "messageHeadline" => c["messageHeadline"] || "",
          "committedDate" => date,
          "authors" => authors
        }
      ]
    else
      _ -> []
    end
  end

  defp nodes(pr, path, key), do: for(n <- get_in(pr, path) || [], n, do: n[key])

  defp thread_comment(c, viewer),
    do: %{
      "id" => c["id"],
      "author" => actor(c["author"]),
      "body" => c["body"] || "",
      "createdAt" => c["createdAt"],
      "url" => trimmed(c["url"]),
      "reactions" => reactions(c["reactionGroups"], viewer)
    }

  @doc "The rest of one review thread's comments, refused unless it is this pull request's."
  def thread_comments(ctx, thread_id, cursor) do
    variables = Map.merge(vars(ctx), %{"threadId" => thread_id, "cursor" => cursor})

    with {:ok, data} <- graphql(ctx, @thread_comments_query, variables) do
      own = get_in(data, ["repository", "pullRequest", "id"])
      node = data["node"] || %{}

      if own != nil and own == get_in(node, ["pullRequest", "id"]) do
        viewer = trimmed(get_in(data, ["viewer", "login"]))

        {:ok,
         %{
           "comments" =>
             for(c <- get_in(node, ["comments", "nodes"]) || [], do: thread_comment(c, viewer)),
           "nextCursor" => next_cursor(get_in(node, ["comments", "pageInfo"]))
         }}
      else
        out_of_scope()
      end
    end
  end

  # --- diffs ------------------------------------------------------------------------

  @diff_timeout 60_000
  @diff_max_bytes 8 * 1024 * 1024
  @files_page 100

  @doc """
  `PullRequestDiffResult`: a slice of the patch. The whole change comes from `gh pr
  diff` in one slice; GitHub refuses that past 300 files, and it can be too large to
  hold, so then (and for one commit, or a cursor) the files API is read a page of a
  hundred files at a time, the cursor being the page number.
  """
  def diff(ctx, cursor, commit) do
    page = cursor && Regex.match?(~r/^[1-9][0-9]{0,6}$/, cursor) && String.to_integer(cursor)

    cond do
      commit != nil and not sha?(commit) ->
        {:error, {:failed, "The commit is not one this change can name."}}

      cursor != nil and not is_integer(page) ->
        {:error, {:failed, "The diff cannot be carried on from that cursor."}}

      cursor != nil or commit != nil ->
        files_page(ctx, page || 1, commit)

      true ->
        args = ["pr", "diff", "#{ctx.number}"] ++ repo_args(ctx) ++ ["--color", "never"]

        case gh(ctx.cwd, args, timeout: @diff_timeout, max_bytes: @diff_max_bytes) do
          {:ok, patch} ->
            {:ok, %{"patch" => patch, "truncated" => false, "nextCursor" => nil}}

          # Refused (past 300 files) or too large: the files API serves it in pages. A
          # fallback that fails too reports the refusal, which explains the page.
          {:error, {reason, _}} = refused when reason in [:failed, :too_large] ->
            with {:error, _} <- files_page(ctx, 1, nil), do: refused

          error ->
            error
        end
    end
  end

  # One page of files as a unified patch: the files API gives each file's hunks with
  # no `diff --git` header, so the headers are written here.
  defp files_page(ctx, page, commit) do
    {owner, name} = split(ctx.repository)
    paging = "per_page=#{@files_page}&page=#{page}"

    args =
      if commit,
        do: ["repos/#{owner}/#{name}/commits/#{commit}?#{paging}", "--jq", ".files // []"],
        else: ["repos/#{owner}/#{name}/pulls/#{ctx.number}/files?#{paging}"]

    case gh(ctx.cwd, ["api", "--hostname", ctx.host | args],
           timeout: @diff_timeout,
           max_bytes: @diff_max_bytes
         ) do
      {:ok, out} ->
        case JSON.decode(out) do
          {:ok, files} when is_list(files) ->
            sections =
              for %{"filename" => path} = file when is_binary(path) <- files, do: file_patch(file)

            omitted = for {_, stat} <- sections, stat, do: stat

            {:ok,
             %{
               "patch" => Enum.map_join(sections, &elem(&1, 0)),
               "truncated" => omitted != [],
               # Counted before decoding, so a page of unreadable files still pages on.
               "nextCursor" => if(length(files) >= @files_page, do: "#{page + 1}")
             }
             |> put_present("omittedFileStats", if(omitted != [], do: omitted))}

          _ ->
            decoded(:error)
        end

      {:error, {:too_large, _}} ->
        {:error, {:failed, "Page #{page} of the changed files was too large to read."}}

      error ->
        error
    end
  end

  # A file's section and, for one whose hunks GitHub withheld (binary, or too large to
  # inline), its own line counts. A pure rename has no hunks and nothing withheld.
  defp file_patch(file) do
    path = file["filename"]
    hunks = file["patch"] || ""
    status = String.downcase(file["status"] || "")
    old = if status == "renamed", do: trimmed(file["previous_filename"]) || path, else: path
    additions = file["additions"] || 0
    deletions = file["deletions"] || 0

    header =
      ["diff --git #{quote_path("a/" <> old)} #{quote_path("b/" <> path)}"] ++
        if(status == "added", do: ["new file mode 100644"], else: []) ++
        if(status == "removed", do: ["deleted file mode 100644"], else: []) ++
        if(status == "renamed",
          do: ["rename from #{quote_path(old)}", "rename to #{quote_path(path)}"],
          else: []
        ) ++
        [
          "--- " <> if(status == "added", do: "/dev/null", else: quote_path("a/" <> old)),
          "+++ " <> if(status == "removed", do: "/dev/null", else: quote_path("b/" <> path))
        ]

    body = if hunks == "" or String.ends_with?(hunks, "\n"), do: hunks, else: hunks <> "\n"

    stat =
      if hunks == "" and additions + deletions > 0,
        do: %{"path" => path, "additions" => additions, "deletions" => deletions}

    {Enum.join(header, "\n") <> "\n" <> body, stat}
  end

  @escapes %{
    ?" => "\\\"",
    ?\\ => "\\\\",
    7 => "\\a",
    ?\b => "\\b",
    ?\t => "\\t",
    ?\n => "\\n",
    ?\v => "\\v",
    ?\f => "\\f",
    ?\r => "\\r"
  }

  @doc """
  A path as a patch header carries it, as `quoteGitPatchPath` writes it: git's quoted
  form when it holds a quote, a backslash or a control character.
  """
  def quote_path(path) do
    escaped =
      for <<char::utf8 <- path>>, into: "" do
        cond do
          escape = @escapes[char] ->
            escape

          char < 0x20 or char == 0x7F ->
            "\\" <> String.pad_leading(Integer.to_string(char, 8), 3, "0")

          true ->
            <<char::utf8>>
        end
      end

    if escaped == path, do: path, else: ~s("#{escaped}")
  end

  @doc "Both sides of one file of the pull request (or of one of its commits)."
  def file_contents(ctx, input) do
    commit = input["commit"]
    {owner, name} = split(ctx.repository)

    {path, jq} =
      if commit,
        do: {"commits/#{commit}", "[.parents[0].sha, .sha] | @tsv"},
        else: {"pulls/#{ctx.number}", "[.base.sha, .head.sha] | @tsv"}

    with true <- commit == nil or sha?(commit),
         {:ok, out} <-
           gh(ctx.cwd, [
             "api",
             "--hostname",
             ctx.host,
             "repos/#{owner}/#{name}/#{path}",
             "--jq",
             jq
           ]),
         [base, head] <- out |> String.trim_trailing() |> String.split("\t"),
         true <-
           sha?(head) and
             (sha?(base) or (commit != nil and input["changeType"] == "new" and base == "")) do
      [old, new] =
        Task.await_many(
          [
            Task.async(fn ->
              if input["changeType"] == "new",
                do: {:ok, ""},
                else: raw_file(ctx, base, input["oldPath"])
            end),
            Task.async(fn ->
              if input["changeType"] == "deleted",
                do: {:ok, ""},
                else: raw_file(ctx, head, input["newPath"])
            end)
          ],
          :infinity
        )

      with {:ok, old} <- old,
           {:ok, new} <- new,
           do: {:ok, %{"oldContents" => old, "newContents" => new}}
    else
      {:error, _} = error -> error
      _ -> {:error, {:failed, "The revisions of this change could not be read."}}
    end
  end

  defp raw_file(ctx, revision, path) do
    {owner, name} = split(ctx.repository)

    encoded =
      path |> String.split("/") |> Enum.map_join("/", &encode/1)

    args = [
      "api",
      "--hostname",
      ctx.host,
      "--header",
      "Accept: application/vnd.github.raw+json",
      "repos/#{owner}/#{name}/contents/#{encoded}?ref=#{encode(revision)}"
    ]

    with {:ok, out} <- gh(ctx.cwd, args, timeout: 60_000) do
      cond do
        byte_size(out) > 1024 * 1024 ->
          {:error, {:failed, "#{path} is too large to show."}}

        String.contains?(out, <<0>>) or not String.valid?(out) ->
          {:error, {:failed, "#{path} is a binary file."}}

        true ->
          {:ok, out}
      end
    end
  end

  # As `encodeURIComponent` does, for a path segment or query value.
  defp encode(text), do: URI.encode(text, &URI.char_unreserved?/1)

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{7,64}$/i, value)

  @doc "Which files the signed-in account has marked viewed, five pages at most."
  def files_viewed(ctx) do
    Enum.reduce_while(1..@files_viewed_pages, {nil, []}, fn page, {after_cursor, files} ->
      case graphql(ctx, @files_viewed_query, Map.put(vars(ctx), "after", after_cursor)) do
        {:ok, data} ->
          found = get_in(data, ["repository", "pullRequest", "files"]) || %{}

          files =
            files ++
              for n <- found["nodes"] || [], n, n["path"] not in [nil, ""] do
                state =
                  case up(n["viewerViewedState"]) do
                    "VIEWED" -> "viewed"
                    "DISMISSED" -> "dismissed"
                    _ -> "unviewed"
                  end

                %{"path" => n["path"], "state" => state}
              end

          case next_cursor(found["pageInfo"]) do
            nil ->
              {:halt, {:ok, %{"files" => files, "truncated" => false}}}

            _ when page == @files_viewed_pages ->
              {:halt, {:ok, %{"files" => files, "truncated" => true}}}

            next ->
              {:cont, {next, files}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  @doc "Marks files viewed or not, in one aliased mutation."
  def set_files_viewed(_ctx, []), do: :ok

  def set_files_viewed(ctx, files) do
    params = Enum.map_join(Enum.with_index(files), ", ", fn {_, i} -> "$path#{i}: String!" end)

    fields =
      Enum.map_join(Enum.with_index(files), "\n", fn {file, i} ->
        verb = if file["viewed"], do: "markFileAsViewed", else: "unmarkFileAsViewed"

        "  f#{i}: #{verb}(input: { pullRequestId: $pullRequestId, path: $path#{i} }) { clientMutationId }"
      end)

    with {:ok, id} <- node_id(ctx) do
      variables =
        for(
          {file, i} <- Enum.with_index(files),
          into: %{"pullRequestId" => id},
          do: {"path#{i}", file["path"]}
        )

      done(graphql(ctx, "mutation($pullRequestId: ID!, #{params}) {\n#{fields}\n}", variables))
    end
  end

  # --- changes ----------------------------------------------------------------------

  @doc "Runs a pull request action through `gh pr`, or GraphQL and REST where `gh` has none."
  def action(ctx, "revert", _merge, _update) do
    with {:ok, id} <- node_id(ctx),
         do: done(graphql(ctx, @revert_mutation, %{"pullRequestId" => id}))
  end

  def action(ctx, "approve-workflows", _merge, _update) do
    with {:ok, _detail, pr} <- detail(ctx) do
      cond do
        pr["isCrossRepository"] != true ->
          :ok

        true ->
          with {:ok, runs} <- approval_runs(ctx, pr) do
            Enum.reduce_while(runs, :ok, fn run, :ok ->
              case rest(ctx, "actions/runs/#{run.id}/approve", method: "POST") do
                {:ok, _} -> {:cont, :ok}
                error -> {:halt, error}
              end
            end)
          end
      end
    end
  end

  def action(ctx, action, merge, update) do
    [sub | flags] =
      case action do
        "merge" -> ["merge", "--#{merge || "merge"}"]
        "enable-auto-merge" -> ["merge", "--auto", "--#{merge || "merge"}"]
        "disable-auto-merge" -> ["merge", "--disable-auto"]
        "update-branch" -> ["update-branch" | if(update == "rebase", do: ["--rebase"], else: [])]
        "ready" -> ["ready"]
        "draft" -> ["ready", "--undo"]
        "close" -> ["close"]
        "reopen" -> ["reopen"]
      end

    done(gh(ctx.cwd, ["pr", sub, "#{ctx.number}"] ++ repo_args(ctx) ++ flags))
  end

  def comment(ctx, body),
    do:
      done(
        gh(ctx.cwd, ["pr", "comment", "#{ctx.number}"] ++ repo_args(ctx) ++ ["--body-file", "-"],
          input: body
        )
      )

  @doc "Rewrites the title, the description, or both; an absent one is left as it is."
  def update(ctx, fields) do
    with {:ok, id} <- node_id(ctx),
         do: done(graphql(ctx, @update_mutation, Map.put(fields, "pullRequestId", id)))
  end

  def update_comment(ctx, id, kind, body) do
    with :ok <- own_subject(ctx, id),
         do: done(graphql(ctx, @comment_mutations[kind], %{"commentId" => id, "body" => body}))
  end

  @doc "Submits a whole review, its line comments with it."
  def submit_review(ctx, verdict, body, comments) do
    review = %{
      "event" =>
        %{"comment" => "COMMENT", "approve" => "APPROVE", "request-changes" => "REQUEST_CHANGES"}[
          verdict
        ],
      "body" => body,
      "comments" =>
        for c <- comments do
          {line, side} =
            case c["position"] do
              %{"kind" => "added", "newLine" => line} -> {line, "RIGHT"}
              %{"kind" => "deleted", "oldLine" => line} -> {line, "LEFT"}
              %{"kind" => "context", "side" => "left", "oldLine" => line} -> {line, "LEFT"}
              %{"kind" => "context", "newLine" => line} -> {line, "RIGHT"}
            end

          %{"path" => c["path"], "line" => line, "side" => side, "body" => c["body"]}
        end
    }

    done(rest(ctx, "pulls/#{ctx.number}/reviews", method: "POST", input: JSON.encode!(review)))
  end

  def reply(ctx, thread_id, body),
    do: done(graphql(ctx, @reply_mutation, %{"threadId" => thread_id, "body" => body}))

  def resolve(ctx, thread_id, resolved),
    do: done(graphql(ctx, @resolution_mutations[resolved == true], %{"threadId" => thread_id}))

  @doc "Reacts to a remark, or to the pull request itself when `subject` is nil."
  def react(ctx, subject, content, reacted) do
    subject =
      if subject,
        do: with(:ok <- own_subject(ctx, subject), do: {:ok, subject}),
        else: node_id(ctx)

    content = Enum.find_value(@reactions, fn {github, ours} -> ours == content && github end)

    with {:ok, subject} <- subject,
         do:
           done(
             graphql(ctx, @reaction_mutations[reacted == true], %{
               "subjectId" => subject,
               "content" => content
             })
           )
  end

  @doc "Who a review may be asked of, whoever is already asked first; never the author."
  def reviewer_candidates(ctx) do
    with {:ok, data} <- graphql(ctx, @reviewer_candidates_query, vars(ctx)),
         %{} = repo <- data["repository"] do
      author = trimmed(get_in(repo, ["pullRequest", "author", "login"]))

      requested =
        for r <-
              nodes(repo["pullRequest"] || %{}, ["reviewRequests", "nodes"], "requestedReviewer"),
            r,
            id = trimmed(r["slug"]) || trimmed(r["login"]) do
          candidate(r, id, if(trimmed(r["slug"]), do: "team", else: "user"), true)
        end

      assignable =
        for u <- get_in(repo, ["assignableUsers", "nodes"]) || [],
            u,
            login = trimmed(u["login"]),
            login != author,
            not Enum.any?(requested, &(&1["kind"] == "user" and &1["id"] == login)) do
          candidate(u, login, "user", false)
        end

      {:ok,
       %{
         "candidates" => requested ++ assignable,
         "truncated" => get_in(repo, ["assignableUsers", "pageInfo", "hasNextPage"]) == true
       }}
    else
      {:error, _} = error -> error
      _ -> not_found(ctx)
    end
  end

  defp candidate(raw, id, kind, requested?),
    do: %{
      "id" => id,
      "kind" => kind,
      "login" => id,
      "name" => trimmed(raw["name"]),
      "avatarUrl" => trimmed(raw["avatarUrl"]),
      "isRequested" => requested?
    }

  def request_reviewers(ctx, reviewers, requested) do
    body = %{
      "reviewers" => for(%{"kind" => "user", "id" => id} <- reviewers, do: id),
      "team_reviewers" => for(%{"kind" => "team", "id" => id} <- reviewers, do: id)
    }

    method = if requested, do: "POST", else: "DELETE"

    done(
      rest(ctx, "pulls/#{ctx.number}/requested_reviewers",
        method: method,
        input: JSON.encode!(body)
      )
    )
  end

  @doc "The repository's labels, with the applied ones marked; an applied one it no longer defines leads."
  def label_candidates(ctx) do
    with {:ok, data} <- graphql(ctx, @label_candidates_query, vars(ctx)),
         %{} = repo <- data["repository"] do
      applied =
        for l <- get_in(repo, ["pullRequest", "labels", "nodes"]) || [],
            l,
            name = trimmed(l["name"]),
            do: name

      defined =
        for l <- get_in(repo, ["labels", "nodes"]) || [], l, name = trimmed(l["name"]) do
          %{
            "name" => name,
            "color" => trimmed(l["color"]),
            "description" => trimmed(l["description"]),
            "isApplied" => name in applied
          }
        end

      missing =
        for name <- applied,
            not Enum.any?(defined, &(&1["name"] == name)),
            do: %{"name" => name, "color" => nil, "description" => nil, "isApplied" => true}

      {:ok,
       %{
         "candidates" => missing ++ defined,
         "truncated" => get_in(repo, ["labels", "pageInfo", "hasNextPage"]) == true
       }}
    else
      {:error, _} = error -> error
      _ -> not_found(ctx)
    end
  end

  # A pull request is an issue to the labels API; taking a label off is one delete each.
  def set_labels(ctx, labels, true),
    do:
      done(
        rest(ctx, "issues/#{ctx.number}/labels",
          method: "POST",
          input: JSON.encode!(%{"labels" => labels})
        )
      )

  def set_labels(ctx, labels, false) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      path = "issues/#{ctx.number}/labels/#{encode(label)}"

      case rest(ctx, path, method: "DELETE") do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp node_id(ctx) do
    case graphql(ctx, @node_id_query, vars(ctx)) do
      {:ok, %{"repository" => %{"pullRequest" => %{"id" => id}}}} -> {:ok, id}
      {:ok, _} -> not_found(ctx)
      error -> error
    end
  end

  # A client-given node id can name a remark on any pull request on the host, so it
  # is checked against the one the request names before anything is written.
  defp own_subject(ctx, subject) do
    case graphql(ctx, @subject_query, Map.put(vars(ctx), "subjectId", subject)) do
      {:ok, data} ->
        own = get_in(data, ["repository", "pullRequest", "id"])
        node = data["node"]
        actual = node && (get_in(node, ["pullRequest", "id"]) || node["id"])
        if own != nil and own == actual, do: :ok, else: out_of_scope()

      error ->
        error
    end
  end

  defp done({:ok, _}), do: :ok
  defp done(error), do: error

  defp not_found(ctx), do: {:error, {:not_found, "Pull request ##{ctx.number} was not found."}}
  defp out_of_scope, do: {:error, {:failed, "That remark does not belong to this pull request."}}

  # --- JSON ----------------------------------------------------------------------------

  @doc "A `PullRequestActor`, or nil for anyone with no login."
  def actor(nil), do: nil

  def actor(raw) do
    with login when is_binary(login) <- trimmed(raw["login"]) do
      %{
        "login" => login,
        "name" => trimmed(raw["name"]),
        "avatarUrl" => trimmed(raw["avatarUrl"])
      }
      |> put_present("isBot", if(raw["__typename"] == "Bot" or raw["is_bot"] == true, do: true))
    end
  end

  @doc """
  An actor with a face: the one GitHub reported, else the one every install serves at
  `/<login>.png`. Apps post as `name[bot]`, which names no picture.
  """
  def with_avatar(actor, host, avatars \\ %{}, bots \\ MapSet.new())
  def with_avatar(nil, _host, _avatars, _bots), do: nil

  def with_avatar(actor, host, avatars, bots) do
    actor =
      if MapSet.member?(bots, actor["login"]), do: Map.put(actor, "isBot", true), else: actor

    fallback =
      if Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,38}$/i, actor["login"]),
        do: "https://#{host}/#{actor["login"]}.png?size=80"

    %{actor | "avatarUrl" => actor["avatarUrl"] || avatars[actor["login"]] || fallback}
  end

  def state(raw) do
    cond do
      trimmed(raw["mergedAt"]) -> "merged"
      up(raw["state"]) == "MERGED" -> "merged"
      up(raw["state"]) == "CLOSED" -> "closed"
      true -> "open"
    end
  end

  defp mergeability(value) do
    case up(value) do
      "MERGEABLE" -> "mergeable"
      "CONFLICTING" -> "conflicting"
      _ -> "unknown"
    end
  end

  defp merge_method(value) do
    case up(value) do
      method when method in ~w(MERGE SQUASH REBASE) -> String.downcase(method)
      _ -> nil
    end
  end

  # GitHub's own decision counts only reviews that satisfy branch rules; when it has
  # none, the latest review per reviewer decides, changes requested first.
  defp review_decision(value, latest) do
    summarized =
      case up(value) do
        "APPROVED" -> "approved"
        "CHANGES_REQUESTED" -> "changes-requested"
        "REVIEW_REQUIRED" -> "review-required"
        _ -> nil
      end

    reviews = if is_map(latest), do: latest["nodes"] || [], else: latest || []
    states = MapSet.new(reviews, &up(&1 && &1["state"]))

    cond do
      summarized in ["approved", "changes-requested"] -> summarized
      "CHANGES_REQUESTED" in states -> "changes-requested"
      "APPROVED" in states -> "approved"
      true -> summarized
    end
  end

  defp labels(raw),
    do:
      for(
        l <- raw || [],
        name = trimmed(l["name"]),
        do: %{"name" => name, "color" => trimmed(l["color"])}
      )

  defp check_status(check) do
    status = up(check["status"])

    if status not in [nil, "", "COMPLETED"] do
      "pending"
    else
      case up(check["conclusion"] || check["state"]) do
        "SUCCESS" -> "success"
        "ACTION_REQUIRED" -> "action-required"
        s when s in ~w(FAILURE ERROR TIMED_OUT STARTUP_FAILURE) -> "failure"
        "CANCELLED" -> "cancelled"
        "SKIPPED" -> "skipped"
        s when s in ~w(PENDING EXPECTED) -> "pending"
        _ -> "neutral"
      end
    end
  end

  @doc """
  `PullRequestCheck`s, one per check rather than per run of it: the newest run of each
  workflow and name, in the order each first appeared; names shared across workflows
  read `workflow / name`.
  """
  def checks(raw) do
    entries =
      for c <- raw || [], name = trimmed(c["name"]) || trimmed(c["context"]) do
        check = %{
          "name" => name,
          "status" => check_status(c),
          "description" => trimmed(c["description"]),
          "url" => trimmed(c["detailsUrl"]) || trimmed(c["targetUrl"])
        }

        {check, trimmed(c["workflowName"]),
         timestamp(c["completedAt"]) || timestamp(c["startedAt"])}
      end

    {order, newest} =
      Enum.reduce(entries, {[], %{}}, fn {check, workflow, at} = entry, {order, newest} ->
        key = {workflow, check["name"]}

        case newest do
          %{^key => {_, _, kept}} ->
            if newer?(at, kept), do: {order, Map.put(newest, key, entry)}, else: {order, newest}

          _ ->
            {[key | order], Map.put(newest, key, entry)}
        end
      end)

    survivors = order |> Enum.reverse() |> Enum.map(&newest[&1])
    counts = Enum.frequencies_by(survivors, fn {check, _, _} -> check["name"] end)

    for {check, workflow, _} <- survivors do
      if workflow && counts[check["name"]] > 1,
        do: %{check | "name" => "#{workflow} / #{check["name"]}"},
        else: check
    end
  end

  defp newer?(nil, kept), do: kept == nil
  defp newer?(at, kept), do: kept == nil or at >= kept

  defp timestamp(value) do
    case trimmed(value) do
      "0001-01-01T00:00:00Z" -> nil
      at -> at
    end
  end

  # The one word a row has room for; a failure outranks anything still running.
  defp rollup(raw) do
    statuses =
      Enum.map(checks(raw), & &1["status"]) ++
        for c <- raw || [],
            trimmed(c["name"]) == nil and trimmed(c["context"]) == nil,
            do: check_status(c)

    cond do
      Enum.any?(statuses, &(&1 in ["failure", "cancelled"])) -> "failing"
      Enum.any?(statuses, &(&1 in ["pending", "action-required"])) -> "pending"
      "success" in statuses -> "passing"
      true -> nil
    end
  end

  # The viewer's own login is left out of `actors`; `count` still counts them.
  defp reactions(groups, viewer) do
    me = viewer && String.downcase(viewer)

    for g <- groups || [], content = @reactions[up(g["content"])] do
      logins =
        for n <- get_in(g, ["reactors", "nodes"]) || [],
            login = n && trimmed(n["login"]),
            do: login

      count = max(get_in(g, ["reactors", "totalCount"]) || length(logins), length(logins))

      %{
        "content" => content,
        "count" => count,
        "actors" => Enum.reject(logins, &(String.downcase(&1) == me)),
        "viewerHasReacted" => g["viewerHasReacted"] == true
      }
    end
    |> Enum.filter(&(&1["count"] > 0))
  end

  defp next_cursor(%{"hasNextPage" => true} = page_info), do: trimmed(page_info["endCursor"])
  defp next_cursor(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_), do: nil

  defp up(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp up(_), do: nil

  defp first_line(text) do
    text |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))
  end
end
