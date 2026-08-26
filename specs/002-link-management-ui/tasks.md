---

description: "Task list template for feature implementation"
---

# Tasks: Link Management Web Application

**Input**: Design documents from `/specs/002-link-management-ui/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. The constitution's Test-First Delivery principle requires every feature to
ship with tests before being marked complete, so contract/server-route tests (Vitest, against
real Postgres+Redis) and end-to-end tests (Playwright) are part of every user-story phase.

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P4) so each can be
implemented, tested, and demoed independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)
- File paths are relative to `ui/` unless otherwise noted

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization per plan.md's Project Structure

- [X] T001 Initialize the SvelteKit (Svelte 5, TypeScript) project at `ui/` with `adapter-node`, per plan.md Project Structure
- [X] T002 Add production dependencies to `ui/package.json`: `@auth/sveltekit`, `drizzle-orm`, `postgres` (Postgres driver for Drizzle), `ioredis`, `qrcode`
- [X] T003 Add dev dependencies to `ui/package.json`: `drizzle-kit`, `vitest`, `@playwright/test`, `testcontainers`, `@testcontainers/postgresql`, `@testcontainers/redis`
- [X] T004 [P] Configure linting/formatting (ESLint + Prettier with the Svelte plugins) in `ui/.eslintrc.cjs` / `ui/.prettierrc`
- [X] T005 [P] Configure `ui/svelte.config.js` to use `adapter-node`
- [X] T006 [P] Write `ui/Dockerfile` with separate `dev` (hot-reload) and `prod` (`adapter-node` build run under `node`) stages, per plan.md
- [X] T007 [P] Write `ui/docker-compose.yml` wiring this app to local Postgres and Redis containers for development

**Checkpoint**: `pnpm run dev` boots an empty SvelteKit app; `docker compose up` brings up app + Postgres + Redis.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T008 Define the Drizzle schema for `users`, `links`, and `click_events` in `ui/src/lib/server/db/schema.ts`, per data-model.md (`users.google_subject_id` unique; `links.code` unique; `links.slug` nullable with no uniqueness constraint; `links.owner_id` references `users.id`; `links.is_active`, `links.expires_at`, timestamps; `click_events.code` references `links.code` with `ON DELETE CASCADE`, per FR-022 — this app owns and migrates the `click_events` schema even though only `redirect/` writes rows to it)
- [X] T009 Configure the Drizzle Postgres client in `ui/src/lib/server/db/client.ts`
- [X] T010 Generate and commit the initial migration (`ui/drizzle/`) via `drizzle-kit generate`, enforcing the `links.code` unique constraint at the database level (data-model.md)
- [X] T011 [P] Configure the write-only Redis client (`ioredis`) in `ui/src/lib/server/redis.ts`, per research.md (this app never reads from Redis)
- [X] T012 [P] Configure `@auth/sveltekit` with only the Google provider in `ui/src/lib/server/auth.ts`, including automatic user-account creation for a new `google_subject_id` on first login (FR-015, FR-016), a session `maxAge` of 72 hours (FR-018), and the `[...auth]` route contract in `ui/src/routes/auth/[...auth]/+server.ts` (contracts/auth.md)
- [X] T013 Wire the session into `ui/src/hooks.server.ts` so every route can read the current user, and requests to protected routes without a valid session are rejected/redirected (FR-001)
- [X] T014 [P] Implement the link-cache write-through module in `ui/src/lib/server/linkCache.ts` with `set(code, {destinationUrl, isActive, expiresAt, slug})` (JSON-encodes to key `link:{code}` via Redis `SET`) and `remove(code)` (`DEL link:{code}`), matching `redirect/`'s cache key/value shape exactly (data-model.md's write-through contract table)

**Checkpoint**: Foundation ready — schema exists, a user can authenticate via Google and get a session, and the Redis write-through helper is ready to be called by any story.

---

## Phase 3: User Story 1 - Create a short link (Priority: P1) 🎯 MVP

**Goal**: A logged-in user can turn a long URL into a working short link (always a system-generated code), optionally with a slug and expiration, with invalid/unsafe URLs and malformed slugs rejected.

**Independent Test**: Log in, submit a valid long URL (with and without a slug, with and without an expiration), confirm a new link is created and its Redis write-through key appears immediately; confirm malformed/unsafe URLs and malformed slugs are rejected with no link created.

### Tests for User Story 1

- [X] T015 [P] [US1] Server-route test for `POST /links/new` covering FR-002–FR-007, FR-017, and FR-019 (valid create, create with a well-formed slug, malformed slug, malformed URL, unsafe URL, past expiration, rate-limit exceeded — asserting the 400/429 status codes per FR-019), plus an SC-004 assertion that the Redis key exists within 2 seconds of the response, in `ui/tests/server/links-create.test.ts`, against real test Postgres + Redis (research.md)
- [X] T016 [P] [US1] Unit tests for the URL-safety module (scheme allow-list, private-network block-list) and the slug-format validator (charset, length boundaries) in `ui/tests/unit/urlSafety.test.ts` and `ui/tests/unit/slugFormat.test.ts`
- [X] T017 [P] [US1] Unit tests for the rate-limit module (account-keyed counter, threshold behavior) in `ui/tests/unit/ratelimit.test.ts`
- [X] T018 [P] [US1] End-to-end test for the create-link flow (Google test-OIDC login → create → link appears) in `ui/tests/e2e/create-link.spec.ts`

### Implementation for User Story 1

- [X] T019 [P] [US1] Implement the URL-safety module in `ui/src/lib/server/urlSafety.ts` (structural validation, scheme allow-list, internal/private-network block-list — FR-005, FR-006) and the slug-format validator in `ui/src/lib/server/slugFormat.ts` (lowercase alphanumeric + hyphens, 3–32 chars — FR-007; research.md)
- [X] T020 [P] [US1] Implement the Redis-backed rate-limit module in `ui/src/lib/server/ratelimit.ts`: `checkAndConsume({userId, action})` keyed `ratelimit:create:acct:{userId}`, with the threshold/window read from environment variables (e.g. `RATE_LIMIT_MAX`, `RATE_LIMIT_WINDOW_SECONDS`) rather than hardcoded (FR-017; research.md — account-keyed only, no IP branch since unauthenticated requests never reach this point per FR-001)
- [X] T021 [US1] Implement the create-link server action in `ui/src/routes/links/new/+page.server.ts`: rate-limit check first (its own 429, not aggregated — FR-017/FR-019), then run URL-safety, slug-format (reusing T019), and expiration-in-the-past (FR-023) checks independently and collect every failure into one `errors` map (FR-021 — do NOT short-circuit on the first failure) → if none, generate a unique `code` → Postgres insert → `linkCache.set` write-through (including `slug`) → redirect to the link's detail page (FR-002, FR-003, FR-004, FR-007, FR-013, FR-014, FR-017, FR-021, FR-023; contracts/links.md)
- [X] T022 [US1] Implement the create-link form UI in `ui/src/routes/links/new/+page.svelte` (URL input, optional SEO-slug input, optional expiration date input, per-field validation error display)
- [X] T023 [US1] Implement the read-only link detail/confirmation page (`ui/src/routes/links/[code]/+page.svelte` + `+page.server.ts` load, ownership-checked per FR-010, returning 403/404 per contracts/links.md's `GET /links/{code}` entry) showing the short URL, destination, slug/code, and expiration — the page User Story 2 will extend with edit/delete controls

**Checkpoint**: User Story 1 is fully functional and independently testable/demoable.

---

## Phase 4: User Story 2 - Manage existing links (Priority: P2)

**Goal**: A logged-in user can update (including deactivate/reactivate) or permanently delete their own links, and can never affect another user's links.

**Independent Test**: Create a link, update its destination/expiration/active status, confirm the Redis key reflects each change immediately; delete it and confirm both the Postgres row and the Redis key are gone; as a second account, confirm update/delete attempts on the first user's link are rejected.

### Tests for User Story 2

- [X] T024 [P] [US2] Server-route test for `PATCH /links/{code}` covering FR-007, FR-008, FR-010, FR-017, FR-019 (successful update of each field including slug, unsafe/invalid new URL leaves link unchanged, malformed new slug leaves link unchanged, non-owner rejected, rate-limit exceeded — asserting the 400/403/404/429 status codes per FR-019) in `ui/tests/server/links-update.test.ts`
- [X] T025 [P] [US2] Server-route test for `DELETE /links/{code}` covering FR-009, FR-010 (successful delete removes both Postgres row and Redis key, non-owner rejected, not rate-limited) in `ui/tests/server/links-delete.test.ts`
- [X] T026 [P] [US2] Server-route test for `GET /links` covering ownership scoping (only the caller's own links are returned) in `ui/tests/server/links-list.test.ts`
- [X] T027 [P] [US2] End-to-end test for update/delete flows, including a cross-account rejection case, in `ui/tests/e2e/manage-links.spec.ts`

### Implementation for User Story 2

- [X] T028 [US2] Implement the `GET /links` list route (`ui/src/routes/links/+page.server.ts` load + `ui/src/routes/links/+page.svelte`), scoped to the caller's own links, paginated 100/page, newest-first, with an empty-state message and create-link CTA when the caller has zero links (FR-010, FR-020; contracts/links.md; spec.md Acceptance Scenario 2.5)
- [X] T029 [US2] Add the update action to `ui/src/routes/links/[code]/+page.server.ts`: ownership check, then rate-limit check (its own 429, not aggregated — FR-017/FR-019), then run URL-safety (on any new destination URL), slug-format (on any new slug, reusing T019), and expiration-in-the-past (FR-023, on any new expiration) checks independently and collect every failure into one `errors` map (FR-021 — do NOT short-circuit on the first failure) → if none, Postgres update → `linkCache.set` write-through with the full new state (FR-007, FR-008, FR-010, FR-013, FR-014, FR-017, FR-021, FR-023; contracts/links.md)
- [X] T030 [US2] Add the delete action to `ui/src/routes/links/[code]/+page.server.ts`: ownership check → Postgres delete → `linkCache.remove` write-through (FR-009, FR-010, FR-013, FR-014; data-model.md)
- [X] T031 [US2] Extend `ui/src/routes/links/[code]/+page.svelte` with an edit form (destination URL, slug, expiration, active/deactivated toggle) and a delete control with confirmation

**Checkpoint**: User Stories 1 and 2 both work independently; a user has a full link lifecycle.

---

## Phase 5: User Story 3 - View click analytics for a link (Priority: P3)

**Goal**: A logged-in user can see click counts over time and a referrer breakdown for any link they own, with an empty report (not an error) for a link with no clicks.

**Independent Test**: Drive a few requests through `redirect/` for one of this app's links so `click_events` rows exist, then open that link's analytics page and confirm counts/referrers match; confirm a link with no clicks shows an empty report; confirm a second account is rejected from viewing it.

### Tests for User Story 3

- [X] T032 [P] [US3] Server-route test for `GET /links/{code}/analytics` covering FR-011, FR-010 (counts-over-time + referrer breakdown for a link with clicks, empty report for a link with none, non-owner rejected, not-found for a deleted code) in `ui/tests/server/links-analytics.test.ts`, seeding `click_events` rows directly against the test Postgres per `redirect/`'s data-model.md shape
- [X] T033 [P] [US3] End-to-end test for viewing an analytics report, including the empty-report case, in `ui/tests/e2e/view-analytics.spec.ts`

### Implementation for User Story 3

- [X] T034 [P] [US3] Implement the analytics aggregation module in `ui/src/lib/server/analytics.ts`: click counts grouped by day and by referrer, reading `click_events` for a given `code` (FR-011; data-model.md)
- [X] T035 [US3] Implement `ui/src/routes/links/[code]/analytics/+page.server.ts` (ownership check, load via T034; FR-010, FR-011; contracts/analytics.md)
- [X] T036 [US3] Implement `ui/src/routes/links/[code]/analytics/+page.svelte` (counts-over-time display, referrer breakdown, empty-state message)

**Checkpoint**: User Stories 1–3 all work independently.

---

## Phase 6: User Story 4 - Generate a QR code for a link (Priority: P4)

**Goal**: A logged-in user can get a scannable QR code for any link they own.

**Independent Test**: Request the QR route for an owned link, confirm the returned image decodes to that link's short URL; confirm a second account is rejected from requesting it.

**Superseded (2026-08-24, constitution v6.0.0)**: T037–T039 below describe `ui/`'s original,
now-removed implementation (`GET /links/{code}/qr`, ownership-checked). QR generation moved to
`redirect/`'s `GET /{code}/qr` (public, no ownership check) — see Phase 14 below for the
removal/repoint work on the `ui/` side, and `specs/001-redirect-service/tasks.md` for the new
endpoint's own tasks. Left `[X]` here as a record of what was originally built, not what's live.

### Tests for User Story 4

- [X] T037 [P] [US4] Server-route test for `GET /links/{code}/qr` covering FR-012, FR-010 (image returned and decodes to the short URL, non-owner rejected, not-found for a deleted code) in `ui/tests/server/links-qr.test.ts`
- [X] T038 [P] [US4] End-to-end test requesting and decoding a QR code in `ui/tests/e2e/qr-code.spec.ts`

### Implementation for User Story 4

- [X] T039 [US4] Implement `ui/src/routes/links/[code]/qr/+server.ts`: ownership check, generate a PNG QR image at least 512×512px (via `qrcode`) encoding the link's short URL, return with `Content-Type: image/png` (FR-012; contracts/qr.md)

**Checkpoint**: All four user stories are independently functional.

---

## Phase 14: QR Generation Moved to redirect/ (constitution v6.0.0)

**Purpose**: Move QR generation off `ui/` per the user's explicit request ("move qr code
generation to redirector") and constitution v6.0.0's Principle II amendment. `ui/` keeps only a
thin link/embed to `redirect/`'s new public endpoint. See research.md's "QR code generation" →
"Moved (2026-08-24...)" entry for the full rationale, including why the ownership check is
dropped (forced by `redirect/`'s no-auth rule, not a separate risk decision).

- [X] T092 Remove `ui/src/routes/links/[code]/qr/+server.ts` and its tests
      (`ui/tests/server/links-qr.test.ts`, `ui/tests/e2e/qr-code.spec.ts`)
- [X] T093 [P] Add `buildQrImageUrl(code)` to `ui/src/lib/shortUrl.ts`, pointing at
      `redirect/`'s public `{domain}/{code}/qr`
- [X] T094 Update `ui/src/routes/links/[code]/+page.svelte`'s QR image/link and "QR code" nav
      button to use `buildQrImageUrl` (external link, `target="_blank"`) instead of the removed
      local route
- [X] T095 [P] Remove the now-unused `qrcode`, `@types/qrcode`, `jsqr`, `pngjs`, `@types/pngjs`
      packages from `ui/package.json` and reinstall to update the lockfile
- [X] T096 Update `ui/tests/unit/slugFormat.test.ts` — no reserved-word test needed (`"qr"` was
      already impossible as a slug under the existing 3-char minimum; documented via a
      comment in `slugFormat.ts` instead of new validation logic)

**Checkpoint**: `pnpm run check` and `pnpm run build` pass with no references to the removed
route; `redirect/`'s own Phase (specs/001-redirect-service/tasks.md) covers the new endpoint.

---

## Phase 15: QR Style Picker (constitution v7.0.0)

**Purpose**: Let a link's detail page render its QR code in any of `redirect/`'s three fixed
presets, per the user's request for "a fancier qr generator which can generate by preset
style." See research.md's "QR style picker" entry.

- [X] T097 [P] Add `QR_STYLES`/`QrStyle` and an optional `style` parameter on
      `buildQrImageUrl` to `ui/src/lib/shortUrl.ts`, mirroring `redirect/`'s `classic`/
      `rounded`/`dark` enum (hand-kept in sync — no shared code between the two deployables,
      Principle I)
- [X] T098 Add a `Tabs`-based style picker to `ui/src/routes/links/[code]/+page.svelte`
      (shadcn-svelte's existing `Tabs` component, no new component scaffolded), wired to
      ephemeral `$state` (not persisted — research.md's "No persistence" note); updates both
      the inline preview image and the "QR code" nav button's link
- [X] T099 [P] Switch the QR preview wrapper's matte color between white and Abyss (`#0d1726`)
      based on the selected style, so the `dark` preset isn't shown on a clashing white card

