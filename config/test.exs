import Config

config :crown, Crown.TestRepo,
  database: "crown_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  pool_size: 10,
  log: false
