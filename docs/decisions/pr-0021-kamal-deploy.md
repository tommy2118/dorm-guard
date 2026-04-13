# PR #21 — Epic 3 — Kamal deploy to dorm-guard.com

**Branch:** `feature/kamal-deploy`
**Generated from:** Slice 5 (ADR), before Slices 6–9 execute
**Status:** runbook precedes runtime — this document is the plan, not the recap

## Why this document exists

Epic 3 is the first real-world deploy. Every prior epic was local-only: seeds, specs, letter_opener. This epic pushes an image to a registry, provisions a droplet, issues a Let's Encrypt cert for a public hostname, and runs a Solid Queue recurring scheduler against real HTTP. When any of those fail, the operator is going to be reading this file under stress. The document has to be short enough to read end-to-end in a hurry and specific enough to execute without pattern-matching on "probably works".

It's written *before* Slice 6 (the first `kamal setup`) runs, so what lands in git is the intended runbook — not a cleaned-up recap. Deviations that emerge during Slice 6 get captured in the Slice 6 commit body + agent-note, not retroactively smoothed into this file.

## Decisions

### Infrastructure
- **Provider:** DigitalOcean. Droplet-based single-box deploy. Kamal 2.11.0 is the deploy tool. Not Fly, not DO App Platform, not ECS.
- **Server size:** `s-1vcpu-1gb` ($6/mo) in `nyc3`. Smallest shared-CPU tier. Plenty for Rails 8 + SQLite + a couple dozen sites polled per minute. Resize-up path is live (`doctl compute droplet-action resize`) if it turns out tight.
- **OS image:** `ubuntu-24-04-x64`. Kamal's documented target.
- **Container registry:** DigitalOcean Container Registry, reusing the existing `nightloom` namespace. DO enforces one registry per account; a second is not available. Image path: `registry.digitalocean.com/nightloom/dorm_guard`. The cross-region pull (registry in `sfo2`, droplet in `nyc3`) adds ~10–30 s to each deploy — not a blocker for a single-operator MVP.
- **DNS:** `dorm-guard.com` is managed in AWS Route 53, hosted zone `Z09106673B9HJ8J7PRZLR`. An `A` record at the apex, TTL 60, points at the droplet's public IPv4. Short TTL is deliberate — Slice 6 provisions, waits for propagation, and runs `kamal setup`; a 60-second TTL keeps the feedback loop tight.
- **TLS:** Kamal's Thruster proxy provisions a Let's Encrypt cert on first `kamal setup`, auto-renewed on the 60-day cycle. No manual cert management.

### Runtime topology
- **Web + jobs co-located in one Puma process.** `SOLID_QUEUE_IN_PUMA=true` runs the Solid Queue supervisor inside Puma's main process. `config/recurring.yml`'s `schedule_due_checks` fires every minute from the same process. No separate job accessory. Single-box MVP; splitting is an Epic 7 concern.
- **`WEB_CONCURRENCY=1` is load-bearing.** Pinned in `config/deploy.yml` and enforced at runtime by a guard in `config/puma.rb` that refuses to boot if `SOLID_QUEUE_IN_PUMA=true` meets `WEB_CONCURRENCY>1`. The combination would instantiate one Solid Queue supervisor per Puma worker and fire the recurring scheduler N× per minute. The pin is *both* configured *and* enforced — "documented but not enforced" is a fragile control.
- **State:** Four SQLite databases (`production`, `production_cache`, `production_queue`, `production_cable`), all under `/rails/storage`, backed by the Kamal-managed `dorm_guard_storage` named volume. Volume persists across deploys.

