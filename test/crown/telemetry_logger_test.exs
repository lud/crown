defmodule Crown.TelemetryLoggerTest do
  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureLog

  setup :set_mox_global
  setup :verify_on_exit!

  defp unique_name, do: :"crown_tlog_#{:erlang.unique_integer([:positive])}"

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

  defp await_monitoring(crown_name, target_pid, timeout \\ 1000) do
    crown_pid = Process.whereis(crown_name)
    {:monitored_by, monitored_by} = Process.info(target_pid, :monitored_by)

    if crown_pid in monitored_by do
      true
    else
      if timeout <= 0, do: flunk("monitoring not established in time")
      Process.sleep(50)
      await_monitoring(crown_name, target_pid, timeout - 50)
    end
  end

  setup do
    # Detach any previous logger attachment to avoid conflicts
    :telemetry.detach(Crown.TelemetryLogger)
    :ok
  rescue
    _ -> :ok
  end

  # --- attach with no filters logs all events ---

  test "logs initialized, claimed, and terminated for a simple claim scenario" do
    crown_name = unique_name()
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    :ok = Crown.attach_default_logger()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: nil
          )

        assert_receive :claimed
        stop_and_wait(pid)
      end)

    assert log =~ "[crown] #{crown_name} initialized"
    assert log =~ "[crown] #{crown_name} elected as leader"
    assert log =~ "[crown] #{crown_name} terminated (:normal)"
  end

  # --- attach with min_log_level filter ---

  test "min_log_level: :warning skips info and debug events" do
    crown_name = unique_name()
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    :ok = Crown.attach_default_logger(min_log_level: :warning)

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: nil
          )

        assert_receive :claimed
        stop_and_wait(pid)
      end)

    # initialized is :info, claimed is :info — both should be filtered out
    refute log =~ "[crown] #{crown_name} initialized"
    refute log =~ "[crown] #{crown_name} elected"
  end

  # --- attach with prefixes filter ---

  test "prefixes: [[:crown, :leadership]] only attaches to leadership events" do
    crown_name = unique_name()
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    :ok = Crown.attach_default_logger(prefixes: [[:crown, :leadership]])

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: {Agent, fn -> :ok end}
          )

        assert_receive :claimed
        stop_and_wait(pid)
      end)

    # Leadership event should be logged
    assert log =~ "[crown] #{crown_name} elected as leader"
    # Process and child events should not be logged
    refute log =~ "[crown] #{crown_name} initialized"
    refute log =~ "started leader child"
  end

  # --- leadership lost logs a warning ---

  test "refresh failure logs leadership lost warning" do
    crown_name = unique_name()
    parent = self()

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

    :ok = Crown.attach_default_logger()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: nil,
            monitor_delay: 5000
          )

        assert_receive :claimed
        assert_receive :refresh_failed, 500
        stop_and_wait(pid)
      end)

    assert log =~ "[crown] #{crown_name} lost leadership"
    assert log =~ "[warning]"
  end

  # --- leader down logs ---

  test "leader down logs a warning with the leader node" do
    crown_name = unique_name()
    parent = self()
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

    :ok = Crown.attach_default_logger()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: nil
          )

        assert_receive :first_claim, 1000
        await_monitoring(crown_name, fake_leader)
        stop_and_wait(fake_leader)
        assert_receive :reclaimed, 1000
        stop_and_wait(pid)
      end)

    assert log =~ "[crown] #{crown_name} leader on node"
    assert log =~ "went down, claiming"
  end

  # --- child crash logs an error ---

  test "child crash logs an error" do
    crown_name = unique_name()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state -> {true, :infinity, :state} end)

    crash_spec = %{
      id: :crash_child,
      start: {Task, :start_link, [fn -> raise "deliberate crash" end]},
      restart: :permanent
    }

    :ok = Crown.attach_default_logger()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: crash_spec
          )

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      end)

    assert log =~ "[crown] #{crown_name} leader child crashed:"
  end

  # --- monitor failed logs ---

  test "monitor failed and timeout logs when no leader is found" do
    crown_name = unique_name()
    parent = self()

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

    :ok = Crown.attach_default_logger()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: nil,
            monitor_delay: 50,
            monitor_timeout: 120
          )

        assert_receive :first_claim
        assert_receive :reclaimed, 1000
        stop_and_wait(pid)
      end)

    assert log =~ "[crown] #{crown_name} could not find leader"
    assert log =~ "[crown] #{crown_name} monitor timed out"
    assert log =~ "reclaiming"
  end

  # --- claim_delay is shown when non-zero ---

  test "claim_delay is shown in log when non-zero" do
    crown_name = unique_name()
    parent = self()

    Crown.OracleMock
    |> expect(:init, fn _ -> {:ok, :state} end)
    |> expect(:claim, fn :state ->
      send(parent, :claimed)
      {true, :infinity, :state}
    end)

    :ok = Crown.attach_default_logger()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Crown.start_link(
            name: crown_name,
            oracle: {Crown.OracleMock, []},
            child_spec: nil,
            claim_delay: 100
          )

        assert_receive :claimed, 1000
        stop_and_wait(pid)
      end)

    assert log =~ "[crown] #{crown_name} initialized, first claim in 100ms"
  end
end
