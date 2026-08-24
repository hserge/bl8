<!--
Sync Impact Report
Version change: 7.0.0 → 8.0.0
Modified principles: II. Redirect Is a Minimal Read-Path Service — redefined again
Added sections: none
Removed sections: none
Follow-up TODOs: none

Changed sections (8.0.0, 2026-08-24):
  - II. Redirect Is a Minimal Read-Path Service: replaces the single `?style=` closed-enum
    exception from v7.0.0 with three independent parameters — `dots` and `corners` remain
    small closed enums (shape is discrete), but `bg` now accepts *any* well-formed hex color,
    unenumerated. MAJOR because v7.0.0's own text explicitly forbade this ("no arbitrary
    colors... an enum-equality check against that set, not free-form customization"); this
    amendment directly reverses that specific prohibition for color while keeping it intact for
    shape. Foreground/ink color is deliberately NOT made a second free parameter — it's derived
    algorithmically from whichever background is chosen, so the one open axis can't produce an
    unreadable combination. Triggered by the user asking for dots/corners/background to each be
    independently styleable, with background accepting an arbitrary hex value — a strictly
    larger ask than v7.0.0's closed-preset system covered.

Changed sections (7.0.0, 2026-08-24):
  - II. Redirect Is a Minimal Read-Path Service: adds a third narrow exception — the QR
    endpoint MAY accept `?style=` selecting from a small, fixed, closed set of preset visual
    styles (enum-equality, not free-form customization). MAJOR because v6.0.0's own text
    explicitly forbade this ("no... QR customization (size, format, styling) beyond the fixed
    PNG this rule specifies"); this amendment directly reverses that specific prohibition, so
    it's a redefinition, not an addition alongside an unchanged rule. Triggered by the user
    asking for "a fancier qr generator which can generate by preset style" — clarified via
    AskUserQuestion to mean a picker across multiple selectable presets (not one fixed fancier
    default), which is exactly the kind of caller-visible customization v6.0.0 ruled out and
    therefore required this amendment rather than just an implementation change.

Changed sections (6.0.0, 2026-08-24):
  - II. Redirect Is a Minimal Read-Path Service: `redirect/`'s guaranteed surface widens from
    "exactly two logical endpoints" to "exactly three" — a new `GET /{code}/qr` PNG endpoint,
    moved here from `ui/` at the user's explicit request ("move qr code generation to
    redirector"). MAJOR because it redefines the principle's core guarantee, which prior
    amendments treated as inviolable ("MUST NOT gain... any feature request... belongs in ui/
    instead"). Admitted as a narrowly-bounded exception (reuses the exact same lookup and
    active/expiry rules as the redirect route, no new business logic, no auth) rather than
    loosening the principle generally. A real behavior change rides along: QR generation drops
    the ownership/auth check `ui/`'s prior implementation had, since `redirect/` performs no
    authentication by rule (Principle II) and the encoded URL is already public/unauthenticated
    via the redirect route itself — judged a forced, non-optional consequence of the move
    rather than a separate risk decision.

Changed sections (5.0.0, 2026-08-21):
  - Frontend Design Workflow — "Design reference": scope widened from color/typography/visual
    style only to also require matching layout, composition, and structural patterns from
    `docs/design/` — page/section composition (e.g. a light-background hero with dark-navy
    text, not an inverted dark hero), primary navigation structure, the full-bleed Voltage
    announcement bar, section-level patterns (feature grid, numbered how-it-works steps,
    developer/API section), and multi-column component layout at wider viewports. MAJOR because
    it redefines what "compliant" means: implementations that were compliant under the prior
    tokens-only reading (e.g. the app's dark-hero/no-announcement-bar landing page, adopted
    specifically because layout was out of scope) are no longer compliant and require rework. A
    new carve-out is added: where the reference's own markup carries fabricated or placeholder
    content (social-proof numbers, sample copy), the STRUCTURE must be adopted but the CONTENT
    must be replaced with the application's true, current information, or the section omitted
    if no truthful equivalent exists.
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

`redirect/` exposes exactly three logical endpoints: the redirect lookup — `GET /{code}`, and
optionally `GET /{code}/{alias}` when the code has a registered SEO alias; a QR-code image for
the same code — `GET /{code}/qr`, returning a PNG that encodes the code's canonical short URL;
and `GET /health`. It MUST NOT gain create, update, delete, or list endpoints, authentication,
or request validation beyond looking up the code, with exactly three narrow exceptions: (1) when
a second path segment is present on the redirect route and isn't the literal `qr`, it MUST be
checked for exact equality against the looked-up record's registered alias (a field already
fetched as part of the same lookup), returning 404 on mismatch; (2) the QR endpoint MUST reuse
that same lookup and its active/expiry status rules unchanged (404 missing/expired, 410
deactivated) rather than adding any QR-specific business logic, and MUST NOT perform an
ownership or authentication check — the URL it encodes is exactly the same already-public,
unauthenticated string the redirect lookup itself resolves, so there is no additional secret to
gate; (3) the QR endpoint MAY accept a small set of rendering parameters, each bounded in its
own way rather than freely combinable into arbitrary customization: `dots` and `corners` each
select from a small, fixed, closed enum of shape names (documented alongside the handler) —
enum-equality checks, not free-form shape customization — while `bg` accepts any well-formed
hex color value, unenumerated, since color is a continuous space where enumerating "allowed"
values would be meaningless; the only bound on `bg` is format validity, not membership in a
fixed set. Foreground/ink color is never a caller-supplied parameter at all — it MUST be
derived algorithmically from the chosen background (e.g. a contrast/luminance rule), so an
arbitrary background can never be paired with an unreadable foreground. Every one of these
parameters, valid or not, MUST silently fall back to its default (never a request error),
since they are cosmetic, not validated, inputs — an unrecognized shape name or malformed hex
string is simply treated as absent. Neither this nor the other two exceptions is general
request validation, and none MUST grow into anything more — no partial matching, normalization,
alias-specific business logic, logo embedding, arbitrary sizing, or any QR parameter beyond
`dots`/`corners`/`bg` as specified here. It is stateless and MUST be safe to run as many
identical, horizontally scaled instances with no shared in-process state.
Any feature request that would add write behavior, business logic, or auth to `redirect/`
belongs in `ui/` instead.

