# Imgd
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

A fast, lightweight, embeddable workflow orchestration platform built with Elixir and Phoenix. Design, execute, and manage complex workflows.

## Overview
Imgd is a workflow platform that combines a real-time collaborative editor with a high-performance execution engine. It is built on Phoenix LiveView + LiveVue for the UI and Runic for execution, so workflows are both **interactive** and **deeply inspectable**. The system is designed to be embedded inside your product, not bolted on later.

If you want a workflow engine that is expressive, versioned, and traceable, with a UI that feels like a first-class product feature, Imgd is built for that.

## Highlights
- **Runic execution engine**: immutable workflow graph that unifies definition + execution state for time-travel debugging and deterministic replay.
- **Draft + publish lifecycle**: edit privately, publish versioned workflows, and restore prior versions.
- **Real-time collaboration**: multi-user presence, live cursor/selection updates, locks, and undo/redo stacks.
- **Partial runs and debugging**: run-to-here execution, preview runs, and pinned outputs for fast iteration.
- **Expressions everywhere**: Liquid-style expressions (Solid) with n8n-compatible syntax, previews in the editor, and custom filters.
- **Triggers and automation**: manual, schedule, webhook, and event triggers; clean execution tracking per run and per step.
- **Workflow contracts**: derive input/output contracts from the workflow draft for safe embedding and API integrations.
- **Observability hooks**: structured logging, telemetry, and real-time execution events.

## Core Concepts
- **Workflow**: the top-level automation container. It has a private draft and one or more published versions.
- **Draft**: mutable working state. It is not public until published.
- **Version**: immutable snapshot created on publish, tagged with a version string.
- **Step**: a node in the graph (trigger, action, transform, control flow).
- **Execution**: a single run of a workflow, with status and step-level outputs.
- **Contract**: derived input/output schema to safely integrate workflows with external systems.

## Built-in Steps (selection)
- Triggers: manual input, schedule, webhook, event
- Flow: condition, switch, join, split/aggregate
- Data: JSON parser, formatter, math, data transform/filter
- Utilities: wait, debug, workflow output
- Integrations: HTTP request, respond to webhook

## Imgd vs n8n (where Imgd differentiates)
If you are evaluating Imgd alongside n8n, these are the areas where Imgd focuses:
- **Embedded-first**: the editor and runtime live inside your Phoenix app using LiveView + LiveVue.
- **Immutable execution graph**: Runic keeps the full execution history inside the workflow, enabling time-travel and replay.
- **Draft/publish with version tags**: clear lifecycle from private edits to published versions.
- **Collaboration built in**: presence, step locks, and undo/redo designed for teams.
- **Fast iteration tools**: partial execution, pinned outputs, and execution previews.
- **Deterministic contracts**: derived workflow I/O contracts for safer integrations.

n8n is an excellent general-purpose automation tool. Imgd is optimized for teams that want a workflow engine embedded inside their own product, with strong versioning and deep execution introspection.

## Architecture Overview
- **Phoenix + LiveView** for backend, auth, and server-driven UI.
- **LiveVue + Vue Flow** for a high-fidelity, reactive workflow editor.
- **Runic** for immutable workflow execution and event-sourced state.
- **Ecto + Postgres** for persistence (workflows, versions, executions).
- **Phoenix PubSub + Presence** for real-time collaboration and execution events.

## Roadmap
Based on the current TODO list, the roadmap includes:

### Core Runtime
- Sub-workflows and streaming outputs
- Workflow-level variables with scoping rules
- Cross-execution memory (state machines / saga patterns)
- Debug execution mode

### Editor UX
- Smarter edit stack grouping for undo/redo
- Inline add-node flow from existing nodes
- Better connection UX (drop node between edges)
- Node wrangler / Blender-style group tools
- Disable node mode refinements

### Interoperability
- n8n workflow import
- Versioned executor namespaces (e.g., `Nodes.V1.HttpRequest`)

### Triggers + Streaming
- WebSocket trigger (long-lived execution modeling)
- Stream trigger model and optimized high-frequency handling
- Optional low-overhead mode for heavy workloads

### Examples / Demos
- FLAME example: input video -> streaming thumbnails
- Multi-node example: distribute execution across devices
- Game server workflow example

### Future
- Docker and Kubernetes system nodes
- UI builder (Kino / Notion inspired)
- Datasets + evaluations
- AI chat workflow builder
- Lightweight deployments (Raspberry Pi)

## Development
Prereqs: Elixir, Node.js, and Postgres.

```bash
mix setup
mix phx.server
```

Run the test + formatting gate:

```bash
mix precommit
```

## Docs
- `docs/runic_guide.md`
- `docs/runic_architectural _overview.md`
- `lib/imgd/steps/executors/README.md`

## License
MIT
