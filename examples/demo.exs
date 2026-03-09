defmodule Demo.TcpOracle do
  @behaviour Crown.Oracle
  require Logger

  @refresh_delay 5_000

  defstruct [:host, :port, :socket, :lease_id, :code]

  @impl Crown.Oracle
  def init(opts) do
    state = %__MODULE__{
      host: Keyword.get(opts, :host, ~c"127.0.0.1"),
      port: Keyword.get(opts, :port, 5544),
      lease_id: Keyword.fetch!(opts, :lease_id),
      socket: nil,
      code: nil
    }

    {:ok, connect(state)}
  end

  @impl Crown.Oracle
  def claim(state) do
    case send_command(state, "CLAIM #{state.lease_id}") do
      {:ok, "OK " <> code, state} -> {true, @refresh_delay, %{state | code: code}}
      {:ok, "NO", state} -> {false, state}
      {:error, state} -> {false, state}
    end
  end

  @impl Crown.Oracle
  def refresh(state) do
    case send_command(state, "REFRESH #{state.lease_id} #{state.code}") do
      {:ok, "OK", state} -> {true, @refresh_delay, state}
      {:ok, "NO", state} -> {false, %{state | code: nil}}
      {:error, state} -> {false, %{state | code: nil}}
    end
  end

  @impl Crown.Oracle
  def abdicate(%__MODULE__{code: nil}), do: :ok

  def abdicate(state) do
    case send_command(state, "RELEASE #{state.lease_id} #{state.code}") do
      {:ok, _, _state} -> :ok
      {:error, _state} -> :ok
    end
  end

  defp send_command(state, command) do
    state = connect(state)

    with {:ok, socket} <- fetch_socket(state),
         :ok <- :gen_tcp.send(socket, command <> "\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, String.trim(line), state}
    else
      {:error, reason} ->
        Logger.error("[tcp_oracle] #{command} failed: #{inspect(reason)}")
        {:error, disconnect(state)}
    end
  end

  defp fetch_socket(%{socket: nil}), do: {:error, :not_connected}
  defp fetch_socket(%{socket: socket}), do: {:ok, socket}

  defp connect(%{socket: nil} = state) do
    case :gen_tcp.connect(state.host, state.port, [:binary, active: false, packet: :line]) do
      {:ok, socket} ->
        %{state | socket: socket}

      {:error, reason} ->
        Logger.error("[tcp_oracle] connect failed: #{inspect(reason)}")
        state
    end
  end

  defp connect(state), do: state

  defp disconnect(state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    %{state | socket: nil}
  end
end

defmodule Demo.LeaderWorker do
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

  @impl GenServer
  def init([]) do
    Logger.info("[leader] started, will crash in 5 seconds")
    Process.send_after(self(), :tick, 1_000)

    remaining =
      try do

      c = File.read!("/tmp/remaining")
       String.to_integer(c)
      rescue
        e ->Logger.error("could not read crash countdown value: #{inspect Exception.message e}")
        20
      end

    {:ok, _remaining = remaining}
  end

  @impl GenServer
  def handle_info(:tick, 1) do
    Logger.error("[leader] crashing now")
    exit(:boom)
  end

  def handle_info(:tick, remaining) do
    Logger.warning("[leader] crashing in #{remaining - 1}")

    Process.send_after(self(), :tick, 500)
    {:noreply, remaining - 1}
  end
end

defmodule Demo.IdleWorker do
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

  @impl GenServer
  def init([]) do
    Logger.info("[follower] started, waiting for leadership")
    Process.send_after(self(), :log, 2_000)
    {:ok, []}
  end

  @impl GenServer
  def handle_info(:log, state) do
    Logger.info("[follower] hello, I'm idle")
    Process.send_after(self(), :log, 2_000)
    {:noreply, state}
  end
end

defmodule Demo.NodeConnector do
  require Logger

  def run do
    ["demo-" <> n, host] = String.split(Atom.to_string(node()), "@")
    peer_n = String.to_integer(n) - 1

    peer_n =
      case peer_n do
        0 -> 2
        n -> n
      end

    sibling = :"demo-#{peer_n}@#{host}"
    connect_loop(sibling)
  end

  defp connect_loop(peer) do
    case Node.connect(peer) do
      false ->
        Logger.error("node #{node()} could not connect to #{peer}")
        Process.sleep(1000)
        connect_loop(peer)

      true ->
        :ok
    end
  end
end

Crown.attach_default_logger()

children = [
  {Crown,
   name: :demo,
   claim_delay: 1000,
   monitor_timeout: 10000,
   monitor_delay: 1000,
   oracle: {Demo.TcpOracle, lease_id: "demo"},
   child_spec: Demo.LeaderWorker,
   follower_child_spec: Demo.IdleWorker},
  {Task, &Demo.NodeConnector.run/0}
]

{:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_all)

Process.sleep(:infinity)
