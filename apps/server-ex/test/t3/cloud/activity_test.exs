defmodule T3.Cloud.ActivityTest do
  use ExUnit.Case, async: false

  alias T3.Cloud.Activity

  @moduletag :tmp_dir
  @at "2026-09-24T10:00:00.000Z"

  defmodule Relay do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)

      send(
        pid,
        {:relay, conn.request_path, get_req_header(conn, "authorization"), JSON.decode!(body)}
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"ok":true,"deliveries":[]}))
    end
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    relay = start_supervised!({Bandit, plug: {Relay, self()}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(relay)
    {:ok, _} = Application.ensure_all_started(:inets)

    for {name, value} <- [
          {"cloud-relay-url", "http://127.0.0.1:#{port}"},
          {"cloud-relay-issuer", "https://relay.test"},
          {"cloud-relay-environment-credential", "env-cred"},
          {"cloud-publish-agent-activity", "true"}
        ],
        do: T3.Secrets.put(name, value)

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Demo",
        "workspaceRoot" => dir
      })

    :ok
  end

  test "an agent's turn is published as it runs and when it finishes" do
    start_supervised!(Activity)
    env = T3.Environment.id()

    run("t1", "running")

    assert_receive {:relay, path, ["Bearer env-cred"], %{"state" => state, "proof" => proof}},
                   2_000

    assert path == "/v1/environments/#{env}/threads/t1/agent-activity"

    assert %{
             "phase" => "running",
             "headline" => "Agent is working",
             "projectTitle" => "Demo",
             "threadTitle" => "Fix it",
             "modelTitle" => "gpt-5",
             "deepLink" => "/threads/" <> _
           } = state

    assert {:ok, %{"threadId" => "t1", "state" => %{"phase" => "running"}}} =
             T3.Cloud.Jwt.verify(
               T3.Cloud.key_pair()["publicKey"],
               proof,
               "t3-env-activity+jwt",
               "t3-env:#{env}",
               "https://relay.test",
               System.os_time(:second)
             )

    # The same state is not sent again.
    commit("t1", [{"thread", "t1", %{"s" => %{"branch" => "main"}}}])
    refute_receive {:relay, _, _, _}, 300

    run("t1", "completed")

    assert_receive {:relay, _, _,
                    %{
                      "state" => %{
                        "phase" => "completed",
                        "detail" => "Review the completed task."
                      }
                    }},
                   2_000

    # Turned off, nothing leaves.
    T3.Secrets.put("cloud-publish-agent-activity", "false")
    run("t1", "running", "r2")
    refute_receive {:relay, _, _, _}, 300
  end

  test "threads are projected as the Node server projects them" do
    thread = %{
      "id" => "t1",
      "title" => "Fix it",
      "status" => "idle",
      "modelSelection" => %{"model" => "m"},
      "updatedAt" => @at,
      "lineage" => %{}
    }

    assert Activity.state("e", "P", thread) == nil

    assert %{"phase" => "waiting_for_input", "headline" => "Waiting for input"} =
             Activity.state(
               "e",
               "P",
               Map.put(thread, "pendingRuntimeRequest", %{"kind" => "user_input"})
             )

    assert %{"phase" => "waiting_for_approval"} =
             Activity.state(
               "e",
               "P",
               Map.put(thread, "pendingRuntimeRequest", %{"kind" => "command"})
             )

    assert Activity.state(
             "e",
             "P",
             Map.put(thread, "pendingRuntimeRequest", %{"kind" => "auth_refresh"})
           ) ==
             nil

    assert %{"phase" => "failed", "detail" => "The agent run failed."} =
             Activity.state("e", "P", %{thread | "status" => "failed"})

    assert %{"phase" => "starting"} =
             Activity.state("e", "P", Map.put(thread, "activityRunStatus", "preparing"))

    assert Activity.state("e", "P", %{
             thread
             | "status" => "running",
               "lineage" => %{"relationshipToParent" => "subagent"}
           }) == nil

    assert Activity.state(
             "e",
             "P",
             Map.merge(thread, %{"status" => "running", "archivedAt" => @at})
           ) ==
             nil
  end

  defp run(thread_id, status, run_id \\ "r1") do
    commit(thread_id, [
      {"thread", thread_id,
       %{
         "s" => %{
           "id" => thread_id,
           "projectId" => "p1",
           "title" => "Fix it",
           "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5"},
           "createdAt" => @at,
           "updatedAt" => @at
         }
       }},
      {"run", run_id,
       %{"s" => %{"id" => run_id, "ordinal" => 1, "status" => status, "requestedAt" => @at}}}
    ])
  end

  defp commit(thread_id, changes), do: {:ok, _} = T3.Streams.commit(thread_id, :thread, changes)
end
