defmodule Crown.Oracles.ObanPeer do
  @moduledoc """
  An Oban-based oracle that mirrors `Oban.Peer.leader?/2` leadership.

  This oracle doesn't acquire leadership itself. Instead, Crown follows the
  leadership already maintained by Oban's peer system.

  ## Options

    * `:oban_name` (optional, default `Oban`) - Oban instance name passed to
      `Oban.Peer.leader?/2`.
    * `:timeout` (optional, default `5000`) - timeout in milliseconds for
      `Oban.Peer.leader?/2`.
    * `:refresh_delay` (optional, default `5000`) - milliseconds until the next
      leadership check after a successful claim/refresh.
    * `:peer_module` (optional, default `Oban.Peer`) - module implementing
      `leader?/2`. Primarily useful for tests.

  ## Example

      {Crown,
       name: :my_worker,
       oracle: {Crown.Oracles.ObanPeer, oban_name: Oban},
       child_spec: MyApp.SingletonWorker}
  """

  @behaviour Crown.Oracle

  require Logger

  @default_oban_name Oban
  @default_peer_module Oban.Peer
  @default_timeout 5_000
  @default_refresh_delay 5_000

  defstruct [:oban_name, :timeout, :refresh_delay, :peer_module]

  @impl Crown.Oracle
  def init(opts) do
    oban_name = Keyword.get(opts, :oban_name, @default_oban_name)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    refresh_delay = Keyword.get(opts, :refresh_delay, @default_refresh_delay)

    with :ok <- validate_non_neg_integer(:timeout, timeout),
         :ok <- validate_non_neg_integer(:refresh_delay, refresh_delay) do
      state = %__MODULE__{
        oban_name: oban_name,
        timeout: timeout,
        refresh_delay: refresh_delay,
        peer_module: Keyword.get(opts, :peer_module, @default_peer_module)
      }

      {:ok, state}
    end
  end

  @impl Crown.Oracle
  def claim(state) do
    check_leadership(state)
  end

  @impl Crown.Oracle
  def refresh(state) do
    check_leadership(state)
  end

  defp check_leadership(%__MODULE__{} = state) do
    if oban_leader?(state) do
      {true, state.refresh_delay, state}
    else
      {false, state}
    end
  end

  defp oban_leader?(%__MODULE__{peer_module: peer_module, oban_name: oban_name, timeout: timeout}) do
    if function_exported?(peer_module, :leader?, 2) do
      peer_module.leader?(oban_name, timeout)
    else
      Logger.warning("Oban oracle peer module does not export leader?/2",
        peer_module: inspect(peer_module)
      )

      false
    end
  rescue
    exception ->
      Logger.warning("Oban oracle could not query leadership",
        oban_name: inspect(oban_name),
        error: Exception.message(exception)
      )

      false
  catch
    :exit, reason ->
      Logger.warning("Oban oracle leadership check exited",
        oban_name: inspect(oban_name),
        reason: inspect(reason)
      )

      false
  end

  defp validate_non_neg_integer(_key, value) when is_integer(value) and value >= 0 do
    :ok
  end

  defp validate_non_neg_integer(key, value) do
    {:error, {:invalid_option, key, value}}
  end
end
