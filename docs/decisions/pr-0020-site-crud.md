# PR #20 — Epic 2 — Site CRUD + detail page

**Branch:** `feature/site-crud`  
**Generated from:** `a866983c27`  
**Generated:** 2026-04-13  
**Slices:** 14

## Walkthrough for a cold reader

### Context
dorm-guard is a Rails 8 uptime monitor that polls a list of sites on an interval and emails the owner when one flips between `up`/`down`. Epic 1 (walking skeleton, PR #13) proved the loop worked end to end, but the only way to add a site was to edit `db/seeds.rb`. Epic 2 makes the monitor operable through the browser: you can create, show, edit, and delete sites, view their check history, and see state flips reflected in the UI — without touching the codebase.

Alongside the CRUD work, this PR establishes a permanent view convention that Epic 1 deferred. Epic 1 shipped with inline `style=` attributes on `sites/index.html.erb` and a small partial because the value loop mattered more than the design layer. Deferring further would mean every new page inherits the inline-styles problem. Fixing it now, while the app is still two views tall, is much cheaper than refactoring three epics from now.

### Where this lives
All changes are scoped to the Rails monolith under `app/` and `spec/`:

- `app/components/` — new directory. Every ViewComponent introduced by this PR lives here. `ApplicationComponent` is the base class.
- `app/controllers/sites_controller.rb` — the only controller in the app for user-facing work; grows from a single `index` action to the full CRUD set.
- `app/views/sites/` — Epic 1 had `index.html.erb` and a status-badge partial. This PR rewrites both, adds `show/new/edit.html.erb`, and deletes the partial.
- `app/views/layouts/application.html.erb` — the shared layout shell; gains a nav + flash region that every page now relies on.
- `spec/components/` — new tree mirroring `app/components/`; every component ships with a spec and a Lookbook preview.
- `spec/requests/sites_spec.rb` — the one place request coverage accumulates, organized by action-level `describe` blocks.
- `vendor/assets/stylesheets/daisyui.css` — a vendored DaisyUI 5.5.19 bundle. Explained in slice 1.

### The arc
The eleven slices land in dependency order so each slice leaves the app green. Infrastructure first (Tailwind/DaisyUI, ViewComponent, Lookbook, Pagy), then the deferred model association, then one controller action at a time (`show` → `new`/`create` → `edit`/`update` → `destroy`), then the index wiring that makes everything reachable, then a review-driven fix for an unstyled pagination control the smoke test caught. The view layer and the product CRUD land in the same PR because postponing the design convention would force a second, larger refactor later.

### Slice 1 — Tailwind + DaisyUI, no views touched
`tailwindcss-rails 4.4` ships Tailwind v4 and a CSS-first config. DaisyUI 5 integrates with Tailwind v4 via `@plugin "daisyui"`, but the plugin loader reaches into `node_modules`, and this project's devcontainer has no Node runtime — it's a pure Ruby image. Rather than introduce `cssbundling-rails` + Bun (significant scope for a styling choice), DaisyUI is **vendored** as a pre-compiled 947 KB CSS bundle at `vendor/assets/stylesheets/daisyui.css` and imported with a relative `@import`. This trades tree-shaking (we ship the full DaisyUI stylesheet unconditionally) for zero Node dependency. Acceptable at MVP scale; a future ops epic can revisit if Core Web Vitals start mattering.

### Slice 2 — ViewComponent + Lookbook wired, nothing rendered yet
`view_component 4.6` + `lookbook 2.3`. Lookbook mounts at `/lookbook` in development. `ApplicationComponent < ViewComponent::Base` becomes the shared base class every component from slice 3 onward inherits from. A throwaway `PlaceholderComponent` proves the wiring compiles and Lookbook renders something; it's deleted in slice 3.

The initializer went through one wrong-API iteration during development — `Rails.application.config.view_component.preview_paths` (v3 API) vs `.previews.paths` (v4 API). Final shape uses v4.

### Slice 3 — Epic 1 views migrated to DaisyUI ViewComponents
Three new components replace Epic 1's inline-styled markup: `StatusBadgeComponent` (the up/down/unknown pill), `FlashComponent` (flash notices rendered as DaisyUI alerts), and `Layouts::NavComponent` (the top navbar). The layout file renders the nav and flash components; the sites index is rewritten to use a DaisyUI `table table-zebra` with `StatusBadgeComponent`.

The nav and flash renders in the layout use **absolute namespace lookup** (`::Layouts::NavComponent`, `::FlashComponent`) because ActionView has its own `Layouts` module on the constant-lookup path. Without the leading `::`, Rails resolves `Layouts::NavComponent` to `ActionView::Layouts::NavComponent` and 500s at request time. Caught by the slice's own spec; kept as a reminder for the next person who touches the layout.

### Slice 4 — `has_many :check_results, dependent: :destroy`
Closes a deferred item flagged across five Epic 1 slices. Epic 1 deliberately left Site without the reverse association because nothing read `site.check_results` — `belongs_to :site` alone was enough. Slice 6 (detail page) is the first reader, so the association finally has a consumer. `dependent: :destroy` was chosen over `delete_all` because a future callback — audit log, broadcast, Solid Queue cleanup — must fire when a site is removed; `delete_all` would silently skip it.

### Slice 5 — Pagy pinned to `~> 9.0`
Pagy jumped from 9.x to 43.x with a ground-up-rewritten API. The initial `bundle add` picked up 43.5.0, which removed `Pagy::Backend` and `Pagy::Frontend` modules and froze `Pagy::DEFAULT`. Specs blew up with `FrozenError` and `NameError`. Fix: pin `~> 9.0`, which gives us the `include Pagy::Backend` / `include Pagy::Frontend` mixin pattern that every Rails tutorial and this plan assume. **Do not let dependabot auto-bump past 9.x** — it would be a silent API break.

### Slice 6 — `SitesController#show` + detail components
`GET /sites/:id` renders a card with site metadata and a paginated check history. Two new components: `SiteDetailComponent` (the card) and `CheckHistoryTableComponent` (the table, with an empty state). The controller paginates via `pagy(@site.check_results.order(checked_at: :desc))` — the `.order` call uses the composite index `(site_id, checked_at desc)` from Epic 1 (`db/schema.rb:22`), so detail-page reads are sequential scans on a small B-tree range, not table scans. If a future migration drops that index, reads on this action go O(n log n) without any spec failure.

### Slice 7 — `#new` + `#create` + SiteFormComponent
`SiteFormComponent` is the single source of truth for the site form. It takes a `site:` kwarg, picks `"New site"` vs `"Edit site"` headings from `site.persisted?`, and renders inline validation errors per field via a `field_error(attribute)` helper. Slice 8 reuses it unchanged.

The form component's spec had a subtle problem: rendering a persisted site requires an `edit` route (to generate `PATCH /sites/:id`), and that route doesn't exist until slice 8. Solution: unit-test `#heading` and `#submit_label` directly as Ruby methods, and only render the new-site path in the full-markup specs.

`site_params` uses the Rails 8 `params.expect(site: [...])` API (replaces `params.require(:site).permit(...)`). It permits **only** `:name`, `:url`, `:interval_seconds` — not `:status` or `:last_checked_at`. A request spec specifically tries to inject `status: 'up'` on create and update, verifying mass-assignment protection at both entry points.

### Slice 8 — `#edit` + `#update`
Reuses `SiteFormComponent`. The `before_action :set_site`'s `only:` array grows from `[:show]` to `[:show, :edit, :update]` — one lookup, three actions. No per-action `Site.find` anywhere in the controller.

### Slice 9 — `#destroy` + DeleteButtonComponent + Turbo confirm
`DeleteButtonComponent` wraps Rails' `button_to` with DaisyUI `btn btn-error btn-sm` classes and a `data-turbo-confirm` prompt. A subtle detail: Turbo reads the confirm attribute from the **form wrapper**, not the button — and `button_to` generates a form around its button. So the component sets `form: { data: { turbo_confirm: ... } }`, not `data: { turbo_confirm: ... }` on the button directly. Component spec asserts the attribute lands on the form element.

The destroy flow relies on `dependent: :destroy` from slice 4 to cascade `check_results`. There's an explicit end-to-end request spec that creates two `CheckResult` rows, issues `DELETE /sites/:id`, and asserts both rows are gone — a load-bearing test for the cascade guarantee. If a future refactor swaps `dependent: :destroy` for soft-delete or async destroy, this spec catches the regression.

### Slice 10 — Index wiring + seeds
Paginates the sites index (`pagy(Site.order(:name))`), adds a "New site" primary button to both the page header and the top nav, and per-row Show/Edit/Delete actions on the index and detail pages. `db/seeds.rb` gains 30 fixture sites (on top of Epic 1's two smoke-test sites) so the manual smoke test exercises index pagination — 32 > 25, the Pagy default page size.

This was meant to be the final slice. Turned out not to be.

### Slice 11 — PagyNavComponent (smoke-test-driven fix)
The manual smoke test that Epic 2's plan defines as the verification gate caught two bugs in slice 10's pagination UI. First, `show.html.erb` called `pagy_nav` via `<%= %>`, which html-escapes the output — pagination rendered as literal text (`&lt;nav class="pagy...`). Second, even after fixing the escape, Pagy's default raw markup clashed with DaisyUI — bare `<a>` tags with no button styling.

`PagyNavComponent` takes a Pagy object and renders a DaisyUI `join` of `btn-sm` items: prev (`«`), numeric page links, current page as `btn-active`, `:gap` entries as disabled ellipses, next (`»`). Prev/next degrade to disabled spans at page boundaries. The component's `render?` returns false when `pagy.pages <= 1`, so single-page collections emit no nav at all.

Both `sites/index.html.erb` and `sites/show.html.erb` call `render(PagyNavComponent.new(pagy: @pagy))` — there is no raw `pagy_nav` anywhere in the app anymore. The request specs were tightened: they now require `aria-label="Pagination"` AND `join-item` in the response body AND explicitly reject the escaped `&lt;nav` form, so the original escape bug cannot regress silently.

### The big picture
**The arc:** Build the view stack → migrate Epic 1 → land the deferred association → install pagination → add controller actions one at a time → wire everything into reachable UI → replace raw pagy_nav with a real component.

**The seams:**
- `ApplicationComponent` is the extension point for app-wide component helpers.
- `SiteFormComponent` is the single source of truth for the site form (new + edit).
- `DeleteButtonComponent` is the only destroy affordance — raw `button_to` to `site_path` is banned.
- `PagyNavComponent` is the only pagination UI — raw `pagy_nav` is banned.
- `before_action :set_site` is the single site-loading path for show/edit/update/destroy.
- `(site_id, checked_at desc)` composite index is load-bearing for the detail page's check history read.

**Deliberately punted to Epic 4:** SSRF protection in HttpChecker, URI scheme allowlist on `Site.url` (currently regex-enforced to http/https only), the `from@example.com` mailer default, auth (single-user MVP pre-deploy), and destroy/job race conditions (accepted MVP risk — deleting a site with in-flight `PerformCheckJob` rows can race; a future epic will add job-side `RecordNotFound` resilience).

**Trade-offs worth noting:** DaisyUI vendored (no tree-shaking, ~1 MB CSS always shipped) in exchange for no Node dependency. Pagy pinned to 9.x in exchange for not adopting the 43.x rewrite mid-epic. Tailwind + DaisyUI + ViewComponent + Lookbook all introduced in one PR in exchange for a second larger refactor later.

### Review-driven additions (slices 12–14)

The eleven slices above describe the arc as planned. Three more slices
landed after the walkthrough was composed, each driven by a review
finding rather than the plan — evidence of the review loop closing.

**Slice 12 — `@site.destroy!` bang method.** `pr-review`'s accuracy pass
flagged `SitesController#destroy` as using `@site.destroy` (non-bang),
which silently swallows veto failures. Theoretical at MVP — `Site` has
no veto callbacks today — but a latent trap for the first future
`before_destroy` that can return false. Fixed by switching to
`destroy!` so `ActiveRecord::RecordNotDestroyed` propagates loudly
rather than leaving the user with a "Site deleted." flash over an
un-deleted record.

**Slice 13 — CI builds Tailwind before specs.** The first CI run on
this branch failed 20 examples with `Propshaft::MissingAssetError`:
the `test` and `system-test` jobs ran `bundle exec rspec` without
first generating `app/assets/builds/tailwind.css`, which is gitignored.
Local rspec had passed because the build artifact was cached from an
earlier session in my container — CI was the honest environment.
Fixed by adding `bin/rails tailwindcss:build` as a step in both CI
jobs. A reminder that local-green isn't real-green when build artifacts
are gitignored.

**Slice 14 — schema invariant for the composite index.** The peer
reviewer asked for the `(site_id, checked_at desc)` composite index
dependency from slice 6 to become an explicit test invariant — so a
future migration that drops or reorders the index fails the suite
with a message that names `SitesController#show` and the O(n log n)
regression, rather than a bare "index not found" or a silent perf
cliff. Added as `spec/db/schema_spec.rb` with two assertions (index
present + desc-ordered).

## Slices

### Slice 1/10 — chore: install Tailwind + DaisyUI CSS pipeline

`e8c1d70a70` · chore · reversible rollback · medium confidence

**Intent.** Install tailwindcss-rails + DaisyUI and prove the CSS pipeline compiles, with no view migration yet. Establishes the styling layer every later slice depends on.

**Scope (9 files).**
- `Gemfile`
- `Gemfile.lock`
- `app/assets/tailwind/application.css`
- `bin/dev`
- `Procfile.dev`
- `.gitignore`
- `app/assets/builds/.keep`
- `app/views/layouts/application.html.erb`
- `vendor/assets/stylesheets/daisyui.css`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests.** Not required — Pure infrastructure slice (gem install + CSS entry point + vendored asset). No Ruby behavior to cover. CSS pipeline is proved by bin/dc bin/rails tailwindcss:build succeeding and the compiled app/assets/builds/tailwind.css (1.1MB) containing DaisyUI classes (.btn / .badge / .alert all present).

**Verified automatically.**
- bin/dc bundle exec rspec — 60/60 green, same as pre-slice baseline
- bin/dc bin/rails tailwindcss:build — 211ms, no errors
- grep of compiled tailwind.css confirms .btn / .badge / .alert DaisyUI classes present

**Verified manually.**
- Did NOT yet verify the compiled CSS is served by the layout's stylesheet_link_tag. Layout still reads :app, not tailwind. Slice 3 is the first slice that uses DaisyUI classes in a view and will fix the wiring if needed.

**Assumptions.**
- DaisyUI 5.5.19 (bundled CSS from jsdelivr) is stable enough to vendor without a lockfile; upstream regressions are rare and we can re-download to bump.
- Propshaft's app/assets/builds lookup will serve app/assets/builds/tailwind.css at request time once the layout references it. Slice 3 verifies.
- Generator's &lt;main class='container mx-auto mt-28 px-5 flex'&gt; wrapper in application.html.erb is harmless scaffolding that slice 3 replaces when it installs the DaisyUI chrome.

**Specifications established.**
- Tailwind entry point lives at app/assets/tailwind/application.css and imports DaisyUI via relative path to vendor/assets/stylesheets/daisyui.css — no JS plugin system, no Node dependency.
- DaisyUI version is pinned by the vendored file's content, not a package manifest. Bumps are explicit re-downloads.

**Deviations from plan.** Two substantive deviations, both disclosed. (1) No config/tailwind.config.js — the plan assumed Tailwind v3 JS config, but tailwindcss-rails 4.4 ships Tailwind v4 which uses CSS-first config and emits no JS config file. Plan item removed from Slice 1's declared list. (2) DaisyUI is wired via @import of a vendored CSS bundle instead of @plugin 'daisyui'; the devcontainer has no Node and tailwindcss-ruby's standalone CLI cannot resolve npm packages, so the plan's plugin approach was unreachable without adding cssbundling-rails + Bun (out of epic scope). The vendored file and the three generator-touched paths that the original plan missed were added to the plan's Slice 1 declared list during drafting, so scope.drift is clean.

**Trade-offs.** Vendoring the DaisyUI CSS bundle costs ~947KB in the repo and forfeits tree-shaking (all DaisyUI classes ship to the browser whether used or not). In exchange: zero Node dependency, no cssbundling-rails, no package.json, no node_modules in the container, no yarn/bun/npm install step in CI. For an MVP with one user and a local dev loop, shipping 1MB of CSS is cheaper than owning a Node toolchain. Tree-shaking becomes relevant if/when the app goes public and Core Web Vitals start mattering — a future ops epic.

**Self-review.**
- **consistency.** Matches the docker-only dev loop (CLAUDE.md rule 1) — no host tooling, no Node. Every command was run through bin/dc.
- **layering.** Vendored asset lives under vendor/assets/stylesheets/ (Rails convention for third-party CSS), not app/assets/ (our own code). Keeps the distinction legible.
- **slice purity.** One infrastructure concept (CSS pipeline + design system). No view migration, no components, no product behavior change. Slice intent is one sentence with no hidden 'and'.
- **generator discipline.** Authored files are only application.css (2 lines) and vendor/assets/stylesheets/daisyui.css (vendored bundle). Everything else is generator output — called out explicitly in this note so a reviewer can tell scaffolding from my edits.

**Reviewer attention.**
- `app/assets/tailwind/application.css:1-2` — the entire authored Tailwind entry. Two lines, but load-bearing for the whole epic.
- `vendor/assets/stylesheets/daisyui.css` — vendored 947KB bundle. Don't read the whole thing; just confirm the provenance comment at the top matches daisyUI 5.5.19.
- `app/views/layouts/application.html.erb:27-29` — generator-inserted &lt;main&gt; wrapper. Harmless, but slice 3 will replace it, so don't over-invest in its class list.

### Slice 2/10 — chore: wire ViewComponent + Lookbook with throwaway placeholder

`365a0f277a` · chore · reversible rollback · high confidence

**Intent.** Install ViewComponent + Lookbook, mount Lookbook in development, and prove the wiring with a throwaway placeholder component. Second half of the view stack infrastructure, used by every slice from 3 onward.

**Scope (9 files).**
- `Gemfile`
- `Gemfile.lock`
- `config/initializers/view_component.rb`
- `config/routes.rb`
- `app/components/application_component.rb`
- `app/components/placeholder_component.rb`
- `app/components/placeholder_component.html.erb`
- `spec/components/previews/placeholder_component_preview.rb`
- `spec/rails_helper.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests.** Not required — Infrastructure slice. PlaceholderComponent is a throwaway removed in slice 3 — no point speccing it. ViewComponent's own unit-test machinery is exercised implicitly by slice 3's real component specs. Lookbook engine mount is verified by grepping bin/rails routes for /lookbook.

**Verified automatically.**
- bin/dc bundle exec rspec — 60/60 green, unchanged from slice 1
- bin/dc bin/rails routes | grep lookbook — Lookbook::Engine mounted at /lookbook

**Verified manually.**
- Did NOT boot a browser against /lookbook to visually verify rendering. The route-table and green-rspec checks are sufficient proof of wiring; slice 3's real components will exercise Lookbook visually when the user opens it.

**Assumptions.**
- view_component 4.6 + lookbook 2.3 are API-compatible with each other and with Rails 8.1. Their combined default config works in development without extra lookbook-specific initializers.
- Setting previews.paths via assignment (not &lt;&lt;) is the v4.x supported API — the v3-era &lt;&lt;-on-nil pattern fails because previews.paths is nil until first access, and the array becomes frozen after config freezing.

**Specifications established.**
- Every ViewComponent in this app inherits from ApplicationComponent, which inherits from ViewComponent::Base — same pattern as ApplicationController/ApplicationRecord. This is the extension seam for app-wide helpers.
- Component previews live at spec/components/previews/&lt;name&gt;_component_preview.rb and use ViewComponent::Preview, not a Lookbook-specific base class. Lookbook discovers them via ViewComponent's preview_paths config.
- Lookbook mount is gated on Rails.env.development? — it is never exposed in test or production.

**Deviations from plan.** None substantive. The initializer went through one wrong-API-shape iteration (preview_paths → previews.paths) during drafting; final state matches plan.

**Trade-offs.** PlaceholderComponent is strictly throwaway — it ships in this slice and dies in slice 3. Alternative: make slice 2 install the infrastructure AND migrate StatusBadgeComponent in one commit. Rejected because (a) that conflates stack-install risk with view-migration risk, (b) it would leave slice 2 with two concepts instead of one, and (c) slice 3 needs to touch the layout and index in a coherent set anyway. One throwaway commit is cheap.

**Interfaces.**
- Published: `ApplicationComponent`

**Self-review.**
- **consistency.** Base class naming (ApplicationComponent) matches Rails convention for app-wide base classes (ApplicationController, ApplicationRecord, ApplicationJob, ApplicationMailer).
- **slice purity.** One concept — 'the view stack component/preview layer is installed.' No DaisyUI classes, no Epic 1 view migration, no CRUD, no product behavior.
- **docker discipline.** All bundler + rails commands routed through bin/dc per CLAUDE.md rule 1. No host-side Ruby invocation.
- **placeholder discipline.** PlaceholderComponent is a single &lt;p&gt; tag with no classes — deliberately NOT using DaisyUI classes, so slice 3 owns the first real design decision rather than inheriting a style from this slice's throwaway.

**Reviewer attention.**
- `config/initializers/view_component.rb:1-3` — the v4 previews.paths API. Easy to regress to the v3 preview_paths shape on upgrade.
- spec/rails_helper.rb (diff) — the require 'view_component/test_helpers' line and the :component-type config.include. Component specs in slice 3 onward depend on both.

### Slice 3/10 — refactor: migrate Epic 1 views to DaisyUI ViewComponents

`7d791b0154` · refactor · reversible rollback · high confidence

**Intent.** Replace Epic 1's inline-styled ERB with DaisyUI ViewComponents and establish the shared layout shell (nav + flash + Tailwind stylesheet) every later slice depends on. No new user-facing capability — same columns, same data, new view convention.

**Scope (18 files).**
- `app/components/status_badge_component.rb`
- `app/components/status_badge_component.html.erb`
- `spec/components/status_badge_component_spec.rb`
- `spec/components/previews/status_badge_component_preview.rb`
- `app/components/flash_component.rb`
- `app/components/flash_component.html.erb`
- `spec/components/flash_component_spec.rb`
- `spec/components/previews/flash_component_preview.rb`
- `app/components/layouts/nav_component.rb`
- `app/components/layouts/nav_component.html.erb`
- `spec/components/layouts/nav_component_spec.rb`
- `spec/components/previews/layouts/nav_component_preview.rb`
- `app/views/layouts/application.html.erb`
- `app/views/sites/index.html.erb`
- `app/views/sites/_status_badge.html.erb`
- `app/components/placeholder_component.rb`
- `app/components/placeholder_component.html.erb`
- `spec/components/previews/placeholder_component_preview.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/components/status_badge_component_spec.rb`
- `spec/components/flash_component_spec.rb`
- `spec/components/layouts/nav_component_spec.rb`

**Verified automatically.**
- bin/dc bundle exec rspec — 73/73 green (+13 specs: 5 StatusBadge, 5 Flash, 3 Nav)
- Component specs assert DaisyUI classes (badge-success / badge-error / badge-ghost / alert-success / alert-error / navbar.bg-base-200)
- Existing request spec assertions still pass — sites index still includes 'Healthy', 'Broken', URLs, 'up', 'down'

**Verified manually.**
- Did NOT yet boot a browser to visually verify DaisyUI classes render. Visual verification is deferred to slice 10's end-to-end smoke test (seeds + index pagination). Rendering correctness is already proved by component specs with pre-seeded records.

**Assumptions.**
- The compiled app/assets/builds/tailwind.css from slice 1 is served at request time by Propshaft when the layout references stylesheet_link_tag 'tailwind'. Propshaft serves files in app/assets/builds/ by default; the slice 1 note flagged this as unverified, and this slice still does not verify it in a browser — test env doesn't load assets, so specs can't fail on this. Slice 10 is the first slice that visually matters.
- DaisyUI 5.5.19's class names (badge badge-success, alert alert-error, navbar bg-base-200, table table-zebra, container, btn btn-ghost, link link-hover) are stable within DaisyUI v5 and match the vendored bundle. Verified by grep'ing vendor/assets/stylesheets/daisyui.css for each class family in slice 1.

**Specifications established.**
- StatusBadgeComponent maps Site.status enum values ({:up, :down, :unknown}) to DaisyUI badge modifiers. Unknown-by-fallback returns badge-ghost — a site with a corrupted status value still renders, it just looks unknown. This is tighter than Epic 1's partial which had a string-keyed hash.
- FlashComponent only renders alerts for flash keys it explicitly knows ('notice' and 'alert'). Any other flash key is silently dropped. This is intentional — future flash types (info, warning) require a deliberate class mapping, not drift-by-default.
- Layouts::NavComponent lives under the ::Layouts namespace to leave room for future layout components (footer, sidebar, breadcrumb) without cluttering app/components/ root. Constant lookup from layouts/application.html.erb must use absolute ::Layouts because ActionView has its own Layouts module on the lookup path.

**Deviations from plan.** None substantive. One mid-slice design decision was needed: fully-qualifying ::Layouts::NavComponent and ::FlashComponent in the layout because ActionView::Layouts shadows the constant lookup. Caught by rspec failures on the first layout rewrite; fixed immediately. No other drift.

**Trade-offs.** Vendored DaisyUI's 947KB CSS (slice 1) is not tree-shaken, so adding a dozen utility classes to the views costs nothing at wire time — the stylesheet is already the same size. Trade accepted in slice 1; noted here because this is the first slice that consumes DaisyUI classes at scale. FlashComponent uses a known-key allowlist (notice/alert) rather than passing through any flash hash key. Alternative: render all flash keys with a default 'alert alert-info' class. Rejected because the plan explicitly scopes this slice to 'no new product capability' — introducing an info/warning category silently would be scope creep. Slice 7+ can add categories if they need them.

**Interfaces.**
- Consumed: `ApplicationComponent`
- Published: `StatusBadgeComponent.new(status:)`, `FlashComponent.new(flash:)`, `::Layouts::NavComponent.new`

**Self-review.**
- **consistency.** StatusBadgeComponent and FlashComponent both use a frozen CLASSES_BY_* constant hash, same small mapping pattern. NavComponent doesn't need it (static markup). Consistent within the file, consistent across components.
- **metz.** StatusBadgeComponent is 19 lines with 3 methods, all ≤2 lines. FlashComponent is 16 lines with 3 methods. Layouts::NavComponent is a naked class with no methods (pure view wrapper). All under Metz's limits.
- **tell dont ask.** Views ask the component for css_classes / entries / label rather than inspecting @status or @flash. Views never branch on component internals.
- **slice purity.** Intent sentence has one 'and' (components AND layout shell) — kept deliberately per the plan because they are tightly coupled (the layout renders the nav/flash components). Both halves are migration-only — no product capability added.
- **not duplicating tests.** Component specs assert presentation (classes, visible text). Request spec keeps its existing behavioral assertions (status codes, record listing). No duplicate coverage.
- **generator discipline.** No generators used in this slice. Everything is hand-authored — reviewer doesn't need to distinguish scaffolding from authored code, it is all authored.

**Reviewer attention.**
- `app/views/layouts/application.html.erb:27-30` — the ::Layouts::NavComponent and ::FlashComponent references must stay fully-qualified. A future refactor that rewrites them as Layouts::NavComponent without the leading colons will silently look up ActionView::Layouts and 500 at request time. Specs caught this once; specs will catch it again, but the comment-free constant is a subtle landmine.
- `app/components/status_badge_component.rb:4-8` — the DaisyUI class map. Epic 1 used hex colors directly; this slice delegates styling to DaisyUI. If DaisyUI ever drops badge-ghost as a modifier, the :unknown fallback breaks visually.
- `app/components/flash_component.rb:4-7` — the known-key allowlist. Slice 7+ may want to add 'info' or 'warning' — doing so is a deliberate spec change, not an oversight. Keep it explicit.

### Slice 4/10 — feat: has_many :check_results, dependent: :destroy on Site

`c1f33f5215` · feature · reversible rollback · high confidence · additive

**Intent.** Land has_many :check_results, dependent: :destroy on Site — the reverse association deferred across every slice of Epic 1. Slice 6 (detail page) and slice 9 (destroy) are the first readers.

**Scope (2 files).**
- `app/models/site.rb`
- `spec/models/site_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/models/site_spec.rb`

**Assumptions.**
- dependent: :destroy's per-record callback cost is acceptable at MVP scale. A site with one month of 60s checks has ~44k CheckResult rows; destroying such a site synchronously in a request is slow but survivable for single-user MVP. Slice 9 destroy flow may revisit if it becomes a problem.

**Specifications established.**
- Site owns its check_results: deleting a site deletes all its check results. No soft-delete, no archival.
- The association has no inverse_of override, no counter_cache, no default scope. Just a plain has_many with cascade. Future slices that need an ordered scope (e.g. most-recent-first for the detail page) should use an explicit .order(checked_at: :desc) at the call site rather than baking it into the association — keeps the association dumb and the callers honest.

**Trade-offs.** dependent: :destroy vs delete_all vs restrict_with_error. :destroy runs ActiveRecord callbacks on each CheckResult (there are none today, so it behaves like delete_all with a transaction). It was chosen over delete_all because a future slice may add a callback (e.g. Solid Queue cleanup, broadcast, audit row) that must fire on cascade — then delete_all would silently skip it. restrict_with_error rejected because it forces the destroy slice to either manually purge check_results first or to fail loudly; both options are more code than the cascade, for no MVP benefit.

**Interfaces.**
- Published: `Site#check_results -> ActiveRecord::Relation(CheckResult)`

**Self-review.**
- **metz.** site.rb grew by one line. Still 21 lines, well under Metz's 100-line rule.
- **tell dont ask.** Specs use site.check_results.create!, not a loose CheckResult.create!(site: site) — they tell the association what to do.
- **not mocking.** No mocks. Real records, real transactions, real cascade — the test asserts actual AR behavior, not stubbed behavior.
- **deferred item closure.** Closes a deferred item flagged in slices 1, 2, 4, 5, and 7 of Epic 1. The agent-notes from those slices said 'added in the first slice that reads the reverse side' — that slice is next (slice 6).

**Reviewer attention.**
- `app/models/site.rb:6` — the new has_many line. Placed between the enum and validations on purpose: associations read first in Rails conventions, before validations. Consistent with ApplicationRecord Rails convention.

### Slice 5/10 — chore: install pagy and wire Backend/Frontend mixins

`e7645068af` · chore · reversible rollback · high confidence

**Intent.** Install pagy and include Pagy::Backend in ApplicationController and Pagy::Frontend in ApplicationHelper so slice 6 and slice 10 can paginate without repeating config.

**Scope (6 files).**
- `Gemfile`
- `Gemfile.lock`
- `config/initializers/pagy.rb`
- `app/controllers/application_controller.rb`
- `app/helpers/application_helper.rb`
- `spec/rails_helper.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests.** Not required — Pure wiring slice. No new behavior to cover — Pagy's own test suite covers its internals, and this slice only includes two modules and sets two defaults. Slice 6 is the first real user of pagy() and carries the first pagination request-spec assertions.

**Assumptions.**
- pagy ~&gt; 9.0 is maintained long enough to be safe pinning to. Pagy 9.x is the last major with the Backend/Frontend mixin API; the project jumped to 43.x with a complete rewrite. If 9.x goes EOL we will need a migration epic, but that's months away at earliest and well beyond Epic 2's horizon.
- Pagy::DEFAULT is mutable in v9.x — it is frozen in v43.x, which is why the first install attempt (v43.5.0) blew up on Pagy::DEFAULT[:limit] = 25 with FrozenError. Pinning to ~&gt; 9.0 restores the mutability and the classic API.

**Specifications established.**
- Every paginated query in this app uses limit: 25 unless explicitly overridden. Set once in the initializer; callers only specify a different limit when the page-size contract genuinely differs (not currently anticipated).
- Pagy overflow is :last_page — an out-of-range ?page=999 silently renders the last page rather than raising Pagy::OverflowError. For a public MVP this beats a 500 error; a future hardening epic may revisit if we want to 404 on bad params instead.

**Deviations from plan.** Mid-slice course correction: initial bundle add picked up pagy 43.5.0, which has a ground-up-rewritten API (no Pagy::Backend, no Pagy::Frontend, frozen DEFAULT hash). Specs failed with FrozenError and NameError. Fixed by bundle remove + bundle add pagy --version '~&gt; 9.0' to pin to the classic mixin API series. The plan's 'include Pagy::Backend / Pagy::Frontend' instructions assume the v9-and-earlier API, so the pin restores plan fidelity rather than deviating from intent. Noted because a future reviewer grepping for 'why pinned' will want to find this.

**Trade-offs.** Pinning pagy to a specific major series trades future-upgrade ease for current clarity. Pagy 43.x likely has real improvements (the jump wasn't accidental), but learning its new API mid-slice would have violated the slice-purity rule — slice 5 is a chore slice, not a spike. If Pagy 43.x proves worth adopting, it gets its own migration epic. Alternative considered: vendor a simple offset paginator inline (30 lines). Rejected because pagy's helpers (pagy_nav, pagy_info) are the reason we chose pagy over hand-rolling in the first place, and v9.x gives us those out of the box.

**Interfaces.**
- Published: `ApplicationController#pagy(collection, **opts) -> [Pagy, Collection]`, `ApplicationHelper#pagy_nav(pagy) -> String`

**Self-review.**
- **slice purity.** One concept — 'pagy is installed and the mixins are included.' No UI change, no pagination usage, no spec deletions.
- **consistency.** Both mixins follow the Pagy 9.x documented pattern verbatim — no custom wrapper, no decorator. Future readers who know Pagy will recognise it instantly.
- **docker discipline.** bundle remove + bundle add both via bin/dc. No host-side gem operations.
- **version pinning rationale.** Pinned ~&gt; 9.0 explicitly rather than unspecified because the v9 → v43 API break is real and would silently regress if a future dependabot bump lands. The pin is load-bearing.

**Reviewer attention.**
- Gemfile (diff): the pagy line is pinned '~&gt; 9.0', not loose. If dependabot opens a PR to bump to v10 (or beyond), that PR MUST include the Backend/Frontend API migration — do not merge it as a mechanical version bump.
- `config/initializers/pagy.rb:3-4` — Pagy::DEFAULT[:limit] = 25 is the single source of truth for page size. Changing it affects both the sites index (slice 10) and the check history table (slice 6). Intentional coupling.

### Slice 6/10 — feat: site detail page with paginated check history

`73ca07fbf0` · feature · reversible rollback · high confidence · additive

**Intent.** Render a site detail view at GET /sites/:id with metadata and a paginated check history table, built from two DaisyUI ViewComponents. First reader of the has_many :check_results association from slice 4.

**Scope (12 files).**
- `config/routes.rb`
- `app/controllers/sites_controller.rb`
- `app/components/site_detail_component.rb`
- `app/components/site_detail_component.html.erb`
- `spec/components/site_detail_component_spec.rb`
- `spec/components/previews/site_detail_component_preview.rb`
- `app/components/check_history_table_component.rb`
- `app/components/check_history_table_component.html.erb`
- `spec/components/check_history_table_component_spec.rb`
- `spec/components/previews/check_history_table_component_preview.rb`
- `app/views/sites/show.html.erb`
- `spec/requests/sites_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/components/site_detail_component_spec.rb`
- `spec/components/check_history_table_component_spec.rb`
- `spec/requests/sites_spec.rb`

**Assumptions.**
- Rails 8 default test env shows exceptions as :rescuable, so ActiveRecord::RecordNotFound becomes a 404 response rather than a re-raised exception in request specs. The first draft of the 404 spec used expect { ... }.to raise_error and failed; updating to have_http_status(:not_found) aligned with Rails 8 default rescue behavior.
- The (site_id, checked_at desc) composite index from Epic 1 (db/schema.rb:22) services site.check_results.order(checked_at: :desc) without a table scan. No new migration needed — verified by the plan, not by EXPLAIN here.

**Specifications established.**
- SitesController uses a single before_action :set_site, only: [:show] hook (will be expanded in slices 7/8/9 to cover edit/update/destroy). The show action ONLY loads its pagy tuple and does not do any per-view ordering beyond the .order(checked_at: :desc) call — the component receives an already-ordered collection.
- CheckHistoryTableComponent renders status_code as the literal integer or an em-dash when nil; never as 'N/A' or 'missing'. The em-dash convention is used twice in this slice (status_code and error_message) and is now the app-wide convention for missing tabular data.
- The detail page's pagy_nav is rendered conditionally (@pagy.pages &gt; 1), so a site with fewer than 26 results shows no navigation UI at all. Intentional — an unused nav is noise.
- 404 on missing site is Rails default behavior; no custom rescue_from in SitesController. A future auth/security epic may want to swap this for a generic 404-or-403 based on ownership, but not this slice.

**Deviations from plan.** One test spec went through a wrong-shape iteration (expect { }.to raise_error ActiveRecord::RecordNotFound → expect(response).to have_http_status(:not_found)) during drafting. Final shape matches Rails 8 request-spec conventions. No scope drift.

**Trade-offs.** SiteDetailComponent reads directly from a Site AR object rather than wrapping it in a presenter. Considered a SitePresenter/decorator pattern, rejected because (a) the component has only one string-formatting helper (last_checked_label), (b) adding a presenter layer for one formatter is premature abstraction, and (c) the Tell-Don't-Ask discipline is already preserved — the view asks the component, the component computes, the site is the data source. A presenter becomes worth it when 3+ formatters accumulate; until then, inline helpers.delegator access is cheaper. CheckHistoryTableComponent takes a raw array of results rather than a Pagy-aware wrapper. Pagination UI lives in the view (pagy_nav), not in the table component. This keeps the table component reusable in contexts that never paginate (e.g. a Lookbook preview, a future admin panel showing the last 5 results).

**Interfaces.**
- Consumed: `StatusBadgeComponent.new(status:)`, `Site#check_results -> ActiveRecord::Relation(CheckResult)`, `ApplicationController#pagy(collection, **opts)`, `ApplicationHelper#pagy_nav(pagy)`
- Published: `SitesController#show`, `SiteDetailComponent.new(site:)`, `CheckHistoryTableComponent.new(results:)`

**Self-review.**
- **controller guardrails.** before_action :set_site with only: [:show] per the Epic 2 decision. Will grow the only: array in slices 7/8/9, never per-action lookup code. site_params is not needed yet — added in slice 7 when create/update require it.
- **tell dont ask.** Views call component methods (last_checked_label, checked_at_label, status_code_label) instead of branching on nil or calling helpers directly. Components call helpers.time_ago_in_words via the standard ViewComponent helpers delegation.
- **metz.** SitesController is 16 lines, 3 methods, all ≤3 lines. SiteDetailComponent is 12 lines, 3 methods. CheckHistoryTableComponent is 23 lines, 6 methods, all ≤2 lines. All under Metz limits.
- **testing boundary.** Component specs assert markup (span.badge, table, tbody tr count, column headers). Request spec asserts behavior (status codes, persisted data in response body, 25-row page limit). No duplicate assertions across both — e.g. component spec checks the em-dash renders, request spec never looks for em-dashes.
- **query in controller.** site.check_results.order(checked_at: :desc) lives in the controller, not the view. Plan guardrail preserved.
- **slice purity.** Intent is one sentence, one coupled behavior (detail page with paginated history). The two components are tightly coupled to the show action — splitting them across slices would force an intermediate commit with a show action rendering a half-done view.

**Reviewer attention.**
- `spec/requests/sites_spec.rb:91-97` — the 27-result pagination assertion. Creates 27 CheckResults and asserts the response has exactly 25 &lt;tr&gt; tags (subtracting the header). If pagy's limit default ever changes in config/initializers/pagy.rb, this test will fail loudly, which is the intent.
- `app/components/check_history_table_component.rb:16-22` — status_code_label and error_label both use .presence || '—'. If CheckResult changes error_message from nullable to required, the '—' branch becomes dead but the component spec will still pass (the em-dash fallback is defensive against nil, not the empty string). Worth a follow-up if the schema tightens.
- `app/controllers/sites_controller.rb:9` — the .order(checked_at: :desc) call relies on the Epic 1 composite index. If a future migration drops that index, reads on this action go O(N log N) without any spec failure.

### Slice 7/10 — feat: create sites through the browser via SiteFormComponent

`4f915ba6ea` · feature · reversible rollback · high confidence · additive

**Intent.** Let users create sites through the browser with inline validation errors and a success flash, driven by a reusable SiteFormComponent shared with slice 8.

**Scope (8 files).**
- `config/routes.rb`
- `app/controllers/sites_controller.rb`
- `app/components/site_form_component.rb`
- `app/components/site_form_component.html.erb`
- `spec/components/site_form_component_spec.rb`
- `spec/components/previews/site_form_component_preview.rb`
- `app/views/sites/new.html.erb`
- `spec/requests/sites_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/components/site_form_component_spec.rb`
- `spec/requests/sites_spec.rb`

**Assumptions.**
- form_with(model: persisted_site) generates PATCH /sites/:id. Since the :update route doesn't exist until slice 8, full-render specs of the edit branch fail with ActionController::RoutingError. The first draft of the component spec rendered a persisted site to test the 'Update site' label and failed; the fix was to split: unit-test #heading/#submit_label directly (no render), and only render the new-site path in the full-markup specs.
- Rack 3.2+ deprecates :unprocessable_entity in favor of :unprocessable_content. Rails 8 still accepts both but logs a deprecation on the old symbol. The slice proactively uses the new symbol.

**Specifications established.**
- site_params permits exactly [:name, :url, :interval_seconds] via strong params. :status and :last_checked_at are never user-assignable — this is enforced at the controller layer (not the model layer), with a request spec verifying that a malicious POST with status: 'up' is silently dropped.
- SiteFormComponent is the single source of truth for the site form. New and Edit views (slices 7 and 8) both render it unchanged. The component picks 'Create site' vs 'Update site' and 'New site' vs 'Edit site' from site.persisted?, not from an explicit 'mode' kwarg.
- Inline validation errors are rendered per-field using field_error(attr) which returns the first error message. Multi-error display is not supported — the first error is the fix-target, the rest follow from it.
- Failed POSTs render :new with status :unprocessable_content (422). Rails standard pattern; no Turbo Stream, no inline JSON.

**Trade-offs.** SiteFormComponent accepts the whole Site object and reads site.persisted?, site.errors inside the component. Alternative: pass mode: (:new | :edit) and errors: as separate kwargs, making the component agnostic to Site. Rejected because (a) it adds two extra arguments without clarity, (b) the Site class is the natural source of truth for 'is this saved?' and 'what are your errors?', (c) the tell-don't-ask violation — the component would be asking callers to derive state that Site already knows. Error rendering uses first-error-only via field_error(attr). Alternative: render all errors as a bulleted list per field. Rejected because the Site model's validations are straightforward and the first error is almost always the only one (presence then format, and format is only checked on non-blank input). Slice 8's edit flow may revisit if we see multi-error cases. Deprecation warning on :unprocessable_entity prompted an immediate switch to :unprocessable_content. Alternative: suppress the warning, keep the old symbol. Rejected because leaving a deprecation noise in a slice that already fixed it is laziness — the fix was two lines.

**Interfaces.**
- Consumed: `ApplicationComponent`
- Published: `SitesController#new`, `SitesController#create`, `SiteFormComponent.new(site:)`

**Self-review.**
- **controller guardrails.** One before_action :set_site (still only: [:show] — slice 8 expands it). site_params permits only mutable user fields. Redirect/render flow matches Rails standard. No query logic in views. One action pair (new + create) added; no 'while I'm in here' additions.
- **metz.** SitesController is now 27 lines, 5 methods, all ≤4 lines. SiteFormComponent is 18 lines, 4 methods. All under Metz.
- **dry without wrong abstraction.** Form markup is in ONE place (SiteFormComponent), not duplicated across new.html.erb and edit.html.erb. Slice 8 reuses it verbatim. This is the right abstraction — two views share one form.
- **testing boundary.** Component spec covers unit methods (#heading, #submit_label) AND rendered markup (input classes, error p tags, cancel link). Request spec covers behavior (status codes, record count, flash, mass assignment). No duplicated assertions.
- **mass assignment defense in depth.** Mass-assignment protection is defended at the request layer (site_params allowlist) AND verified by a request spec that specifically tries to inject status and last_checked_at. If a future refactor loosens site_params, this spec catches it.

**Reviewer attention.**
- `app/controllers/sites_controller.rb:31` — params.expect(site: [:name, :url, :interval_seconds]) is the Rails 8+ strong-params API (replaces params.require(:site).permit(...)). Less common; readers unfamiliar with Rails 8 may mistake it for an error-handling call.
- `spec/requests/sites_spec.rb:135-142` — the mass-assignment defense spec. If anyone ever widens site_params, this is where the regression lands.
- `app/components/site_form_component_spec.rb:16-27` — #heading/#submit_label tested as unit methods rather than via rendering. The reason (route doesn't exist yet) is subtle and will confuse someone reading the spec cold; reviewer should verify slice 8 does NOT duplicate these assertions via rendering (keeps the testing boundary clean).

### Slice 8/10 — feat: edit and update sites via the shared SiteFormComponent

`568abbf006` · feature · reversible rollback · high confidence · additive

**Intent.** Let users edit existing sites, reusing SiteFormComponent from slice 7. Adds the :edit and :update routes/actions and expands before_action :set_site's only array.

**Scope (4 files).**
- `config/routes.rb`
- `app/controllers/sites_controller.rb`
- `app/views/sites/edit.html.erb`
- `spec/requests/sites_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/requests/sites_spec.rb`

**Assumptions.**
- SiteFormComponent's submit_label/heading logic is correct for persisted records. Verified via slice 7's unit tests on the component methods (not re-verified here via rendering).

**Specifications established.**
- Update failures render :edit with :unprocessable_content. The symbol choice is consistent with slice 7's create failure path; a future Rack deprecation would catch both in the same sweep.
- Mass-assignment protection for status/last_checked_at is enforced identically on create AND update — the request spec re-verifies on PATCH, because a future change that widens site_params could easily leak through only one of the two actions.

**Trade-offs.** edit.html.erb is a one-liner that calls render(SiteFormComponent.new(site: @site)). Alternative: render the component directly from the controller, skip the view file. Rejected because (a) Rails convention expects one view file per action, (b) a future reviewer looking at app/views/sites/ would be surprised by a missing file, (c) Turbo Streams in future slices may need to address edit.html.erb by name. The edit action is empty — no instance variable assignment beyond what set_site already did. Could be elided (Rails auto-renders the matching view), but an explicit empty action is clearer than implicit rendering. Kept explicit for readability.

**Interfaces.**
- Consumed: `SiteFormComponent.new(site:)`, `Site#check_results`
- Published: `SitesController#edit`, `SitesController#update`

**Self-review.**
- **controller guardrails.** before_action :set_site grew from only: [:show] to only: [:show, :edit, :update]. One lookup, three actions. No per-action Site.find. site_params reused from slice 7 — not redefined. Rails standard redirect/render flow preserved. One action PAIR (edit + update) added; no opportunistic additions.
- **metz.** SitesController is now 35 lines, 7 methods, all ≤4 lines. Still under Metz's 100-line / 5-line limits.
- **dry.** Form rendering is the one-line `<%= render(SiteFormComponent.new(site: @site)) %>` in both new.html.erb and edit.html.erb. Zero duplication.
- **testing boundary enforcement.** Deliberately did not add a component spec that renders a persisted site to verify 'Update site' label — slice 7's unit tests cover the method, and duplicating via rendering would add flake risk (the edit route dependency) without catching new bugs.
- **mass assignment defense in depth.** Separate request spec on PATCH for mass-assignment protection, not just on POST. Both paths through site_params are covered.

**Reviewer attention.**
- `app/controllers/sites_controller.rb:2` — the before_action only: array. Slice 9 adds :destroy to this array (a site must be loaded to be destroyed). Any future action that needs @site should be added here, not with its own find.
- `config/routes.rb:18` — the resources :sites line keeps growing one symbol pair at a time. Slice 9 completes it with :destroy; resist the temptation to collapse to a bare 'resources :sites' in slice 9 — that hides the incremental growth in the git history.

### Slice 9/10 — feat: destroy sites with Turbo confirm via DeleteButtonComponent

`da6a423c8f` · feature · entangled rollback · high confidence · additive

**Intent.** Let users delete sites via a DaisyUI error button with Turbo confirm; dependent: :destroy (slice 4) cascades check history automatically. DeleteButtonComponent is ready for slice 10 to wire into views.

**Scope (7 files).**
- `config/routes.rb`
- `app/controllers/sites_controller.rb`
- `app/components/delete_button_component.rb`
- `app/components/delete_button_component.html.erb`
- `spec/components/delete_button_component_spec.rb`
- `spec/components/previews/delete_button_component_preview.rb`
- `spec/requests/sites_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/components/delete_button_component_spec.rb`
- `spec/requests/sites_spec.rb`

**Assumptions.**
- dependent: :destroy from slice 4 fires correctly in a destroy request path. The slice-4 model spec verified the association-level cascade; this slice re-verifies end-to-end through the controller, which is where a future refactor (e.g. destroy_async, soft-delete) would break silently.
- button_to in Rails 8 wraps its button in a form and forwards data: { turbo_confirm: ... } passed via form: { data: { ... } }. A Turbo JS layer reads the confirm from the form element, not the button. Verified by the data-turbo-confirm component spec.
- DELETE on a missing site returns 404 via Rails default rescue — same path as GET /sites/:id with a bad id, covered in slice 6.

**Specifications established.**
- Destroying a site cascades its check history via dependent: :destroy. The controller does NOT manually purge check_results before destroying the site.
- Destroy flow responds with a redirect + flash, not a Turbo Stream. The Turbo confirm is purely a client-side guard; there is no progressive enhancement via Turbo Streams in this slice.
- DeleteButtonComponent is the ONLY place in the app that renders a delete button for a site. Slice 10 consumes it; future views wanting to delete a site must also go through the component, not inline button_to calls.

**Deviations from plan.** None substantive. Minor: the plan's file list said 'app/components/delete_button_component.html.erb' uses a button with data-turbo-method/turbo-confirm attributes. Implementation uses button_to with form-level Turbo confirm because Rails 8 + Turbo's confirm lookup is on the form, not the button. Functionally equivalent; the component spec verifies the right attribute is on the right element.

**Trade-offs.** reversibility is flagged as 'entangled' rather than 'reversible' because this slice couples three concerns that can't be individually undone: the destroy route, the controller action, and the has_many dependent behavior from slice 4 (which is load-bearing and covered by both the model and request specs). Reverting this slice alone does not break anything, but reverting this slice AND slice 4 together would leave orphaned CheckResult rows if any destroy happened in between — a full entanglement chain. DeleteButtonComponent is introduced one slice before it's wired into any view (slice 10 uses it from the index row and the detail card). Alternative: inline the button_to in slice 10 and skip the component entirely. Rejected because (a) the confirm message interpolation is non-trivial enough that slice 10's index.html.erb would grow by 8+ lines per use, (b) slice 10's intent is wiring-only, not new-component-introduction, (c) having the component with a spec here keeps slice 10's diff pure wiring.

**Interfaces.**
- Consumed: `ApplicationComponent`, `Site`
- Published: `SitesController#destroy`, `DeleteButtonComponent.new(site:)`

**Self-review.**
- **controller guardrails.** before_action :set_site only: [:show, :edit, :update, :destroy] — the final expansion. No per-action Site.find anywhere. resources :sites line now contains all 7 CRUD actions explicitly, not the bare 'resources :sites' shortcut — kept the symbols explicit so the git history shows each action being added one-by-one.
- **destroy race conditions.** Called out in Epic 2's plan: destroying a site with in-flight PerformCheckJob rows is a race condition accepted as MVP risk. The Site.destroy call happens synchronously in the request; any Solid Queue job that loads this site after destroy will get ActiveRecord::RecordNotFound, which the job does not currently handle. Future ops epic will add rescue_from in PerformCheckJob. Not fixing here per plan.
- **metz.** SitesController grew to 41 lines, 8 methods, all ≤3 lines. DeleteButtonComponent is 11 lines, 2 methods. Under Metz.
- **dependent destroy integration test.** The 'cascade-deletes the site's check results' spec is the first end-to-end test of dependent: :destroy through an HTTP request. Slice 4's model spec covered the association-level cascade; this slice covers the controller-level cascade. Both are necessary — a future change that swaps dependent: :destroy for a manual purge must pass both tests.
- **testing boundary.** Component asserts markup (form action, _method hidden input, DaisyUI classes, data-turbo-confirm text). Request asserts behavior (record count deltas, redirect, 404). No overlap.

**Reviewer attention.**
- `app/components/delete_button_component.html.erb:4` — data-turbo-confirm is on the form wrapper, not the button. button_to's form: { data: { ... } } syntax is subtle. Moving the attribute to the button would break the confirm prompt silently — the component spec catches it, but the markup looks 'wrong' to anyone used to button-level data attributes.
- `spec/requests/sites_spec.rb:207-214` — the cascade-deletes spec. Load-bearing for dependent: :destroy. If this spec ever gets removed or skipped, the cascade guarantee regresses to 'probably works'.
- `app/controllers/sites_controller.rb:24-27` — destroy does no soft-delete, no archival, no event broadcast. A future audit-log epic will need to hook in here; the current shape is the simplest possible destroy.

### Slice 10/10 — feat: wire CRUD affordances into the sites index and detail views

`bf14e1c8d8` · feature · reversible rollback · high confidence · additive

**Intent.** Wire the Epic 2 CRUD actions into the index and detail views — New site button, per-row Show/Edit/Delete actions, pagination, expanded seeds — so the feature is reachable end-to-end from /sites. Wiring only, no new components, no new features.

**Scope (8 files).**
- `app/controllers/sites_controller.rb`
- `app/views/sites/index.html.erb`
- `app/components/site_detail_component.html.erb`
- `app/components/layouts/nav_component.html.erb`
- `db/seeds.rb`
- `spec/requests/sites_spec.rb`
- `spec/components/site_detail_component_spec.rb`
- `spec/components/previews/site_detail_component_preview.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/requests/sites_spec.rb`

**Assumptions.**
- Pagy's pagy_nav output contains the literal string 'pagy' somewhere in its markup (class names, data attributes). Verified by grepping pagy 9.4.0's helpers.rb; may need adjustment on a future Pagy version bump.
- button_to inside the DeleteButtonComponent, rendered inside a table row, is valid HTML (form-inside-tr). It is — forms can wrap any flow content. Might feel wrong but the component spec and the request spec both pass.

**Specifications established.**
- The sites index shows pagy_nav ONLY when @pagy.pages &gt; 1. A single-page result has no nav UI — no placeholder, no skeleton, no 'Page 1 of 1' text.
- The 'New site' primary button appears in two places: page header (always visible when @sites.any?) and the top nav (always visible regardless of result count). The nav version makes creation reachable even from an empty state.
- Seeds create 32 total sites at db:seed time: 2 Epic 1 smoke-test fixtures + 30 Fixture NN entries. find_or_create_by! makes db:seed idempotent across multiple runs. The pagination assertion in the request spec creates its own data independent of seeds — seeds are for the manual smoke test, not for automated tests.

**Deviations from plan.** Two files touched beyond the plan's original declared list: spec/components/site_detail_component_spec.rb and spec/components/previews/site_detail_component_preview.rb. Both had to switch from Site.new to a persisted/id-assigned Site because the detail component template now renders edit_site_path(site) and DeleteButtonComponent, which require site.id to generate URLs. Not scope creep — direct fallout from wiring action buttons into the component, and the plan's Slice 10 declared list has been updated to match reality. Drift cleared; scope.drift is empty.

**Trade-offs.** Pagination UI is rendered via &lt;%== pagy_nav(@pagy) %&gt; (html_safe output) wrapped in a &lt;nav&gt; element. Alternative: build a custom DaisyUI-styled navigation component and skip Pagy's default helper. Rejected as scope creep — slice 10 is wiring only. The default pagy_nav markup is unstyled but functional; a future slice or epic can introduce a PagyNavComponent if the aesthetic becomes a priority. SiteDetailComponent spec was updated to create! the site rather than mocking a stub with a fake id. Considered: introduce a double('Site', id: 1, name: 'X', ...) to avoid DB writes in a component spec. Rejected because (a) dorm-guard's CLAUDE.md forbids mocking what you don't own, and Site is ours, so it's actually mockable — but (b) the component reads url, status, interval_seconds, last_checked_at, AND the DeleteButtonComponent reads id and name separately, so a mock would need 6 stubbed methods and still not exercise the URL helper resolution. create! is cheaper. DeleteButtonComponent inside the index table row uses button_to which generates a nested &lt;form&gt; inside &lt;tr&gt;. This is valid HTML5 (flow content) but historically gave some browsers trouble with row selection. On modern browsers and with DaisyUI's simple table layout there are no visible issues; if a future UX epic introduces row-click-to-show, the button_to may need to move to an inline JS trigger instead.

**Interfaces.**
- Consumed: `StatusBadgeComponent.new(status:)`, `SitesController#new, #edit, #show, #destroy`, `DeleteButtonComponent.new(site:)`, `ApplicationController#pagy(collection)`, `ApplicationHelper#pagy_nav(pagy)`

**Self-review.**
- **no new components.** Declared intent: wiring only. Count of new components in this slice: zero. Verified by git show --stat HEAD — only modified files under app/components/, no new files.
- **no new features.** New affordances on existing pages do not count as new features in this slice's terms — the routes, controllers, and components they point at all landed in slices 6-9. This slice only makes them reachable. No new routes, no new controller actions.
- **no opportunistic polish.** Things I could have done but did not: restyle the table header, add a loading spinner, animate the flash alerts, introduce a dark mode toggle, add keyboard shortcuts. All out of scope for a wiring slice.
- **seeds are test data not fixtures.** db/seeds.rb Fixture sites are for the manual smoke test gate in Epic 2's Verification section. The request spec's pagination assertion creates its own sites — it does not rely on seeds running in test env. Seeds and test data are separate concerns.
- **controller guardrails.** Index action gained pagination; no new action, no new filter. site_params unchanged. before_action :set_site unchanged (index doesn't need a specific site). resources :sites line unchanged — slice 9 already completed it. Guardrail preservation verified.
- **epic 2 done condition.** All 10 slices landed. Automated specs green (120/120). /lookbook renders every Epic 2 component. Manual smoke test is the final gate before the PR ritual — that is the user's call, not mine.

**Reviewer attention.**
- `app/views/sites/index.html.erb:55` — `<%== pagy_nav(@pagy) %>` uses `<%==` (double equals) for html_safe output. Pagy's helper returns a string that must not be escaped. Easy to regress to `<%=` which would print the raw HTML as text.
- `db/seeds.rb:14-21` — the 30 fixture sites. If a future ops epic adds email alerts on site creation, re-running db:seed would fire 30 emails unless the find_or_create_by! idempotency holds. Verified idempotent today; keep it that way.
- `spec/requests/sites_spec.rb:60-74` — the pagination regression test is the ONLY automated test that proves pagination actually activates. Don't delete it when refactoring.

### Slice 11/11 — fix: DaisyUI-styled PagyNavComponent replaces raw pagy_nav

`8867988f81` · fix · reversible rollback · high confidence · additive

**Intent.** Replace the raw pagy_nav output with a DaisyUI-styled PagyNavComponent that renders a join of btn-sm buttons for prev / numeric pages / current / gap / next, fixing the unstyled pagination discovered during the Epic 2 smoke test.

**Scope (7 files).**
- `app/components/pagy_nav_component.rb`
- `app/components/pagy_nav_component.html.erb`
- `spec/components/pagy_nav_component_spec.rb`
- `spec/components/previews/pagy_nav_component_preview.rb`
- `app/views/sites/index.html.erb`
- `app/views/sites/show.html.erb`
- `spec/requests/sites_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/components/pagy_nav_component_spec.rb`
- `spec/requests/sites_spec.rb`

**Assumptions.**
- Pagy 9.x's pagy.series returns an array of Integer | String | :gap elements. Integer = navigable page, String = current page (pre-coerced by Pagy), :gap = ellipsis. Verified by reading Pagy 9.4.0 source during drafting and by the :gap spec constructing a 700-count pagy.
- helpers.pagy_url_for(pagy, page) is callable from inside a ViewComponent because Pagy::Frontend is included in ApplicationHelper (slice 5), and ViewComponent's helpers delegates to ActionView. Verified by passing component specs that call render_inline inside with_request_url.

**Specifications established.**
- PagyNavComponent is the ONLY place in the app that renders pagination UI. Direct calls to pagy_nav are banned — any future paginated page must render(PagyNavComponent.new(pagy:)) instead. The index and show views are the two current callers and both use the component.
- Single-page collections render no nav at all (render? false). No placeholder, no 'Page 1 of 1' text, no empty div. A future reader who expects a dead nav element will be surprised, but clutter is the worse failure mode.
- Prev/next degrade to disabled spans, not missing elements, so the join layout stays visually consistent at page boundaries. This is a DaisyUI idiom (btn-disabled on a span) rather than the HTML5 &lt;button disabled&gt; idiom, because there is nothing to submit — these are navigation anchors.

**Deviations from plan.** Formal deviation from the Epic 2 plan: the plan has no slice 11. This slice is a review-driven addition after the manual smoke test (Epic 2's verification gate) discovered the unstyled pagination. Added to the plan's numbered Slices list as slice 11 during drafting so scope.drift stays clean. addresses field names the smoke-test gap it closes, and the kind is 'fix' rather than 'feature' because the underlying behavior (pagination) was already shipped in slices 5/6/10; this slice only changes how it looks.

**Addresses.** smoke-test gap: pagy_nav rendered escaped on show.html.erb and unstyled everywhere

**Trade-offs.** Chose a new ViewComponent over the two alternatives I considered: (a) a pagy_daisy_nav helper method in ApplicationHelper, and (b) CSS that uses @apply to style Pagy's default .pagy nav output. (a) was rejected because Epic 2's stack decisions explicitly moved view logic OUT of helpers and INTO components. (b) was rejected because introducing a CSS layer beyond DaisyUI utility classes in templates reopens a styling-strategy decision that slice 3 settled on 'DaisyUI classes in component templates, no custom CSS'. A component is the consistent choice for this codebase even though it formally breaks 'slice 10 has no new components' — the plan was wrong about slice 10 being the last slice, not wrong about the component being the right shape. Rejected wrapping the pagy_nav output with html_safe and calling it done — that fixes the escape but leaves the default Pagy .pagy-nav CSS class dangling without a stylesheet. The DaisyUI join is the actual design. render? gate lives in the component rather than every caller — one rule, one place. If a future page wants to force-render an empty nav (unlikely), it can pass a different prop, but YAGNI.

**Interfaces.**
- Consumed: `ApplicationHelper#pagy_url_for(pagy, page)`, `Site#check_results`
- Published: `PagyNavComponent.new(pagy:)`

**Self-review.**
- **slice purity.** Intent is one concept — 'pagination UI is a DaisyUI-styled component' — even though it touches seven files, because the other six files are all 'wire the component into existing call sites and update the assertions to match the new DOM'. No product behavior change.
- **metz.** PagyNavComponent is 15 lines, 3 methods (initialize, render?, url_for_page), all ≤2 lines.
- **tell dont ask.** View asks the component 'should I render?' via the render? hook and 'what URL for page N?' via url_for_page(page). The view never inspects pagy.pages or pagy.prev.
- **testing boundary.** Component specs assert markup (.join, .join-item, .btn-active, .btn-disabled, aria-current). Request specs assert Response body includes the aria-label and the join-item class — enough to prove the component rendered, not enough to overlap with component-level structural assertions.
- **stack consistency.** Uses DaisyUI join + btn-sm — the same atomic classes that appear in DeleteButtonComponent (btn btn-error btn-sm) and SiteFormComponent (input input-bordered, btn btn-primary). No new utility classes introduced.
- **smoke test closed loop.** The smoke test that discovered the bug is Epic 2's verification gate. The slice that closes the gap is the slice that proves the gate works as intended — reviewers catching real bugs before merge.

**Reviewer attention.**
- `app/components/pagy_nav_component.rb:13-15` — helpers.pagy_url_for delegates through ViewComponent's helpers proxy. If a future ViewComponent upgrade changes helpers resolution semantics, this component's URL generation breaks silently; the request spec's assertion that join-item appears in the body catches the silent failure.
- `app/components/pagy_nav_component.html.erb:12` — the when String branch renders the current page as a span with btn-active. Pagy 9.x uses a stringified page number as the in-array marker for the current page (e.g., series = [1, 2, '3', 4, 5]). If Pagy ever changes this to :current or a tuple, the case/when needs to update — the component spec pins the current-page rendering so a regression fails fast.
- spec/requests/sites_spec.rb:75-79,121-125 — the two request-spec tightenings. They require 'aria-label="Pagination"' AND 'join-item' AND no '&lt;nav' escape. Keep all three conditions; any one alone would miss a class of regression.

### Slice 12/12 — fix: SitesController#destroy uses bang method to surface failures

`498082e292` · fix · trivial rollback · high confidence

**Intent.** Replace @site.destroy with @site.destroy! in SitesController#destroy so a veto failure surfaces as ActiveRecord::RecordNotDestroyed instead of silently rendering "Site deleted." while the record remains.

**Scope (1 files).**
- `app/controllers/sites_controller.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests.** Not required — No new test added for the failure case. Existing destroy specs from slice 9 (happy path + cascade-deletion) still pass because destroy! returns the record on success, identical to destroy. Constructing a failure case in a spec would require either (a) mocking Site (forbidden by CLAUDE.md — don't mock what you own when reality is cheaper) or (b) stubbing before_destroy to return false (invasive monkey-patch on a model with no real veto callbacks). The fix is a one-character change with a clear failure mode, and dev-time exceptions are louder than spec assertions here. A future epic that adds a real veto callback (audit log, soft delete, payment hold) MUST add a failure-path spec at the same time, not in this slice.

**Assumptions.**
- ActiveRecord::RecordNotDestroyed propagates through the controller and lands in Rails' default exception handler. Rails 8 dev env shows the exception in the browser; production renders the standard 500 page. No custom rescue_from in SitesController, no custom 500 page registered — both are Epic 4 hardening concerns.

**Specifications established.**
- SitesController#destroy uses the bang variant of destroy. Any future code that touches this action MUST keep it bang — silently downgrading to non-bang would re-introduce the latent silent-failure pattern this slice was specifically created to fix.

**Deviations from plan.** addressing review feedback

**Addresses.** #20 comment 3072949838

**Trade-offs.** Bang method vs explicit if-branching. `@site.destroy!` (chosen) raises and propagates — failure mode is loud and hits dev.log. Alternative: `if @site.destroy ... else render :show, alert: "Could not delete." end` — failure mode is graceful and user-visible. Rejected because (a) Site has no veto callbacks today, so the graceful path is theoretical; (b) when a real veto lands in a future epic, that epic should design its own failure UX rather than inherit a placeholder; (c) loud-by-default is the right choice when there is no real failure case to design for. The bang is honest about 'this should never fail under current rules'.

**Self-review.**
- **consistency.** Matches the pattern Rails 8 uses elsewhere — destroy! is the bang variant of destroy and is the conventional choice when failure is exceptional. No new pattern introduced.
- **metz.** SitesController unchanged in line/method count. Single character delta.
- **testing boundary pragmatic.** Skipping the failure-path spec is honest, not lazy. The note documents WHY it's skipped so a future reviewer doesn't add the wrong test (e.g., a mock-heavy spec that mocks Site).
- **review driven discipline.** Slice 12 exists ONLY because the pr-review accuracy pass on PR #20 raised this as a verify-level finding. addresses field carries the comment id so the link is permanent. deviations_from_plan: addressing review feedback per the agent-notes convention.

**Reviewer attention.**
- `app/controllers/sites_controller.rb:38` — the single character change. The bang is load-bearing; non-bang would silently re-introduce the bug this slice was created to fix.

### Slice 13/13 — fix(ci): build Tailwind CSS before running specs

`ae788ff2d3` · fix · trivial rollback · high confidence

**Intent.** Add a tailwindcss:build step to both the test and system-test CI jobs so app/assets/builds/tailwind.css exists before rspec runs. Fixes 20 failing examples on PR #20 where the layout's stylesheet_link_tag hit Propshaft::MissingAssetError.

**Scope (1 files).**
- `.github/workflows/ci.yml`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests.** Not required — CI workflow change only. The underlying rspec suite is unchanged — local rspec was green throughout because the build artifact had been generated earlier in the session. No new test coverage is possible for the workflow file itself; verification happens when CI runs on the pushed branch.

**Verified automatically.**
- bin/dc bundle exec rspec — 129/129 green (same baseline, unchanged)

**Verified manually.**
- Workflow file hand-verified: both test and system-test jobs now run `bin/rails tailwindcss:build` with RAILS_ENV=test immediately before db:test:prepare.
- Will be observable on the next CI run of feature/site-crud — the test job must flip from red to green.

**Assumptions.**
- tailwindcss-rails's rake task is available in CI after `bundler-cache: true` installs the gem. Verified by the fact that slice 1 created the build step via the same gem.
- No cssbundling-rails is involved. The standalone CLI in tailwindcss-ruby runs without Node, so the CI step needs no apt-get or node setup. Matches slice 1's stack decision.
- The workflow file will trigger a fresh CI run when pushed because the PR is already open against main — GitHub Actions re-runs on new commits to the PR head.

**Specifications established.**
- CI's test and system-test jobs MUST run `bin/rails tailwindcss:build` before rspec. Any future refactor that removes this step will resurrect the 20-failure Propshaft::MissingAssetError regression that this slice was created to fix.

**Deviations from plan.** addressing CI feedback

**Trade-offs.** Two alternatives considered. (a) Gitignore change — commit the compiled app/assets/builds/tailwind.css. Rejected because committed build artifacts drift from source and create merge conflicts every time the stylesheet changes; the .gitignore entry from slice 1 is deliberate. (b) Configure Propshaft to tolerate missing assets in test env — a config/environments/test.rb change that stubs stylesheet_link_tag. Rejected because it hides the real failure: the test env would stop noticing that the asset pipeline broke. Running the actual build step is the honest fix. Adding the step to BOTH test AND system-test jobs — slight duplication. Alternative: a shared composite action or a reusable workflow step. Rejected as premature abstraction for two jobs and one command.

**Self-review.**
- **consistency.** New step uses the same RAILS_ENV: test env block and indentation as the existing db:test:prepare step. No style drift.
- **ci discipline.** CI mirrors dev now. Dev uses bin/dev which runs foreman + tailwindcss:watch in parallel; CI runs tailwindcss:build once before specs. Both produce the same app/assets/builds/tailwind.css output, so CI and dev environments stay aligned.
- **honest failure mode.** Did not try to hide the failure in config/environments/test.rb. The asset pipeline IS load-bearing for layout rendering, and CI should fail loudly if it's broken — the fix is to make it not break, not to silence it.
- **slice purity.** One concept: CI builds Tailwind before running specs. One file. One change. Intent is one sentence with no 'and'.

**Reviewer attention.**
- .github/workflows/ci.yml:83-86 and 105-108 — the two new build steps. If either is removed, the test job regresses to 20 failures immediately. The step must land BEFORE db:test:prepare because db:test:prepare does not depend on assets but rspec's very first request spec will.

### Slice 14/14 — test: pin the composite index SitesController#show depends on

`a866983c27` · test · trivial rollback · high confidence

**Intent.** Make the (site_id, checked_at desc) composite index an explicit test invariant so dropping it via a future migration fails the suite with a message that explains the controller-level consequence.

**Scope (1 files).**
- `spec/db/schema_spec.rb`

**Proof.** `bin/dc bundle exec rspec` → **green**

**Tests added.**
- `spec/db/schema_spec.rb`

**Assumptions.**
- ActiveRecord::Base.connection.indexes(:check_results) returns the same structure across SQLite (current) and PostgreSQL (potential future). .columns is an array of string column names; .orders is a hash mapping column name to :asc/:desc. If dorm-guard ever migrates to PostgreSQL, these assertions should still hold — both adapters implement the same IndexDefinition interface.

**Specifications established.**
- The (site_id, checked_at) composite index on check_results is a load-bearing contract for SitesController#show. Any migration that drops or reorders it MUST land alongside a corresponding update to this spec — red first, fix second.

**Deviations from plan.** addressing peer review feedback

**Addresses.** #20 peer review — schema spec for composite index

**Trade-offs.** Schema spec lives at spec/db/schema_spec.rb rather than spec/models/check_result_spec.rb because the contract isn't about CheckResult's behavior — it's about the database's physical layout for controller-level query performance. Putting it in a dedicated schema-invariants file keeps model specs focused on model semantics and creates a natural home for future 'database contract' tests (foreign keys, not-null constraints, check constraints). Considered an in-memory EXPLAIN assertion instead — actually run the query and assert the plan uses the index. Rejected because SQLite's EXPLAIN output is unstable across minor versions and the test would be brittle; asserting the index exists is a cheaper invariant that catches the regression the peer reviewer was worried about.

**Self-review.**
- **slice purity.** One spec file, one invariant, one intent sentence. No new production code.
- **failure message quality.** Both assertions include failure messages that explain WHY the index matters, not just WHAT is missing. A future failing test reads like a code review comment.
- **placement.** spec/db/ is a new directory. Convention-neutral but precedented — many Rails codebases use spec/db for schema/migration invariants.

**Reviewer attention.**
- `spec/db/schema_spec.rb:8-13` — the composite-index existence assertion. If this test ever fails, read the failure message before reaching for a schema change; the message explains the controller-level consequence.

## Deferred concerns (registry)

_(Future schema work: aggregate from a structured `deferrals:` field._  
_For now, grep slice notes manually:_  
_`git log --show-notes=agent main..HEAD | grep -A2 -i 'multi-user\|deferred\|future epic'`)_

## Conventions established

_(Future schema work: aggregate from `principle_violations` + `self_review.consistency`._  
_For now, scan the per-slice sections above for `consistency` self_review entries.)_

