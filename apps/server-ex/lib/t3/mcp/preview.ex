defmodule T3.Mcp.Preview do
  @moduledoc """
  The `preview_*` MCP tools: an agent drives the browser panel of a desktop client
  through `T3.PreviewAutomation`, as it does on the Node server.

  Snapshots come back as bounded JSON text plus the screenshot as image content
  (`{:ok, structured, content}`), and a stopped recording is claimed into the
  thread as an attachment the agent can open.
  """

  @tools ~w(preview_status preview_open preview_navigate preview_resize preview_set_appearance
            preview_snapshot preview_click preview_type preview_press preview_scroll
            preview_evaluate preview_wait_for preview_recording_start preview_recording_stop)

  @operations %{
    "preview_status" => "status",
    "preview_open" => "open",
    "preview_navigate" => "navigate",
    "preview_resize" => "resize",
    "preview_set_appearance" => "setColorScheme",
    "preview_click" => "click",
    "preview_type" => "type",
    "preview_press" => "press",
    "preview_scroll" => "scroll",
    "preview_wait_for" => "waitFor",
    "preview_recording_start" => "recordingStart"
  }
  # Only these take the tool's own timeoutMs; others use the broker's default.
  @timed ~w(preview_navigate preview_resize preview_click preview_type preview_wait_for)
  @recording_stop_timeout 120_000

  def names, do: @tools

  def call("preview_snapshot", args, caller) do
    {_, input} = Map.split(args, ~w(includeImage save tabId))

    with {:ok, snapshot} <- invoke(caller, "snapshot", input, tab: args["tabId"]) do
      snapshot_content(snapshot, args)
    end
  end

  def call("preview_evaluate", args, caller) do
    {tab, input} = Map.pop(args, "tabId")

    with {:ok, value, icon} <- invoke_with_icon(caller, "evaluate", input, tab: tab),
         do: {:ok, with_icon(%{"value" => value}, icon)}
  end

  def call("preview_recording_stop", args, caller) do
    {tab, input} = Map.pop(args, "tabId")
    input = Map.put(input, "transferToEnvironment", true)

    with {:ok, artifact, icon} <-
           invoke_with_icon(caller, "recordingStop", input,
             tab: tab,
             timeout: @recording_stop_timeout
           ),
         {:ok, recording} <- claim_recording(caller.thread_id, artifact) do
      {:ok, with_icon(recording, icon)}
    end
  end

  def call(name, args, caller) do
    args = if name == "preview_open", do: open_input(args), else: args
    {tab, input} = Map.pop(args, "tabId")
    timeout = if name in @timed, do: args["timeoutMs"]

    with {:ok, result, icon} <-
           invoke_with_icon(caller, @operations[name], input, tab: tab, timeout: timeout) do
      {:ok, with_icon(if(is_map(result), do: result, else: %{}), icon)}
    end
  end

  # `show` is `open`; a preview the agent said nothing about follows the user's
  # desktop preference, so an unstated `open` stays unstated.
  defp open_input(args) do
    open = Map.get(args, "open", args["show"])
    args = if open == nil, do: args, else: Map.merge(args, %{"open" => open, "show" => open})
    Map.put_new(args, "reuseExistingTab", true)
  end

  # --- broker ----------------------------------------------------------------------

  defp invoke(caller, operation, input, opts) do
    scope = %{thread_id: caller.thread_id, instance: caller.instance}

    opts =
      [tab_id: opts[:tab], timeout_ms: opts[:timeout], update_current_tab: opts[:update_tab]]
      |> Enum.reject(fn {_key, value} -> value == nil end)

    case T3.PreviewAutomation.invoke(scope, operation, input, opts) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error["_tag"], T3.PreviewAutomation.message(error)}
    end
  end

  # Actions also report the page they left the tab on, for the tool's icon.
  defp invoke_with_icon(caller, operation, input, opts) do
    with {:ok, result} <- invoke(caller, operation, input, opts) do
      if operation in ~w(status open navigate) do
        {:ok, result, nil}
      else
        tab = (operation != "evaluate" && is_map(result) && result["tabId"]) || opts[:tab]

        page =
          case invoke(caller, "status", %{}, tab: tab, timeout: 500, update_tab: false) do
            {:ok, %{"url" => "http" <> _ = url}} when byte_size(url) <= 4096 -> url
            _ -> nil
          end

        {:ok, result, page && %{"_tag" => "website", "pageUrl" => page}}
      end
    end
  end

  defp with_icon(result, nil), do: result
  defp with_icon(result, icon), do: Map.put(result, "toolIcon", icon)

  # --- recordings ------------------------------------------------------------------

  defp claim_recording(thread_id, %{"uploadedAttachmentId" => "pending-" <> _ = id} = artifact) do
    upload = %{
      "id" => id,
      "name" => artifact["fileName"] || "recording",
      "sizeBytes" => artifact["sizeBytes"]
    }

    case T3.Attachments.claim(thread_id, [upload]) do
      {:ok, [%{"id" => claimed} = attachment]} ->
        recording =
          artifact
          |> Map.delete("uploadedAttachmentId")
          |> Map.merge(%{"id" => claimed, "path" => T3.Attachments.path(attachment)})

        {:ok, recording}

      _ ->
        {:error, "PreviewAutomationRecordingTransferError",
         "The preview recording could not be transferred to this environment."}
    end
  end

  defp claim_recording(_thread_id, %{} = _artifact),
    do:
      {:error, "PreviewAutomationRecordingDesktopUpdateRequiredError",
       "Update T3 Code's desktop app to transfer preview recordings."}

  defp claim_recording(_thread_id, _other),
    do:
      {:error, "PreviewAutomationRecordingTransferError",
       "The preview recording could not be transferred to this environment."}

  # --- snapshots ---------------------------------------------------------------------

  # Claude Code drops any MCP result past ~25k tokens, locators and all, so the
  # snapshot text stays under this and says what was cut.
  @max_text_bytes 60_000
  @max_visible_text 8_000
  @max_element_name 200
  @max_log_entries 40
  @max_log_text 500
  @max_identifier 2_048
  @shed_order ~w(actionTimeline networkEntries consoleEntries interactiveElements)

  defp snapshot_content(%{"screenshot" => shot} = snapshot, args) do
    page = Map.delete(snapshot, "screenshot")
    png = Base.decode64!(shot["data"])

    with {:ok, saved} <- maybe_save(args["save"] == true, snapshot["url"] || "", png) do
      metadata =
        page
        |> Map.put("screenshot", Map.take(shot, ~w(mimeType width height)))
        |> then(&if(saved, do: Map.put(&1, "screenshotPath", saved), else: &1))

      {text, omitted} = bound(metadata)

      content =
        [
          text_block(JSON.encode!(%{"url" => cut(snapshot["url"] || "", @max_identifier)})),
          text_block(text)
        ] ++
          if(omitted == [],
            do: [],
            else: [text_block("Snapshot text was bounded. Omitted: #{Enum.join(omitted, "; ")}.")]
          ) ++
          if(args["includeImage"] == false,
            do: [],
            else: [%{"type" => "image", "data" => shot["data"], "mimeType" => shot["mimeType"]}]
          )

      {:ok, metadata, content}
    end
  end

  defp snapshot_content(_snapshot, _args),
    do: {:error, "PreviewSnapshotError", "Preview snapshot failed: the page sent no screenshot."}

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp maybe_save(false, _url, _png), do: {:ok, nil}

  defp maybe_save(true, url, png) do
    dir = Path.join(Application.fetch_env!(:t3, :home), "browser-artifacts")
    stamp = System.system_time(:millisecond) |> Integer.to_string(36) |> String.downcase()
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    path = Path.join(dir, "browser-screenshot-#{site_slug(url)}-#{stamp}-#{suffix}.png")

    with :ok <- File.mkdir_p(dir), :ok <- File.write(path, png) do
      {:ok, path}
    else
      _ -> {:error, "PreviewScreenshotSaveError", "Could not save preview screenshot to #{path}."}
    end
  end

  defp site_slug(url) do
    slug =
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) ->
          host
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")
          |> String.slice(0, 40)
          |> String.trim_trailing("-")

        _ ->
          ""
      end

    if slug == "", do: "site", else: slug
  end

  # Drops the accessibility tree; cuts page text, names, identifiers and log text;
  # keeps the newest log entries; then halves lists, elements last, until it fits.
  defp bound(metadata) do
    elements = metadata["interactiveElements"] || []
    url = metadata["url"] || ""
    title = metadata["title"] || ""
    visible = metadata["visibleText"] || ""

    omitted =
      [
        Map.has_key?(metadata, "accessibilityTree") &&
          "accessibilityTree (use interactiveElements locators or preview_evaluate)",
        (String.length(url) > @max_identifier or String.length(title) > @max_identifier) &&
          "url or title after #{@max_identifier} characters",
        Enum.any?(elements, &(String.length(&1["name"] || "") > @max_element_name)) &&
          "element names longer than #{@max_element_name} characters",
        String.length(visible) > @max_visible_text &&
          "visibleText after #{@max_visible_text} characters (use preview_evaluate for more)"
      ]
      |> Enum.filter(& &1)

    {logs, omitted} =
      Enum.reduce(
        [
          {"consoleEntries", "console entries"},
          {"networkEntries", "network entries"},
          {"actionTimeline", "action timeline entries"}
        ],
        {%{}, omitted},
        fn {key, label}, {logs, omitted} ->
          entries = metadata[key] || []
          count = length(entries)
          kept = Enum.take(entries, -@max_log_entries)

          omitted =
            omitted ++
              if(count > @max_log_entries,
                do: ["#{count - @max_log_entries} older #{label}"],
                else: []
              ) ++
              if(Enum.any?(kept, &long_string?/1),
                do: ["#{label} text after #{@max_log_text} characters"],
                else: []
              )

          {Map.put(logs, key, Enum.map(kept, &cut_entry/1)), omitted}
        end
      )

    lists =
      Map.put(
        logs,
        "interactiveElements",
        Enum.map(elements, &Map.put(&1, "name", cut(&1["name"] || "", @max_element_name)))
      )

    base =
      metadata
      |> Map.delete("accessibilityTree")
      |> Map.merge(%{
        "url" => cut(url, @max_identifier),
        "title" => cut(title, @max_identifier),
        "visibleText" => cut(visible, @max_visible_text)
      })

    {text, final} = shed(base, lists)

    dropped =
      for key <- @shed_order, (n = length(lists[key]) - length(final[key])) > 0 do
        "#{n} of #{length(lists[key])} #{key}"
      end

    {text, omitted ++ dropped}
  end

  defp shed(base, lists) do
    text = JSON.encode!(Map.merge(base, lists))

    key =
      Enum.find(@shed_order -- ["interactiveElements"], &(lists[&1] != [])) ||
        if lists["interactiveElements"] != [], do: "interactiveElements"

    if byte_size(text) <= @max_text_bytes or key == nil do
      {text, lists}
    else
      list = lists[key]
      keep = div(length(list), 2)

      kept =
        cond do
          keep == 0 -> []
          key == "interactiveElements" -> Enum.take(list, keep)
          true -> Enum.take(list, -keep)
        end

      shed(base, Map.put(lists, key, kept))
    end
  end

  defp long_string?(%{} = entry),
    do: Enum.any?(entry, fn {_k, v} -> is_binary(v) and String.length(v) > @max_log_text end)

  defp long_string?(_entry), do: false

  defp cut_entry(%{} = entry),
    do: Map.new(entry, fn {k, v} -> {k, if(is_binary(v), do: cut(v, @max_log_text), else: v)} end)

  defp cut_entry(entry), do: entry

  defp cut(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