**Rationale**: A tiny, fixed surface area is what makes the redirect path fast, cheap to
scale, and easy to reason about under load; every added responsibility erodes that. QR
generation is admitted as a narrow, explicitly-bounded exception rather than a precedent for
future endpoints: it's a pure, stateless derivation of data this service already looks up (no
write, no new authorization model, no per-request business decision beyond the same status
checks the redirect route already makes), and serving it from the same public domain the
encoded URL itself points to is more correct than generating it from a different, authenticated
admin service. Moving it out of `ui/` also means `ui/` no longer needs a legitimate reason to
serve a public, unauthenticated image endpoint — QR generation's own real security posture (no
secret exists to protect once you have the code) is now enforced by design, not by an
ownership check that only ever guarded already-public information. The `dots`/`corners`/`bg`
exception draws its boundary differently for shape versus color, deliberately: shape is a small,
genuinely discrete design choice (there are only so many reasonable module/marker shapes), so
enumerating it is natural and keeps the surface predictable; color is not discrete — there is no
finite "reasonable" set of hex values — so bounding it by format instead of membership is the
honest version of the same narrow-exception principle, not a loophole. Auto-deriving foreground
from background (rather than accepting it as a second free color) keeps the one truly open
parameter from being able to produce something unreadable, which is the actual risk an
unbounded customization surface would otherwise pose.

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

**Design reference**: All UI/UX design and implementation MUST match the "Increase Design
System" as implemented at `docs/design/` (a working HTML/CSS/JS reference build —
`styles.css` is the authoritative token source; `index.html` shows real component markup and
layout structure). This local implementation is the primary reference, taking precedence over
the design system's public write-up at
https://styles.refero.design/style/1ad4f49f-275a-4268-8ed1-677dc3c6e475 (kept only as
background/provenance) since it is more precise and cannot go unreachable.

This rule covers not only color, typography, and visual style (tokens below) but also layout,
composition, and structural patterns shown in `docs/design/index.html`:

- **Page/section composition**: a landing hero MUST use `docs/design/index.html`'s light
  background with dark-navy headline text — not an inverted dark-background/white-text
  treatment.
