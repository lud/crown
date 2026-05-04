defmodule Crown.Oracles.ObanPeerTest.PeerStub do
  @moduledoc false

  def leader?(_oban_name, _timeout) do
    case Process.get(:peer_stub_result, false) do
      {:raise, exception} -> raise exception
      {:exit, reason} -> exit(reason)
      result when is_boolean(result) -> result
    end
  end
end

defmodule Crown.Oracles.ObanPeerTest do
  use ExUnit.Case, async: true

  alias Crown.Oracles.ObanPeer, as: ObanPeerOracle
  alias Crown.Oracles.ObanPeerTest.PeerStub

  setup do
    Process.delete(:peer_stub_result)
    :ok
  end

  test "init/1 sets default values" do
    assert {:ok, state} = ObanPeerOracle.init([])

    assert state.oban_name == Oban
    assert state.timeout == 5_000
    assert state.refresh_delay == 5_000
    assert state.peer_module == Oban.Peer
  end

  test "init/1 accepts custom options" do
    assert {:ok, state} =
             ObanPeerOracle.init(
               oban_name: :"Elixir.Oban.Private",
               timeout: 1_000,
               refresh_delay: 250,
               peer_module: PeerStub
             )

    assert state.oban_name == :"Elixir.Oban.Private"
    assert state.timeout == 1_000
    assert state.refresh_delay == 250
    assert state.peer_module == PeerStub
  end

  test "init/1 validates timeout" do
    assert {:error, {:invalid_option, :timeout, -1}} = ObanPeerOracle.init(timeout: -1)
  end

  test "init/1 validates refresh_delay" do
    assert {:error, {:invalid_option, :refresh_delay, :fast}} =
             ObanPeerOracle.init(refresh_delay: :fast)
  end

  test "claim/1 succeeds when Oban peer is leader" do
    Process.put(:peer_stub_result, true)
    state = init_state()

    assert {true, 321, ^state} = ObanPeerOracle.claim(state)
  end

  test "claim/1 fails when Oban peer is not leader" do
    Process.put(:peer_stub_result, false)
    state = init_state()

    assert {false, ^state} = ObanPeerOracle.claim(state)
  end

  test "refresh/1 mirrors claim behavior" do
    state = init_state()

    Process.put(:peer_stub_result, true)
    assert {true, 321, ^state} = ObanPeerOracle.refresh(state)

    Process.put(:peer_stub_result, false)
    assert {false, ^state} = ObanPeerOracle.refresh(state)
  end

  test "claim/1 fails safely when peer module raises" do
    Process.put(:peer_stub_result, {:raise, RuntimeError.exception("boom")})
    state = init_state()

    assert {false, ^state} = ObanPeerOracle.claim(state)
  end

  test "claim/1 fails safely when peer module exits" do
    Process.put(:peer_stub_result, {:exit, :noproc})
    state = init_state()

    assert {false, ^state} = ObanPeerOracle.claim(state)
  end

  defp init_state do
    assert {:ok, state} = ObanPeerOracle.init(peer_module: PeerStub, refresh_delay: 321)
    state
  end
end
