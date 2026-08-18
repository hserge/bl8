# Feature Specification: Link Management Web Application

**Feature Branch**: `002-link-management-ui`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description: "Build the web application (ui/) that owns all URL shortener business logic. A user can log in, create a short link from a long URL (optionally with a custom alias and an expiration date), update or delete their links, view click analytics per link (counts over time, referrers) in the report, and generate a QR code for any link. Reject invalid, malformed, or unsafe URLs at creation time, and reject a custom alias that's already taken. On create, update, or delete, write to Postgres as the source of truth and write through the corresponding change to Redis so the redirect service serves fresh data immediately, without waiting for a cache miss."

## Clarifications

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
- Q: Should custom aliases replace the code (as originally specced) and be unique, or become a separate, non-unique SEO decoration? → A: Separate SEO decoration. The code is always system-generated and globally unique (the sole lookup key, unchanged); an alias is an optional, non-unique value tied 1:1 to one code, appended after it (`/{code}/{alias}`). `redirect/` checks the supplied alias for exact equality against the code's registered alias, 404 on any mismatch (including when no alias is registered). This redefines FR-003 and FR-007, and requires a matching change in `redirect/`'s spec (see `specs/001-redirect-service/spec.md` FR-020/FR-021).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create a short link (Priority: P1)

A logged-in user pastes a long URL and gets back a working short link (a system-generated
code), optionally attaching an SEO alias for readability and optionally setting when the link
should stop working.

**Why this priority**: This is the core value of the product — turning a long URL into a
short, shareable one. Nothing else in this feature matters without it.

**Independent Test**: Can be fully tested by logging in, submitting a valid long URL, and
confirming a new short link is returned and immediately usable, without touching update,
delete, analytics, or QR functionality.

**Acceptance Scenarios**:

1. **Given** a logged-in user on the create-link form, **When** they submit a valid long URL
   with no SEO alias, **Then** a new short link is created with a system-generated code and is
   immediately available at `/{code}`.
2. **Given** a logged-in user, **When** they submit a valid long URL with a well-formed SEO
   alias, **Then** the short link is created with a system-generated code and the alias
   attached, available both at `/{code}` and `/{code}/{alias}`.
3. **Given** a logged-in user, **When** they submit a valid long URL with a malformed SEO
   alias (wrong charset, or outside the 3–32 character range), **Then** the creation is
   rejected and no link is created.
4. **Given** a logged-in user, **When** they submit a URL that is malformed or otherwise
   invalid, **Then** the creation is rejected with a clear reason and no link is created.
5. **Given** a logged-in user, **When** they submit an expiration date along with the URL,
   **Then** the created link stops being usable after that date.
6. **Given** a user who is not logged in, **When** they submit a valid long URL on the
   public landing page's shorten form, **Then** they are routed through Google sign-in and,
   upon successful authentication, the same link is created automatically without needing to
   re-enter the URL, alias, or expiration, landing on the new link's result page.
7. **Given** a user who is not logged in, **When** they submit the public shorten form with an
   invalid or unsafe URL (or malformed alias, or a past expiration), **Then** after completing
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

**Independent Test**: Can be fully tested by requesting a QR code for an existing link and
confirming it decodes to that link's short URL.

**Acceptance Scenarios**:

1. **Given** a logged-in user who owns a link, **When** they request a QR code for it,
   **Then** they receive a QR code that, when scanned, resolves to that link's short URL.
2. **Given** a logged-in user, **When** they request a QR code for a link they do not own,
   **Then** the attempt is rejected.

---

### Edge Cases

- What happens when two different links (even from different owners) use the exact same SEO
  alias text? Nothing — allowed. The alias has no uniqueness requirement; it's tied 1:1 to its
  own code and never used as a lookup key, so collisions between unrelated links' aliases are
  not a conflict.
- What happens when a visitor requests `/{code}/{alias}` with an alias that doesn't match the
  code's registered alias (or the code has no alias registered)? The redirect service reports
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

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST allow a user to log in, and MUST NOT allow link creation,
  update, deletion, analytics viewing, or QR code generation without being logged in. (A
  public, unauthenticated entry point may accept the *start* of a create request — see
  FR-028/FR-029 — but the creation itself never happens until the user is authenticated.)
