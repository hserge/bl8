# Feature Specification: Link Management Web Application

**Feature Branch**: `002-link-management-ui`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description: "Build the web application (ui/) that owns all URL shortener business logic. A user can log in, create a short link from a long URL (optionally with a custom slug and an expiration date), update or delete their links, view click analytics per link (counts over time, referrers) in the report, and generate a QR code for any link. Reject invalid, malformed, or unsafe URLs at creation time, and reject a custom slug that's already taken. On create, update, or delete, write to Postgres as the source of truth and write through the corresponding change to Redis so the redirect service serves fresh data immediately, without waiting for a cache miss."

## Clarifications

### Session 2026-09-09 through 2026-09-11

- Q: Should a user be able to permanently delete their own account? → A: Yes — a typed-confirmation flow (the user must type their own account email to enable the delete action) that permanently removes the account and every link/click history it owns, in one atomic operation; there is no recovery afterward. Captured as FR-030.
- Q: Should the product introduce a paid tier? → A: Yes — Free and Pro plans. Free keeps every core capability (create/manage/analytics/QR/Google sign-in) but caps how many *currently-active* links an account may hold at once (a standing cap, not a monthly creation quota — deactivating or letting a link expire frees a slot); Pro removes that cap entirely and unlocks programmatic API access. The cap's exact number is operator-configurable, not hardcoded. Captured as FR-031/FR-032.
- Q: How does a user actually become Pro? → A: A checkout flow through a third-party billing provider (Paddle live; Stripe implemented and code-complete but currently running on placeholder credentials until a real Stripe account exists) — this application never collects or stores payment details itself, only the resulting subscription status via that provider's webhook. Captured as FR-032.
- Q: What does Pro's "API access" actually unlock? → A: Pro-only named API keys a user creates from their profile page, authenticating a `POST /api/links` endpoint that creates a link the same way the authenticated UI form does — for scripting/CI use, independent of a browser session/cookie. A newly created key's raw value is shown exactly once (at creation) and never recoverable afterward — only a hash is stored — matching this application's existing "trust Google's own session security, don't invent parallel secret-recovery flows" posture. A key can be individually revoked without affecting a user's other keys. Captured as FR-033/FR-034.
- Q: Should there be a limit on how many API keys one account can hold at once? → A: Yes — a standing cap on *active* (non-revoked) keys, mirroring the Free-plan active-link cap's shape (revoking a key frees a slot; not a lifetime creation quota), operator-configurable, defaulting to 10. Exists to bound abuse/storage growth, not because holding multiple keys is itself a problem. Captured as FR-035.

### Session 2026-08-14

- Q: Should the rate limit apply only to link creation, or also to update and delete? → A: Create and update, not delete.

### Session 2026-08-18

- Q: Should the light/dark/system theme toggle be a formal requirement of this feature's spec, with the manual-override-defaulting-to-system behavior already settled on during planning? → A: Yes — add as a formal FR: user can switch between light/dark/system; defaults to system; explicit choice persists across visits. Captured as FR-027.
- Q: Should the public (signed-out) landing page get a real, working "shorten a link" form, where submitting it while signed out redirects to Google sign-in and completes the creation automatically on return? → A: Yes — the shorten form appears on the public landing page; submitting it while signed in creates the link immediately; submitting it while signed out routes through Google sign-in and completes the same creation afterward, landing on the result page — no data re-entry required. Captured as FR-028/FR-029, and Acceptance Scenario 6 under User Story 1 is updated accordingly.

### Session 2026-08-17

