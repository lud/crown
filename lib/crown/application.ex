defmodule Crown.Application do
  # The application is used for tests
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = children(Application.get_env(:crown, :env, :prod))
    opts = [strategy: :one_for_one, name: Crown.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if Mix.env() == :test do
    defp children(:test) do
      [
        Crown.TestRepo
      ]
    end
  end

  defp children(_) do
    []
  end
end