**Checkpoint**: `pnpm run check` and `pnpm run build` pass; manually confirmed all three
presets render and the picker updates both the preview and the nav-button link.

**Superseded (2026-08-24, constitution v8.0.0)**: T097–T099 above describe the original
three-preset `style` picker. Replaced by Phase 16 below with independent `dots`/`corners`/`bg`
controls, per the user's follow-up request. Left `[X]` here as a record of what was originally
built, not what's live.

---

## Phase 16: QR dots/corners/bg Picker + Download Button (constitution v8.0.0)

**Purpose**: Replace the single style picker with independently configurable dot shape, corner
shape, and arbitrary background color, and change the "QR code" nav button into a download
action. See research.md's "QR dots/corners/bg picker + download button" entry.

- [X] T100 [P] Replace `QR_STYLES`/`QrStyle` in `ui/src/lib/shortUrl.ts` with
      `QR_DOT_SHAPES`/`QrDotShape`, `QR_CORNER_SHAPES`/`QrCornerShape`, and a `QrOptions`-typed
      `buildQrImageUrl(code, { dots, corners, bg })`, mirroring `redirect/`'s new parameters
      (hand-kept in sync, no shared code between the two deployables — Principle I)
- [X] T101 Replace the single style `Tabs` picker in
      `ui/src/routes/links/[code]/+page.svelte` with two independent `Tabs` pickers (Dots,
      Corners) plus a native `<input type="color">` bound to a hex string for background;
      switch the preview wrapper's background to an inline style bound to the chosen color
      (not a fixed Tailwind class list, since `bg` is arbitrary)
