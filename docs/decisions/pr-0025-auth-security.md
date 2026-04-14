# PR #25 — Epic 4 — Authentication + security hardening

**Branch:** `feature/auth-security`  
**Generated from:** `7a754c2dfe`  
**Generated:** 2026-04-14  
**Slices:** 6

## Context

dorm-guard went live (Epic 3) with a deliberate trade-off recorded in the plan: zero authentication. Anyone who found the URL at dorm-guard.com could list, create, modify, or destroy uptime monitors. Two additional security holes were flagged and deferred from Epic 1: `HttpChecker` would follow a `Site.url` straight into private IP ranges (SSRF), and the Site model's URI scheme whitelist had no regression spec pinning it. This PR closes all three debts.

## Where this lives

- **`app/controllers/concerns/authentication.rb`** — the generated Rails 8 concern; the nerve center. It wires `before_action :require_authentication` into every controller via `included do`, and exposes `allow_unauthenticated_access` as the controller-level opt-out mechanism.
- **`app/controllers/application_controller.rb`** — one added line: `include Authentication`. Because every app controller inherits from here, this single include makes the guard global.
- **`app/models/user.rb`** — BCrypt-backed User model with a 16-char password floor and email normalizer.
- **`app/services/ssrf_guard.rb`** — new Faraday middleware that intercepts every outbound HTTP request and rejects it before TCP if the target resolves to non-public IP space.
- **`spec/requests/authentication_spec.rb`** — the boundary contract (8 examples); **`spec/services/ssrf_guard_spec.rb`** — SSRF coverage (18 examples); **`spec/support/auth_helpers.rb`** — the `sign_in_as` helper used by all request specs.

## The arc

Four slices, each green before the next begins. Slice 1 installs the scaffolding and intentionally breaks all existing request specs (auth fires everywhere — expected). Slice 2 proves the boundary and makes tests maintainable. Slice 3 adds the SSRF firewall and service-level scheme guard. Slice 4 locks the model's scheme whitelist with regression specs.

## Slice 1/4 — Rails 8 auth scaffold + User model + admin seed

The Rails 8 `generate authentication` command produces the session/password-reset infrastructure in one pass — User + Session models, sessions/passwords controllers, views, mailer. Two critical side effects: it adds `include Authentication` to `ApplicationController` (making `before_action :require_authentication` fire globally), and it runs two DB migrations.

We added two things on top of the generated code: a 16-char password floor (`validates :password, length: { minimum: 16 }, allow_nil: true`) and a production-gated admin seed in `db/seeds.rb`.

**`allow_nil: true` is load-bearing.** `has_secure_password` never persists the plaintext password — only the BCrypt digest. After a record loads from the DB, `user.password` is nil. Without `allow_nil`, updating any other attribute on an existing user (e.g., email normalization) would fail the length validation even when no password change was intended.

