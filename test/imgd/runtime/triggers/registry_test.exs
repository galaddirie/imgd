defmodule Imgd.Runtime.Triggers.RegistryTest do
  use Imgd.DataCase, async: false

  alias Imgd.Runtime.Triggers.Registry
  import Imgd.Factory

  test "can register and unregister workflows" do
    workflow = insert(:workflow, status: :draft)
    workflow_id = workflow.id
    name = Module.concat(__MODULE__, TestRegistry1)
    start_supervised!({Registry, name: name})

    # Initially not active (unless it was in DB at boot)
    assert Registry.active?(workflow_id, name) == false

    Registry.register(workflow_id, [], name)
    # It's a cast, so we might need a small peek or use call if we want sync
    # But let's see if it works with a small sleep or a sync call
    Process.sleep(50)
    assert Registry.active?(workflow_id, name) == true

    Registry.unregister(workflow_id, name)
    Process.sleep(50)
    assert Registry.active?(workflow_id, name) == false
  end

  test "initialization loads active workflows" do
    # Create an active workflow
    workflow = insert(:workflow, status: :active)
    name = Module.concat(__MODULE__, TestRegistry2)
    start_supervised!({Registry, name: name})

    assert Registry.active?(workflow.id, name) == true
  end
end
