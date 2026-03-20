defmodule Crown.TestWorker do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_opts(server) do
    GenServer.call(server, :get_opts)
  end

  @impl GenServer
  def init(opts) do
    {:ok, opts}
  end

  @impl GenServer
  def handle_call(:get_opts, _from, opts) do
    {:reply, opts, opts}
  end
end
