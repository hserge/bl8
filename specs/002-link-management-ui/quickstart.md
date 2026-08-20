# Quickstart: Link Management Web Application

Validates the feature end-to-end against real Postgres and Redis, with Google login replaced
by a test OIDC provider for local/automated runs. See contracts/ for exact request/response
shapes and data-model.md for schema details.

## Prerequisites

- Node.js 22 LTS, Docker
- A Google OAuth client (for manual testing of the real login flow) — for automated
  local/CI runs, a test OIDC provider stands in instead (research.md)

## Setup

```bash
cd ui/
docker compose up -d db redis
pnpm install
pnpm exec drizzle-kit push   # apply schema (users, links, click_events) to the local Postgres
pnpm run dev                 # or: docker compose up ui (Dockerized dev target)
```

## Validate: create a link (User Story 1)

1. Sign in with Google (or the test OIDC provider in dev/CI).
2. Submit a valid long URL with no alias → expect a new link with a generated code, visible
   immediately in `GET /links`.
3. Submit another valid long URL with a well-formed SEO alias (e.g. `my-article-title`) →
   expect a new link with its own generated code, the alias attached, resolvable at both
   `/{code}` and `/{code}/my-article-title`.
4. Submit a URL with a malformed alias (e.g. `AB`, too short, or containing `_`) → expect
   rejection (FR-007), no link created.
5. Submit a malformed URL (e.g. `not a url`) → expect rejection (FR-005), no link created.
6. Submit a URL with a disallowed scheme (e.g. `javascript:alert(1)`) or targeting an internal
   address → expect rejection (FR-006), no link created.

Confirm in Redis (`redis-cli GET` on the write-through key) that each successfully created
link's mapping — including its `alias` field — appears immediately; this is what `redirect/`
will read on its next
cache-aside lookup, without waiting for a cache miss (FR-014).

## Validate: manage a link (User Story 2)

1. Update the link created above (change destination URL, or toggle `isActive` off).
2. Confirm the Redis key for that `code` reflects the new state immediately.
3. As a second user account, attempt to update or delete the first user's link → expect
   `403 Forbidden` and no change (FR-010).
4. Delete the link as its owner → confirm the Postgres row is gone and the Redis key for that
   `code` is removed (not just marked inactive) — distinct from step 2's deactivation.

## Validate: view analytics (User Story 3)

1. Drive a few requests through the redirect service (`redirect/`) for one of this app's
   links, so `click_events` rows exist.
2. Open that link's `/links/{code}/analytics` page → expect click counts over time and a
   referrer breakdown matching what was driven through.
3. Open the analytics page for a link with no clicks → expect an empty report, not an error.
4. As a second user account, attempt to view the first user's link's analytics → expect
   `403 Forbidden`.

## Validate: QR code (User Story 4)

1. Request `/links/{code}/qr` for an owned link → expect an image response; scan it (or decode
   it programmatically in a test) and confirm it resolves to the link's short URL.
2. As a second user account, request the same path → expect `403 Forbidden`.

## Validate: rate limiting on creation

```bash
# authenticated, same account, in a loop past the configured limit
for i in $(seq 1 <limit+10>); do curl -s -o /dev/null -w "%{http_code}\n" -b "<session-cookie>" -X POST http://localhost:PORT/links/new -d "url=https://example.com"; done
```

Expected: once the account-keyed limit is exceeded, subsequent responses return `429` instead
of creating more links. Repeating this unauthenticated (no session cookie) should simply
return a rejection from the auth gate (FR-001) rather than ever reaching the rate limiter.

## Validate: system status page

```bash
curl -i http://localhost:PORT/status   # no auth — expect 200, human-readable, Postgres reachable
curl -i http://localhost:PORT/health   # expect 200 JSON, same underlying check
# stop Postgres
curl -i http://localhost:PORT/status   # expect the page to show Postgres as unreachable, no login required
```

## Validate: theme (light/dark/system)