- Q: Should FR-017's rate limiter still have an IP-keyed branch for unauthenticated requests, given FR-001 already blocks all unauthenticated access to these routes? → A: No — removed. Unauthenticated users must never reach the dashboard or any protected route at all, so an IP-keyed branch for them is unnecessary; FR-017 is now account-keyed only.
- Q: How long should a user's session last before requiring re-authentication? → A: 72 hours (fixed session lifetime). Captured as FR-018.
- Q: Should FR-006's unsafe-URL check still include the external reputation/safe-browsing service call? → A: No — removed for now. FR-006 is structural checks only (scheme allow-list, private/internal network block-list); the external check may be reconsidered later.
- Q: Should FR-017's rate-limit threshold (request count, time window) be a fixed hardcoded value, or configurable? → A: Configurable, not hardcoded.
- Q: Should rate-limited, ownership-rejected, and validation-rejected requests return distinct responses? → A: Yes — 400 (validation), 403 (ownership), 404 (not found), 429 (rate limit). Captured as FR-019.
- Q: What are the pagination, ordering, and maximum-result-size requirements for `GET /links`? → A: 100 links per page, newest-first ordering, no separate total cap (pagination alone bounds each response). Captured as FR-020.
- Q: Should the QR code's image format (SVG vs. PNG) be a firm requirement? → A: Yes — PNG, fixed resolution of at least 512×512px, for reliable print/embedding compatibility. Updated in FR-012.
- Q: When create/update has multiple validation failures at once, should the response report all of them or just the first? → A: All of them, in one response. Captured as FR-021.
- Q: When a link is deleted, should its click-event history be retained (orphaned), or deleted with it? → A: Deleted with it — via a database foreign key `ON DELETE CASCADE` from `click_events.code` to `links.code`. Captured as FR-022.
- Q: Should custom slugs replace the code (as originally specced) and be unique, or become a separate, non-unique SEO decoration? → A: Separate SEO decoration. The code is always system-generated and globally unique (the sole lookup key, unchanged); a slug is an optional, non-unique value tied 1:1 to one code, appended after it (`/{code}/{slug}`). `redirect/` checks the supplied slug for exact equality against the code's registered slug, 404 on any mismatch (including when no slug is registered). This redefines FR-003 and FR-007, and requires a matching change in `redirect/`'s spec (see `specs/001-redirect-service/spec.md` FR-020/FR-021).

### Session 2026-08-24

- Q: Should QR code generation move from `ui/` to `redirect/`? → A: Yes. `redirect/` gains a third endpoint, `GET /{code}/qr` (constitution v6.0.0 — Principle II widened from "exactly two logical endpoints" to "exactly three", admitted as a narrowly-bounded exception). Forced consequence: the endpoint has no ownership/auth check, since `redirect/` performs no authentication by rule and the encoded URL is already public via the redirect route itself. Captured as an update to FR-001/FR-012 and User Story 4's Acceptance Scenarios; see `specs/002-link-management-ui/contracts/qr.md` and `specs/001-redirect-service/` for the new contract.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create a short link (Priority: P1)

A logged-in user pastes a long URL and gets back a working short link (a system-generated
code), optionally attaching a slug for readability and optionally setting when the link
should stop working.

**Why this priority**: This is the core value of the product — turning a long URL into a
short, shareable one. Nothing else in this feature matters without it.

**Independent Test**: Can be fully tested by logging in, submitting a valid long URL, and
confirming a new short link is returned and immediately usable, without touching update,
delete, analytics, or QR functionality.

**Acceptance Scenarios**:

1. **Given** a logged-in user on the create-link form, **When** they submit a valid long URL
   with no slug, **Then** a new short link is created with a system-generated code and is
   immediately available at `/{code}`.
2. **Given** a logged-in user, **When** they submit a valid long URL with a well-formed SEO
   slug, **Then** the short link is created with a system-generated code and the slug
   attached, available both at `/{code}` and `/{code}/{slug}`.
3. **Given** a logged-in user, **When** they submit a valid long URL with a malformed SEO
   slug (wrong charset, or outside the 3–32 character range), **Then** the creation is
   rejected and no link is created.
4. **Given** a logged-in user, **When** they submit a URL that is malformed or otherwise
   invalid, **Then** the creation is rejected with a clear reason and no link is created.
5. **Given** a logged-in user, **When** they submit an expiration date along with the URL,
   **Then** the created link stops being usable after that date.
6. **Given** a user who is not logged in, **When** they submit a valid long URL on the
   public landing page's shorten form, **Then** they are routed through Google sign-in and,
   upon successful authentication, the same link is created automatically without needing to
   re-enter the URL, slug, or expiration, landing on the new link's result page.
7. **Given** a user who is not logged in, **When** they submit the public shorten form with an
   invalid or unsafe URL (or malformed slug, or a past expiration), **Then** after completing
   Google sign-in they land on the create form with their original input preserved and the
   applicable validation errors shown, rather than the link being silently created or the
   input being lost.

---

### User Story 2 - Manage existing links (Priority: P2)

A logged-in user reviews the links they've created and updates or removes the ones they no
longer want active, without affecting anyone else's links.

