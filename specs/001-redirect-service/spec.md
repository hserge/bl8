# Feature Specification: Redirect Service

**Feature Branch**: `001-redirect-service`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description: "Build the redirect service (redirect/). It has exactly two routes: GET /{code}, which looks up the short code, redirects to the associated long URL, and records a click event; and GET /health, which reports whether the service can reach Redis and Postgres. On a redirect request, check Redis first. On a cache miss, look up the code in Postgres, serve the redirect, and write the mapping back into Redis so subsequent requests hit the cache. If the code doesn't exist in either Redis or Postgres, or the link has expired, return 404. It has global, hardcoded rate limiter. Link also can be deactivated which will return 410. Click recording must never block or slow down the redirect response. This service has no create, update, delete, or list endpoints, no authentication, and no request validation beyond looking up the code."

## Clarifications

### Session 2026-08-24

- Q: Should QR code generation move here from `ui/`? → A: Yes — a third route, `GET /{code}/qr`, returning a PNG that encodes the code's canonical short URL. Reuses the exact same lookup and active/expiry rules as the redirect route (FR-005–FR-008); no ownership or auth check, since this service performs no authentication by rule (FR-017) and the encoded URL is already public via `GET /{code}` itself. Captured as FR-022, and FR-019 is updated from "no routes other than redirect and health" to include this third route. See `.specify/memory/constitution.md` v6.0.0.
- Q: Should the QR endpoint support a "fancier" generator with selectable preset styles? → A: Yes — clarified via AskUserQuestion that this means a picker across multiple presets (not one fixed fancier default), so it's real caller-visible customization. An optional `?style=` query param selects from a small, fixed, closed enum (`classic`, `rounded`, `dark`); an unrecognized or missing value silently falls back to `classic` rather than erroring. Captured as an update to FR-022. See `.specify/memory/constitution.md` v7.0.0.
- Q: Should styling go further — independent dot shape, corner-marker shape, and an arbitrary background color? → A: Yes, superseding the single `style` enum. `dots` (`square`/`round`) and `corners` (`square`/`round`/`half`) stay small closed enums; `bg` accepts any well-formed hex color, unenumerated, since color isn't a discrete space the way shape is. Foreground/ink color is never a parameter — it's derived from `bg`'s luminance so no combination can render unreadable. Corner markers render as one unified layered shape per marker (not per-module dots, which is what the prior per-module circle rendering actually produced). Captured as an update to FR-022. See `.specify/memory/constitution.md` v8.0.0.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Follow a short link to its destination (Priority: P1)

A visitor clicks or navigates to a short link. The service looks up the code and sends them
on to the destination URL, recording that the click happened without making the visitor wait
for that recording to finish.

**Why this priority**: This is the entire reason the service exists. Every other behavior
(caching, health, rate limiting, deactivation) only matters in service of this journey.

**Independent Test**: Can be fully tested by requesting a known, active, unexpired short code
and confirming the visitor is redirected to the correct destination URL, with a click event
recorded for that request.

**Acceptance Scenarios**:

1. **Given** a short code whose mapping is already cached, **When** a visitor requests it,
   **Then** the service redirects to the destination URL using the cached mapping and a click
   event is recorded for the request.
2. **Given** a short code that exists and is active but is not yet cached, **When** a visitor
   requests it, **Then** the service looks it up from durable storage, redirects the visitor
   to the destination URL, and stores the mapping in the cache so the next request for that
   code is served from cache.
3. **Given** the cache is completely unavailable, **When** a visitor requests a short code
   that exists in durable storage, **Then** the visitor is still redirected successfully.
4. **Given** a successful redirect just occurred, **When** the click event is being recorded,
   **Then** the recording happens after the redirect response has already been sent, and any
   failure to record it does not change or delay the response the visitor received.

---

### User Story 2 - Get a clear result for links that can't be followed (Priority: P2)

