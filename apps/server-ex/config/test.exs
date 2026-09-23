import Config

# Tests start the pieces they need under their own supervisors.
config :t3, start_node: false
config :logger, level: :warning

# Text generation never reaches a real model; tests that need it set a fake.
config :t3, text_claude_command: "t3-test-no-claude", text_codex_command: "t3-test-no-codex"

# Provider update checks never reach the npm registry.
config :t3, provider_update_checks: false

# Usage pricing never fetches the LiteLLM table; tests that price point this at a file.
config :t3, usage_rates_url: "t3-test-no-usage-rates.json"
