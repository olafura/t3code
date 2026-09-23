defmodule T3.PreviewAutomationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    start_supervised!(T3.PreviewAutomation)
    :ok
  end

  @caller %{thread_id: "th-1", instance: "codex"}
  @png Base.encode64(<<137, 80, 78, 71>>)

  # A desktop host: registers, then answers requests with `answer`.
  defp host(client_id, operations \\ nil) do
    host = %{"clientId" => client_id, "environmentId" => "env"}
    host = if operations, do: Map.put(host, "supportedOperations", operations), else: host
    {:ok, connection_id} = T3.PreviewAutomation.connect(host, self())
    assert_receive {:t3_preview_automation, _, ^client_id, %{"type" => "connected"}}
    connection_id
  end

  defp next_request(client_id) do
    assert_receive {:t3_preview_automation, _, ^client_id,
                    %{"type" => "request", "connectionId" => connection_id, "request" => request}}

    {connection_id, request}
  end

  defp answer(client_id, connection_id, request, result) do
    T3.PreviewAutomation.respond(%{
      "clientId" => client_id,
      "connectionId" => connection_id,
      "requestId" => request["requestId"],
      "ok" => true,
      "result" => result
    })
  end

  test "an agent's click reaches the host, and the tab it lands on stays its current tab" do
    host("desk")

    call =
      Task.async(fn -> T3.Mcp.Preview.call("preview_click", %{"locator" => "#go"}, @caller) end)

    {connection_id, request} = next_request("desk")

    assert %{"operation" => "click", "input" => %{"locator" => "#go"}, "threadId" => "th-1"} =
             request

    refute Map.has_key?(request, "tabId")
    answer("desk", connection_id, request, %{"tabId" => "tab-1", "clicked" => true})

    # The follow-up status read names the page for the tool's icon.
    {_, status} = next_request("desk")
    assert %{"operation" => "status", "tabId" => "tab-1", "tabIdExplicit" => true} = status
    answer("desk", connection_id, status, %{"url" => "http://localhost:5173/"})

    assert {:ok, %{"clicked" => true, "toolIcon" => %{"pageUrl" => "http://localhost:5173/"}}} =
             Task.await(call)

    # The next call without a tab goes to that tab.
    call = Task.async(fn -> T3.Mcp.Preview.call("preview_status", %{}, @caller) end)
    {_, request} = next_request("desk")
    assert %{"tabId" => "tab-1", "tabIdExplicit" => false} = request
    answer("desk", connection_id, request, %{"url" => "about:blank"})
    assert {:ok, %{"url" => "about:blank"}} = Task.await(call)
  end

  test "without a host, or with one that cannot do it, the agent is told" do
    assert {:error, "PreviewAutomationNoAvailableHostError", message} =
             T3.Mcp.Preview.call("preview_status", %{}, @caller)

    assert message =~ "desktop app"

    host("old", ~w(status))

    assert {:error, "PreviewAutomationNoAvailableHostError", _} =
             T3.Mcp.Preview.call("preview_resize", %{"mode" => "fill"}, @caller)
  end

  test "an unanswered request fails and drops the host, whose stream ends" do
    host("desk")

    assert {:error, "PreviewAutomationTimeoutError", _} =
             T3.Mcp.Preview.call("preview_wait_for", %{"text" => "x", "timeoutMs" => 50}, @caller)

    assert_receive {:t3_preview_automation, _, "desk", :end}

    assert {:error, "PreviewAutomationNoAvailableHostError", _} =
             T3.Mcp.Preview.call("preview_status", %{}, @caller)
  end

  test "a snapshot is bounded JSON plus the screenshot, and can be saved" do
    host("desk")

    call =
      Task.async(fn ->
        T3.Mcp.Preview.call(
          "preview_snapshot",
          %{"save" => true, "includeImage" => true},
          @caller
        )
      end)

    {connection_id, request} = next_request("desk")
    assert request["input"] == %{}

    answer("desk", connection_id, request, %{
      "url" => "https://example.com/a",
      "title" => "Example",
      "visibleText" => String.duplicate("x", 9_000),
      "interactiveElements" => [%{"name" => "Go", "locator" => "#go"}],
      "consoleEntries" => for(i <- 1..50, do: %{"level" => "log", "text" => "line #{i}"}),
      "networkEntries" => [],
      "actionTimeline" => [],
      "accessibilityTree" => %{"role" => "document"},
      "screenshot" => %{"mimeType" => "image/png", "data" => @png, "width" => 10, "height" => 10}
    })

    assert {:ok, metadata, [_url, %{"text" => text}, %{"text" => note}, image]} = Task.await(call)
    assert File.read!(metadata["screenshotPath"]) == Base.decode64!(@png)
    assert metadata["screenshotPath"] =~ "browser-screenshot-example-com-"
    refute Map.has_key?(metadata["screenshot"], "data")
    assert image == %{"type" => "image", "data" => @png, "mimeType" => "image/png"}

    sent = JSON.decode!(text)
    refute Map.has_key?(sent, "accessibilityTree")
    assert length(sent["consoleEntries"]) == 40
    assert String.length(sent["visibleText"]) == 8_001
    assert note =~ "10 older console entries"
  end
end
