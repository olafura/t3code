defmodule T3.Mcp.Tools.PullRequests do
  @moduledoc """
  MCP tools that link the pull requests an agent opens to its own thread, so T3
  tracks them beside it (`T3.Mcp.Tools`). A pull request is named by its URL, or
  by repository and number on the project's host.
  """

  import T3.Mcp.Tools, only: [command_id: 0, orchestration: 1, project_row: 1, thread: 1]

  alias T3.Orchestration
  alias T3.Projection.PullRequests

  @tools ~w(link_pull_request unlink_pull_request list_thread_pull_requests)

  def tools, do: @tools

  def run("link_pull_request", args, %{row: me}) do
    with {:ok, target} <- target(args, me) do
      existing = Enum.find(links(me["id"]), &same?(&1, target))

      if existing && existing["source"] != "stack-dismissed" do
        {:ok, Map.put(target, "alreadyLinked", true)}
      else
        with {:ok, _} <-
               orchestration(
                 Orchestration.dispatch(
                   Map.merge(target, %{
                     "type" => "thread.pull-request.link",
                     "commandId" => command_id(),
                     "threadId" => me["id"],
                     "source" => "agent"
                   })
                 )
               ),
             do: {:ok, Map.put(target, "alreadyLinked", false)}
      end
    end
  end

  def run("unlink_pull_request", args, %{row: me}) do
    with {:ok, target} <- target(args, me) do
      key = Map.take(target, ~w(host repository number))

      if Enum.any?(links(me["id"]), &same?(&1, target)) do
        with {:ok, _} <-
               orchestration(
                 Orchestration.dispatch(
                   Map.merge(key, %{
                     "type" => "thread.pull-request.unlink",
                     "commandId" => command_id(),
                     "threadId" => me["id"]
                   })
                 )
               ),
             do: {:ok, Map.put(key, "wasLinked", true)}
      else
        {:ok, Map.put(key, "wasLinked", false)}
      end
    end
  end

  def run("list_thread_pull_requests", _args, %{row: me}) do
    visible = Enum.reject(links(me["id"]), &(&1["source"] == "stack-dismissed"))
    chains = chains(visible)

    {:ok,
     %{
       "pullRequests" => Enum.map(visible, &entry(&1, chains)),
       "chains" =>
         for(
           {kind, layers} <- chains,
           do: %{"kind" => kind, "numbers" => Enum.map(layers, & &1["number"])}
         )
     }}
  end

  # --- helpers ----------------------------------------------------------------------------

  defp links(thread_id), do: PullRequests.of(thread(thread_id) || %{})

  defp same?(link, target),
    do: key(link) == key(target)

  defp key(link),
    do:
      "#{String.downcase(link["host"] || "")}/#{String.downcase(link["repository"] || "")}##{link["number"]}"

  defp repository_key(link),
    do: "#{String.downcase(link["host"] || "")}/#{String.downcase(link["repository"] || "")}"

  # Whichever shape the agent passed, as one host-level identity. A URL wins;
  # otherwise the repository is taken to be on the project's host.
  defp target(%{"url" => url}, _me) when is_binary(url) do
    case PullRequests.parse_change_request_url(url) do
      nil ->
        {:error, "invalid_request",
         "This is not a recognised pull request URL. Pass repository and number instead."}

      parsed ->
        {:ok,
         %{
           "host" => Map.get(parsed, :authority, parsed.host),
           "repository" => parsed.repository,
           "number" => parsed.number,
           "url" => url
         }}
    end
  end

  defp target(%{"repository" => repository, "number" => number} = args, me)
       when is_binary(repository) and is_integer(number) do
    remote = project_remote(me["projectId"])

    case args["host"] || (remote && remote.host) do
      nil ->
        {:error, "invalid_request",
         "This thread's project has no recognised remote. Pass host or url."}

      host ->
        host = String.downcase(host)
        repository = String.downcase(repository)
        kind = if remote && remote.host == host, do: remote.kind

        {:ok,
         %{
           "host" => host,
           "repository" => repository,
           "number" => number,
           "url" => url(kind, host, repository, number)
         }}
    end
  end

  defp target(_args, _me),
    do: {:error, "invalid_request", "Pass either url, or both repository and number."}

  defp project_remote(project_id) do
    with %{"workspaceRoot" => root} <- project_row(project_id),
         {:ok, url} <- T3.Git.ok(root, ~w(remote get-url origin)),
         do: T3.PullRequests.parse_remote(url),
         else: (_ -> nil)
  end

  defp url("gitlab", host, repository, number),
    do: "https://#{host}/#{repository}/-/merge_requests/#{number}"

  defp url("forgejo", host, repository, number),
    do: "https://#{host}/#{repository}/pulls/#{number}"

  defp url("bitbucket", host, repository, number),
    do: "https://#{host}/#{repository}/pull-requests/#{number}"

  defp url("azure-devops", host, repository, number),
    do: "https://#{host}/#{repository}/pullrequest/#{number}"

  defp url(_kind, host, repository, number),
    do: "https://#{host}/#{repository}/pull/#{number}"

  defp entry(link, chains) do
    snapshot = link["snapshot"] || %{}

    stack =
      Enum.find_value(chains, fn {kind, layers} ->
        index = Enum.find_index(layers, &(key(&1) == key(link)))

        if length(layers) > 1 and index,
          do: %{"kind" => kind, "position" => index + 1, "size" => length(layers)}
      end)

    %{
      "host" => String.downcase(link["host"] || ""),
      "repository" => link["repository"],
      "number" => link["number"],
      "url" => link["url"],
      "source" => link["source"],
      "state" => snapshot["state"],
      "title" => snapshot["title"],
      "headBranch" => snapshot["headBranch"],
      "baseBranch" => snapshot["baseBranch"],
      "isDraft" => snapshot["isDraft"],
      "stack" => stack
    }
  end

  # How linked pull requests stack, bottom to top (`resolveThreadPullRequestChains` in
  # the shared package): host-native stacks first, then chains derived from each pull
  # request's base branch being another's head branch.
  defp chains(links) do
    native =
      links
      |> Enum.filter(& &1["stack"])
      |> Enum.group_by(&"#{repository_key(&1)}#stack:#{&1["stack"]["id"]}")
      |> Map.values()
      |> Enum.map(fn [first | _] = members ->
        order =
          (first["stack"]["layers"] || [])
          |> Enum.with_index()
          |> Map.new(fn {layer, index} -> {layer["number"], index} end)

        {"native", Enum.sort_by(members, &Map.get(order, &1["number"], 0))}
      end)

    placed = MapSet.new(for {_, layers} <- native, layer <- layers, do: key(layer))
    remaining = Enum.reject(links, &MapSet.member?(placed, key(&1)))
    branch = fn link, name -> "#{repository_key(link)}:#{name}" end

    # A head branch used twice cannot name a parent.
    by_head =
      Enum.reduce(remaining, %{}, fn link, acc ->
        case link["snapshot"] do
          nil ->
            acc

          snapshot ->
            Map.update(acc, branch.(link, snapshot["headBranch"]), link, fn _ -> :ambiguous end)
        end
      end)

    parent = fn link ->
      case link["snapshot"] &&
             Map.get(by_head, branch.(link, link["snapshot"]["baseBranch"])) do
        %{} = parent -> if key(parent) != key(link), do: parent
        _ -> nil
      end
    end

    has_child = MapSet.new(for link <- remaining, p = parent.(link), do: key(p))

    {derived, placed} =
      remaining
      |> Enum.reject(&MapSet.member?(has_child, key(&1)))
      |> Enum.reduce({[], placed}, fn top, {chains, placed} ->
        {layers, placed} = walk(top, parent, [], placed)
        {if(layers == [], do: chains, else: chains ++ [{"derived", layers}]), placed}
      end)

    # Cycles have no top; their links stay visible on their own.
    cycles = for link <- remaining, not MapSet.member?(placed, key(link)), do: {"derived", [link]}

    native ++ derived ++ cycles
  end

  defp walk(nil, _parent, layers, placed), do: {layers, placed}

  defp walk(link, parent, layers, placed) do
    if MapSet.member?(placed, key(link)),
      do: {layers, placed},
      else: walk(parent.(link), parent, [link | layers], MapSet.put(placed, key(link)))
  end
end
