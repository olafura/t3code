defmodule T3.Repository do
  @moduledoc """
  Which hosted repository a checkout is a clone of (the contracts' `RepositoryIdentity`),
  as the Node server resolves it: the checkout's top level and its primary remote
  (`upstream`, then `origin`, then the first by name). Clients group projects on
  different machines by its `canonicalKey`, and pull requests find their repository
  through it.
  """

  @doc "The identity of the repository holding `root`, or nil outside one or without a remote."
  @spec identity(String.t()) :: map | nil
  def identity(root) do
    with {:ok, top} <- T3.Git.ok(root, ~w(rev-parse --show-toplevel)),
         top when top != "" <- String.trim(top),
         {:ok, out} <- T3.Git.ok(top, ~w(remote -v)),
         {name, url} <- primary(out) do
      build(name, url, top)
    else
      _ -> nil
    end
  end

  defp primary(out) do
    remotes =
      for line <- String.split(out, "\n"),
          [_, name, url] <- [Regex.run(~r/^(\S+)\s+(\S+)\s+\(fetch\)$/, String.trim(line))],
          into: %{},
          do: {name, url}

    Enum.find_value(["upstream", "origin"], &(remotes[&1] && {&1, remotes[&1]})) ||
      remotes |> Enum.sort() |> List.first()
  end

  defp build(name, url, root) do
    key = T3.AgentSessions.remote_key(url)
    path = key |> String.split("/") |> Enum.drop(1) |> Enum.join("/")
    segments = String.split(path, "/", trim: true)

    %{
      "canonicalKey" => key,
      "locator" => %{"source" => "git-remote", "remoteName" => name, "remoteUrl" => url},
      "rootPath" => root,
      "displayName" => if(path != "", do: path),
      "provider" => provider(url),
      "owner" => List.first(segments),
      "name" => List.last(segments)
    }
    |> Map.reject(fn {_, value} -> value in [nil, ""] end)
  end

  @doc "The kind of host a remote URL points at, as `@t3tools/shared/sourceControl` names it."
  @spec provider(String.t()) :: String.t() | nil
  def provider(url) do
    case host(url) do
      nil ->
        nil

      host ->
        labels = String.split(host, ".")

        cond do
          host == "codeberg.org" or "forgejo" in labels or "gitea" in labels ->
            "forgejo"

          host == "github.com" or "github" in labels ->
            "github"

          host == "gitlab.com" or "gitlab" in labels ->
            "gitlab"

          host == "dev.azure.com" or
              String.ends_with?(host, [".dev.azure.com", ".visualstudio.com"]) ->
            "azure-devops"

          host == "bitbucket.org" or "bitbucket" in labels ->
            "bitbucket"

          true ->
            "unknown"
        end
    end
  end

  defp host(url) do
    url = String.trim(url)

    case Regex.run(~r/^[a-zA-Z0-9._-]+@([^:\/]+):/, url) do
      [_, host] ->
        String.downcase(host)

      nil ->
        case URI.new(url) do
          {:ok, %URI{host: host}} when is_binary(host) and host != "" -> String.downcase(host)
          _ -> nil
        end
    end
  end
end