- [X] T102 Replace the "QR code" nav button with a "Download QR" button (Lucide `download`
      icon): `fetch()` the current styled image, convert to a blob, trigger a synthetic
      `<a download>` click — requires `redirect/`'s `Access-Control-Allow-Origin: *` (T044) to
      work cross-origin

**Checkpoint**: `pnpm run check` and `pnpm run build` pass; manually confirmed every
dots×corners combination renders, a custom background color updates the preview and downloaded
file, and clicking "Download QR" actually saves a file rather than opening a new tab.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Operational readiness and final validation across all stories

- [X] T040 [P] Implement `ui/src/routes/health/+server.ts`: a live, unauthenticated JSON reachability check against Postgres, for infra probes (this app's own liveness signal, analogous to `redirect/`'s health route; plan.md Project Structure)
- [X] T041 [P] Implement the public, unauthenticated system-status page (`ui/src/routes/status/+page.server.ts` load + `+page.svelte`), reusing T040's Postgres reachability check, human-readable (FR-025; plan.md Project Structure)
- [X] T042 [P] Write `ui/README.md` covering local setup (`docker compose up`, `drizzle-kit push`, `pnpm run dev`) and how to run each test suite
- [X] T043 Run through quickstart.md's manual validation steps end-to-end against a Dockerized dev environment
- [X] T044 Review `specs/002-link-management-ui/checklists/review.md` and address or explicitly defer each remaining open item
- [X] T045 [P] Accessibility pass across create/manage/analytics/QR flows (FR-024): keyboard operability and screen-reader-compatible labeling for interactive elements, spot-checked with an automated tool (e.g. axe) plus manual keyboard-only navigation
- [X] T046 Implement a structured-logging module in `ui/src/lib/server/logger.ts` and wire it into the create (T021), update (T029), delete (T030) actions and every rejection path (validation, ownership, rate-limit) across those and the analytics/QR routes: one structured log entry per mutation (acting account + affected code) and per rejection (reason, acting account or IP if unauthenticated), with no other user's data included (FR-026)
- [X] T047 [P] Unit/server test asserting the configured Google session `maxAge` is 72 hours (FR-018) in `ui/tests/unit/auth.test.ts`
- [X] T048 [P] Server-route test for `GET /links/{code}` (the detail page from T023) asserting a non-owner is rejected (403) and a deleted/nonexistent code returns 404 (FR-010) — the one non-owner-rejection case that had no dedicated test, unlike update/delete/analytics/QR — in `ui/tests/server/links-detail.test.ts`
- [X] T049 Migrate the package manager from npm to pnpm (plan.md, research.md): remove `package-lock.json`, generate `pnpm-lock.yaml`, add `@auth/core` as an explicit dependency (pnpm's strict node_modules surfaced it as a phantom transitive dependency that npm's flatter hoisting had been masking), add `pnpm.onlyBuiltDependencies` for `esbuild`/`cpu-features`/`protobufjs`/`ssh2`, and update `Dockerfile`, `playwright.config.ts`, `README.md`, and `quickstart.md` from `npm`/`npx` to `pnpm`/`pnpm exec`
- [X] T050 Add Tailwind CSS via `sv add tailwindcss` (plan.md, research.md): wires `@tailwindcss/vite` into `vite.config.ts` and imports it in `src/routes/+layout.svelte`

