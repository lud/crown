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
ExUnit.start()
