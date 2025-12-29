# Imgd
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

A fast, lightweight, embeddable workflow orchestration platform built with Elixir and Phoenix. Design, execute, and manage complex workflows.


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

