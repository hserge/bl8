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

**Moved (2026-08-24, constitution v6.0.0)**: Generation itself relocates to `redirect/`
(`GET /{code}/qr`, Go, `github.com/skip2/go-qrcode`) — see
`specs/001-redirect-service/research.md`'s own QR entry for that side's decision. `ui/` no
longer has a QR route at all: the `qrcode`/`@types/qrcode`/`jsqr`/`@types/pngjs`/`pngjs` npm
packages, `src/routes/links/[code]/qr/+server.ts`, and its tests
(`tests/server/links-qr.test.ts`, `tests/e2e/qr-code.spec.ts`) are removed. `ui/`'s link detail
page now just links to/embeds `redirect/`'s public endpoint via a new
`src/lib/shortUrl.ts:buildQrImageUrl(code)` helper (`{domain}/{code}/qr`) — no alias variant,
matching what was actually built here before the move (the decision text above described an
unbuilt alias branch; the real `qr/+server.ts` only ever encoded `https://bl8.us/{code}`, and
the new `redirect/` endpoint preserves that same code-only behavior, not the aspirational one).
The prior ownership/auth check (401/403) is gone, since `redirect/` performs no authentication
by rule and the encoded URL is already public via the redirect route itself — see
`.specify/memory/constitution.md` v6.0.0's Principle II rationale.

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

## Design reference — visual system (supersedes "Light palette" above; superseded by "Design reference — Increase Design System" below)

**Decision (2026-08-17, constitution v3.6.0, `frontend-design` + `ui-ux-pro-max` applied)**:
The constitution named two reference images (since removed from governance — see "Design
reference — Increase Design System" below) with an explicit division of labor: one governed
overall look/feel/color/typography/visual style; the other governed the top shorten/QR form
and overall page content orientation only. This **replaced** the prior "Light palette" decision
above (which predates the reference images) rather than sitting alongside it.

- **Color** (from the color/type reference, a light marketing-site template): white/near-white
  surfaces, deep-navy headings and primary text, a single teal-green accent for every primary
  action (buttons, links, focus rings, active nav state), warm neutral grays for secondary text
  and borders. Expressed as shadcn-svelte's semantic OKLCH tokens: `--background`/`--card`
  white, `--foreground` deep navy, `--primary` teal-green, `--muted`/`--muted-foreground` warm
  gray, `--border`/`--input` light gray, `--ring` teal-green. `--radius` is set larger than
  shadcn-svelte's default (pill-shaped buttons, generously rounded cards, matching both
  references — their pill CTAs and rounded form card are the same structural idea).
  **Dark scope reconciliation**: the layout reference's hero is itself a deep-navy band —
  rather than treating that as out-of-scope (it governed structure, not color, per the user's
  explicit split) or inventing an unrelated dark palette, the `.dark` token scope reuses that
  same navy as `--background`/`--card`, with the identical teal-green `--primary` carried
  across both themes as the one consistent brand accent. This keeps light and dark as one
  coherent identity instead of two unrelated palettes, and both references end up contributing
  color information after all — the color/type reference directly for light, the layout
  reference's hero incidentally for dark.
- **Typography** (from the color/type reference): a bold, rounded/geometric sans-serif for
  display headings (concrete pick: `Plus Jakarta Sans`, close in character to what the
  reference shows and pairs well with the pill/rounded-card visual style) and a clean, highly
  legible sans for body/UI text (`Inter`). The previous session's monospace-for-short-codes
  treatment is **dropped**: neither reference rendered a short link's code in a
  code-styled/monospace font — the layout reference's own "URL Shortener" feature card showed
  a short link in the same plain sans as everything else — so per the constitution's "extend
  the same visual language" rule for anything not directly shown, short codes/aliases render in
  the same body sans, not a distinct monospace face.
