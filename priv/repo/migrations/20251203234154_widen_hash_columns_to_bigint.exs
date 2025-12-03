defmodule Imgd.Repo.Migrations.WidenHashColumnsToBigint do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      modify :definition_hash, :bigint, from: :integer
    end

    alter table(:workflow_versions) do
      modify :definition_hash, :bigint, from: :integer
    end

    alter table(:execution_checkpoints) do
      modify :completed_step_hashes, {:array, :bigint},
        from: {:array, :integer},
        using: "completed_step_hashes::bigint[]"
    end

    alter table(:execution_steps) do
      modify :step_hash, :bigint,
        null: false,
        from: :integer,
        using: "step_hash::bigint"

      modify :input_fact_hash, :bigint,
        from: :integer,
        using: "input_fact_hash::bigint"

      modify :output_fact_hash, :bigint,
        from: :integer,
        using: "output_fact_hash::bigint"

      modify :parent_step_hash, :bigint,
        from: :integer,
        using: "parent_step_hash::bigint"
    end
  end
end
