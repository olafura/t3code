defmodule T3.Projection.PullRequests do
  @moduledoc """
  A thread's pull request links, ported from the parts of the Node server's
  `threadPullRequests.ts` and `changeRequestUrl.ts` the shell needs.

  Older thread payloads stored a single `linkedPullRequest`; `of/1` turns it into a
  one-element link list. An explicit `pullRequests` array, even an empty one, wins.
  """

  import T3.Projection.JS, only: [get: 2, json: 1, trim: 1]

  @spec of(map) :: [map]
  def of(thread) do
    case Map.fetch(thread, "pullRequests") do
      {:ok, links} ->
        json(links)

      :error ->
        case get(thread, "linkedPullRequest") do
          nil ->
            []

          linked ->
            [
              linked
              |> legacy_key()
              |> Map.merge(%{
                "url" => get(linked, "url"),
                "source" => "manual",
                "linkedAt" => "1970-01-01T00:00:00.000Z",
                "snapshot" => nil,
                "stack" => nil
              })
            ]
        end
    end
  end

  # Legacy Azure selectors omit the organization and project; recover them from the URL.
  defp legacy_key(linked) do
    url = get(linked, "url")
    number = get(linked, "number")
    parsed = parse_change_request_url(url)

    if parsed != nil and parsed.number == number and
         (Map.has_key?(parsed, :authority) or
            String.starts_with?(
              canonical_repository_key("#{parsed.host}/#{parsed.repository}"),
              "dev.azure.com/"
            )) do
      normalize_key(parsed)
    else
      host =
        case URI.new(url) do
          {:ok, %URI{host: host}} when is_binary(host) -> host
          {:ok, _} -> ""
          {:error, _} -> "unknown"
        end

      host = host |> trim() |> String.downcase()

      %{
        "host" => if(host == "", do: "unknown", else: host),
        "repository" => get(linked, "repository") |> trim() |> String.downcase(),
        "number" => number
      }
    end
  end

  defp normalize_key(key) do
    canonical =
      canonical_repository_key(
        "#{(key[:authority] || key.host) |> trim() |> String.downcase()}/#{key.repository |> trim() |> String.downcase()}"
      )

    [host, repository] = String.split(canonical, "/", parts: 2)
    %{"host" => host, "repository" => repository, "number" => key.number}
  end

  @doc "The host, repository and number behind a change request URL, or `nil`."
  @spec parse_change_request_url(String.t()) :: map | nil
  def parse_change_request_url(url) do
    with true <- is_binary(url),
         {:ok, %URI{scheme: scheme, host: host} = uri}
         when scheme in ["http", "https"] and is_binary(host) <-
           URI.new(url) do
      host = String.downcase(host)
      path = uri.path || "/"

      github =
        host_of?(host, "github.com", "github") &&
          Regex.run(~r{^/([^/]+/[^/]+)/pull/([0-9]+)(?:/|\z)}u, path)

      cond do
        github ->
          claim(host, github)

        match = Regex.run(~r{^/([^/]+(?:/[^/]+)+)/pulls/([0-9]+)(?:/|\z)}u, path) ->
          with %{} = link <- claim(host, match), do: Map.put(link, :authority, authority(uri))

        match = Regex.run(~r{^/([^/]+(?:/[^/]+)+)/-/merge_requests/([0-9]+)(?:/|\z)}u, path) ->
          claim(host, match)

        host_of?(host, "bitbucket.org", "bitbucket") ->
          claim(host, Regex.run(~r{^/([^/]+/[^/]+)/pull-requests/([0-9]+)(?:/|\z)}u, path))

        host_of?(host, "dev.azure.com", nil) or String.ends_with?(host, ".visualstudio.com") ->
          claim(
            host,
            Regex.run(~r{^/((?:[^/]+/)*_git/[^/]+)/pullrequest/([0-9]+)(?:/|\z)}u, path)
          )

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp host_of?(host, apex, label) do
    host == apex or String.ends_with?(host, "." <> apex) or
      (label != nil and label in String.split(host, "."))
  end

  defp claim(host, [_, repository, digits]) do
    number = String.to_integer(digits)

    if repository != "" and number > 0 and number <= 9_007_199_254_740_991,
      do: %{host: host, repository: String.downcase(repository), number: number}
  end

  defp claim(_host, nil), do: nil

  # URL#host: the port only when it is not the scheme's default.
  defp authority(%URI{host: host, port: port, scheme: scheme}) do
    host = String.downcase(host)
    if port == nil or port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp canonical_repository_key(key) do
    key
    |> String.replace(
      ~r{^(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)/v3/([^/]+)/([^/]+)/([^/]+)\z}u,
      "dev.azure.com/\\1/\\2/_git/\\3"
    )
    |> String.replace(
      ~r{^([^.]+)\.visualstudio\.com/(?:defaultcollection/)?([^/]+)/_git/([^/]+)\z}u,
      "dev.azure.com/\\1/\\2/_git/\\3"
    )
  end
end
