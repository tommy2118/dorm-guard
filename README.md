# dorm-guard

Production-grade uptime monitoring for the many sites I run, **built completely in the open** as a proving ground for AI-pair programming workflow (`agent-notes` + `pr-walkthrough` + `pr-review`). Every commit, every PR, every review comment is a public artifact of the process.

The domain `dorm-guard.com` is the eventual home.

## Why this exists

Two birds, one stone:

1. I need a real uptime/observability tool for my sites — checks, downtime detection, alerts.
2. I need a real, non-trivial project to exercise the AI-pair workflow on. Toy repos don't stress the loop.

Building it in public means the workflow itself becomes the documentation. Anyone reading this repo can see the slice arc, the agent commit notes, the PR walkthroughs, and form their own opinion about whether AI-pair programming holds up at production-grade.

## Stack

Stock Rails 8 — SQLite, Solid Queue / Cache / Cable, Propshaft, Hotwire, Kamal for deploy, Minitest. Consistency over cleverness; deviating from the framework defaults requires a real reason.

## Development

**All Ruby tooling runs inside the dev container, never on the host.** A short `bin/dc` wrapper makes that frictionless:

```sh
# One-time: build and start the dev container
docker compose -f .devcontainer/compose.yaml up -d --build

# Run any command inside the container
bin/dc bundle install
bin/dc bin/rails db:prepare
bin/dc bin/rails test
bin/dc bin/rails server     # → http://localhost:3000
bin/dc bin/jobs             # Solid Queue worker
bin/dc bash                 # interactive shell

# Tear down when done
docker compose -f .devcontainer/compose.yaml down
```

The devcontainer is also VS Code / JetBrains Gateway compatible — open the repo and it'll prompt to reopen in the container.

## Project management

Tracked in [GitHub Issues](https://github.com/tommy2118/dorm-guard/issues) with epic parent issues and per-slice child issues. Milestones group epics. No Projects v2 board — `gh issue list --milestone "..."` is the dashboard.
