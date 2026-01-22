# TODO

### Core / Platform
- [ ] Credentials system
- [ ] Sub-workflows ( webhook triggers, add streaming outputs, and events users can subscribe to for workflow outputs etc before we do this, why? so that the step can subscribe to the execution without polling)
- [ ] Add variable feature like n8n, add a flag to keep variables local to the execution or global (cross execution and workflow)
    - [ ] Add variable trigger nodes (ex. variable changed)
- [ ] State machine support for **cross-execution memory** (e.g., saga pattern with persisted state, game server)
- [ ] Execution registry (for visbility in what executions are running on what node for observability and lifecycle management - future durability features)
- [ ] Add debug execution mode 


### Editor UX
- [ ] Add **Publish** button
- [ ] lets be efficent with edit stack, if a user moves a node 5 times, do we need to add 5 entries to the edit stack? no. if they move groups and nodes multiple times, ( not just 1 change but multiple changes that are relitively small and heavily related to each other) do we need to add multiple entries to the edit stack? no. we should be efficient with edit stack and only add entries when there are significant changes that are not related to each other, when they are far apart,  and or unique changes that are not related to each other. 
maybe after edit stack is full we normalize / merge edits? 




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




- [ ] investigate how n8n secures its webhook endpoints









add merge node - unlike n8n we arent limited to two paths merging and cleaner merge ui and options 

merge node will also act as a edit fields node 


- determine risk of api key exposure in webhook trigger outputs


- if we edit connections we should update the context menu to show the new current input data as long as that upstream has changed


- fix assets/vue stores and store dirs, merge into a single store dir 


- review what we store in proccess dictionaries and if we need to clean them up


Suport logs /traces for some nodes (ex. ai exeuction node should show openai external api logs)
- we should have langgraph style detailed traces


- when we refresh we dont load duration data for steps only for fan out steps

- random nil steps showing up in data