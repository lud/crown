defmodule Crown.Oracles.PostgresLease do
  @moduledoc """
  A PostgreSQL-based oracle for leader election using database leases.

  Uses a single table with atomic upserts to manage leadership leases.
  The table is created automatically (no migrations needed).

  ## Options

    * `:repo` (required) - an `Ecto.Repo` module
    * `:duration` (optional, default `30`) - lease duration in seconds
    * `:crown_name` (injected by Crown) - used as the lock name

  ## Example

      {Crown,
       name: :my_worker,
       oracle: {Crown.Oracles.PostgresLease, repo: MyApp.Repo},
       child_spec: MyApp.SingletonWorker}

  """

  @behaviour Crown.Oracle

  alias Ecto.Adapters.SQL

  require Logger

  defstruct [:repo, :lock_name, :holder, :duration, :refresh_delay]

  @table "crown_lease_v1"

  @create_table_sql """
  CREATE TABLE IF NOT EXISTS #{@table} (
    lock_name TEXT PRIMARY KEY,
    holder TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
  )
  """

  @upsert_sql """
  INSERT INTO #{@table} (lock_name, holder, expires_at)
  VALUES ($1, $2, clock_timestamp() + make_interval(secs => $3))
  ON CONFLICT (lock_name) DO UPDATE
    SET holder = EXCLUDED.holder, expires_at = EXCLUDED.expires_at
    WHERE #{@table}.expires_at < clock_timestamp()
       OR #{@table}.holder = EXCLUDED.holder
  RETURNING holder
  """

  @delete_sql "DELETE FROM #{@table} WHERE lock_name = $1 AND holder = $2"

  @impl Crown.Oracle
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    lock_name = Atom.to_string(Keyword.fetch!(opts, :crown_name))
    duration = Keyword.get(opts, :duration, 30)
    holder = Atom.to_string(node())
    refresh_delay = div(duration * 1000, 2)

    Logger.debug("initialize table#{@table}", node: node())
    {:ok, _} = SQL.query(repo, @create_table_sql)

    state = %__MODULE__{
      repo: repo,
      lock_name: lock_name,
      holder: holder,
      duration: duration,
      refresh_delay: refresh_delay
    }

    {:ok, state}
  end

  @impl Crown.Oracle
  def claim(state) do
    do_upsert(state)
  end

  @impl Crown.Oracle
  def refresh(state) do
    do_upsert(state)
  end

  @impl Crown.Oracle
  def abdicate(state) do
    %__MODULE__{repo: repo, lock_name: lock_name, holder: holder} = state
    _ = SQL.query!(repo, @delete_sql, [lock_name, holder])
    :ok
  end

  @doc "Drops the leases table. Useful for test cleanup."
  def drop_leases_table(repo) do
    _ = SQL.query!(repo, "DROP TABLE IF EXISTS #{@table}")
    :ok
  end

  defp do_upsert(state) do
    %__MODULE__{
      repo: repo,
      lock_name: lock_name,
      holder: holder,
      duration: duration,
      refresh_delay: refresh_delay
    } = state

    result = SQL.query!(repo, @upsert_sql, [lock_name, holder, duration])

    case result do
      %{num_rows: n, rows: [[^holder] | _]} when n >= 1 ->
        {true, refresh_delay, state}

      _ ->
        {false, state}
    end
  end
end
