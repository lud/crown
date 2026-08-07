case System.cmd("epmd", ~w(-names)) do
  # not running
  {"", 1} ->
    :ok

  {epmd_state, 0} ->
    IO.puts(:stderr, epmd_state)
end

{_, 0} = System.cmd("epmd", ~w(-daemon))
:ok = LocalCluster.start()

Application.stop(:logger)
{:ok, _} = Application.ensure_all_started(:crown, mode: :concurrent)

Crown.Oracles.PostgresLease.drop_leases_table(Crown.TestRepo)

# The Oban peer tests need the oban_* tables, so the test database migrates
# itself on every run.
Ecto.Migrator.run(
  Crown.TestRepo,
  Path.join(:code.priv_dir(:crown), "test_repo/migrations"),
  :up,
  all: true,
  log: false,
  log_migrations_sql: false
)

ExUnit.start()
