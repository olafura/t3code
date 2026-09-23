defmodule T3.Acp.UrlAuthTest do
  use ExUnit.Case, async: false

  alias T3.Acp.UrlAuth

  setup do
    start_supervised!(T3.Settings)
    start_supervised!(UrlAuth)
    # Clients hear about a pending page as a provider change.
    :ok = T3.Settings.watch(self())
    :ok
  end

  defp ask(id, url \\ "http://localhost:4000/login") do
    Task.async(fn ->
      UrlAuth.request("opencode", %{"mode" => "url", "url" => url, "elicitationId" => id})
    end)
  end

  defp await_action(id) do
    assert_receive {:t3_providers_changed, _}, 1_000

    case UrlAuth.action("opencode") do
      %{"elicitationId" => ^id} = action -> action
      _ -> await_action(id)
    end
  end

  test "an agent's sign-in page waits on the provider until a user opens it" do
    task = ask("e1")
    assert %{"url" => "http://localhost:4000/login", "expiresAt" => _} = await_action("e1")

    assert {:ok, %{"accepted" => false}} =
             UrlAuth.accept(%{"instanceId" => "opencode", "elicitationId" => "other"})

    assert {:ok, %{"accepted" => true}} =
             UrlAuth.accept(%{"instanceId" => "opencode", "elicitationId" => "e1"})

    assert Task.await(task) == %{"action" => "accept"}
    assert UrlAuth.action("opencode") == nil
  end

  test "a newer request declines the older one, and odd URLs are declined outright" do
    first = ask("e1")
    await_action("e1")
    second = ask("e2")
    assert Task.await(first) == %{"action" => "decline"}
    await_action("e2")
    UrlAuth.accept(%{"instanceId" => "opencode", "elicitationId" => "e2"})
    assert Task.await(second) == %{"action" => "accept"}

    assert Task.await(ask("e3", "file:///etc/passwd")) == %{"action" => "decline"}
  end
end
