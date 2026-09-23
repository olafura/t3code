defmodule T3.ProviderAuthTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    auth_file = Path.join(dir, "signed-in")
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})
    on_exit(fn -> Application.delete_env(:t3, :acp_commands) end)
    start_supervised!(T3.Settings)

    # The agent reads where to keep its sign-in from the instance's environment.
    {:ok, _} =
      T3.Settings.put(
        %{
          "providerInstances" => %{
            "opencode" => %{
              "driver" => "opencode",
              "enabled" => true,
              "environment" => [%{"name" => "FAKE_AUTH_FILE", "value" => auth_file}]
            }
          }
        },
        0
      )

    start_supervised!({Registry, keys: :unique, name: T3.ProviderAuth.Registry})

    start_supervised!(
      {DynamicSupervisor, name: T3.ProviderAuth.Supervisor, strategy: :one_for_one}
    )

    {:ok, _} = T3.ProviderAuth.subscribe("opencode", self())
    assert_receive {:t3_provider_auth, "opencode", %{"methods" => methods}}, 5_000

    assert [%{"id" => "browser", "type" => "agent"}, %{"id" => "cli", "type" => "terminal"}] =
             methods

    T3.Acp.forget("opencode")
    on_exit(fn -> T3.Acp.forget("opencode") end)
    %{auth_file: auth_file}
  end

  # The provider list says whether the agent is signed in, probing it when needed.
  defp auth_status do
    :ok = T3.Settings.watch(self())
    flush_provider_changes()
    T3.Acp.entry("opencode")
    assert_receive {:t3_providers_changed, _}, 5_000
    entry = T3.Acp.entry("opencode")
    assert entry["setup"]["canAuthenticate"]
    entry["auth"]["status"]
  end

  test "an agent method signs in after the user opens its URL", %{auth_file: auth_file} do
    assert auth_status() == "unauthenticated"

    {:ok, %{"phase" => "starting", "flowId" => flow}} =
      T3.ProviderAuth.start(%{"instanceId" => "opencode", "methodId" => "browser"})

    interaction = await_phase("waiting")["interaction"]

    assert %{"type" => "browser", "id" => "e1", "url" => "https://example.com/login"} =
             interaction

    {:ok, _} =
      T3.ProviderAuth.respond(%{
        "instanceId" => "opencode",
        "flowId" => flow,
        "interactionId" => "e1",
        "response" => %{"type" => "browser", "action" => "accept"}
      })

    await_phase("succeeded")
    assert File.exists?(auth_file)
    assert auth_status() == "authenticated"
  end

  test "a terminal method runs the login command the user types into", %{auth_file: auth_file} do
    {:ok, %{"flowId" => flow}} =
      T3.ProviderAuth.start(%{"instanceId" => "opencode", "methodId" => "cli"})

    await_output("Paste code")

    {:ok, _} =
      T3.ProviderAuth.respond(%{
        "instanceId" => "opencode",
        "flowId" => flow,
        "interactionId" => "terminal",
        "response" => %{"type" => "terminal", "data" => "ok\n"}
      })

    await_phase("succeeded")
    assert File.exists?(auth_file)
  end

  test "a declined URL fails the sign-in; a cancelled one stops it" do
    {:ok, %{"flowId" => flow}} =
      T3.ProviderAuth.start(%{"instanceId" => "opencode", "methodId" => "browser"})

    await_phase("waiting")

    {:ok, _} =
      T3.ProviderAuth.respond(%{
        "instanceId" => "opencode",
        "flowId" => flow,
        "interactionId" => "e1",
        "response" => %{"type" => "browser", "action" => "decline"}
      })

    assert await_phase("failed")["message"] =~ "declined"

    {:ok, %{"flowId" => flow}} =
      T3.ProviderAuth.start(%{"instanceId" => "opencode", "methodId" => "cli"})

    await_output("Paste code")

    assert {:ok, %{"phase" => "cancelled"}} =
             T3.ProviderAuth.cancel(%{"instanceId" => "opencode", "flowId" => flow})
  end

  defp flush_provider_changes do
    receive do
      {:t3_providers_changed, _} -> flush_provider_changes()
    after
      0 -> :ok
    end
  end

  defp await_phase(phase) do
    receive do
      {:t3_provider_auth, _, %{"phase" => ^phase} = state} ->
        state

      {:t3_provider_auth, _, %{"phase" => "failed"} = state} ->
        flunk("failed: #{state["message"]}")

      {:t3_provider_auth, _, _} ->
        await_phase(phase)
    after
      10_000 -> flunk("no #{phase} state")
    end
  end

  defp await_output(text) do
    receive do
      {:t3_provider_auth, _, %{"interaction" => %{"type" => "terminal", "output" => output}}} ->
        if output =~ text, do: :ok, else: await_output(text)

      {:t3_provider_auth, _, _} ->
        await_output(text)
    after
      10_000 -> flunk("no terminal output #{inspect(text)}")
    end
  end
end
