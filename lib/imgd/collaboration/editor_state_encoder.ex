defimpl LiveVue.Encoder, for: Imgd.Collaboration.EditorState do
  def encode(state, opts) do
    data = %{
      workflow_id: state.workflow_id,
      pinned_outputs: state.pinned_outputs,
      disabled_steps: MapSet.to_list(state.disabled_steps),
      disabled_mode: state.disabled_mode,
      step_locks: state.step_locks
    }

    LiveVue.Encoder.encode(data, opts)
  end
end
