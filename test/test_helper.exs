System.cmd("epmd", ~w(-daemon))
:ok = LocalCluster.start()

Application.stop(:logger)
{:ok, _} = Application.ensure_all_started(:crown, mode: :concurrent)

Crown.Oracles.PostgresLease.drop_leases_table(Crown.TestRepo)
ExUnit.start()