A visitor requests a short code that doesn't exist, has expired, or has been deliberately
deactivated. The service tells them clearly that the link can't be followed, using a distinct
result for "never existed or expired" versus "deliberately turned off."

**Why this priority**: Correct not-found and deactivated handling is what makes the primary
redirect behavior trustworthy; without it, broken or retired links would silently misbehave.

**Independent Test**: Can be fully tested by requesting a nonexistent code, an expired code,
and a deactivated code, and confirming each produces the expected distinct outcome with no
redirect and no click event recorded.

**Acceptance Scenarios**:

1. **Given** a short code that has never existed, **When** a visitor requests it, **Then**
   the service reports the link as not found and does not redirect.
2. **Given** a short code that existed but has expired, **When** a visitor requests it,
   **Then** the service reports the link as not found and does not redirect.
3. **Given** a short code that has been deactivated, **When** a visitor requests it, **Then**
   the service reports the link as gone (distinct from not-found) and does not redirect.
4. **Given** a short code that is both expired and deactivated, **When** a visitor requests
   it, **Then** the service reports the link as gone (deactivation takes precedence).
5. **Given** any of the above non-redirect outcomes, **When** the request completes, **Then**
   no click event is recorded, since no successful redirect occurred.

---

### User Story 3 - Confirm the service's dependencies are reachable (Priority: P3)

An operator or monitoring system asks the service whether it can currently reach its cache
and its durable storage, so unhealthy instances can be detected and taken out of rotation.

**Why this priority**: Operability matters, but the service delivers no value if health
checks work and redirects don't — this is supporting infrastructure, not the core journey.

**Independent Test**: Can be fully tested by calling the health endpoint while both
dependencies are reachable (expect healthy), and again while one dependency is deliberately
unreachable (expect the response to reflect that specific dependency as unreachable).

**Acceptance Scenarios**:

1. **Given** both the cache and durable storage are reachable, **When** the health endpoint
   is called, **Then** it reports the service as healthy.
2. **Given** the cache is unreachable but durable storage is reachable, **When** the health
   endpoint is called, **Then** it reports the cache as unreachable while distinguishing it
   from durable storage's status.
3. **Given** durable storage is unreachable, **When** the health endpoint is called, **Then**
   it reports durable storage as unreachable.

---

### User Story 4 - Get a scannable QR code for a short link (Priority: P4)

Anyone with a short code — not just its owner — wants a QR code that resolves to the same
destination the short link itself would, for use in print or physical media. **Moved here
2026-08-24** from `ui/`'s original implementation, per constitution v6.0.0 (Session 2026-08-24
clarification above).

**Why this priority**: A convenient, self-contained add-on with no dependency from the other
stories, same as it was when `ui/` owned it.

**Independent Test**: Can be fully tested by requesting the QR route for an active code and
confirming the returned image decodes to that code's short URL; and by confirming the same
active/expiry rules as the redirect route apply (missing/expired → 404, deactivated → 410).

**Acceptance Scenarios**:

1. **Given** an active, unexpired code, **When** its QR route is requested, **Then** a PNG
   image is returned that, when scanned, resolves to that code's short URL.
2. **Given** a code that doesn't exist or has expired, **When** its QR route is requested,
   **Then** the response is 404 — the same status the redirect route itself would give.
3. **Given** a deactivated code, **When** its QR route is requested, **Then** the response is
   410 — the same status the redirect route itself would give.
4. **Given** any requester, regardless of whether they created or own the underlying link,
   **When** they request the QR route for a code they know, **Then** the request succeeds —
   there is no ownership or authentication check, matching this service's no-auth rule (FR-017)
   and the fact that the encoded URL is already public via `GET /{code}`.

---

### Edge Cases

- What happens when both the cache and durable storage are unreachable at redirect time? The
  visitor cannot be redirected; the service reports the link as unavailable rather than
  hanging or crashing.
