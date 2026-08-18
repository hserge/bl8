<!--
Sync Impact Report
Version change: 3.5.0 → 3.6.0
Modified principles: none
Added sections:
  - Frontend Design Workflow: new "Design reference" sub-rule — UI/UX MUST match the reference
    images at docs/design.png (look/feel/color/typography/visual style) and
    docs/form_content.png (primary link-shortening/QR-code form + page content layout and
    orientation), consulted before any visual/layout/component decision; unreferenced
    screens/components MUST extend the same visual language rather than introduce a new style
Removed sections: none
Follow-up TODOs: none
-->

# URL Shortener Constitution

## Core Principles

### I. Independent, Non-Overlapping Components

The system is composed of two components — `redirect/` (Go) and `ui/` (SvelteKit) — with
strictly non-overlapping responsibilities. Each MUST be developed, tested, and deployed
independently of the other. Neither component's codebase MUST import, embed, or depend on
the other's source. Contract changes between them (data shapes in Postgres, cache key/value
formats in Redis) MUST be treated as breaking-change boundaries, not internal refactors.

**Rationale**: Independent deployability lets the high-traffic read path (`redirect/`) scale
and release on its own schedule, unconstrained by the slower-moving, feature-heavy `ui/`.

### II. Redirect Is a Minimal Read-Path Service

`redirect/` exposes exactly two logical endpoints: the redirect lookup — `GET /{code}`, and
optionally `GET /{code}/{alias}` when the code has a registered SEO alias — and `GET /health`.
It MUST NOT gain create, update, delete, or list endpoints, authentication, or request
validation beyond looking up the code, with exactly one narrow exception: when a second path
segment is present, it MUST be checked for exact equality against the looked-up record's
registered alias (a field already fetched as part of the same lookup), returning 404 on
mismatch. This is an equality check on data already in hand, not general request validation,
and MUST NOT grow into anything more — no partial matching, normalization, or alias-specific
business logic. It is stateless and MUST be safe to run as many identical, horizontally scaled
instances with no shared in-process state. Any feature request that would add write behavior,
business logic, or auth to `redirect/` belongs in `ui/` instead.

**Rationale**: A tiny, fixed surface area is what makes the redirect path fast, cheap to
scale, and easy to reason about under load; every added responsibility erodes that.

### III. Cache-Aside Reads, Postgres as Source of Truth

Postgres is the durable source of truth for links and click data. Redis is a cache only:
evictable, fully rebuildable from Postgres, and never a hard dependency for correctness. On
each redirect, `redirect/` MUST check Redis first; on a miss, it MUST fall back to Postgres,
serve the redirect, and repopulate Redis. `ui/` MUST write to Postgres directly and write
through to Redis on create, update, and delete so `redirect/` always serves fresh data. If
Redis is unavailable, redirects MUST continue to work via Postgres.

**Rationale**: Treating Redis as disposable prevents cache outages or staleness from becoming
correctness or availability incidents.

### IV. Non-Blocking Click Recording

`redirect/` MUST record click events to Postgres asynchronously. Click recording MUST NOT
block, delay, or be a precondition for the redirect response reaching the client. Failures in
click recording MUST NOT surface as redirect errors.

**Rationale**: Analytics durability is a secondary concern to redirect latency; the user
waiting on a redirect must never pay the cost of a database write.

### V. UI Owns Writes and Business Logic

All write paths and business rules — link creation, validation, unsafe-URL rejection, SEO
alias formatting, update, delete, authentication, rate limiting on creation, and analytics —
live exclusively in `ui/`. `redirect/` MUST remain ignorant of these rules; it only looks up
codes and serves results (including reading the global, environment-configurable rate limit
for redirects, deactivated-link 410s, expired/missing-link 404s, and the alias-match check in
Principle II, all of which are inherent to serving a lookup, not business validation).

**Rationale**: Keeping business logic in one place avoids divergent validation rules and
keeps the read path free of logic that would slow it down or complicate its scaling story.