---

## Phase 8: Design System Foundation (Blocking Prerequisite for Phases 9–10)

**Purpose**: shadcn-svelte adoption, the light/dark token system, and typography per
constitution v3.6.0's Technology & Architecture Constraints and Frontend Design Workflow;
research.md's "Frontend component library", "Light/dark mode", "Design reference — visual
system"

**⚠️ CRITICAL**: No re-skin work (Phase 9) or public-shorten-form work (Phase 10) can begin
until this phase is complete

- [X] T051 Run the shadcn-svelte CLI init (`pnpm dlx shadcn-svelte@latest init`) in `ui/`, pointing `components.json`'s `tailwind.css` at the existing `ui/src/routes/layout.css` (no new global CSS file — research.md)
- [X] T052 [P] Add the `mode-watcher` dependency and mount `<ModeWatcher />` in `ui/src/routes/+layout.svelte` (FR-027; research.md's "Light/dark mode")
- [X] T053 Define the light (`:root`) and dark (`.dark`) OKLCH token scopes in `ui/src/routes/layout.css` per research.md's "Design reference — visual system": white/navy/teal-green light scope, navy-background dark scope reusing the reference's hero color, one teal-green `--primary` shared across both, and an enlarged `--radius` for the pill-button/rounded-card look both references share
- [X] T054 [P] Add `Plus Jakarta Sans` (display) and `Inter` (body) font loading in `ui/src/app.html`, replacing the prior monospace-for-short-codes treatment (research.md — neither reference renders codes in a monospace face)
- [X] T055 Add the shadcn-svelte components needed across the app to `ui/src/lib/components/ui/` (`pnpm dlx shadcn-svelte@latest add button input label field badge card tabs dropdown-menu alert-dialog separator`)
- [X] T056 Implement `ui/src/lib/components/ModeToggle.svelte`: a `DropdownMenu`-based light/dark/system switcher using `mode-watcher`'s `setMode`/`resetMode` (FR-027)
- [X] T057 Restyle `ui/src/lib/components/Header.svelte` with shadcn-svelte's `Button`/`DropdownMenu` and the new token system, adding `ModeToggle` (T056) to the nav

**Checkpoint**: The app runs on shadcn-svelte + the new token system; light/dark/system switching works app-wide via the header, even though individual pages haven't been re-skinned yet.

---

## Phase 9: Re-skin Existing Pages (extends US1–US4)

**Goal**: Every existing page matches the new design system (Phase 8) instead of the prior
hand-rolled dark/monospace styling, per constitution v3.6.0's design-reference rule, which
applies to all UI, not just new work.

**Independent Test**: Each restyled page still passes its existing story's tests (Phases 3–6)
unchanged in behavior — this phase is visual only, no server-route logic changes — and is
verified at 375px width before wider breakpoints (constitution: Mobile-first).

- [X] T058 [P] [US1] Restyle `ui/src/routes/links/new/+page.svelte` with shadcn-svelte `Field`/`Input`/`Button` (mobile-first: verify at 375px before wider breakpoints)
- [X] T059 [US2] Restyle `ui/src/routes/links/[code]/+page.svelte`: the read-only detail view and the edit form with shadcn-svelte `Card`/`Badge`/`Field`/`Input`/`Select`, the QR thumbnail in a `Card` (keeping its `bg-white` tile for scannability), and the delete control as a shadcn-svelte `AlertDialog` in place of the native `confirm()` (per shadcn-svelte's composition rules) (mobile-first)
- [X] T060 [US2] Update `ui/tests/e2e/manage-links.spec.ts`'s delete step from the native-dialog (`page.once('dialog', ...)`) pattern to the `AlertDialog` introduced in T059 (click "Delete" → confirm in the dialog) — the existing test would otherwise hang waiting for a native dialog that no longer appears
- [X] T061 [P] [US2] Restyle `ui/src/routes/links/+page.svelte` (list) with shadcn-svelte `Card`/`Badge`/`Button`, replacing the prior hand-rolled manifest-row markup (mobile-first)
- [X] T062 [P] [US3] Restyle `ui/src/routes/links/[code]/analytics/+page.svelte` with shadcn-svelte `Card`, re-theming the existing CSS bar-rows to the new token colors (mobile-first)
- [X] T063 [P] Restyle `ui/src/routes/status/+page.svelte` with shadcn-svelte `Card`/`Badge` (mobile-first) — no story label, matches the original T041 cross-cutting pattern

**Checkpoint**: All existing pages match the new design system; Phases 3–6's tests (with T060's update) still pass.

---

## Phase 10: Public Shorten Form on the Landing Page (FR-028, FR-029) — extends US1

**Goal**: A signed-out visitor can start creating a link from the public landing page; the
link is only ever written after they authenticate, and their input is never lost across the
Google sign-in redirect (spec.md Acceptance Scenarios 6–7, research.md's "Public shorten-form:
auth gating and continuation").

**Independent Test**: Signed out, submit a valid URL on `/` → complete Google sign-in → land
on the result page with no re-entry required; repeat with an invalid URL → land on `/links/new`
with the input pre-filled and errors shown; while already signed in, submit on `/` → identical
immediate-creation behavior to `/links/new`.

### Tests for Phase 10

- [X] T064 [P] [US1] Server-route test for the carried-through creation path: an authenticated `GET /links/new?url=...&slug=...&expiresAt=...` creates the link and redirects to the result page; an invalid carried URL renders the form pre-filled with validation errors instead of silently discarding the input (FR-029; contracts/links.md's `GET /links/new` entry) in `ui/tests/server/links-new-carrythrough.test.ts`
- [X] T065 [P] [US1] End-to-end test: a signed-out visitor submits the public shorten form, completes sign-in (via the `e2e-test` Credentials provider), and lands on the result page with no re-entry; a second run asserts an already-signed-in submission on `/` behaves identically to `/links/new` in `ui/tests/e2e/public-shorten-form.spec.ts`

### Implementation for Phase 10

- [X] T066 [US1] Implement `ui/src/lib/components/ShortenForm.svelte`: the tabbed Short Link/QR Code card (shadcn-svelte `Tabs`/`Field`/`Input`/`Button`) matching the design reference's structure, shared by the landing page (T067) and `/links/new` (T058) (FR-028; research.md)
- [X] T067 [US1] Rebuild `ui/src/routes/+page.svelte`'s logged-out state: a dark-navy hero band containing `ShortenForm`, followed by an honest explanation of what bl8 does (research.md's "Design reference — content honesty" — no fabricated testimonials/stats/logos), matching the design reference's spacing and section rhythm; the logged-in state is unchanged (mobile-first)
- [X] T068 [US1] `ShortenForm` (T066) submits directly to `/links/new`'s existing `default` action (`ui/src/routes/links/new/+page.server.ts`, T021) — no new route needed. Add a branch there, before the current `error(401, ...)` throw: when no session exists, redirect to Google sign-in with the submitted `url`/`slug`/`expiresAt` carried as `callbackUrl` query parameters targeting `/links/new` (FR-029)
- [X] T069 [US1] Extend `ui/src/routes/links/new/+page.server.ts`'s `load` to detect carried `url`/`slug`/`expiresAt` query parameters for an authenticated session (arriving via T068's redirect), run T021's creation logic, and redirect to the result page on success or pre-fill the form with validation errors shown on failure (FR-029; contracts/links.md)

**Checkpoint**: FR-028/FR-029 fully functional and independently testable; User Story 1 now has two working entry points (public landing page, `/links/new` directly) sharing one component and one server-side creation path.

---

## Phase 11: Design System Polish

**Purpose**: Cross-cutting validation for Phases 8–10

- [X] T070 [P] Verify every restyled/new component from Phases 8–10 at 375px width before confirming wider breakpoints, per constitution's Mobile-first rule
- [X] T071 Run quickstart.md's "Validate: theme (light/dark/system)" and "Validate: public shorten form" sections end-to-end against a Dockerized dev environment
- [X] T072 [P] Re-run the accessibility pass (FR-024) across all restyled pages, confirming shadcn-svelte's bits-ui-backed primitives (`AlertDialog`, `Tabs`, `DropdownMenu`) meet keyboard-operability and screen-reader-labeling requirements — extends the original T045

---

## Phase 12: Design Token Corrections (constitution v4.2.0)

**Purpose**: `ui/src/routes/layout.css` already implements the Increase Design System
correctly (Fog/Mint Signal/Abyss/Inkwell Navy, with real WCAG AA contrast fixes beyond what
research.md originally specified) — Phases 8–11 evidently already targeted it, not the earlier
Stratus/Bitly palette. Verified directly against the running code before writing this phase
(`ui/src/routes/layout.css`, `ui/src/routes/links/**`) rather than assumed. What's actually
still missing, matched against `docs/design/styles.css` and research.md's "Correction
(2026-08-20)" entry:

- No `--color-code` token — the design system's dedicated code/data accent (`#7ec4ff`) has
  never been added, so short codes (already rendered in `font-mono`) have no distinct color.
- `Badge` uses shadcn's default pill radius (`rounded-4xl`) — the design system defines a
  separate, smaller `--r-tag: 4px` specifically for tags, and bl8's badges (slug, status) are
  exactly that.
- Headings use generic Tailwind scale/tracking (`text-2xl tracking-tight`, etc.) rather than
  the design system's exact `clamp()`-based sizes and letter-spacing.

Everything else research.md's "Correction" entry describes (mint-tint hover fill, navy-tinted
multi-layer shadows, Inter/JetBrains Mono fonts, no Voltage yellow anywhere) is **already
correctly implemented** — confirmed by reading `layout.css` directly, not re-built here.

