defmodule T3.PreviewTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(T3.Preview)
    :ok = T3.Preview.subscribe(self())
    :ok
  end

  test "a tab opens, navigates, fails, and closes, with an event for each" do
    {:ok, %{"tabId" => tab, "navStatus" => %{"_tag" => "Loading"}}} =
      T3.Preview.open(%{"threadId" => "t1", "url" => "http://localhost:5173/"})

    assert_receive {:t3_preview, _, %{"type" => "opened", "revision" => 1}}

    {:ok, snapshot} =
      T3.Preview.navigate(%{
        "threadId" => "t1",
        "tabId" => tab,
        "url" => "http://localhost:5173/a"
      })

    assert %{"navStatus" => %{"_tag" => "Success", "url" => "http://localhost:5173/a"}} = snapshot
    assert_receive {:t3_preview, _, %{"type" => "navigated", "revision" => 2}}

    failed = %{
      "_tag" => "LoadFailed",
      "url" => "http://localhost:5173/b",
      "title" => "",
      "code" => -102,
      "description" => "refused"
    }

    {:ok, nil} =
      T3.Preview.report_status(%{
        "threadId" => "t1",
        "tabId" => tab,
        "navStatus" => failed,
        "canGoBack" => true,
        "canGoForward" => false
      })

    assert_receive {:t3_preview, _, %{"type" => "failed", "code" => -102}}

    assert {:ok, %{"sessions" => [%{"canGoBack" => true}], "revision" => 3}} =
             T3.Preview.list(%{"threadId" => "t1"})

    {:ok, nil} = T3.Preview.close(%{"threadId" => "t1"})
    assert_receive {:t3_preview, _, %{"type" => "closed", "tabId" => ^tab}}
    assert {:ok, %{"sessions" => []}} = T3.Preview.list(%{"threadId" => "t1"})
  end

  test "an unknown tab is a lookup error" do
    assert {:error, %{"_tag" => "PreviewSessionLookupError"}} =
             T3.Preview.refresh(%{"threadId" => "t1", "tabId" => "nope"})
  end
end
