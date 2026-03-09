defmodule LeaseServer do
  use GenServer

  @lease_duration_ms 10_000

  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def command(cmd) do
    GenServer.call(__MODULE__, {:command, cmd})
  end

  @impl GenServer
  def init(_), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:command, "CLAIM " <> id}, _from, leases) do
    now = System.system_time(:millisecond)

    case Map.get(leases, id) do
      {_code, expiry} when now < expiry ->
        IO.puts("[lease] CLAIM #{id} -> NO (held)")
        {:reply, "NO", leases}

      _ ->
        code = Base.encode16(:crypto.strong_rand_bytes(4))
        expiry = now + @lease_duration_ms
        IO.puts("[lease] CLAIM #{id} -> OK #{code}")
        {:reply, "OK #{code}", Map.put(leases, id, {code, expiry})}
    end
  end

  def handle_call({:command, "REFRESH " <> rest}, _from, leases) do
    [id, code] = String.split(rest, " ", parts: 2)
    now = System.system_time(:millisecond)

    case Map.get(leases, id) do
      {^code, _expiry} ->
        IO.puts("[lease] REFRESH #{id} -> OK")
        {:reply, "OK", Map.put(leases, id, {code, now + @lease_duration_ms})}

      {_other_code, _expiry} ->
        IO.puts("[lease] REFRESH #{id} -> NO (invalid code)")
        {:reply, "NO", leases}

      nil ->
        IO.puts("[lease] REFRESH #{id} -> NO (unknown lease)")
        {:reply, "NO", leases}
    end
  end

  def handle_call({:command, "RELEASE " <> rest}, _from, leases) do
    [id, code] = String.split(rest, " ", parts: 2)

    case Map.get(leases, id) do
      {^code, _} ->
        IO.puts("[lease] RELEASE #{id} -> OK (removed)")
        {:reply, "OK", Map.delete(leases, id)}

      _ ->
        IO.puts("[lease] RELEASE #{id} -> OK (no-op)")
        {:reply, "OK", leases}
    end
  end

  def handle_call({:command, other}, _from, leases) do
    IO.puts("[lease] unknown command: #{inspect(other)}")
    {:reply, "ERR", leases}
  end
end

defmodule LeaseServer.Acceptor do
  def start(port) do
    {:ok, listen} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, packet: :line])

    IO.puts("[lease] listening on port #{port}")
    accept_loop(listen)
  end

  defp accept_loop(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    spawn(fn -> serve(socket) end)
    accept_loop(listen)
  end

  defp serve(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        response = LeaseServer.command(String.trim(data))
        :gen_tcp.send(socket, response <> "\n")
        serve(socket)

      {:error, :closed} ->
        :ok
    end
  end
end

{:ok, _} = LeaseServer.start_link()
LeaseServer.Acceptor.start(5544)