1. Open the app with no prior visit (fresh browser profile or cleared site data) → expect the
   theme to match the OS's current light/dark setting, with no visible flash of the wrong
   theme on load.
2. Use the mode toggle in the header to pick "Light" or "Dark" explicitly → expect the whole
   app (nav, forms, badges, buttons) to switch immediately using shadcn-svelte's semantic
   tokens, not a partially-themed page.
3. Reload the page → expect the explicit choice from step 2 to persist (not revert to system).
4. Switch the toggle back to "System" → expect the app to track the OS setting again,
   including live changes to it without a manual reload (if the OS setting is changed while
   the app is open).
5. Spot-check contrast and legibility in both themes on the create-link form, links list, and
   analytics report — these were the pages most reliant on the prior hand-tuned dark-only
   palette.

## Validate: public shorten form (landing page)

1. While signed out, open `/` → expect the dark-navy hero with the tabbed Short Link/QR Code
   card, not the previous plain sign-in-only landing page.
2. While signed out, submit a valid long URL → expect a redirect into Google's sign-in flow
   (no link created yet — confirm nothing appears in `GET /links` for any account as a result
   of this step alone).
3. Complete sign-in from step 2 → expect to land directly on the new link's detail/result
   page, with no need to re-enter the URL.
4. Repeat step 2 with a URL that fails validation (e.g. malformed) → after completing
   sign-in, expect to land on `/links/new` with the URL pre-filled and the validation error
   shown, not a silently-discarded submission.
5. While already signed in, submit the same public-page form → expect immediate creation and
   redirect to the result page, matching `/links/new`'s existing behavior exactly.

## Validate: Increase Design System tokens

1. Open the app in light mode → expect a Fog-canvas (`#edf0f2`) page background with white
   (`#ffffff`) cards, Inkwell-Navy (`#1a2b3b`) text, and Mint-Signal (`#31f2bf`) buttons/links/
   focus rings — not the prior teal-green-on-white Stratus palette.
2. Switch to dark mode → expect an Abyss (`#0d1726`) page background with Inkwell-Navy
   (`#1a2b3b`) cards, light-neutral text, and the same Mint-Signal accent.
3. Confirm short codes and aliases (links list, link detail, the create-form preview line)
   render in a monospace face (JetBrains Mono) — reintroduced in this amendment, distinct from
   the surrounding Inter body text.
4. Confirm no "Voltage" yellow (`#e4ff33`) appears anywhere in the UI — it's reserved by the
   constitution for a full-bleed announcement bar this app doesn't have.
5. Spot-check card corner radius (~12px) and button/input radius (~8–10px) look visually
   distinct-but-related, not identical or jarringly mismatched.
6. Hover a button/link → expect a faint mint-tinted fill (not plain gray) — the corrected
   `--accent` value (2026-08-20).
7. Confirm short-code chips (links list, link detail) render in a distinct light-blue
   (`#7ec4ff`-derived) color, visually separate from the app's mint-colored buttons/links.
8. Confirm the hero form card's shadow reads as a soft, diffused navy-tinted glow rather than a
   sharp gray drop-shadow — the corrected `--shadow-elevated` value.
9. Confirm heading text (page titles, hero headline) has visibly tighter letter-spacing than
   body text, while small uppercase labels (if any) look slightly *more* spaced out than body
   text, not tighter — the type scale's tracking direction reverses between headings and labels.

## Automated tests

- Unit tests: `pnpm run test:unit` (Vitest) — `urlSafety`, alias-format validation, rate-limit
  key logic, session `maxAge` config.
- Server-route tests: `pnpm run test:unit -- tests/server` (Vitest, against real Postgres +
  Redis via testcontainers — requires Docker).
- End-to-end: `pnpm run test:e2e` (Playwright; Google sign-in bypassed via a test-only
  credentials login path — `tests/e2e/helpers.ts` — since the real consent screen can't be
  automated headlessly).
