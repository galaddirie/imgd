# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Imgd.Repo
alias Imgd.Accounts
alias Imgd.Accounts.User
alias Imgd.Accounts.Scope
alias Imgd.Workflows

IO.puts("🌱 Seeding database...")

# Create a test user if one doesn't exist
user =
  case Repo.get_by(User, email: "temp@imgd.io") do
    nil ->
      IO.puts("Creating user temp@imgd.io...")

      {:ok, user} =
        Accounts.register_user(%{
          email: "temp@imgd.io",
          password: "password123456"
        })

      user

    user ->
      IO.puts("Using existing user temp@imgd.io...")
      user
  end

IO.puts("\n🔐 Login Credentials:")
IO.puts("  Email: temp@imgd.io")
IO.puts("  Password: password123456")
IO.puts("")
