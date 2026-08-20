# Implementation Plan: Link Management Web Application

**Branch**: `002-link-management-ui` | **Date**: 2026-08-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-link-management-ui/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

A SvelteKit application (frontend + server-side routes, not a static frontend) that owns all
URL-shortener business logic: Google-authenticated link creation (with an optional SEO alias
and expiration), update/delete, per-link click analytics, and QR code generation. Server
routes talk directly to Postgres for all reads and writes of link, user, and analytics data,
and write through the corresponding change to Redis on create/update/delete so `redirect/`
serves fresh state immediately. Login is via Google OAuth only, and no unauthenticated request
can reach any protected route. Rate limiting on the creation and update routes is keyed by
account. Deploys
as an `adapter-node` build, Dockerized for both development and production, fully independent
of `redirect/`'s own deployment — the two share nothing except the Postgres and Redis
instances.

**Amendment (2026-08-17)**: The UI layer is being migrated from hand-rolled Tailwind markup to
shadcn-svelte components (Tailwind CSS + bits-ui), per constitution v3.2.0's Technology &
Architecture Constraints, with a light/dark/system theme toggle (`mode-watcher`, defaulting to
system, manually overridable and persisted) added alongside it. See research.md's "Frontend
component library", "Light/dark mode", and "Light palette" decisions.

**Amendment (2026-08-17, v2)**: Constitution v3.6.0 adds a concrete design-reference
requirement (two reference images: one for color/typography/visual style, one for the top
shorten/QR form and page orientation), which **supersedes** the "Light palette"
decision above with a reconciled visual system — see research.md's "Design reference — visual
system", "Design reference — content honesty", and "Public shorten-form: auth gating and
continuation" decisions. The public landing page gains a functional (not decorative) tabbed
Short Link/QR Code form matching the reference; submitting it while signed out carries the
entered values through the Google sign-in redirect and completes creation afterward — FR-001
still holds (no Postgres write happens before authentication), only the entry point changes.

**Amendment (2026-08-18, v3)**: Constitution v4.0.0 removed the prior image-based design
reference entirely; v4.1.0 replaced it with a single external
reference — the "Increase Design System" (an institutional fintech/banking design system) —
governing color, typography, and visual style only (not layout/orientation). Existing page
structure is retained (Principle VI: the new rule doesn't ask for restructuring); only the
color tokens, fonts, and radius/shadow values change. See research.md's "Design reference —
Increase Design System" for the full hex→OKLCH token mapping, the font-licensing note (Inter/
JetBrains Mono used as the constitution's own documented fallbacks for the unavailable
commercial "Untitled Sans"/"Input Mono"), and the reintroduction of monospace styling for short
codes.

**Amendment (2026-08-20, v4)**: Constitution v4.2.0 repoints the design reference at a local
working implementation, `docs/design/` (`styles.css`/`index.html`), rather than the external
style-guide URL — same design system, more precise source. See research.md's "Design reference
— Increase Design System" → "Correction (2026-08-20, constitution v4.2.0)" for the specific
fixes: an actual mint-tint hover fill (not neutral gray, as previously guessed), the exact type
scale and shadow recipes (not approximated), and a new code-specific accent color (`#7ec4ff`)
applied to short-code chips. All localized token-level corrections — no structural changes.

## Technical Context

**Language/Version**: TypeScript, SvelteKit (Svelte 5) on Node.js 22 LTS. Package manager:
`pnpm` (resolved 2026-08-17 — see research.md).

**Primary Dependencies**: `@auth/sveltekit` with the Google provider (OAuth login, session
cookies, CSRF handling); `drizzle-orm` + `drizzle-kit`, on the `postgres` (porsager) driver
(typed Postgres access and migrations — this app owns the schema, so typed migrations are
directly useful, not speculative); `ioredis` (Redis write-through client); `qrcode`
(server-side QR code generation); `tailwindcss` + `@tailwindcss/vite` (styling — resolved
2026-08-17, see research.md); `shadcn-svelte` (CLI-scaffolded components) + `bits-ui`
(headless primitives it wraps) + `@lucide/svelte` (icon set) — frontend component library,
constitution-mandated (resolved 2026-08-17, see research.md); `mode-watcher` — light/dark/
system theme switching with persistence (resolved 2026-08-17, see research.md); `Inter`
(display/heading + body/UI font) + `JetBrains Mono` (code/data — short codes, aliases) —
typography per the "Increase Design System" constitution reference (resolved 2026-08-18, see
research.md's "Design reference — Increase Design System"; Inter/JetBrains Mono are the
constitution's own documented fallbacks for the unlicensed commercial "Untitled Sans"/"Input
Mono"; supersedes the prior `Plus Jakarta Sans` display font and the dropped-monospace
decision — monospace for short codes is back)