**Why this priority**: Links inevitably need correcting, retiring, or removing; this is
required for the product to be trustworthy over time, but it depends on links already
existing from User Story 1.

**Independent Test**: Can be fully tested by creating a link, then updating its destination
or expiration, then deleting it, and confirming each change is reflected and that another
user's links are unaffected and inaccessible.

**Acceptance Scenarios**:

1. **Given** a logged-in user who owns a link, **When** they update its destination URL,
   expiration, or active status, **Then** the change is saved and takes effect immediately.
2. **Given** a logged-in user who owns a link, **When** they delete it, **Then** the link is
   removed and can no longer be resolved.
3. **Given** a logged-in user, **When** they attempt to update or delete a link owned by
   another user, **Then** the attempt is rejected.
4. **Given** a logged-in user updating a link, **When** they submit a new destination URL
   that is malformed, invalid, or unsafe, **Then** the update is rejected and the existing
   link is left unchanged.
5. **Given** a logged-in user who has never created a link, **When** they open their link
   list, **Then** they see an empty-state message inviting them to create their first link,
   not a blank page or an error.

---

### User Story 3 - View click analytics for a link (Priority: P3)

A logged-in user opens the report for one of their links to see how much traffic it's
gotten over time and where that traffic came from.

**Why this priority**: Analytics is a high-value differentiator but is read-only and
depends on links already existing and having been clicked — it doesn't block the core
create/manage loop.

**Independent Test**: Can be fully tested by viewing the report for a link that has recorded
clicks and confirming counts over time and referrer breakdown are displayed accurately, and
that a link with no clicks shows an empty/zero report rather than an error.

**Acceptance Scenarios**:

1. **Given** a logged-in user who owns a link with recorded clicks, **When** they open that
   link's report, **Then** they see click counts broken down over time and by referrer.
2. **Given** a logged-in user who owns a link with no recorded clicks, **When** they open
   that link's report, **Then** they see an empty report rather than an error.
3. **Given** a logged-in user, **When** they attempt to view the report for a link they do
   not own, **Then** the attempt is rejected.

---

### User Story 4 - Generate a QR code for a link (Priority: P4)

A logged-in user wants a scannable QR code for one of their short links, for use in print or
physical media.

**Why this priority**: A convenient, self-contained add-on with no dependency from the other
stories, and the lowest-impact if delayed.

**Moved (2026-08-24, constitution v6.0.0)**: QR *generation* itself is now `redirect/`'s
responsibility (`GET /{code}/qr` — specs/001-redirect-service), not `ui/`'s — see FR-012 below.
`ui/`'s role in this story is now just linking/embedding that endpoint on the link detail page.
Acceptance Scenario 2 (ownership rejection) no longer applies: the moved endpoint has no
ownership check, since it encodes exactly the same already-public URL the redirect endpoint
itself resolves (see FR-012).

**Independent Test**: Can be fully tested by requesting a QR code for an existing link and
confirming it decodes to that link's short URL.

**Acceptance Scenarios**:

1. **Given** any user, logged in or not, **When** they request a QR code for an active link's
   code, **Then** they receive a QR code that, when scanned, resolves to that link's short URL.

---

### User Story 5 - Upgrade to Pro (Priority: P5)

A Free-plan user who's approaching (or has hit) the active-link cap, or who wants programmatic
API access, subscribes to Pro through a third-party billing provider and immediately gets an
uncapped account.

**Added (2026-09-10)**: Not part of the original feature description; introduced once a paid
tier was decided on. See Clarifications above.

**Why this priority**: Monetization matters, but it depends on User Stories 1–2 already working
(a plan is meaningless without links to be capped or uncapped), and nothing else in the product
depends on it.

**Independent Test**: Can be fully tested by having a Free-plan user at the active-link cap
attempt (and fail) to create one more link, complete a Pro checkout, and confirm the same
creation now succeeds and the cap no longer applies.

**Acceptance Scenarios**:

1. **Given** a Free-plan user with fewer active links than the configured cap, **When** they
   create a new link, **Then** creation succeeds exactly as it always has.
2. **Given** a Free-plan user already at the configured active-link cap, **When** they attempt
   to create another link, **Then** the creation is rejected with a clear reason referencing the
   cap, and no link is created.
3. **Given** a Free-plan user at the cap, **When** they deactivate or let an existing link
   expire, **Then** they immediately have room to create one more, without needing to upgrade.
