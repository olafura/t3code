import Config

# Tests start the pieces they need under their own supervisors.
config :t3, start_node: false
config :logger, level: :warning
