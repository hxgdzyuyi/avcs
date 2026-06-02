defmodule Avcs.Repo do
  use Ecto.Repo,
    otp_app: :avcs,
    adapter: Ecto.Adapters.SQLite3
end
