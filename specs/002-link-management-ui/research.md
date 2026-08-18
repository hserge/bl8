# Phase 0 Research: Link Management Web Application

All Technical Context items were resolvable from the feature description, the ratified spec
(including its two resolved clarifications — safe-URL checking and Google-only auth), and the
constitution. No `NEEDS CLARIFICATION` markers remain. This document records the decisions and
why alternatives were rejected.

## Server-side routing approach

**Decision**: Use SvelteKit's own `+page.server.ts` (form actions, `load`) and `+server.ts`
(API-only endpoints, e.g. QR image, health) — no separate backend framework.

**Rationale**: The feature explicitly requires "server-side routes (not just frontend)," which
is exactly what SvelteKit's server-route layer is for. Introducing a separate API framework
(e.g. a standalone Express/Fastify service behind the SvelteKit frontend) would duplicate
routing, add a network hop, and contradict constitution Principle VI (no layer without a
concrete need — SvelteKit's server routes already fully cover this app's API surface).

**Alternatives considered**: A separate Node API service consumed by a static SvelteKit
frontend — rejected; the feature asks for one deployable app with server routes, not a
frontend/backend split, and splitting would add a deployment and a network boundary with no
corresponding benefit here.

## Authentication

**Decision**: `@auth/sveltekit` (Auth.js) configured with only the Google provider.

**Rationale**: FR-015/FR-016 require Google-only login with automatic account creation on
first login and no password-based registration. Auth.js handles the OAuth2/OIDC exchange,
state/PKCE, session cookie issuance, and CSRF protection — all security-sensitive code that is
better owned by a widely-used, audited library than hand-rolled per constitution Principle VI
("prefer... well-tested code"; a vetted auth library is the well-tested choice here, not an
unjustified abstraction).

**Alternatives considered**: Hand-rolled OAuth2 against Google's endpoints directly (e.g. via
`arctic`) — viable and lighter-weight, but pushes session-cookie/CSRF handling onto this app's
own code for no real benefit over a maintained library; rejected as unnecessary risk for a
security-critical path. A general-purpose identity platform (e.g. Auth0/Clerk) — rejected,
adds an external paid dependency and a third identity system to operate when the requirement is
specifically "Google authentication," not "any SSO."

**Identity model**: A user is keyed by their Google account's unique subject identifier (`sub`
claim), not email (spec.md Assumptions), so ownership survives an email change on the Google
side.

## Database access

**Decision**: `drizzle-orm` + `drizzle-kit` for schema definition and migrations, on top of the
`postgres` (porsager) driver — the underlying connection Drizzle needs.

**Rationale**: `ui/` owns the Postgres schema (constitution Principle V: `ui/` owns all writes
and business logic, which includes the schema that data validation and uniqueness constraints
rely on) and is the only component that ever migrates it — confirmed, not just assumed, and
consistent with `redirect/`'s own research.md ("Confirmed: schema ownership"). Drizzle gives
typed queries and a real migration workflow for that ownership without hiding SQL behind a
heavy ORM abstraction (it stays close to SQL, consistent with Simplicity Over Abstraction).

**Alternatives considered**: Raw `postgres.js`/`pg` with hand-written SQL and a separate
migration tool (e.g. `node-pg-migrate`) — viable, marginally "simpler" in dependency count, but
loses compile-time query typing for a schema this app owns and evolves; rejected since the
typed-migration benefit is concrete here, not speculative. A heavier ORM (e.g. Prisma) —
rejected as more machinery (separate codegen step, engine binary) than this app's schema size
warrants.

## Redis write-through

**Decision**: `ioredis` client, used exclusively to *write* on create/update/delete — `ui/`
never reads from Redis (it always reads Postgres directly, since Postgres is its own source of
truth for rendering pages).

**Rationale**: Matches constitution Principle III precisely: "`ui/` MUST write to Postgres
directly and write through to Redis on create, update, and delete." `ui/` has no need to read
its own cache — it's not on a latency-critical read path the way `redirect/` is, and reading
its own recent write from Postgres is simpler and always consistent.

**Alternatives considered**: `node-redis` (the official client) — also viable and equally
capable; `ioredis` chosen for its more ergonomic pipelining/cluster API, which the write-through
path benefits from when a create/update/delete writes multiple related cache entries in one
round trip. Not a load-bearing choice either way.

