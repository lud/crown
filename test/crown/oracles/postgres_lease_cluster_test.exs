defmodule Crown.Oracles.PostgresLeaseClusterTest do
  use ExUnit.Case, async: false

  alias Crown.Oracles.PostgresLease

  @repo Crown.TestRepo

  defp unique_name do
    # erlang unique integer resets on each test run, we want unique names over
    # time

    Process.sleep(10)
    :"cluster_#{System.system_time(:microsecond)}"
  end

  defp start_cluster(num_nodes) do
    {:ok, cluster} =
      LocalCluster.start_link(num_nodes,
        prefix: "crown-peer-",
        environment: [
          logger: [
            default_formatter: [
              format: "PEER $metadata[$level] $message\n",
              metadata: [:node]
            ]
          ],
          crown: [
            {Crown.TestRepo,
             database: "crown_test",
             username: "postgres",
             password: "postgres",
             hostname: "localhost",
             port: 5432,
             log: false,
             pool_size: 5}
          ]
        ]
      )

    {:ok, nodes} = LocalCluster.nodes(cluster)

    Enum.each(nodes, fn peer ->
      # Enforce logger config
      :ok = :rpc.call(peer, Application, :stop, [:logger])
      :ok = :rpc.call(peer, Application, :start, [:logger])

      # Add our logs
      :ok = :rpc.call(peer, Crown, :attach_default_logger, [])
    end)

    {cluster, nodes}
  end

  defp start_crown_on(peer, opts) do
    {:ok, _crown_pid} =
      :rpc.call(peer, Supervisor, :start_child, [
        Crown.Supervisor,
        Supervisor.child_spec({Crown, opts}, restart: :transient)
      ])

    :ok
  end

  defp get_lease(lock_name) do
    result =
      Ecto.Adapters.SQL.query!(
        @repo,
        "SELECT holder, expires_at FROM crown_lease_v1 WHERE lock_name = $1",
        [Atom.to_string(lock_name)]
      )

    case result.rows do
      [[holder, expires_at]] -> {holder, expires_at}
      [] -> nil
    end
  end

  defp poll(fun, attempts \\ 20) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if attempts <= 1 do
          flunk("poll timed out")
        else
          Process.sleep(100)
          poll(fun, attempts - 1)
        end
    end
  end

  defp poll_leader([node_a, node_b], crown_name) do
    poll(fn ->
      a_leader? = :rpc.call(node_a, Crown, :leader?, [crown_name])
      b_leader? = :rpc.call(node_b, Crown, :leader?, [crown_name])

      case {a_leader?, b_leader?} do
        {true, false} -> {:ok, {node_a, node_b}}
        {false, true} -> {:ok, {node_b, node_a}}
        _ -> :retry
      end
    end)
  end

  defp poll_follower_monitoring(follower_node, crown_name) do
    poll(
      fn ->
        case :rpc.call(follower_node, Crown, :status, [crown_name]) do
          {:following, node} when is_atom(node) and node != nil -> {:ok, node}
          _ -> :retry
        end
      end,
      40
    )
  end

  # --- Cluster tests ---

  test "one of two nodes becomes leader, the other stays follower" do
    crown_name = unique_name()
    worker_name = :"worker_#{crown_name}"
    {_cluster, nodes} = start_cluster(2)

    for peer <- nodes do
      start_crown_on(peer,
        name: crown_name,
        oracle: {PostgresLease, repo: @repo, duration: 10},
        child_spec: {Crown.TestWorker, name: worker_name, node: peer}
      )
    end

    # Wait for one to become leader
    {leader_node, follower_node} = poll_leader(nodes, crown_name)

    # The leader's child is running and reports the correct node
    opts = :rpc.call(leader_node, Crown.TestWorker, :get_opts, [worker_name])
    assert opts[:node] == leader_node

    # The follower has no worker running
    assert :rpc.call(follower_node, GenServer, :whereis, [worker_name]) == nil

    # The lease in the DB belongs to the leader
    {holder, _} = get_lease(crown_name)
    assert holder == Atom.to_string(leader_node)
  end

  test "follower takes over after leader stops" do
    crown_name = unique_name()
    worker_name = :"worker_#{crown_name}"
    {_cluster, nodes} = start_cluster(2)

    for peer <- nodes do
      start_crown_on(peer,
        name: crown_name,
        oracle: {PostgresLease, repo: @repo, duration: 10},
        child_spec: {Crown.TestWorker, name: worker_name, node: peer}
      )
    end

    # Wait for leadership to settle
    {leader_node, follower_node} = poll_leader(nodes, crown_name)

    # Wait for the follower to be actively monitoring the leader
    poll_follower_monitoring(follower_node, crown_name)

    # Stop Crown on the leader (abdicate clears the lease)
    :ok = :rpc.call(leader_node, Crown, :stop, [crown_name])

    # The former follower should become the new leader
    poll(
      fn ->
        case :rpc.call(follower_node, Crown, :leader?, [crown_name]) do
          true -> {:ok, true}
          _ -> :retry
        end
      end,
      40
    )

    # Its worker is running with the correct node
    opts = :rpc.call(follower_node, Crown.TestWorker, :get_opts, [worker_name])
    assert opts[:node] == follower_node

    # The lease now belongs to the former follower
    {holder, _} = get_lease(crown_name)
    assert holder == Atom.to_string(follower_node)
  end

  test "leader node going down triggers failover" do
    crown_name = unique_name()
    worker_name = :"worker_#{crown_name}"
    {cluster, nodes} = start_cluster(2)

    # Use a short lease so the follower can claim quickly after the leader dies
    for peer <- nodes do
      start_crown_on(peer,
        name: crown_name,
        oracle: {PostgresLease, repo: @repo, duration: 2},
        child_spec: {Crown.TestWorker, name: worker_name, node: peer},
        monitor_delay: 200,
        monitor_timeout: 2000
      )
    end

    {leader_node, follower_node} = poll_leader(nodes, crown_name)

    # Wait for the follower to be actively monitoring the leader
    poll_follower_monitoring(follower_node, crown_name)

    # Kill the leader node entirely
    :ok = LocalCluster.stop(cluster, leader_node)

    # The follower should take over after the lease expires (~2s)
    poll(
      fn ->
        case :rpc.call(follower_node, Crown, :leader?, [crown_name]) do
          true -> {:ok, true}
          _ -> :retry
        end
      end,
      50
    )

    opts = :rpc.call(follower_node, Crown.TestWorker, :get_opts, [worker_name])
    assert opts[:node] == follower_node
  end
end