- **Structure/orientation** (from the layout reference): a full-bleed dark-navy hero band
  holding the nav, a centered headline, and a floating white card containing a tabbed "Short
  Link / QR Code" switcher above a URL input and a solid teal-green CTA button — the card
  overlaps the boundary between the dark hero and the lighter content below it, with a visible
  drop shadow. Below the hero, content sections sit on a light background with generous
  whitespace, consistent with the color/type reference's spacing rhythm.

**Rationale**: Honored the user's explicit split (one image for color/type, the other for form
structure/orientation) while still producing one coherent system rather than two competing
ones, by noticing the layout reference's hero background was itself unavoidably a color choice
and using it deliberately for the dark scope instead of ignoring it or picking an arbitrary
alternative.

**Alternatives considered**: Treat the layout reference as pure layout with zero color
influence, inventing a fully separate dark palette — rejected, more arbitrary than reusing the
color the second reference already showed, and harder to justify against "extend the same
visual language." Keep the previous session's dark-terminal/monospace identity and only reskin
new components — rejected, the constitution's design-reference rule applied to *all* UI, not
just new work, and the monospace treatment had no basis in either reference.

## Design reference — content honesty

**Decision (2026-08-17)**: the layout reference's marketing-site content sections below its
hero (testimonial quotes, customer-count stats, partner logos, blog-style feature cards) were
**not** reproduced verbatim — bl8 is a personal link-management tool, not a multi-tenant SaaS
product with real customers, testimonials, or usage stats to report, and inventing fake ones
would be fabricated content (`frontend-design`'s guidance: copy is design material, and
specific/honest beats template-shaped filler). What **was** adopted from that section of the
reference is the structural pattern — light background, generous whitespace, rounded cards,
section rhythm — not its specific fabricated content. Below the hero, the landing page instead
uses a short, honest explanation of what bl8 actually does (create a short link, track clicks,
generate a QR code), not simulated social proof.

**Rationale**: The constitution's design-reference rule governs visual/layout/component
decisions, not license to fabricate content the app has no basis for; `frontend-design`'s
"more on writing in design" section is explicit that fabricated or templated copy undermines a
design as much as a generic layout would.

**Alternatives considered**: Reproduce the reference's marketing sections with placeholder/fake
numbers — rejected outright as dishonest content, independent of any design consideration.

## Public shorten-form: auth gating and continuation

**Decision (2026-08-17, clarified directly with the user)**: The tabbed Short Link/QR Code
form from the layout reference's hero lives on the **public, unauthenticated landing page**,
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

## Design reference — Increase Design System (supersedes color/typography from "Design reference — visual system" above)

**Decision (2026-08-18, constitution v4.1.0)**: The constitution's prior image-based design
reference was removed entirely (v4.0.0) and replaced with a single external reference — the
"Increase Design System" at
https://styles.refero.design/style/1ad4f49f-275a-4268-8ed1-677dc3c6e475 (an institutional
fintech/banking design system) — which governs **color, typography, and visual style only**,
not layout/orientation (unlike the old rule, the new one says nothing about page structure).
Per Principle VI, the existing structure — the dark hero band with a floating tabbed
Short-Link/QR-Code form card, the honest "what bl8 does" section, mobile-first responsive
behavior, the public-shorten-form auth-carry-through flow — is **retained unchanged**; there's
no constitutional reason to redo working, tested layout just because the color source changed,
and the new rule doesn't ask for that. Only the token values and type choices below change.

**Color** — mapped from the constitution's extracted hex values into the existing shadcn-svelte
OKLCH token architecture (`src/routes/layout.css`), replacing the teal-green/navy Stratus-era
values:

- Light (`:root`): `--background` Fog canvas `#edf0f2`; `--card` Pure White `#ffffff`;
  `--foreground` / `--card-foreground` Inkwell Navy `#1a2b3b`; `--primary` Mint Signal
  `#31f2bf` with `--primary-foreground` Abyss `#0d1726` (dark text for contrast on the bright
  mint); `--secondary` / `--muted` a light neutral `#e1e5e9` with `--muted-foreground`
  `#687887`; `--border` / `--input` `#bdc2c8`; `--ring` matches `--primary` (`#31f2bf`).
  `--accent` (hover-state fill) uses the same light neutral as `--muted` rather than a
  mint-tinted shade — the spec's own "minimal chromatic energy" principle argues against
  colorful hover states.
