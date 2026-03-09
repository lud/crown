# Full mock — implements all callbacks including optional ones (abdicate/1, handle_info/2).
# Use when a test specifically exercises those optional callbacks.
Mox.defmock(Crown.OracleMockFull, for: Crown.Oracle)

# Minimal mock — skips optional callbacks (abdicate/1, handle_info/2).
# Use for most tests: no stub needed, and Crown will correctly skip those code paths.
Mox.defmock(Crown.OracleMock, for: Crown.Oracle, skip_optional_callbacks: true)
