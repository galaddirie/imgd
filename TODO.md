# TODO

### Core / Platform
- [ ] build workflow node groups ( basically a sub workflow that can be used as a node in a larger workflow) but without registering it as a workflow in the database. the execution context will be local and nodes in the workflow outside the group will not be able to access the context of the group. except for the final output of the group which will be available to the parent workflow.
- [ ] Credentials system
- [x] API keys management
- [ ] Sub-workflows
- [x] Add request metadata to expression context ( user id, request id, headers, body, etc)
- [ ] Add variable feature like n8n, add a flag to keep variables local to the execution or global (cross execution and workflow)
    - [ ] Add variable trigger nodes (ex. variable changed)
### Editor UX
- [ ] Add **Save** button
- [ ] Add **Publish** button
- [ ] Unsaved changes indicator + autosave
- [ ] Undo/redo (unsaved changes remain in session local storage)
- [x] Add error highlighting to Expression UI
- [x] Fix edit operations (remove client-side UUID)


- [ ] State machine support for **cross-execution memory** (e.g., saga pattern with persisted state, game server)

- [ ] Execution registry (for visbility in what executions are running on what node for observability and lifecycle management - future durability features)

### Data-flow rules
- [ ] fix:Only allow expressions to access **direct upstream node** data

### Interoperability
- [ ] n8n import feature



### Node executor versioning
- [ ] Versioned namespaces (e.g., `Nodes.V1.HttpRequest`)
- [ ] “Latest” label for auto-discovery
- [ ] Enforce single “latest” per node name (V1 + V2 conflicts fail tests or compile)

### Complex Triggers 
need to figure out how to model this, is each event a workflow execution or only one execution for the entire stream, if so how do we model workflows? special workflow event "trigger" nodes, basically after the initial websocket connection open event, the workflow keeps proccessing events using the event declared nodes as the new trigger? maybe not, there should be an elegent solution to this
- [ ] WebSocket trigger:
  - [ ] On connection open → start workflow
  - [ ] Nodes to process websocket events (game server style)
  - [ ] Decide: per-event execution vs single long-lived execution
  - [ ] Model trigger semantics (avoid awkward “event trigger nodes” if possible)
- [ ] Stream trigger (similar modeling concerns)
- [ ] Option to disable overhead (telemetry/metrics/logging) for high-frequency/long-lived workflows

### Performance / Optimization
- [ ] Compile expression evaluations to avoid runtime template evaluation (basically building routes from output to target ports)
  - [ ] Store compiled templates in **workflow versions** (DB)
  - [ ] Drafts compile on every run
  - [ ] Target: save ~3–4ms per expression evaluation

### Observability + Sandbox
- [ ] Integrate WASM sandbox with OTEL metrics + telemetry

### Examples / Demos
- [ ] FLAME example: input video → return thumbnails
  - [ ] Output is a **streaming endpoint**
  - [ ] Realtime UI demo (SDK is fine for now)
- [ ] Multi-node example (self-hosted): file from PC → send to laptop to run code
- [ ] Game server workflow example

### Sytsem Nodes?
How would this work in a zero trust environment?
- [ ] Docker node
- [ ] Kubernetes node

### Future
- [ ] Kino-like UI builder (notion inspired?)
- [ ] Datasets
- [ ] Evaluations
- [ ] AI chat workflow builder
- [ ] Lightweight deployments + easy installs (run full system on a Raspberry Pi)


BUGS
- [x] When initially loading a edit session with previous preview execution data present, we arent able to update the expression preview unless we reun a new execution. the  step config modal shows Resolved Result instead of Live Preview


- [ ] investigate how n8n secures its webhook endpoints


- step names from node library should not be uuids - they should be step name + <index if multiple of same type>

- data not being passed between steps correctly ( ex expressions )

webhook test system

- determine risk of api key exposure in webhook trigger outputs