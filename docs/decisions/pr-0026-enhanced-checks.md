# PR #26 — Epic 5 — Enhanced check types

**Branch:** `feature/enhanced-checks`
**Generated from:** `ce8a93e` (squash-merge of 13 slices)
**Generated:** 2026-04-15
**Slices:** 13 (10 planned + 3 review-driven)
**Plan:** `~/.claude/plans/majestic-wibbling-brook.md`

## Context

Before this PR, dorm-guard's monitoring loop could do exactly one thing: HTTP GET + status code. That's enough for Epic 1's walking skeleton but not for real uptime monitoring. SSL certificate expiry is the #1 "my site went down" surprise. TCP port probes are the only way to monitor non-HTTP services. DNS resolution catches domain-expiry misconfiguration. Content-match catches "the server returned 200 but is serving a blank page." Beyond the new types themselves, the checker layer was hardcoded around a single class — no dispatch, no shared return contract, no place for future checkers to hook in. Epic 5 builds those seams first and then uses them, while paying down three long-flagged HTTP-checker improvements (redirect following from Epic 1's pr-review, per-site expected-status allowlist, and a slow-response `:degraded` state).

## Where this lives

- **`app/services/http_checker.rb`** — was the only checker. Used Faraday, wrapped `SsrfGuard` middleware, returned a `Data.define(...)` inner struct. After Epic 5 it's one of five checkers that all return the same top-level `CheckOutcome` struct, with an optional `follow_redirects:` kwarg and the `faraday-follow_redirects` middleware registered after `SsrfGuard` in the stack.
- **`app/services/ssrf_guard.rb`** — Faraday middleware that blocks outbound requests to private IP space. Before Epic 5, its range-check logic lived inline; today it delegates to the new `IpGuard` PORO and just translates `IpGuard::BlockedIpError` to `SsrfGuard::BlockedIpError` (a `Faraday::Error` subclass) at the Faraday boundary.
- **`app/services/ip_guard.rb`** — new. Standalone Faraday-agnostic SSRF range check that every non-Faraday checker (`TcpChecker`, `SslChecker`) calls before opening a socket. DNS-resolves the hostname, checks all resolved addresses against the blocked range list, fails closed on NXDOMAIN and unparseable addresses.
- **`app/services/check_dispatcher.rb`** — new. The single routing boundary. `CheckDispatcher.call(site) → CheckOutcome`. Case statement over `site.check_type` with one branch per check type and an `else` that raises `CheckDispatcher::UnknownCheckType` loudly.
- **`app/jobs/perform_check_job.rb`** — runs on every `Site`'s interval. Fetches the site, calls the checker via `CheckDispatcher.call(site)`, records a `CheckResult`, updates `Site.status`, and (if newly-failing) enqueues a `DowntimeAlertMailer`. `derive_status(site, result)` is the single authoritative place that maps a `CheckOutcome` + `Site` pair to a status symbol, with SSL as the documented classification exception (temporal signal owned by the checker).
- **`app/models/site.rb`** — configuration. Now carries a `check_type` enum plus seven type-specific columns (`tls_port`, `tcp_port`, `dns_hostname`, `content_match_pattern`, `slow_threshold_ms`, `expected_status_codes`, `follow_redirects`), a `before_validation :clear_irrelevant_config` callback that normalizes stale config on every save, and a `:degraded` status added at integer 4 (intentionally skipping 3 so `:down: 2` stays stable forever).
- **`app/components/site_form/`** — new directory for per-type form field components. `SiteForm::TypeFieldsComponent` dispatches to one of `{HttpOptions,Ssl,Tcp,Dns,ContentMatch}FieldsComponent` based on `site.check_type`. The shell (`site_form_component.html.erb`) renders the dispatcher once unconditionally — zero check_type branching in the shell.

## The arc

Thirteen slices in four phases. **Phase 1 (Slices 1–2)** establishes shared contracts nothing has used yet. **Phase 2 (Slices 3–7)** adds the four new check types one per slice, each using the Phase-1 contracts, then the smoke gate. **Phase 3 (Slices 8–10)** ships HTTP improvements (redirect follow + expected-status allowlist) and the `:degraded` state: Slice 9 adds `:degraded` to the enum without emission, Slice 10 emits it from HTTP (slow-response) and SSL (cert expiring 8–30 days). **Phase 4 (Slices 11–13)** landed as review-driven fixes after ChatGPT's PR review caught a priority-inversion bug in `derive_status`, a scrub gap in `clear_irrelevant_config`, and a UX regression where invalid `expected_status_codes` input was wiped on form redisplay.

## Slice 1/13 — Extract `IpGuard` + canonicalize `CheckOutcome`

Pure refactor establishing the architectural seams Slices 2–13 build on. The SSRF range-check logic lived in `SsrfGuard` as a Faraday middleware — fine for HTTP, useless for the TCP/DNS/SSL sockets that Slices 3–5 would add. The `HttpChecker::Result` struct was an inner type nobody else could use.

`IpGuard` is a new plain-Ruby class with `self.check!(host_or_ip)` doing a literal-IP fast path followed by DNS resolution and private-range assertion. It raises `IpGuard::BlockedIpError < StandardError` on failure — deliberately Faraday-free so socket-level checkers can rescue it without a Faraday dependency. `SsrfGuard` drops from 79 lines to 21: it catches `IpGuard::BlockedIpError` and re-raises as `SsrfGuard::BlockedIpError < Faraday::Error`, preserving `HttpChecker`'s existing `rescue Faraday::Error` with zero changes.

