defmodule T3.AttachmentsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias T3.Attachments

  @moduletag :tmp_dir
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    :persistent_term.erase({Attachments, :secret})
    on_exit(fn -> :persistent_term.erase({Attachments, :secret}) end)
    :ok
  end

  defp upload(bytes \\ @png) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      Attachments.create_upload_url(%{
        "name" => "shot.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(bytes)
      })

    {id, token}
  end

  test "an upload is stored only with a valid token and the promised size" do
    {id, token} = upload()

    assert {:error, 400, _} = Attachments.store(token, "short")
    [payload, _signature] = String.split(token, ".")
    assert {:error, 403, _} = Attachments.store(payload <> ".forged", @png)
    assert :ok = Attachments.store(token, @png)
    assert File.read!(Attachments.path(%{"id" => id})) == @png
  end

  test "a message claims its uploads into the thread, and asset URLs serve them" do
    {id, token} = upload()
    :ok = Attachments.store(token, @png)

    attachment = %{
      "type" => "image",
      "id" => id,
      "name" => "shot.png",
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(@png)
    }

    assert {:ok, [%{"id" => claimed}]} = Attachments.claim("Thread 42", [attachment])
    assert "thread-42-" <> _ = claimed
    # Already claimed attachments pass through.
    assert {:ok, [%{"id" => ^claimed}]} =
             Attachments.claim("Thread 42", [%{attachment | "id" => claimed}])

    assert {:error, "Attachment 'shot.png' was not uploaded."} =
             Attachments.claim("t", [
               %{attachment | "id" => "pending-00000000-0000-0000-0000-000000000000"}
             ])

    {:ok, %{"relativeUrl" => "/api/assets/" <> asset}} =
      Attachments.create_url(%{
        "resource" => %{
          "_tag" => "attachment",
          "attachmentId" => claimed,
          "mimeType" => "image/png"
        }
      })

    assert {:ok, @png, "image/png", _name, "attachment"} = Attachments.read(asset)
  end

  test "the HTTP routes take an upload and serve an asset" do
    {id, token} = upload()
    conn = conn(:post, "/api/attachments/upload/" <> token, @png) |> T3.Web.Router.call([])
    assert conn.status == 204

    {:ok, %{"relativeUrl" => url}} =
      Attachments.create_url(%{
        "resource" => %{
          "_tag" => "attachment",
          "attachmentId" => id,
          "mimeType" => "image/png",
          "fileName" => "shot.png"
        }
      })

    conn = conn(:get, url) |> T3.Web.Router.call([])
    assert conn.status == 200
    assert conn.resp_body == @png
    assert ["image/png" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    assert (conn(:get, "/api/assets/bad.token") |> T3.Web.Router.call([])).status == 403
  end

  test "media URLs serve only media files" do
    dir = Application.fetch_env!(:t3, :home)
    File.write!(Path.join(dir, "clip.mp4"), "video")
    File.write!(Path.join(dir, "notes.txt"), "text")

    assert {:ok, _} =
             Attachments.create_url(%{
               "resource" => %{
                 "_tag" => "media-file",
                 "threadId" => "t",
                 "path" => Path.join(dir, "clip.mp4")
               }
             })

    assert {:error, %{"_tag" => "AssetPreviewTypeValidationError"}} =
             Attachments.create_url(%{
               "resource" => %{
                 "_tag" => "media-file",
                 "threadId" => "t",
                 "path" => Path.join(dir, "notes.txt")
               }
             })
  end

  test "pasted images are stored straight into the thread" do
    data = "data:image/png;base64," <> Base.encode64(@png)

    assert {:ok,
            %{
              "attachments" => [
                %{"id" => "t1-" <> _ = id, "sizeBytes" => 11, "mimeType" => "image/png"}
              ]
            }} =
             Attachments.persist(%{
               "threadId" => "t1",
               "messageId" => "m",
               "attachments" => [
                 %{
                   "type" => "image",
                   "name" => "p.png",
                   "mimeType" => "image/png",
                   "sizeBytes" => 11,
                   "dataUrl" => data
                 }
               ]
             })

    assert File.read!(Attachments.path(%{"id" => id})) == @png

    assert {:error, %{"_tag" => "PersistChatAttachmentsError"}} =
             Attachments.persist(%{
               "threadId" => "t1",
               "attachments" => [%{"name" => "x", "dataUrl" => "nope"}]
             })
  end
end
