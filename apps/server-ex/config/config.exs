import Config

# State lives in the repo's gitignored .t3 sandbox during development so a dev node
# never opens the real ~/.t3/userdata. Releases default T3_HOME to ~/.t3/elixir
# (rel/env.sh.eex); runtime.exs reads it.
config :t3, home: Path.expand("../../../.t3/elixir", __DIR__), start_node: true

import_config "#{config_env()}.exs"