**Write-through key/value shape**: Mirrors exactly what `redirect/`'s cache-aside path expects
to read (see `redirect/`'s data-model.md) — this is the shared contract between the two
independently-deployed components (constitution Principle I: contract changes here are a
breaking-change boundary, not an internal refactor). Key `link:{code}`; value a single JSON
string with `destination_url` (string), `is_active` (boolean), `expires_at` (ISO 8601 UTC
string or JSON `null`) — set via Redis `SET`/`DEL`, not a hash, to avoid boolean/timestamp
string-coercion mismatches across the TypeScript/Go boundary (resolved 2026-08-17; see
data-model.md's Write-through contract for the exact shape).

## Unsafe-URL checking

**Decision**: A single `urlSafety` module performing, in order: (1) parse/structural
validation (malformed → reject, per FR-005), then (2) a scheme allow-list (only `http`/`https`
survive; `javascript:`, `data:`, etc. rejected) and a block-list for internal/private-network
targets (FR-006).

**Resolved (2026-08-17)**: An earlier draft of FR-006 also required a call to an external
URL-reputation/safe-browsing service, fail-closed on unavailability. The user removed that
requirement for now — structural checks only. The external check may be reconsidered later;
if reintroduced, revisit the fail-closed decision and provider choice noted in the prior
version of this entry.

**Rationale**: Directly implements FR-005/FR-006 as currently scoped. Dropping the external
check removes a third-party dependency and added latency from the create/update path, at the
cost of not catching structurally-valid-but-malicious destinations (phishing/malware URLs
using an allowed scheme) — an accepted tradeoff per the user's explicit scope decision.

## Rate limiting on the creation and update routes

**Decision**: A Redis-backed counter (fixed or sliding window), keyed
`ratelimit:create:acct:{userId}`, checked at the top of both the create route and the update
route, after the auth check (FR-001 already rejects unauthenticated requests before this point
— see resolved clarification below). Delete is explicitly excluded (resolved via
`/speckit-clarify`: create and update are rate-limited, delete is not — see spec.md FR-017).
The threshold (request count, time window) is read from configuration/environment variables at
startup, not hardcoded (FR-017) — unlike `redirect/`'s deliberately hardcoded limiter, which is
a distinct, separately-governed mechanism (constitution.md).

**Resolved (2026-08-17)**: An earlier draft of this decision included an IP-keyed branch for
unauthenticated requests, reasoning it would protect the auth check itself from being hammered
pre-login. The user explicitly rejected that: unauthenticated requests must never reach the
dashboard or any protected route at all (FR-001), full stop — there is no scenario where an
unauthenticated request should be rate-limited-but-otherwise-processed here. The limiter is now
account-keyed only.

**Rationale**: Because `ui/` may run more than one instance and already has Redis available
(shared with `redirect/`, but under a distinct key namespace — `ratelimit:` vs. `redirect/`'s
per-code cache keys, and now covered by the constitution's scoped Redis exception — see
constitution.md v1.2.0), a Redis-backed counter gives a consistent per-account limit across
instances, unlike an in-process counter that a multi-instance deployment could route around.

**Alternatives considered**: In-process (per-instance) rate limiting — rejected as
inconsistent across replicas, unlike `redirect/`'s deliberately per-instance limiter (simple by
design, though its threshold is configurable, not hardcoded — see `redirect/`'s constitution
v2.0.0 update); this route's requirement is a real per-account limit, which needs the shared
counter Redis already provides.

## QR code generation

**Decision**: `qrcode` npm package, generating a PNG at least 512×512px (`Content-Type:
image/png`) server-side in the `[code]/qr/+server.ts` route, encoding the link's short URL on
the `bl8.us` domain (e.g. `https://bl8.us/{code}` or `https://bl8.us/{code}/{alias}` if an
alias is set) (FR-012).

**Rationale**: Small, focused, widely-used library for exactly this one job; no server-side
rendering pipeline or external service needed. PNG at a fixed, sufficiently high resolution was
chosen over SVG for universal print/embedding compatibility (Clarifications 2026-08-17).

**Alternatives considered**: Client-side QR generation — rejected; generating server-side keeps
the short URL construction (`bl8.us`, per the constitution's domain-separation rule) in one
place and lets the QR image be linked/cached/downloaded directly.

## Testing strategy

**Decision**: Vitest for unit tests (`urlSafety`, alias-format validation, rate-limit key
logic) and server-route tests (form actions, load functions, using a real test Postgres +
Redis, not mocks, for the same reason as `redirect/`'s plan: the value here is in the real
interaction with the database and cache). Playwright for end-to-end coverage of each user
story's full flow, with Google's real consent screen bypassed via a test-only `Credentials`
provider (`id: "e2e-test"`, gated behind `E2E_TEST_MODE=true`, never registered otherwise) that
still goes through Auth.js's own real credential-exchange and cookie-signing — a real
third-party consent screen can't be automated headlessly.

**Resolved (2026-08-17)**: An earlier draft of this decision said "test/mock OIDC provider."
What was actually built and verified is narrower and simpler: not a separate mock identity
server, but one extra Auth.js provider on the same app, active only under an explicit test
flag. `tests/e2e/helpers.ts`'s `loginAsTestUser` POSTs to `/auth/callback/e2e-test` with an
`Origin` header matching the app's own origin (SvelteKit's built-in CSRF protection checks
this on same-site form POSTs; `@auth/sveltekit` intentionally disables Auth.js's separate
CSRF-token-cookie flow in favor of it).

**Rationale**: Constitution Principle VII requires tests before a feature is done. Given how
much of this app's correctness lives in database constraints (code uniqueness, alias format),
Redis write-through, and ownership scoping, integration-style tests against real Postgres/Redis
catch what pure unit tests with mocks would miss.

**Alternatives considered**: A separate mock OIDC identity server — rejected as more
infrastructure than needed; the Credentials-provider approach exercises the exact same
Auth.js session/cookie code path as the real Google provider, just with a different (test-only)
front door. Hand-rolling a signed session JWT/cookie directly (bypassing Auth.js's own
`encode`/cookie-naming logic) — rejected; that module is explicitly marked unstable in Auth.js's
own docs ("will be refactored/changed... do not rely on it"), and going through Auth.js's real
sign-in flow is no harder and doesn't depend on its internals.

## Deployment

**Decision**: `adapter-node` production build; a multi-stage Dockerfile with separate
dev (hot-reload, e.g. `vite dev`) and prod (built `adapter-node` output run under plain
`node`) targets; `docker-compose.yml` for local development wiring this app to local Postgres
and Redis containers.

**Rationale**: Matches "Deploy as an adapter-node build... Dockerised for development and
production" directly. Independent of `redirect/`'s own Docker image/deployment (constitution
Principle I) — the only shared infrastructure is the Postgres and Redis *instances* themselves,
reached over the network, not shared containers or shared code.

