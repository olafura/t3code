defmodule T3.TextGenerationTest do
  use ExUnit.Case, async: false

  alias T3.{Settings, TextGeneration}
  alias T3.TextGeneration.{Prompts, Style}

  @moduletag :tmp_dir
  @fake Path.expand("../support/fake_text_cli.py", __DIR__)
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    previous =
      for key <- [:home, :text_claude_command, :text_codex_command, :acp_commands],
          do: {key, Application.get_env(:t3, key)}

    Application.put_env(:t3, :home, dir)
    log = Path.join(dir, "calls.jsonl")
    System.put_env("FAKE_TEXT_LOG", log)

    on_exit(fn ->
      System.delete_env("FAKE_TEXT_LOG")

      for {key, value} <- previous,
          do:
            if(value == nil,
              do: Application.delete_env(:t3, key),
              else: Application.put_env(:t3, key, value)
            )
    end)

    start_supervised!(Settings)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ~w(init -q -b main))
    git!(repo, ~w(config user.name t))
    git!(repo, ~w(config user.email t@t))
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    git!(repo, ["commit", "-q", "-m", "feat: first thing"])
    %{repo: repo, log: log}
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end

  defp settings!(doc) do
    {_, version} = Settings.get()
    {:ok, _} = Settings.put(doc, version)
  end

  defp install(clis) do
    Application.put_env(
      :t3,
      :text_claude_command,
      if(:claude in clis, do: @fake, else: "t3-test-no-claude")
    )

    Application.put_env(
      :t3,
      :text_codex_command,
      if(:codex in clis, do: @fake, else: "t3-test-no-codex")
    )
  end

  defp calls(log) do
    case File.read(log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp after_flag(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  describe "model routing" do
    test "commits use the source control writer and titles the text generation model", %{
      repo: repo,
      log: log
    } do
      install([:claude, :codex])

      settings!(%{
        "textGenerationModelSelection" => %{
          "instanceId" => "codex",
          "model" => "gpt-text",
          "options" => [%{"id" => "reasoningEffort", "value" => "medium"}]
        },
        "sourceControlWriterModelSelection" => %{
          "instanceId" => "claudeAgent",
          "model" => "claude-writer",
          "options" => [%{"id" => "effort", "value" => "high"}]
        }
      })

      assert {:ok,
              %{
                "subject" => "claude subject",
                "body" => "claude body",
                "branch" => "feature/claude-branch"
              }} = TextGeneration.commit_message(repo, "main", "M a.txt", "diff", true)

      assert {:ok, %{"title" => "codex title", "needsRefinement" => false}} =
               TextGeneration.thread_title(repo, "Fix the login page")

      assert [claude, codex] = calls(log)
      assert after_flag(claude["argv"], "--model") == "claude-writer"
      assert after_flag(claude["argv"], "--effort") == "high"
      assert Path.basename(claude["cwd"]) == "repo"
      assert claude["prompt"] =~ "Return a JSON object with keys: subject, body, branch."

      assert ["exec" | _] = codex["argv"]
      assert after_flag(codex["argv"], "--model") == "gpt-text"
      assert ~s(model_reasoning_effort="medium") in codex["argv"]
      assert codex["prompt"] =~ "User message:\nFix the login page"
    end

    test "a writer on a disabled provider falls back to the text generation model", %{
      repo: repo,
      log: log
    } do
      install([:claude, :codex])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"},
        "sourceControlWriterModelSelection" => %{"instanceId" => "claudeAgent", "model" => "x"},
        "providerInstances" => %{
          "claudeAgent" => %{"driver" => "claudeAgent", "enabled" => false}
        }
      })

      assert {:ok, %{"branch" => "codex-branch"}} = TextGeneration.branch_name(repo, "Add login")
      assert [%{"argv" => ["exec" | _] = argv}] = calls(log)
      assert after_flag(argv, "--model") == "gpt-text"
    end

    test "a model whose CLI is missing falls back to the first usable provider's default", %{
      repo: repo,
      log: log
    } do
      install([:claude])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"}
      })

      assert {:ok, %{"title" => "claude title"}} = TextGeneration.thread_title(repo, "Fix it")
      assert [%{"argv" => argv, "cwd" => cwd}] = calls(log)
      assert after_flag(argv, "--model") == "claude-haiku-4-5"
      # Titles run outside the checkout.
      assert Path.basename(cwd) =~ ~r/^t3-text-/

      install([])

      assert {:error, "No text generation provider is available" <> _} =
               TextGeneration.commit_message(repo, "main", "M a.txt", "diff")
    end

    test "an ACP agent writes through one prompt in an empty directory", %{repo: repo} do
      install([])
      Application.put_env(:t3, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})

      settings!(%{
        "providers" => %{"opencode" => %{"enabled" => true}},
        "sourceControlWriterModelSelection" => %{
          "instanceId" => "opencode",
          "model" => "fake/two"
        }
      })

      assert {:ok, %{"branch" => branch}} = TextGeneration.branch_name(repo, "Add login")
      assert branch =~ ~r{^acp-branch-fake/two-in-t3-text-\d+$}
    end
  end

  describe "writing style" do
    test "Conventional Commits and custom instructions", %{repo: repo} do
      settings!(%{"sourceControlWritingStyle" => %{"mode" => "conventional_commits"}})
      policy = Style.policy(repo)

      assert Prompts.commit("main", "M a.txt", "diff", false, policy) ==
               """
               You write concise git commit messages.
               Return a JSON object with keys: subject, body.
               Rules:
               - subject must be imperative, <= 72 chars, and no trailing period
               - body can be empty string or short bullet points
               - capture the primary user-visible or developer-visible change

               Additional instructions:
               Use Conventional Commits when generating commit subjects. Prefer the narrowest accurate type and include a scope only when it is obvious from the diff.

               Branch: main

               Staged files:
               M a.txt

               Staged patch:
               diff\
               """

      settings!(%{
        "sourceControlWritingStyle" => %{
          "mode" => "custom",
          "customInstructions" => " Be terse. "
        }
      })

      assert %{commit: "Be terse.", change_request: "Be terse."} = Style.policy(repo)

      settings!(%{"sourceControlWritingStyle" => %{"mode" => "custom"}})
      refute Prompts.commit("main", "M", "d", false, Style.policy(repo)) =~ "Additional"
    end

    test "repository conventions read commit subjects, AGENTS.md, and CLAUDE.md for Claude", %{
      repo: repo
    } do
      install([:claude, :codex])
      File.write!(Path.join(repo, "AGENTS.md"), "Use plain language.\n")
      File.write!(Path.join(repo, "CLAUDE.md"), "Claude only.\n")

      examples =
        "Recent commit subjects from this repository:\nfeat: first thing\n\nLocal AGENTS.md:\nUse plain language."

      assert Style.policy(repo) == %{
               kind: "repo_conventions",
               commit:
                 "Follow the repository's established commit message style when examples are available.\n\n" <>
                   examples,
               change_request:
                 "Follow the repository's established change request title and body style when examples are available.\n\n" <>
                   examples
             }

      settings!(%{
        "sourceControlWriterModelSelection" => %{"instanceId" => "claudeAgent", "model" => "x"}
      })

      assert Style.policy(repo).commit =~ examples <> "\n\nLocal CLAUDE.md:\nClaude only."
    end

    test "the pull request prompt follows the repository's template", %{repo: repo} do
      File.mkdir_p!(Path.join(repo, ".github/PULL_REQUEST_TEMPLATE"))
      File.write!(Path.join(repo, ".github/PULL_REQUEST_TEMPLATE/one.md"), "## One\n")
      git!(repo, ~w(add .))
      git!(repo, ~w(commit -q -m templates))
      assert Style.pr_template(repo, "HEAD") == "## One"

      # Two templates in the folder leave the choice to the user.
      File.write!(Path.join(repo, ".github/PULL_REQUEST_TEMPLATE/two.md"), "## Two\n")
      git!(repo, ~w(add .))
      git!(repo, ~w(commit -q -m more))
      assert Style.pr_template(repo, "HEAD") == nil

      # A template path wins; only the committed tree counts.
      File.write!(Path.join(repo, "pull_request_template.md"), "\n<!-- hint -->\n## Why\n")
      assert Style.pr_template(repo, "HEAD") == nil
      git!(repo, ~w(add .))
      git!(repo, ~w(commit -q -m root))
      template = Style.pr_template(repo, "HEAD")
      assert template == "<!-- hint -->\n## Why"

      prompt =
        Prompts.pr("main", "feature/x", "abc feat", "1 file", "diff", template, %{
          change_request: "Sentence case."
        })

      assert prompt ==
               """
               You write source control change request content.
               Return a JSON object with keys: title, body.
               Rules:
               - title should be concise and specific
               - body must be markdown and follow the repository change request template structure
               - fill in the template sections appropriately for this change
               - drop HTML comments from the template in the generated body
               - keep the template's markdown structure

               Additional instructions:
               Sentence case.

               Repository change request template:
               <!-- hint -->
               ## Why

               Base branch: main
               Head branch: feature/x

               Commits:
               abc feat

               Diff stat:
               1 file

               Diff patch:
               diff\
               """

      settings!(%{"sourceControlWritingStyle" => %{"followChangeRequestTemplates" => false}})
      assert Style.pr_template(repo, "HEAD") == nil
    end
  end

  test "a regenerated title reads the first and latest requests before the answers" do
    messages = [
      %{"role" => "user", "text" => "Fix the flaky login test"},
      %{"role" => "assistant", "text" => String.duplicate("a", 9_000)},
      %{"role" => "reasoning", "text" => "hidden"},
      %{
        "role" => "user",
        "text" => "Also cover logout",
        "attachments" => [%{"id" => "i1", "name" => "shot.png"}]
      }
    ]

    {text, attachments} = Prompts.thread_context(messages)

    assert "[Earlier content truncated]\n\nUSER:\nFix the flaky login test\n\nASSISTANT:\n" <>
             rest =
             text

    assert rest =~ "\n[Content truncated]\n"
    assert String.ends_with?(rest, "USER:\nAlso cover logout\n[Attachments: shot.png]")
    refute text =~ "hidden"
    assert [%{"id" => "i1"}] = attachments
  end
end
