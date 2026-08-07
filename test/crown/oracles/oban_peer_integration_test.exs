defmodule Crown.Oracles.ObanPeerIntegrationTest do
  use ExUnit.Case, async: false

  alias Crown.Oracles.ObanPeer, as: ObanPeerOracle
  alias Ecto.Adapters.SQL

  @moduletag :capture_log

  @repo Crown.TestRepo

  setup do
    SQL.query!(@repo, "DELETE FROM oban_peers", [])
    :ok
  end

  test "claim/1 succeeds when the local Oban peer holds the lease" do
    oban_name = start_oban!()

    assert {:ok, state} = ObanPeerOracle.init(oban_name: oban_name, refresh_delay: 100)
    assert {true, 100, ^state} = ObanPeerOracle.claim(state)
    assert {true, 100, ^state} = ObanPeerOracle.refresh(state)
  end

  test "refresh/1 fails after another node takes over the lease" do
    oban_name = start_oban!()

    assert {:ok, state} = ObanPeerOracle.init(oban_name: oban_name, refresh_delay: 100)
    assert {true, 100, ^state} = ObanPeerOracle.claim(state)

    take_over(oban_name, "+30 seconds")
    force_election(oban_name)

    assert {false, ^state} = ObanPeerOracle.refresh(state)
  end

  test "refresh/1 succeeds again once the other node's lease expires" do
    oban_name = start_oban!()

    assert {:ok, state} = ObanPeerOracle.init(oban_name: oban_name, refresh_delay: 100)
    assert {true, 100, ^state} = ObanPeerOracle.claim(state)

    take_over(oban_name, "-1 second")
    force_election(oban_name)

    assert {true, 100, ^state} = ObanPeerOracle.refresh(state)
  end

  test "claim/1 fails when the Oban instance is not running" do
    assert {:ok, state} = ObanPeerOracle.init(oban_name: :"NotStartedOban#{unique()}")

    ref = attach_query_error_handler()

    assert {false, ^state} = ObanPeerOracle.claim(state)
    assert_receive {^ref, :query_error, metadata}
    assert metadata.kind == :error
  end

  test "Crown starts the child on the Oban leader and stops it when leadership is conceded" do
    oban_name = start_oban!()
    crown_name = :"crown_oban_#{unique()}"
    worker_name = :"worker_#{unique()}"

    {:ok, crown} =
      Crown.start_link(
        name: crown_name,
        oracle: {ObanPeerOracle, oban_name: oban_name, refresh_delay: 50},
        child_spec: {Crown.TestWorker, name: worker_name}
      )

    crown_ref = Process.monitor(crown)

    assert eventually(fn -> is_pid(Process.whereis(worker_name)) end)
    assert Crown.leader?(crown)

    worker = Process.whereis(worker_name)
    worker_ref = Process.monitor(worker)

    take_over(oban_name, "+30 seconds")
    force_election(oban_name)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^crown_ref, :process, ^crown, :normal}, 1_000
  end

  test "Crown follows without starting the child when another node is the Oban leader" do
    oban_name = :"TestOban#{unique()}"

    # Another node holds a valid lease before this node's peer starts.
    insert_peer(oban_name, "web.B", "+30 seconds")

    ^oban_name = start_oban!(name: oban_name, node: "web.A")

    crown_name = :"crown_oban_#{unique()}"
    worker_name = :"worker_#{unique()}"

    {:ok, crown} =
      Crown.start_link(
        name: crown_name,
        oracle: {ObanPeerOracle, oban_name: oban_name, refresh_delay: 50},
        child_spec: {Crown.TestWorker, name: worker_name}
      )

    # The claim attempt is asynchronous, give it time to happen (and fail).
    Process.sleep(200)

    assert Process.alive?(crown)
    refute Crown.leader?(crown)
    refute is_pid(Process.whereis(worker_name))
  end

  # --- Helpers ---

  defp unique do
    System.unique_integer([:positive])
  end

  defp start_oban!(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, fn -> :"TestOban#{unique()}" end)

    opts =
      Keyword.merge(
        [
          name: name,
          repo: @repo,
          node: "web.A",
          peer: Oban.Peers.Database,
          notifier: Oban.Notifiers.PG,
          queues: false,
          plugins: [],
          stage_interval: :infinity
        ],
        opts
      )

    start_supervised!({Oban, opts}, id: name)

    name
  end

  # Overwrite the peers row so it belongs to another node, as Oban does in its
  # own peer tests. Coordinating actual remote nodes would not exercise
  # anything more.
  defp take_over(oban_name, interval) do
    conf_name = Oban.config(oban_name).name

    {:ok, _} =
      SQL.query(
        @repo,
        """
        UPDATE oban_peers
        SET node = 'web.B', expires_at = (now() at time zone 'utc') + interval '#{interval}'
        WHERE name = $1
        """,
        [inspect(conf_name)]
      )

    :ok
  end

  defp insert_peer(conf_name, node, interval) do
    {:ok, _} =
      SQL.query(
        @repo,
        """
        INSERT INTO oban_peers (name, node, started_at, expires_at)
        VALUES ($1, $2, now() at time zone 'utc',
                (now() at time zone 'utc') + interval '#{interval}')
        """,
        [inspect(conf_name), node]
      )

    :ok
  end

  defp force_election(oban_name) do
    pid = Oban.Registry.whereis(oban_name, Oban.Peer)
    GenServer.call(pid, :election)
    :ok
  end

  defp attach_query_error_handler do
    ref = make_ref()
    parent = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:crown, :oracle, :oban, :query_error],
      fn _event, _measurements, metadata, _config ->
        send(parent, {ref, :query_error, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ref
  end

  defp eventually(fun, timeout \\ 1_000) do
    cond do
      fun.() ->
        true

      timeout <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, timeout - 10)
    end
  end
end
