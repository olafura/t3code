defmodule T3.Attachments do
  @moduledoc """
  Chat attachments and file URLs (`attachments.createUploadUrl`, `attachments.delete`,
  `assets.createUrl`), as the Node server serves them.

  A client asks the thread's node for a signed upload URL, sends the bytes to it,
  and names the upload in its message; the message's node then claims it into the
  thread (`claim/2`), and providers read the file from `path/1`. Asset URLs are
  signed the same way and serve an attachment or a project file.

  A client reaches every node through one: signed URLs name the node that issued
  them, the node that receives the request forwards it there (`T3.Web.Router`),
  and only the issuing node checks the signature, with its own key.
  """

  @upload_ttl_ms 10 * 60_000
  @asset_ttl_ms 60 * 60_000
  @max_image_bytes 10 * 1024 * 1024
  @max_file_bytes 50 * 1024 * 1024
  @pending_max_age_s 24 * 60 * 60
  @image_types %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/jpg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/svg+xml" => ".svg",
    "image/bmp" => ".bmp",
    "image/avif" => ".avif",
    "image/heic" => ".heic",
    "image/heif" => ".heif",
    "image/tiff" => ".tiff"
  }
  # What a media URL may serve from outside a project.
  @media_extensions ~w(.png .jpg .jpeg .gif .webp .svg .bmp .avif .ico .mp4 .webm .mov .m4v .html .htm .pdf)

  # --- uploads ---------------------------------------------------------------------

  @doc "`attachments.createUploadUrl`: an id for the upload and where to send it."
  def create_upload_url(%{"name" => name, "mimeType" => mime, "sizeBytes" => size} = input) do
    type = input["type"] || "image"
    limit = if type == "file", do: @max_file_bytes, else: @max_image_bytes

    if is_integer(size) and size >= 1 and size <= limit do
      sweep_pending()
      id = "pending-#{T3.Environment.uuid4()}" <> id_suffix(type, name)
      expires = now_ms() + @upload_ttl_ms

      claims = %{
        "kind" => "attachment-upload",
        "type" => type,
        "attachmentId" => id,
        "name" => name,
        "mimeType" => mime,
        "sizeBytes" => size,
        "expiresAt" => expires
      }

      {:ok,
       %{
         "attachmentId" => id,
         "relativeUrl" => "/api/attachments/upload/" <> sign(claims),
         "expiresAt" => expires
       }}
    else
      {:error, "Attachments may be at most #{div(limit, 1024 * 1024)} MB."}
    end
  end

  @doc "Stores an upload's bytes on this node, if its signed token is valid."
  def store(token, body) do
    with {:ok, %{"kind" => "attachment-upload"} = claims} <- verify(token),
         true <-
           byte_size(body) == claims["sizeBytes"] || {:error, 400, "The body is the wrong size."} do
      path =
        Path.join(
          dir(),
          claims["attachmentId"] <> extension(claims["type"], claims["mimeType"], claims["name"])
        )

      File.mkdir_p!(dir())
      part = path <> ".part"
      File.write!(part, body)
      File.rename!(part, path)
      :ok
    else
      {:ok, _other} -> {:error, 403, "Not an upload URL."}
      {:error, status, message} -> {:error, status, message}
      {:error, message} -> {:error, 403, message}
    end
  end

  @doc "`attachments.delete`: drops an upload no message took."
  def delete(%{"attachmentId" => "pending-" <> _ = id}) do
    if safe_id?(id), do: Enum.each(Path.wildcard(Path.join(dir(), id <> ".*")), &File.rm/1)
    {:ok, nil}
  end

  def delete(_input), do: {:ok, nil}

  @doc """
  Moves a message's pending uploads into its thread: each is copied under a
  thread-scoped id, which the message then names. Attachments the thread already
  has pass through.
  """
  def claim(thread_id, attachments) when is_list(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case claim_one(thread_id, attachment) do
        {:ok, claimed} -> {:cont, {:ok, [claimed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, claimed} -> {:ok, Enum.reverse(claimed)}
      error -> error
    end
  end

  def claim(_thread_id, _attachments), do: {:ok, []}

  defp claim_one(thread_id, %{"id" => "pending-" <> rest = id} = attachment) do
    with true <- safe_id?(id) || {:error, "Attachment '#{attachment["name"]}' has a bad id."},
         [source] <- Path.wildcard(Path.join(dir(), id <> ".*")),
         {:ok, %File.Stat{size: size}} <- File.stat(source),
         true <-
           size == attachment["sizeBytes"] ||
             {:error, "Attachment '#{attachment["name"]}' does not match its upload."} do
      claimed_id = "#{thread_segment(thread_id)}-#{rest}"
      File.cp!(source, Path.join(dir(), claimed_id <> Path.extname(source)))
      {:ok, Map.put(attachment, "id", claimed_id)}
    else
      [] -> {:error, "Attachment '#{attachment["name"]}' was not uploaded."}
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Attachment '#{attachment["name"]}' cannot be sent."}
    end
  end

  defp claim_one(_thread_id, attachment), do: {:ok, attachment}

  @doc """
  `assets.persistChatAttachments`: images a client sends inline (pasted), stored
  straight into the thread as its attachments.
  """
  def persist(%{"threadId" => thread_id, "attachments" => attachments}) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      with "data:" <> rest <- attachment["dataUrl"] || "",
           [header, data] <- String.split(rest, ",", parts: 2),
           true <- String.ends_with?(header, ";base64"),
           {:ok, bytes} <- Base.decode64(data, ignore: :whitespace),
           true <- byte_size(bytes) <= @max_image_bytes do
        mime = attachment["mimeType"] || String.replace_suffix(header, ";base64", "")
        id = "#{thread_segment(thread_id)}-#{T3.Environment.uuid4()}"
        File.mkdir_p!(dir())
        File.write!(Path.join(dir(), id <> extension("image", mime, attachment["name"])), bytes)

        stored =
          %{
            "type" => "image",
            "id" => id,
            "name" => attachment["name"],
            "mimeType" => mime,
            "sizeBytes" => byte_size(bytes)
          }
          |> then(
            &if(attachment["source"], do: Map.put(&1, "source", attachment["source"]), else: &1)
          )

        {:cont, {:ok, [stored | acc]}}
      else
        _ ->
          {:halt,
           {:error,
            %{
              "_tag" => "PersistChatAttachmentsError",
              "message" => "Image '#{attachment["name"]}' could not be saved."
            }}}
      end
    end)
    |> case do
      {:ok, stored} -> {:ok, %{"attachments" => Enum.reverse(stored)}}
      error -> error
    end
  end

  @doc "The file of an attachment on this node, or `nil`."
  def path(%{"id" => id}),
    do: if(safe_id?(id), do: List.first(Path.wildcard(Path.join(dir(), id <> ".*"))))

  @native_image_types ~w(image/gif image/jpeg image/png image/webp)

  @doc """
  A turn's text with where each attachment is saved, as the Node server words it,
  so agents can open files (and images they cannot take natively).
  """
  def prompt_text(text, attachments) do
    Enum.reduce(attachments, text || "", fn attachment, text ->
      note =
        ~s([Attached #{attachment.type} "#{attachment.name}" is saved at: #{attachment.path}])

      if text == "", do: note, else: text <> "\n\n" <> note
    end)
  end

  @doc "The images a model takes inline: `{mime_type, base64}` for each."
  def native_images(attachments) do
    for %{type: "image", mime_type: mime, path: path} <- attachments,
        String.downcase(mime || "") in @native_image_types,
        {:ok, bytes} <- [File.read(path)],
        do: {String.downcase(mime), Base.encode64(bytes)}
  end

  # Uploads no message took within a day go away, checked at most every 15 minutes.
  defp sweep_pending do
    now = System.os_time(:second)

    if now - :persistent_term.get({__MODULE__, :swept}, 0) > 900 do
      :persistent_term.put({__MODULE__, :swept}, now)

      for file <- Path.wildcard(Path.join(dir(), "pending-*")),
          {:ok, %File.Stat{mtime: mtime}} <- [File.stat(file, time: :posix)],
          now - mtime > @pending_max_age_s,
          do: File.rm(file)
    end

    :ok
  end

  # --- asset URLs ------------------------------------------------------------------

  @doc "`assets.createUrl`: a signed URL that serves an attachment or a file."
  def create_url(%{"resource" => resource}) do
    with {:ok, path, mime, name} <- resolve(resource) do
      expires = now_ms() + @asset_ttl_ms

      claims = %{
        "kind" => "asset",
        "path" => path,
        "mimeType" => mime,
        "fileName" => name,
        "disposition" =>
          resource["disposition"] ||
            if(resource["_tag"] == "attachment", do: "attachment", else: "inline"),
        "expiresAt" => expires
      }

      {:ok, %{"relativeUrl" => "/api/assets/" <> sign(claims), "expiresAt" => expires}}
    end
  end

  @doc "Reads a signed asset on this node: `{:ok, bytes, mime, file_name, disposition}`."
  def read(token) do
    with {:ok, %{"kind" => "asset", "path" => path} = claims} <- verify(token),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes, claims["mimeType"], claims["fileName"], claims["disposition"]}
    else
      {:ok, _} -> {:error, 403, "Not an asset URL."}
      {:error, message} when is_binary(message) -> {:error, 403, message}
      {:error, _reason} -> {:error, 404, "The file is gone."}
    end
  end

  defp resolve(%{"_tag" => "attachment", "attachmentId" => id} = resource) do
    case path(%{"id" => id}) do
      nil ->
        error("AssetAttachmentNotFoundError", resource, "Attachment was not found.")

      file ->
        {:ok, file, resource["mimeType"] || MIME.from_path(file),
         resource["fileName"] || Path.basename(file)}
    end
  end

  defp resolve(%{"_tag" => "workspace-file", "threadId" => thread_id, "path" => relative} = r),
    do: project_file(r, thread_root(thread_id), relative)

  defp resolve(%{"_tag" => "draft-workspace-file", "cwd" => cwd, "path" => relative} = r),
    do: project_file(r, cwd, relative)

  # A media file may be anywhere the node can read, but only a media type.
  defp resolve(%{"_tag" => "media-file", "threadId" => thread_id, "path" => path} = resource) do
    full =
      if Path.type(path) == :absolute,
        do: path,
        else: Path.join(thread_root(thread_id) || "/", path)

    cond do
      String.downcase(Path.extname(full)) not in @media_extensions ->
        error("AssetPreviewTypeValidationError", resource, "Only media files are served.")

      not File.regular?(full) ->
        error("AssetWorkspaceAssetNotFoundError", resource, "Media file was not found.")

      true ->
        {:ok, full, MIME.from_path(full), Path.basename(full)}
    end
  end

  defp resolve(%{"_tag" => tag} = resource),
    do:
      error(
        "AssetWorkspaceResolutionError",
        resource,
        "#{tag} files are not served by this node yet."
      )

  defp project_file(resource, nil, _relative),
    do: error("AssetWorkspaceContextNotFoundError", resource, "Workspace context was not found.")

  defp project_file(resource, root, relative) do
    case T3.Workspace.resolve(root, relative) do
      {:ok, full} ->
        if File.regular?(full),
          do: {:ok, full, MIME.from_path(full), Path.basename(full)},
          else:
            error("AssetWorkspaceAssetNotFoundError", resource, "Workspace file was not found.")

      {:error, %{"message" => message}} ->
        error("AssetWorkspaceResolutionError", resource, message)
    end
  end

  defp thread_root(thread_id) do
    case T3.Shell.row(node(), thread_id) do
      {"thread", row} -> row["worktreePath"] || project_root(row["projectId"])
      _ -> nil
    end
  end

  defp project_root(nil), do: nil

  defp project_root(project_id) do
    case T3.Shell.row(node(), project_id) do
      {"project", %{"workspaceRoot" => root}} -> root
      _ -> nil
    end
  end

  # The contract's asset errors carry the resource; `cause` where they take one.
  defp error(tag, resource, message) do
    detail = %{"_tag" => tag, "resource" => resource, "message" => message}

    {:error,
     if(tag == "AssetWorkspaceResolutionError",
       do: Map.put(detail, "cause", message),
       else: detail
     )}
  end

  # --- tokens ----------------------------------------------------------------------

  @doc "The node a signed token was issued by (unverified: only for routing)."
  def issuer(token) do
    with [payload, _signature] <- String.split(token, ".", parts: 2),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"node" => name}} <- JSON.decode(json),
         node when node != nil <- Enum.find([node() | Node.list()], &(Atom.to_string(&1) == name)) do
      {:ok, node}
    else
      _ -> :error
    end
  end

  defp sign(claims) do
    payload =
      claims
      |> Map.merge(%{"v" => 1, "node" => Atom.to_string(node())})
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    payload <> "." <> mac(payload)
  end

  defp verify(token) do
    with [payload, signature] <- String.split(token, ".", parts: 2),
         true <- Plug.Crypto.secure_compare(signature, mac(payload)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"expiresAt" => expires} = claims} <- JSON.decode(json),
         true <- expires > now_ms() do
      {:ok, claims}
    else
      _ -> {:error, "The link is invalid or expired."}
    end
  end

  defp mac(payload),
    do: :crypto.mac(:hmac, :sha256, secret(), payload) |> Base.url_encode64(padding: false)

  # One random key per node, kept owner-only in its home.
  defp secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil ->
        path = Path.join([home(), "secrets", "asset-signing-key"])

        key =
          case File.read(path) do
            {:ok, key} when byte_size(key) == 32 ->
              key

            _ ->
              key = :crypto.strong_rand_bytes(32)
              File.mkdir_p!(Path.dirname(path))
              File.write!(path, key)
              File.chmod!(path, 0o600)
              key
          end

        :persistent_term.put({__MODULE__, :secret}, key)
        key

      key ->
        key
    end
  end

  # --- ids and paths ---------------------------------------------------------------

  defp id_suffix("file", name) do
    case String.downcase(Path.extname(name)) do
      "." <> ext ->
        if Regex.match?(~r/^[a-z0-9]{1,10}$/, ext) and ext != "part", do: "-" <> ext, else: "-bin"

      _ ->
        "-bin"
    end
  end

  defp id_suffix(_image, _name), do: ""

  defp extension("file", _mime, name) do
    "-" <> ext = id_suffix("file", name)
    "." <> ext
  end

  defp extension(_image, mime, _name), do: Map.get(@image_types, String.downcase(mime), ".bin")

  defp safe_id?(id), do: is_binary(id) and Regex.match?(~r/^[a-z0-9_-]{1,200}$/i, id)

  defp thread_segment(thread_id) do
    segment =
      thread_id
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    if segment in ["", "pending"], do: "_pending", else: segment
  end

  defp dir, do: Path.join(home(), "attachments")
  defp home, do: Application.fetch_env!(:t3, :home)
  defp now_ms, do: System.system_time(:millisecond)
end
