# quokka:skip-module-directive-reordering

defmodule Crown.TelemetryLogger do
  events = %{
    # Process lifecycle
    [:crown, :process, :initialized] => :info,
    [:crown, :process, :terminating] => :info,

    # Leadership
    [:crown, :leadership, :claimed] => :info,
    [:crown, :leadership, :rejected] => :info,
    [:crown, :leadership, :refreshed] => :debug,
    [:crown, :leadership, :lost] => :warning,
    [:crown, :leadership, :conflict] => :warning,

    # Monitor
    [:crown, :monitor, :started] => :debug,
    [:crown, :monitor, :failed] => :warning,
    [:crown, :monitor, :timeout] => :warning,
    [:crown, :monitor, :leader_down] => :warning,

    # Child
    [:crown, :child, :started] => :debug,
    [:crown, :child, :stopped] => :debug,
    [:crown, :child, :exited] => :error
  }

  @moduledoc """
  A `:telemetry` event listener that produces logs for events emitted by Crown.

  ## Usage

      Crown.attach_default_logger()
      Crown.attach_default_logger(min_log_level: :warning)
      Crown.attach_default_logger(prefixes: [[:crown, :leadership]])

  ## Events

  #{events |> Enum.sort() |> Enum.map(fn {evt, log_level} -> """
    * `#{inspect(evt)}` with a log level of `#{inspect(log_level)}`
    """ end)}
  """

  require Logger

  @events events

  defp events do
    @events
  end

  def attach(filters \\ []) do
    :telemetry.attach_many(
      __MODULE__,
      filter_events(events(), filters),
      &__MODULE__.handle_event/4,
      []
    )
  end

  defp filter_events(events_map, []) do
    Map.keys(events_map)
  end

  defp filter_events(events_map, filters) do
    events_map =
      case filters[:min_log_level] do
        nil ->
          events_map

        min_level ->
          Map.filter(events_map, fn {_, level} ->
            :logger.compare_levels(level, min_level) in [:gt, :eq]
          end)
      end

    events_map =
      case filters[:prefixes] do
        prefixes when is_list(prefixes) ->
          Map.filter(events_map, fn {k, _} -> Enum.any?(prefixes, &List.starts_with?(k, &1)) end)

        nil ->
          events_map
      end

    Map.keys(events_map)
  end

  @doc false

  # -- Process -----------------------------------------------------------------

  def handle_event([:crown, :process, :initialized] = p, _, %{name: name, claim_delay: delay}, _) do
    if delay > 0 do
      log(p, "[crown] #{name} initialized, first claim in #{delay}ms", %{crown_name: name})
    else
      log(p, "[crown] #{name} initialized", %{crown_name: name})
    end
  end

  def handle_event([:crown, :process, :terminating] = p, _, %{name: name, reason: reason}, _) do
    log(p, "[crown] #{name} terminating (#{inspect(reason)})", %{crown_name: name})
  end

  # -- Leadership --------------------------------------------------------------

  def handle_event([:crown, :leadership, :claimed] = p, _, %{name: name, refresh_delay: delay}, _) do
    log(p, "[crown] #{name} elected as leader on node #{node()}", %{
      crown_name: name,
      refresh_delay: delay
    })
  end

  def handle_event([:crown, :leadership, :rejected] = p, _, %{name: name}, _) do
    log(p, "[crown] #{name} claim rejected, following", %{crown_name: name})
  end

  def handle_event(
        [:crown, :leadership, :refreshed] = p,
        _,
        %{name: name, refresh_delay: delay},
        _
      ) do
    log(p, "[crown] #{name} leadership refreshed, next refresh in #{inspect(delay)}ms", %{
      crown_name: name,
      refresh_delay: delay
    })
  end

  def handle_event([:crown, :leadership, :lost] = p, _, %{name: name}, _) do
    log(p, "[crown] #{name} lost leadership, transitioning to follower", %{crown_name: name})
  end

  def handle_event([:crown, :leadership, :conflict] = p, _, %{name: name}, _) do
    log(p, "[crown] #{name} lost global name conflict, shutting down", %{crown_name: name})
  end

  # -- Monitor -----------------------------------------------------------------

  def handle_event(
        [:crown, :monitor, :started] = p,
        _,
        %{name: name, leader_pid: leader_pid, leader_node: leader_node},
        _
      ) do
    log(p, "[crown] #{name} monitoring leader #{inspect(leader_pid)} on node #{leader_node}", %{
      crown_name: name,
      leader_node: leader_node
    })
  end

  def handle_event(
        [:crown, :monitor, :failed] = p,
        _,
        %{name: name, retry_count: retry_count, remaining_ms: remaining_ms},
        _
      ) do
    log(
      p,
      "[crown] #{name} could not find leader (attempt #{retry_count}, re-claim in #{remaining_ms}ms)",
      %{crown_name: name, retry_count: retry_count}
    )
  end

  def handle_event([:crown, :monitor, :timeout] = p, _, %{name: name, elapsed_ms: elapsed_ms}, _) do
    log(p, "[crown] #{name} monitor timed out after #{elapsed_ms}ms, reclaiming", %{
      crown_name: name
    })
  end

  def handle_event(
        [:crown, :monitor, :leader_down] = p,
        _,
        %{name: name, leader_node: leader_node},
        _
      ) do
    log(p, "[crown] #{name} leader on node #{inspect(leader_node)} went down, claiming", %{
      crown_name: name,
      leader_node: leader_node
    })
  end

  # -- Child -------------------------------------------------------------------

  def handle_event(
        [:crown, :child, :started] = p,
        _,
        %{name: name, kind: kind, child_pid: child_pid},
        _
      ) do
    log(p, "[crown] #{name} started #{kind} child #{inspect(child_pid)}", %{
      crown_name: name,
      kind: kind
    })
  end

  def handle_event([:crown, :child, :stopped] = p, _, %{name: name, kind: kind}, _) do
    log(p, "[crown] #{name} stopped #{kind} child", %{crown_name: name, kind: kind})
  end

  def handle_event([:crown, :child, :exited] = p, _, %{name: name, kind: kind, reason: reason}, _) do
    log(p, "[crown] #{name} #{kind} child crashed: #{inspect(reason)}", %{
      crown_name: name,
      kind: kind,
      reason: reason
    })
  end

  # -- Catchall ----------------------------------------------------------------

  if Mix.env() == :test do
    def handle_event(other, _, meta, _) do
      keymap = ["%{", Enum.map_intersperse(meta, ", ", fn {k, _} -> "#{k}: #{k}" end), "}"]

      Logger.error("""
      unhandled telemetry event #{inspect(other)} with #{inspect(meta)}

      Add the following code
      in #{__ENV__.file}:#{__ENV__.line - 11}

          def handle_event(#{inspect(other)} = p, _, #{keymap},_) do
            log(p, "...")
          end

      """)

      Logger.flush()
      System.halt(1)
    end
  else
    def handle_event(_other, _, _meta, _) do
      :ok
    end
  end

  defp log(prefix, message, metadata) do
    level = Map.fetch!(events(), prefix)
    Logger.log(level, message, metadata)
  end
end