- Dark (`.dark`): `--background` Abyss `#0d1726` (the spec's own "dark surfaces" color);
  `--card` Inkwell Navy `#1a2b3b` (one tier lighter than the page background, reusing a color
  already in the palette rather than inventing a new one — the same two-navy-tier structure
  the prior Bitly-derived dark scope used, so the *pattern* carries over even though the exact
  hex values don't); `--foreground` / `--card-foreground` the lightest neutral `#e1e5e9`;
  `--primary` / `--ring` stay Mint Signal `#31f2bf` (unchanged across themes, per the spec);
  `--primary-foreground` stays Abyss; `--secondary` / `--muted` / `--border` / `--input` the
  darker neutral `#314352` with `--muted-foreground` `#8995a1`.
- Voltage (`#e4ff33`) is deliberately **not** wired into any general-purpose token — the
  constitution reserves it exclusively for a full-bleed announcement bar, which this app has no
  current use for. It stays undefined until/unless that need arises, rather than being
  smuggled into `--accent` or similar for lack of a better place.
- `--destructive` is **not** specified by the source design system (a gap in the spec, not an
  oversight here) — kept at its existing red value, since delete/error states need *some* color
  and inventing one from the given palette would be more arbitrary than keeping a standard,
  already-accessible red.

**Typography** — the constitution names "Untitled Sans" and "Input Mono," both commercial
typefaces (NAN and Font Bureau respectively) this project has no license for and can't bundle
via Google Fonts the way `Inter`/`Plus Jakarta Sans` were. The constitution itself anticipates
exactly this by naming fallbacks: **Inter** (already loaded) for `--font-sans`/`--font-display`,
and **JetBrains Mono** for `--font-mono`. This also reintroduces monospace styling for short
codes/aliases — dropped in the Stratus/Bitly-era decision above — since the source spec
explicitly calls out its mono face for "code/data," and a short code is exactly that; the
earlier rationale for dropping it (neither old reference used monospace) no longer applies once
the reference itself changed. Display headings use tight/negative letter-spacing (Tailwind's
`tracking-tighter`, or an arbitrary `tracking-[-0.05em]` value where that's not tight enough) to
approximate the spec's extreme negative tracking at display sizes, without chasing its exact
-5.4px figure pixel-for-pixel.

**Radius** — the design system's 12px card / 8px input-button / 999px pill split is
approximated through the existing single-`--radius`-token architecture (`--radius-sm/md/lg/xl`
derived via `calc()`, set up in Phase 8) rather than hand-tuning three separate radius tokens:
`--radius: 0.75rem` (12px) makes cards land exactly on-spec and derived button/input radii land
close (~10px vs. the spec's 8px) — an accepted approximation, per Principle VI, rather than
adding bespoke per-component radius overrides for a 2px difference.

**Shadows** — the spec's "three-layer navy-tinted shadow stack" and "angular, faceted gradient
blocks (no soft glows)" have no equivalent in shadcn-svelte's default component styles (which
use neutral-gray shadows); implementing them is deferred to task-level work (a small set of
Tailwind arbitrary-value shadow utilities using Inkwell-Navy-tinted `rgba()` values, applied to
`Card` and floating elements like the hero form).

**Rationale**: Reuses the constitution's own extracted tokens directly (no re-deriving from the
external URL, keeping this grounded in what's actually written into governance) while fitting
them into the token architecture and component library already built, rather than starting the
re-skin over. Retaining structure and reintroducing monospace are both direct consequences of
reading the new rule's actual scope (color/typography/style, not layout) rather than assuming
"new design reference" means "start from a blank page."

**Alternatives considered**: Re-fetch and re-derive the palette from the live URL each time —
rejected; the constitution already extracted and pinned the tokens specifically so implementation
doesn't depend on an external page staying reachable or unchanged. Also restructure the page
layout to match some assumed "typical fintech" pattern — rejected, the constitution's new rule
doesn't ask for that, and inventing layout requirements it doesn't state would be scope creep
beyond what was actually amended.

**Correction (2026-08-20, constitution v4.2.0)**: The constitution's design reference now
points primarily at a local working implementation, `docs/design/` (`styles.css` is the
authoritative token source; `index.html` shows real component markup), rather than the
external style-guide URL. Reading the actual CSS corrects three approximations made above from
the URL summary alone, and adds one token that summary didn't surface:

- **`--accent` (hover-state fill) was wrong** — `styles.css` defines an explicit
  `--c-mint-tint: rgba(49, 242, 191, 0.08)` for exactly this purpose. The "minimal chromatic
  energy" reasoning used above to justify a neutral-gray hover fill doesn't hold: the source
  system does use a colored (if very subtle) tint, it's just far lighter than the solid mint
  used for `--primary`. `--accent` is corrected to Mint Signal at 8% opacity;
  `--accent-foreground` stays Inkwell Navy.
- **Type scale is now exact, not approximated** — `styles.css` defines the full scale directly:
  display `clamp(44px, 7vw, 90px)` at `clamp(-2.6px, -0.06em, -5.4px)` letter-spacing; step
  sizes at 40px/-1.6px, 32px/-1.28px, 24px/-0.96px, 20px/-0.2px; body 16px/-0.16px; small text
  13px/-0.13px; tiny 10px/-0.1px. These replace the prior "use `tracking-tighter` or an
  arbitrary `-0.05em` value" approximation with the real `clamp()` expressions, applied
  directly as arbitrary Tailwind values rather than guessed at. The one exception — eyebrow/
  label text — uses *positive* tracking (`+0.08em`), not negative; this direction-reversal is
  itself part of the design system's character (tight display type, open-tracked labels) and
  wasn't visible from the URL summary at all.
- **Shadows are now exact, not deferred** — `styles.css` defines three concrete tiers instead
  of the vague "three-layer navy-tinted stack" description used above: `--shadow-subtle`
  (`0px 1px 3px rgba(0,0,0,0.1), 0px 1px 2px -1px rgba(0,0,0,0.1)` — near-black, minimal
  elevation), `--shadow-sm` and `--shadow-elevated` (both genuinely navy-tinted,
  `rgba(12,25,39,...)`, multi-layer, `--shadow-elevated` the more pronounced of the two, used
  for the hero's floating form card). These are added as CSS custom properties in
  `layout.css` (not Tailwind arbitrary values — they're multi-layer and reused enough to
  warrant a named property) and consumed via `shadow-[var(--shadow-elevated)]` etc.
- **New: a code-specific accent, `#7ec4ff`** — not present in the URL summary at all. Given
  this app's short codes are literally "code," and the source system defines this color
  specifically for that purpose (distinct from the general-purpose Mint Signal action color),
  it's added as its own token — `--color-code` in the `@theme inline` block — and used for the
  monospace short-code chip's text color specifically (link list, link detail, the create-form
  alias preview), giving a visual distinction between "this is an identifier" (blue) and "this
  is an action" (mint) that the flat single-accent approach above didn't have.
- Also newly available: the exact 4px-based spacing scale (4/8/12/16/20/24/32/40/48/60/64/96px)
  and the `--r-tag: 4px` radius tier (for small badges/tags, distinct from the 8px
  control/12px card tiers already in use) — both used at task-implementation time rather than
  needing their own research.md entries, since they're direct value lookups, not decisions.

**Rationale**: A local, precise reference is strictly better ground truth than a summarized
external page — these aren't new design choices, they're corrections to values that were
approximated or missed when only the URL's prose summary was available.

**Alternatives considered**: Leave the approximations in place since they were "close enough" —
rejected; the whole point of the constitution pointing at an exact source now is to *not*
approximate where the real values are available, and the corrections above are small, localized
token changes, not a rework.

## Design reference — structural rebuild (constitution v5.0.0, supersedes the "existing structure retained" conclusion in "Design reference — Increase Design System" above)

**Decision (2026-08-21)**: Constitution v5.0.0 widened the "Design reference" rule from
color/typography/visual-style only to also cover layout, composition, and structural patterns
from `docs/design/index.html`. A direct visual comparison (via the `playwright-cli` skill,
screenshotting the live app against a local static server for `docs/design/`) confirmed the
user's observation that the two were "completely different" at the structural level even though
token application was already correct — inverted hero (dark/white vs. the reference's
light/navy), an entirely different nav, no announcement bar, a stacked/tabbed form vs. the
reference's flat two-column one, and whole sections (how-it-works, stats, trust logos, API/dev)
the app didn't have at all. This entry supersedes the "retained unchanged" structural decision
above and the "Design reference — content honesty" entry's narrower scope (which only addressed
the marketing sections below the old hero, not the hero/nav/form themselves).

Read directly from `docs/design/index.html` (not just the earlier screenshots), section by
section, applying the constitution's new carve-out — adopt structure, replace or omit fabricated
content:

- **Hero**: adopt the light-background/navy-headline composition, the eyebrow label above the
  headline, and the flat (non-tabbed) two-field form (Long URL + optional Custom back-half)
  directly below/overlapping the hero, matching `docs/design/`'s `.hero`/`.tool-card`
  structure. **Drop the `Short Link`/`QR Code` tab switcher** (resolved via AskUserQuestion,
  2026-08-21, "Match reference exactly"): QR generation remains a real, already-shipped
  capability (`[code]/qr/+server.ts`, User Story 4), it just moves out of the hero's creation
  step and continues to be available on the created link's detail page, matching how the
  reference itself treats QR as a features-grid item, not a hero-form mode.
  **Omit the avatar stack + "Trusted by teams shortening 2.4M+ links a month" trust line** —
  fabricated social proof, no truthful equivalent (bl8 has no aggregate cross-user usage
  numbers to report).
- **Announcement bar**: the constitution now requires a full-bleed Voltage-colored bar be
  present per the reference's structural pattern, but its specific copy ("Now supporting custom
  back-halves and bulk import") describes features bl8 doesn't have. Rather than inventing fake
  "news," the bar's copy is set to a true, evergreen statement of already-shipped functionality
  — "Every link includes click tracking and a QR code, automatically." — satisfying the
  structural requirement (the bar itself, its full-bleed Voltage treatment, its position above
  the header) without fabricating a change that didn't happen. Non-dismissible, single line,
  matching the reference's own markup (no close control there either).
- **Primary navigation**: adopt the structural pattern (horizontal list of section anchors +
  sign-in/primary-CTA actions) with bl8's actual sections, not the reference's literal list:
  `Features` / `How it works` / `FAQ` (the reference's `API` link is dropped — see below) plus
  the pre-existing `Status` page (FR-025), which has no equivalent slot in the reference but is
  real, shipped, and worth keeping discoverable — added as a fourth nav item rather than
  dropped, since omitting a real feature to match the reference's item *count* would be
  cargo-culting the pattern past the point the rule asks for. Nav actions become `Sign in with
  Google` (ghost button, existing OAuth flow, unchanged) and `Get started` (primary button,
  anchor-scrolls to the hero form) — adapted 1:1 from the reference's `Sign in`/`Get started`
  slots.
- **Stats bar** (`2.4M` links/month, `140ms` median redirect, `99.99%` uptime, `180+`
  countries): **omitted entirely** — no truthful equivalent exists; bl8 has no cross-user
  aggregate analytics capability in scope (per-link analytics only, FR-011), and inventing
  platform-wide numbers would be fabricated content regardless of design considerations (same
  reasoning as "Design reference — content honesty" above, now applied to this section too).
- **Features grid**: adopt the 3-column icon-badge card structural pattern, but keep bl8's
  actual three features (short links, click tracking, QR codes — the existing "What bl8 does"
  content) rather than padding to the reference's six cards with features bl8 doesn't have
  (branded domains, UTM builder, REST API). Three real cards in the reference's grid/badge
  style, not six card-shaped placeholders.
- **How it works**: adopt the numbered three-step structural pattern (`01`/`02`/`03`, heading,
  one-sentence description per step) with truthful copy describing bl8's actual flow: paste a
  URL, optionally set a custom alias, share and track — this is a real sequence (order carries
  information: validation happens before customization happens before the link is live), so the
  numbered-step device is appropriate here, not decorative.
- **"For developers" / API section**: **omitted entirely** — bl8 has no public REST API in
  scope (plan.md: `ui/`'s server routes are internal, not a documented external interface); a
  section showing `curl -X POST https://api.short.hn/v1/links` for an API that doesn't exist
  would be actively false, not just unpolished.
- **Trust/logo wall** ("Trusted by product and marketing teams at NORTHWIND, ATLAS CO, ..."):
  **omitted entirely** — fabricated company names, no truthful equivalent.
- **FAQ**: adopt the section pattern with truthful, bl8-specific answers (the reference's own
  answers don't transfer as-is — e.g. its "links never expire" contradicts bl8's actual
  optional-expiration feature): "Do short links expire?" → only if you set an expiration when
  creating one; otherwise they stay live indefinitely. "Can I change where a link points?" →
  yes, update the destination any time without changing the short code. "Is there a cost?" →
  bl8 is a personal tool with no plans or billing — omitted rather than answered, since there's
  nothing truthful to say that isn't just "not applicable."
- **Final CTA**: adopt the pattern (heading + subheading + primary action, centered, full-width
  band) but with a single primary button ("Shorten a link", anchor-scrolls to the hero form)
  instead of the reference's primary+ghost pair — the ghost button linked to API docs that don't
  exist in bl8's scope, so it's dropped rather than repointed at something unrelated.
- **Footer**: adopt the overall footer band placement, but not the reference's 4-column
  Product/Resources/Company link grid — most of those (`Pricing`, `Docs`, `About`, `Careers`)
  are placeholder `#` anchors in the reference itself and have no bl8 equivalent at all. Replaced
  with a minimal footer: logo/copyright line plus the one real cross-cutting link that exists
  today (`Status`). Padding out four columns of dead links to match the reference's *shape*
  would be worse than a simpler, fully-functional footer — the constitution's carve-out is about
  preserving real structure, not manufacturing placeholder content to fill it.

**Rationale**: The constitution's new carve-out ("adopt structure, replace or omit fabricated
content") is the operative rule for every section above — none of these are visual-taste calls,
each follows directly from asking "does bl8 actually have this, truthfully, right now?" for the
specific content the reference's structural pattern was built to hold. Where the answer is yes
(features, how-it-works, FAQ), the pattern is adopted with real content. Where the answer is no
with no equivalent (stats, trust logos, API section, most footer links), the section is omitted
rather than faked. The hero form's mode (flat vs. tabbed) was the one genuine judgment call with
two reasonable answers — resolved directly with the user rather than assumed, per the
Ambiguity Resolution principle.

**Alternatives considered**: Reproduce every reference section with bl8-flavored placeholder
copy (e.g. invented usage stats, a stubbed "API coming soon" section) — rejected, this is
exactly the fabricated-content pattern the constitution's carve-out and `frontend-design`'s
writing guidance both rule out; a placeholder is still a lie about present capability. Keep the
tabbed hero form and treat the flat-form pattern as inapplicable to bl8 — rejected per the
user's explicit resolution favoring the reference's exact structure.