**Alternatives considered**: A static-adapter build behind a separate Node API — rejected for
the same reason as the routing decision above (the requirement is one app with real server
routes, not a static frontend).

## Package manager

**Decision (2026-08-17, explicit user request)**: `pnpm`, migrated from the `npm` the project
was originally scaffolded with. `Dockerfile` uses Node 22's built-in `corepack enable` to get
`pnpm` rather than installing it separately.

**Rationale**: Requested directly, not a technical tradeoff decision. One real consequence
surfaced by the migration: pnpm's strict (non-hoisting) `node_modules` layout does not expose
transitive dependencies the way npm's flatter layout does. `src/lib/server/auth.ts` imports
`@auth/core/providers/google` and `@auth/core/providers/credentials` directly — under npm this
resolved because `@auth/core` (a dependency of `@auth/sveltekit`) got hoisted to top-level
`node_modules`; under pnpm it's invisible to our own code unless declared as our own
dependency. `@auth/core` was added explicitly to `dependencies` to fix this — not a new
capability, just making an existing implicit dependency explicit, which pnpm's model requires.
Also added `pnpm.onlyBuiltDependencies` (`esbuild`, `cpu-features`, `protobufjs`, `ssh2`) in
`package.json`, since pnpm blocks postinstall scripts by default and `esbuild`'s postinstall
(fetching its platform binary) is required for Vite to function at all. A `packageManager`
field pinning the exact pnpm version (`pnpm@10.9.0`) was also added, after the Dockerfile's
`corepack enable` (with no pin) fetched a newer pnpm release whose default supply-chain policy
rejected the lockfile over transitive dependencies it considered too-recently published —
version drift between local dev and the Docker build. Pinning via `packageManager` is corepack's
standard mechanism for exactly this and keeps both environments on the same pnpm release.

