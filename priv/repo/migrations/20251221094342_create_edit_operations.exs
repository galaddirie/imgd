defmodule Imgd.Repo.Migrations.CreateEditOperations do
  use Ecto.Migration

  def change do
    create table(:edit_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :operation_id, :string, null: false
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :payload, :map, null: false
      add :user_id, references(:users, type: :binary_id), null: false
      add :client_seq, :integer

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:edit_operations, [:operation_id])
    create unique_index(:edit_operations, [:workflow_id, :seq])
    create index(:edit_operations, [:workflow_id, :inserted_at])
  end
end
