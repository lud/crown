defmodule Crown.Oracles.PostgresLeaseTest do
  use ExUnit.Case, async: false

  alias Crown.Oracles.PostgresLease
  alias Ecto.Adapters.SQL

  @repo Crown.TestRepo

  defp unique_name do
    :"lease_#{System.system_time(:microsecond)}"
  end

  defp init_oracle(opts \\ []) do
    name = Keyword.get(opts, :name, unique_name())
    duration = Keyword.get(opts, :duration, 30)

    oracle_opts = [repo: @repo, crown_name: name, duration: duration]
    {:ok, state} = PostgresLease.init(oracle_opts)
    state
  end

  defp init_oracle_with_holder(holder, opts) do
    state = init_oracle(opts)
    %{state | holder: holder}
  end

  defp insert_lease(lock_name, holder, expires_in_seconds) do
    SQL.query!(
      @repo,
      """
      INSERT INTO crown_lease_v1 (lock_name, holder, expires_at)
      VALUES ($1, $2, NOW() + make_interval(secs => $3))
      """,
      [Atom.to_string(lock_name), holder, expires_in_seconds]
    )
  end

  defp get_lease(lock_name) do
    result =
      SQL.query!(
        @repo,
        "SELECT holder, expires_at FROM crown_lease_v1 WHERE lock_name = $1",
        [Atom.to_string(lock_name)]
      )

    case result.rows do
      [[holder, expires_at]] -> {holder, expires_at}
      [] -> nil
    end
  end

  # --- Initialization ---

  test "init/1 succeeds with valid repo" do
    assert {:ok, %PostgresLease{}} = PostgresLease.init(repo: @repo, crown_name: :test_init)
  end

  test "init/1 is idempotent (calling twice doesn't fail)" do
    assert {:ok, _} = PostgresLease.init(repo: @repo, crown_name: :test_idem)
    assert {:ok, _} = PostgresLease.init(repo: @repo, crown_name: :test_idem)
  end

  test "default duration is 30, refresh_delay is 15_000" do
    {:ok, state} = PostgresLease.init(repo: @repo, crown_name: :test_defaults)
    assert state.duration == 30
    assert state.refresh_delay == 15_000
  end

  test "custom duration yields correct refresh_delay" do
    {:ok, state} = PostgresLease.init(repo: @repo, crown_name: :test_dur, duration: 10)
    assert state.duration == 10
    assert state.refresh_delay == 5_000
  end

  test "holder is node() as string" do
    {:ok, state} = PostgresLease.init(repo: @repo, crown_name: :test_holder)
    assert state.holder == Atom.to_string(node())
  end

  # --- Claim ---

  test "claim/1 succeeds on empty table" do
    state = init_oracle()
    assert {true, 15_000, ^state} = PostgresLease.claim(state)
  end

  test "claim/1 fails when another holder has an active lease" do
    name = unique_name()
    state = init_oracle(name: name)
    insert_lease(name, "other_node@host", 60)
    assert {false, ^state} = PostgresLease.claim(state)
  end

  test "claim/1 succeeds when existing lease from another holder is expired" do
    name = unique_name()
    state = init_oracle(name: name)
    insert_lease(name, "other_node@host", -10)
    assert {true, 15_000, ^state} = PostgresLease.claim(state)
  end

  test "claim/1 succeeds when we already hold the lease (idempotent)" do
    state = init_oracle()
    assert {true, _, ^state} = PostgresLease.claim(state)
    assert {true, _, ^state} = PostgresLease.claim(state)
  end

  test "after successful claim, the row has correct holder and future expires_at" do
    name = unique_name()
    state = init_oracle(name: name)
    assert {true, _, _} = PostgresLease.claim(state)

    {holder, expires_at} = get_lease(name)
    assert holder == state.holder
    assert DateTime.after?(expires_at, DateTime.utc_now())
  end

  # --- Refresh ---

  test "refresh/1 succeeds when we hold the lease" do
    state = init_oracle()
    {true, _, state} = PostgresLease.claim(state)
    assert {true, 15_000, ^state} = PostgresLease.refresh(state)
  end

  test "refresh/1 extends expires_at" do
    name = unique_name()
    state = init_oracle(name: name)
    {true, _, state} = PostgresLease.claim(state)
    {_, first_expires} = get_lease(name)

    # Small sleep to ensure time difference
    Process.sleep(10)
    {true, _, _} = PostgresLease.refresh(state)
    {_, second_expires} = get_lease(name)

    assert DateTime.after?(second_expires, first_expires)
  end

  test "refresh/1 fails when someone else holds an active lease" do
    name = unique_name()
    state = init_oracle(name: name)
    insert_lease(name, "other_node@host", 60)
    assert {false, ^state} = PostgresLease.refresh(state)
  end

  test "refresh/1 fails when our lease has expired and someone else claimed" do
    name = unique_name()
    state = init_oracle(name: name)
    # We claim first
    {true, _, state} = PostgresLease.claim(state)
    # Simulate expiry + another holder claiming
    SQL.query!(
      @repo,
      "UPDATE crown_lease_v1 SET holder = $1, expires_at = NOW() + interval '60 seconds' WHERE lock_name = $2",
      ["other_node@host", Atom.to_string(name)]
    )

    assert {false, ^state} = PostgresLease.refresh(state)
  end

  # --- Abdicate ---

  test "abdicate/1 deletes our lease row" do
    name = unique_name()
    state = init_oracle(name: name)
    {true, _, state} = PostgresLease.claim(state)
    assert :ok = PostgresLease.abdicate(state)
    assert nil == get_lease(name)
  end

  test "abdicate/1 is safe when no row exists" do
    state = init_oracle()
    assert :ok = PostgresLease.abdicate(state)
  end

  test "abdicate/1 does not delete another holder's row" do
    name = unique_name()
    state = init_oracle(name: name)
    insert_lease(name, "other_node@host", 60)
    assert :ok = PostgresLease.abdicate(state)
    assert {"other_node@host", _} = get_lease(name)
  end

  test "after abdicate, another holder can claim immediately" do
    name = unique_name()
    state = init_oracle(name: name)
    {true, _, state} = PostgresLease.claim(state)
    :ok = PostgresLease.abdicate(state)

    other = init_oracle_with_holder("other_node@host", name: name)
    assert {true, _, _} = PostgresLease.claim(other)
  end

  # --- Competition (two oracle instances, different holders) ---

  test "two oracles with same lock_name: only one can claim" do
    name = unique_name()
    state_a = init_oracle(name: name)
    state_b = init_oracle_with_holder("other_node@host", name: name)

    assert {true, _, _} = PostgresLease.claim(state_a)
    assert {false, _} = PostgresLease.claim(state_b)
  end

  test "after winner abdicates, loser can claim" do
    name = unique_name()
    state_a = init_oracle(name: name)
    state_b = init_oracle_with_holder("other_node@host", name: name)

    {true, _, state_a} = PostgresLease.claim(state_a)
    {false, _} = PostgresLease.claim(state_b)

    :ok = PostgresLease.abdicate(state_a)
    assert {true, _, _} = PostgresLease.claim(state_b)
  end

  test "after winner's lease expires, loser can claim" do
    name = unique_name()
    state_a = init_oracle(name: name, duration: 1)
    state_b = init_oracle_with_holder("other_node@host", name: name)

    {true, _, _} = PostgresLease.claim(state_a)
    {false, _} = PostgresLease.claim(state_b)

    # Simulate expiry
    SQL.query!(
      @repo,
      "UPDATE crown_lease_v1 SET expires_at = NOW() - interval '1 second' WHERE lock_name = $1",
      [Atom.to_string(name)]
    )

    assert {true, _, _} = PostgresLease.claim(state_b)
  end

  # --- Integration test (through Crown GenServer) ---

  test "Crown with PostgresLease oracle becomes leader and abdicates on stop" do
    name = unique_name()
    parent = self()

    {:ok, pid} =
      Crown.start_link(
        name: name,
        oracle: {PostgresLease, repo: @repo, duration: 10},
        child_spec: {Agent, fn -> send(parent, :child_started) end}
      )

    assert_receive :child_started, 5000
    assert Crown.leader?(pid)

    # Stop and verify lease is cleared
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert nil == get_lease(name)
  end
end