4. **Given** a Free-plan user, **When** they complete a Pro checkout through the billing
   provider, **Then** their account's plan updates to Pro and the active-link cap no longer
   applies to them, with no limit on how many active links they may hold.
5. **Given** a Pro subscriber, **When** they view their account, **Then** they can see their
   current plan and manage their subscription through the billing provider.

---

### User Story 6 - Create links programmatically via the API (Priority: P6)

A Pro subscriber generates a named API key from their profile page and uses it from a script or
CI job to create short links without going through the browser UI.

**Added (2026-09-10, extended 2026-09-11)**: Not part of the original feature description;
introduced alongside the Pro plan. See Clarifications above.

**Why this priority**: A genuine differentiator for Pro, but it's an add-on for users who
already have the core product working — nothing else depends on it.

**Independent Test**: Can be fully tested by a Pro user creating an API key, using its raw value
to call the link-creation API successfully, then revoking it and confirming it no longer
authenticates.

**Acceptance Scenarios**:

1. **Given** a Pro subscriber, **When** they create a new named API key, **Then** its raw value
   is shown to them exactly once and never displayed again afterward.
2. **Given** a valid, active API key, **When** it's used to call the link-creation API, **Then**
   a link is created for that key's owner, the same as if they'd used the authenticated UI form.
3. **Given** a Free-plan user (no Pro subscription), **When** they attempt to create an API key,
   **Then** the attempt is rejected.
4. **Given** a Pro subscriber who revokes one of their API keys, **When** that key is used
   afterward, **Then** authentication fails and no link is created, while the account's other
   keys continue to work.
5. **Given** a Pro subscriber already holding the configured maximum number of active API keys,
   **When** they attempt to create one more, **Then** the attempt is rejected with a clear reason
   referencing the limit, until they revoke an existing key.

---

### User Story 7 - Delete my account (Priority: P7)

A user who no longer wants their account permanently removes it, along with everything it owns.

**Added (2026-09-09)**: Not part of the original feature description.

**Why this priority**: A low-frequency action that must still be correct, but nothing else in
the product depends on it, and it's the most destructive, least-reversible action a user can
take, so it's ordered last.

**Independent Test**: Can be fully tested by creating an account with at least one link and
some click history, deleting it, and confirming the account, its links, and their click history
are all gone and the account's short codes are no longer resolvable.

**Acceptance Scenarios**:

1. **Given** a logged-in user on their account page, **When** they type their own account email
   to confirm and submit account deletion, **Then** their account, every link they own, and
   those links' click history are permanently removed in one operation.
2. **Given** a logged-in user attempting to delete their account, **When** the text they type
   does not exactly match their account email, **Then** the delete action stays disabled and no
   deletion occurs.
3. **Given** an account that has just been deleted, **When** anyone requests one of its former
   short codes, **Then** the redirect service reports it as not-found, the same as any code that
   never existed.

---

### Edge Cases

- What happens when two different links (even from different owners) use the exact same SEO
  slug text? Nothing — allowed. The slug has no uniqueness requirement; it's tied 1:1 to its
  own code and never used as a lookup key, so collisions between unrelated links' slugs are
  not a conflict.
- What happens when a visitor requests `/{code}/{slug}` with a slug that doesn't match the
  code's registered slug (or the code has no slug registered)? The redirect service reports
  not-found (404) — this is `redirect/`'s behavior (its spec FR-021), not something this
  application enforces at request time.
- What happens when a user sets an expiration date that is already in the past? Creation or
  update is rejected as invalid, rather than silently producing an already-expired link
  (FR-023).
- What happens when a user deletes a link that has existing click history? The link becomes
  permanently unresolvable, and its click history is deleted along with it — not merely
  inaccessible, actually removed (see FR-022).
- What happens when the write-through to Redis fails after the Postgres write succeeds on
  create, update, or delete? The change is still durable and correct in Postgres (the source
  of truth); the redirect service will serve stale or missing data only until its own
  cache-miss fallback path picks up the corrected state.
- What happens when a user tries to create a link pointing at a URL that is syntactically
  valid but uses a disallowed scheme (e.g. `javascript:`, `data:`)? Rejected as unsafe, the
  same as any other unsafe URL.
- What happens when a user signs in with Google but has never logged in before? A user
  account is created automatically from their Google identity; there is no separate
  registration step to complete first.
