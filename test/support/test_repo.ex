defmodule Crown.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :crown, adapter: Ecto.Adapters.Postgres
end
