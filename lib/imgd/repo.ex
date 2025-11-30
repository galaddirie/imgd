defmodule Imgd.Repo do
  use Ecto.Repo,
    otp_app: :imgd,
    adapter: Ecto.Adapters.Postgres
end