- How does the system behave if a user is deactivated by an update while the link is
  currently cached as active in Redis? The write-through on update immediately corrects the
  cached state, so the deactivation takes effect without waiting on cache expiry.
- What happens when a user submits two conflicting updates to the same link at nearly the same
  time (e.g. from two browser tabs)? Last write wins — no conflict detection or optimistic
  locking; since only the owning user can ever update their own link, this is treated as a
  low-stakes case not worth the added complexity.
- What happens when the operating system's light/dark preference changes while a user has the
  application open and has not made an explicit appearance choice (FR-027)? The application
  follows the OS's live change rather than requiring a reload; once the user makes an explicit
  choice, it no longer tracks OS changes.
- What happens when a signed-out visitor abandons or declines the Google sign-in prompt
  triggered by the public shorten form (FR-028/FR-029)? No link is created — the write never
  happens until authentication succeeds (FR-001) — and no data is retained beyond what was
  already present in that in-progress browser session.
- What happens to a Pro subscriber's active-link cap if their subscription is later canceled or
  lapses? They revert to the Free plan and its cap; any links already active past that cap are
  left as-is (not force-deactivated), but they cannot create another active link until they're
  back under the cap or resubscribe (FR-031/FR-032).
- What happens to a Pro subscriber's existing API keys if their subscription is canceled? The
  keys themselves are not automatically revoked — they still exist and are still listed — but
  they stop authenticating immediately, since plan status is checked live on every API request,
  not just at key-creation time (see Assumptions). They'd work again without needing to be
  recreated if the account becomes Pro again.
- What happens when an API key is used to attempt something other than link creation (e.g. an
  update or delete)? There is no such route — the API surface for a key is exactly the same
  create-only capability as `POST /api/links`, nothing more (FR-033).
- What happens when an account being deleted (FR-030) has a Pro subscription or any API keys?
  **Known gap, flagged 2026-09-11, not yet fixed**: `subscriptions` and `api_keys` (both added
  2026-09-10) were never reconciled with the account-deletion implementation, which predates
  them — it deletes `links` then the `users` row, but not `subscriptions`/`api_keys`, and both
  reference `users.id` with no cascade. An account that has ever subscribed to Pro or created an
  API key almost certainly cannot delete itself today, violating Acceptance Scenario 1 above.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST allow a user to log in, and MUST NOT allow link creation,
  update, deletion, or analytics viewing without being logged in. (A public, unauthenticated
  entry point may accept the *start* of a create request — see FR-028/FR-029 — but the creation
  itself never happens until the user is authenticated. QR code generation is exempt — see
  FR-012, moved to `redirect/` as a public endpoint in constitution v6.0.0.)
- **FR-002**: The system MUST allow a logged-in user to create a short link by supplying a
  long destination URL.
- **FR-003**: The system MUST allow a user, when creating or later updating a link, to
  optionally supply a slug — a separate, cosmetic value from the link's code, appended
  after it in the short URL (`bl8.us/{code}/{slug}`) purely for readability/SEO. The
  slug is never used as, or in place of, the code itself.
- **FR-004**: The system MUST allow a user, when creating a link, to optionally supply an
  expiration date after which the link stops being usable.
- **FR-005**: The system MUST reject link creation or update when the supplied URL is
  malformed or otherwise not a valid URL.
- **FR-006**: The system MUST reject link creation or update when the supplied URL is
  determined to be unsafe via structural checks: disallowed schemes (e.g. `javascript:`,
  `data:`) and blocked internal/private-network targets. (A prior draft also required checking
  the URL against an external reputation/safe-browsing service; that was removed for now — see
  Clarifications session 2026-08-17 — and may be reconsidered later.)
- **FR-007**: The system MUST reject link creation or update when a supplied slug doesn't
  match the required format — lowercase alphanumeric characters and hyphens only, 3–32
  characters long. The slug has no uniqueness requirement (per code, per owner, or globally):
  it is not a lookup key, so two different links (even from different owners) may freely use
  the same slug text.
- **FR-008**: The system MUST allow a user to update their own links, including the
  destination URL, expiration date, and active/deactivated status.
- **FR-009**: The system MUST allow a user to permanently delete their own links.
- **FR-010**: The system MUST prevent a user from viewing, updating, deleting, or viewing
  analytics for links owned by another user.
- **FR-011**: The system MUST display, for each of a user's links, click analytics comprising
  click counts broken down over time and by referrer.
