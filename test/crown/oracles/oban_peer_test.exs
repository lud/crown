defmodule Crown.Oracles.ObanPeerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Crown.Oracles.ObanPeer, as: ObanPeerOracle

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Crown.MockObanPeer, :start_link, fn opts ->
      Agent.start_link(fn -> nil end, name: opts[:name])
    end)

    :ok
  end

  test "init/1 sets default values" do
    assert {:ok, state} = ObanPeerOracle.init([])

    assert state.oban_name == Oban
    assert state.timeout == 5_000
    assert state.refresh_delay == 15_000
  end

  test "init/1 accepts custom options" do
    assert {:ok, state} =
             ObanPeerOracle.init(
               oban_name: :"Elixir.Oban.Private",
               timeout: 1_000,
               refresh_delay: 250
             )

    assert state.oban_name == :"Elixir.Oban.Private"
    assert state.timeout == 1_000
    assert state.refresh_delay == 250
  end

  test "init/1 validates timeout" do
    assert {:error, {:invalid_option, :timeout, -1}} = ObanPeerOracle.init(timeout: -1)
  end

  test "init/1 validates refresh_delay" do
    assert {:error, {:invalid_option, :refresh_delay, :fast}} =
             ObanPeerOracle.init(refresh_delay: :fast)
  end

  test "claim/1 succeeds when Oban peer is leader" do
    expect(Crown.MockObanPeer, :leader?, fn _pid, _timeout -> true end)

    oban_name = start_oban!()
    state = init_state(oban_name)

    assert {true, 321, ^state} = ObanPeerOracle.claim(state)
  end

  test "claim/1 fails when Oban peer is not leader" do
    expect(Crown.MockObanPeer, :leader?, fn _pid, _timeout -> false end)

    oban_name = start_oban!()
    state = init_state(oban_name)

    assert {false, ^state} = ObanPeerOracle.claim(state)
  end

  test "refresh/1 mirrors claim behavior" do
    expect(Crown.MockObanPeer, :leader?, fn _pid, _timeout -> true end)
    expect(Crown.MockObanPeer, :leader?, fn _pid, _timeout -> false end)

    oban_name = start_oban!()
    state = init_state(oban_name)

    assert {true, 321, ^state} = ObanPeerOracle.refresh(state)
    assert {false, ^state} = ObanPeerOracle.refresh(state)
  end

  test "claim/1 fails safely when peer raises" do
    expect(Crown.MockObanPeer, :leader?, fn _pid, _timeout ->
      raise RuntimeError, "boom"
    end)

    oban_name = start_oban!()
    state = init_state(oban_name)

    assert {false, ^state} = ObanPeerOracle.claim(state)
  end

  test "claim/1 fails safely when peer exits" do
    expect(Crown.MockObanPeer, :leader?, fn _pid, _timeout -> exit(:noproc) end)

    oban_name = start_oban!()
    state = init_state(oban_name)

    assert {false, ^state} = ObanPeerOracle.claim(state)
  end

  defp start_oban! do
    name = :"TestOban#{System.unique_integer([:positive])}"

    start_supervised!(
      {Oban,
       name: name, repo: Crown.TestRepo, peer: Crown.MockObanPeer, queues: false, plugins: []}
    )

    name
  end

  defp init_state(oban_name) do
    assert {:ok, state} = ObanPeerOracle.init(oban_name: oban_name, refresh_delay: 321)
    state
  end
end