**Storage**: Postgres (source of truth for users, links, and click-analytics reads — this app
owns the schema and runs migrations); Redis (write-through target only — this app never reads
from Redis, `redirect/` is the only reader; see Constitution Check)

**Testing**: Vitest for unit and server-route tests; Playwright for end-to-end flows (login
through create/update/delete/analytics/QR), with Google's real OAuth consent screen bypassed
via a test-only `Credentials` provider gated behind `E2E_TEST_MODE=true` (never active
otherwise) that still goes through Auth.js's own real credential-exchange and cookie-signing —
a real third-party login can't run headlessly in CI (research.md)

**Target Platform**: Node.js container (Docker), `adapter-node` build, deployed independently
of `redirect/`'s deployment, served on the `admin.bl8.us` subdomain (constitution: domain
separation — `redirect/` owns the bare `bl8.us` domain)

**Project Type**: Web application — single SvelteKit project combining frontend and
server-side routes (not a separate frontend/backend split; SvelteKit's server routes are the
backend here)

**Performance Goals**: Standard interactive web-app responsiveness (sub-second response for
create/update/delete/list actions under normal load); write-through to Redis completes as part
of the same request/transaction that writes Postgres, so `redirect/` reflects changes within 2
seconds p95 (spec SC-004)

**Constraints**: Must deploy and scale independently of `redirect/` (separate Docker
image/process, separate release cadence); must share no state with `redirect/` beyond the
Postgres and Redis instances themselves (no direct network calls between the two services);
Google is the only login method — no password storage

**Scale/Scope**: Multi-user SaaS-style web app; every link, update, delete, analytics view,
and QR generation is scoped to the authenticated owner

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Independent, Non-Overlapping Components | PASS | This plan touches only `ui/`; deploys independently (`adapter-node`, own Docker image) from `redirect/`; the two share only the Postgres and Redis instances, not code or a network API between them. |
| II. Redirect Is a Minimal Read-Path Service | N/A here | Enforced by the redirect plan, not this one; this plan doesn't touch `redirect/`. |
| III. Cache-Aside Reads, Postgres as Source of Truth | PASS | `ui/` writes to Postgres first (source of truth) and write-throughs to Redis in the same operation on create/update/delete — this is exactly the write side of the pattern the constitution assigns to `ui/`. `ui/` never depends on Redis for correctness (it never reads from Redis). |
| IV. Non-Blocking Click Recording | N/A here | Click recording is `redirect/`'s responsibility; `ui/` only reads/aggregates click data for analytics, never records clicks. |
| V. UI Owns Writes and Business Logic | PASS | All write paths (create/update/delete), URL validation, unsafe-URL rejection, alias formatting, auth, and creation/update-route rate limiting live here, matching the constitution exactly. |
| VI. Simplicity Over Abstraction | PASS | `@auth/sveltekit` is used instead of hand-rolling OAuth2 (state/PKCE/token exchange is exactly the kind of security-sensitive code a vetted library should own, not a speculative abstraction). `drizzle-orm` is justified because this app owns the schema and needs real migrations — not added as a defensive layer over a currently-unneeded need. No repository/service-layer indirection beyond what SvelteKit's own `+page.server.ts`/`+server.ts` routing already provides. |
| VII. Test-First Delivery | PASS (commitment) | Vitest (unit/server-route) and Playwright (end-to-end) tests are scoped in Project Structure below and required before any task is marked complete in `/speckit-tasks` → `/speckit-implement`. |

**Newer constitution sections (v3.2.0–v3.4.0)**, added after this feature's original design:

