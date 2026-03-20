defmodule CrownTest do
  use ExUnit.Case, async: false
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  # --- Helpers ---

  defp unique_name, do: :"crown_#{:erlang.unique_integer([:positive])}"

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # Registers a fake process as the current crown holder for the given crown name.
  # This simulates another node holding the crown.
  defp start_fake_leader(crown_name) do
    {:ok, pid} = Agent.start(fn -> :ok end)
    :yes = :global.register_name(Crown.global_name(crown_name), pid)
    pid
  end

  defp assert_leader(pid_or_name), do: assert(Crown.leader?(pid_or_name))
  defp refute_leader(pid_or_name), do: refute(Crown.leader?(pid_or_name))

  # --- Existing passing test ---

  test "starts the process, inits the oracle, claims the crown and starts the child" do
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn opts ->
      assert "hello" == Keyword.fetch!(opts, :some_opt)
      send(parent, :oracle_init_called)
      {:ok, :some_state}
    end)
    |> expect(:claim, fn :some_state ->
      send(parent, :oracle_claim_called)
      {true, :infinity, :some_state}
    end)

    child_spec = {Agent, fn -> send(parent, :child_started) end}

    {:ok, pid} =
      Crown.start_link(
        name: :test_crown,
        oracle: {Crown.OracleMock, some_opt: "hello"},
        child_spec: child_spec
      )

    assert_receive :oracle_init_called
    assert_receive :oracle_claim_called
    assert_receive :child_started

    stop_and_wait(pid)
  end

  # --- Oracle initialization ---

  test "oracle.init returning {:error, reason} prevents Crown from starting" do
    Crown.OracleMock
    |> expect(:init, fn _ -> {:error, :some_reason} end)

    assert {:error, :some_reason} =
             Crown.start_link(
               name: unique_name(),
               oracle: {Crown.OracleMock, []},
               child_spec: nil
             )
  end

  test "oracle.init returning :ignore is passed through" do
    Crown.OracleMock
    |> expect(:init, fn _ -> :ignore end)

    assert :ignore =
             Crown.start_link(
               name: unique_name(),
               oracle: {Crown.OracleMock, []},
               child_spec: nil
             )
  end

  # --- Claiming — success ---

  test "Crown is registered globally when leading" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :claimed
    assert_leader(pid)
    assert pid == :global.whereis_name(Crown.global_name(crown_name))
    stop_and_wait(pid)
  end

  test "claim is not attempted before claim_delay has elapsed" do
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        claim_delay: 200
      )

    refute_receive :claimed, 100
    assert_receive :claimed, 200
    stop_and_wait(pid)
  end

  # --- Claiming — failure ---

  test "child is not started when claim fails" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: {Agent, fn -> send(parent, :child_started) end},
        monitor_delay: 0
      )

    refute_receive :child_started, 200
    stop_and_wait(pid)
  end

  test "follower child is started when claim fails and follower_child_spec is set" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)

    {:ok, _pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        follower_child_spec: {Agent, fn -> send(parent, :follower_started) end},
        monitor_delay: 0
      )

    assert_receive :follower_started
  end

  test "Crown attempts to monitor the leader immediately after a failed claim" do
    parent = self()
    crown_name = unique_name()
    fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :first_claim)
      {false, :state}
    end)
    |> expect(:claim, fn :state ->
      send(parent, :reclaimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :first_claim
    refute_leader(pid)
    # Crown found and is monitoring the leader; stop it to trigger reclaim
    stop_and_wait(fake_leader)
    assert_receive :reclaimed, 1000
    stop_and_wait(pid)
  end

  test "when leader is not found, Crown retries after monitor_delay then claims after monitor_timeout" do
    parent = self()
    crown_name = unique_name()
    # No fake leader — :global.whereis_name returns :undefined

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :first_claim)
      {false, :state}
    end)
    |> expect(:claim, fn :state ->
      send(parent, :reclaimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        monitor_delay: 50,
        monitor_timeout: 200
      )

    assert_receive :first_claim
    # Crown cannot find a leader and keeps retrying every monitor_delay ms.
    # After monitor_timeout it gives up and claims again.
    refute_receive :reclaimed, 100
    assert_receive :reclaimed, 300
    stop_and_wait(pid)
  end

  test "when monitor_leader is false, Crown stays alive without monitoring" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        monitor_leader: false
      )

    assert_receive :claimed
    refute_leader(pid)
    # Crown is alive, not leading, and has set up no monitors
    # despite a leader being available in global
    assert Process.alive?(pid)
    assert [] == pid |> Process.info(:monitors) |> elem(1)
    stop_and_wait(pid)
  end

  # --- Monitoring — leader goes down ---

  test "when the monitored leader dies, Crown attempts to claim" do
    parent = self()
    crown_name = unique_name()
    fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :first_claim)
      {false, :state}
    end)
    |> expect(:claim, fn :state ->
      send(parent, :reclaimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        monitor_delay: 0
      )

    assert_receive :first_claim
    refute_leader(pid)
    stop_and_wait(fake_leader)
    assert_receive :reclaimed, 1000
    stop_and_wait(pid)
  end

  test "when Crown claims after leader dies, follower child stops and leader child starts" do
    parent = self()
    crown_name = unique_name()
    fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :reclaimed)
      {true, :infinity, :state}
    end)

    {:ok, _pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: {Agent, fn -> send(parent, :leader_started) end},
        follower_child_spec: {Agent, fn -> send(parent, {:follower_pid, self()}) end},
        monitor_delay: 0
      )

    assert_receive {:follower_pid, follower_pid}
    follower_ref = Process.monitor(follower_pid)
    refute_leader(crown_name)

    stop_and_wait(fake_leader)
    assert_receive :reclaimed, 1000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, _}, 1000
    assert_receive :leader_started, 1000
  end

  test "when Crown fails to claim after leader dies, it goes back to monitoring" do
    parent = self()
    crown_name = unique_name()
    fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :first_claim)
      {false, :state}
    end)
    |> expect(:claim, fn :state ->
      send(parent, :second_claim)
      # Another node grabbed the crown during the failover
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        monitor_delay: 0,
        monitor_timeout: 5000
      )

    assert_receive :first_claim
    refute_leader(pid)
    stop_and_wait(fake_leader)
    assert_receive :second_claim, 1000
    # Crown should still be alive, waiting to find and monitor a new leader
    assert Process.alive?(pid)
    stop_and_wait(pid)
  end

  test "when Crown fails to claim after leader dies, follower child is kept alive" do
    parent = self()
    crown_name = unique_name()
    fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :second_claim)
      {false, :state_after_second_claim}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        follower_child_spec: {Agent, fn -> send(parent, {:follower_pid, self()}) end},
        monitor_delay: 0,
        monitor_timeout: 5000
      )

    assert_receive {:follower_pid, follower_pid}
    follower_ref = Process.monitor(follower_pid)
    refute_leader(pid)

    stop_and_wait(fake_leader)
    assert_receive :second_claim, 1000
    refute_leader(pid)
    # Follower child should still be running, unchanged
    assert Process.alive?(follower_pid)
    refute_receive {:DOWN, ^follower_ref, :process, ^follower_pid, _}, 200
    stop_and_wait(pid)
  end

  # --- Refresh ---

  test "oracle.refresh is called after the refresh_delay returned by claim" do
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, 50, :state} end)
    |> expect(:refresh, fn :state ->
      send(parent, :refreshed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :refreshed, 500
    stop_and_wait(pid)
  end

  test "successive refreshes work, each scheduling the next" do
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, 50, :state} end)
    |> expect(:refresh, fn :state ->
      send(parent, :first_refresh)
      {true, 50, :state}
    end)
    |> expect(:refresh, fn :state ->
      send(parent, :second_refresh)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :first_refresh, 500
    assert_receive :second_refresh, 500
    stop_and_wait(pid)
  end

  test "oracle.refresh is never called when refresh_delay is :infinity" do
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :claimed
    refute_receive :refreshed, 200
    stop_and_wait(pid)
  end

  test "when refresh fails, Crown tears down child, unregisters from global, and stops" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :first_claim)
      {true, 50, :state}
    end)
    |> expect(:refresh, fn :state ->
      send(parent, :refresh_failed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: {Agent, fn -> send(parent, {:child_pid, self()}) end}
      )

    assert_receive :first_claim
    assert_receive {:child_pid, child_pid}
    child_ref = Process.monitor(child_pid)
    crown_ref = Process.monitor(pid)

    assert_receive :refresh_failed, 500
    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _}, 500
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 500
    assert :undefined == :global.whereis_name(Crown.global_name(crown_name))
  end

  test "when refresh fails with no child spec, Crown unregisters from global and stops" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :first_claim)
      {true, 50, :state}
    end)
    |> expect(:refresh, fn :state ->
      send(parent, :refresh_failed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :first_claim
    assert_leader(pid)
    assert pid == :global.whereis_name(Crown.global_name(crown_name))

    crown_ref = Process.monitor(pid)
    assert_receive :refresh_failed, 500
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 500
    assert :undefined == :global.whereis_name(Crown.global_name(crown_name))
  end

  test "after refresh failure, Crown process stops so monitors on other nodes fire" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, 50, :state} end)
    |> expect(:refresh, fn :state ->
      send(parent, :refresh_failed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: {Agent, fn -> send(parent, :child_started) end}
      )

    assert_receive :child_started, 500
    crown_ref = Process.monitor(pid)

    assert_receive :refresh_failed, 500
    # Crown stops so that other nodes monitoring this pid get :DOWN
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 500
  end

  # --- Child / supervisor failure ---

  test "when the leader child crashes, Crown stops" do
    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, :infinity, :state} end)

    crash_spec = %{
      id: :crash_leader,
      start: {Task, :start_link, [fn -> raise "deliberate crash" end]},
      restart: :permanent
    }

    {:ok, pid} =
      Crown.start(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: crash_spec
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  test "when the follower child crashes, Crown stops" do
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)

    crash_spec = %{
      id: :crash_follower,
      start: {Task, :start_link, [fn -> raise "deliberate crash" end]},
      restart: :permanent
    }

    {:ok, pid} =
      Crown.start(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        follower_child_spec: crash_spec,
        monitor_delay: 0
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  test "when the leader child exits normally, Crown stops" do
    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, :infinity, :state} end)

    normal_exit_spec = %{
      id: :normal_exit,
      start: {Task, :start_link, [fn -> :ok end]},
      restart: :permanent
    }

    {:ok, pid} =
      Crown.start(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: normal_exit_spec
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  # --- Clean shutdown during init phase ---

  test "stopping Crown before claim_delay fires shuts down cleanly" do
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ ->
      send(parent, :oracle_init_called)
      {:ok, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: unique_name(),
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        claim_delay: 60_000
      )

    assert_receive :oracle_init_called
    # Stop while still in :init phase (claim_delay hasn't fired)
    stop_and_wait(pid)
  end

  # --- Abdicate / clean shutdown ---

  test "oracle.abdicate is called on clean shutdown when leading" do
    parent = self()

    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)
    |> expect(:abdicate, fn :state ->
      send(parent, :abdicated)
      :ok
    end)

    {:ok, pid} =
      Crown.start_link(
        name: unique_name(),
        oracle: {Crown.OracleMockFull, []},
        child_spec: nil
      )

    assert_receive :claimed
    stop_and_wait(pid)
    assert_receive :abdicated
  end

  test "oracle.abdicate is not called on clean shutdown when not leading" do
    crown_name = unique_name()
    parent = self()

    # Not stubbing or expecting :abdicate — any unexpected call will fail the test
    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMockFull, []},
        child_spec: nil,
        monitor_delay: 0
      )

    assert_receive :claimed
    refute_leader(pid)
    stop_and_wait(pid)
  end

  test "global name is unregistered on clean shutdown" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :claimed
    assert_leader(pid)
    assert pid == :global.whereis_name(Crown.global_name(crown_name))
    stop_and_wait(pid)
    assert :undefined == :global.whereis_name(Crown.global_name(crown_name))
  end

  test "global name is unregistered when refresh fails" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, 50, :state}
    end)
    |> expect(:refresh, fn :state ->
      send(parent, :refresh_failed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :claimed
    crown_ref = Process.monitor(pid)
    assert_receive :refresh_failed, 500
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 500
    assert :undefined == :global.whereis_name(Crown.global_name(crown_name))
  end

  # --- Global name conflict ---

  test "global_name_conflict while leading tears down child, abdicates, and stops" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)
    |> expect(:abdicate, fn :state ->
      send(parent, :abdicated)
      :ok
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMockFull, []},
        child_spec: {Agent, fn -> send(parent, {:child_pid, self()}) end}
      )

    assert_receive :claimed
    assert_receive {:child_pid, child_pid}
    child_ref = Process.monitor(child_pid)
    crown_ref = Process.monitor(pid)

    send(pid, {:global_name_conflict, Crown.global_name(crown_name)})

    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _}, 1000
    assert_receive :abdicated
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 1000
  end

  test "global_name_conflict while following tears down follower child and stops" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil,
        follower_child_spec: {Agent, fn -> send(parent, {:follower_pid, self()}) end},
        monitor_delay: 0
      )

    assert_receive :claimed
    assert_receive {:follower_pid, follower_pid}
    follower_ref = Process.monitor(follower_pid)
    crown_ref = Process.monitor(pid)

    send(pid, {:global_name_conflict, Crown.global_name(crown_name)})

    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, _}, 1000
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 1000
  end

  test "global_name_conflict while leading with no child still abdicates and stops" do
    parent = self()
    crown_name = unique_name()

    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)
    |> expect(:abdicate, fn :state ->
      send(parent, :abdicated)
      :ok
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMockFull, []},
        child_spec: nil
      )

    assert_receive :claimed
    crown_ref = Process.monitor(pid)

    send(pid, {:global_name_conflict, Crown.global_name(crown_name)})

    assert_receive :abdicated
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 1000
  end

  # --- oracle.handle_info ---

  @tag :skip
  test "unknown message is forwarded to oracle.handle_info" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)
    |> expect(:handle_info, fn :some_external_message, :state ->
      send(parent, :handle_info_called)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMockFull, []},
        child_spec: nil,
        monitor_delay: 0
      )

    refute_leader(pid)
    send(pid, :some_external_message)
    assert_receive :handle_info_called, 500
    stop_and_wait(pid)
  end

  @tag :skip
  test "oracle.handle_info returning {true, refresh_delay, state} makes Crown become leader" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)
    |> expect(:handle_info, fn :claim_now, :state ->
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMockFull, []},
        child_spec: {Agent, fn -> send(parent, :leader_started) end},
        monitor_delay: 0
      )

    refute_leader(pid)
    send(pid, :claim_now)
    assert_receive :leader_started, 500
    stop_and_wait(pid)
  end

  @tag :skip
  test "oracle.handle_info returning {false, state} keeps Crown in its current state" do
    parent = self()
    crown_name = unique_name()
    _fake_leader = start_fake_leader(crown_name)

    Crown.OracleMockFull
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {false, :state} end)
    |> expect(:handle_info, fn :claim_now, :state ->
      send(parent, :handle_info_returned_false)
      {false, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMockFull, []},
        child_spec: {Agent, fn -> send(parent, :leader_started) end},
        monitor_delay: 0
      )

    refute_leader(pid)
    send(pid, :claim_now)
    assert_receive :handle_info_returned_false, 500
    refute_receive :leader_started, 200
    stop_and_wait(pid)
  end

  @tag :skip
  test "unknown messages are silently dropped when oracle.handle_info is not exported" do
    crown_name = unique_name()

    # OracleMock skips optional callbacks, so handle_info/2 is not exported.
    # Crown should detect this and drop unknown messages without crashing.
    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, :infinity, :state} end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_leader(pid)
    send(pid, :some_unknown_message)
    assert_leader(pid)
    assert Process.alive?(pid)
    stop_and_wait(pid)
  end
end