### Mail
- **Provider:** Amazon SES SMTP at `email-smtp.us-east-1.amazonaws.com:587`, STARTTLS, AUTH LOGIN. Chosen in Slice 5B after Mailgun's free tier turned out to be unavailable on the operator's account; SES is effectively free at this volume (pennies per month for a single-recipient downtime monitor) and we were already using AWS credentials for Route 53.
- **Operator precondition:** the sending identity must be verified in SES (`aws ses verify-email-identity`). SES's sandbox mode is actually ideal for this use case — it restricts delivery to *verified* recipients only, which matches "single-operator MVP alerting one person" exactly. Proper domain verification (for the sending side) can follow in a later slice; for now, verify the same email address as both `DORM_GUARD_MAIL_FROM` and `DORM_GUARD_ALERT_TO` and SES will send-to-self.
- **Credentials:** `SMTP_USER_NAME` and `SMTP_PASSWORD` have **no defaults** in `config/environments/production.rb`. Missing either causes a `KeyError` at boot and Kamal rolls the deploy back. This is deliberate — silent delivery failure is the one thing a downtime monitor cannot afford. For SES specifically, `SMTP_USER_NAME` is the IAM access key ID of a user scoped to `ses:SendEmail`/`ses:SendRawEmail`, and `SMTP_PASSWORD` is the [SES SMTP password derived](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html) from that IAM user's secret access key — **not** the IAM secret itself. Slice 6 documents the derivation steps in the Slice 6 commit body.
- **Env var naming:** `SMTP_*` is deliberately provider-neutral. Swapping providers (SES → Resend, SES → Postmark, etc.) is a `.env` change, not another rename slice. Slice 5B renamed from `MAILGUN_SMTP_*` → `SMTP_*` for exactly this reason.
- **Accepted trade-off:** `raise_delivery_errors = false`. Cost: a post-boot SMTP outage or credential rot will silently drop alerts; the operator learns via inbox absence + the SES / CloudWatch dashboards, not via exception. Reason: letting mailer exceptions bubble from `PerformCheckJob` would poison Solid Queue's failed-job table on every transient SMTP hiccup. Revisit in Epic 6.

### Secrets
- `.env` on the operator's laptop (gitignored), sourced by `.kamal/secrets`. CI's deploy workflow (Slice 8) writes a matching `.env` from GitHub repo secrets so laptop and runner are schema-symmetric.
- `.env.example` in the repo root is the authoritative schema. Adding a required deploy var to `config/deploy.yml` without a matching line in `.env.example` is a process violation.

### Deferrals to future epics
- **Authentication.** Epic 4. During the zero-auth window `public/robots.txt` is `Disallow: /` to discourage indexing. Operator should keep the URL private or front it with IP allowlist / VPN until Epic 4 merges.
- **SSRF protection in `HttpChecker`.** Epic 4. Current `HttpChecker` will follow any URL in `Site.url` including private ranges.
- **Backup story.** Future ops epic. Named volume `dorm_guard_storage` means backups can bolt on without code changes.
- **Separate Solid Queue job accessory.** Epic 7 or later, when multi-node is on the table.
- **Log aggregation.** Future ops epic. Current approach is `kamal app logs` as needed.

## Operator preconditions (must be true before `kamal setup`)

1. **Droplet provisioned** via `doctl compute droplet create` in `nyc3`, `s-1vcpu-1gb`, `ubuntu-24-04-x64`, with all personal SSH keys installed (`pulse-deploy`, `ironman`, `thor`, `captain-america`). Public IPv4 captured.
2. **DNS propagated:** Route 53 `A` record at `dorm-guard.com` → droplet IPv4, TTL 60. Verify with `dig +short dorm-guard.com` from the operator's laptop before proceeding.
3. **`config/deploy.yml` placeholders substituted:** grep for `REPLACE-` in the file and replace both tokens with real values. There are exactly two: `REPLACE-DROPLET-IP` and `REPLACE-DOCR-NAMESPACE`. Miss either and `kamal setup` fails at push or SSH.
4. **`.env` populated:** copy `.env.example` to `.env` and fill in `RAILS_MASTER_KEY`, `KAMAL_REGISTRY_PASSWORD` (DigitalOcean API access token), `SMTP_USER_NAME` (SES IAM access key ID), `SMTP_PASSWORD` (SES-derived SMTP password, not the IAM secret), `DORM_GUARD_ALERT_TO`, `DORM_GUARD_MAIL_FROM`. Leave the vars with defaults empty unless overriding.
5. **DOCR login:** `doctl registry login` on the operator's laptop so Docker can push to `registry.digitalocean.com/nightloom`.
6. **SES identity verified:** `aws ses verify-email-identity --email-address <addr> --region us-east-1` and click the verification link. Same address should be both `DORM_GUARD_MAIL_FROM` and `DORM_GUARD_ALERT_TO` while SES is in sandbox mode.