**Known UX debt:** `PasswordsController#update` (generated, 7 lines — one over Metz's 5-line limit) shows "Passwords did not match" for both a password mismatch AND a password that's too short. Not a security defect — the password isn't stored in either case — but the error message is misleading. Flagged for a future polish pass.

The breaking change here was intentional: all 25 existing request specs started failing with 302 redirects after this slice. They were patched with an inline `sign_in_as` helper (extracted to a proper support module in Slice 2).

## Slice 2/4 — Auth boundary: /up exempt, shared helper, boundary spec

No production behavior change — auth wiring was fully in place after Slice 1. The work here is proving what the boundary looks like and ensuring tests are maintainable.

**Key discovery:** `/up` (Kamal's health probe) needs no exemption configuration. `Rails::HealthController` is a framework-internal controller that doesn't inherit from `ApplicationController`, so `before_action :require_authentication` never fires on it. The boundary spec is the proof — `GET /up` returns 200 without a session cookie. Zero production code changed in this slice.

**`sign_in_as(user)` posts to the real session endpoint** rather than stubbing `Current.session` or faking the cookie. Cost: one extra POST per request spec example. Benefit: exercises actual `SessionsController#create` — a stub would miss misconfigured cookie settings or rate-limit interactions.

The `authentication_spec.rb` boundary spec proves five contracts: unauthenticated redirects to login (sites, root), `/up` and `/session/new` remain open, authenticated access works, return-to-URL is honored after login, and logout destroys the session.

## Slice 3/4 — SSRF Faraday middleware + service scheme guard

`HttpChecker` would faithfully follow any URL a Site record contained — including `http://169.254.169.254/latest/meta-data/`. The fix lives at the HTTP client layer so it catches records created through any path (UI, console, migration, validation bypass).

**`SsrfGuard`** is a Faraday middleware (`Faraday::Middleware` subclass) applying a two-phase check before any TCP connection:

1. **Literal IP fast path** — if `env.url.hostname` parses as an IP address (`IPAddr.new` succeeds), check it directly against the blocked ranges. No DNS lookup. Handles `127.0.0.1`, `10.0.0.1`, `[::1]`, etc.
2. **DNS resolution** — for hostnames, `Resolv.getaddresses` fetches all A/AAAA records. Every resolved address must clear the blocked-range check. One blocked address in the set blocks the request — this prevents split-horizon DNS bypass (a hostname resolving to both a public and a private IP).

Fail-closed in two ways: NXDOMAIN (empty address list) blocks rather than passes, and an unparsable resolved address raises `BlockedIpError` rather than being skipped.

**`BlockedIpError < Faraday::Error`** is load-bearing. `HttpChecker#check` already rescues `Faraday::Error`. The new error type falls into that rescue automatically — no changes to the rescue clause, no unhandled exceptions escaping to the job layer.

**Named non-goal — DNS rebinding:** The guard checks the resolved IP at request-initiation time. A TTL-0 rebinding attack can switch the IP after the check. Full protection requires a custom adapter pinning the resolved IP for the TCP connection lifetime — explicitly deferred to a future security epic, documented in code.

`HttpChecker` also gains a scheme check before the Faraday call: `ftp://`, `javascript:`, and other non-http(s) schemes are rejected immediately. Defence-in-depth — the Site model validates at the UI layer, but the service needs its own boundary for all other record-creation paths.

## Slice 4/4 — URI scheme regression lock

The Site model's URL validator already rejects `javascript:`, `data:`, `file:`, and `ftp:` schemes via `URI::DEFAULT_PARSER.make_regexp(%w[http https])`. This slice adds four parameterized spec examples making that rejection explicit and machine-checked. A future refactor widening the allowlist breaks a named test rather than silently opening an injection vector. Pre-verified in the container — no model patch needed.

## The big picture

**Layered defense after this PR:**
```
Request → ApplicationController (require_authentication)
              ↓ authenticated
Site CRUD → Site.url validated (http/https only — scheme whitelist locked by spec)
              ↓ valid URL persisted
Background job → HttpChecker.check(url)
              ↓ scheme check (defence-in-depth)
              ↓ Faraday → SsrfGuard: literal IP check → DNS resolution check
              → outbound TCP (only if all guards pass)
```

**Seams — where future changes land:**
- Adding OAuth/SSO: extend the `Authentication` concern and `SessionsController`. `allow_unauthenticated_access` is the designated extension point.
- Adding redirect-following in Faraday: `SsrfGuard` must remain first in the stack — there's a code comment at `f.use SsrfGuard` in `http_checker.rb:27`.
- Tightening SSRF against DNS rebinding: requires a custom adapter pinning the resolved IP for the TCP connection lifetime — future security epic.

**Accepted trade-offs:** DNS rebinding not addressed (named gap, documented in code). Password reset UX shows wrong error for too-short passwords (not a security defect, future polish). Single admin, single node.

**Open question:** Production seeding (`bin/rails db:seed` via Kamal exec, documented in PR description) is a one-time manual bootstrap. Needs to run before the first login attempt on dorm-guard.com.

*LLM walkthrough generated by Claude Code — for teaching/orientation only. Run `pr-review` for an accuracy-focused fact-check pass.*

## Slices

### Slice 1/4 — feat(auth): Slice 1 — Rails 8 auth scaffold + User model + admin seed

`2f3e4804a3` · feature · entangled rollback · medium confidence · breaking

**Intent.** Bootstrap the Rails 8 authentication scaffold: land User + Session models, wire ApplicationController with require_authentication, add a 16-char password floor, seed one admin from ENV, and prove the model contract with specs.

**Scope (27 files).**
- `Gemfile`
- `Gemfile.lock`
- `app/models/user.rb`
- `app/models/current.rb`
- `app/models/session.rb`
- `app/controllers/application_controller.rb`
- `app/controllers/sessions_controller.rb`
- `app/controllers/passwords_controller.rb`
- `app/controllers/concerns/authentication.rb`
- `app/views/sessions/new.html.erb`
- `app/views/passwords/new.html.erb`
- `app/views/passwords/edit.html.erb`
- `app/mailers/passwords_mailer.rb`
- `app/views/passwords_mailer/reset.html.erb`
- `app/views/passwords_mailer/reset.text.erb`
- `db/migrate/20260414124519_create_users.rb`
- `db/migrate/20260414124520_create_sessions.rb`
- `db/schema.rb`
- `config/routes.rb`
- `db/seeds.rb`
- `spec/models/user_spec.rb`
- `spec/requests/sites_spec.rb`
- `app/channels/application_cable/connection.rb`
- `db/cable_schema.rb`
- `db/cache_schema.rb`
- `db/queue_schema.rb`
- `spec/fixtures/users.yml`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/user_spec.rb`
- `spec/requests/sites_spec.rb`

**Assumptions.**
- rails generate authentication output matches the plan's declared files — drift items are all valid generator output, not unexpected additions
- ADMIN_EMAIL and ADMIN_PASSWORD will be set in the production environment before the first login attempt
- URI::MailTo::EMAIL_REGEXP is sufficient email validation for a single-admin app (not RFC 5322 strict)

**Specifications established.**
- User requires email_address (presence + URI::MailTo::EMAIL_REGEXP format)
- User password minimum: 16 chars; allow_nil: true so existing-record updates without password re-entry remain valid
- Admin seed is create-only (find_or_create_by!); subsequent password changes go through password reset flow
- Production admin seed runs once as a manual bootstrap step, not on every deploy
- ApplicationController includes Authentication — before_action :require_authentication fires on every request by default

**Deviations from plan.** Plan listed app/channels/application_cable/connection.rb as not in scope, but rails generate authentication creates it unconditionally to wire WebSocket auth. Also committed: db/cable_schema.rb, db/cache_schema.rb, db/queue_schema.rb (auto-regenerated by db:migrate, schema version bump 7.1 → 8.1) and spec/fixtures/users.yml (empty fixture generated by rspec hook). All generator artifacts — not a plan bug, just incomplete declared scope. Second deviation: spec/requests/sites_spec.rb updated with an inline sign_in_as helper (planned for Slice 2 as spec/support/auth_helpers.rb) to keep the suite green after the auth guard lands. Slice 2 extracts this to the support module.

**Trade-offs.** Inline sign_in_as in sites_spec.rb instead of waiting for Slice 2's support module: costs a duplicated method that lives one slice, gains a green suite at every commit boundary. CLAUDE.md requires green tests at end of every slice — this is the minimum viable fix. Alternative considered: skip_before_action in the spec environment (rejected: masks the actual auth behavior under test).

**Interfaces.**
- Published: `User.authenticate_by(email_address:, password:) -> User | false`, `Session.find_by(id:) -> Session | nil`, `Authentication#require_authentication -> redirect | nil`, `Authentication#allow_unauthenticated_access(**options)`

**Self-review.**
- **consistency.** Inline sign_in_as in sites_spec.rb intentionally deviates from the future spec/support/auth_helpers.rb module — comment declares the extraction target (Slice 2). All other patterns match surrounding code.
- **metz.** passwords_controller.rb update method is 7 lines (Metz limit: 5). Generated code; single sequential reset flow — splitting would obscure the path. All other generated methods measured under 5 lines. user.rb is 12 lines.
- **error paths.** PasswordsController#update redirects "Passwords did not match" when @user.update returns false — now includes our minimum-length validation failure. Misleading UX (short password shows wrong error message), not a security defect. Known UX debt for a future polish pass.
- **api.** ApplicationController before_action :require_authentication is a breaking change for all unauthenticated requests. New public routes: resource :session, resources :passwords. Slice 2 exempts /up via allow_unauthenticated_access.

**Reviewer attention.**
- `app/models/user.rb:9-11` — password floor with allow_nil: true; verify the nil semantics are correct on update
- `app/controllers/passwords_controller.rb:20-26` — update method will surface length error as wrong message after our validation addition

### Slice 2/4 — feat(auth): Slice 2 — auth boundary: /up exempt, shared sign_in_as, boundary spec

`7ce4296587` · test · trivial rollback · high confidence

**Intent.** Prove the auth boundary: /up remains accessible without login, all Site routes redirect unauthenticated requests, and extract sign_in_as to a shared support module so request specs don't carry duplicated inline helpers.

**Scope (4 files).**
- `spec/support/auth_helpers.rb`
- `spec/rails_helper.rb`
- `spec/requests/sites_spec.rb`
- `spec/requests/authentication_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/requests/authentication_spec.rb`
- `spec/support/auth_helpers.rb`

**Assumptions.**
- /up is exempt because Rails::HealthController does not inherit ApplicationController — verified via boundary spec (GET /up returns 200 without login)
- session_path route helper is available in the AuthHelpers module when included into request spec examples

**Specifications established.**
- GET /up returns 200 without authentication (Kamal health probe must never be blocked)
- GET /session/new is accessible without authentication (login page must be reachable)
- All other application routes redirect unauthenticated requests to new_session_path
- After login, Rails redirects to the originally requested URL (session[:return_to_after_authenticating])
- DELETE /session destroys the session cookie; subsequent requests are unauthenticated

**Deviations from plan.** Plan implied a HealthController investigation before deciding the /up exemption mechanism. Approach changed: used the boundary spec itself as the proof (GET /up returns 200 without login). No path-string branching added anywhere — exemption holds by class inheritance, not configuration.

**Trade-offs.** Authenticating through the real session endpoint in sign_in_as (POST /session) rather than stubbing session state. Cost: one extra POST per request spec example. Benefit: tests the real auth path — a stub would miss misconfigured cookie settings or rate-limit interactions. The cost is negligible at 34 request specs.

**Interfaces.**
- Consumed: `Authentication#require_authentication -> redirect | nil (from Slice 1)`, `Authentication#allow_unauthenticated_access(**options) (from Slice 1)`, `SessionsController#create(email_address:, password:) -> session cookie (from Slice 1)`
- Published: `AuthHelpers#sign_in_as(user, password: String) -> void`

**Self-review.**
- **consistency.** sign_in_as signature (keyword arg with default) matches the boundary spec usage. Pattern mirrors how other Rails projects wire request spec auth helpers.
- **metz.** auth_helpers.rb: 1 public method, 3 lines. authentication_spec.rb: 8 examples, no class.
- **security.** sign_in_as uses a hardcoded test password string — correct for test env. Boundary spec proves /up bypasses auth without any config change.

**Reviewer attention.**
- `spec/support/auth_helpers.rb:10-12` — sign_in_as posts to real session endpoint; confirm this is the correct controller action name after Slice 1 routing

### Slice 3/4 — feat(security): Slice 3 — SSRF Faraday middleware + service scheme guard

`4d364fd6e8` · feature · reversible rollback · high confidence · additive

**Intent.** Block SSRF attacks at the HTTP client boundary: SsrfGuard Faraday middleware rejects requests to private/loopback/link-local IP space before any TCP connection is attempted; HttpChecker gains a scheme whitelist as defence-in-depth.

**Scope (4 files).**
- `app/services/ssrf_guard.rb`
- `app/services/http_checker.rb`
- `spec/services/ssrf_guard_spec.rb`
- `spec/services/http_checker_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/services/ssrf_guard_spec.rb`
- `spec/services/http_checker_spec.rb`

**Assumptions.**
- Faraday 2.x env.url.hostname strips brackets from IPv6 literals (e.g. [::1] -&gt; ::1)
- Resolv.getaddresses is the correct stdlib API for all-record DNS resolution in Ruby 4.0
- The Faraday :test adapter bypasses WebMock (different stack layer) — verified by passing passthrough test

**Specifications established.**
- SSRF guard fails closed on NXDOMAIN (empty Resolv result -&gt; BlockedIpError)
- SSRF guard fails closed on unparsable resolved addresses (IPAddr::InvalidAddressError -&gt; BlockedIpError)
- Multi-IP resolution: any blocked address in the resolved set blocks the request (split-horizon guard)
- Literal IP fast path: blocked_literal_ip? short-circuits before Resolv.getaddresses is called
- BlockedIpError &lt; Faraday::Error — caught by existing rescue in HttpChecker#check
- HttpChecker rejects non-http(s) schemes before creating a Faraday connection
- SsrfGuard must precede any redirect middleware in the Faraday stack (noted in code comment)

**Trade-offs.** Stubbing Resolv.getaddresses in specs rather than allowing real DNS resolution. Cost: test isolation from real DNS behaviour. Benefit: deterministic tests, no flakiness from network, no dependency on external resolvers in CI. Alternative considered: WebMock DNS stubbing (not applicable — WebMock operates at Net::HTTP, not Resolv level).

**Interfaces.**
- Consumed: `Faraday::Middleware (Faraday ~2.0 — base class for the middleware)`, `HttpChecker::Result (Data.define — returned by check)`
- Published: `SsrfGuard::BlockedIpError < Faraday::Error`, `SsrfGuard#call(env) — Faraday middleware contract`

**Self-review.**
- **metz.** ssrf_guard.rb: 72 lines including comments. blocked_literal_ip? is 5 lines, block! is 6 lines (one rescue clause). All within limits.
- **security.** DNS rebinding non-goal documented in code comment and plan. No path-string branching. Fail-closed on all error cases. BlockedIpError subclasses Faraday::Error so no unhandled exceptions escape to the job layer.
- **consistency.** Middleware pattern (f.use SsrfGuard) is idiomatic Faraday 2.x. rescue Faraday::Error in HttpChecker already covers the new subclass — zero changes to the rescue clause.

**Reviewer attention.**
- `app/services/ssrf_guard.rb:71-78` — block! raises on IPAddr::InvalidAddressError rather than skipping; verify this is the correct fail-closed behaviour for your threat model
- `app/services/ssrf_guard.rb:38-40` — fc00::/7 covers both fc00::/8 and fd00::/8; double-check the prefix length covers the intended ULA range

### Slice 4/4 — feat(security): Slice 4 — URI scheme regression lock on Site model

`421ad5f8f1` · trivial rollback · high confidence

**Intent.** Pin the Site model's http/https URL whitelist against injection schemes (javascript:, data:, file:, ftp:) as a regression lock — verified the existing validator already blocks them; spec ensures future refactors cannot silently widen the allowlist.

**Scope (1 files).**
- `spec/models/site_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/site_spec.rb — 4 parameterized examples (javascript:, data:, file:, ftp:)`

**Assumptions.**
- URI::DEFAULT_PARSER.make_regexp(%w[http https]) rejects all four injection schemes — verified in container before writing specs
- No Site.url validation patch needed because the existing format: validator already covers these cases

**Specifications established.**
- javascript:, data:, file:, ftp: schemes must remain invalid for Site#url
- Violation of this spec = the http/https whitelist was widened — intentional deviations need a companion spec update

**Trade-offs.** ["Parameterized loop style in specs: slightly less explicit but prevents copy-paste drift across 4 similar cases"]

**Interfaces.**
- Consumed: `Site#valid? — checked against http/https format regexp`

**Self-review.**
- **tests.** 4 regression examples added; each tests a distinct injection scheme against the model boundary
- **consistency.** Matches existing spec pattern — described_class.new(valid_attrs.merge(...))
- **metz.** No source files changed; spec additions are 9 lines total
- **duplication.** Parameterized loop avoids 4 copy-paste examples
- **mocking.** No mocking
- **error paths.** N/A — validation spec, not error handling
- **security.** This slice IS the security concern — injection scheme lock

**Lint.** `` → 

<details><summary>Additional fields (unknown to renderer)</summary>

```yaml
plan: delegated-crunching-crescent

```

</details>

### Slice lint-fix — fix(lint): rubocop — trailing comma + array bracket spacing

`d98cd79e81` · trivial rollback · high confidence

**Intent.** Fix rubocop violations introduced in Slices 3 and 4 that were not caught before committing.

**Scope (0 files).**


**Proof.** `bin/dc bundle exec rspec && bin/dc bundle exec rubocop` → **green**

**Tests.** Not required — Formatting-only changes; no logic touched

**Deviations from plan.** Lint was not run before committing Slices 3 and 4. Two cops fired: Style/TrailingCommaInArrayLiteral (ssrf_guard.rb BLOCKED_RANGES last entry) and Layout/SpaceInsideArrayLiteralBrackets (ssrf_guard_spec.rb stub_dns calls). Both autocorrected.

**Trade-offs.** []

<details><summary>Additional fields (unknown to renderer)</summary>

```yaml
plan: delegated-crunching-crescent

```

</details>

### Slice pr-review-fixes — fix(security): pr-review findings — cookie secure flag + passwords spec

`7a754c2dfe` · trivial rollback · high confidence

**Intent.** Address three findings from the pr-review pass: fix wrong line pointer in Slice 3 agent note, add explicit secure: true to session cookie, and add spec coverage for the PasswordsController password reset flow.

**Scope (0 files).**


**Proof.** `bin/dc bundle exec rspec && bin/dc bundle exec rubocop` → **green**

**Tests added.**
- `spec/requests/passwords_controller_spec.rb — 9 examples covering new, create (enumeration guard), edit token validation, update success/mismatch/floor/invalid-token`

**Assumptions.**
- secure: Rails.env.production? is the right conditional — test/CI environments run without HTTPS, production always does
- generate_token_for(:password_reset) is the Rails 8 API for generating reset tokens in specs

**Specifications established.**
- Session cookie must carry Secure attribute in production
- Password reset flow (new/create/edit/update) must have automated request spec coverage

**Deviations from plan.** addressing pr-review findings, not in original 4-slice plan

**Interfaces.**
- Consumed: `User#generate_token_for(:password_reset) -> String`, `User.find_by_password_reset_token!(token) -> User | raises`

**Self-review.**
- **tests.** 9 spec examples cover the full reset flow including enumeration guard and the known UX debt (wrong alert for short passwords)
- **security.** secure: Rails.env.production? makes the Secure flag explicit; enumeration guard confirmed — same notice regardless of email existence
- **metz.** passwords_controller_spec.rb: no class, method lengths n/a for spec files

<details><summary>Additional fields (unknown to renderer)</summary>

```yaml
plan: delegated-crunching-crescent

```

</details>

## Deferred concerns (registry)

_(Future schema work: aggregate from a structured `deferrals:` field._  
_For now, grep slice notes manually:_  
_`git log --show-notes=agent main..HEAD | grep -A2 -i 'multi-user\|deferred\|future epic'`)_

## Conventions established

_(Future schema work: aggregate from `principle_violations` + `self_review.consistency`._  
_For now, scan the per-slice sections above for `consistency` self_review entries.)_

