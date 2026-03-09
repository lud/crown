defmodule Crown.TelemetryTest do
  use ExUnit.Case, async: false
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  defp unique_name, do: :"crown_tel_#{:erlang.unique_integer([:positive])}"

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp start_fake_leader(crown_name) do
    {:ok, pid} = Agent.start(fn -> :ok end)
    :yes = :global.register_name(Crown.global_name(crown_name), pid)
    pid
  end

  defp attach_telemetry(test_name) do
    parent = self()

    handler = fn event, measurements, metadata, _ ->
      send(parent, {:telemetry, event, measurements, metadata})
    end

    :ok =
      :telemetry.attach_many(
        "#{test_name}-#{:erlang.unique_integer([:positive])}",
        Crown.Telemetry.events(),
        handler,
        nil
      )
  end

  defp assert_telemetry(event, extra_checks \\ []) do
    assert_receive {:telemetry, ^event, measurements, metadata}, 1000
    assert measurements == %{}
    assert is_atom(metadata.name)
    assert is_pid(metadata.pid)
    assert is_atom(metadata.phase)
    assert is_atom(metadata.ocl_mod)
    assert Map.has_key?(metadata, :monitored_node)

    for {key, expected} <- extra_checks do
      assert Map.fetch!(metadata, key) == expected,
             "expected #{inspect(key)} to be #{inspect(expected)}, got #{inspect(Map.get(metadata, key))} in event #{inspect(event)}"
    end

    metadata
  end

  defp refute_telemetry(event) do
    refute_receive {:telemetry, ^event, _, _}, 100
  end

  # --- Scenario: successful claim with child ---

  test "claim success emits initialized, claimed, child started, then terminated on stop" do
    parent = self()
    crown_name = unique_name()
    attach_telemetry("claim-success")

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
        child_spec: {Agent, fn -> :ok end}
      )

    assert_receive :claimed

    assert_telemetry([:crown, :process, :initialized],
      phase: :init,
      claim_delay: 0,
      name: crown_name
    )

    assert_telemetry([:crown, :leadership, :claimed],
      phase: :leading,
      refresh_delay: :infinity,
      monitored_node: node()
    )

    meta = assert_telemetry([:crown, :child, :started], phase: :leading, kind: :leader)
    assert is_pid(meta.child_pid)

    stop_and_wait(pid)

    assert_telemetry([:crown, :process, :terminating], reason: :normal)
    assert_telemetry([:crown, :child, :stopped], kind: :leader)
  end

  # --- Scenario: claim rejected, leader found, leader dies, reclaim ---

  test "claim rejected then leader down emits full monitoring cycle" do
    parent = self()
    crown_name = unique_name()
    attach_telemetry("reject-monitor-reclaim")
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

    assert_telemetry([:crown, :process, :initialized])
    assert_telemetry([:crown, :leadership, :rejected], phase: :following)

    meta =
      assert_telemetry([:crown, :monitor, :started],
        monitored_node: node(fake_leader)
      )

    assert meta.leader_pid == fake_leader
    assert meta.leader_node == node(fake_leader)

    # Kill the fake leader to trigger LEADER_DOWN
    stop_and_wait(fake_leader)
    assert_receive :reclaimed, 1000

    assert_telemetry([:crown, :monitor, :leader_down], monitored_node: nil)
    assert_telemetry([:crown, :leadership, :claimed], phase: :leading)

    stop_and_wait(pid)
    assert_telemetry([:crown, :process, :terminating])
  end

  # --- Scenario: claim rejected, no leader found, monitor retries then timeout ---

  test "monitor failed and timeout events fire when no leader is found" do
    parent = self()
    crown_name = unique_name()
    attach_telemetry("monitor-timeout")
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
        monitor_timeout: 120
      )

    assert_receive :first_claim

    assert_telemetry([:crown, :process, :initialized])
    assert_telemetry([:crown, :leadership, :rejected])

    # First failed attempt from start_monitoring
    meta = assert_telemetry([:crown, :monitor, :failed])
    assert meta.retry_count == 0
    assert meta.remaining_ms == 120
    assert meta.monitored_node == nil

    # Retry(s) from retry_monitoring
    meta = assert_telemetry([:crown, :monitor, :failed])
    assert meta.retry_count >= 1

    # Eventually times out and reclaims
    assert_receive :reclaimed, 1000
    assert_telemetry([:crown, :monitor, :timeout])

    assert_telemetry([:crown, :leadership, :claimed])

    stop_and_wait(pid)
  end

  # --- Scenario: refresh success ---

  test "refresh success emits refreshed event" do
    parent = self()
    crown_name = unique_name()
    attach_telemetry("refresh-success")

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, 50, :state}
    end)
    |> expect(:refresh, fn :state ->
      send(parent, :refreshed)
      {true, :infinity, :state}
    end)

    {:ok, pid} =
      Crown.start_link(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: nil
      )

    assert_receive :claimed
    assert_receive :refreshed, 500

    assert_telemetry([:crown, :process, :initialized])
    assert_telemetry([:crown, :leadership, :claimed], refresh_delay: 50)

    assert_telemetry([:crown, :leadership, :refreshed],
      phase: :leading,
      refresh_delay: :infinity
    )

    stop_and_wait(pid)
  end

  # --- Scenario: refresh failure (leadership lost) ---

  test "refresh failure emits lost event and process stops" do
    parent = self()
    crown_name = unique_name()
    attach_telemetry("refresh-lost")

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
        child_spec: {Agent, fn -> :ok end}
      )

    assert_receive :claimed
    crown_ref = Process.monitor(pid)
    assert_receive :refresh_failed, 500
    assert_receive {:DOWN, ^crown_ref, :process, ^pid, :normal}, 500

    assert_telemetry([:crown, :process, :initialized])
    assert_telemetry([:crown, :leadership, :claimed], monitored_node: node())
    assert_telemetry([:crown, :child, :started], kind: :leader)
    assert_telemetry([:crown, :leadership, :lost], phase: :leading)
    assert_telemetry([:crown, :child, :stopped], kind: :leader)
    assert_telemetry([:crown, :process, :terminating])
  end

  # --- Scenario: child crash ---

  test "child crash emits exited event" do
    crown_name = unique_name()
    attach_telemetry("child-crash")

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, :infinity, :state} end)

    crash_spec = %{
      id: :crash_child,
      start: {Task, :start_link, [fn -> raise "deliberate crash" end]},
      restart: :permanent
    }

    {:ok, pid} =
      Crown.start(
        name: crown_name,
        oracle: {Crown.OracleMock, []},
        child_spec: crash_spec
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    assert_telemetry([:crown, :process, :initialized])
    assert_telemetry([:crown, :leadership, :claimed])
    assert_telemetry([:crown, :child, :started], kind: :leader)
    assert_telemetry([:crown, :child, :exited], kind: :leader)
    assert_telemetry([:crown, :process, :terminating])
  end

  # --- Scenario: no child spec (nil) does not emit child events ---

  test "no child spec does not emit child started events" do
    parent = self()
    crown_name = unique_name()
    attach_telemetry("no-child")

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

    assert_telemetry([:crown, :process, :initialized])
    assert_telemetry([:crown, :leadership, :claimed])
    refute_telemetry([:crown, :child, :started])

    stop_and_wait(pid)

    assert_telemetry([:crown, :process, :terminating])
    refute_telemetry([:crown, :child, :stopped])
  end

  # --- Crown.Telemetry.events/0 ---

  test "Crown.Telemetry.events/0 returns all 14 event names" do
    events = Crown.Telemetry.events()
    assert length(events) == 14
    assert [:crown, :process, :initialized] in events
    assert [:crown, :process, :terminating] in events
    assert [:crown, :leadership, :claimed] in events
    assert [:crown, :leadership, :rejected] in events
    assert [:crown, :leadership, :refreshed] in events
    assert [:crown, :leadership, :lost] in events
    assert [:crown, :leadership, :conflict] in events
    assert [:crown, :monitor, :started] in events
    assert [:crown, :monitor, :failed] in events
    assert [:crown, :monitor, :timeout] in events
    assert [:crown, :monitor, :leader_down] in events
    assert [:crown, :child, :started] in events
    assert [:crown, :child, :stopped] in events
    assert [:crown, :child, :exited] in events
  end
end