`CheckOutcome` is a top-level `Data.define` with six fields: `status_code`, `response_time_ms`, `error_message`, `checked_at`, `body` (1 MiB-truncated UTF-8 with `scrub("")` on invalid sequences), and `metadata` (a checker-specific hash where Slice 6 stashes `matched:` and Slice 10 stashes SSL's `classification:`). The struct is frozen so checkers cannot mutate an in-flight outcome.

A 9-case mutation-resistant `ip_guard_spec.rb` locks the range-check logic: literal blocked IPv4, literal public IPv4, single/multi public DNS, split-horizon mix, NXDOMAIN, unparseable resolved, IPv6 ULA, IPv6 link-local. The `ssrf_guard_spec.rb` slimmed from 18 range cases to 4 middleware-concern cases.

## Slice 2/13 — `check_type` enum + `CheckDispatcher` + `UnknownCheckType`

`Site.check_type` is a new integer-backed enum (`http=0, ssl=1, tcp=2, dns=3, content_match=4`), defaulting to `:http`. Existing rows backfill to `:http` via the migration's `null: false, default: 0`. `CheckDispatcher.call(site)` is the new single routing boundary the job calls instead of `HttpChecker.check(site.url)` directly. In Slice 2 it only routes `:http`; the other branches land in Slices 3–6.

The dispatcher's public surface is **structurally pinned** via a spec that asserts `CheckDispatcher.singleton_methods(false) == [:call]` and `CheckDispatcher.constants == [:UnknownCheckType]`. Adding a second public method or a helper constant turns the spec red on purpose, forcing a "does this logic belong in a checker or in the job?" conversation. The plan's decision 1 commits to the dispatcher as a thin routing boundary only — three responsibilities (read check_type, extract primitives, call matching checker) — and any logic that pools there is a god-object seed.

`UnknownCheckType` is raised loudly rather than falling back to HTTP. The exception bubbles out of `PerformCheckJob#perform` to Solid Queue's failed-job log instead of being swallowed into a ghost `:down` check result. Two scaffolded predicates on `Site` (`healthy?` aliasing `up?`, `failing?` aliasing `down?`) prepare for Slice 9's `:degraded` semantic where these aliases acquire load-bearing meaning. The `before_validation :clear_irrelevant_config` callback is wired here as a no-op — Slices 3–10 extend it one column at a time.

## Slice 3/13 — `SslChecker` (2-state; evolves to 3-state in Slice 10)

First alternative check type. Opens a TLS socket via `Socket.tcp(host, port, connect_timeout: 5)` + `OpenSSL::SSL::SSLSocket` wrapped in `Timeout.timeout(10)` for the handshake bound, reads `peer_cert.not_after`, and classifies by days-until-expiry. Slice 3 ships two-state (`:up` if >7 days, `:down` otherwise); Slice 10 extends it to three-state (`:up` >30, `:degraded` 8–30, `:down` <8).

**Classification lives in `SslChecker`, not `PerformCheckJob#derive_status`** — the documented ownership asymmetry from the plan's decision 3. SSL's signal is temporal (`not_after - Time.current`), and splitting the threshold logic into job code would force the job to interpret cert metadata. Every other checker returns raw signals and lets the job classify; SSL is the one deliberate exception.

`Timeout.timeout` wrapping socket ops is technically unsafe — async interrupts can leak an FD. Accepted trade-off: the `ensure` block closes both TCP and SSL sockets on normal paths, and rare FD leaks are cheaper than stuck TLS handshakes hanging the job worker. The stdlib alternative (`IO.select` + `connect_nonblock`) is much more code for a check that runs on a 60-second cadence.

A small plan-bug fix landed alongside this slice: `PerformCheckJob#derive_status` learned to handle `nil` status_code + `nil` error_message as a non-HTTP `:up` (previously `nil.between?(200, 399)` would have raised the first time an SSL check succeeded). The plan listed derive_status in the slice text but missed it from the bottom-of-slice file list.

## Slice 4/13 — `TcpChecker` + per-type form partial extraction

Second alternative check type, and the plan's trigger for extracting per-type form components. The rule from the plan's Notes section: "at the first sign of branching on check_type in more than one spot, extract per-check-type partials IMMEDIATELY." That moment is this slice, when `tcp_port` joins `tls_port` as a conditional form field.

`TcpChecker.check(host:, port:)` uses `Socket.tcp(host, port, connect_timeout: 5, &:close)` — the block form closes the socket on both normal and exception paths with no `ensure` clause needed. The rescue list covers `Errno::ECONNREFUSED`, `ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, `EADDRNOTAVAIL`, `SocketError`, and `IpGuard::BlockedIpError`. Rejected alternatives documented in the class comment: `Timeout.timeout` around `TCPSocket.new` is unsafe (async interrupts leak FDs), and reinventing `connect_nonblock` + `IO.select` reinvents what the stdlib already does correctly.

Form extraction: `SiteForm::TypeFieldsComponent` is a new ViewComponent dispatcher that case-switches on `site.check_type` and renders the matching leaf component (`SiteForm::SslFieldsComponent`, `SiteForm::TcpFieldsComponent`). The shell `site_form_component.html.erb` no longer contains any `check_type` branching — it renders `TypeFieldsComponent` once unconditionally. Slices 5–6 add DNS and content-match leaf components without touching the shell, satisfying open/closed at the view layer.

## Slice 5/13 — `DnsChecker` + `dns_hostname` + URL nullability relaxation

DNS is the first check type that isn't URL-native. A DNS check on `example.com` has no URL, no status code, no body — just "does the name resolve?" The Site schema has to accommodate that.

`DnsChecker.check(hostname:)` does one `Resolv.getaddresses` call and succeeds iff at least one address comes back. The `Site.dns_hostname` column is new; `Site.url`'s validation relaxes with `unless: :dns?` and a second migration in this slice flips `sites.url` from NOT NULL to nullable. `clear_irrelevant_config` is extended to null `url` when flipping TO `:dns` and to null `dns_hostname` when flipping AWAY from `:dns`. The form shell wraps its URL field in `<% unless site.dns? %>` — the only remaining check_type branch in the shell after Slice 4's extraction, scoped to the one field that's shared-except-DNS.

**`DnsChecker` deliberately does NOT call `IpGuard`.** A DNS check on `internal.corp` is explicitly asking "does our internal DNS still work?" — blocking resolution of private hostnames would defeat the entire point. A dedicated spec case stubs `IpGuard.check!` with `not_to receive` to regression-lock the behavior against a future "add the missing guard" refactor.

**Plan-bug fix:** the plan's Slice 5 prose said "null url when switching to DNS" but assumed the column was already nullable. Epic 1's original migration had made it NOT NULL, so `clear_irrelevant_config`'s `self.url = nil if dns?` raised `SQLite3::ConstraintException`. Added `RelaxUrlNullConstraintOnSites` migration, updated the plan file to match.

## Slice 6/13 — `ContentMatchChecker` + `content_match_pattern`

Fourth new check type. Small wrapper over `HttpChecker`: calls it, inspects the body, stores the substring match result in `metadata[:matched]` as an explicit `true`/`false`. If the HTTP call fails at the transport layer, `http_outcome` passes through unchanged — content-match inherits transport-level errors without second-guessing. Only on HTTP success does the checker run `body.to_s.include?(pattern.to_s)` and set the match flag.

**Match result in `metadata`, not `error_message`.** Decision 3 says checkers return raw signals and the job classifies. Setting `error_message` on a miss would move classification into the checker. `PerformCheckJob#derive_status` gains one new branch that reads `metadata[:matched] == false` (explicit equality, not truthiness, so HTTP/SSL/TCP/DNS sites with empty metadata are unaffected). The branch orders AFTER `error_message` (transport failures still route to `:down`) and BEFORE the HTTP 200-399 classification (so a "200 with no match" correctly flips to `:down`).

`String#include?` is O(n·m) worst case but bounded by the 1 MiB body truncation from Slice 1 and the 500-char pattern limit enforced by the model. No ReDoS risk, no regex compilation. The form helper text explicitly names the 1 MiB truncation so operators see the limit before they configure the check: "We search the first 1 MiB of the response. Patterns beyond that point will not match."

## Slice 7/13 — End-to-end smoke gate

Unit specs cover each checker in isolation. The dispatcher, job, model, and form components each have their own spec files. The integration between them — form submission → strong params → model validation → `clear_irrelevant_config` → dispatcher → checker → job → `derive_status` → status badge — has no unit test. Slice 7 pins that wiring.

`spec/system/check_types_smoke_spec.rb` uses `type: :request` (not `:system` — Capybara/browser drivers aren't configured in this project) and a shared `"a check type end-to-end"` example group. For each of `:http`, `:ssl`, `:tcp`, `:dns`, `:content_match`: POST to `/sites` with real form params, assert the Site is created, stub the checker with a happy outcome, run `PerformCheckJob.perform_now`, assert the status flipped to `:up` and the index view renders `badge-success`. Then re-stub with a failing outcome, re-run, assert `:down` and `badge-error`. One additional case covers rejected input: posting a `:tcp` site without `tcp_port` must re-render `:new` with 422 and the field label in the body.

**Network-free.** Every external boundary is stubbed — all five checker class methods — so the spec exercises the integration seams unit specs can't cover without introducing flakiness. WebMock's `disable_net_connect!(allow_localhost: true)` is already active in `rails_helper`.

## Slice 8/13 — HTTP redirect follow + expected-status allowlist

Two long-flagged HTTP-checker improvements. Redirect following was called out in Epic 1's pr-review comment ("a site returning 301/302 records that code and `derive_status` classifies as `:up` by accident"). Expected-status allowlist was called out in the Epic 5 issue body ("a site behind auth might return 401 and that's 'up'"). Paid both debts in one slice with a sprawl warning from the plan: if the diff grew past ~300 lines, split into 8a and 8b — ended up ~280 lines, kept as one slice.

`faraday-follow_redirects` added to the Gemfile. `HttpChecker.check` gains a `follow_redirects:` kwarg (default `true`); the middleware is conditionally wired into the Faraday stack **after** `SsrfGuard` so every redirect hop is re-validated against the blocked IP ranges. A structural spec in `http_checker_spec.rb` asserts the ordering via `conn.builder.handlers.map(&:klass)` and pins `ssrf_index < redirect_index` — the hop-by-hop SSRF protection can't silently regress. Hop cap is the gem default of 3 (`HttpChecker::MAX_REDIRECTS = 3`), named explicitly in the class and in the form helper text so nobody assumes unlimited.

`Site.expected_status_codes` is a JSON-serialized text column with a custom setter that parses `"200, 301"` into `[200, 301]`: comma-separated, whitespace-tolerated, integers 100–599 only, **ranges NOT supported**, invalid tokens rejected with a validation error (via an instance variable that the validator reads). `PerformCheckJob#derive_status` gains a `site` argument so it can read the allowlist.

**Allowlist semantics are full override, not additive.** If the list is `[200, 301]`, then `202` is `:down` even though it's in the default 200-399 range. Form helper says "ONLY those codes count as up." Additive semantics would be harder to document and harder to reason about.

Two intentional interface signature evolutions landed here (both flagged by agent-review's drift detector as expected): `HttpChecker.check(url)` → `HttpChecker.check(url, follow_redirects: true)` and `ContentMatchChecker.check(url:, pattern:)` → `ContentMatchChecker.check(url:, pattern:, follow_redirects: true)`. Both additive with defaults, backward-compatible for any caller passing the old signature. Documented in `deviations_from_plan`.

**Deployment-time behavior change:** `Site.follow_redirects` has a DB default of `true`, so every existing HTTP Site backfills to `follow_redirects: true` on the Slice 8 migration. On the first `PerformCheckJob` run after this PR merges, existing sites start following redirects where they previously did not. A Site monitoring `http://www.example.com/` that was recording `301 → www.example.com` as `:up` will now follow to the destination. **Accepted trade-off** per Epic 1's pr-review comment ("most users want the final destination"); anyone who was intentionally monitoring a 301 as a canary will notice the shift.

## Slice 9/13 — `:degraded` enum value (handled, not yet emitted)

Schema-add slice. `Site.status` gains `degraded: 4`. **Integer 3 is intentionally skipped** so `:down: 2` stays at 2 forever — no renumber, no data migration, no risk of silently corrupting existing rows. A round-trip spec pins `read_attribute_before_type_cast(:status) == 4` for `:degraded` rows.

`StatusBadgeComponent.CLASSES_BY_STATUS` gains `:degraded → "badge badge-warning"` (DaisyUI yellow). The Slice-2 `healthy?`/`failing?` predicates get their final semantic meaning: `:degraded` is explicitly **NEITHER healthy NOR failing**. `PerformCheckJob#notify_if_newly_down` swaps `site.down?` for `site.failing?` — no behavior change yet (`failing?` still aliases `down?`) but the predicate discipline is in place for when Slice 10's `:degraded` transitions start happening.

The migration is **documentation-only** — integer-backed enums in Rails don't require a schema change when you append a new key. The file exists so `schema_migrations` has an audit trail for when `:degraded` joined.

## Slice 10/13 — Emit `:degraded` from HTTP (slow) + SSL (expiring)

Final planned slice. Wires the two emission paths for the Slice 9 enum value.

**SSL (checker-owned, temporal exception):** `SslChecker` extends its classification from 2-state to 3-state: `days < 8 → :down` (with `error_message` set), `8..30 → :degraded` (with `error_message: nil`), `> 30 → :up`. The classification is stashed in `metadata[:classification]` and `PerformCheckJob#derive_status` reads it directly when `site.ssl?`. The 30-day warn boundary is **inclusive** (`days <= 30 → :degraded`; 31-day cert is `:up`).

**HTTP / content-match (job-owned):** new nullable `Site.slow_threshold_ms` column (validated 100..60_000). `derive_status` gains a `slow_http_response?` check: if the site is `:http` or `:content_match`, has a threshold set, and `response_time_ms` exceeds it, the classification is `:degraded`. Order is load-bearing — this check runs AFTER the `expected_status_codes` allowlist match (so a slow-but-in-allowlist response is correctly `:degraded`, not `:up`) and BEFORE the HTTP 200-399 fallback.

**Explicit non-goal:** no `:degraded` emission for `:tcp`, `:dns`, or content-match without a slow threshold. TCP and DNS are binary signals (port open/closed, hostname resolves/not). Content-match's only degraded source is the inherited HTTP slow-response path. The non-goal exists specifically to prevent "while we're here" scope creep — any further `:degraded` semantics belong to Epic 6 (alerting) or Epic 7 (dashboards).

## Slice 11/13 — Slow-response downgrade applies to allowlist success (review fix)

ChatGPT's PR review caught a priority-inversion bug in Slice 10's `derive_status` implementation that the author's self-review missed. The rule comment block above the method listed the allowlist check (rule 5) and the slow-response check (rule 6) as separate concerns, but the implementation returned from the `expected_status_codes` branch before `slow_http_response?` ran. A 200-in-allowlist response that was also slower than `slow_threshold_ms` would be marked `:up`, not `:degraded`. The Slice 8 and Slice 10 spec suites each exercised their concern in isolation and never covered the intersection.

Fix: compute an HTTP verdict first via a new `http_status_verdict(site, result)` private helper that owns both the allowlist path (full override) and the 200-399 fallback. Then apply the slow-response downgrade only when the verdict is `:up`. A `:down` HTTP verdict is final — failure trumps slowness, so a slow 500 in an allowlist-miss stays `:down`, not `:degraded`. The rule comment block was rewritten to describe the verdict-then-downgrade pattern literally rather than implying the implementation.

Two new regression-lock specs cover the exact intersection the Slice 10 suite missed: `allowlist match + slow → :degraded` (the blocker case) and `allowlist miss + slow → :down` (failure trumps slowness).

## Slice 12/13 — `clear_irrelevant_config` scrubs HTTP options (review fix)

Second PR-review finding. `clear_irrelevant_config` was claimed in the Epic 5 walkthrough narrative to "normalize stale config on every save" but only scrubbed five per-type columns and `url` for DNS sites. HTTP-only fields (`expected_status_codes`, `follow_redirects`) were left in place when flipping a Site from `:http` or `:content_match` to `:ssl`, `:tcp`, or `:dns`. Harmless at runtime today — the dispatcher ignores them for non-HTTP check types — but it contradicts the normalization claim and leaves stale config in the row.

Fix: extend the callback to null `expected_status_codes` and reset `follow_redirects` to the DB default (`true`) for any save where the check_type is not `:http` or `:content_match`. `follow_redirects` is `null: false` at the DB level so it can't be nulled — reset-to-default is the closest equivalent of "wipe stale state." Inline comment explains the constraint.

Parameterized spec across `:ssl`, `:tcp`, `:dns` flip targets (each asserting both `expected_status_codes` nulled and `follow_redirects` reset) plus a preserve-for-content-match case pinning the `:http → :content_match` flip as an HTTP-option-preserving transition (content-match wraps HttpChecker and the options stay meaningful).

## Slice 13/13 — Preserve raw `expected_status_codes` input on parse failure (review fix)

Third PR-review finding. The `expected_status_codes=` setter parses the incoming string; on `ArgumentError` it stashes the raw value in `@expected_status_codes_parse_error` and stores `nil` in the attribute. The form then renders `value: site.expected_status_codes_for_display`, which returned `""` whenever the attribute was nil — wiping the user's input on a failed submit. A bad input like `"200, foo"` would produce the validation error AND a blank field, forcing the user to retype from scratch instead of correcting the bad token.

Fix: `expected_status_codes_for_display` now returns the raw `@expected_status_codes_parse_error.to_s` when a parse error is pending, falling back to the joined array or empty string. After a failed submit the user sees their own input back with the validation error inline, matching every other field on the form.

## The big picture

**Seams.** `CheckDispatcher.call(site)` is the single routing boundary. Every checker goes through it. Its public surface is structurally pinned so future engineers who want to "add a helper" have to stop and ask whether the logic belongs in a checker or in the job. SSRF protection is `IpGuard.check!(host_or_ip)` — one call per non-Faraday checker plus one middleware delegation for the Faraday path. The Site schema has seven type-specific columns plus a `clear_irrelevant_config` callback that normalizes stale config on every save (including the HTTP options the review feedback caught in Slice 12).

**Trade-offs that shaped the architecture.**

1. **Primitive-based checker interfaces** (`host:`, `port:`, `hostname:`) not Site-based. Checkers stay unit-testable without factories, and Site schema churn doesn't cascade into checker spec edits.
2. **Enum + nullable columns** for per-type config, not STI or JSON blob. Four check types isn't enough mass to earn polymorphism. Nullable-smell mitigated by `clear_irrelevant_config`.
3. **`:degraded` at integer 4, not 3.** Skipping an integer beats silent data corruption from renumbering existing rows.
4. **Classification in the job EXCEPT for SSL.** SSL's signal is temporal and splitting into job logic would leak cert metadata interpretation up a layer. All other "what state does this Site become?" logic routes through `PerformCheckJob#derive_status`.
5. **Allowlist semantics are override, not additive.** A listed `[200, 301]` rejects `202` even though it's in the default range. Unambiguous over "clever."
6. **Health classification priority: verdict first, downgrade second.** Slice 11's refactor makes this symmetric across allowlist and 200-399 paths. Failure trumps slowness; slowness downgrades an otherwise-`:up` verdict.

**Accepted trade-offs.**

- **`faraday-follow_redirects` gem default hop cap (3).** Configurable per-site later if real usage demands it.
- **1 MiB body truncation for content-match.** Pattern beyond 1 MiB never matches; form helper names the limit explicitly so operators see it.
- **`Timeout.timeout` around TLS handshake.** Technically unsafe (async interrupt can leak an FD); ensure block closes sockets on normal paths; rare leaks cheaper than stuck handshakes hanging the job worker.
- **`follow_redirects` default `true` backfills existing HTTP rows.** Sites intentionally monitoring a 301 as a canary will notice the shift. Documented in the review response comment on PR #26.
- **Two `BlockedIpError` classes** (one `StandardError`, one `Faraday::Error`). Preserves HttpChecker's existing rescue contract without introducing a Faraday dependency for socket-level checkers.

**Open questions / deliberately deferred.**

- `Site` is 128 lines after Slice 13 — over Metz's 100-line limit. Post-epic chore, likely extracting `HttpOptions` / `ResourceConfig` value objects or an attribute-type approach for the parsing setter.
- Six `SiteForm::*FieldsComponent` leaves share near-identical class bodies. Base-class extraction filed as a follow-up.
- DNS rebinding protection still deferred (noted in `ip_guard.rb` comments). Future security epic.
- No regex support for content-match. Separate issue if real usage demands it.
- `:degraded` alerting. Deliberately silent in this epic — Epic 6 owns multi-channel + severity-aware notifications.
- Recovery notifications (`:down → :up`), alert dedup, quiet hours — all Epic 6.
- Response-time charts, uptime percentages, public status pages, incident timelines — all Epic 7.

**Lessons captured from the PR review.**

The blocker bug in `derive_status` ordering is worth naming explicitly: three guardrails (the agent-note priority list, the in-code rule comment block, and the per-branch specs) all let the bug through because none of them exercised the intersection of `expected_status_codes` and `slow_threshold_ms`. The note *stated* the intended priority order correctly; the specs covered each branch in isolation; the code put the allowlist return before the slow check. The code is the tiebreaker in practice, so the rule comment and the specs need to be literal about the branch order — "rule 5 before rule 6 is a bug" is not something you can catch from a prose description, only from an intersection test. Added to the post-epic follow-up list: any job-level classification method with more than 3 branches deserves a spec matrix, not a one-case-per-rule arrangement.

The metz-count claims in the Slice 8 and Slice 10 notes (`15 methods` when actual was 8; `11 methods` when actual was 10; `9 methods` when actual was 7) were estimated rather than measured. pr-review caught this and the notes were amended in place via `git notes add -f` with a `**Lesson: run wc -l and grep -c '^\s*def ' rather than eyeballing the diff.**` annotation. The senior-review skill explicitly says "measure numeric claims, don't estimate them" — this epic was three separate violations in a row and the correction is to run the measurement every time.

*LLM walkthrough generated from the `refs/notes/agent` chain. For teaching/orientation. Run `pr-review` on any follow-up branch for an accuracy-focused fact-check pass.*

## Slices

### Slice 1/13 — refactor(checker): Slice 1 — extract IpGuard + CheckOutcome

`80d7067c61` · refactor · reversible rollback · high confidence · additive

**Intent.** Extract `IpGuard` and `CheckOutcome` so Slices 2–10 build on stable shared contracts: a Faraday-agnostic SSRF range check and a canonical checker return value with body + metadata.

**Scope (9 files).** `app/services/check_outcome.rb`, `app/services/ip_guard.rb`, `app/services/ssrf_guard.rb`, `app/services/http_checker.rb`, `spec/services/check_outcome_spec.rb`, `spec/services/ip_guard_spec.rb`, `spec/services/ssrf_guard_spec.rb`, `spec/services/http_checker_spec.rb`, `spec/jobs/perform_check_job_spec.rb`.

**Key specifications.** `CheckOutcome` has exactly six frozen fields; `HttpChecker` body truncated to 1 MiB bytes, UTF-8 force-encoded, `scrub("")` drops invalid sequences; `IpGuard.check!` fails closed on NXDOMAIN and unparseable resolved addresses, blocks any single-private in a multi-address resolution (split-horizon guard); `SsrfGuard::BlockedIpError < Faraday::Error` preserves HttpChecker's existing rescue clause; literal public IPs short-circuit the Resolv lookup that the pre-slice code performed redundantly.

**Deviations.** Small behavior change documented as deliberate: literal public IPs now skip `Resolv.getaddresses`, which the plan's 9-case mutation-resistant spec gate explicitly required (case 2: "literal public IP passes, no DNS lookup attempted").

### Slice 2/13 — feat(checker): Slice 2 — check_type enum + CheckDispatcher

`c486ab5160` · feature · entangled rollback · high confidence · additive

**Intent.** Introduce `check_type` enum + `CheckDispatcher` so all checker calls flow through one thin routing boundary, with loud failure on unknown types and scaffolded seams for later per-type config scrubbing.

**Scope (8 files).** `db/migrate/20260414171235_add_check_type_to_sites.rb`, `db/schema.rb`, `app/models/site.rb`, `app/services/check_dispatcher.rb`, `app/jobs/perform_check_job.rb`, `spec/services/check_dispatcher_spec.rb`, `spec/models/site_spec.rb`, `spec/jobs/perform_check_job_spec.rb`.

**Key specifications.** `CheckDispatcher.call(site)` raises `CheckDispatcher::UnknownCheckType` for any check_type not explicitly routed — no silent fallback; structural spec pins `singleton_methods(false) == [:call]` and `constants == [:UnknownCheckType]`; `UnknownCheckType` bubbles out of `PerformCheckJob#perform` rather than being swallowed; `Site#healthy? := up?`, `Site#failing? := down?` (3-state meaning — `:degraded` is deliberately neither once Slice 9 lands); `before_validation :clear_irrelevant_config` wired as a no-op, extended per-column by Slices 3–12.

### Slice 3/13 — feat(checker): Slice 3 — SslChecker (cert expiry, 2-state)

`c2243b6e01` · feature · entangled rollback · high confidence · additive

**Intent.** Land the first alternative check type (SSL cert expiry) so the dispatcher routes end-to-end and the `IpGuard` reuse pattern is proven for non-Faraday sockets.

**Scope (15 files).** `app/services/ssl_checker.rb`, `db/migrate/20260414195125_add_tls_port_to_sites.rb`, `db/schema.rb`, `app/models/site.rb`, `app/services/check_dispatcher.rb`, `app/jobs/perform_check_job.rb`, `app/components/site_form_component.{html.erb,rb}`, `app/controllers/sites_controller.rb`, `spec/services/{ssl_checker,check_dispatcher}_spec.rb`, `spec/models/site_spec.rb`, `spec/jobs/perform_check_job_spec.rb`, `spec/components/{previews/,}site_form_component_spec.rb`.

**Key specifications.** `SslChecker.check(host:, port:)` derives host from `URI.parse(site.url).host`; classification (expired / <7 days / OK) lives in the checker per decision 3's temporal-signal exception; `IpGuard.check!(host)` runs before any socket open (regression-locked by a spec that stubs `IpGuard` to raise and asserts `Socket.tcp` is never called); `PerformCheckJob#derive_status` handles `nil status_code + nil error_message` as `:up` for non-HTTP checks.

**Deviations.** Three files added beyond the plan's Slice 3 list (`perform_check_job.rb` + its spec + `site_form_component_spec.rb`); prose described them but bottom-of-slice file list omitted them. Plan file updated in place.

### Slice 4/13 — feat(checker): Slice 4 — TcpChecker + per-type form partial extraction

`a725178630` · feature · entangled rollback · high confidence · additive

**Intent.** Add `TcpChecker` and extract per-check-type form components so `SiteFormComponent` shell stops branching on `check_type` (plan-mandated refactor when the second conditional field lands).

**Scope (19 files).** `app/services/tcp_checker.rb`, `db/migrate/20260414200003_add_tcp_port_to_sites.rb`, `db/schema.rb`, `app/models/site.rb`, `app/services/check_dispatcher.rb`, `app/components/site_form_component.{html.erb,rb}`, `app/components/site_form/{type,ssl,tcp}_fields_component.{rb,html.erb}`, `app/controllers/sites_controller.rb`, `spec/services/{tcp_checker,check_dispatcher}_spec.rb`, `spec/models/site_spec.rb`, `spec/components/{site_form_component_spec,previews/site_form_component_preview}.rb`.

**Key specifications.** `TcpChecker` uses `Socket.tcp(host, port, connect_timeout: N, &:close)` — NOT `Timeout.timeout` around `TCPSocket.new` (unsafe), NOT `connect_nonblock` + `IO.select` (reinventing stdlib); `SiteFormComponent` renders `SiteForm::TypeFieldsComponent` once unconditionally; `TypeFieldsComponent` is the only place in the form stack that branches on `site.check_type`.

### Slice 5/13 — feat(checker): Slice 5 — DnsChecker + dns_hostname column

`7547297972` · feature · entangled rollback · high confidence · additive

**Intent.** Add `DnsChecker` and the `dns_hostname` column so pure-DNS checks work end-to-end, including the url-optional-for-DNS validation relaxation and form plumbing.

**Scope (17 files).** `app/services/dns_checker.rb`, `db/migrate/20260414203658_add_dns_hostname_to_sites.rb`, `db/migrate/20260414203901_relax_url_null_constraint_on_sites.rb`, `db/schema.rb`, `app/models/site.rb`, `app/services/check_dispatcher.rb`, `app/components/site_form_component.{html.erb,rb}`, `app/components/site_form/{type,dns}_fields_component.{html.erb,rb}`, `app/controllers/sites_controller.rb`, `spec/services/{dns_checker,check_dispatcher}_spec.rb`, `spec/models/site_spec.rb`, `spec/components/{site_form_component_spec,previews/site_form_component_preview}.rb`.

**Key specifications.** `DnsChecker` deliberately does NOT call `IpGuard` — DNS resolution of private hostnames is a legitimate monitoring goal; `Site.url` presence and format validation are skipped when `check_type == :dns`; sites.url column relaxed from `NOT NULL` to nullable via a second migration in this slice (plan-bug fix — Epic 1 had made it NOT NULL but the plan prose assumed it was already nullable); `Site#clear_irrelevant_config` nulls `dns_hostname` for non-`:dns` saves and nulls `url` for `:dns` saves.

### Slice 6/13 — feat(checker): Slice 6 — ContentMatchChecker + content_match_pattern

`a3b050481a` · feature · entangled rollback · high confidence · additive

**Intent.** Add `ContentMatchChecker` (the fourth and final new check type) that wraps `HttpChecker` and asserts a pattern appears in the response body, with match-result classification flowing through metadata per decision 3.

**Scope (17 files).** `app/services/content_match_checker.rb`, `db/migrate/20260414204701_add_content_match_pattern_to_sites.rb`, `db/schema.rb`, `app/models/site.rb`, `app/services/check_dispatcher.rb`, `app/jobs/perform_check_job.rb`, `app/components/site_form/{type,content_match}_fields_component.{html.erb,rb}`, `app/components/site_form_component.rb`, `app/controllers/sites_controller.rb`, `spec/services/{content_match_checker,check_dispatcher}_spec.rb`, `spec/jobs/perform_check_job_spec.rb`, `spec/models/site_spec.rb`, `spec/components/{previews/,}site_form_component_spec.rb`.

**Key specifications.** `ContentMatchChecker` passes HTTP failures through unchanged — content-match inherits transport-level failures; sets `metadata[:matched]` to an explicit `true` or `false`; does NOT set `error_message` on a match miss — classification stays in the job via `metadata[:matched] == false`; the explicit equality check preserves HTTP/SSL/TCP/DNS sites with empty metadata unaffected; the 1 MiB truncation false-negative risk is named in the form helper text.

### Slice 7/13 — test(checker): Slice 7 — end-to-end smoke gate

`b5f500eb4b` · test · trivial rollback · high confidence

**Intent.** Pin the end-to-end wiring for all four new check types with a network-free smoke gate that exercises form → model → dispatcher → job → index badge across one happy and one sad path per type.

**Scope (1 file).** `spec/system/check_types_smoke_spec.rb`.

**Key specifications.** All five checker service class methods stubbed at class level — network-free per the plan's locked rule; 5 happy-sad arcs (one per check_type) plus one rejected-input case; uses `type: :request` not `:system` because Capybara/browser drivers aren't configured.

### Slice 8/13 — feat(checker): Slice 8 — HTTP redirect following + expected status allowlist

`1ec3c22172` · feature · entangled rollback · high confidence · additive

**Intent.** Pay down Epic 1's redirect-follow carry-forward and add the per-site `expected_status_codes` allowlist, with middleware ordering pinned and parsing semantics locked.

**Scope (18 files).** `Gemfile`, `Gemfile.lock`, `db/migrate/20260414235028_add_http_options_to_sites.rb`, `db/schema.rb`, `app/services/http_checker.rb`, `app/services/content_match_checker.rb`, `app/services/check_dispatcher.rb`, `app/jobs/perform_check_job.rb`, `app/models/site.rb`, `app/components/site_form/{http_options,type}_fields_component.{rb,html.erb}`, `app/controllers/sites_controller.rb`, `spec/services/{http_checker,content_match_checker,check_dispatcher}_spec.rb`, `spec/jobs/perform_check_job_spec.rb`, `spec/models/site_spec.rb`.

**Key specifications.** `HttpChecker.check` takes url positionally plus `follow_redirects:` keyword (default true); `Faraday::FollowRedirects::Middleware` registered after `SsrfGuard` (structural spec pins `ssrf_index < redirect_index` via `conn.builder.handlers.map(&:klass)`); hop cap is `HttpChecker::MAX_REDIRECTS = 3` matching gem default; `expected_status_codes` is an OVERRIDE when set — 202 is `:down` if the list is [200, 301] even though 202 is in the default 200-399 range; ranges like `"200-299"` are rejected; invalid tokens raise validation errors; `Site#follow_redirects` has DB default true, NOT NULL — existing pre-Slice-8 rows backfill to true.

**Deviations.** Two deliberate interface signature evolutions flagged by agent-review: `HttpChecker.check` and `ContentMatchChecker.check` both gained `follow_redirects:` kwargs with defaults. Additive, backward-compatible for existing callers. Drift detector firing is the expected signal per the skill's "intentional evolution = flagged + documented" rule.

### Slice 9/13 — feat(status): Slice 9 — :degraded enum value (handled, not emitted)

`8a693b285e` · feature · entangled rollback · high confidence · additive

**Intent.** Append `:degraded` to `Site.status` at integer 4 and thread it through every status-aware code path (badge component, alert guard, predicates) without yet emitting it — Slice 10 will wire HTTP and SSL emission paths.

**Scope (8 files).** `db/migrate/20260415001502_add_degraded_to_site_status.rb`, `app/models/site.rb`, `app/components/status_badge_component.rb`, `app/jobs/perform_check_job.rb`, `spec/models/site_spec.rb`, `spec/components/status_badge_component_spec.rb`, `spec/components/previews/status_badge_component_preview.rb`, `spec/jobs/perform_check_job_spec.rb`.

**Key specifications.** `Site.status` is 4-state: `unknown=0, up=1, down=2, degraded=4`; integer 3 intentionally left unused — do NOT renumber existing values; `Site#degraded?` true when status is `:degraded`; `Site#healthy? := up?` (unchanged); `Site#failing? := down?` (unchanged — `:degraded` is explicitly NOT failing); `read_attribute_before_type_cast(:status)` returns 4 for `:degraded` rows (pinned by spec); `StatusBadgeComponent` renders `:degraded` with `badge badge-warning`; `notify_if_newly_down` uses `site.failing?` instead of `site.down?` for Slice-10 forward compat.

### Slice 10/13 — feat(checker): Slice 10 — emit :degraded from HTTP (slow) and SSL (expiring)

`dd7c471880` · feature · entangled rollback · high confidence · additive

**Intent.** Wire `:degraded` emission from HTTP (slow response) and SSL (cert expiring in 8–30 days), closing Epic 5's planned code scope.

**Scope (10 files).** `db/migrate/20260415001849_add_slow_threshold_ms_to_sites.rb`, `db/schema.rb`, `app/jobs/perform_check_job.rb`, `app/services/ssl_checker.rb`, `app/models/site.rb`, `app/components/site_form/http_options_fields_component.html.erb`, `app/controllers/sites_controller.rb`, `spec/jobs/perform_check_job_spec.rb`, `spec/services/ssl_checker_spec.rb`, `spec/models/site_spec.rb`.

**Key specifications.** HTTP slow-response classification: `site.http?`/`content_match?` AND `site.slow_threshold_ms.present?` AND `result.response_time_ms > threshold` → `:degraded`; SSL cert classification in-checker (temporal exception) with thresholds `<8 → :down`, `8..30 → :degraded`, `>30 → :up`; SSL stashes in `metadata[:classification]`; job reads it for `:ssl` sites; 30-day warn boundary is inclusive; explicit non-goal: no `:degraded` for `:tcp`, `:dns`, or content-match without slow_threshold_ms.

### Slice 11/13 — fix(checker): Slice 11 — slow-response downgrade applies to allowlist success

`6a796b01cc` · fix · reversible rollback · high confidence · breaking

**Intent.** Fix PR #26 review blocker: `derive_status` was short-circuiting the slow-response check whenever the `expected_status_codes` allowlist matched, so a 200-in-allowlist slow response was returning `:up` instead of `:degraded`.

**Scope (2 files).** `app/jobs/perform_check_job.rb`, `spec/jobs/perform_check_job_spec.rb`.

**Key specifications.** HTTP status classification is a two-step process: compute a bottom-line `:up`/`:down` verdict via `http_status_verdict`, then apply slow-response as a downgrade only when the verdict is `:up`; `:down` HTTP verdict is final — failure trumps slowness (a slow 500 in an allowlist=[200,301] site stays `:down`); `:up` HTTP verdict is downgraded to `:degraded` iff `slow_http_response?(site, result)` returns true; rule comment above `derive_status` now describes the verdict-then-downgrade pattern literally.

**Deviations.** Review-driven slice, not a planned slice from `majestic-wibbling-brook`. Addresses #26.

### Slice 12/13 — fix(checker): Slice 12 — clear_irrelevant_config scrubs HTTP options

`b6a23080e2` · fix · reversible rollback · high confidence · additive

**Intent.** Fix PR #26 review follow-up: `clear_irrelevant_config` left HTTP-only config (`expected_status_codes`, `follow_redirects`) in place when flipping a Site from `:http`/`:content_match` to `:ssl`/`:tcp`/`:dns`, contradicting the "normalizes stale config on every save" claim.

**Scope (2 files).** `app/models/site.rb`, `spec/models/site_spec.rb`.

**Key specifications.** `clear_irrelevant_config` nulls `expected_status_codes` whenever check_type is not `:http` or `:content_match`; resets `follow_redirects` to true (DB default) whenever check_type is not `:http` or `:content_match` (can't null — column is `null: false`); flipping from `:http` with custom options to `:content_match` preserves both fields (content-match wraps HttpChecker).

### Slice 13/13 — fix(checker): Slice 13 — preserve raw expected_status_codes input on parse failure

`d8e5b192c8` · fix · trivial rollback · high confidence

**Intent.** Fix PR #26 review UX bug: a parse failure on `expected_status_codes` wiped the user's input on form redisplay, forcing them to retype the bad input from scratch.

**Scope (2 files).** `app/models/site.rb`, `spec/models/site_spec.rb`.

**Key specifications.** `expected_status_codes_for_display` returns the raw `@expected_status_codes_parse_error` value (as a String via `to_s`) when a parse error is pending, otherwise the joined array or empty string; after a parse failure the attribute is nil BUT the display helper returns the original bad input so the user sees their own text on the re-rendered form.

## Deferred concerns (registry)

- **`Site` model decomposition** — 128 lines after Slice 13. Extract `HttpOptions` / `ResourceConfig` value objects or move the parsing setter to an ActiveModel attribute type. Post-epic chore.
- **`SiteForm::*FieldsComponent` base class** — six leaves share near-identical class bodies (initialize, attr_reader, field_error helper). Extract a `SiteForm::FieldsComponent` base class with one optional override for the field_error helper. Follow-up issue.
- **DNS rebinding protection** — still deferred. Noted in `ip_guard.rb` comments. Future security epic.
- **Regex support for content-match** — out of scope for Epic 5. Separate issue if real usage demands it.
- **`:degraded` alerting** — deliberately silent in this epic. Epic 6 owns multi-channel + severity-aware notifications.
- **Recovery notifications** (`:down → :up`, `:degraded → :up`), alert dedup, flap detection, quiet hours — Epic 6.
- **Response-time charts**, uptime percentages, public status pages, incident timelines — Epic 7.
- **`follow_redirects` default-true backfill behavior change** — existing HTTP sites will start following redirects on the first post-merge job run. Accepted trade-off per Epic 1's pr-review comment ("most users want the final destination"); documented in PR #26's response comment.
- **Spec matrix for job-level classification** — the Slice 11 blocker slipped through because per-branch specs didn't exercise the intersection of flags. Any `derive_status`-shaped method with more than 3 branches should get a spec matrix, not a one-case-per-rule arrangement.

## Conventions established

- **Checker interface shape.** Every checker: `self.check(**primitives)` class method → instance method of the same name → private helpers. `RECOVERABLE_ERRORS` frozen constant used in `rescue *` clauses. `CheckOutcome` as the return type, always — 6 fields, all populated even if `nil`/`{}`.
- **Classification ownership rule.** `PerformCheckJob#derive_status(site, result)` is the single authoritative place that maps a `CheckOutcome` + `Site` pair to a status symbol. Exception: `SslChecker` owns its own classification via `metadata[:classification]` because the signal is temporal. Any future checker that wants checker-owned classification must justify the exception in its own agent-note.
- **Dispatcher discipline.** `CheckDispatcher` is a thin routing boundary only: read `check_type`, extract primitives, call the checker. No validation, no status derivation, no fallback, no retry, no logging, no defaults. Enforced structurally by `spec/services/check_dispatcher_spec.rb` asserting `singleton_methods(false) == [:call]` + `constants == [:UnknownCheckType]`.
- **Field-meaningfulness matrix + staleness normalization.** Every per-type column is either meaningful or must-be-blank for each check type. `before_validation :clear_irrelevant_config` is the single authoritative scrub point. Not strong_params scrubbing (would miss console writes, seeds, migrations).
- **Enum integer assignment.** Never renumber existing integer values. Append new values at the next unused integer, even if it means gaps. `:degraded: 4` skipping `3` is the load-bearing example.
- **Form component extraction trigger.** At the first sign of branching on `check_type` in more than one spot, extract per-type partials immediately. Slice 4 was the trigger; Slices 5–6 added new types without touching the shell.
- **Network-free specs.** Every checker spec stubs its external boundary (`Socket.tcp`, `OpenSSL::SSL::SSLSocket`, `Resolv.getaddresses`, Faraday adapter). WebMock's `disable_net_connect!(allow_localhost: true)` is already active. The smoke spec stubs checker class methods at the integration level.
- **Middleware ordering is security-critical.** `SsrfGuard` MUST be before any redirect-following middleware in the Faraday stack. A structural spec pins the ordering (`ssrf_index < redirect_index`) — the hop-by-hop SSRF protection can't silently regress.
- **Measure, don't estimate.** The Slice 8 and Slice 10 metz claims were estimated (15 methods claimed vs 8 actual; 11 vs 10; 9 vs 7) and the PR review caught them. Amended in place via `git notes add -f` with a `Lesson: run wc -l and grep -c '^\s*def ' rather than eyeballing the diff` annotation. Run the measurement every time a numeric claim goes into `self_review.metz`.