- **FR-012**: The system MUST make a QR code available for any active link, which resolves to
  that link's short URL when scanned, as a PNG image at a fixed resolution of at least
  512×512 pixels, so it can be printed or embedded in other documents without pixelation.
  **Moved (2026-08-24, constitution v6.0.0)**: generation itself is `redirect/`'s
  responsibility (`GET /{code}/qr`, specs/001-redirect-service), not `ui/`'s — a public,
  unauthenticated endpoint with no ownership check, since it encodes exactly the same
  already-public URL the redirect endpoint itself resolves. `ui/` only links/embeds it (link
  detail page).
- **FR-013**: On every create, update, or delete of a link, the system MUST write the change
  to Postgres as the durable source of truth.
- **FR-014**: On every create, update, or delete of a link, the system MUST also write the
  corresponding change through to Redis as part of that same operation, so the redirect
  service reflects the new state immediately rather than waiting for its own cache-miss
  fallback.
- **FR-015**: The system MUST let a user log in via Google authentication (Google as the
  identity provider); the system MUST NOT provide its own self-service sign-up or
  password-based account creation.
- **FR-016**: The system MUST create a user account for a given Google identity automatically
  on first successful Google login, so no separate registration step is required.
- **FR-017**: The system MUST apply a rate limit, keyed by account, to a logged-in user's link
  creation and link update requests. Delete requests are not rate-limited. (Unauthenticated
  requests never reach this limiter — FR-001 already rejects them outright, so no separate
  IP-keyed limiting applies here.) The threshold (request count and time window) MUST be
  configurable without a code change, not hardcoded.
- **FR-018**: The system MUST expire a user's session 72 hours after login, requiring the user
  to re-authenticate via Google after that point.
- **FR-019**: On the create and update routes, the system MUST return a distinct, unambiguous
  response for each rejection category, so a caller can tell them apart: a validation failure
  (malformed/unsafe URL, malformed slug, or past-dated expiration) MUST return 400 Bad Request; a
  rate-limited request (FR-017) MUST return 429 Too Many Requests; on update, a non-owner
  request MUST return 403 Forbidden and a request for a nonexistent code MUST return 404 Not
  Found.
