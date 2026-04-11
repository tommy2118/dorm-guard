# CLAUDE.md — dorm-guard project overrides

These are project-specific overrides on top of the user's global `~/.claude/CLAUDE.md`. Read both. When they conflict, this file wins for work in this repo.

## The unbreakable rules

1. **All Ruby tooling runs in the dev container.** Never invoke `bin/rails`, `bundle`, `ruby`, `rake`, or any gem binary directly on the host. Always go through `bin/dc`:
   ```sh
   bin/dc bin/rails test
   bin/dc bundle add some-gem
   bin/dc bin/rails console
   ```
   The only host-side exceptions are the one-time bootstrap commands (`rails new`, `bin/rails devcontainer`) that create the container itself. After bootstrap, the host has no business running Ruby. If you catch yourself typing `bin/rails` without `bin/dc`, stop.

2. **The PR ritual is the deliverable.** Every feature-branch commit gets an `agent-notes` YAML. Every PR gets walked with `pr-walkthrough` and reviewed with `pr-review`. Skipping either skill on the grounds that "the change is small" defeats the entire reason this project exists. The workflow is the artifact.

3. **Issues live in GitHub, not in local task lists or memory.** When the user says "make a ticket" or "track this," `gh issue create`. When refining scope, `gh issue edit`. Local TaskCreate is fine for in-conversation execution but never the persistent home of project state.

## Stack discipline

- **Rails 8 defaults, no deviations without a reason.** SQLite, Solid Queue/Cache/Cable, Propshaft, Hotwire, Kamal. If you reach for Postgres, Sidekiq, or Webpack, you're fighting the framework — surface that and ask first.
- **Test framework: RSpec** (`rspec-rails`). This is an explicit deviation from the Rails 8 Minitest default — chosen mid-bootstrap because the user's broader workflow (Sandi Metz / GOOS / mockist TDD) is more fluent in RSpec. Specs live in `spec/`, not `test/`. CI runs `bundle exec rspec`, not `bin/rails test`.
- **Composition over inheritance, Tell Don't Ask, Sandi's rules** — all still in force, now in RSpec syntax (`describe`, `context`, `it`, `expect(...).to`).

## Slice and commit cadence

- Slices come from `~/.claude/plans/parallel-wandering-crown.md`. Each slice = one commit on a feature branch = one `agent-notes` YAML.
- A slice is too big when you can't summarize its `intent` in one sentence. Re-split.
- Tests green at the end of every slice. Run `bin/dc bundle exec rspec` before committing — *inside the container*.
- The plan file's `## Slices` section is the source of truth for `agent-notes`'s slice number.

## When in doubt

- Read the plan file first.
- Read this file second.
- Read the global `~/.claude/CLAUDE.md` third.
- Ask the user.