- **FR-002**: The system MUST allow a logged-in user to create a short link by supplying a
  long destination URL.
- **FR-003**: The system MUST allow a user, when creating or later updating a link, to
  optionally supply an SEO alias — a separate, cosmetic value from the link's code, appended
  after it in the short URL (`bl8.us/{code}/{alias}`) purely for readability/SEO. The
  alias is never used as, or in place of, the code itself.
- **FR-004**: The system MUST allow a user, when creating a link, to optionally supply an
  expiration date after which the link stops being usable.
- **FR-005**: The system MUST reject link creation or update when the supplied URL is
  malformed or otherwise not a valid URL.
- **FR-006**: The system MUST reject link creation or update when the supplied URL is
  determined to be unsafe via structural checks: disallowed schemes (e.g. `javascript:`,
  `data:`) and blocked internal/private-network targets. (A prior draft also required checking
  the URL against an external reputation/safe-browsing service; that was removed for now — see
  Clarifications session 2026-08-17 — and may be reconsidered later.)
- **FR-007**: The system MUST reject link creation or update when a supplied SEO alias doesn't
  match the required format — lowercase alphanumeric characters and hyphens only, 3–32
  characters long. The alias has no uniqueness requirement (per code, per owner, or globally):
  it is not a lookup key, so two different links (even from different owners) may freely use
  the same alias text.
- **FR-008**: The system MUST allow a user to update their own links, including the
  destination URL, expiration date, and active/deactivated status.
- **FR-009**: The system MUST allow a user to permanently delete their own links.
- **FR-010**: The system MUST prevent a user from viewing, updating, deleting, or viewing
  analytics for links owned by another user.
- **FR-011**: The system MUST display, for each of a user's links, click analytics comprising
  click counts broken down over time and by referrer.
- **FR-012**: The system MUST allow a user to generate a QR code for any link they own, which
  resolves to that link's short URL when scanned. The QR code MUST be returned as a PNG image
  at a fixed resolution of at least 512×512 pixels, so it can be printed or embedded in other
  documents without pixelation.
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
  (malformed/unsafe URL, malformed alias, or past-dated expiration) MUST return 400 Bad Request; a
  rate-limited request (FR-017) MUST return 429 Too Many Requests; on update, a non-owner
  request MUST return 403 Forbidden and a request for a nonexistent code MUST return 404 Not
  Found.
- **FR-020**: The system MUST allow a user to view a paginated list of their own links (and no
  other user's), ordered newest-first, 100 links per page. There is no separate cap on the
  total number of links a user may have — pagination is what bounds each response.
- **FR-021**: When a create or update submission has multiple validation failures at once
  (e.g. a malformed URL and a malformed alias together), the system MUST report all applicable
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
  SEO alias, optional expiration) — the **public shorten form** — on the public,
  unauthenticated landing page, so a visitor does not need to already be signed in to begin
  creating a link.
- **FR-029**: When a signed-out visitor submits the public shorten form, the system MUST
  route them through Google sign-in (FR-015) and, upon successful authentication, complete
  that same creation request without requiring the visitor to re-enter the URL, alias, or
  expiration — redirecting to the new link's result page on success (FR-002), or returning
  them to the create form with their original input preserved and validation errors shown on
  failure (FR-019, FR-021).

### Key Entities

- **User Account**: A person who can log in and who owns short links. Links, their updates,
  deletions, and analytics views are all scoped to the owning account.
- **Short Link**: A destination URL together with its system-generated code, an optional
  cosmetic SEO alias tied 1:1 to that code, owner, optional expiration date, and
  active/deactivated status. Created, updated, and deleted exclusively through this
  application; read (and, for expiration/deactivation/alias-matching, enforced) by the
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
- **SC-003**: 100% of link creation or update attempts with a malformed SEO alias (wrong
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
  the URL, alias, or expiration.

## Assumptions

- The short code is always system-generated (never user-chosen) and remains the sole,
  globally-unique lookup key, unchanged from the original design. The SEO alias is a separate,
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
