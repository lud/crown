# Full mock, implements all callbacks including optional ones
Mox.defmock(Crown.OracleMockFull, for: Crown.Oracle)

# Minimal mock, skips optional callbacks
Mox.defmock(Crown.OracleMock, for: Crown.Oracle, skip_optional_callbacks: true)

Mox.defmock(Crown.MockObanPeer, for: Oban.Peer)
