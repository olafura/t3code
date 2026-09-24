defmodule T3.Antigravity.ProtocolTest do
  use ExUnit.Case, async: true

  alias T3.Antigravity.{ClientFiles, Profile, Prompt, Protocol, Skills}

  @moduletag :tmp_dir

  @models [
    %{
      "id" => "model",
      "type" => "select",
      "currentValue" => "gemini-2.5-pro",
      "options" => [
        %{"value" => "gemini-2.5-pro", "name" => "Gemini 2.5 Pro"},
        %{"group" => "Flash", "options" => [%{"value" => "gemini-3.8-flash-high", "name" => ""}]}
      ]
    }
  ]

  test "runtime modes map to the agent's permission modes" do
    assert Protocol.permission_mode("full-access") == "yolo"
    assert Protocol.permission_mode("auto-accept-edits") == "auto_edit"
    assert Protocol.permission_mode("approval-required") == "default"
    assert Protocol.permission_mode("auto") == "default"
  end

  test "a chosen model is always applied; the default alias prefers the manifest default" do
    assert Protocol.resolve_model(@models, "gemini-2.5-pro") == {:set, "gemini-2.5-pro"}

    assert Protocol.resolve_model(@models, "antigravity-default") ==
             {:set, "gemini-3.8-flash-high"}

    assert Protocol.resolve_model(@models, nil) == {:set, "gemini-3.8-flash-high"}
    # Without the manifest default on the account, the agent keeps its current model.
    assert Protocol.resolve_model(@models, "antigravity-default", "gemini-9") == :keep

    assert {:error, "Antigravity model 'gemini-1' is unavailable" <> _} =
             Protocol.resolve_model(@models, "gemini-1")
  end

  test "models keep native ids, and the manifest decides the default and legacy ones" do
    models = Protocol.models(%{"configOptions" => @models})

    assert [
             %{
               "slug" => "gemini-2.5-pro",
               "isDefault" => true,
               "aliases" => ["antigravity-default"]
             },
             %{"slug" => "gemini-3.8-flash-high", "name" => "gemini-3.8-flash-high"}
           ] = models

    assert [old, current] = Protocol.classify(models)
    assert %{"isLegacy" => true} = old
    refute Map.has_key?(old, "isDefault")
    assert %{"isDefault" => true, "aliases" => ["antigravity-default"]} = current
    refute Map.has_key?(current, "isLegacy")

    assert [%{"slug" => "m1", "isDefault" => true}] =
             Protocol.models(%{
               "models" => %{
                 "currentModelId" => "m1",
                 "availableModels" => [%{"modelId" => "m1", "name" => "One"}]
               }
             })
  end

  test "approvals offer only what the request can honour, with the agent's warning" do
    params = %{
      "toolCall" => %{"toolCallId" => "call-1"},
      "options" => [
        %{"optionId" => "once", "kind" => "allow_once"},
        %{
          "optionId" => "always",
          "kind" => "allow_always",
          "_meta" => %{"agy.security.warning" => %{"title" => "Careful"}}
        }
      ]
    }

    assert Protocol.approval_options(params) == [
             %{"decision" => "accept", "label" => "Allow once"},
             %{
               "decision" => "acceptForSession",
               "label" => "Allow for this thread",
               "warning" => "Careful"
             },
             %{"decision" => "cancel", "label" => "Cancel"}
           ]

    assert Protocol.option_for(params, "accept") == "once"
    assert Protocol.option_for(params, "acceptForSession") == "always"
    assert Protocol.option_for(params, "decline") == nil
    assert Protocol.option_for(params, "cancel") == nil
  end

  test "native questions become user questions answered by option or label" do
    params = %{
      "toolCall" => %{"toolCallId" => "interaction_7", "title" => "  Which one?  "},
      "options" => [%{"optionId" => "a", "name" => "Apple"}, %{"optionId" => "b", "name" => ""}]
    }

    assert Protocol.question?(params)
    assert Protocol.approval_options(params) == []

    assert %{
             "id" => "interaction_7",
             "question" => "Which one?",
             "options" => [%{"label" => "Apple"}, %{"label" => "b"}],
             "multiSelect" => false
           } = Protocol.question(params)

    selected = &%{"outcome" => %{"outcome" => "selected", "optionId" => &1}}
    assert Protocol.question_response(params, %{"interaction_7" => "Apple"}) == selected.("a")
    assert Protocol.question_response(params, %{"interaction_7" => ["b"]}) == selected.("b")
    assert Protocol.question_response(params, %{"interaction_7" => "Pear"}) == nil

    assert Protocol.question(%{
             params
             | "options" => [%{"optionId" => "a"}, %{"optionId" => "a"}]
           }) == nil
  end

  test "tool updates are bounded and their native command fields mapped" do
    long = String.duplicate("x", 9_000)

    update =
      Protocol.normalize_update(%{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "t",
        "rawInput" => %{
          "CommandLine" => " ls -la ",
          "image" => %{"type" => "image", "data" => "AAAA"}
        },
        "rawOutput" => %{
          "combinedOutput" => long,
          "formatted_output" => long,
          "shot" => "data:image/png;base64,AAAA"
        }
      })

    assert update["kind"] == "execute"
    assert update["rawInput"]["command"] == "ls -la"
    assert update["rawInput"]["image"] == %{"type" => "image"}
    assert "[Earlier output truncated]\n\n" <> tail = update["rawOutput"]["output"]
    assert byte_size(tail) == 8_000
    refute Map.has_key?(update["rawOutput"], "formatted_output")
    refute Map.has_key?(update["rawOutput"], "shot")

    other = %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => long}}
    assert Protocol.normalize_update(other) == other
  end

  @url "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A8123%2F&state=s1"

  test "sign-in URLs are read from the agent's lines and checked" do
    assert {:ok, %{redirect_uri: "http://127.0.0.1:8123/", state: "s1"}} =
             Protocol.auth_line(Protocol.auth_prefix() <> @url <> "\r\n")

    assert {:ok, _} = Protocol.auth_line(Profile.auth_marker() <> @url, Profile.auth_marker())
    assert Protocol.auth_line(Profile.auth_marker() <> @url) == :none
    assert Protocol.auth_line("{\"jsonrpc\":\"2.0\"}") == :none

    for bad <- [
          String.replace(@url, "accounts.google.com", "evil.example"),
          String.replace(@url, "127.0.0.1%3A8123", "127.0.0.1%3A80"),
          String.replace(@url, "response_type=code", "response_type=token"),
          @url <> "&state=s2",
          @url <> "#frag"
        ] do
      assert {:error, "Antigravity returned an invalid Google sign-in URL."} =
               Protocol.auth_line(Protocol.auth_prefix() <> bad)
    end
  end

  test "a pasted redirect must answer the current sign-in" do
    pending = %{redirect_uri: "http://127.0.0.1:8123/", state: "s1"}
    assert :ok = Protocol.validate_callback("http://127.0.0.1:8123/?state=s1&code=abc", pending)

    assert :ok =
             Protocol.validate_callback(
               "http://127.0.0.1:8123/?state=s1&error=access_denied&iss=https%3A%2F%2Faccounts.google.com",
               pending
             )

    assert {:error, "This redirect URL does not belong" <> _} =
             Protocol.validate_callback("http://127.0.0.1:9000/?state=s1&code=abc", pending)

    assert {:error, "This redirect URL does not belong" <> _} =
             Protocol.validate_callback("http://127.0.0.1:8123/?state=other&code=abc", pending)

    assert {:error, "The redirect URL must contain one" <> _} =
             Protocol.validate_callback("http://127.0.0.1:8123/?state=s1&code=a&code=b", pending)

    assert {:error, "The redirect URL is not a Google" <> _} =
             Protocol.validate_callback("http://127.0.0.1:8123/?state=s1&code=a&iss=x", pending)

    assert {:error, "Paste the complete redirect URL" <> _} =
             Protocol.validate_callback("not a url", pending)
  end

  describe "prompts" do
    defp attachment(dir, name, type, mime, body, extra \\ %{}) do
      path = Path.join(dir, name)
      File.write!(path, body)
      Map.merge(%{type: type, name: name, mime_type: mime, path: path}, extra)
    end

    test "uploads go as native content", %{tmp_dir: dir} do
      assert {:ok, blocks} =
               Prompt.build("  look  ", [
                 attachment(dir, "a.png", "image", "image/png", <<1, 2>>),
                 attachment(dir, "b.mp3", "file", "audio/mpeg; codec=x", "ID3"),
                 attachment(dir, "c.pdf", "file", "application/pdf", "%PDF"),
                 attachment(dir, "d.py", "file", "application/octet-stream", "defmodule"),
                 attachment(dir, "e.txt", "file", "text/plain", "pasted", %{pasted: true})
               ])

      assert [
               %{"type" => "text", "text" => "look"},
               %{"type" => "image", "mimeType" => "image/png", "data" => "AQI="},
               %{"type" => "audio", "mimeType" => "audio/mpeg"},
               %{"type" => "resource_link", "uri" => "file://" <> _, "name" => "c.pdf"},
               %{"type" => "resource", "resource" => %{"text" => "defmodule"}}
             ] = blocks
    end

    test "unsupported, oversized and binary files fail the turn", %{tmp_dir: dir} do
      assert {:error, "Antigravity does not support 'x.gif'" <> _} =
               Prompt.build("hi", [attachment(dir, "x.gif", "image", "image/gif", "GIF")])

      big =
        attachment(dir, "big.txt", "file", "text/plain", String.duplicate("a", 1024 * 1024 + 1))

      assert {:error, "Attachment 'big.txt' is too large." <> _} = Prompt.build("hi", [big])

      assert {:error, "Attachment 'bin.txt' contains binary data."} =
               Prompt.build("hi", [attachment(dir, "bin.txt", "file", "text/plain", <<0, 1>>)])

      assert {:error, "Attachment 'l.txt' is not a UTF-8 text file."} =
               Prompt.build("hi", [attachment(dir, "l.txt", "file", "text/plain", <<0xFF>>)])

      assert {:error, "A turn requires text or supported attachments."} = Prompt.build(" ", [])
    end
  end

  describe "client files" do
    test "reads and writes stay inside the session's roots", %{tmp_dir: dir} do
      work = Path.join(dir, "work")
      outside = Path.join(dir, "outside")
      File.mkdir_p!(work)
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(work, "link"))

      assert {:ok, %{}} =
               ClientFiles.write([work], %{
                 "path" => Path.join(work, "a/b.txt"),
                 "content" => "1\n2\n3"
               })

      assert {:ok, %{"content" => "2\n3"}} =
               ClientFiles.read([work], %{"path" => Path.join(work, "a/b.txt"), "line" => 2})

      assert {:ok, %{"content" => "1"}} =
               ClientFiles.read([work], %{"path" => Path.join(work, "a/b.txt"), "limit" => 1})

      assert {:error, %{"code" => -32602}} =
               ClientFiles.write([work], %{"path" => Path.join(outside, "x"), "content" => ""})

      assert {:error, %{"code" => -32602}} =
               ClientFiles.write([work], %{"path" => Path.join(work, "link/x"), "content" => ""})

      refute File.exists?(Path.join(outside, "x"))

      assert {:error, %{"code" => -32002}} =
               ClientFiles.read([work], %{"path" => Path.join(work, "missing")})
    end
  end

  describe "profiles" do
    test "settings name the method and GCP block, never a key" do
      config = %{
        "authMethod" => "agent-platform",
        "apiKey" => "k",
        "gcpProject" => "p",
        "gcpLocation" => ""
      }

      assert JSON.decode!(Profile.settings_json(config)) == %{
               "auth" => %{"type" => "agent-platform"},
               "gcp" => %{"project" => "p"}
             }
    end

    test "only the configured method's key reaches the agent, and other credentials are unset" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "leak")
      on_exit(fn -> System.delete_env("GOOGLE_CLOUD_PROJECT") end)
      exe = %{path: "/opt/agy/agy_acp_server.par", harness: "/opt/agy/localharness_external"}

      config = %{
        "authMethod" => "gemini-api-key",
        "apiKey" => "secret",
        "gcpProject" => "",
        "gcpLocation" => ""
      }

      {argv, env} = Profile.command(exe, "/p", config, [{"GEMINI_HOME", "/x"}, {"KEEP", "1"}])

      assert ["-u", "GOOGLE_CLOUD_PROJECT"] -- argv == []
      assert List.last(argv) == "/opt/agy/agy_acp_server.par" or List.last(argv) == "--uid="
      assert {"GEMINI_API_KEY", "secret"} in env
      assert {"GEMINI_HOME", "/p"} in env
      assert {"KEEP", "1"} in env
      refute {"GEMINI_HOME", "/x"} in env
      assert {"ANTIGRAVITY_HARNESS_PATH", "/opt/agy/localharness_external"} in env
      refute Enum.any?(env, &(elem(&1, 0) == "GOOGLE_API_KEY"))
    end

    test "a profile suppresses the browser and links the user skills", %{tmp_dir: dir} do
      home = Path.join(dir, "user")
      File.mkdir_p!(Path.join(home, ".gemini/config/skills"))
      profile = Path.join(dir, "profile")

      assert {:ok, ^profile} =
               Profile.prepare_dir(
                 profile,
                 %{"authMethod" => "oauth-personal", "gcpProject" => "", "gcpLocation" => ""},
                 home
               )

      assert File.read_link!(Path.join(profile, "config/skills")) ==
               Path.join(home, ".gemini/config/skills")

      {_argv, env} =
        Profile.command(%{path: "/a", harness: "/b"}, profile, %{"authMethod" => "oauth-personal"})

      {_, browser} = List.keyfind(env, "BROWSER", 0)
      [_, helper] = Regex.run(~r/^'(.+)' %s$/, browser)

      assert {out, 0} = System.cmd(helper, ["https://x.test/"], stderr_to_stdout: true)
      assert out == Profile.auth_marker() <> "https://x.test/\n"
    end
  end

  test "skills come from the agent's roots, first name wins", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(dir, "work")

    write = fn path, body ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    write.(Path.join(home, ".gemini/config/skills/review/SKILL.md"), """
    ---
    name: review
    description: >
      Reviews the
      current diff.
    ---
    body
    """)

    write.(
      Path.join(cwd, ".gemini/skills/review/SKILL.md"),
      "---\nname: review\ndescription: project\n---\n"
    )

    write.(Path.join(cwd, ".agents/skills/SKILL.md"), "---\ndescription: 'A root skill'\n---\n")
    write.(Path.join(cwd, ".agent/skills/bad/SKILL.md"), "---\nname: \" padded \"\n---\n")

    assert {:ok, [root, review]} = Skills.discover(cwd, home)
    assert %{"name" => "SKILL", "description" => "A root skill", "scope" => "project"} = root

    assert %{
             "name" => "review",
             "description" => "Reviews the current diff.",
             "scope" => "user",
             "enabled" => true
           } =
             review
  end
end
