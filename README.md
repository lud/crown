# Crown

<!-- rdmx :badges
    hexpm         : "crown?color=4e2a8e"
    github_action : "lud/crown/elixir.yaml?label=CI&branch=main"
    license       : crown
    -->
[![hex.pm Version](https://img.shields.io/hexpm/v/crown?color=4e2a8e)](https://hex.pm/packages/crown)
[![Build Status](https://img.shields.io/github/actions/workflow/status/lud/crown/elixir.yaml?label=CI&branch=main)](https://github.com/lud/crown/actions/workflows/elixir.yaml?query=branch%3Amain)
[![License](https://img.shields.io/hexpm/l/crown.svg)](https://hex.pm/packages/crown)
<!-- rdmx /:badges -->

Crown is a leader election and singleton supervision library for Elixir. It runs
a child process on exactly one node of an Erlang cluster, delegating leadership
authority to a pluggable **oracle** (database lease, distributed lock, …) so
only one node holds the crown at a time, even during netsplits.

When a node holds the crown, Crown starts the configured `:child_spec`. When it
does not, it optionally starts a `:follower_child_spec` and monitors the leader
to claim again as soon as it goes down.

- [Crown](#crown)
  - [Installation](#installation)
  - [Built-in Oracles](#built-in-oracles)
    - [Postgres Lease](#postgres-lease)
    - [Oban Peer](#oban-peer)
  - [Custom Oracles](#custom-oracles)

## Installation

<!-- rdmx :app_dep vsn:$app_vsn -->
```elixir
def deps do
  [
    {:crown, "~> 0.2"},
  ]
end
```
<!-- rdmx /:app_dep -->



## Built-in Oracles

### Postgres Lease

`Crown.Oracles.PostgresLease` uses a single Postgres table to maintain a
time-bounded lease. The leader periodically refreshes the lease before it
expires; if the leader dies, the lease expires and another node takes over.

**How it works:**

* On startup the oracle creates a `crown_lease_v1` table (if missing) with
  `lock_name`, `holder` and `expires_at` columns.
* `claim/1` and `refresh/1` run an atomic upsert that succeeds only if the
  current row is expired, or the holder is this node. Postgres' `clock_timestamp()`
  is used to avoid relying on synchronized clocks across nodes.
* The refresh interval is half the lease duration so that a missed tick still
  leaves time for the next attempt before expiry.
* `abdicate/1` deletes the row on clean shutdown so a successor can claim
  immediately instead of waiting for expiry.

The oracle requires an `Ecto.Repo`. No migrations are needed, the
`crown_lease_v1` table is automatically created when needed.


<!-- rdmx :section name:postgres_lease_example format:true -->
```elixir
children = [
  MyApp.Repo,
  {Crown,
   name: :my_worker,
   oracle: {Crown.Oracles.PostgresLease, repo: MyApp.Repo, duration: 30},
   child_spec: MyApp.SingletonWorker}
]

Supervisor.start_link(children, strategy: :one_for_one)
```
<!-- rdmx /:section -->

### Oban Peer

`Crown.Oracles.ObanPeer` follows the leadership maintained by Oban's own peer
system. It does not acquire its own lock; instead, Crown becomes leader on
whichever node Oban already considers the leader. This is convenient for apps
that already run Oban and want to piggyback on its election.

**How it works:**

* `claim/1` and `refresh/1` call `Oban.Peer.leader?/2`. If the current node is
  the Oban leader, Crown takes the crown; otherwise it follows.
* Errors and timeouts from `Oban.Peer.leader?/2` are caught and treated as
  "not the leader", emitting a `[:crown, :oracle, :oban, :query_error]`
  telemetry event.
* The refresh delay defaults to 15 seconds. Because Oban manages the
  underlying lease, no `abdicate/1` is needed.

<!-- rdmx :section name:oban_peer_example format:true -->
```elixir
children = [
  {Oban, repo: MyApp.Repo, queues: [default: 10]},
  {Crown,
   name: :my_worker,
   oracle: {Crown.Oracles.ObanPeer, oban_name: Oban},
   child_spec: MyApp.SingletonWorker}
]

Supervisor.start_link(children, strategy: :one_for_one)
```
<!-- rdmx /:section -->

## Custom Oracles

Any module implementing the `Crown.Oracle` behaviour can be plugged in. The
contract is small: `init/1`, `claim/1`, `refresh/1`, and the optional
`abdicate/1` and `handle_info/2`.

The `claim/1` and `refresh/1` callbacks return `{true, refresh_delay, state}`
when leadership is granted, where `refresh_delay` is the number of milliseconds
Crown should wait before calling `refresh/1` again (or `:infinity` for
event-driven oracles). They return `{false, state}` when leadership is denied.

When the oracle options are a keyword list, Crown injects the Crown instance
name as `:crown_name` so the oracle can use it for namespacing (e.g. as a
lock key).

<!-- rdmx :section name:custom_oracle_example format:true -->
```elixir
defmodule MyApp.HttpLeaseOracle do
  @behaviour Crown.Oracle

  # Talks to an external lock service exposing:
  #   POST   /locks/:name/claim    {"holder": "..."}  -> 200 acquired / 409 held
  #   POST   /locks/:name/refresh  {"holder": "..."}  -> 200 renewed  / 409 lost
  #   DELETE /locks/:name          {"holder": "..."}  -> 204
  # The server is responsible for TTLs and expiry.

  @refresh_delay 5_000

  defstruct [:url, :holder]

  @impl Crown.Oracle
  def init(opts) do
    base = Keyword.fetch!(opts, :base_url)
    name = Atom.to_string(Keyword.fetch!(opts, :crown_name))

    {:ok, %__MODULE__{url: "#{base}/locks/#{name}", holder: Atom.to_string(node())}}
  end

  @impl Crown.Oracle
  def claim(state), do: post(state, "/claim")

  @impl Crown.Oracle
  def refresh(state), do: post(state, "/refresh")

  @impl Crown.Oracle
  def abdicate(state) do
    _ = Req.delete(state.url, json: %{holder: state.holder})
    :ok
  end

  defp post(state, path) do
    case Req.post(state.url <> path, json: %{holder: state.holder}) do
      {:ok, %{status: 200}} -> {true, @refresh_delay, state}
      _ -> {false, state}
    end
  end
end
```
<!-- rdmx /:section -->

For oracles that learn about leadership changes through external signals (e.g.
a webhook or a pub/sub message) rather than polling, implement `handle_info/2`
and start Crown with `monitor_leader: false`. Any message sent to the Crown
process will be forwarded to the oracle, which can then return
`{true, _, state}` or `{false, state}` to drive a claim or release.

