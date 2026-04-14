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
bin/dc bundle exec rspec    # run the test suite (RSpec)
bin/dc bin/rails server     # → http://localhost:3000
bin/dc bin/jobs             # Solid Queue worker
bin/dc bash                 # interactive shell

# Tear down when done
docker compose -f .devcontainer/compose.yaml down
```

The devcontainer is also VS Code / JetBrains Gateway compatible — open the repo and it'll prompt to reopen in the container.

## Project management

Tracked in [GitHub Issues](https://github.com/tommy2118/dorm-guard/issues) with epic parent issues and per-slice child issues. Milestones group epics. No Projects v2 board — `gh issue list --milestone "..."` is the dashboard.

## Deployment environment

Production is deployed with Kamal to `dorm-guard.com`. The operator keeps a local `.env` file (gitignored — see `.gitignore` and the committed `.env.example` template) and `.kamal/secrets` sources it at deploy time. CI's deploy workflow writes the same schema from GitHub repo secrets so laptop and runner stay symmetric.

| Variable                  | Required | Default                                  | Consumed by                                                                   |
| ------------------------- | -------- | ---------------------------------------- | ----------------------------------------------------------------------------- |
| `RAILS_MASTER_KEY`        | yes      | (from `config/master.key`)               | Rails credentials / message verifier                                          |
| `DORM_GUARD_HOST`         | no       | `dorm-guard.com`                         | `config.hosts`, mailer URL options, Kamal proxy host                          |
| `DORM_GUARD_MAIL_FROM`    | no       | `dorm-guard@dorm-guard.com`              | `ApplicationMailer.default[:from]`                                            |
| `DORM_GUARD_ALERT_TO`     | no       | `alerts@dorm-guard.local`                | `DowntimeAlertMailer` recipient                                               |
| `SMTP_ADDRESS`            | no       | `email-smtp.us-east-1.amazonaws.com`     | `action_mailer.smtp_settings[:address]` (Amazon SES us-east-1 by default)     |
| `SMTP_PORT`               | no       | `587`                                    | `action_mailer.smtp_settings[:port]`                                          |
| `SMTP_USER_NAME`          | **yes**  | — (fail-fast)                            | `action_mailer.smtp_settings[:user_name]` — container refuses boot if missing |
| `SMTP_PASSWORD`           | **yes**  | — (fail-fast)                            | `action_mailer.smtp_settings[:password]` — container refuses boot if missing  |
| `KAMAL_REGISTRY_PASSWORD` | yes      | —                                        | Kamal → DigitalOcean Container Registry push                                  |
| `SOLID_QUEUE_IN_PUMA`     | yes      | `true` (set in `deploy.yml`)             | Runs Solid Queue workers inside the Puma process                              |
| `WEB_CONCURRENCY`         | yes      | `1` (pinned in `deploy.yml`)             | Pinned to prevent Solid Queue recurring-scheduler double-fire                 |

The SMTP vars are provider-neutral on purpose — swapping from SES to Resend / Mailgun / Postmark is a `.env` change, not a code change. For Amazon SES specifically: `SMTP_USER_NAME` is the IAM access key ID of a user with `ses:SendEmail`/`ses:SendRawEmail`; `SMTP_PASSWORD` is the [SES SMTP password derived](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html) from that IAM user's secret — **not** the IAM secret itself.

`.env.example` in the repo root is the authoritative schema — adding a new required deploy var to `config/deploy.yml` or `.kamal/secrets` without a matching line there is a process violation.

### Zero-auth deploy window (Epic 3 → Epic 4)

Epic 3 ships the production deploy without authentication as a deliberate stepping stone to Epic 4. Until auth lands, `/sites` CRUD is technically reachable by anyone who finds the URL. `public/robots.txt` is a `User-agent: *` / `Disallow: /` to discourage crawler indexing during this window. Operators who care about leakage should keep the URL private (or front it with a VPN / IP allowlist on the droplet) until Epic 4 merges.