- [X] T073 Add `--color-code` to `ui/src/routes/layout.css`'s `@theme inline` block and a
      corresponding `--code` value in both `:root` and `.dark` (code-blue `#7ec4ff`, mapped to
      OKLCH and contrast-checked against each scope's background — darken for light mode if
      needed, matching the existing pattern already used for `--ring`/`--muted-foreground`).
      Apply `text-code` to short-code rendering in `ui/src/routes/links/+page.svelte` (list),
      `ui/src/routes/links/[code]/+page.svelte` (detail heading), and
      `ui/src/routes/links/new/+page.svelte` (slug-preview line's code portion, if
      distinguishable from the slug text itself)
- [X] T074 [P] Override `Badge`'s radius in `ui/src/lib/components/ui/badge/badge.svelte` from
      `rounded-4xl` to the design system's tag radius (`rounded-[4px]`), matching
      `docs/design/styles.css`'s `--r-tag`
- [X] T075 [P] Tighten the most prominent headings — the landing hero `<h1>`
      (`ui/src/routes/+page.svelte`), page-level `<h1>`s (`ui/src/routes/links/+page.svelte`
      and similar), and `Card.Title` section headers — to the design system's exact
      `clamp()`-based size/letter-spacing values from `docs/design/styles.css` where they
      currently use approximated Tailwind scale classes; leave smaller/secondary text as-is
      (Principle VI — not chasing every heading level pixel-for-pixel, per research.md's
      "Correction" rationale)
