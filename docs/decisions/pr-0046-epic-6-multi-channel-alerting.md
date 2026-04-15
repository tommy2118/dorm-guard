# PR #46 — Epic 6 — Multi-channel alerting

**Branch:** `feature/epic-6-multi-channel-alerting`  
**Generated from:** `90b3f26bfe`  
**Generated:** 2026-04-15  
**Slices:** 14

## Context

`dorm-guard` is a Rails 8 uptime monitor. Before this PR, "alerting" meant exactly one thing: every time `PerformCheckJob` observed a site transition from `:up` (or `:unknown`) to `:down`, it enqueued `DowntimeAlertMailer.site_down` and sent a single email to a hardcoded `ENV["DORM_GUARD_ALERT_TO"]` recipient. That's the whole alert story. No recovery notifications. No Slack. No webhooks. No way to configure anything per-site. And — critically — `:degraded` existed as a status but no alert path for it.

This works in a demo. It does not work operationally. Real ops teams live in Slack, not their inbox. Real sites flap, and a single-check blip shouldn't page anyone. Real on-call schedules need quiet hours for non-critical events. And real alert pipelines need to cope with a channel going down — if Slack is broken, email should still fire, and the system shouldn't retry the broken channel every 30 seconds.

Epic 6 closes every one of those gaps.

## Where this lives

If you've never seen dorm-guard before, the files you'll want to orient against first are:

