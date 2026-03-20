import Config

config :crown, env: config_env()

config :logger, :default_formatter,
  format: "MAIN $metadata[$level] $message\n",
  metadata: [:node, :module]

if config_env() == :test, do: import_config("test.exs")