## First deploy runbook (Slice 6)

Execute in order. Stop at the first failure and consult the Rollback section.

```sh
# 1. On the operator's laptop, on feature/kamal-deploy
git status                      # Working tree clean, on feature/kamal-deploy
grep REPLACE- config/deploy.yml # Must return nothing — placeholders substituted

# 2. Verify the image builds locally first (catches Dockerfile bugs
#    before the registry push stage)
docker build -t dorm_guard:preflight .

# 3. Confirm Kamal parses the resolved config
bin/dc kamal config

# 4. Push the image + provision the host
doctl registry login            # Docker CLI can auth to DOCR
bin/dc kamal setup              # First deploy — installs Docker on the
                                # droplet, pushes image to DOCR, pulls
                                # on the droplet, boots container,
                                # provisions Let's Encrypt cert.

# 5. Verify over the public internet (not localhost)
curl -sSI https://dorm-guard.com/up          # Expect: HTTP/2 200
openssl s_client -connect dorm-guard.com:443 -servername dorm-guard.com < /dev/null \
  2>&1 | grep -E "subject=|issuer=|verify return"

# 6. Confirm the Rails app sees the volume and is empty
bin/dc kamal app exec "bin/rails runner 'puts Site.count'"  # Expect: 0
bin/dc kamal app logs | tail -40                             # Clean boot
```

## Rollback

Not a full DR plan — just the minimum answer to "deploy is unhealthy, what do I do in the next 60 seconds?"

### Failed container boot after `kamal deploy`
Symptom: `kamal deploy` succeeds up to the container-run stage, then health check fails and Kamal reports a rolled-back state.

```sh
bin/dc kamal rollback
curl -sSI https://dorm-guard.com/up   # Expect: HTTP/2 200 from previous image
```

Kamal's `rollback` moves the live container back to the previous image digest. If the previous digest is itself broken (first deploy scenario), there is no rollback target — forward-fix is the only option. In that case, `bin/dc kamal app stop` leaves the site cleanly down while you fix and redeploy.

### Failed health check post-deploy
Symptom: container boots, `/up` returns non-200, Kamal keeps the new image live because the check ran out of retries.

```sh
bin/dc kamal app logs | tail -100    # Find the error
bin/dc kamal rollback                # Back to previous image
```