- What happens when a code was cached, then deactivated or expired afterward? The redirect
  path re-checks durable state on cache population and honors deactivation/expiration; a
  stale cached mapping must not keep serving a deactivated or expired link indefinitely
  (see Assumptions for cache freshness handling).
- How does the system behave when the global rate limit is exceeded? Requests beyond the
  limit are rejected with a distinct response rather than being queued or silently dropped,
  and this applies uniformly to all requesters rather than per-visitor.
- What happens when a request is made for a route other than `GET /{code}`,
  `GET /{code}/{alias}`, or `GET /health`? No such routes exist; the service has no other
  endpoints to handle.
- What happens when `GET /{code}/{alias}` is requested with an alias that doesn't match the
  code's registered alias, or the code has no alias registered? The service reports the link
  as not found (404) — same as an unrecognized code — rather than falling back to a bare-code
  redirect (FR-021).
- What happens if writing the freshly-looked-up mapping back into the cache fails? The
  redirect still succeeds for the current visitor; only the cache repopulation is affected,
  and the next request simply falls back to durable storage again.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The service MUST provide a route that accepts a short code and, when that code
  maps to an active, unexpired link, redirects the requester to the associated destination
  URL.
- **FR-002**: On each redirect request, the service MUST check the cache for the code's
  mapping before consulting durable storage.
- **FR-003**: When the mapping is not found in the cache, the service MUST look up the code
  in durable storage.
- **FR-004**: When a lookup in durable storage succeeds, the service MUST write the mapping
  into the cache so that subsequent requests for the same code are served from the cache.
- **FR-005**: The service MUST report the link as not found when the requested code does not
  exist in either the cache or durable storage.
- **FR-006**: The service MUST report the link as not found when the requested code exists
  but its link has expired.
- **FR-007**: The service MUST report the link as gone, distinctly from not-found, when the
  requested code's link has been deactivated.
- **FR-008**: When a link is both expired and deactivated, the service MUST report it as gone
  (deactivated takes precedence over expired).
- **FR-009**: For every successful redirect, the service MUST record a click event.
- **FR-010**: Click event recording MUST happen asynchronously and MUST NOT block, delay, or
  otherwise affect the timing of the redirect response.
- **FR-011**: A failure to record a click event MUST NOT change the redirect response or
  surface as an error to the requester.
- **FR-012**: The service MUST apply a single, global rate limit shared across all requests
  to the redirect route, not a per-visitor or per-code limit.
- **FR-013**: When the global rate limit is exceeded, the service MUST reject the excess
  request with a distinct response rather than queuing, delaying, or silently dropping it.
- **FR-014**: The service MUST provide a health route that reports whether it can currently
  reach the cache and whether it can currently reach durable storage.
- **FR-015**: The health route's report MUST distinguish which dependency (cache vs. durable
  storage) is unreachable when only one of them is unreachable.
- **FR-016**: The service MUST NOT provide any endpoint to create, update, delete, or list
  links.
- **FR-017**: The service MUST NOT require or perform authentication on any of its routes.
- **FR-018**: The service MUST NOT perform request validation beyond looking up the supplied
  code (no format, schema, or content validation of the code or any other input).
- **FR-019**: The service MUST expose no routes other than the redirect route (with or without
  a trailing SEO-alias segment, per FR-020/FR-021), the QR route (FR-022), and the health route.
- **FR-020**: The service MUST also accept an optional second path segment on the redirect
  route (`GET /{code}/{alias}`) representing an SEO alias. When present, the service MUST
  compare it for exact equality against the looked-up link's registered alias (already fetched
  as part of the same lookup) before redirecting.
- **FR-021**: When the supplied alias does not exactly match the code's registered alias — or
  the code has no registered alias at all — the service MUST report the link as not found
  (404), the same as an unrecognized code (spec.md Edge Cases).
