# Imgd
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

A fast, lightweight, embeddable workflow orchestration platform built with Elixir and Phoenix. Design, execute, and manage complex workflows.

## ✨ Features

### Workflow design & governance
- Draft-first editing with immutable published versions (semantic version tags + content hash)
- Workflow visibility and sharing with roles (`viewer`, `editor`, `owner`) plus public access
- DAG-based workflow modeling with validated steps/connections and graph utilities
- Automatic DAG layout metadata for UI rendering (layered layout + edge paths)

### Step system
- Step types are code-defined with JSON schemas for config/input/output
- Registry loads step types at startup (fast ETS lookups, category/kind grouping)
- Built-in step library includes:
  - Triggers: Manual Input, Webhook Trigger, Schedule Trigger
  - Control Flow: If/Else, Switch
  - Data & Transform: Format String, JSON Parser, Math, Splitter, Aggregator, Data Filter, Data Transform
  - Integrations & Utilities: HTTP Request, Debug
  - Output & Communication: Data Output, Respond to Webhook

### Execution runtime
- Runic-backed dataflow engine with per-execution OTP processes
- StepRunner resolves Liquid (Solid) expressions against execution context
- Step-level execution tracking with retries, timing, input/output/error capture
- Execution events + PubSub broadcasting for real-time UI updates
- Compute targets per step: local, cluster nodes, or FLAME pools

### Triggers & scheduling
- Webhook triggers with configurable path/method and response modes
- Schedule triggers managed via Oban jobs with automatic rescheduling
- Manual trigger and preview executions with custom input payloads
- Active trigger registry for efficient webhook routing

### Collaboration & preview tooling
- Collaborative edit sessions with operation linearization and persistence
- Presence tracking (cursor/selection/focus) and soft step locks
- Editor state features: pinned outputs, disabled steps, test webhook listeners
- Preview execution modes: full, from-step, to-step, or selected steps

### Expressions & data flow
- Liquid templates with access to `json`, `steps`, `execution`, `workflow`, `variables`, `metadata`, `request`, and `env`
- Custom filters for JSON, hashing, encoding, data manipulation, math, and dates
- Safe expression validation/evaluation with timeouts and strict modes

### Observability & operations
- Telemetry events for engine lifecycle, steps, and expression evaluation
- PromEx metrics with custom dashboards plus Phoenix/Ecto/Oban metrics
- OpenTelemetry tracing with trace-context propagation
- JSON log formatter for log aggregation pipelines

### Security & access
- Scope-based authorization for workflows, executions, and edit sessions
- Email/password auth plus magic-link login flows
- User API keys with hashed storage and partial key previews

### Sandboxed scripting
- QuickJS-in-Wasm sandbox with fuel, memory, and timeout limits
- FLAME-backed isolation with captured stdout/stderr and structured errors


## 🚀 Quick Start

### Prerequisites

- Elixir 1.15+
- PostgreSQL 13+
- Node.js 18+ (for asset compilation)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/your-username/imgd.git
   cd imgd
   ```

2. **Setup the application**
   ```bash
   # Install dependencies and setup database
   mix setup
   ```

3. **Start development services**
   ```bash
   # Start PostgreSQL and Adminer (optional)
   task up
   ```

4. **Run the application**
   ```bash
   # Start the Phoenix server
   mix phx.server
   ```

5. **Visit the application**
   Open [`http://localhost:4000`](http://localhost:4000) in your browser.





## 🛠️ Development

### Task Commands

```bash
# Development services
task up          # Start PostgreSQL + Adminer
task down        # Stop services
task restart     # Restart services
task logs        # View service logs

# Application
mix setup        # Initial setup
mix phx.server   # Start development server
mix test         # Run test suite
mix precommit    # Run pre-commit checks
```

### Architecture

```
lib/
├── imgd/                 # Core business logic
│   ├── accounts/         # User management
│   ├── workflows/        # Workflow orchestration
│   ├── executions/       # Runtime execution engine
│   ├── steps/           # Node type definitions
│   ├── runtime/         # WebAssembly runtime
│   └── observability/   # Monitoring & logging
└── imgd_web/            # Phoenix web interface
    ├── live/           # LiveView components
    ├── controllers/    # HTTP controllers
    └── components/     # Reusable UI components
```
