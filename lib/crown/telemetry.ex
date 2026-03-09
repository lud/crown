defmodule Crown.Telemetry do
  @moduledoc """
  Telemetry events emitted by Crown.

  All events follow a three-level hierarchy: `[:crown, subsystem, outcome]`.

  ## Subsystems

    * `:process` — Crown GenServer lifecycle
    * `:leadership` — Oracle claim/refresh outcomes
    * `:monitor` — Leader discovery and monitoring
    * `:child` — Child supervisor lifecycle

  ## Events

      [:crown, :process,    :initialized]   # GenServer init complete
      [:crown, :process,    :terminated]    # GenServer terminate/2 called

      [:crown, :leadership, :claimed]       # Oracle.claim returned {true, ...}
      [:crown, :leadership, :rejected]      # Oracle.claim returned {false, ...}
      [:crown, :leadership, :refreshed]     # Oracle.refresh returned {true, ...}
      [:crown, :leadership, :lost]          # Oracle.refresh returned {false, ...}

      [:crown, :monitor,    :started]       # :global found leader, monitor established
      [:crown, :monitor,    :failed]        # :global returned :undefined (retry scheduled)
      [:crown, :monitor,    :timeout]       # monitor_timeout elapsed, reclaiming
      [:crown, :monitor,    :leader_down]   # :LEADER_DOWN received

      [:crown, :child,      :started]       # child supervisor started
      [:crown, :child,      :stopped]       # child supervisor stopped cleanly
      [:crown, :child,      :exited]        # child supervisor crashed (EXIT received)

  ## Standard Metadata

  Every event includes:

    * `:name` — Crown process name
    * `:pid` — Crown process pid
    * `:phase` — current FSM phase
    * `:ocl_mod` — oracle module
    * `:monitored_node` — the node being monitored or `nil`

  See the plan documentation for per-event extra fields.
  """

  @events [
    [:crown, :process, :initialized],
    [:crown, :process, :terminated],
    [:crown, :leadership, :claimed],
    [:crown, :leadership, :rejected],
    [:crown, :leadership, :refreshed],
    [:crown, :leadership, :lost],
    [:crown, :monitor, :started],
    [:crown, :monitor, :failed],
    [:crown, :monitor, :timeout],
    [:crown, :monitor, :leader_down],
    [:crown, :child, :started],
    [:crown, :child, :stopped],
    [:crown, :child, :exited]
  ]

  @doc "Returns the list of all 13 Crown telemetry event names."
  def events, do: @events
end