- **FR-022**: The service MUST provide a route, `GET /{code}/qr`, that returns a PNG image
  (at least 512×512px) encoding the code's canonical short URL, applying the exact same
  lookup and active/expiry status rules as the redirect route (FR-002–FR-008) — not a separate
  set of business logic — and performing no ownership or authentication check (moved from
  `ui/`, constitution v6.0.0; Session 2026-08-24 clarification above). The route MUST accept
  optional `dots` (`square`/`round`), `corners` (`square`/`round`/`half`), and `bg` (any
  well-formed hex color) parameters; an unrecognized/malformed or missing value for any of them
  MUST fall back to that parameter's default rather than rejecting the request; foreground/ink
  color MUST be derived from `bg`, never accepted as its own parameter (constitution v8.0.0,
  superseding v7.0.0's single `style` enum). The response MUST include
  `Access-Control-Allow-Origin: *` so it can be fetched cross-origin for client-side download.

### Key Entities

- **Short Link**: The record a code is resolved against. Represents the mapping from a short
  code to a destination URL, plus the state needed to decide whether it can currently be
  followed: whether it is active or deactivated, whether/when it expires, and an optional SEO
  alias (FR-020/FR-021) used only for the trailing-segment equality check, never for lookup.
  Owned and written by systems outside this service; this service only reads it.
- **Click Event**: A record that a short code was successfully resolved and redirected.
  Represents at minimum which code was followed and when. Written by this service, but its
  durability is secondary to — and must never come at the cost of — the redirect response
  itself.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Visitors following a short link that is already cached are redirected with no
  perceptible delay beyond normal network latency.
- **SC-002**: Visitors following a short link that is not yet cached are still redirected
  successfully, with the one-time lookup adding no more than a brief, unnoticeable delay
  compared to a cached redirect.
- **SC-003**: Click event recording adds zero measurable delay to the redirect response — a
  visitor's redirect completes independently of whether or how long click recording takes.
- **SC-004**: 100% of requests for codes that never existed or have expired receive a
  not-found result, and 100% of requests for deactivated codes receive a gone result, with no
  redirect occurring in either case.
- **SC-005**: An operator can determine, via a single call, whether the service can currently
  reach each of its two dependencies, and that determination reflects real-time reachability
  rather than a cached or stale status.
- **SC-006**: Redirects for existing, active, unexpired links keep succeeding even during a
  complete cache outage, as long as durable storage remains reachable.
- **SC-007**: When request volume exceeds the configured global limit, the service continues
  serving requests within that limit rather than degrading or failing for all requesters.

## Assumptions

- The short link's data (destination URL, active/deactivated state, expiration) is created
  and maintained entirely outside this service; this service only ever reads it.
- The redirect issued to the visitor's browser is a temporary (not permanently cached)
  redirect, so that every visit reaches this service and can be counted as a click, rather
  than being satisfied by the visitor's browser from its own redirect cache.
- The global rate limit's exact threshold is set via operator-controlled configuration (e.g.
  environment variables), not a per-link or per-user setting, and the specific value is not
  part of this specification's scope (constitution: no hardcoded tunable parameters).
- The SEO alias is set and formatted (charset, length) entirely by `ui/`; this service never
  validates alias format, only compares the supplied path segment against the stored value for
  exact equality.
- "Reachable" for the health check means the service can successfully establish a connection
  to and get a response from the cache and durable storage, not that every operation against
  them is guaranteed to succeed.
- A click event's recorded details are minimal — at least the code and the time of the click —
  sufficient for downstream analytics to attribute traffic to a link, without this service
  needing to know how that data will later be used.
- Cache entries populated by this service are expected to become consistent with durable
  storage again within a bounded, short time (e.g., via a cache expiration policy) even if a
  link is deactivated or expires after being cached; this service is not required to
  proactively invalidate cache entries the moment a link's status changes elsewhere.
- This service has no user-facing interface beyond the raw HTTP redirect/error responses;
  "visitor" and "operator" in this document refer to whoever or whatever issues the HTTP
  request, not a UI.