- [`app/models/site.rb`](app/models/site.rb) — the central domain entity. A `Site` is a thing being monitored. It has a `status` enum (`unknown / up / down / degraded`), a `check_type` (http, ssl, tcp, dns, content_match), and per-check configuration. Epic 6 adds alert-noise-control attributes on top.
- [`app/jobs/perform_check_job.rb`](app/jobs/perform_check_job.rb) — the background job that runs one check against one site and persists the result. This is where the alert hook lives. Before Epic 6 it called `notify_if_newly_down` inline; after Epic 6 it delegates to a dispatcher.
- `app/services/` — where the business-logic seams live. `HttpChecker`, `CheckDispatcher` (Epic 5), `SsrfGuard` (Epic 4 Faraday middleware), and — new in this PR — `AlertDispatcher` and `app/services/alert_channels/{base,email,slack,webhook}.rb`.
- [`app/components/`](app/components) — this project uses [ViewComponent](https://viewcomponent.org/) for every view concern. Every card / form / badge / list in the UI is a component with a matching preview under [`spec/components/previews/`](spec/components/previews) (browse them live at `/lookbook` in dev). DaisyUI + Tailwind 4 for styling.

The PR touches all four of those areas. The model grows three sets of new attributes; the job gets rewired; two new service classes land with three concrete channel implementations; two new view components plus a nested CRUD controller hang off the existing sites surface.

## The arc

Epic 6 ships 11 slices (plus one rubocop cleanup chore), but the spine is three pieces stacked in order:

1. **Model infrastructure** (slices 1–3) — a new `AlertPreference` record, per-event cooldown state on `Site`, and a debounce mechanism that keeps a single-check blip from committing a status change.
2. **Channels + routing** (slices 4–7b) — an abstract channel contract, three concrete channels (email / Slack / generic webhook), a central `AlertDispatcher` service that decides *what* to fire and *who* to notify, and the wiring into `PerformCheckJob`.
3. **User-facing surface** (slices 8a–9) — form fields on the existing Site edit page, a new nested-route CRUD for `AlertPreference`, and seeds that give a fresh dev environment a working Epic 6 sandbox.

Each slice is committed independently with an attached agent-note (`refs/notes/agent`). Run `~/.claude/bin/agent-review main..HEAD` to see them all in context.

## Slice 1 — `AlertPreference` model + migration

**Why this slice exists.** A `Site` needs to carry routing information: which channels, whose address, which events. Epic 4 locked in a single-admin + global-sites model, so per-user preferences don't apply — but per-site preferences absolutely do. A marketing site and a payment API on the same dashboard need different alert trees.

**What changed.** A new `AlertPreference` ActiveRecord model (`belongs_to :site`) with four load-bearing columns: `channel` (an integer enum mapping `email: 0, slack: 1, webhook: 2`), `target` (a single string column that holds an email address *or* an https URL depending on the channel), `events` (a JSON-serialized array of event atoms — subset of `%w[down up degraded]`), and `enabled` (a boolean with default `true`). The `events` column uses the same `serialize :events, coder: JSON, type: Array` pattern Epic 2 established for `Site#expected_status_codes`, so you're seeing a consistency win rather than a new convention.

The target validation is worth a close read. It's not a single regex — it's a channel-switched validator that parses URLs with `URI.parse` and asserts three things independently: scheme must be `https`, host must be non-blank, and `userinfo` must be nil. That lets the model produce distinct error messages for `http://` (wrong scheme), `https:///path` (no host), and `https://user:pass@host/path` (userinfo present), which is both more intention-revealing and easier to debug than a single opaque regex match. The cost is a handful of extra lines in the model; the win is that when this surface grows in Epic 7+, the validator doesn't need a regex rewrite.

**Key decision.** `target` is a single polymorphic string column, not three channel-specific columns or STI. Three channels sharing the same shape (a destination string + an events array + an enabled flag) meant STI would have added three classes for zero behavioral win. Future migration to split channels into their own tables, if it ever becomes necessary, is a three-line rename.

## Slice 2 — `Site` noise controls (cooldown + quiet hours)

**Why.** Routing is only half the story. Even with perfect routing, a flapping site can generate a hundred alerts in ten minutes. This slice gives `Site` the state it needs for two independent noise-reduction mechanisms: cooldown (don't re-alert about the same event) and quiet hours (suppress non-critical events during configured windows).

**What changed.** Five new attributes on `Site`: `last_alerted_events` (a JSON hash mapping `"down" / "up" / "degraded"` to an ISO8601 timestamp), `cooldown_minutes` (integer, default 5), and three quiet-hours columns (`quiet_hours_start`, `quiet_hours_end`, `quiet_hours_timezone`). Three new instance methods anchor the contract: `Site#alert_cooldown_expired?(event)`, `Site#record_alert_sent!(event)`, and `Site#in_quiet_hours?`.

`in_quiet_hours?` is the subtlest method in this slice. It has to handle three distinct cases: no configured window (return false), same-day window (`09:00–17:00`), and overnight window that wraps past midnight (`22:00–06:00`). The implementation converts everything to integer seconds-since-midnight and branches on whether `start <= end`. Boundary semantics are inclusive-start, exclusive-end, and DST transitions in `America/New_York` are tested explicitly because the Rails `TimeZone` layer handles the clock jumps for you — but only if you actually `.in_time_zone(zone)` before comparing. Miss that step and spring-forward silently delivers a one-hour gap.

**Key decision — worth arguing about during review.** Cooldown is **event-level, not channel-level**. The motivation was a reviewer blocker during planning: a single global `last_alert_at` field would let a low-priority email at T=0 silently suppress a `:down` Slack alert at T+1min — starvation across event types. Per-event cooldown prevents that. But it does *not* prevent starvation across channels for the same event: a partial success (email fires, Slack raises) records the cooldown just like a full success, so the broken Slack URL won't be retried until either cooldown expires or a new transition occurs. The rationale is in the decisions table above. True channel independence would require per-`AlertPreference` cooldown storage, and that was explicitly deferred.

## Slice 3 — `Site` debounce (candidate_status + propose_status)

**Why.** A single check that happens to hit a 500 — maybe during a deploy window, maybe a transient network blip — shouldn't produce a `site_down` email and then a `site_recovered` email thirty seconds later. That's noise, not signal. This slice adds a minimum-viable debounce: require two consecutive same-status checks before committing a status change.

**What changed.** Two new `Site` attributes: `candidate_status` (reuses the same integer enum mapping as `status`) and `candidate_status_at` (a timestamp so operators debugging flapping sites can tell when the pending candidate started). One new method: `Site#propose_status(new_status)`. The method implements the full N=2 rule in fifteen lines: if the incoming status matches the already-confirmed status, clear any pending candidate and no-op; if it matches the pending candidate, commit the flip; otherwise stash the incoming status as the new candidate.

**Key decision.** `propose_status` mutates `self` in memory only — it does **not** call `save`, does **not** touch `updated_at`, and returns the proposed effective status as a string. The caller (slice 7b's `PerformCheckJob#update_site`) owns persistence. This keeps the job's transaction boundary explicit and means the method is trivially unit-testable without a database round-trip per example. The spec pins this explicitly with an assertion that `updated_at` doesn't change after calling `propose_status` on a persisted record.

The trade-off worth naming: a brand-new site now takes two check cycles to commit its first real status. The UI shows "unknown" for an extra 30–60 seconds on first run. Accepted; documented in the open-design-notes section of the plan.

**Cold-reader trap.** The model declares `enum :candidate_status, { unknown: 0, up: 1, down: 2, degraded: 4 }, prefix: :candidate, allow_nil: true`. The `prefix: :candidate` is load-bearing — without it, Rails' enum would generate scope methods like `Site.up` and `Site.down` that collide with the existing `status` enum's scopes. The `allow_nil: true` is load-bearing too — a site with no pending candidate is the normal state, and the enum would otherwise refuse to accept nil. Both come from a half-hour of staring at enum collision errors in the console; flag either of these and the whole slice falls over.

## Slice 4 — Mailer actions + `AlertChannels::Email` + the contract shared example

**Why.** Before Epic 6, `DowntimeAlertMailer` had exactly one action (`site_down`). Epic 6 needs three: down, recovered, and degraded. And the three channels this PR adds need a common shape so `AlertDispatcher` can call them uniformly.

**What changed.** Three mailer actions (`site_down`, `site_recovered`, `site_degraded`) with matching `.html.erb` + `.text.erb` templates. The mailer itself now resolves its recipient via a three-level fallback: `params[:recipient]` (per-preference override — new in Epic 6), then `ENV["DORM_GUARD_ALERT_TO"]` (Epic 3's single-recipient mode), then a hardcoded `alerts@dorm-guard.local` dev default. Epic 3's existing behavior is preserved when no per-preference recipient is passed, so this slice is purely additive.

Alongside the mailer, this slice lands the first half of the channel infrastructure: a new `AlertChannels` module (holding `EVENTS` and `DeliveryError`), an abstract `AlertChannels::Base` class, and the first concrete channel `AlertChannels::Email`. `Base` is deliberately minimal — a single method that raises `NotImplementedError`. No template methods, no callbacks, no ceremony. It exists only to pin the interface signature; if it ever starts accumulating logic, that logic probably belongs on the concrete channels.

**Key decision.** `AlertChannels::Email#deliver` maps events to mailer actions via a case statement (`"down" → :site_down`, `"up" → :site_recovered`, `"degraded" → :site_degraded`) and raises `DeliveryError` for anything unsupported. That makes every unmapped event a loud failure instead of a silent no-op — if a future slice adds a new event atom, the channel fails fast and the spec catches it.

The new `spec/support/alert_channel_contract.rb` holds a `shared_examples "an alert channel"` block that every concrete channel spec runs via `it_behaves_like`. Today it pins the method name, the keyword signature, and the error class — it does not assert actual delivery behavior, because that would require WebMock/mailer fixtures that bleed across channel-specific concerns. If slice 7a's partial-success contract ever grows a new cross-channel invariant, the shared example is where it'd land.

## Slice 5 — `AlertChannels::Slack` *(with a retroactive contract fix)*

**Why.** Slack is where ops teams actually live. If Epic 6 doesn't ship Slack on day one, it's an email-only upgrade and not worth the complexity.

**What changed.** A new `AlertChannels::Slack` class. Built-in Faraday with `SsrfGuard` middleware mounted and explicit 5s open / 10s read timeouts (copied from `HttpChecker`'s construction pattern — if you haven't read [`app/services/http_checker.rb`](app/services/http_checker.rb), it's worth a glance to see where the numbers come from). The channel POSTs a JSON payload with a **locked text field** (`"[dorm-guard] <name> is <event>"`) and optional `blocks` for rich Slack rendering. The text field is always present, guaranteed — any Slack client that can't render blocks falls back gracefully.

**The deviation worth noticing.** Slice 5's declared scope was "Slack channel only." Actual scope spilled into six slice-4 files. The reason: slice 4 shipped `AlertChannels::Base#deliver` with a three-keyword signature (`site:, event:, check_result:`) that could not express *which* webhook URL to POST to. Slack needs to know its own target; webhook does too. Making Slack the only channel with a four-keyword signature would have broken the shared contract that slice 4 had just established. So slice 5 retroactively adds `target:` to `Base`, `Email`, the mailer (via `params[:recipient]`), the shared-examples file, and the email + mailer specs — all in one atomic commit. The self-declared drift is noted in the slice's agent-note; reviewer feedback welcome on whether this should have been split into 5a (contract fix) + 5b (Slack channel) instead.

**SSRF subtlety.** `hooks.slack.com` resolves to public AWS IPs and isn't in `IpGuard::BLOCKED_RANGES`, so real Slack webhooks pass the SSRF check trivially. The guard still runs unconditionally — users can paste any URL into the `target` field, and the same protection covers the case of a malicious / misconfigured webhook pointing at `169.254.169.254`. There's a known DNS-rebind caveat documented in `SsrfGuard` itself (a TTL=0 hostname could swap peers between check and connect), which will be acknowledged in the decision record.

## Slice 6 — `AlertChannels::Webhook` (generic)

**Why.** Slack is one integration. Everything else — PagerDuty, Opsgenie, custom Lambda handlers, IFTTT, in-house log pipelines — wants a generic HTTPS POST with a documented JSON payload. This slice ships that.

**What changed.** `AlertChannels::Webhook` mirrors `Slack` structurally: same Faraday construction, same SsrfGuard middleware, same 5/10s timeouts, same per-call connection. The difference is the payload — not a Slack `blocks` structure but a flat, documented JSON envelope keyed by `schema_version`, a nested `site { id, name, url }`, the event atom as a string, a nested `check_result { status_code, response_time_ms, error_message, checked_at }`, and a `sent_at` timestamp. `PAYLOAD_SCHEMA_VERSION = 1` is a module-level constant, and the rule is: additive-only changes never bump the version; shape-breaking changes do. Consumers can branch on the version.

**Key decision.** The payload shape is checked into the class file as a comment block at the top. That comment is the contract — not the spec, not a separate docs/ markdown file. The reason is aggressive co-location: if you're editing this file to change the shape, you see the contract right above where you're typing. Misses are harder.

## Slice 7a — `AlertDispatcher` (isolated, pure service)

**Why.** This is the heart of Epic 6. Every decision about what to alert about, who to notify, whether to respect quiet hours, whether to apply cooldown, and how to handle a failing channel — it all lives here. Previously `PerformCheckJob` had a five-line `notify_if_newly_down` hook. This slice replaces it with a pure service that the job will call in slice 7b.

**What changed.** A new `AlertDispatcher` class with a class-level `.call(site:, from:, to:, check_result:)` entry point. The flow is a six-step pipeline: (1) compute the event atom from the `from → to` transition; (2) return early if the event is nil (same-state transitions, `unknown → up`, `unknown → degraded`); (3) gate on quiet hours *unless* the event is `:down`, which is the critical override; (4) gate on event-level cooldown *once* outside the preference loop (cooldown is event-level, not per-channel); (5) iterate eligible preferences and dispatch each through its channel class, wrapped in a `rescue AlertChannels::DeliveryError` that logs and continues; (6) after the loop, record the cooldown *once* if **any** channel delivered successfully.

That last step is the partial-success contract. The dispatcher spec pins it explicitly: Slack raises, Email succeeds, Webhook succeeds → cooldown recorded → next immediate call with the same transition sends nothing, including to Slack. This is the thing that makes "a broken Slack URL doesn't retry every 30 seconds" a real guarantee instead of a promise.

**Cold-reader trap.** `CHANNELS = { "email" => AlertChannels::Email, ... }.freeze` is a constant hash mapping channel enum string values to concrete classes. It's not a `constantize` lookup or a dynamic class name resolution — it's a static registry, and adding a new channel means editing one line. The win is no surprises: a new channel can't accidentally sneak in via string interpolation, and the set of possible targets is greppable from the top of the file.

**Unknown → down is the only exception.** The `event_from_transition` helper returns `nil` for most transitions involving `unknown`, but `unknown → down` is the one case that maps to `:down`. The intent is "a brand-new site that's never been checked, observed failing on its first check, still deserves an alert." Dispatcher spec lines pin this explicitly.

## Slice 7b — `PerformCheckJob` integration

**Why.** Slices 3 and 7a built the debounce and the dispatcher in isolation. This slice wires them into the job — the commit that turns Epic 6 from "infrastructure on disk" into "alerts actually fire."

**What changed.** Two edits in [`app/jobs/perform_check_job.rb`](app/jobs/perform_check_job.rb). First, `#update_site` now wraps the derived status through `site.propose_status(derived)` so the debounce is active — the return value is what gets persisted as the new `status`, and the in-memory `candidate_status` / `candidate_status_at` attributes are persisted alongside. Second, the old `notify_if_newly_down` method is deleted, and one line replaces it after `apply_result`: `AlertDispatcher.call(site: site, from: previous_status, to: site.status, check_result: latest_check_result(site))`.

The job spec was the bulk of the work. The existing specs assumed a single-check commit — "after this one `perform_now` call, the site is `:up`." With debounce active, that's no longer true on a first-ever check. The fix is a helper method `run_until_confirmed` that calls `perform_now` twice, and every existing status-assertion spec now calls it. The dispatcher integration tests assert the outgoing message via `expect(AlertDispatcher).to receive(:call).with(...)` — Sandi's outgoing-command rule. The 29 dispatcher-internal edge cases stay in `alert_dispatcher_spec.rb`; duplicating them in the job spec would be brittle.

**The drift worth noting.** The Epic 5 check-types smoke spec (`spec/system/check_types_smoke_spec.rb`) also assumed single-check commits — one line fixed in place. Self-declared in the slice's agent-note.

## Slice 8a — `SiteFormComponent` gets noise-control fields

**Why.** Slices 2 and 3 gave `Site` new columns but no UI. This slice makes them editable on the existing Site form.

**What changed.** A new "Alert noise controls" section on `SiteFormComponent` with a DaisyUI divider, a `cooldown_minutes` number input, two time inputs for `quiet_hours_start` / `quiet_hours_end`, and a select populated from `ActiveSupport::TimeZone.all` for `quiet_hours_timezone`. Each field carries help text describing its semantics — the cooldown field explicitly calls out "per-event" to make the decision visible at configuration time, and the quiet-hours help text flags the drop-not-defer semantic so operators don't expect queued recovery alerts at window-end.

`SitesController#site_params` permits all five new attributes. A new helper on the component (`#timezone_options`) mirrors the existing `#check_type_options` pattern rather than computing `ActiveSupport::TimeZone.all` inline in the ERB template.

**Key decision.** A request-spec test pins a subtle UX rule: if an operator blanks `quiet_hours_start` + `quiet_hours_end` but leaves `quiet_hours_timezone` populated, the timezone persists unchanged. That means re-enabling quiet hours later doesn't require re-selecting the zone. It's a small thing, and it's the kind of thing that silently regresses if you refactor the form without the spec there to catch it.

## Slice 8b — `AlertPreference` CRUD UI (nested routes)

**Why.** Without a UI to configure preferences, everything Epic 6 ships is only accessible via the Rails console.

**What changed.** This slice introduces the **first nested resource in the app**. [`config/routes.rb`](config/routes.rb) now has `resources :sites do resources :alert_preferences end`, which gives you URLs like `/sites/:site_id/alert_preferences` and `/sites/:site_id/alert_preferences/:id/edit`. Epic 2 shipped flat routes for Sites; Epic 6 breaks that precedent *once*, in the one place where nesting is the textbook Rails answer, and future epics can follow.

`AlertPreferencesController` is six standard CRUD actions. The load-bearing detail is the `set_alert_preference` before-action: it scopes lookup through `@site.alert_preferences.find(params[:id])`, never `AlertPreference.find`. That means a request to `/sites/1/alert_preferences/<id-from-site-2>` raises `ActiveRecord::RecordNotFound` and Rails returns a 404. Without that scoping, an authenticated user could edit any site's preferences via URL manipulation. The spec pins this explicitly with a dedicated test.

Two new ViewComponents handle the display: `AlertPreferenceFormComponent` (new + edit, following the `SiteFormComponent` single-source-of-truth pattern from Epic 2) and `AlertPreferenceListComponent` (the index table). Both get Lookbook previews. The form's event picker is a checkbox group; it uses the `hidden_field_tag "alert_preference[events][]", ""` idiom so that unchecking all boxes still submits the `events[]` key — without that, Rails doesn't send the field at all and the server sees the events array as unchanged.

## Slice 9 — Seeds + README update

**Why.** A fresh dev environment should give you a working Epic 6 sandbox without manual wiring.

**What changed.** [`db/seeds.rb`](db/seeds.rb) now creates a "Quiet-hours demo" site with a 00:00–23:59 UTC window (active for almost any local clock during smoke runs), and attaches three alert preferences (email + slack + webhook) to each of the three demo sites — nine preferences total. Targets for Slack and webhook default to IANA-reserved placeholders on `example.com` so the channels actually fire and log their POST attempts but the payloads 404 harmlessly. Two new ENV overrides (`DORM_GUARD_SLACK_WEBHOOK_URL` / `DORM_GUARD_GENERIC_WEBHOOK_URL`) let a developer test real delivery.

The README gets a new "Alerting (Epic 6)" section that names the key files so an operator can find the code from the prose, plus two new rows in the deployment-env table for the webhook overrides. Design rationale stays out of the README — that's what the decision record is for.

## Chore — CI-green rubocop cleanup

A twelfth commit (`3deb14d`) lands after slice 9: seven `rubocop-rails-omakase` autocorrects across three spec files (`Layout/SpaceInsideArrayLiteralBrackets` and `Layout/CaseIndentation`/`Layout/EndAlignment`). Zero behavioral change. This exists because every slice above shipped with `lint: skipped — no linter wired` in its agent-note, which was a wrong assumption — `.github/workflows/ci.yml` runs `bin/rubocop -f github` as a required check. The honest fix is to add `bin/dc bundle exec rubocop` to the pre-commit checklist for every future slice on this branch (and every future epic).

## The big picture

**The arc, compressed.** Build the model surface (AlertPreference, noise controls on Site, debounce on Site) → build the channel layer (contract, Email, Slack, Webhook) → build the routing brain (AlertDispatcher) → wire it into the job → add the UI → seed a sandbox.

**The seams to watch in future epics.** The `AlertChannels::Base` abstract interface is the extension point for new channels — adding SMS or PagerDuty or a custom HTTP-over-TLS client means one new class + one line in `AlertDispatcher::CHANNELS`. The dispatcher's event-atom set is the extension point for new event kinds — adding something like `:certificate_expiring` or `:response_time_spike` means updating `AlertChannels::EVENTS` and the mailer's action lookup. Per-channel (not per-event) cooldown would require adding columns to `AlertPreference` and moving `record_alert_sent!` from `Site` to `AlertPreference`; that's explicitly deferred.

**Trade-offs that shaped the design.** (1) Cooldown is event-level, not channel-level — a partial success still records the cooldown. (2) Quiet-hours-suppressed alerts are dropped, not deferred — the window-end case never delivers a retroactive recovery. (3) Debounce delays a real outage by one check cycle — 30–60 seconds of added latency is the cost of eliminating blip false-positives. (4) Slack = incoming webhook only, no OAuth Slack app — MVP.

**Open questions / deliberately punted.**

- **The slice-5 drift.** Slack retroactively added `target:` to six slice-4 files. The drift is self-declared and justified, but a reviewer could reasonably argue it should have been split into 5a (contract fix) + 5b (Slack channel). Worth a conversation.
- **Per-channel cooldown.** Currently impossible to say "Slack has a 5-minute cooldown but email has 30 minutes." If this matters to operators, it's a schema change.
- **Deferred/queued alerts during quiet hours.** Currently impossible; a recovery at 3am is silent forever. Would require a `pending_alerts` table and a window-end hook.
- **Alert grouping across sites.** Also impossible; each site alerts independently. A future epic could add a cross-site grouping layer.

Full `docs/decisions/pr-0046-multi-channel-alerting.md` will land as part of merging.

## Slices

### Slice 1/11 — Epic 6 · Slice 1: AlertPreference model + migration

`cf0582842f` · feature · entangled rollback · high confidence · additive

**Intent.** Introduce the AlertPreference model as the per-site routing record for Epic 6. Inert on its own — later slices (6, 7a, 8b) will consume it.

**Scope (5 files).**
- `app/models/alert_preference.rb`
- `db/migrate/20260415120001_create_alert_preferences.rb`
- `db/schema.rb`
- `app/models/site.rb`
- `spec/models/alert_preference_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/alert_preference_spec.rb`

**Assumptions.**
- URI::MailTo::EMAIL_REGEXP is the project's accepted email-format boundary (matches User model in Epic 4).
- Rails 8's `normalizes` runs before `before_validation` callbacks — the events normalizer sees the stripped target.
- SQLite will preserve the JSON-serialized array exactly as round-tripped (matches Epic 2's expected_status_codes pattern).

**Specifications established.**
- AlertPreference::EVENTS = %w[down up degraded] is the canonical event set referenced across the epic.
- Target validation branches on channel: email uses URI::MailTo::EMAIL_REGEXP; slack/webhook parse via URI.parse and require scheme=https, non-blank host, nil userinfo.
- Events are normalized (map-to-s, strip, reject-blank, uniq) BEFORE validation.
- Sites cascade-destroy their alert preferences (has_many :alert_preferences, dependent: :destroy).

**Trade-offs.** Kept target polymorphic (one string column, channel-switched validation) rather than channel-specific columns or STI. Future split is a 3-line rename migration if we ever need it. Uniqueness across (site_id, channel, target) is NOT enforced — a site can hold duplicate Slack prefs. Noted in the plan; revisit if it becomes a support pain.

**Interfaces.**
- Published: `AlertPreference.new(site:, channel:, target:, events:, enabled:)`, `AlertPreference::EVENTS -> %w[down up degraded]`, `Site#alert_preferences -> ActiveRecord::Relation<AlertPreference>`

**Self-review.**
- **consistency.** Matches Epic 2's serialize-JSON-array pattern (Site#expected_status_codes at site.rb:16).
- **metz.** AlertPreference is 72 lines; all private methods ≤7 lines. Acceptable by the spirit of Metz's rules (validation branches are straight-line).
- **security.** No SSRF exposure here — this is the model boundary. SsrfGuard will run at delivery time in slices 4/5/6.

**Reviewer attention.**
- `app/models/alert_preference.rb:47-75` — the URI.parse-based URL validation branches; make sure I haven't let any malformed URL through.

**Lint.** `(skipped — no linter wired in the project yet)` → skipped (0)

### Slice 2/11 — Epic 6 · Slice 2: Site noise controls (cooldown + quiet hours)

`80b34fa245` · feature · entangled rollback · high confidence · additive

**Intent.** Give Site the noise-control surface that AlertDispatcher will gate on: per-event cooldown (not per-channel) and quiet hours with a critical-override semantics. Inert until slice 7a.

**Scope (4 files).**
- `db/migrate/20260415120002_add_alert_noise_controls_to_sites.rb`
- `db/schema.rb`
- `app/models/site.rb`
- `spec/models/site_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/site_spec.rb`

**Assumptions.**
- SQLite3 stores :time columns as strings but ActiveRecord exposes them as Time objects with hour/min/sec accessors.
- ActiveSupport::TimeZone[name] returns nil for unknown zones, so a cheap truthy check validates the name.
- Rails.application.config.time_zone (UTC by default) is the right fallback when quiet_hours_timezone is nil.

**Specifications established.**
- Per-event cooldown: Site#alert_cooldown_expired?(event) reads last_alerted_events[event.to_s] and compares against cooldown_minutes.minutes.ago.
- Site#record_alert_sent!(event) merges {event.to_s =&gt; now.iso8601} into last_alerted_events and saves.
- Quiet hours: nil start+end = no suppression; start &lt;= end is same-day; start &gt; end is overnight (wrap-around); boundary is inclusive-start, exclusive-end.
- Quiet hours validation: start and end must both be set or both nil; timezone must be a valid ActiveSupport::TimeZone name if present.

**Deviations from plan.** Dropped the planned `null: false, default: "{}"` on last_alerted_events. Serialize with type: Hash reads nil-in-db as {}, and Rails 8's persistence path was writing nil on INSERT for new records — fighting that would have required either after_initialize gymnastics or an attribute API change. Nullable column + serializer default is the simpler, idiomatic answer and changes zero observable semantics. Noted for the decision record.

**Trade-offs.** seconds_since_midnight() compares integer seconds rather than Time/DateTime objects. This is safe for same-day + overnight windows and immune to DST boundary issues because the comparison happens after `.in_time_zone(zone)` converts the current moment to the site's local clock. Alternative (direct Time arithmetic) was rejected because it introduces date-rollover edge cases that integer-seconds avoids.

**Interfaces.**
- Published: `Site#alert_cooldown_expired?(event, now = Time.current) -> Boolean`, `Site#record_alert_sent!(event, now = Time.current) -> Site`, `Site#in_quiet_hours?(now = Time.current) -> Boolean`

**Self-review.**
- **consistency.** Serialize pattern matches Site#expected_status_codes (site.rb:16, now 17).
- **metz.** Longest new method is in_quiet_hours? at 14 lines — breaks Metz's 5-line rule but the alternative is 3 one-line helpers that fragment the intent. Accepted.
- **security.** No new external inputs. Timezone name is validated against ActiveSupport::TimeZone lookup before use.

**Reviewer attention.**
- `app/models/site.rb:109-123` — in_quiet_hours? window logic (the overnight wrap case is the one that bites in production)
- `app/models/site.rb:94-102` — alert_cooldown_expired? returning true on nil/blank/unparseable timestamps (fail-open is the right call here but worth confirming)

**Principle violations (deliberate).**
- **Sandi Metz 5-line method rule** at `app/models/site.rb in_quiet_hours? (14 lines)` — Straight-line: zone lookup, integer conversion, window branch. Splitting would make the overnight wrap-around case harder to follow.

**Lint.** `(skipped — no linter wired in the project)` → skipped (0)

### Slice 3/11 — Epic 6 · Slice 3: Site debounce (candidate_status + propose_status)

`3017c00d99` · feature · entangled rollback · high confidence · additive

**Intent.** Give Site the 2-consecutive-check debounce contract that slice 7b will wire into PerformCheckJob. Pure model; inert until then.

**Scope (5 files).**
- `db/migrate/20260415120003_add_candidate_status_to_sites.rb`
- `db/schema.rb`
- `app/models/site.rb`
- `spec/models/site_spec.rb`
- `spec/rails_helper.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/site_spec.rb`

**Assumptions.**
- Rails 8 enum :candidate_status with prefix: :candidate, allow_nil: true allows the same symbol mapping as the status enum without scope collisions.

**Specifications established.**
- Site#propose_status mutates self in memory only — does NOT call save, does NOT touch updated_at.
- Rule: if new_status == status → clear candidate; if new_status == candidate_status → commit status; else → stash new_status as candidate.
- Returns the proposed effective status as a string so callers can compare to pre-proposal value.
- candidate_status reuses the same integer mapping as status so switching a pending candidate to confirmed is a single integer copy.
- candidate_status_at captures when the pending candidate was first seen — invaluable during debugging a site stuck in pending state.

**Deviations from plan.** Drifted spec/rails_helper.rb to include ActiveSupport::Testing::TimeHelpers. The "does not persist" spec uses travel_to to observe updated_at not changing. No other test file in the project needed time helpers yet; this slice is the first legitimate consumer, so the inclusion is minimal and scoped to tests.

**Trade-offs.** Considered tracking debounce via a CheckResult `derived_status` column and having AlertDispatcher re-derive from the last N rows. Rejected: couples the dispatcher to PerformCheckJob#derive_status's internal logic. The Site-level candidate is one column, one method, zero cross-module coupling, and makes the rule visible on the record (operators can see candidate_status in the console). The trade-off: a brand-new Site stays in :unknown for one extra check cycle. First check: candidate=:up, status=:unknown (returned). Second check: commit. Accepted — the UI shows "unknown" for ~30-60s longer on first run, no alert-path impact.

**Interfaces.**
- Published: `Site#propose_status(new_status, now = Time.current) -> String`, `Site#candidate_status -> String | nil`, `Site#candidate_status_at -> ActiveSupport::TimeWithZone | nil`

**Self-review.**
- **consistency.** Pattern matches Epic 5's derive_status approach (reading + returning a string) but kept as an instance method since candidate state lives on the record.
- **metz.** propose_status is 16 lines with early returns — longer than Metz's 5-line ideal but each branch is a straight assignment. Splitting into 3 private methods would hide the tripartite decision tree.
- **tell dont ask.** Good — the method mutates internal state and returns the effective status. Caller never needs to inspect candidate_status to decide next action.

**Reviewer attention.**
- app/models/site.rb propose_status — walk the 3 branches against the spec's flap sequence to confirm the up→down→up→down→down case is handled correctly (it commits down on check 5, not 3 or 4)
- `app/models/site.rb:13-17` — new candidate_status enum with prefix: :candidate and allow_nil: true; confirm no scope collision with status enum's `up` / `down` / `degraded` scopes

**Principle violations (deliberate).**
- **Sandi Metz 5-line method rule** at `app/models/site.rb propose_status (16 lines)` — Straight-line 3-branch decision tree. Extracting helpers would add indirection without reducing cognitive load.

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 4/11 — Epic 6 · Slice 4: Mailer actions + AlertChannels::Email + contract

`9b5ccc5c78` · feature · reversible rollback · high confidence · additive

**Intent.** Add the Email concrete channel and its shared contract so slices 5/6 can implement Slack and Webhook against the same interface. Also extends DowntimeAlertMailer with the two new actions the epic needs.

**Scope (11 files).**
- `app/mailers/downtime_alert_mailer.rb`
- `app/views/downtime_alert_mailer/site_recovered.html.erb`
- `app/views/downtime_alert_mailer/site_recovered.text.erb`
- `app/views/downtime_alert_mailer/site_degraded.html.erb`
- `app/views/downtime_alert_mailer/site_degraded.text.erb`
- `spec/mailers/downtime_alert_mailer_spec.rb`
- `app/services/alert_channels.rb`
- `app/services/alert_channels/base.rb`
- `app/services/alert_channels/email.rb`
- `spec/support/alert_channel_contract.rb`
- `spec/services/alert_channels/email_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/mailers/downtime_alert_mailer_spec.rb`
- `spec/services/alert_channels/email_spec.rb`
- `spec/support/alert_channel_contract.rb`

**Assumptions.**
- have_enqueued_mail is available via rspec-rails' ActionMailer matchers — confirmed by the existing downtime_alert_mailer_spec using ActionMailer test mode implicitly.
- Extracting the recipient into a private #recipient method does not break the existing spec that stubs ENV['DORM_GUARD_ALERT_TO'].

**Specifications established.**
- AlertChannels::EVENTS = %w[down up degraded] is the canonical event set.
- AlertChannels::DeliveryError is the single error class the dispatcher catches per-channel; any other exception bubbles.
- AlertChannels::Base#deliver raises NotImplementedError — minimal abstract interface; no template methods, no callbacks.
- Email#deliver selects the mailer action by event (down → site_down, up → site_recovered, degraded → site_degraded) and calls deliver_later.
- Email success = successful enqueue. Mailer-job failures at execution time are out-of-band from the channel's contract.

**Trade-offs.** Kept DowntimeAlertMailer as the single mailer rather than renaming it to SiteAlertMailer. Rename would cascade through Epic 3 references and provide zero observable benefit — the mailer name is internal; subject lines already carry the event atom. The shared contract spec currently only pins the interface and event-set acceptance. It does NOT assert actual delivery behavior — that lives in each channel's own spec. Rationale: the contract must be runnable by Slack/Webhook specs without needing WebMock stubs or Faraday setup that would pollute a shared concern.

**Interfaces.**
- Consumed: `DowntimeAlertMailer.with(site:).site_down | site_recovered | site_degraded -> ActionMailer::MessageDelivery`
- Published: `AlertChannels::EVENTS -> [String]`, `AlertChannels::DeliveryError (exception class)`, `AlertChannels::Base#deliver(site:, event:, check_result:) [abstract]`, `AlertChannels::Email#deliver(site:, event:, check_result:) -> true`, `shared_examples 'an alert channel' (RSpec)`

**Self-review.**
- **consistency.** Email channel follows the existing mailer pattern from Epic 1; new actions mirror site_down in structure.
- **metz.** Email class is 24 lines; action_for is 5 lines exactly. Compliant.
- **tell dont ask.** Channel receives event atoms and routes internally — the caller does not inspect channel state.

**Reviewer attention.**
- app/services/alert_channels/email.rb action_for — confirm every AlertChannels::EVENTS entry has a mapping; unmapped events raise DeliveryError, which is the right failure mode but worth double-checking the exhaustiveness
- `spec/support/alert_channel_contract.rb` — shared_examples is minimal (interface + event acceptance); if we later decide the contract should also assert truthy-return, that's a one-line addition

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 5/11 — Epic 6 · Slice 5: AlertChannels::Slack (+ target: contract retrofit)

`350167f381` · feature · reversible rollback · medium confidence · additive

**Intent.** Add the Slack concrete channel and retroactively fix a slice-4 mistake: the Base/Email contract was missing the target: keyword, which made it impossible to express "post to this specific webhook URL" without the channel reaching back into the preference to discover the target. Also teaches the mailer to honor a per-preference recipient override.

**Scope (8 files).**
- `app/services/alert_channels/slack.rb`
- `spec/services/alert_channels/slack_spec.rb`
- `app/services/alert_channels/base.rb`
- `app/services/alert_channels/email.rb`
- `app/mailers/downtime_alert_mailer.rb`
- `spec/support/alert_channel_contract.rb`
- `spec/services/alert_channels/email_spec.rb`
- `spec/mailers/downtime_alert_mailer_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/services/alert_channels/slack_spec.rb`
- `spec/support/alert_channel_contract.rb`
- `spec/services/alert_channels/email_spec.rb`
- `spec/mailers/downtime_alert_mailer_spec.rb`

**Assumptions.**
- WebMock's stub_request + JSON body matching is the idiomatic way to assert payload shape without spinning up a real Slack mock server.
- SsrfGuard's IpGuard list blocks 127.0.0.1 — verified at Epic 4, tested here for regression coverage.

**Specifications established.**
- Slack channel uses a locked payload contract: `text` key always present with '[dorm-guard] &lt;name&gt; is &lt;event&gt;' phrasing; `blocks` is additive-only.
- Slack POSTs go through Faraday with SsrfGuard middleware + 5s open_timeout / 10s read_timeout. Matches HttpChecker's construction exactly.
- All channels now take a target: keyword. Email reads it as a recipient email; Slack and Webhook read it as the webhook URL.
- DowntimeAlertMailer#recipient prefers params[:recipient] over ENV['DORM_GUARD_ALERT_TO'] over the hardcoded default — preserving existing Epic 3 behavior when no per-preference recipient is passed.

**Deviations from plan.** Slice 5's declared scope was "Slack channel only." Actual scope extended into slice 4's files (Base, Email, mailer, contract, email spec, mailer spec) to retrofit the missing `target:` keyword. Slice 4 shipped with a 3-keyword deliver() signature (`site:, event:, check_result:`) that could not express which webhook URL to POST to for Slack/Webhook. Making Slack introduce the 4th keyword unilaterally would have broken the shared contract. This slice brings all channels into alignment in a single atomic commit. Single failure domain preserved: "the Slack channel delivers correctly AND every channel now speaks the same 4-keyword contract." Splitting into 5a (contract fix) + 5b (Slack) would have left 5a as a pure refactor with no behavioral difference, which is ceremony without payoff.

**Trade-offs.** Could have kept Email ignoring `target:` (accepted but unused). Rejected because it hides the per-preference recipient from the email path — users configuring Epic 6 for the first time would expect their Slack prefs AND their email prefs to respect the target they typed in. Email now honors the override while falling back to ENV+default when not provided, so Epic 3's single-recipient mode still works in isolation. Faraday connection is built per-call rather than memoized at the class level. Per-call is ~1ms overhead and avoids thread-safety questions about reusing a Faraday connection across jobs. Same posture as HttpChecker.

**Interfaces.**
- Consumed: `SsrfGuard (Faraday middleware) from Epic 4`, `Faraday::Connection#post`
- Published: `AlertChannels::Slack#deliver(site:, event:, check_result:, target:) -> true`, `Every concrete channel's #deliver(site:, event:, check_result:, target:) -> truthy (new signature)`

**Self-review.**
- **consistency.** Faraday construction mirrors HttpChecker#connection exactly (ssrf_guard, timeouts, no redirect middleware since webhooks don't redirect).
- **metz.** Slack class is 50 lines; deliver is 10 lines, build_payload is 12 lines (mostly data). Compliant.
- **security.** SsrfGuard is the load-bearing defense — tested explicitly with 127.0.0.1 to lock in the behavior.
- **goos.** Test stubs webmock at the HTTP boundary, which is what the channel talks to. No mocking of types we don't own.

**Reviewer attention.**
- app/services/alert_channels/slack.rb build_payload — the locked `text` phrasing ('&lt;name&gt; is &lt;event&gt;') is what mobile clients display; any future edit here is operator-visible
- `app/mailers/downtime_alert_mailer.rb:22-25` — the three-level fallback (params[:recipient] → ENV → hardcoded default) is easy to misread; confirm the precedence matches what you want
- The slice-4 drift (6 files from slice 4 touched again) — if you prefer, I can split the next contract-affecting change differently; this one felt atomic enough to commit together

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 6/11 — Epic 6 · Slice 6: AlertChannels::Webhook (generic)

`700246cf1e` · feature · reversible rollback · high confidence · additive

**Intent.** Third and final concrete channel. Generic webhook with a stable JSON payload consumers can lock to via the schema_version field. Same Faraday+SsrfGuard+timeout pattern as Slack.

**Scope (2 files).**
- `app/services/alert_channels/webhook.rb`
- `spec/services/alert_channels/webhook_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/services/alert_channels/webhook_spec.rb`

**Assumptions.**
- External consumers of the webhook (PagerDuty, IFTTT, custom handlers) will branch on schema_version before reading the rest of the payload. Documented in the class comment.
- `example.com` resolves to a public IP in any test environment so SsrfGuard's DNS check passes before WebMock intercepts. Not using .invalid or a non-resolving test hostname.

**Specifications established.**
- PAYLOAD_SCHEMA_VERSION = 1. Bump only on shape-breaking changes; additive fields never bump the version.
- Payload keys: schema_version, site{id,name,url}, event, check_result{status_code,response_time_ms,error_message,checked_at}, sent_at.
- nil check_result is serialized as null (not as an empty object) — a handler that sees null check_result knows no check was associated.
- SSRF guard blocks private ranges (tested with 10.0.0.1) — users cannot accidentally (or maliciously) paste an internal URL.

**Trade-offs.** Chose to render check_result.checked_at as ISO8601 rather than epoch seconds — ISO8601 is self-describing in logs and doesn't require the consumer to know the timezone. The extra 20 chars per payload are negligible at the operational scale of a single site. build_payload is a plain Ruby hash rather than an ActiveModel::Serializer or jbuilder template. Channels are few, payloads are small, and keeping it inline means the class file shows the exact wire format at a glance.

**Interfaces.**
- Consumed: `SsrfGuard (Faraday middleware, Epic 4)`
- Published: `AlertChannels::Webhook#deliver(site:, event:, check_result:, target:) -> true`, `AlertChannels::Webhook::PAYLOAD_SCHEMA_VERSION (Integer)`

**Self-review.**
- **consistency.** Structurally identical to AlertChannels::Slack. Both use the same connection builder pattern; both raise DeliveryError on the same failure classes.
- **metz.** Webhook class is 69 lines; deliver is 10, build_payload is 13, serialize_check_result is 9. Compliant.
- **security.** SSRF guard spec pins the private-range block. If a test passes for 10.0.0.1 today and fails after a middleware refactor, the regression catches it.

**Reviewer attention.**
- app/services/alert_channels/webhook.rb:30-65 build_payload — if the payload shape is going to be externally documented, the class comment IS the contract. Any edit here is a schema change.

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 7a/11 — Epic 6 · Slice 7a: AlertDispatcher service (isolated)

`103361fc1f` · feature · reversible rollback · high confidence · additive

**Intent.** Central routing service. This is the slice that makes all the pieces slice 1-6 built into a coherent feature. Still isolated from PerformCheckJob — slice 7b wires it in.

**Scope (2 files).**
- `app/services/alert_dispatcher.rb`
- `spec/services/alert_dispatcher_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/services/alert_dispatcher_spec.rb`

**Assumptions.**
- Preference iteration order is determined by insertion order (the .where(enabled: true).select returns AR-default order). Not semantically important — the dispatcher contract guarantees 'any successful delivery records the cooldown' regardless of order.

**Specifications established.**
- Transition mapping: unknown → up/degraded returns nil (no alert). unknown → down returns 'down' (new failure is worth alerting). Same-state transitions return nil. Everything else maps to the destination state as a string.
- Quiet-hours gate: non-:down events during in_quiet_hours? are dropped entirely. :down always proceeds (critical override) and records its cooldown normally.
- Event-level cooldown: site.alert_cooldown_expired?(event) is checked ONCE outside the per-preference loop. Cooldown is event-level, not channel-level.
- Partial success: any successful delivery sets delivered_any = true. After the loop, site.record_alert_sent!(event) fires once if delivered_any. A subsequent call with the same (site, event) inside cooldown returns early — no retry for failed channels until cooldown expires or a new transition.
- Per-channel error isolation: AlertChannels::DeliveryError is caught, logged at WARN, and the loop continues. Any other exception type bubbles and the job's retry policy takes over.
- Each channel instance is built fresh per dispatch (.new) — no memoization, no thread-safety surface.

**Trade-offs.** Cooldown check is outside the per-preference loop, not inside. This means a single recent cooldown blocks ALL channels for that event. The plan locks this as "event-level, not channel-level" — channel-level would require per-preference last_alerted_events storage, explicitly deferred. eligible_preferences uses Array#select in Ruby rather than SQL filtering on the events JSON column. SQLite's JSON1 functions exist but are not universally consistent across versions; filtering in Ruby is trivially cheap at the operational scale of a few preferences per site. Channel classes are looked up via a frozen hash constant rather than `constantize`. Faster, safer, and the registry is tiny. Adding a new channel means editing one line.

**Interfaces.**
- Consumed: `Site#alert_preferences (association from slice 1)`, `Site#in_quiet_hours? (slice 2)`, `Site#alert_cooldown_expired?(event) (slice 2)`, `Site#record_alert_sent!(event) (slice 2)`, `AlertChannels::Email#deliver(site:, event:, check_result:, target:) (slice 4/5)`, `AlertChannels::Slack#deliver(site:, event:, check_result:, target:) (slice 5)`, `AlertChannels::Webhook#deliver(site:, event:, check_result:, target:) (slice 6)`, `AlertChannels::DeliveryError (slice 4)`
- Published: `AlertDispatcher.call(site:, from:, to:, check_result:) -> void`, `AlertDispatcher::EVENTS -> [String]`

**Self-review.**
- **consistency.** Structurally mirrors Epic 5's CheckDispatcher in shape (service object, class-level .call).
- **metz.** AlertDispatcher is 76 lines; call is 25 lines (close to the line but branches are straight and the early-returns are the readability point), event_from_transition is 12 lines, eligible_preferences is 4 lines. Call method is the one at the edge of Metz's rule.
- **tell dont ask.** Site knows how to check its own cooldown + quiet hours and how to record an alert sent. Dispatcher orchestrates; Site does.
- **goos.** Dispatcher spec mocks the channel classes (instance_double); never mocks types we don't own. The channel specs mock Faraday at the HTTP boundary.

**Reviewer attention.**
- app/services/alert_dispatcher.rb #call lines 25-45 — the cooldown write at line 47 (after the loop, only on delivered_any) is THE partial-success contract. The spec pins it but please read it against your mental model of 'what if Slack fails twice in a row' to confirm the behavior matches the plan.
- app/services/alert_dispatcher.rb event_from_transition — the unknown→down branch is the only transition where 'from was unknown' still fires an alert. Double-check this matches the plan's 'first-ever failure is worth alerting' rule.

**Principle violations (deliberate).**
- **Sandi Metz 5-line method rule** at `app/services/alert_dispatcher.rb #call (25 lines)` — Straight-line orchestration with 3 early returns and a single loop. Splitting into sub-methods would fragment the control flow and hide the early-return cascade that makes the quiet-hours/cooldown/enabled checks legible.

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 7b/11 — Epic 6 · Slice 7b: PerformCheckJob integration

`f949f903b1` · feature · reversible rollback · high confidence · additive

**Intent.** Wire slices 3 + 7a into the job. This is the commit that turns the whole epic from "infrastructure inert on main" into "alerts actually fire."

**Scope (3 files).**
- `app/jobs/perform_check_job.rb`
- `spec/jobs/perform_check_job_spec.rb`
- `spec/system/check_types_smoke_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/jobs/perform_check_job_spec.rb`

**Assumptions.**
- latest_check_result(site) loads the row record_check just inserted. The transaction has committed by the time apply_result returns (non-nested transaction), so the SELECT is guaranteed to see it.
- Any existing callers that depended on PerformCheckJob committing a status on a single check have been updated. The failing Epic 5 smoke spec was the only one; the rest of the suite already used before-state setup (site.update!(status: :up)) that the debounce treats as a no-op.

**Specifications established.**
- PerformCheckJob#update_site: calls site.propose_status(derived) and persists the returned status PLUS the candidate_status/candidate_status_at fields that propose_status mutated in memory.
- PerformCheckJob#perform: after apply_result, calls AlertDispatcher.call(site:, from: previous_status, to: site.status, check_result: latest_check_result(site)).
- latest_check_result loads the most recent CheckResult from the database so the dispatcher and downstream channels see a persisted record (required for the Webhook channel's payload serialization).

**Deviations from plan.** Drifted into spec/system/check_types_smoke_spec.rb. The plan said slice 7b touches perform_check_job.rb and its spec; the smoke spec from Epic 5 was an unanticipated downstream consumer. Both changes are mechanical (single-check perform_now → two-call run_until_confirmed / 2.times). Keeping this in one slice because splitting "fix the test suite" from "wire the code" would leave the branch red for a second commit.

**Trade-offs.** Job spec uses mocks for AlertDispatcher instead of end-to-end assertions about channel delivery. Rationale: dispatcher logic has 29 pinned spec examples in its own file; duplicating them in the job spec would make the test suite fragile to dispatcher internals. The job's only responsibility is "call the dispatcher with the right arguments" — that IS an outgoing command, test the interaction. latest_check_result does a full ORDER BY checked_at DESC LIMIT 1 query per job run. Cheap on a site with few check results; could memoize the record_check return value but that couples record_check's signature to apply_result. Leaving as-is until the profiler says otherwise.

**Interfaces.**
- Consumed: `Site#propose_status (slice 3)`, `AlertDispatcher.call(site:, from:, to:, check_result:) (slice 7a)`

**Self-review.**
- **consistency.** Job structure unchanged — same transaction boundary, same derive_status pipeline. Only the commit + dispatcher call are new.
- **metz.** perform is 8 lines; update_site is 9 lines; every private method under 10. Compliant.
- **goos.** Test mocks AlertDispatcher (our type) and CheckDispatcher (our type). No mocking of types we don't own.

**Reviewer attention.**
- app/jobs/perform_check_job.rb update_site — the site.update! now persists 4 attributes (status, candidate_status, candidate_status_at, last_checked_at). Confirm that passing `candidate_status: site.candidate_status` re-persists the value propose_status just wrote to the in-memory attribute (it should, since it reads self.candidate_status after the mutation)
- spec/jobs/perform_check_job_spec.rb run_until_confirmed helper — 2.times loop. If we ever bump N=2 to N=3, this helper moves with it

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 8a/11 — Epic 6 · Slice 8a: SiteFormComponent noise-control fields

`009b4cd7cd` · feature · reversible rollback · high confidence · additive

**Intent.** Give operators a UI for the slice-2 noise controls on the existing Site form. First time those columns become user-editable.

**Scope (6 files).**
- `app/components/site_form_component.html.erb`
- `app/components/site_form_component.rb`
- `app/controllers/sites_controller.rb`
- `spec/components/site_form_component_spec.rb`
- `spec/requests/sites_spec.rb`
- `spec/components/previews/site_form_component_preview.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/components/site_form_component_spec.rb`
- `spec/requests/sites_spec.rb`

**Assumptions.**
- ActiveSupport::TimeZone.all returns the Rails-curated friendly name list, NOT raw IANA identifiers. The Site model validates against ActiveSupport::TimeZone[name] which accepts both forms, so a user could theoretically POST 'America/New_York' and it would validate — but the UI only offers the friendly names.
- time_field input renders an HH:MM format that Rails parses back into a Time with today's date as context. The Site#in_quiet_hours? method reads .hour/.min/.sec so the stored value's date component is irrelevant.

**Specifications established.**
- SiteFormComponent renders a 'divider' labeled 'Alert noise controls' between the check-config section and the submit actions.
- Cooldown help text is 'Minimum minutes between alerts for the same event type. Applied per-event (down / up / degraded).'
- Quiet hours help text references the drop-not-defer semantic: 'down alerts still fire but up and degraded alerts are silently dropped (not deferred).'
- Blanking quiet_hours_start AND quiet_hours_end via the form preserves quiet_hours_timezone on the record — tested in spec/requests/sites_spec.rb.
- SitesController#site_params permits: cooldown_minutes, quiet_hours_start, quiet_hours_end, quiet_hours_timezone (alongside the existing attributes).

**Deviations from plan.** Drifted into site_form_component.rb to add #timezone_options — the helper doesn't live on the view since computing ActiveSupport::TimeZone.all inside an ERB template is noisy. Same pattern as the existing #check_type_options on line 29.

**Trade-offs.** Using ActiveSupport::TimeZone.all (friendly names) rather than a raw IANA list. Friendly names are more discoverable for ops users ("Eastern Time (US & Canada)" vs "America/New_York"). Users who prefer IANA can still paste directly via API or console — the model validator accepts both. The cooldown field's help text mentions all three event atoms to make the per-event-not-per-channel decision visible at the point of configuration, not buried in the decision record.

**Interfaces.**
- Consumed: `Site attributes from slice 2 (cooldown_minutes, quiet_hours_start, quiet_hours_end, quiet_hours_timezone)`

**Self-review.**
- **consistency.** Matches the existing form-control + card-body + divider pattern established by Epic 2's site form structure.
- **metz.** SiteFormComponent is 37 lines (up from 33); timezone_options is 3 lines. Compliant.
- **design.** Divider + descriptive help text under each new field are cheap ways to communicate the semantic of cooldown + quiet hours without dumping docs.

**Reviewer attention.**
- `app/components/site_form_component.html.erb:46-102` — new section layout; check that the card-actions (cancel + submit) still sit at the bottom after the noise-control block
- spec/requests/sites_spec.rb new timezone-preservation test — this pins the behavior the plan called out; if a future controller refactor stops preserving the zone on blank-both, this test should catch it

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 8b/11 — Epic 6 · Slice 8b: AlertPreference CRUD UI (nested routes)

`bd85366938` · feature · reversible rollback · high confidence · additive

**Intent.** Give operators a UI to configure AlertPreferences per-site. First nested resource in the app; introduces the cross-site scoping pattern the rest of the dashboard can follow later.

**Scope (15 files).**
- `config/routes.rb`
- `app/controllers/alert_preferences_controller.rb`
- `app/components/alert_preference_form_component.rb`
- `app/components/alert_preference_form_component.html.erb`
- `app/components/alert_preference_list_component.rb`
- `app/components/alert_preference_list_component.html.erb`
- `app/views/alert_preferences/index.html.erb`
- `app/views/alert_preferences/new.html.erb`
- `app/views/alert_preferences/edit.html.erb`
- `app/views/sites/show.html.erb`
- `spec/requests/alert_preferences_spec.rb`
- `spec/components/alert_preference_form_component_spec.rb`
- `spec/components/alert_preference_list_component_spec.rb`
- `spec/components/previews/alert_preference_form_component_preview.rb`
- `spec/components/previews/alert_preference_list_component_preview.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/requests/alert_preferences_spec.rb`
- `spec/components/alert_preference_form_component_spec.rb`
- `spec/components/alert_preference_list_component_spec.rb`

**Assumptions.**
- Rails' default 404 handling for ActiveRecord::RecordNotFound returns status 404 in non-production environments (not :not_found → nil). Confirmed by the cross-site scoping spec.
- The password in sign_in_as defaults to 'a_secure_passphrase_16' (spec/support/auth_helpers.rb). User creation in this spec matches.

**Specifications established.**
- Nested routes: resources :sites do resources :alert_preferences end — first nested resource in the app.
- AlertPreferencesController#set_alert_preference scopes via @site.alert_preferences.find, NOT AlertPreference.find. Cross-site ID lookups raise ActiveRecord::RecordNotFound, which Rails renders as 404.
- Strong params permit :channel, :target, :enabled, events: []. The events: [] scalar-array syntax is required for Rails' params.expect to deserialize a multi-checkbox submission correctly.
- The empty events array is handled by a trailing hidden_field_tag with blank value — unchecking all boxes still sends the events[] key, which the model's normalize hook collapses to [].

**Trade-offs.** Chose a table-based list over a card grid. Tables are denser and the alert-preferences listing is operational (ops-oriented), not marketing. DaisyUI's table class plus channel badges give enough visual structure. AlertPreferenceFormComponent does NOT conditionally render per-channel fields (no SiteForm::TypeFieldsComponent equivalent) because the form's only channel-varying surface is the target label. A sub-component would be 15 lines of indirection for a label change. Deletes use button_to with turbo_confirm rather than a rails_ujs data attribute. Epic 5's DeleteButtonComponent does the same; consistent with the project's existing idiom.

**Interfaces.**
- Consumed: `AlertPreference model (slice 1)`, `Site#alert_preferences association (slice 1)`, `ApplicationController#require_authentication (Epic 4)`
- Published: `site_alert_preferences_path(site)`, `new_site_alert_preference_path(site)`, `edit_site_alert_preference_path(site, alert_preference)`, `site_alert_preference_path(site, alert_preference)`, `AlertPreferenceFormComponent.new(site:, alert_preference:)`, `AlertPreferenceListComponent.new(site:, alert_preferences:)`

**Self-review.**
- **consistency.** Mirrors SiteFormComponent's structure exactly — card-body + form-control + card-actions, same validation error rendering.
- **metz.** AlertPreferencesController is 43 lines; every action is 4 lines or fewer. Components are 30-50 lines each. Compliant.
- **security.** Cross-site scoping is the load-bearing check. Spec pins it: GET /sites/1/alert_preferences/&lt;id-from-site-2&gt; → 404. Without this, an authenticated user could read/edit any other site's preferences via URL manipulation.
- **tell dont ask.** Components receive the site + collection; view is thin wrappers. Controller tells AR what to do; AR tells the view.

**Reviewer attention.**
- app/controllers/alert_preferences_controller.rb:46-50 set_alert_preference — the @site.alert_preferences.find scoping is what makes the cross-site 404 test pass. If anyone ever refactors this to AlertPreference.find(params[:id]), the spec should catch it — but that's a comment-level invariant worth noting
- app/components/alert_preference_form_component.html.erb:40 the hidden_field_tag with blank value — this is the idiom for 'the user unchecked all boxes'; without it, Rails doesn't send the events[] key at all and the server sees the field as unchanged

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice 9/11 — Epic 6 · Slice 9: Seeds + README update

`ee68f1e7f2` · feature · trivial rollback · high confidence · additive

**Intent.** Close the loop: seed the demo environment so `bin/dc bin/rails db:seed` gives an operator a realistic Epic 6 sandbox out of the box, and document the new alert surface in the README.

**Scope (2 files).**
- `db/seeds.rb`
- `README.md`

**Proof.** `bin/dc bundle exec rspec && bin/dc bin/rails db:seed` → **green**

**Tests.** Not required — Seed and README changes don't warrant unit tests — the model/component specs for slices 1-8 already exercise the shapes the seeds construct. Ran bin/dc bin/rails db:seed manually to verify the seeds execute without errors and create 9 AlertPreference records (3 preferences per 3 demo sites).

**Verified automatically.**
- Full suite passes: 534 examples, 0 failures.

**Verified manually.**
- bin/dc bin/rails db:seed ran cleanly; AlertPreference.count is 9 after seed; each demo site has email + slack + webhook preferences.
- Quiet-hours demo site carries quiet_hours_start=00:00, quiet_hours_end=23:59, quiet_hours_timezone=UTC as expected.

**Assumptions.**
- The IANA reserved example.com targets will 404 but not hang. SSRF guard passes them. Acceptable for smoke verification.
- Operators reading the README will discover DORM_GUARD_SLACK_WEBHOOK_URL and DORM_GUARD_GENERIC_WEBHOOK_URL overrides from the deployment-env table before running the smoke test with real integrations.

**Specifications established.**
- The Quiet-hours demo site is the only seeded site with a quiet_hours window. The other two demos can demonstrate normal alert flow.
- Each demo site has exactly three preferences (email/slack/webhook). Changing this count changes the expected smoke-test signal count.
- README's Alerting section is the user-facing contract for Epic 6. It names the key files (AlertDispatcher, AlertChannels::*, Site#propose_status) so operators can find the code from the prose.

**Trade-offs.** Kept the existing 30 fixture sites for pagination tests and added 3 new demo sites instead of converting fixtures to carry alert prefs. Two reasons: (1) pagination tests still need bulk, and (2) the demo sites are conceptually distinct — they have names that signal intent ('Quiet-hours demo') where fixtures are just 'Fixture 01' etc. README prose keeps it factual: what the models do, where the code lives, how to override for real delivery. No design rationale — that will land in docs/decisions/pr-00XX-multi-channel-alerting.md during the PR ritual.

**Interfaces.**
- Consumed: `AlertPreference model (slice 1)`, `Site quiet_hours attributes (slice 2)`

**Self-review.**
- **consistency.** Seed structure matches the existing file's style (find_or_create_by! + nested config blocks). README alerting section mirrors the tone + structure of the existing Deployment environment section.
- **metz.** N/A (no new classes).
- **tell dont ask.** Seed file tells the model how to find-or-create its own state; no getters chained.

**Reviewer attention.**
- `db/seeds.rb` — the find_or_create_by! nested inside .alert_preferences is idempotent on re-seed (safe to run twice). If we ever change AlertPreference#find_or_create_by semantics, this would be the first place to break.

**Lint.** `(skipped — no linter wired)` → skipped (0)

### Slice chore — Epic 6 · chore: rubocop-rails-omakase fixes (CI green)

`3deb14ddbb` · chore · trivial rollback · high confidence

**Intent.** Fix CI-breaking rubocop violations introduced across slices 1, 3, and 7a. Pure mechanical auto-fix — no behavior change, no new tests.

**Scope (3 files).**
- `spec/models/alert_preference_spec.rb`
- `spec/models/site_spec.rb`
- `spec/services/alert_dispatcher_spec.rb`

**Proof.** `bin/dc bundle exec rubocop && bin/dc bundle exec rspec` → **green**

**Tests.** Not required — No behavior changed — all edits are whitespace + indentation autocorrects from rubocop -a.

**Assumptions.**
- The project uses rubocop-rails-omakase which is effectively the Rails 8 default. Confirmed by .github/workflows/ci.yml running bin/rubocop -f github as a required check.

**Specifications established.**
- Array literals with whitespace-sensitive content use `[ x, y ]` (space inside brackets) per omakase Layout/SpaceInsideArrayLiteralBrackets.
- case/when blocks indent `when` to the same column as `case`, not nested one level deeper.

**Deviations from plan.** This slice was not in the plan. It exists because my slice-1/3/7a agent-notes recorded `lint: skipped - no linter wired`, which was wrong — the project has rubocop wired via CI. Every prior slice shipped with the same false assumption; this slice is the single consolidated cleanup that turns CI green. The correct fix going forward is to add `bin/dc bundle exec rubocop` to the pre-commit checklist for every future slice on this branch (and every future epic).

**Addresses.** #46

**Trade-offs.** Could have amended individual slice commits to bake the formatting fix into each original commit. Rejected because (1) CLAUDE.md explicitly prohibits amending feature-branch commits, (2) this commit's existence as a named "chore" makes the lint-discipline lesson visible in the history, and (3) rebasing would break the agent-notes attached to the prior SHAs.

### Slice fix — Epic 6 · fix: canonicalize quiet_hours_timezone to IANA (review #1)

`2a52d177af` · fix · reversible rollback · high confidence · additive

**Intent.** Fix a medium-severity correctness bug surfaced in human review: the Site edit form's timezone &lt;select&gt; emits values that don't match the IANA identifiers the model and seeds persist, causing pre-selection to fail and silent timezone wipes on save.

**Scope (4 files).**
- `app/models/site.rb`
- `app/components/site_form_component.rb`
- `spec/models/site_spec.rb`
- `spec/components/site_form_component_spec.rb`

**Proof.** `bin/dc bundle exec rubocop && bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/site_spec.rb`
- `spec/components/site_form_component_spec.rb`

**Verified automatically.**
- Unit: Site#normalizes converts every input class (IANA idempotent, friendly name → IANA, UTC → Etc/UTC, whitespace strip, invalid passthrough, blank → nil, save round-trip)
- Component: A persisted site with quiet_hours_timezone='America/New_York' renders an edit form whose &lt;select&gt; has that exact option marked [selected]
- Component: Same behavior via the normalizer when input is a Rails friendly name

**Verified manually.**
- Reproduced the original bug in Chrome pre-fix: created site 3 with tz=America/New_York via update_column (bypassing normalization), loaded /sites/3/edit, inspected the &lt;select&gt; via javascript_tool, confirmed hasMatchingOption=false and selectedText='(default Rails time zone)'. Screenshot captured.
- After fix: will re-verify in Chrome after push to confirm the select now pre-selects America/New_York.

**Assumptions.**
- ActiveSupport::TimeZone.all returns the same set of zones as the MAPPING constant plus Etc/UTC. The .all iteration + tz.tzinfo.name emits every IANA identifier a user could pick from the form.
- tz.tzinfo.name for Rails TimeZone['UTC'] is 'Etc/UTC' (not 'UTC'). Verified empirically via bin/dc bin/rails runner before committing.
- normalizes :foo runs on attribute assignment (Rails 8 behavior), not only on save. Site.new(quiet_hours_timezone: 'UTC').quiet_hours_timezone returns 'Etc/UTC' immediately.

**Specifications established.**
- Site#quiet_hours_timezone is always an IANA identifier after normalization, or nil.
- SiteFormComponent#timezone_options emits [label, iana_value] tuples where label is tz.to_s (Rails formatted) and value is tz.tzinfo.name (IANA).
- A persisted tz roundtrips through the edit form without loss: POST value == render value == DB value.
- Invalid tz names pass through the normalizer unchanged and are rejected by validate_quiet_hours_timezone with a proper error.

**Deviations from plan.** This slice wasn't in the Epic 6 plan — it's a review-driven fix landing on the feature branch after the initial 11 slices + CI chore shipped. Addresses review finding #1 which the reviewer marked as "fix before merge."

**Addresses.** #46 human review

**Trade-offs.** Could have canonicalized the other direction (Rails friendly names everywhere, specs and seeds would change). Rejected because IANA is more universal, stable across Rails versions, grep-friendly, and unambiguous ("Eastern Time (US & Canada)" spans multiple tz rules — Indiana-Starke vs Eastern proper). Choosing IANA minimized test churn: all existing specs already use IANA where they assert the persisted value. Could have done canonicalization in a before_validation callback instead of `normalizes`. Rejected because `normalizes` runs on assignment, so in-memory reads of site.quiet_hours_timezone always return the canonical form without needing a save round-trip. This matches the form's behavior (the form reads the attribute at render time, before any save).

**Interfaces.**
- Consumed: `ActiveSupport::TimeZone#tzinfo#name (Rails core)`, `Rails 8 normalizes callback`
- Published: `Site#quiet_hours_timezone always returns an IANA identifier or nil after assignment`

**Self-review.**
- **consistency.** normalizes pattern matches Rails 8 idioms and mirrors the `normalizes :target` line in app/models/alert_preference.rb:11 that Epic 6 already established.
- **metz.** Normalizer lambda is 4 lines. timezone_options helper is 3 lines. Compliant.
- **tell dont ask.** Caller (form) doesn't inspect the normalizer; it reads a canonical attribute. Good.

**Reviewer attention.**
- app/models/site.rb Site#normalizes :quiet_hours_timezone lambda — the fallback 'zone ? zone.tzinfo.name : value' returns the invalid value unchanged instead of nil. That's intentional (so the validator can reject with a meaningful error), but worth double-checking against the 'blank → nil' branch above it.
- `spec/components/site_form_component_spec.rb` — the two round-trip tests are the regression lock. They hit the exact shape of the original bug. If a future refactor of timezone_options reverts to tz.name, these tests turn red.

### Slice fix — Epic 6 · fix: AlertDispatcher logs on unknown channel (review #2)

`90b3f26bfe` · fix · trivial rollback · high confidence · additive

**Intent.** Replace the silent-skip on an unknown channel class in AlertDispatcher with a log-and-skip, so future config drift (e.g., new enum value added without a matching CHANNELS registry entry) is diagnosable from ops dashboards instead of invisible.

**Scope (2 files).**
- `app/services/alert_dispatcher.rb`
- `spec/services/alert_dispatcher_spec.rb`

**Proof.** `bin/dc bundle exec rubocop && bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/services/alert_dispatcher_spec.rb`

**Assumptions.**
- RSpec's stub_const can temporarily replace a frozen module constant for the duration of an example. Confirmed by running the spec.

**Specifications established.**
- When AlertDispatcher encounters a preference whose channel value doesn't map to a CHANNELS entry, it logs a warning (Rails.logger.warn) naming both the channel and the preference id, then proceeds to the next preference.
- An unknown channel preference does NOT call any channel's deliver and does NOT record the cooldown (so a future retry with a fixed registry can still fire).

**Deviations from plan.** Review-driven fix, not in the Epic 6 plan. Addresses both my own pr-review finding and the human reviewer's finding #2. The reviewer said won't-block, but shipping both fixes in one cycle costs nothing and closes the drift-hiding trap before Epic 7 can hit it.

**Addresses.** #46 human review · #46 pr-review pass

**Trade-offs.** Chose log + skip over raise. Raising would fail loud but take down every other channel's delivery for the same event, violating the per-channel error isolation contract from slice 7a. Log + skip preserves the contract (other channels still fire) while surfacing the drift to anyone reading production logs. Alternative: raise a new AlertChannels::UnknownChannelError and catch it at the dispatch loop's rescue block — same behavioral effect but more code for zero operator-visible difference. Chose not to record a cooldown on the unknown-channel path. If I did, a fix to CHANNELS that lands later would still be blocked by the recorded cooldown until it expires. By leaving the cooldown untouched, a repaired dispatcher fires on the next check cycle.

**Self-review.**
- **consistency.** Matches the existing warn-and-continue posture in the per-channel DeliveryError rescue block directly below (line 42-44). Same log prefix, same site+preference identification.
- **metz.** The if/else expansion is 8 lines total, replacing a 1-line guard. Method call is now 32 lines (was 25). Already flagged as a Metz principle_violation in slice 7a's note; this slice adds 7 lines of straight-line logging and doesn't push the method past the legibility threshold.

## Deferred concerns (registry)

_(Future schema work: aggregate from a structured `deferrals:` field._  
_For now, grep slice notes manually:_  
_`git log --show-notes=agent main..HEAD | grep -A2 -i 'multi-user\|deferred\|future epic'`)_

## Conventions established

_(Future schema work: aggregate from `principle_violations` + `self_review.consistency`._  
_For now, scan the per-slice sections above for `consistency` self_review entries.)_

