# Full mock, implements all callbacks including optional ones
Mox.defmock(Crown.OracleMockFull, for: Crown.Oracle)

# Minimal mock, skips optional callbacks
Mox.defmock(Crown.OracleMock, for: Crown.Oracle, skip_optional_callbacks: true)

# Behaviour matching the 2-arity convention used by Oban.Peer.safe_call/4 when
# dispatching to the configured peer module: apply(peer, :leader?, [pid, timeout]).
defmodule Crown.Test.ObanPeerBehaviour do
  @callback leader?(GenServer.server(), timeout()) :: boolean()
end

Mox.defmock(Crown.MockObanPeer, for: [Oban.Peer, Crown.Test.ObanPeerBehaviour])
