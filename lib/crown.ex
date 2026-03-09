defmodule Crown do
  use GenServer
  require Logger
  @gen_opts ~w(name timeout debug spawn_opt hibernate_after)a
  @options_schema NimbleOptions.new!(
                    name: [
                      type: :atom,
                      required: true,
                      doc: """
                      Atom used to register the process locally and, when leading, as
                      `{:global, {Crown, name}}` for cross-node discoverability.
                      """
                    ],
                    oracle: [
                      type: :mod_arg,
                      required: true,
                      doc: """
                      A `{module, opts}` tuple. `module` must implement `Crown.Oracle`.
                      `opts` are passed to `c:Crown.Oracle.init/1`.
                      """
                    ],
                    child_spec: [
                      type: :any,
                      required: true,
                      doc: """
                      Child spec to start when this node holds the crown. May be `nil`
                      if no child is needed (though Crown's main purpose is to supervise
                      a child). Accepts any value accepted by `Supervisor.child_spec/2`.
                      """
                    ],
                    follower_child_spec: [
                      type: :any,
                      default: nil,
                      doc: """
                      Child spec to start when this node does *not* hold the crown.
                      Defaults to `nil` (no follower child).
                      """
                    ],
                    claim_delay: [
                      type: :non_neg_integer,
                      default: 0,
                      doc: """
                      Milliseconds to wait after startup before the first claim attempt.
                      """
                    ],
                    monitor_delay: [
                      type: :non_neg_integer,
                      default: 5000,
                      doc: """
                      Milliseconds to wait between attempts to find and monitor the
                      current leader after a failed claim. The first attempt always
                      happens immediately (delay 0); subsequent retries use this value.
                      Useful in environments where the cluster takes time to form.
                      Defaults to 5000.
                      """
                    ],
                    monitor_timeout: [
                      type: :pos_integer,
                      default: 30_000,
                      doc: """
                      Maximum time in milliseconds to spend trying to find the leader
                      before giving up and attempting to claim again. Defaults to 30000.

                      This timeout is checked each time a `monitor_delay` tick fires,
                      so the actual elapsed time before a re-claim may exceed
                      `monitor_timeout` by up to one `monitor_delay` interval.
                      """
                    ],
                    monitor_leader: [
                      type: :boolean,
                      default: true,
                      doc: """
                      When `true`, nodes that fail to claim will monitor the current
                      leader and attempt to claim when it goes down. Set to `false` in
                      deployments where nodes cannot see each other and rely instead on
                      oracle `handle_info` callbacks to trigger claim attempts.
                      """
                    ]
                  )

  @moduledoc """
  Leader election and supervised child management backed by an external oracle.

  Crown is a `GenServer` that coordinates leader election across an Erlang
  cluster. Leadership authority is delegated to a pluggable oracle (see
  `Crown.Oracle`) — typically a database lease or distributed lock — so that
  only one node holds the crown at a time even during netsplits.

  The elected leader starts a supervised child (the `:child_spec` option) and
  keeps it running for as long as leadership is held. When leadership is lost
  the child is stopped and, optionally, a `:follower_child_spec` is started
  instead. Followers monitor the leader and attempt to claim when it goes down.

  Crown registers the leader globally as `{Crown, name}` so followers on other
  nodes can discover and monitor it.

  ## Usage

      children = [
        {Crown,
         name: :my_worker,
         oracle: {MyApp.RedisOracle, lock_key: "my_worker"},
         child_spec: MyApp.SingletonWorker}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

  #{NimbleOptions.docs(@options_schema)}

  ## Telemetry

  Crown emits telemetry events under the `[:crown, ...]` prefix. Use
  `attach_default_logger/1` for built-in logging or attach your own handlers.
  See `Crown.Telemetry` for the full list of events.
  """

  def child_spec(opts) do
    # Name is mandatory but we will the that be validated by the init callback.
    # Here this is just to ease multiple crown processes in a list of child
    # specs.
    name = Keyword.get(opts, :name, __MODULE__)
    %{id: name, start: {Crown, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(opts) do
    {gen_opts, opts} = start_opts(opts)
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def start(opts) do
    {gen_opts, opts} = start_opts(opts)
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  defp start_opts(opts) do
    name = Keyword.fetch!(opts, :name)
    {gen_opts, opts} = Keyword.split(opts, @gen_opts)
    {gen_opts, Keyword.put(opts, :name, name)}
  end

  def stop(server) do
    GenServer.stop(server)
  end

  def leader?(server) do
    GenServer.call(server, :leader?)
  end

  def attach_default_logger(filters \\ []) do
    Crown.TelemetryLogger.attach(filters)
  end

  def global_name(name) when is_atom(name), do: {__MODULE__, name}

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :name,
      :phase,
      :leader_mref,
      :child_spec,
      :follower_child_spec,
      :ocl_mod,
      :ocl_state,
      :sup,
      :monitor_leader?,
      :monitor_timeout,
      :monitor_delay,
      :tref,
      :monitored_node
    ]
    defstruct @enforce_keys
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    opts = NimbleOptions.validate!(opts, @options_schema)
    {ocl_mod, ocl_opts} = Keyword.fetch!(opts, :oracle)

    case ocl_mod.init(ocl_opts) do
      {:ok, ocl_state} ->
        name = Keyword.fetch!(opts, :name)

        state = %State{
          ocl_state: ocl_state,
          phase: :init,
          name: name,
          child_spec: Keyword.fetch!(opts, :child_spec),
          follower_child_spec: Keyword.fetch!(opts, :follower_child_spec),
          leader_mref: nil,
          ocl_mod: ocl_mod,
          sup: :none,
          monitor_leader?: Keyword.fetch!(opts, :monitor_leader),
          monitor_timeout: Keyword.fetch!(opts, :monitor_timeout),
          monitor_delay: Keyword.fetch!(opts, :monitor_delay),
          tref: nil,
          monitored_node: nil
        }

        claim_delay = Keyword.fetch!(opts, :claim_delay)
        state = set_timer(state, claim_delay, :after_init)

        telemetry_exec([:crown, :process, :initialized], state, %{
          claim_delay: claim_delay
        })

        {:ok, state}

      {:error, reason} ->
        {:error, reason}

      :ignore ->
        :ignore
    end
  end

  @impl GenServer
  def handle_call(:leader?, _, state) do
    reply = state.phase == :leading
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:timeout, tref, event}, %State{tref: tref} = state) do
    {:ok, state} = handle_event(event, consume_timer(state, tref))
    {:noreply, state}
  end

  def handle_info({:LEADER_DOWN, ref, :process, _, _}, %State{leader_mref: ref} = state) do
    {:ok, state} = handle_event(:LEADER_DOWN, state)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %State{sup: {pid, kind}} = state) do
    Logger.error("Child crashed: #{inspect(kind)}")
    telemetry_exec([:crown, :child, :exited], state, %{kind: kind, reason: reason})
    {:stop, _reason, _state} = handle_event({:SUP_EXIT, reason}, state)
  end

  def handle_info(message, state) do
    Logger.error(
      "unexpected info in Crown #{inspect(state.name)} / #{inspect(state.phase)}: #{inspect(message)}"
    )

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    telemetry_exec([:crown, :process, :terminated], state, %{reason: reason})
    handle_event(:terminating, state)
  end

  defp handle_event(:after_init, %State{phase: :init, tref: nil} = state) do
    state = claim_and_start_child(state)
    true = state.phase in [:leading, :following]
    {:ok, state}
  end

  defp handle_event(:refresh_claim, %State{phase: :leading, tref: nil} = state) do
    state = refresh_and_start_child(state)
    true = state.phase in [:leading, :following]
    {:ok, state}
  end

  defp handle_event(
         {:retry_monitor, reclaim_after_abs, retry_count},
         %State{phase: :following, tref: nil} = state
       ) do
    state = retry_monitoring(state, reclaim_after_abs, retry_count)
    true = state.phase in [:leading, :following]
    {:ok, state}
  end

  defp handle_event(:LEADER_DOWN, %State{phase: :following} = state) do
    leader_node = state.monitored_node
    state = %State{state | monitored_node: nil}
    telemetry_exec([:crown, :monitor, :leader_down], state, %{leader_node: leader_node})
    state = clear_leader_mref(state)
    state = claim_and_start_child(state)
    true = state.phase in [:leading, :following]
    {:ok, state}
  end

  defp handle_event({:SUP_EXIT, reason}, %State{phase: phase} = state)
       when phase in [:leading, :following] do
    state = %State{state | sup: :none}
    state = clean_shutdown(state)
    true = state.phase == :finishing

    # If we exit from there, the terminate/2 callback will be called with the
    # old state with the sup process, and tearing it down will lead to a noproc
    # error.
    #
    # We must return a state from there.

    {:stop, reason, state}
  end

  defp handle_event(:terminating, %State{} = state) do
    state = clean_shutdown(state)
    true = state.phase == :finishing
    :ok
  end

  defp claim_and_start_child(state) do
    case claim(state) do
      {true, delay, state} ->
        :ok = global_register(state, :claim)
        state = put_phase(state, :leading)
        state = %State{state | monitored_node: node()}
        telemetry_exec([:crown, :leadership, :claimed], state, %{refresh_delay: delay})
        state = set_timer(state, delay, :refresh_claim)
        ensure_child_started(state, :leader)

      {false, state} ->
        state = put_phase(state, :following)
        telemetry_exec([:crown, :leadership, :rejected], state)
        state = ensure_child_started(state, :follower)
        start_monitoring(state)
    end
  end

  defp refresh_and_start_child(state) do
    case refresh(state) do
      {true, delay, state} ->
        state = put_phase(state, :leading)
        telemetry_exec([:crown, :leadership, :refreshed], state, %{refresh_delay: delay})
        state = set_timer(state, delay, :refresh_claim)
        ensure_child_started(state, :leader)

      {false, state} ->
        :ok = global_unregister_self(state)
        state = put_phase(state, :following)
        state = %State{state | monitored_node: nil}
        telemetry_exec([:crown, :leadership, :lost], state)
        state = ensure_child_started(state, :follower)
        start_monitoring(state)
    end
  end

  defp start_monitoring(%State{} = state) do
    case monitor_leader(state) do
      {:monitoring, state} ->
        state

      :noproc ->
        state = %State{state | monitored_node: nil}

        telemetry_exec([:crown, :monitor, :failed], state, %{
          retry_count: 0,
          elapsed_ms: 0
        })

        reclaim_after_abs = now_ms() + state.monitor_timeout
        set_timer(state, state.monitor_delay, {:retry_monitor, reclaim_after_abs, 0})
    end
  end

  defp retry_monitoring(%State{} = state, reclaim_after_abs, retry_count) do
    case monitor_leader(state) do
      {:monitoring, state} ->
        state

      :noproc ->
        state = %State{state | monitored_node: nil}
        elapsed_ms = state.monitor_timeout - max(reclaim_after_abs - now_ms(), 0)

        if now_ms() >= reclaim_after_abs do
          telemetry_exec([:crown, :monitor, :timeout], state, %{elapsed_ms: elapsed_ms})
          claim_and_start_child(state)
        else
          telemetry_exec([:crown, :monitor, :failed], state, %{
            retry_count: retry_count + 1,
            elapsed_ms: elapsed_ms
          })

          set_timer(
            state,
            state.monitor_delay,
            {:retry_monitor, reclaim_after_abs, retry_count + 1}
          )
        end
    end
  end

  defp monitor_leader(%State{} = state) do
    %{name: name} = state

    case state.monitor_leader? do
      false ->
        {:monitoring, %State{state | leader_mref: :disabled}}

      _ ->
        case :global.whereis_name(global_name(name)) do
          pid when is_pid(pid) ->
            leader_mref = :erlang.monitor(:process, pid, tag: :LEADER_DOWN)
            leader_node = node(pid)
            state = %State{state | leader_mref: leader_mref, monitored_node: leader_node}

            telemetry_exec([:crown, :monitor, :started], state, %{
              leader_pid: pid,
              leader_node: leader_node
            })

            {:monitoring, state}

          :undefined ->
            :noproc
        end
    end
  end

  defp clear_leader_mref(%State{} = state) do
    true = is_reference(state.leader_mref)
    %State{state | leader_mref: nil}
  end

  defp claim(%State{} = state) do
    %{ocl_mod: ocl_mod, ocl_state: ocl_state} = state
    handle_claim_result(state, ocl_mod.claim(ocl_state))
  end

  defp refresh(%State{} = state) do
    %{ocl_mod: ocl_mod, ocl_state: ocl_state} = state
    handle_claim_result(state, ocl_mod.refresh(ocl_state))
  end

  defp abdicate(%State{} = state) do
    %{ocl_mod: ocl_mod, ocl_state: ocl_state} = state
    Code.ensure_loaded!(state.ocl_mod)

    if function_exported?(ocl_mod, :abdicate, 1) do
      :ok = ocl_mod.abdicate(ocl_state)
    else
      :ok
    end
  end

  defp handle_claim_result(%State{} = state, result) do
    case result do
      {true, refresh_delay, ocl_state} ->
        {true, refresh_delay, %State{state | ocl_state: ocl_state}}

      {false, ocl_state} ->
        {false, %State{state | ocl_state: ocl_state}}
    end
  end

  defp ensure_child_started(%State{sup: {_, kind}} = state, kind) do
    # Already started
    Logger.debug("keeping child in #{inspect(kind)} alive")
    state
  end

  defp ensure_child_started(%State{sup: :none} = state, kind) do
    opt =
      case kind do
        :leader -> :child_spec
        :follower -> :follower_child_spec
      end

    sup =
      case Map.fetch!(state, opt) do
        nil ->
          # If there is no child spec then we keep the supervisor state as-is
          :none

        child_spec ->
          sup_children = [Supervisor.child_spec(child_spec, restart: :permanent)]

          {:ok, sup} =
            Supervisor.start_link(sup_children, strategy: :one_for_one, max_restarts: 0)

          telemetry_exec([:crown, :child, :started], state, %{kind: kind, child_pid: sup})

          {sup, kind}
      end

    %State{state | sup: sup}
  end

  defp ensure_child_started(%State{sup: {_, other_kind}} = state, kind) do
    Logger.info("stopping child for #{inspect(other_kind)}")
    state = teardown_child(state)
    ensure_child_started(state, kind)
  end

  defp teardown_child(%State{sup: {sup, kind}} = state) do
    telemetry_exec([:crown, :child, :stopped], state, %{kind: kind})
    :ok = Supervisor.stop(sup)
    :ok = flush_exit(sup)
    %State{state | sup: :none}
  end

  defp maybe_teardown_child(%State{sup: :none} = state) do
    state
  end

  defp maybe_teardown_child(state) do
    teardown_child(state)
  end

  defp flush_exit(pid) do
    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp global_register(%State{} = state, :claim = callback) do
    case :global.register_name(global_name(state.name), self(), &:global.random_notify_name/3) do
      :yes ->
        :ok

      :no ->
        %{ocl_mod: ocl_mod, ocl_state: ocl_state} = state
        gname = global_name(state.name)

        Logger.error(
          "could not register with :global.register_name(#{inspect(gname)}, #{inspect(self())}, ...) despite oracle #{inspect(ocl_mod)}.#{callback}(#{inspect(ocl_state)}) returning {true, ...}"
        )

        exit(:invalid_claim)
    end
  end

  defp global_unregister_self(%State{} = state) do
    this = self()
    gname = global_name(state.name)
    ^this = :global.whereis_name(gname)
    :ok = :global.unregister_name(gname)
  end

  defp clean_shutdown(state) do
    state =
      case state.phase do
        :leading ->
          :ok = global_unregister_self(state)
          # child must be tear down before releasing locks/leases, otherwise
          # duplicate leader child can exist
          state = maybe_teardown_child(state)
          :ok = abdicate(state)
          state

        :following ->
          state = maybe_teardown_child(state)
          state

        # This phase is set by this function for re-entry from terminate after
        # handling a child failure. So we can always predict what should be done
        :finishing ->
          :none = state.sup
          state
      end

    put_phase(state, :finishing)
  end

  defp set_timer(%State{} = state, delay, message) do
    nil = state.tref
    %State{state | tref: start_timer(delay, message)}
  end

  defp start_timer(:infinity, _msg) do
    make_ref()
  end

  defp start_timer(delay, msg) do
    :erlang.start_timer(delay, self(), msg)
  end

  defp consume_timer(%State{tref: tref} = state, tref) do
    %State{state | tref: nil}
  end

  defp put_phase(%State{} = state, phase) do
    %State{state | phase: phase}
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp telemetry_exec(event, state, extra \\ %{}) do
    :telemetry.execute(event, %{}, Map.merge(telemetry_metadata(state), extra))
  end

  defp telemetry_metadata(state) do
    %{
      name: state.name,
      pid: self(),
      phase: state.phase,
      ocl_mod: state.ocl_mod,
      monitored_node: state.monitored_node
    }
  end
end