- **Primary navigation**: structure (a horizontal nav listing the site's main sections plus
  sign-in/primary-CTA actions) MUST follow the reference's pattern, adapted to this
  application's actual sections and actions rather than copied verbatim.
- **Announcement bar**: a full-bleed Voltage-colored announcement bar MUST be present at the
  top of the page, per the reference — Voltage remains reserved exclusively for this use (see
  the color token below).
- **Section-level patterns**: a feature grid, a numbered how-it-works sequence, and a
  developer/API section (where the application has API functionality to show) MUST follow the
  reference's structural patterns.
- **Component layout**: forms and similar wide components MUST use the reference's
  multi-column layout at viewports where the width allows, subject to the mobile-first rule
  above (which still governs the small-viewport, single-column structure).
- **Fabricated or placeholder content**: where `docs/design/index.html` pairs a structural
  pattern with fabricated or placeholder content (social-proof numbers, sample copy, invented
  claims), the STRUCTURE MUST be adopted but the CONTENT MUST be replaced with the
  application's own true, current information — or the section omitted entirely if no
  truthful equivalent exists. Copying fabricated claims verbatim is never acceptable.

The following tokens, extracted from `docs/design/styles.css`, are the source of truth if that
file is ever unavailable:

- **Color**: `#1a2b3b` Inkwell Navy (primary text); `#edf0f2` Fog / `#ffffff` White
  (backgrounds); `#31f2bf` Mint Signal (primary accent) with `rgba(49,242,191,0.08)` as its
  light hover/tint fill; `#e4ff33` Voltage (reserved exclusively for a full-bleed announcement
  bar, never general-purpose); `#0d1726` Abyss (dark surfaces); `#7ec4ff` (code-specific
  accent); neutrals `#314352` Slate, `#687887` Graphite, `#8995a1` Steel, `#bdc2c8` Pewter,
  `#caced2` Silver, `#e1e5e9` Mist.
- **Typography**: "Untitled Sans" (fallback Inter) for primary text; "Input Mono" (fallback
  JetBrains Mono) for code/data. Type scale: display `clamp(44px, 7vw, 90px)` at
  `clamp(-2.6px, -0.06em, -5.4px)` letter-spacing; headings step down through 40px/-1.6px,
  32px/-1.28px, 24px/-0.96px, 20px/-0.2px; body 16px/-0.16px; small text 13px/-0.13px down to
  10px/-0.1px; eyebrow/label text is the one exception with *positive* tracking (`+0.08em`),
  not negative.
- **Spacing**: a 4px base scale — 4/8/12/16/20/24/32/40/48/60/64/96px.
- **Radius**: 4px tags, 8px controls (inputs/buttons), 12px cards, 999px pills.
- **Shadow**: three tiers — `--shadow-subtle` (fine 1–3px, near-black) for minimal elevation;
  `--shadow-sm` and `--shadow-elevated` both navy-tinted (`rgba(12,25,39,...)`) multi-layer
  stacks for cards/floating elements, `--shadow-elevated` being the more pronounced of the two.
- **Layout**: 1200px max content width, 80px section gaps.
- **Visual style**: disciplined, minimal chromatic energy, diagrammatic (not lifestyle)
  imagery — a "financial terminal" feel, not consumer-friendly softness; angular, faceted
  gradients, no soft glows.

`docs/design/` MUST be consulted before any visual, layout, or component decision not already
covered by the extracted tokens and structural patterns above.

**Rationale**: A concrete, named design system removes ambiguity that guidance alone leaves
open, and keeps the application visually coherent with one deliberate identity instead of
drifting screen-by-screen or defaulting to generic component-library styling. Preferring the
local implementation over the external write-up means the reference can't disappear or change
out from under the project, and gives implementers exact values (precise shadow recipes, a
full type scale, real component markup) that a style-guide summary page couldn't. Extending the
rule to layout and structure, not just tokens, closes the gap where a page could apply every
color and type value correctly and still read as an unrelated design because its composition,
navigation, and section patterns diverged from the reference — colors and type alone don't
carry a design's identity, structure does too.

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

**Version**: 8.0.0 | **Ratified**: 2026-08-14 | **Last Amended**: 2026-08-24
