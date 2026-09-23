defmodule T3.PullRequestsTest do
  use ExUnit.Case, async: false

  alias T3.PullRequests
  alias T3.PullRequests.GitHub

  @moduletag :tmp_dir
  @fake_gh Path.expand("../support/fake_gh.py", __DIR__)
  @ref %{"projectId" => "p1", "repository" => "acme/widgets", "number" => 5}

  setup %{tmp_dir: dir} do
    Application.put_env(:t3, :home, dir)
    previous = Application.get_env(:t3, :gh_command)
    Application.put_env(:t3, :gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "gh.log"))

    on_exit(fn ->
      Application.put_env(:t3, :gh_command, previous)
      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)

    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    start_supervised!(T3.PullRequests.Refreshes)
    # Forgets who is signed in, which other tests may have cached.
    {:ok, nil} = PullRequests.invalidate(%{})

    :ok = T3.Shell.subscribe(self())
    project!(dir, "p1", "https://github.com/acme/widgets.git")
    File.write!(Path.join(dir, "gh.log"), "")
    %{dir: dir}
  end

  test "checks are one per check, the newest run of each, qualified when names clash" do
    raw = [
      %{
        "__typename" => "CheckRun",
        "name" => "test",
        "workflowName" => "CI",
        "status" => "COMPLETED",
        "conclusion" => "FAILURE",
        "completedAt" => "2026-01-01T00:00:00Z"
      },
      %{
        "__typename" => "CheckRun",
        "name" => "test",
        "workflowName" => "CI",
        "status" => "COMPLETED",
        "conclusion" => "SUCCESS",
        "completedAt" => "2026-01-02T00:00:00Z",
        "detailsUrl" => "https://ci/2"
      },
      %{
        "__typename" => "CheckRun",
        "name" => "test",
        "workflowName" => "Nightly",
        "status" => "IN_PROGRESS",
        "conclusion" => ""
      },
      %{
        "__typename" => "StatusContext",
        "context" => "deploy",
        "state" => "ERROR",
        "targetUrl" => "https://deploy"
      },
      %{"__typename" => "CheckRun", "name" => "", "context" => nil}
    ]

    assert GitHub.checks(raw) == [
             %{
               "name" => "CI / test",
               "status" => "success",
               "description" => nil,
               "url" => "https://ci/2"
             },
             %{
               "name" => "Nightly / test",
               "status" => "pending",
               "description" => nil,
               "url" => nil
             },
             %{
               "name" => "deploy",
               "status" => "failure",
               "description" => nil,
               "url" => "https://deploy"
             }
           ]

    assert %{kind: "github", host: "github.example.com", repository: "acme/widgets"} =
             PullRequests.parse_remote("git@github.example.com:acme/widgets.git")

    assert %{kind: "gitlab", repository: "group/sub/app"} =
             PullRequests.parse_remote("https://gitlab.com/group/sub/app")
  end

  test "a listing reads each repository, newest first, and carries on from a cursor", %{dir: dir} do
    rules!(dir, [
      viewer_rule(),
      %{
        "args" => ["pr list", "--repo github.com/acme/widgets"],
        "stdout" => [
          pr(5, "2026-03-02T00:00:00Z", %{
            "reviewRequests" => [%{"login" => "octo"}],
            "latestReviews" => [%{"state" => "APPROVED", "author" => %{"login" => "bot"}}],
            "statusCheckRollup" => [
              %{"name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
            ],
            "labels" => [%{"name" => "bug", "color" => "ff0000"}]
          }),
          pr(4, "2026-03-01T00:00:00Z", %{"isDraft" => true}),
          %{"number" => "malformed"}
        ]
      }
    ])

    assert {:ok, result} = PullRequests.list(%{"state" => "open", "limit" => 1})
    assert result["viewers"] == %{"github.com" => "octo"}

    assert [
             %{
               "host" => "github.com",
               "kind" => "github",
               "configured" => true,
               "projectCount" => 1
             }
           ] =
             result["providers"]

    assert [entry] = result["entries"]

    assert %{
             "number" => 5,
             "projectId" => "p1",
             "repository" => "acme/widgets",
             "viewerReviewRequested" => true,
             "reviewDecision" => "approved",
             "checksState" => "passing",
             "labels" => [%{"name" => "bug", "color" => "ff0000"}],
             "author" => %{
               "login" => "someone",
               "avatarUrl" => "https://github.com/someone.png?size=80"
             }
           } = entry

    assert result["truncated"]
    assert %{"github.com acme/widgets" => cursor} = result["nextCursors"]
    assert cursor == "2026-03-02T00:00:00Z|1|5"

    [list | _] = calls(dir, "pr list")
    assert "--search" in list["args"]
    assert Enum.any?(list["args"], &String.ends_with?(&1, "sort:updated-desc"))

    assert {:ok, next} =
             PullRequests.list(%{
               "state" => "open",
               "limit" => 2,
               "cursors" => result["nextCursors"]
             })

    # The row already sent at the boundary is not sent again.
    assert Enum.map(next["entries"], & &1["number"]) == [4]

    assert Enum.any?(calls(dir, "pr list"), fn call ->
             Enum.any?(call["args"], &String.contains?(&1, "updated:<=2026-03-02T00:00:00Z"))
           end)

    assert {:error, %{"_tag" => "PullRequestOperationError", "operation" => "list"}} =
             PullRequests.list(%{"state" => "open", "cursors" => %{"x" => "nonsense"}})
  end

  test "a signed-out gh is reported as the fix", %{dir: dir} do
    rules!(dir, [
      %{
        "args" => ["api user"],
        "exit" => 1,
        "stderr" => "To get started with GitHub CLI, please run:  gh auth login\n"
      }
    ])

    assert {:error,
            %{
              "_tag" => "PullRequestUnavailableError",
              "reason" => "cli-unauthenticated",
              "provider" => "github"
            }} =
             PullRequests.list(%{"state" => "open"})
  end

  test "a project on another host is unsupported", %{dir: dir} do
    project!(dir, "p2", "https://gitlab.com/acme/app.git")

    assert {:error,
            %{
              "_tag" => "PullRequestUnavailableError",
              "reason" => "provider-unsupported",
              "provider" => "gitlab"
            }} =
             PullRequests.detail(%{
               "projectId" => "p2",
               "repository" => "acme/app",
               "number" => 1
             })

    assert {:error, %{"_tag" => "PullRequestOperationError", "operation" => "resolveRepository"}} =
             PullRequests.detail(%{@ref | "repository" => "someone/else"})
  end

  test "detail and checks read the pull request, its permissions and base comparison", %{dir: dir} do
    rules!(dir, [viewer_rule(), core_rule("WRITE")])

    assert {:ok, detail} = PullRequests.detail(@ref)

    assert %{
             "provider" => "github",
             "projectTitle" => "p1",
             "number" => 5,
             "title" => "Widgets",
             "body" => "Adds widgets.",
             "state" => "open",
             "mergeability" => "mergeable",
             "baseComparison" => "behind",
             "behindBy" => 2,
             "autoMergeEnabled" => false,
             "viewer" => "octo",
             "mergeCapabilities" => %{"merge" => true, "squash" => true, "rebase" => false},
             "reviewers" => [%{"login" => "reviewer", "name" => nil, "avatarUrl" => nil}],
             "checks" => [%{"name" => "build", "status" => "success"}],
             "workflowApprovalsRequired" => 0,
             "viewerPermissions" => %{
               "comment" => true,
               "resolve" => true,
               "requestReviewers" => true
             }
           } = detail

    assert "update-branch" in detail["viewerPermissions"]["actions"]
    assert "merge" in detail["viewerPermissions"]["actions"]
    assert detail["capabilities"]["viewedFiles"] == "host"

    assert {:ok, %{"state" => "open", "checks" => [%{"name" => "build"}]}} =
             PullRequests.checks(@ref)

    [query] =
      calls(dir, "graphql")
      |> Enum.filter(&String.contains?(&1["stdin"], "viewerCanUpdateBranch"))
      |> Enum.take(1)

    assert JSON.decode!(query["stdin"])["variables"] == %{
             "owner" => "acme",
             "name" => "widgets",
             "number" => 5,
             "headRef" => "refs/pull/5/head"
           }
  end

  test "a comment travels over stdin and tells readers to refresh", %{dir: dir} do
    rules!(dir, [%{"args" => ["pr comment 5", "--repo github.com/acme/widgets", "--body-file -"]}])

    {:ok, revision} = T3.PullRequests.Refreshes.subscribe(self())
    next = revision + 1

    assert {:ok, nil} = PullRequests.comment(Map.put(@ref, "body", "  looks *good*\n"))
    assert [%{"stdin" => "  looks *good*\n", "args" => args}] = calls(dir, "pr comment")
    refute Enum.any?(args, &String.contains?(&1, "looks"))
    assert_receive {:t3_pull_request_refreshes, _, ^next}

    assert {:error,
            %{"_tag" => "PullRequestOperationError", "detail" => "A comment cannot be empty."}} =
             PullRequests.comment(Map.put(@ref, "body", "   "))
  end

  test "a merge runs only for someone who may merge", %{dir: dir} do
    rules!(dir, [permissions_rule("WRITE"), %{"args" => ["pr merge 5", "--squash"]}])

    assert {:ok, nil} =
             PullRequests.run_action(
               Map.merge(@ref, %{"action" => "merge", "mergeMethod" => "squash"})
             )

    assert [%{"args" => ["pr", "merge", "5", "--repo", "github.com/acme/widgets", "--squash"]}] =
             calls(dir, "pr merge")

    rules!(dir, [permissions_rule("READ")])

    assert {:error,
            %{
              "_tag" => "PullRequestOperationError",
              "detail" => "You need write access on this repository to merge."
            }} =
             PullRequests.run_action(Map.put(@ref, "action", "merge"))

    assert {:error,
            %{"detail" => "This stack action is not supported or has no expected head revision."}} =
             PullRequests.run_action(Map.merge(@ref, %{"action" => "merge", "stackNumber" => 3}))
  end

  test "activity joins the conversation with its threads, reactions and dismissals", %{dir: dir} do
    at = &"2026-01-0#{&1}T00:00:00Z"

    rules!(dir, [
      %{
        "args" => ["pr view 5", "author,comments,reviews,commits"],
        "stdout" => %{
          "author" => %{"login" => "someone"},
          "comments" => [
            %{
              "id" => "IC_1",
              "author" => %{"login" => "x"},
              "body" => "hi",
              "createdAt" => at.(3)
            }
          ],
          "reviews" => [
            %{
              "id" => "R_1",
              "author" => %{"login" => "rev"},
              "body" => "<!-- bot -->",
              "state" => "DISMISSED",
              "submittedAt" => at.(2)
            },
            %{
              "id" => "R_2",
              "author" => %{"login" => "rev"},
              "body" => "",
              "state" => "COMMENTED",
              "submittedAt" => at.(2)
            }
          ],
          "commits" => []
        }
      },
      %{
        "args" => ["api graphql"],
        "stdin" => ["reviewThreads"],
        "stdout" => %{
          "data" => %{
            "viewer" => %{"login" => "octo"},
            "repository" => %{
              "pullRequest" => %{
                "reviewThreads" => %{
                  "pageInfo" => %{"hasNextPage" => false},
                  "nodes" => [
                    %{
                      "id" => "T1",
                      "path" => "a.ex",
                      "line" => 3,
                      "diffSide" => "RIGHT",
                      "comments" => %{
                        "totalCount" => 12,
                        "pageInfo" => %{"hasNextPage" => true, "endCursor" => "C"},
                        "nodes" => [
                          %{
                            "id" => "RC1",
                            "author" => %{"login" => "rev", "avatarUrl" => "https://av/rev"},
                            "body" => "nit",
                            "createdAt" => at.(4),
                            "reactionGroups" => [
                              %{
                                "content" => "THUMBS_UP",
                                "viewerHasReacted" => true,
                                "reactors" => %{
                                  "totalCount" => 2,
                                  "nodes" => [%{"login" => "octo"}, %{"login" => "x"}]
                                }
                              }
                            ]
                          }
                        ]
                      }
                    }
                  ]
                },
                "author" => %{"login" => "someone", "avatarUrl" => "https://av/someone"},
                "reactionGroups" => [],
                "comments" => %{
                  "nodes" => [
                    %{
                      "id" => "IC_1",
                      "reactionGroups" => [
                        %{
                          "content" => "HEART",
                          "reactors" => %{"totalCount" => 1, "nodes" => [%{"login" => "x"}]}
                        }
                      ]
                    }
                  ]
                },
                "reviews" => %{"nodes" => []},
                "reviewRequests" => %{"nodes" => []},
                "latestReviews" => %{
                  "nodes" => [
                    %{
                      "state" => "APPROVED",
                      "author" => %{"login" => "rev", "avatarUrl" => "https://av/rev"}
                    }
                  ]
                },
                "reviewDismissals" => %{
                  "nodes" => [%{"dismissalMessage" => "stale", "review" => %{"id" => "R_1"}}]
                },
                "commits" => %{
                  "nodes" => [
                    %{
                      "commit" => %{
                        "oid" => "c1",
                        "messageHeadline" => "Add widgets",
                        "committedDate" => at.(1),
                        "additions" => 3,
                        "deletions" => 1,
                        "parents" => %{"totalCount" => 1},
                        "authors" => %{
                          "nodes" => [%{"name" => "S", "user" => %{"login" => "someone"}}]
                        }
                      }
                    }
                  ]
                }
              }
            }
          }
        }
      }
    ])

    assert {:ok, activity} = PullRequests.activity(@ref)
    assert activity["author"]["avatarUrl"] == "https://av/someone"
    assert [%{"login" => "rev"}] = activity["reviewers"]

    assert [
             %{"id" => "R_1", "kind" => "review", "body" => "stale"},
             %{
               "id" => "IC_1",
               "kind" => "issue-comment",
               "reactions" => [%{"content" => "heart", "count" => 1}]
             },
             %{
               "id" => "RC1",
               "kind" => "review-comment",
               "path" => "a.ex",
               "reactions" => [
                 %{
                   "content" => "thumbs-up",
                   "count" => 2,
                   "actors" => ["x"],
                   "viewerHasReacted" => true
                 }
               ]
             }
           ] = activity["comments"]

    assert activity["commentCount"] == 14
    assert activity["commentsTruncated"]

    assert [%{"id" => "T1", "line" => 3, "side" => "right", "nextCommentsCursor" => "C"}] =
             activity["reviewThreads"]

    assert [
             %{
               "oid" => "c1",
               "additions" => 3,
               "deletions" => 1,
               "authors" => [%{"login" => "someone", "avatarUrl" => "https://av/someone"}]
             }
           ] = activity["commits"]
  end

  test "a reaction is written only to a remark on the pull request it names", %{dir: dir} do
    subject = fn owner ->
      %{
        "args" => ["api graphql"],
        "stdin" => ["IssueComment"],
        "stdout" => %{
          "data" => %{
            "repository" => %{"pullRequest" => %{"id" => "PR_5"}},
            "node" => %{"id" => "IC_1", "pullRequest" => %{"id" => owner}}
          }
        }
      }
    end

    reaction = %{
      "args" => ["api graphql"],
      "stdin" => ["addReaction", "THUMBS_UP"],
      "stdout" => %{"data" => %{}}
    }

    input = Map.merge(@ref, %{"subjectId" => "IC_1", "content" => "thumbs-up", "reacted" => true})

    rules!(dir, [subject.("PR_9"), reaction])
    assert {:error, %{"_tag" => "PullRequestOperationError"}} = PullRequests.set_reaction(input)
    assert [_] = calls(dir, "graphql")

    rules!(dir, [subject.("PR_5"), reaction])
    assert {:ok, nil} = PullRequests.set_reaction(input)
  end

  test "a pull request opens in a worktree of its own, which is reused", %{dir: dir} do
    origin = Path.join(dir, "origin")
    File.mkdir_p!(origin)
    git!(origin, ~w(init -q -b main))
    File.write!(Path.join(origin, "a.txt"), "a\n")
    git!(origin, ~w(add a.txt))
    git!(origin, ~w(-c user.name=t -c user.email=t@t commit -q -m init))
    git!(origin, ~w(checkout -q -b feature))
    File.write!(Path.join(origin, "feature.txt"), "f\n")
    git!(origin, ~w(add feature.txt))
    git!(origin, ~w(-c user.name=t -c user.email=t@t commit -q -m feature))
    git!(origin, ~w(update-ref refs/pull/5/head HEAD))
    git!(origin, ~w(checkout -q main))
    work = Path.join(dir, "work")
    git!(dir, ["clone", "-q", origin, work])

    rules!(dir, [
      %{
        "args" => ["pr view 5"],
        "stdout" => %{
          "number" => 5,
          "title" => "Feature",
          "url" => "https://github.com/acme/widgets/pull/5",
          "baseRefName" => "main",
          "headRefName" => "feature",
          "state" => "OPEN",
          "isCrossRepository" => false
        }
      }
    ])

    assert {:ok,
            %{"pullRequest" => %{"number" => 5, "headBranch" => "feature", "state" => "open"}}} =
             PullRequests.Checkout.resolve(%{"cwd" => work, "reference" => "#5"})

    input = %{"cwd" => work, "reference" => "5", "mode" => "worktree"}

    assert {:ok, %{"branch" => "feature", "worktreePath" => path, "isOnPullRequestHead" => true}} =
             PullRequests.Checkout.prepare(input)

    assert File.read!(Path.join(path, "feature.txt")) == "f\n"
    assert git!(path, ~w(rev-parse --abbrev-ref @{upstream})) == "origin/feature\n"

    assert {:ok, %{"worktreePath" => ^path, "isOnPullRequestHead" => true}} =
             PullRequests.Checkout.prepare(input)
  end

  describe "POST /api/pull-requests/diff" do
    setup %{dir: dir} do
      Application.put_env(:t3, :port, 0)
      start_supervised!(T3.Auth)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
      {:ok, _} = Application.ensure_all_started(:inets)

      {:ok, token, _, _} =
        T3.Auth.exchange(T3.Auth.create_pairing_token(Path.join(dir, "t3.sqlite")))

      %{url: "http://127.0.0.1:#{port}/api/pull-requests/diff", token: token}
    end

    test "the whole change comes from gh pr diff", %{dir: dir, url: url, token: token} do
      patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n"

      rules!(dir, [
        %{
          "args" => ["pr diff 5", "--repo github.com/acme/widgets", "--color never"],
          "stdout" => patch
        }
      ])

      assert {200, %{"patch" => ^patch, "truncated" => false, "nextCursor" => nil}} =
               post(url, token, @ref)
    end

    test "a refused diff is read a page of files at a time", %{dir: dir, url: url, token: token} do
      page_one =
        for(
          i <- 1..99,
          do: %{
            "filename" => "f#{i}.txt",
            "status" => "modified",
            "patch" => "@@ -1 +1 @@\n-a\n+b",
            "additions" => 1,
            "deletions" => 1
          }
        ) ++
          [%{"filename" => "logo.png", "status" => "added", "additions" => 5, "deletions" => 0}]

      page_two = [
        %{
          "filename" => "new name.txt",
          "previous_filename" => "old.txt",
          "status" => "renamed",
          "additions" => 0,
          "deletions" => 0
        }
      ]

      rules!(dir, [
        %{
          "args" => ["pr diff 5"],
          "exit" => 1,
          "stderr" => "HTTP 406: Sorry, the diff exceeded the maximum number of files (300)."
        },
        %{"args" => ["pulls/5/files?per_page=100&page=1"], "stdout" => page_one},
        %{"args" => ["pulls/5/files?per_page=100&page=2"], "stdout" => page_two}
      ])

      assert {200, first} = post(url, token, @ref)
      assert %{"nextCursor" => "2", "truncated" => true} = first

      assert first["omittedFileStats"] == [
               %{"path" => "logo.png", "additions" => 5, "deletions" => 0}
             ]

      assert first["patch"] =~
               "diff --git a/f1.txt b/f1.txt\n--- a/f1.txt\n+++ b/f1.txt\n@@ -1 +1 @@\n-a\n+b\n"

      assert first["patch"] =~
               "diff --git a/logo.png b/logo.png\nnew file mode 100644\n--- /dev/null\n+++ b/logo.png\n"

      assert {200, second} = post(url, token, Map.put(@ref, "cursor", "2"))
      assert %{"nextCursor" => nil, "truncated" => false} = second
      refute Map.has_key?(second, "omittedFileStats")
      assert second["patch"] =~ "rename from old.txt\nrename to new name.txt\n"

      assert {502, %{"_tag" => "PullRequestOperationError", "operation" => "diff"}} =
               post(url, token, Map.put(@ref, "cursor", "nonsense"))
    end

    test "a client needs orchestration:read, and a host gh can read", %{
      dir: dir,
      url: url,
      token: token
    } do
      {:ok, %{"credential" => credential}} =
        T3.Auth.create_pairing_link(%{"scopes" => ["relay:read"]})

      {:ok, relay_only, _, _} = T3.Auth.exchange(credential)

      assert {403,
              %{
                "_tag" => "EnvironmentScopeRequiredError",
                "requiredScope" => "orchestration:read"
              }} =
               post(url, relay_only, @ref)

      assert {401, %{"_tag" => "EnvironmentAuthInvalidError", "reason" => "missing_credential"}} =
               post(url, nil, @ref)

      project!(dir, "p2", "https://gitlab.com/acme/app.git")

      assert {503, %{"_tag" => "PullRequestUnavailableError", "reason" => "provider-unsupported"}} =
               post(url, token, %{"projectId" => "p2", "repository" => "acme/app", "number" => 1})
    end
  end

  defp post(url, token, body) do
    headers = if token, do: [{~c"authorization", ~c"Bearer " ++ to_charlist(token)}], else: []

    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(:post, {url, headers, ~c"application/json", JSON.encode!(body)}, [], [])

    {status, JSON.decode!(to_string(resp))}
  end

  # --- helpers ------------------------------------------------------------------------

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end

  defp project!(dir, id, remote) do
    repo = Path.join(dir, id)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: repo)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: repo)

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => id,
        "title" => id,
        "workspaceRoot" => repo
      })

    assert_receive {:t3_shell, {:rows, _, [{^id, _}]}}, 1_000
  end

  defp rules!(dir, rules), do: File.write!(Path.join(dir, "rules.json"), JSON.encode!(rules))

  defp calls(dir, fragment) do
    dir
    |> Path.join("gh.log")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.filter(&String.contains?(Enum.join(&1["args"], " "), fragment))
  end

  defp viewer_rule, do: %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "octo"}}

  defp pr(number, updated, fields) do
    Map.merge(
      %{
        "number" => number,
        "title" => "PR #{number}",
        "url" => "https://github.com/acme/widgets/pull/#{number}",
        "author" => %{"login" => "someone"},
        "headRefName" => "feature-#{number}",
        "baseRefName" => "main",
        "state" => "OPEN",
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => updated
      },
      fields
    )
  end

  defp permissions_rule(permission),
    do: %{
      "args" => ["api graphql"],
      "stdin" => ["viewerCanUpdate viewerDidAuthor }"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "mergeCommitAllowed" => true,
            "squashMergeAllowed" => true,
            "rebaseMergeAllowed" => true,
            "viewerPermission" => permission,
            "pullRequest" => %{
              "viewerCanUpdate" => permission == "WRITE",
              "viewerDidAuthor" => false
            }
          }
        }
      }
    }

  defp core_rule(permission),
    do: %{
      "args" => ["api graphql"],
      "stdin" => ["viewerCanUpdateBranch"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "mergeCommitAllowed" => true,
            "squashMergeAllowed" => true,
            "rebaseMergeAllowed" => false,
            "viewerPermission" => permission,
            "pullRequest" => %{
              "number" => 5,
              "title" => "Widgets",
              "url" => "https://github.com/acme/widgets/pull/5",
              "body" => "Adds widgets.",
              "state" => "OPEN",
              "isDraft" => false,
              "mergeable" => "MERGEABLE",
              "reviewDecision" => nil,
              "additions" => 10,
              "deletions" => 2,
              "changedFiles" => 3,
              "createdAt" => "2026-01-01T00:00:00Z",
              "updatedAt" => "2026-01-02T00:00:00Z",
              "mergedAt" => nil,
              "closedAt" => nil,
              "headRefName" => "feature",
              "baseRefName" => "main",
              "headRefOid" => "abc1234",
              "isCrossRepository" => false,
              "headRepositoryOwner" => %{"login" => "acme"},
              "author" => %{"login" => "someone", "avatarUrl" => "https://avatars/someone"},
              "autoMergeRequest" => nil,
              "viewerCanUpdate" => true,
              "viewerDidAuthor" => false,
              "viewerCanUpdateBranch" => true,
              "baseRef" => %{"compare" => %{"behindBy" => 2}},
              "reviewRequests" => %{
                "nodes" => [%{"requestedReviewer" => %{"login" => "reviewer"}}]
              },
              "labels" => %{"nodes" => []},
              "commits" => %{
                "nodes" => [
                  %{
                    "commit" => %{
                      "statusCheckRollup" => %{
                        "contexts" => %{
                          "nodes" => [
                            %{
                              "__typename" => "CheckRun",
                              "name" => "build",
                              "status" => "COMPLETED",
                              "conclusion" => "SUCCESS"
                            }
                          ],
                          "pageInfo" => %{"hasNextPage" => false}
                        }
                      }
                    }
                  }
                ]
              }
            }
          }
        }
      }
    }
end
