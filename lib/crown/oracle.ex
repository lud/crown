defmodule Crown.Oracle do
  @moduledoc """
  Behaviour for the external oracle used by `Crown` to determine leadership.

  The oracle is the authority that grants and renews the crown. Implementations
  back this with an external service (database lease, Redis lock, etc.) so that
  leadership is enforced even across netsplits.

  ## Callbacks

  * `init/1` — called once at startup with the oracle options.
  * `claim/1` — attempt to claim the crown. Returns `{true, refresh_delay, state}`
    on success, `{false, state}` otherwise. `refresh_delay` is a millisecond
    duration or `:infinity`.
  * `refresh/1` — renew an already-held crown. Same return shape as `claim/1`.
  * `abdicate/1` — optional. Called when the crown holder shuts down cleanly,
    allowing the oracle to release the claim early.
  * `handle_info/2` — optional. Called when Crown receives an unexpected message,
    forwarding it to the oracle. Useful when `monitor_leader: false` and the oracle
    needs to react to external signals (e.g. a webhook) to trigger a claim attempt.
    Returns the same shape as `claim/1` and `refresh/1`.
  """

  @doc "Initialize the oracle with the given options."
  @callback init(opts :: keyword()) ::
              {:ok, state :: term()}
              | {:error, reason :: term()}
              | :ignore

  @doc "Attempt to claim the crown."
  @callback claim(state :: term()) ::
              {true, refresh_delay :: non_neg_integer() | :infinity, new_state :: term()}
              | {false, new_state :: term()}

  @doc "Refresh an already-held crown."
  @callback refresh(state :: term()) ::
              {true, refresh_delay :: non_neg_integer() | :infinity, new_state :: term()}
              | {false, new_state :: term()}

  @doc "Release the crown on clean shutdown. Optional."
  @callback abdicate(state :: term()) :: :ok

  @doc "Handle an unexpected message forwarded by Crown. Optional."
  @callback handle_info(msg :: term(), state :: term()) ::
              {true, refresh_delay :: non_neg_integer() | :infinity, new_state :: term()}
              | {false, new_state :: term()}

  @optional_callbacks abdicate: 1, handle_info: 2
end