- [X] T076 [P] Verify every changed component from T073–T075 at 375px width before confirming
      wider breakpoints, per constitution's Mobile-first rule
- [X] T077 [P] Re-run the accessibility pass (contrast especially) on the new `--color-code`
      value and the resized headings from T073/T075
- [X] T078 Run quickstart.md's "Validate: Increase Design System tokens" section (all 9 steps,
      including the four added for this amendment) end-to-end against a Dockerized dev
      environment

---

## Phase 13: Landing Page Structural Rebuild (constitution v5.0.0)

**Purpose**: Constitution v5.0.0 widened "Design reference" from tokens-only to also cover
layout/structure. A direct visual comparison (`playwright-cli`) confirmed the live landing page
and `docs/design/index.html` were structurally unalike despite correct token application —
inverted hero, missing announcement bar, different nav, tabbed vs. flat form, and several
sections the app lacked entirely. See research.md's "Design reference — structural rebuild
(constitution v5.0.0)" for the section-by-section adopt/replace/omit decisions this phase
implements. Scoped to the landing page (`/`) and its shared components (`Header.svelte`,
`ShortenForm.svelte`) — no changes to `/links/**`, auth, or any write path.

- [X] T079 [P] Create `ui/src/lib/components/AnnounceBar.svelte`: full-bleed Voltage
      (`bg-[#e4ff33]` or an equivalent token) bar, single line, non-dismissible, copy "Every
      link includes click tracking and a QR code, automatically." — truthful, evergreen
      (research.md: no fabricated "news" to announce). Mount at the very top of
      `ui/src/routes/+layout.svelte`, above `Header.svelte`.
- [X] T080 Rebuild `ui/src/lib/components/Header.svelte`'s nav: replace the current nav-item set
      with anchor links to `#features` / `#how` / `#faq` plus the existing `/status` route, and
      nav actions `Sign in with Google` (ghost, existing OAuth trigger unchanged) / `Get started`
      (primary, anchor-scrolls to `#tool`). Collapse to a menu toggle below the existing mobile
      breakpoint, matching `docs/design/`'s `.nav-toggle` pattern — verify at 375px first
      (mobile-first).