**Alternatives considered**: None — this was a direct instruction, not an evaluated choice.

## Styling

**Decision (2026-08-17, explicit user request)**: Tailwind CSS, added via `sv add tailwindcss`
(no `typography`/`forms` plugins — not requested, and adding them speculatively would be
exactly the kind of unjustified abstraction constitution Principle VI warns against). This
wired `@tailwindcss/vite` into `vite.config.ts` and added `src/routes/layout.css`
(`@import "tailwindcss";`), imported from `+layout.svelte`.

**Rationale**: Requested directly. Using the official `sv add` add-on (the same tool used for
the original scaffold and for `prettier`/`eslint`/`vitest`/`playwright`/`drizzle`) keeps the
setup idiomatic and consistent with how everything else in this project was added, rather than
hand-wiring Tailwind's Vite plugin and CSS entry point manually.

**Alternatives considered**: Manual setup (install `tailwindcss`/`@tailwindcss/vite` directly,
hand-write the Vite config and CSS import) — rejected; no reason to duplicate what the
project's own scaffolding tool already does correctly.

## Frontend component library

**Decision (2026-08-17, constitution v3.2.0)**: Migrate `ui/`'s UI layer to shadcn-svelte
(Tailwind CSS + bits-ui), scaffolded and maintained via the `shadcn-svelte` CLI
(`pnpm dlx shadcn-svelte@latest init`, then `add <component>` per component as pages are
migrated) rather than hand-rolled markup styled with raw Tailwind utility classes. This
replaces the fully custom Tailwind implementation built in the prior session (hand-written
`<header>`/nav/list-row/form/badge markup across `Header.svelte` and every `routes/**`
page) with shadcn-svelte's generated, source-owned components under `src/lib/components/ui/`
(button, input, badge, card, dropdown-menu, field, alert-dialog for the delete confirmation,
etc.), composed per the CLI's own conventions (`Field.FieldGroup`/`Field.Field` for forms,
grouped `Item`s inside overlay `Group`s, `cn()` for conditional classes). `components.json`
points its `tailwind.css` at the existing `src/routes/layout.css` (kept in place — no reason
to relocate/rename it, per Principle VI) rather than introducing a second global CSS file.

**Rationale**: Directly required by the constitution's Technology & Architecture Constraints
("`ui/` MUST build its UI with shadcn-svelte..."). Beyond compliance, it gives the app
accessible, keyboard-correct primitives (bits-ui-backed dialogs, dropdowns, focus management)
that the hand-rolled version had to approximate manually (e.g. the native `confirm()` used for
delete becomes a proper `AlertDialog`), and a semantic-token theming model (`bg-primary`,
`text-muted-foreground`, ...) that generalizes cleanly to the light/dark mode requirement
below, instead of the single fixed dark palette hand-authored via a custom Tailwind `@theme`
block.

**Alternatives considered**: Keep the hand-rolled Tailwind components — rejected, violates the
constitution mandate directly. A different headless-component ecosystem (e.g. Melt UI used
directly, without shadcn-svelte's CLI/registry layer) — rejected, the constitution names
shadcn-svelte specifically, and its CLI-plus-registry workflow (vs. hand-wiring Melt UI
builders) is the simpler, more maintained path (Principle VI).

## Light/dark mode

**Decision (2026-08-17, explicit user request, clarified via AskUserQuestion)**: `mode-watcher`
(the shadcn-svelte-ecosystem package for Svelte/SvelteKit theme management) — a `<ModeWatcher
/>` component mounted in the root layout applies/removes the `.dark` class on `<html>` via a
FOUC-safe inline script, defaults to `prefers-color-scheme` (system) until the user picks
explicitly, and persists the explicit choice (localStorage) across visits. A `ModeToggle`
component (a small `DropdownMenu` with Light/Dark/System items, using mode-watcher's exported
`setMode`/`resetMode`) is added to the header, next to the existing nav. This satisfies the
user's confirmed requirement: manual override available, defaults to system, persisted — not
a system-only/no-override theme.

**Rationale**: `mode-watcher` is what shadcn-svelte's own docs point to for Svelte/SvelteKit
dark-mode support, and it directly implements the confirmed behavior (system default +
persisted manual override) without hand-rolling `prefers-color-scheme` detection and
localStorage plumbing ourselves — the kind of already-solved problem Principle VI says not to
reimplement.

**Alternatives considered**: Hand-rolled `matchMedia('(prefers-color-scheme: dark)')` listener
plus manual `localStorage` read/write — rejected, reinvents what `mode-watcher` already
solves correctly (including avoiding a flash of the wrong theme on load, which a naive
client-side-only implementation gets wrong). CSS-only `prefers-color-scheme` media query with
no manual override — rejected per the user's explicit clarification requiring a toggle.

## Light palette

**Decision (2026-08-17)**: Before implementation, use the `frontend-design` and
`ui-ux-pro-max` skills (constitution: Frontend Design Workflow) to design a companion **light**
palette expressed as shadcn-svelte's semantic OKLCH token set (`--background`,
`--foreground`, `--primary`, `--muted`, `--accent`, `--destructive`, `--border`, `--input`,
`--ring`, etc.) in `:root`, alongside the existing dark palette's *intent* — reclaimed
hyperlink-blue as `--primary`, amber reserved for the alias/SEO badge accent, desaturated
green/red for active/inactive status — re-expressed as the `.dark` scope's token values (not
copied byte-for-byte, since the prior hex values were hand-tuned for a bespoke `@theme` block,
not shadcn-svelte's token names or OKLCH format).