- **FR-020**: The system MUST allow a user to view a paginated list of their own links (and no
  other user's), ordered newest-first, 100 links per page. There is no separate cap on the
  total number of links a user may have — pagination is what bounds each response.
- **FR-021**: When a create or update submission has multiple validation failures at once
  (e.g. a malformed URL and a malformed slug together), the system MUST report all applicable
  failures in a single response, not just the first one encountered.
- **FR-022**: When a link is permanently deleted, the system MUST also delete its associated
  click-event history; deleted click data is not retained or recoverable.
- **FR-023**: The system MUST reject link creation or update when the supplied expiration date
  is at or before the current time.
- **FR-024**: The create, manage, analytics, and QR flows SHOULD conform to WCAG 2.1 Level AA
  wherever practical — including keyboard operability and screen-reader-compatible labeling
  for all interactive elements. This is a best-effort target, not a hard release gate: where a
  specific interaction genuinely can't meet it, that's an acceptable, documentable exception
  rather than a blocker.
- **FR-025**: The system MUST provide a public, unauthenticated system-status page reporting
  whether it can currently reach Postgres, separate from any machine-readable health endpoint
  used by infrastructure probes. It MUST NOT require login — an outage is exactly when login
  itself might be affected, and status information isn't sensitive.
- **FR-026**: The system MUST emit structured (not plain-text) logs for every link creation,
  update, and deletion — including the acting account and the affected code — and for every
  rejected request (validation failure, ownership rejection, rate-limit rejection). Logged
  detail MUST NOT include another user's data beyond what's needed to identify the rejected
  action (e.g. no other user's destination URLs).
- **FR-027**: The system MUST let a user switch the application's appearance between light,
  dark, and system-matched. Appearance MUST default to the operating system's current
  light/dark preference until the user makes an explicit choice; an explicit choice MUST
  persist across future visits rather than reverting to system on the next visit.
- **FR-028**: The system MUST present the short-link creation form (destination URL, optional
  slug, optional expiration) — the **public shorten form** — on the public,
  unauthenticated landing page, so a visitor does not need to already be signed in to begin
  creating a link.
- **FR-029**: When a signed-out visitor submits the public shorten form, the system MUST
  route them through Google sign-in (FR-015) and, upon successful authentication, complete
  that same creation request without requiring the visitor to re-enter the URL, slug, or
  expiration — redirecting to the new link's result page on success (FR-002), or returning
  them to the create form with their original input preserved and validation errors shown on
  failure (FR-019, FR-021).

- **FR-030**: The system MUST allow a logged-in user to permanently delete their own account.
  The action MUST require the user to type their own account email to confirm before it can be
  submitted. Deletion MUST remove the account and every link (and, via FR-022's existing
  cascade, click history) it owns in a single operation; it MUST NOT be partially applied or
  recoverable afterward. **Known gap** — see Edge Cases: this is not yet reconciled with
  `subscriptions`/`api_keys` (FR-032/FR-033), added after this requirement's original
  implementation.
- **FR-031**: The system MUST support exactly two account plans — Free and Pro — with every
  capability in FR-001 through FR-029 available on both. Free MUST cap how many of an account's
  links may be simultaneously active at once; Pro MUST NOT apply this cap. The cap is a standing
  limit on currently-active links, not a monthly or lifetime creation quota — deactivating or
  letting a link expire MUST immediately free a slot. The cap's specific number MUST be
  configurable without a code change, not hardcoded.
- **FR-032**: The system MUST let a Free-plan user upgrade to Pro by completing checkout through
  a third-party billing provider; the system MUST NOT collect or store payment card details
  itself. On successful subscription (via the provider's webhook), the account's plan MUST
  update to Pro without requiring the user to take any further action. The system MUST let a Pro
  subscriber reach their subscription management through the billing provider from their
  account page.
- **FR-033**: The system MUST let a Pro subscriber (and MUST NOT let a Free-plan user) create a
  named API key from their account page. Creating one MUST require a name. The raw key value
  MUST be shown to the user exactly once, at creation; the system MUST NOT store it in a
  recoverable form afterward, and MUST NOT display it again on any later view. Every active API
  key MUST authenticate a link-creation-only API route (`POST /api/links`), independent of the
  browser session/cookie authentication used everywhere else in this application, creating a
  link for that key's owning account and applying the exact same validation and rejection rules
  (FR-005–FR-007, FR-019, FR-021, FR-023) as the authenticated UI create flow. The route MUST
  re-verify the owning account is still on the Pro plan on every request (not only once, at the
  key's own creation), so a lapsed subscription stops authentication immediately without
  requiring the key itself to be separately revoked.
- **FR-034**: The system MUST let a Pro subscriber view a list of their own active API keys
  (name, a non-secret identifying prefix, creation date, last-used date) and individually revoke
  any one of them without affecting their other keys. A revoked key MUST immediately stop
  authenticating.
- **FR-035**: The system MUST cap how many active (non-revoked) API keys a single account may
  hold at once, configurable without a code change, defaulting to 10. Revoking a key MUST
  immediately free a slot for creating another, the same standing-cap shape as FR-031's
  active-link cap.

### Key Entities

- **User Account**: A person who can log in and who owns short links. Links, their updates,
  deletions, and analytics views are all scoped to the owning account. Also owns a plan
  (FR-031), at most one subscription (FR-032), and zero or more API keys (FR-033–FR-035).
  Can permanently delete itself and everything it owns (FR-030).
- **Subscription**: Represents a User Account's paid relationship with a billing provider —
  which provider, its plan, and its current status. Created and kept in sync exclusively by
  that provider's webhook (FR-032); this application never originates or edits it directly.
- **API Key**: A named, Pro-only credential (FR-033) belonging to one User Account, used to
  authenticate the link-creation API independent of a browser session. Its raw value exists
  only once, at creation; the account can list its own keys (without their raw values) and
  revoke any one individually (FR-034).
- **Short Link**: A destination URL together with its system-generated code, an optional
  cosmetic slug tied 1:1 to that code, owner, optional expiration date, and
  active/deactivated status. Created, updated, and deleted exclusively through this
  application; read (and, for expiration/deactivation/slug-matching, enforced) by the
  redirect service.
- **Click Analytics**: A read-oriented view, per link, of click counts over time and by
  referrer. Derived from click events recorded elsewhere (by the redirect service); this
  application reads and presents them but does not itself record clicks.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A logged-in user can go from pasting a long URL to having a working short link
  in a single straightforward submission, with no more than one round trip for correction if
  their input was invalid.
- **SC-002**: 100% of link creation or update attempts with a malformed or unsafe URL are
  rejected, with no link created or changed as a result.
- **SC-003**: 100% of link creation or update attempts with a malformed slug (wrong
  charset or length) are rejected, with no link created or changed as a result.
- **SC-004**: Changes made through create, update, or delete are reflected in the redirect
  service's behavior within 2 seconds (p95), rather than waiting for a cache entry to expire
  or be evicted.
- **SC-005**: A user can find accurate, up-to-date click counts and referrer breakdowns for
  any link they own.
- **SC-006**: A user can obtain a working, scannable QR code for any link they own.
- **SC-007**: In 100% of attempts, a user is unable to view, edit, delete, or see analytics
  for a link they do not own.
- **SC-008**: A single authenticated account sending excessive create or update requests is
  throttled rather than able to overwhelm the system without limit; deletion is never
  throttled.
- **SC-009**: A user's explicit light/dark/system appearance choice persists across sessions
  without needing to be re-selected on each visit.
- **SC-010**: A signed-out visitor who starts creating a link on the public landing page and
  completes Google sign-in ends up with that exact link created, without needing to re-enter
  the URL, slug, or expiration.
- **SC-011**: 100% of link-creation attempts by a Free-plan account already at the active-link
  cap are rejected, with no link created; the same account can create again as soon as it's
  back under the cap, with no other action required.
- **SC-012**: A Free-plan user who completes a Pro checkout can create an unlimited number of
  active links and a Pro-only API key immediately afterward, with no additional manual step.
- **SC-013**: A revoked API key stops authenticating within the same request cycle — there is
  no window where a just-revoked key still works.
- **SC-014**: A deleted account, and everything it owned, is fully unresolvable and
  unrecoverable immediately afterward, with no partial or delayed cleanup.

## Assumptions

- The short code is always system-generated (never user-chosen) and remains the sole,
  globally-unique lookup key, unchanged from the original design. The slug is a separate,
  optional, non-unique cosmetic value.
- "Update" is the mechanism by which a link's active/deactivated status is changed; the
  feature description didn't call out deactivation as a separate action, and it is treated as
  one of the fields a user can update on their own link (alongside destination URL and
  expiration date).
- Deleting a link is permanent and distinct from deactivating it: a deleted link's code no
  longer exists at all (the redirect service reports it as not-found), whereas a deactivated
  link's record still exists but is flagged as inactive (the redirect service reports it as
  gone). This mirrors the not-found vs. gone distinction already established for the redirect
  service.
- Click events themselves are recorded by the redirect service, not by this application; this
  application only reads and aggregates them for the analytics report.
- Analytics click counts are bucketed by day (`FR-011`); the retention window (how far back
  the report looks) is left to a standard, reasonable default and is not treated as
  scope-defining. (QR code format is no longer a default — see FR-012.)
- Loading/in-progress UI states for create, update, and the analytics report are left to
  standard, reasonable implementation defaults and are not treated as scope-defining.
- The rate limiter in FR-017 is a mechanism distinct and independent from the redirect
  service's own global, environment-configurable read-path rate limiter — the two are
  unrelated.
- A user's identity is keyed on their unique Google account identity (not just their email
  address), so link ownership stays stable even if the associated email were to change.
- Account/session compromise (e.g. a hijacked Google session) is out of scope for this
  feature; this application relies on Google's own session/account security rather than
  defining its own compromise-detection or session-revocation requirements.
- If Google's OAuth service is unreachable during login, the user sees a standard error
  message (e.g. "sign-in temporarily unavailable, try again") — there is no fallback login
  method, since Google is the only login method by design (FR-015).
- A canceled/lapsed Pro subscription is checked live on every API-authenticated request (FR-033),
  not just at key-creation time — so access via an existing, still-active key stops immediately
  once the account is no longer Pro, without needing to also revoke the key itself. Creation of
  a *new* key (FR-033) is a separate, one-time gate at the moment of creation.
- Which specific Pro-plan capabilities beyond the active-link cap and API access actually ship
  (e.g. exportable analytics, priority support) is marketing/roadmap scope, not this
  specification's — only capabilities that are actually implemented and testable are captured
  as FRs here.
- The billing provider (Paddle or Stripe) is solely responsible for payment collection, card
  storage, and PCI compliance; this application only ever receives and stores the resulting
  plan/subscription status, never payment instrument details.