- [X] T081 Rewrite `ui/src/lib/components/ShortenForm.svelte`: remove the `Short Link`/`QR Code`
      tab switcher entirely; replace with a flat form (Long URL required + Custom back-half
      optional, `bl8.us/` prefix shown per the slug field, matching `docs/design/`'s
      `.field-row` pattern) that stacks at 375px and lays out as two columns + submit button at
      desktop widths (`sm:`/`md:` breakpoint). Submit behavior (validation, auth-gated creation,
      carry-through query params per research.md's "Public shorten-form" decision) is unchanged
      — this is a layout-only rewrite of the same form fields plus one field removed (the QR/
      Short-Link mode toggle), not new logic.
- [X] T082 [US4] Confirm `ui/src/routes/links/[code]/+page.svelte` (the link detail page) still
      renders/links its QR code clearly, since T081 removes the only other place QR generation
      was surfaced pre-creation — add a brief "QR code" heading/section there if the existing
      presentation assumed the hero form's QR tab as the primary discovery path
- [X] T083 Rebuild the hero section of `ui/src/routes/+page.svelte`: light background
      (`--background`/Fog, not the fixed dark-Abyss override), navy headline text, an eyebrow
      label above the headline (e.g. "URL Shortener"), matching `docs/design/`'s `.hero`
      composition. Remove the dark-hero-specific decorative facet SVGs (`hero-facet-a/b/c`) —
      they were built for the inverted dark treatment being removed. Mount the rewritten
      `ShortenForm` (T081) below/overlapping the hero per the reference's `.tool-card` overlap
      pattern.
- [X] T084 [P] Add a `#features` section to `ui/src/routes/+page.svelte`: restructure the
      existing "What bl8 does" content into `docs/design/`'s icon-badge/3-column grid pattern
      with an eyebrow + heading + subheading section head — keep bl8's real three features
      (short links, click tracking, QR codes), not padded to match the reference's six
- [X] T085 [P] Add a `#how` "How it works" section to `ui/src/routes/+page.svelte`: numbered
      `01`/`02`/`03` steps (paste URL → optionally customize → share and track), matching
      `docs/design/`'s `.steps` pattern, with bl8-accurate copy
- [X] T086 [P] Add a `#faq` section to `ui/src/routes/+page.svelte` with bl8-specific, truthful
      answers per research.md ("Do short links expire?" / "Can I change where a link points?")
      — omit any question with no truthful answer (e.g. pricing)
- [X] T087 Add a final CTA band to `ui/src/routes/+page.svelte`: heading + subheading + a single
      primary button ("Shorten a link", anchor-scrolls to `#tool`) — no secondary ghost button,
      since the reference's second action links to API docs bl8 doesn't have
- [X] T088 Create a minimal `ui/src/lib/components/Footer.svelte` (logo + short tagline +
      copyright + a link to `/status`, the one real cross-cutting link that exists today) and
      mount it in `ui/src/routes/+layout.svelte` below the page content — not the reference's
      4-column Product/Resources/Company grid, most of which has no bl8 equivalent
- [X] T089 Verify every section touched by T079–T088 at 375px width before confirming wider
      breakpoints (constitution: Mobile-first)
- [X] T090 Re-run an accessibility pass on the rebuilt landing page: announcement bar as a
      `role="banner"`-adjacent but non-obstructive region, nav landmark and anchor-link focus
      order, heading hierarchy across the new sections (one `h1`, `h2`s per section), contrast
      on the light hero's navy-on-Fog text
- [X] T091 Run quickstart.md's new "Validate: landing page structural rebuild (constitution
      v5.0.0)" section end-to-end against a Dockerized dev environment, plus a re-run of the
      existing "Validate: public shorten form" section (both updated for the flat-form/QR-on-
      detail-page changes) and User Story 4's existing QR test to confirm nothing regressed

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational only
- **User Story 2 (Phase 4)**: Depends on Foundational; reuses US1's `urlSafety`/`ratelimit`/`linkCache` modules and `[code]/+page.server.ts` (extends the file T023 created) and is not independently *implementable* before US1, but is independently *testable/demoable* once both are done
- **User Story 3 (Phase 5)**: Depends on Foundational only; independent of US1/US2 code (reads `click_events`, which US1/US2 never write) — could be implemented in parallel with US1/US2 by a different contributor, though a link must exist (from US1) to demo it end-to-end
- **User Story 4 (Phase 6)**: Depends on Foundational only; independent of US1/US2/US3 — could be implemented in parallel
- **Polish (Phase 7)**: Depends on all desired user stories being complete
- **Design System Foundation (Phase 8)**: Independent of Phases 1–7's *behavior*, but touches
  the same UI files Phases 3–6 already created — start only once Phases 1–7 are complete, to
  avoid churn on in-flight files. Blocks Phases 9 and 10.
- **Re-skin (Phase 9)**: Depends on Phase 8 only; visual-only changes to already-implemented,
  already-tested pages
- **Public Shorten Form (Phase 10)**: Depends on Phase 8 (design system) and Phase 3 (T021's
  creation logic, which T069 reuses); independent of Phase 9 (different files) so could run in
  parallel with it
- **Design System Polish (Phase 11)**: Depends on Phases 8–10 being complete
- **Design Token Corrections (Phase 12)**: Depends on Phase 11 being complete (it re-verifies
  mobile-first/accessibility on top of the corrected tokens); independent of Phases 1–7's
  behavior — token/component-only changes