**Rationale**: The constitution requires both the design-skill consultation and the
shadcn-svelte token convention; treating the already-validated dark-mode design intent as the
`.dark` scope (rather than discarding it) preserves the distinctive, contrast-checked identity
from the prior redesign instead of falling back to shadcn-svelte's stock default theme, while
still needing genuine new design work for the light scope, which doesn't exist yet.

**Alternatives considered**: Adopt shadcn-svelte's stock default theme unmodified for both
scopes — rejected, abandons the already-shipped, accessibility-verified dark identity and
skips the constitution's required design-skill consultation.

## Design reference — visual system (supersedes "Light palette" above)

**Decision (2026-08-17, constitution v3.6.0, `frontend-design` + `ui-ux-pro-max` applied)**:
The constitution now names two concrete reference images with an explicit division of labor —
`docs/design.png` governs overall look/feel/color/typography/visual style; `docs/form_content.png`
governs the top shorten/QR form and overall page content orientation only. This **replaces** the
prior "Light palette" decision above (which predates the reference images) rather than sitting
alongside it.

- **Color** (from `design.png`, a light marketing-site template): white/near-white surfaces,
  deep-navy headings and primary text, a single teal-green accent for every primary action
  (buttons, links, focus rings, active nav state), warm neutral grays for secondary text and
  borders. Expressed as shadcn-svelte's semantic OKLCH tokens: `--background`/`--card` white,
  `--foreground` deep navy, `--primary` teal-green, `--muted`/`--muted-foreground` warm gray,
  `--border`/`--input` light gray, `--ring` teal-green. `--radius` is set larger than
  shadcn-svelte's default (pill-shaped buttons, generously rounded cards, matching both
  references — Stratus's pill CTAs and Bitly's rounded form card are the same structural idea).
  **Dark scope reconciliation**: `docs/form_content.png`'s hero is itself a deep-navy band —
  rather than treating that as out-of-scope (it governs structure, not color, per the user's
  explicit split) or inventing an unrelated dark palette, the `.dark` token scope reuses that
  same navy as `--background`/`--card`, with the identical teal-green `--primary` carried
  across both themes as the one consistent brand accent. This keeps light and dark as one
  coherent identity instead of two unrelated palettes, and both references end up contributing
  color information after all — `design.png` directly for light, `form_content.png`'s hero
  incidentally for dark.
- **Typography** (from `design.png`): a bold, rounded/geometric sans-serif for display
  headings (concrete pick: `Plus Jakarta Sans`, close in character to what the reference shows
  and pairs well with the pill/rounded-card visual style) and a clean, highly legible sans for
  body/UI text (`Inter`). The previous session's monospace-for-short-codes treatment is
  **dropped**: neither reference renders a short link's code in a code-styled/monospace font —
  `form_content.png`'s own "URL Shortener" feature card shows `yourbrnd.co/link` in the same
  plain sans as everything else — so per the constitution's "extend the same visual language"
  rule for anything not directly shown, short codes/aliases render in the same body sans, not a
  distinct monospace face.