### VI. Simplicity Over Abstraction

Prefer simple, direct, well-tested code over speculative abstraction, frameworks, or
indirection. Do not introduce a layer, interface, or configuration knob until a second
concrete use justifies it. When in doubt, choose the implementation a new contributor can
understand in one read-through.

For `ui/` specifically: use current SvelteKit and Svelte idioms and APIs (e.g. Svelte 5
runes, SvelteKit's built-in routing, load functions, and form actions) rather than outdated
patterns kept out of habit — but "latest" is never license for extra complexity. When a
newer feature and an older, simpler approach both solve the problem equally well, simplicity
still wins.

**Rationale**: This is a small, well-bounded system; premature abstraction costs more in
review and maintenance than it saves. Staying current with Svelte/SvelteKit avoids
accumulating workarounds for problems the framework has already solved natively.

### VII. Test-First Delivery

Every feature MUST ship with tests before it is marked complete. This applies equally to
`redirect/` (Go) and `ui/` (SvelteKit): redirect/cache-fallback behavior, health checks,
write/validation paths, and rate limiting all require test coverage proportional to their
risk. A feature without tests is not done.

**Rationale**: A read path this thin has no room for regressions, and a write path this rich
(auth, validation, uniqueness) has no room for untested edge cases.

## Technology & Architecture Constraints

- `redirect/` is implemented in Go; `ui/` is implemented in SvelteKit. Each component's
  internal technology choices beyond this are that component's own concern, not the other's.
- Postgres is the only durable datastore for links and click data.
- Redis's primary role is as a cache in front of Postgres (used by `redirect/`'s cache-aside
  reads and `ui/`'s write-through writes) and MUST remain safely evictable and rebuildable at
  any time without data loss for that role.
- **Scoped exception**: `ui/` MAY also use Redis to store rate-limit counters, keyed by
  account, for the link creation and update routes. These counters are ephemeral and, unlike
  the cache, are not derived from or rebuildable from Postgres — losing them resets rate
  limits, not correctness. This is a distinct, narrowly bounded use, not a precedent for
  treating Redis as general-purpose or durable state. No other component or purpose may use
  Redis outside the cache role and this one exception without a further constitution
  amendment.
- `redirect/` performs no authentication and no request validation beyond code lookup;
  it applies only a global rate limiter and status rules (404 for missing/expired, 410 for
  deactivated) that fall directly out of the lookup itself.
- **No hardcoded tunable parameters**: Any operational parameter that may reasonably need to
  change over time — rate-limit thresholds and windows, timeouts, connection pool sizes, and
  similar tunables — MUST be configurable via environment variables, not hardcoded in source
  code. This applies to both `redirect/` and `ui/` equally; "global" or "simple" does not mean
  "hardcoded." Values that are structural rather than tunable (e.g. `redirect/`'s fixed set of
  two routes, or which fields a cache entry carries) are not affected by this rule.
- `ui/` MUST use current SvelteKit and Svelte best practices and APIs, avoiding
  deprecated or legacy patterns, while still preferring the simplest implementation that
  meets the requirement (Principle VI).
- **Frontend component library**: `ui/` MUST build its UI with shadcn-svelte
  (https://www.shadcn-svelte.com/docs/components — Tailwind CSS + bits-ui) rather than
  hand-rolled markup styled with raw utility classes. Where shadcn-svelte offers a component
  for a given piece of UI (buttons, inputs, forms, dialogs, badges, nav, cards, and similar),
  it MUST be used instead of a custom equivalent. Plain, hand-written CSS (bespoke stylesheets
  or `<style>` blocks implementing component-level presentation from scratch) MUST NOT be used
  where an equivalent shadcn-svelte component exists; Tailwind utility classes and
  shadcn-svelte's own theme configuration remain the styling mechanism throughout. This does
  not require every existing page to be rewritten at once, but new and materially changed UI
  MUST follow this rule, and existing hand-rolled UI should migrate to shadcn-svelte components
  as it's next touched.
- **Domain separation**: `redirect/` is served on the bare domain (`bl8.us`); `ui/` is served
  on a subdomain (`admin.bl8.us`). The two components' path namespaces never need to avoid
  colliding with each other — `redirect/`'s `/{code}`, `/{code}/{alias}`, `/health` and `ui/`'s
  `/links`, `/auth`, `/health`, etc. live on entirely different hosts. This is what makes
  Principle I's independence concrete at the deployment level, not just at the code level.

## Frontend Design Workflow

Before writing or materially modifying any UI/frontend code in `ui/`, the `frontend-design` and
`ui-ux-pro-max` skills MUST be consulted to inform the visual and UX approach before
implementation begins. This applies to new pages/components and materially changed existing
ones; trivial copy edits, bug fixes with no visual/interaction change, and config-only changes
are exempt.

**Rationale**: Consulting established design guidance before writing code produces more
deliberate, consistent UI decisions than styling ad hoc during implementation, and avoids
generic-looking output that has to be redone later.

**Mobile-first**: Every screen or component MUST be designed and implemented mobile-first. The
smallest viewport (mobile, verified at a 375px width) is the default layout and the sole
source of truth for structure and content — not a stripped-down variant of a desktop design
produced afterward. Larger breakpoints (tablet, desktop) MUST extend the mobile layout via
responsive logic — revealing additional components/content, expanding collapsed sections, or
reflowing existing elements as space allows — rather than introducing separate parallel
layouts per breakpoint. Content MUST NOT be hidden at the mobile breakpoint unless it is
already present and functional there first. Every component MUST be verified working at
375px width before larger breakpoints are implemented.

**Rationale**: This guarantees the core experience is fully functional on the most constrained
viewport, and prevents desktop-first designs that degrade or break when scaled down.

**Design reference**: All UI/UX design and implementation MUST match the reference images at
`docs/design.png` (overall look, feel, color palette, typography, and visual style) and
`docs/form_content.png` (the primary link-shortening/QR-code form, and overall page content
layout and orientation). Both images MUST be consulted before making any visual, layout, or
component decision. Where a screen or component isn't shown in either reference, its design
MUST extend the visual language the references establish rather than introducing a new,
unrelated style.

**Rationale**: A concrete visual reference removes ambiguity that guidance alone leaves open,
and keeps every screen visually coherent with the two anchor references instead of drifting
screen-by-screen.

## Ambiguity Resolution

When a requirement, design choice, or UI/UX decision is ambiguous or admits multiple reasonable
interpretations, do not guess and proceed silently. Ask a clarifying question that briefly
states what is ambiguous and the likely options and their trade-offs, before implementing.

**Rationale**: A wrong guess on an ambiguous requirement is more expensive to unwind than a
short pause to ask — this project would rather spend a clarifying question than rework from a
misread requirement.

## Localization

This application is English-only. There is no localization or internationalization (i18n)
support, and none should be added — no locale negotiation, translated strings, or
locale-specific formatting.

## Governance

This constitution supersedes conflicting practices, READMEs, or ad-hoc conventions in either
component. Amendments require: a documented rationale, an explicit version bump per the
policy below, and updating this file in the same change that introduces the governance
change.

**Versioning policy** (semantic versioning applied to governance):
- MAJOR: Backward-incompatible governance changes, e.g. removing or redefining a principle
  (such as relaxing the redirect service's minimal-surface guarantee).
- MINOR: A new principle or materially expanded guidance is added.
- PATCH: Clarifications, wording, or non-semantic fixes.

All feature work must be checked against these principles during planning and review;
deviations require an explicit, documented justification in the relevant plan, not silent
drift. Complexity that isn't justified by a real, current need should be rejected in review.

**Version**: 3.6.0 | **Ratified**: 2026-08-14 | **Last Amended**: 2026-08-17
