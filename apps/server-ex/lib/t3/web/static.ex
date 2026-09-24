defmodule T3.Web.Static do
  @moduledoc """
  The web app, served by the node as `npx t3` serves it: files from the built app,
  and its `index.html` for any other path so the app routes it (`/pair#token=…`
  included). Build assets named by their content hash are cached for good;
  everything else revalidates.

  The app comes from `T3_STATIC_DIR`, else the release's `priv/web` (copied in when
  the release is built), else in development the checkout's `apps/web/dist`.
  Without one the node
  serves no app.
  """

  import Plug.Conn

  # A checkout's own build, in development only: releases carry theirs in `priv/web`.
  @checkout if Mix.env() == :dev, do: Path.expand("../../../../web/dist", __DIR__)

  @doc "The directory holding the built app, or nil."
  @spec dir() :: String.t() | nil
  def dir do
    [System.get_env("T3_STATIC_DIR"), Application.app_dir(:t3, "priv/web"), @checkout]
    |> Enum.find(&(is_binary(&1) and File.regular?(Path.join(&1, "index.html"))))
  end

  @doc "Answers a GET from the app in `dir`."
  @spec serve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def serve(conn, dir) do
    if Enum.any?(conn.path_info, &(&1 in [".", ".."] or String.contains?(&1, ["\\", <<0>>]))) do
      send_resp(conn, 400, "Invalid static file path")
    else
      relative = Path.join(["." | conn.path_info])

      path =
        [relative, Path.join(relative, "index.html"), "index.html"]
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.find(&File.regular?/1)

      send_static(conn, dir, path)
    end
  end

  defp send_static(conn, _dir, nil), do: send_resp(conn, 404, "Not Found")

  defp send_static(conn, dir, path) do
    type = MIME.from_path(path)
    html? = type == "text/html"

    immutable? =
      not html? and Regex.match?(~r"^assets/.+-[\w-]{8}\.[^/]+$", Path.relative_to(path, dir))

    conn
    |> put_resp_header(
      "cache-control",
      if(immutable?, do: "public, max-age=31536000, immutable", else: "no-cache")
    )
    |> put_resp_content_type(type, if(html?, do: "utf-8"))
    |> send_file(200, path)
  end
end
