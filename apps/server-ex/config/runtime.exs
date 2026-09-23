import Config

if home = System.get_env("T3_HOME"), do: config(:t3, home: home)
if port = System.get_env("T3_PORT"), do: config(:t3, port: String.to_integer(port))