- **Landing Page Structural Rebuild (Phase 13)**: Depends on Phase 12 being complete (T073's
  `--color-code` token and T074's badge radius are used by the rebuilt sections); depends on
  User Story 4 (Phase 6) for the QR-code route T082 confirms; independent of Phases 3–5's
  business logic (no write-path or auth changes) and of `/links/**` pages other than the QR
  check in T082

### Within Each User Story

- Tests are written first and must fail before implementation (constitution Test-First Delivery)
- Shared modules (urlSafety, ratelimit, linkCache) before the routes that call them
- Server actions/routes before the UI that calls them

### Parallel Opportunities

- All Setup tasks marked [P] (T004–T007) in parallel
- T011, T012, T014 in Foundational in parallel (different files); T013 depends on T012
- Within US1: T015–T018 (tests) in parallel; T019/T020 in parallel; T021 depends on T019+T020+T014+T010
- Within US2: T024–T027 (tests) in parallel; T028 in parallel with T029/T030 (different files)
- Within US3: T032/T033 in parallel; T034 before T035
- Within US4: T037/T038 in parallel
- Once Foundational (Phase 2) is done, US3 and US4 can proceed fully in parallel with US1/US2 if staffed, since neither touches `urlSafety`/`ratelimit`/`linkCache`/the create-or-update path
- Within Phase 8: T052/T054/T055 in parallel; T053 (tokens) can run alongside them (different file from T052/T054); T051 (CLI init) should complete first since it creates `components.json` that T055's `add` commands need; T056/T057 depend on T051–T055
- Within Phase 9: T058/T061/T062/T063 in parallel (different files); T059 is standalone (its own file, not shared with T058/T061); T060 depends on T059 (same behavior, different file — a test following its implementation)
- Within Phase 10: T064/T065 (tests) in parallel; T066 before T067–T069 (they render/use it); T068/T069 depend on T066
- Phase 9 and Phase 10 can run fully in parallel with each other once Phase 8 is done (disjoint files, except both read the Phase 8 token system)
- Within Phase 13: T079 (new file) in parallel with everything; T080/T081 touch different files
  and can run in parallel with each other, but T083 (hero) depends on T081 (`ShortenForm`)
  existing in its new flat form before it's mounted; T084/T085/T086 are parallel (all add
  disjoint sections to the same `+page.svelte`, but each is a self-contained `<section>` insert
  — coordinate to avoid a merge conflict rather than treating them as fully independent files);
  T087/T088 come after the sections they close out; T089/T090/T091 are sequential validation
  passes at the end

---

## Parallel Example: User Story 1

```bash
# Tests together:
Task: "Server-route test for POST /links/new in ui/tests/server/links-create.test.ts"
Task: "Unit tests for urlSafety in ui/tests/unit/urlSafety.test.ts"
Task: "Unit tests for ratelimit in ui/tests/unit/ratelimit.test.ts"
Task: "E2E test for create-link flow in ui/tests/e2e/create-link.spec.ts"

# Shared modules together:
Task: "Implement urlSafety module in ui/src/lib/server/urlSafety.ts"
Task: "Implement ratelimit module in ui/src/lib/server/ratelimit.ts"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (blocks everything)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: run T015–T018 and confirm the independent test criteria above
5. Deploy/demo if ready — a user can already create working, safe short links

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. User Story 1 → validate → deploy/demo (MVP)
3. User Story 2 → validate → deploy/demo (full link lifecycle)
4. User Story 3 → validate → deploy/demo (analytics)
5. User Story 4 → validate → deploy/demo (QR codes)
6. Polish (Phase 7)

### Parallel Team Strategy

After Foundational is done:
- Developer A: User Story 1, then User Story 2 (2 depends on 1's shared modules)
- Developer B: User Story 3 (independent)
- Developer C: User Story 4 (independent)

### Design System Amendment (Phases 8–11)

Added after the original feature (T001–T050) was already implemented and shipped, per
constitution v3.2.0–v3.6.0 (shadcn-svelte mandate, light/dark mode, mobile-first, design
reference images):

1. Complete Phase 8: Design System Foundation (blocks everything below)
2. Phase 9 (re-skin) and Phase 10 (public shorten form) in parallel — disjoint files
3. Phase 11: Design System Polish — validate mobile-first, theme, and the new public-form flow
4. **STOP and VALIDATE**: re-run Phases 3–6's existing test suites plus T060/T064/T065/T072 to
   confirm nothing regressed

### Design Token Corrections (Phase 12)

Added after constitution v4.2.0 repointed the design reference at the local `docs/design/`
implementation. Narrower than the Phase 8–11 amendment above — most of the design system was
already correctly implemented; this closes the specific gaps found by reading the current code
directly (T073–T075), then re-validates (T076–T078).

### Landing Page Structural Rebuild (Phase 13)

Added after constitution v5.0.0 widened the design reference from tokens-only to also cover
layout/structure, triggered by a direct visual comparison confirming the app and
`docs/design/index.html` were structurally unalike. Unlike Phase 12 (a token-only correction),
this is a real rebuild of the landing page's markup and component composition:

1. T079–T081: build the new shared pieces (announcement bar, nav, flat form) first
2. T082: confirm QR generation's new-only discovery path (the link detail page) still works,
   since T081 removes the hero form's QR tab
3. T083: rebuild the hero around the new form
4. T084–T088: add/adapt the remaining sections (features, how-it-works, FAQ, final CTA, footer)
5. T089–T091: mobile-first re-verification, accessibility pass, full quickstart re-run
6. **STOP and VALIDATE**: re-run quickstart.md's "Validate: public shorten form" and User Story
   4's QR test to confirm the flat-form rewrite and QR relocation didn't regress either flow

---

## Notes

- [P] tasks touch different files with no unmet dependencies
- [Story] labels map every user-story-phase task back to spec.md for traceability
- Verify each test fails before implementing the task it covers
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently
- T029/T030 both modify `ui/src/routes/links/[code]/+page.server.ts` (already created by T023) — not parallelizable with each other
- T059 touches `ui/src/routes/links/[code]/+page.svelte` (created by T023, extended by T031) — not parallelizable with anything else touching that file
- T066 (`ShortenForm.svelte`) is a shared component consumed by both T058 (`/links/new`) and T067 (`/`) — do not restyle either consumer's usage of it before T066 exists
- T068/T069 both modify `ui/src/routes/links/new/+page.server.ts` (created by T021) — not parallelizable with each other
