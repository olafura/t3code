defmodule T3.Antigravity.Prompt do
  @moduledoc """
  A turn's `session/prompt` content for Antigravity: the message, then each upload
  as native ACP content instead of a path hint. Images (BMP, JPEG, PNG, WebP) and
  audio go inline as base64, a PDF as a `resource_link`, a text file as an embedded
  `resource`. A pasted clipboard file stays behind its path in the message, so the
  agent can search it rather than take it all in. Anything else, or more than the
  limits, fails the turn with a message saying what Antigravity accepts.
  """

  @image_types ~w(image/bmp image/jpeg image/png image/webp)
  @audio_types ~w(audio/aac audio/flac audio/mp3 audio/mpeg audio/mp4 audio/m4a audio/x-m4a
    audio/ogg audio/wav audio/x-wav audio/webm)
  @text_types ~w(application/json application/ld+json application/javascript
    application/typescript application/xml application/yaml application/x-yaml application/x-sh)
  @text_extensions ~w(.txt .md .mdx .json .jsonl .yaml .yml .toml .xml .csv .tsv .js .jsx .mjs
    .cjs .ts .tsx .html .css .scss .less .py .rs .go .java .kt .swift .c .h .cc .cpp .hpp .cs .rb
    .php .sh .bash .zsh .sql .graphql .svelte .vue .log .diff .patch .ini .conf)

  @max_image 10 * 1024 * 1024
  @max_audio 20 * 1024 * 1024
  @max_text 1024 * 1024
  @max_file 50 * 1024 * 1024
  @max_total 50 * 1024 * 1024

  @doc """
  The content blocks for the message `text` (which already says where each upload
  is saved) and `attachments` (the turn's `%{type, name, mime_type, path}` maps,
  `pasted: true` for a clipboard paste): `{:ok, blocks}` or `{:error, message}`.
  """
  def build(text, attachments) do
    text = String.trim(text || "")
    blocks = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

    attachments
    |> Enum.reduce_while({:ok, blocks, 0}, fn attachment, {:ok, blocks, total} ->
      case block(attachment, total) do
        {:ok, nil, total} -> {:cont, {:ok, blocks, total}}
        {:ok, block, total} -> {:cont, {:ok, [block | blocks], total}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [], _} -> {:error, "A turn requires text or supported attachments."}
      {:ok, blocks, _} -> {:ok, Enum.reverse(blocks)}
      error -> error
    end
  end

  defp block(attachment, total) do
    name = attachment.name || "attachment"

    mime =
      (attachment.mime_type || "")
      |> String.downcase()
      |> String.split(";")
      |> hd()
      |> String.trim()

    file? = attachment.type == "file"

    kind =
      cond do
        attachment.type == "image" and mime in @image_types ->
          :image

        file? and mime in @audio_types ->
          :audio

        file? and mime == "application/pdf" ->
          :pdf

        file? and
            (String.starts_with?(mime, "text/") or mime in @text_types or
               String.downcase(Path.extname(name)) in @text_extensions) ->
          :text

        true ->
          nil
      end

    with true <-
           kind != nil ||
             {:error,
              "Antigravity does not support '#{name}' (#{attachment.mime_type}). Attach a BMP, JPEG, PNG, WebP, PDF, audio, or text file."},
         {:ok, %File.Stat{type: :regular, size: size}} <- stat(attachment) do
      limit =
        case kind do
          :image -> @max_image
          :audio -> @max_audio
          :pdf -> @max_file
          :text -> @max_text
        end

      cond do
        Map.get(attachment, :pasted, false) ->
          {:ok, nil, total}

        size > limit or total + size > @max_total ->
          {:error,
           "Attachment '#{name}' is too large. Antigravity accepts text files up to 1 MiB, images up to 10 MiB, audio up to 20 MiB, and 50 MiB total attachments."}

        kind == :pdf ->
          {:ok,
           %{
             "type" => "resource_link",
             "uri" => file_url(attachment.path),
             "name" => name,
             "mimeType" => mime
           }, total + size}

        true ->
          read(attachment, kind, mime, limit, total)
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Could not read attachment '#{name}'."}
    end
  end

  defp stat(%{path: path}) when is_binary(path), do: File.stat(path)
  defp stat(_attachment), do: {:error, :invalid}

  defp read(attachment, kind, mime, limit, total) do
    name = attachment.name

    with {:ok, bytes} <- File.read(attachment.path),
         true <-
           (byte_size(bytes) <= limit and total + byte_size(bytes) <= @max_total) ||
             {:error, "Attachment '#{name}' changed while being read and is too large."} do
      total = total + byte_size(bytes)

      case kind do
        :image ->
          {:ok, %{"type" => "image", "data" => Base.encode64(bytes), "mimeType" => mime}, total}

        :audio ->
          {:ok, %{"type" => "audio", "data" => Base.encode64(bytes), "mimeType" => mime}, total}

        :text ->
          cond do
            not String.valid?(bytes) ->
              {:error, "Attachment '#{name}' is not a UTF-8 text file."}

            String.contains?(bytes, <<0>>) ->
              {:error, "Attachment '#{name}' contains binary data."}

            true ->
              {:ok,
               %{
                 "type" => "resource",
                 "resource" => %{
                   "uri" => file_url(attachment.path),
                   "mimeType" => mime,
                   "text" => bytes
                 }
               }, total}
          end
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Could not read attachment '#{name}'."}
    end
  end

  defp file_url(path), do: "file://" <> URI.encode(Path.expand(path))
end