- **Structure/orientation** (from `form_content.png`): a full-bleed dark-navy hero band holding
  the nav, a centered headline, and a floating white card containing a tabbed "Short Link / QR
  Code" switcher above a URL input and a solid teal-green CTA button — the card overlaps the
  boundary between the dark hero and the lighter content below it, with a visible drop shadow.
  Below the hero, content sections sit on a light background with generous whitespace,
  consistent with `design.png`'s spacing rhythm.

**Rationale**: Honors the user's explicit split (one image for color/type, the other for form
structure/orientation) while still producing one coherent system rather than two competing
ones, by noticing the second reference's hero background is itself unavoidably a color choice
and using it deliberately for the dark scope instead of ignoring it or picking an arbitrary
alternative.

**Alternatives considered**: Treat `form_content.png` as pure layout with zero color influence,
inventing a fully separate dark palette — rejected, more arbitrary than reusing the color the
second reference already shows, and harder to justify against "extend the same visual
language." Keep the previous session's dark-terminal/monospace identity and only reskin new
components — rejected, the constitution's design-reference rule applies to *all* UI, not just
new work, and the monospace treatment has no basis in either reference.

## Design reference — content honesty

**Decision (2026-08-17)**: `form_content.png`'s marketing-site content sections below its hero
(testimonial quotes, customer-count stats, partner logos, blog-style feature cards) are **not**
reproduced verbatim — bl8 is a personal link-management tool, not a multi-tenant SaaS product
with real customers, testimonials, or usage stats to report, and inventing fake ones would be
fabricated content (`frontend-design`'s guidance: copy is design material, and specific/honest
beats template-shaped filler). What **is** adopted from that section of the reference is the
structural pattern — light background, generous whitespace, rounded cards, section rhythm — not
its specific fabricated content. Below the hero, the landing page instead uses a short, honest
explanation of what bl8 actually does (create a short link, track clicks, generate a QR code),
not simulated social proof.

**Rationale**: The constitution's design-reference rule governs visual/layout/component
decisions, not license to fabricate content the app has no basis for; `frontend-design`'s
"more on writing in design" section is explicit that fabricated or templated copy undermines a
design as much as a generic layout would.

**Alternatives considered**: Reproduce the reference's marketing sections with placeholder/fake
numbers — rejected outright as dishonest content, independent of any design consideration.

## Public shorten-form: auth gating and continuation

**Decision (2026-08-17, clarified directly with the user)**: The tabbed Short Link/QR Code
form from `form_content.png`'s hero lives on the **public, unauthenticated landing page**,
matching the reference. Submitting it does not itself create a link while logged out (FR-001
is unchanged — no write happens before authentication) but the flow completes the user's
intent rather than discarding it:

- **Already signed in** (e.g. a returning user lands on `/` while authenticated): submitting
  the form creates the link immediately and redirects straight to its detail/result page —
  identical behavior to the existing `/links/new` action, just entered from `/` instead.
- **Signed out**: the submitted URL (and alias/expiration, if provided) are carried as query
  parameters into the Google sign-in redirect's `callbackUrl` (e.g.
  `/links/new?url=...&alias=...&expiresAt=...`). "Ask to login" is Google's own consent
  screen — no separate custom prompt UI. On return, `/links/new`'s server `load` detects the
  carried parameters for an authenticated session and completes the creation server-side
  (no client-side auto-submit needed, so it works with JS disabled too), redirecting to the
  result page exactly as the logged-in path does. If the carried URL fails validation
  (FR-005/FR-006/FR-023), the user lands on `/links/new` with the fields pre-filled and the
  validation errors shown, rather than silently losing what they typed.
- The same tabbed card component is reused, unchanged in structure, as `/links/new`'s own
  layout for users who navigate there directly while already authenticated — one creation
  experience, not two divergent ones.

**Rationale**: Matches the reference's public-form placement without violating FR-001 (the
Postgres write still only ever happens post-authentication), and avoids the common bad pattern
of losing a user's input across a login redirect — carrying it through as plain query
parameters is stateless and needs no server-side pending-request storage.

**Alternatives considered**: Server-side pending-request token (store the submitted values
against a short-lived signed token, pass only the token through the redirect) — rejected as
more machinery than a URL a user is about to make public needs; query parameters are
sufficient and simpler (Principle VI). Blocking the public form entirely behind a "sign in
first" wall with no data carry-through — rejected, that was explicitly ruled out by the user's
clarification ("create the link and take user to the result page", not "make them start over").