| Section | Status | Notes |
|---|---|---|
| Technology & Architecture Constraints — Frontend component library | PASS (this plan) | This plan is precisely the shadcn-svelte migration the constraint requires — see "Frontend component library" in research.md. |
| Frontend Design Workflow | PASS (this plan) | The `frontend-design` and `ui-ux-pro-max` skills are used to design the light palette (research.md's "Light palette") before implementation, and MUST continue to be used for any further UI work on this feature. |
| Ambiguity Resolution | PASS (this plan) | The dark-mode requirement ("default to system") was genuinely ambiguous between a system-only theme and a manual toggle defaulting to system; resolved via an explicit clarifying question rather than assumed — see research.md's "Light/dark mode". Whether the public shorten form should live behind a login wall or on the public page was also ambiguous given FR-001; resolved by asking directly — see research.md's "Public shorten-form: auth gating and continuation". |
| Frontend Design Workflow — Design reference | PASS (this plan) | The prior image-based design-reference rule was removed in constitution v4.0.0 and replaced in v4.1.0 by the "Increase Design System" URL; v4.2.0 repointed it at the local `docs/design/` implementation, read directly (not just its earlier prose summary) before drafting research.md's "Correction (2026-08-20)" entry. The new rule scopes only color/typography/visual style (not layout), so existing structure is knowingly retained rather than re-derived — a deliberate reading of the rule's actual scope, not an oversight. |

No violations. Complexity Tracking table is empty and omitted below.

**Post-Phase 1 re-check**: data-model.md, contracts/, and quickstart.md add nothing beyond what
Technical Context already covers — `GET /links` (a list endpoint, needed for the "manage
existing links" UI implied by User Story 2) reads only the caller's own rows, and every
contract enforces the ownership check from FR-010. The Redis write-through key/value shape is
defined to exactly match what `redirect/`'s own data-model.md expects to read, keeping the two
components' only shared contract explicit rather than implicit. All seven applicable principles
above still PASS unchanged after design.

**Re-check after the 2026-08-17 amendments**: the shadcn-svelte migration and light/dark mode
addition touch only presentation-layer code (`src/lib/components/`, `src/routes/layout.css`,
`+layout.svelte`) — no new domain entities, no new write paths, no new interface contracts.
data-model.md is unchanged. contracts/links.md gained one clarifying addition (the public
landing page's shorten form can now reach `POST /links/new`'s existing creation logic via a
new `GET /links/new` query-param carry-through path after sign-in — same validation, same
outcomes, no new write path, FR-001 still holds since the write only happens post-auth).
quickstart.md gains two new validation sections (theme toggle + visual smoke-check; the public
shorten-form's logged-in/logged-out/carry-through-after-signin behaviors). All principles and
the newer constitution sections above still PASS.

**Re-check after the 2026-08-18 amendment**: the design-system swap (Increase Design System
tokens replacing the Stratus-era teal-green ones) is a token/typography-only change to files
already covered by the prior re-check — no new entities, write paths, or contracts. quickstart.md
gains one new validation section (color/typography spot-check against the new tokens). All
principles and constitution sections still PASS.

**Re-check after the 2026-08-20 amendment**: the token corrections (mint-tint hover, exact
shadow/type-scale values, the new code-accent color) are refinements to the same files the
2026-08-18 re-check already covers — no new entities, write paths, or contracts, no structural
change. quickstart.md's existing token-validation section gains a few more specific checks
rather than a new section. All principles and constitution sections still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/002-link-management-ui/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
ui/
├── src/
│   ├── hooks.server.ts                       # sequence(authHandle, requireAuth) — auth + FR-001 route gate
│   ├── routes/
│   │   │ # No routes/auth/[...auth] file: @auth/sveltekit's handle (lib/server/auth.ts)
│   │   │ # intercepts /auth/* before SvelteKit routing — resolved 2026-08-17, see research.md
│   │   ├── links/
│   │   │   ├── +page.svelte                 # list/manage view (User Story 2)
│   │   │   ├── +page.server.ts               # load: list owner's links
│   │   │   ├── new/
│   │   │   │   ├── +page.svelte               # create form (User Story 1)
│   │   │   │   └── +page.server.ts              # action: create (validate, alias check, write-through)
│   │   │   └── [code]/
│   │   │       ├── +page.svelte                  # edit/detail view (User Story 2)
│   │   │       ├── +page.server.ts                 # actions: update, delete (ownership-checked)
│   │   │       ├── analytics/
│   │   │       │   ├── +page.svelte                  # report view (User Story 3)
│   │   │       │   └── +page.server.ts                 # load: click counts over time + referrers
│   │   │       └── qr/
│   │   │           └── +server.ts                       # GET: QR image for the link (User Story 4)
│   │   ├── health/
│   │   │   └── +server.ts                     # GET: JSON liveness check for infra probes (Postgres reachability)
│   │   ├── status/
│   │   │   ├── +page.svelte                     # public, unauthenticated human-readable status page (FR-025)
│   │   │   └── +page.server.ts                    # load: same Postgres reachability check as health/+server.ts
│   │   ├── +layout.svelte                          # imports layout.css, mounts <ModeWatcher />
│   │   └── layout.css                                # @import "tailwindcss"; + shadcn-svelte OKLCH tokens
│   │                                                    # in :root / .dark — Increase Design System palette
│   │                                                    # (Fog/Mint-Signal/Abyss/Inkwell-Navy) — resolved 2026-08-18
│   ├── lib/
│   │   ├── server/
│   │   │   ├── db/                             # drizzle schema + client (links, users, click_events read)
│   │   │   ├── redis.ts                         # write-through client (ioredis), write-only from ui/
│   │   │   ├── linkCache.ts                       # Redis write-through: set(code, {...}) / remove(code)
│   │   │   ├── urlSafety.ts                       # structural checks: scheme + private-network (FR-006)
│   │   │   ├── aliasFormat.ts                       # SEO alias format validation (FR-007)
│   │   │   ├── ratelimit.ts                         # Redis-backed limiter: keyed by account
│   │   │   ├── analytics.ts                           # click-count aggregation (day-bucketed) + referrers (FR-011)
│   │   │   ├── logger.ts                                # structured logging for mutations/rejections (FR-026)
│   │   │   └── auth.ts                                # @auth/sveltekit config, Google provider
│   │   ├── components/
│   │   │   ├── ui/                               # shadcn-svelte generated components (button, input, badge,
│   │   │   │                                        # card, tabs, dropdown-menu, field, alert-dialog, ...) —
│   │   │   │                                        # resolved 2026-08-17, added via CLI as pages migrate
│   │   │   ├── Header.svelte                     # app nav bar, composed from shadcn-svelte primitives
│   │   │   ├── ModeToggle.svelte                    # light/dark/system switcher (mode-watcher)
│   │   │   └── ShortenForm.svelte                     # tabbed Short Link/QR Code hero card — structure
│   │   │                                                # retained from the prior design reference (Principle
│   │   │                                                # VI; the current constitution rule governs color/type
│   │   │                                                # only, not layout), shared by the public landing page
│   │   │                                                # and /links/new
│   │   └── utils.ts                                # shadcn-svelte's cn() class-merge helper (CLI-generated)
│   └── app.d.ts
├── components.json                          # shadcn-svelte CLI config — resolved 2026-08-17
├── drizzle/                                 # generated SQL migrations (drizzle-kit)
├── static/
├── Dockerfile                              # dev and prod targets, adapter-node build, pnpm via corepack
├── docker-compose.yml                       # local dev: this app + Postgres + Redis
├── vite.config.ts                            # adapter-node + tailwindcss() plugins (no separate svelte.config.js —
│                                               # current sv-cli scaffolds configure the adapter here instead)
├── package.json
├── pnpm-lock.yaml
└── tests/
    ├── unit/                                # Vitest: urlSafety, aliasFormat, ratelimit, auth session config
    ├── server/                               # Vitest: +page.server.ts / +server.ts route behavior
    └── e2e/                                    # Playwright: full flows against a real (test) Postgres+Redis
```

**Structure Decision**: Single SvelteKit project rooted at `ui/` (the repository's other
independent component, alongside `redirect/`, per constitution Principle I). SvelteKit's own
routing already separates concerns (pages vs. server actions vs. API-only routes under
`+server.ts`), so there's no separate `frontend/`/`backend/` split — the "backend" *is* the
`+page.server.ts`/`+server.ts` layer within this one project, consistent with constitution
Principle VI (no indirection beyond what's already load-bearing).

## Complexity Tracking

*No constitution violations — this section intentionally left empty.*