Same as above — if no previous image exists, forward-fix. Common first-deploy causes: `config.force_ssl` loop (Slice 2A's `/up` redirect-exclude missing), `config.hosts` rejecting the Kamal probe's Host header (Slice 2A's host-auth exclude missing), missing SMTP credential causing `KeyError` at boot (Slice 2B/5B's fail-fast firing correctly — fix `.env`).

### Failed TLS cert issuance on first `kamal setup`
Symptom: `kamal setup` completes the image push + container boot, but the proxy shows no cert and `https://dorm-guard.com/up` fails with a TLS error.

Check in order:
1. **DNS:** `dig +short dorm-guard.com` — does the A record resolve to the droplet IP? If not, the Route 53 change hasn't propagated yet or points at the wrong IP. Fix and wait one TTL.
2. **Port 80 reachable:** Let's Encrypt's HTTP-01 challenge hits the droplet on port 80. If the droplet firewall blocks it, the challenge fails silently. `ufw status` on the droplet; Kamal's setup opens 80 and 443 by default but a custom firewall rule can close them.
3. **Rate limit:** Let's Encrypt rate-limits cert issuance per domain. If you've been iterating, you might be rate-limited. Check the Kamal proxy logs (`bin/dc kamal proxy logs`) for `urn:ietf:params:acme:error:rateLimited`. Wait out the window or use the staging environment.

Rollback does **not** help here — a cert problem is forward-fix only. `bin/dc kamal proxy reboot` retries cert issuance without a full redeploy.

### Failed post-deploy smoke
Symptom: `/up` returns 200 over TLS, but Slice 7's seeded check + mail flow doesn't complete end-to-end.

1. `bin/dc kamal app logs | grep -E "(PerformCheckJob|DowntimeAlertMailer|SMTP)"` — did the job run? did the mailer run?
2. **SES console → Account dashboard → Sending statistics** (plus CloudWatch `AWS/SES` namespace for per-minute send/bounce counts). Check for `Delivery`, `Bounce`, or `Complaint` events tied to `DORM_GUARD_ALERT_TO`.
3. If SES shows no attempts, the app isn't reaching SMTP — check `smtp_settings` is being read (the fail-fast would have caught unset credentials at boot, so this would be a network / DNS issue reaching `email-smtp.us-east-1.amazonaws.com`, or SES throttling).
4. If SES shows `MessageRejected: Email address is not verified`, the recipient isn't verified and SES is still in sandbox mode — verify it with `aws ses verify-email-identity` or request production access from the SES console.

Rollback the image only if the broken state is tied to a code regression in the current slice. If it's a credential or domain issue, forward-fix in `.env` + redeploy (`bin/dc kamal env push && bin/dc kamal deploy`).

### What rollback does *not* cover
- **Database migrations.** Epic 3 ships no migrations. If a future slice ships an irreversible migration (dropping a column, narrowing a constraint, backfilling data), its own rollback section must spell out the forward-fix because `kamal rollback` alone will leave the DB in a state the old image can't read.
- **Volume corruption.** A corrupted `dorm_guard_storage` volume cannot be rolled back — it must be restored from a backup. No backup story in Epic 3; this is an accepted risk.
- **DNS.** If DNS points at a droplet that's destroyed, there is no app to roll back to. Keep the droplet.

## Secrets required in CI (Slice 8)

These are the GitHub repo secrets the Slice 8 deploy workflow will read. Listed here so the operator can provision them ahead of time:

- `DIGITALOCEAN_ACCESS_TOKEN` — DO API token for `doctl registry login` + droplet SSH (via the installed key)
- `KAMAL_SSH_KEY` — private key whose public key is installed on the droplet (one of the SSH keys from Slice 6)
- `KAMAL_REGISTRY_PASSWORD` — same DO API token as above; Kamal uses it as both username and password for DOCR
- `RAILS_MASTER_KEY` — contents of `config/master.key`
- `SMTP_USER_NAME` — SES IAM access key ID (or equivalent for other providers)
- `SMTP_PASSWORD` — SES SMTP password derived from the IAM secret (not the raw IAM secret; see SES docs for the derivation)
- `DORM_GUARD_ALERT_TO` — recipient for downtime alerts (must be a verified SES identity while the sandbox is in effect)
- `DORM_GUARD_MAIL_FROM` — sender address on a verified SES identity (same address as ALERT_TO is fine during sandbox)

## Constraints that must not drift

- `config.hosts` in `production.rb`, `proxy.host` in `deploy.yml`, and `dorm-guard.com` in Route 53 must agree. All three are the same string or TLS issuance / host authorization / request routing breaks.
- `WEB_CONCURRENCY=1` in `deploy.yml` and the boot guard in `puma.rb` are an atomic pair. Changing one without the other is a regression. Any slice that wants `WEB_CONCURRENCY>1` must also move Solid Queue to a dedicated accessory.
- `.env.example` and `config/deploy.yml` must stay schema-synchronized. Any var added to `deploy.yml`'s `env.secret` or `env.clear` must appear in `.env.example` with a comment explaining its purpose.
