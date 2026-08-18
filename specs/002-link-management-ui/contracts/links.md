# Contract: Link Create / List / Update / Delete

All routes below require a valid session (see contracts/auth.md); none accept anonymous
requests (FR-001).

## Response Body Conventions (shared across contracts/links.md, analytics.md, qr.md)

- **Validation failures (400)**: SvelteKit's `fail()` action convention —
  `{ errors: { <fieldName>: <message> }, values: { ...echoed form input, excluding any
  sensitive fields } }`. This is what a page's `ActionData` expects, so the form can show
  per-field errors and preserve what the user typed. When multiple fields fail validation at
  once, `errors` MUST include every applicable field, not just the first one found (FR-021).
- **Ownership-rejected (403), not-found (404), rate-limited (429)**: SvelteKit's `error()`
  helper convention — `{ message: string }`. These aren't reachable through normal UI use
  (a user can't see another user's edit form to submit to), so they don't need field-level
  detail.

## `GET /links`

Lists the authenticated user's own links (supports User Story 2's "reviews the links they've
created"). Never returns another user's links (FR-010).

**Pagination**: 100 links per page, ordered newest-first by `created_at` (FR-020). No separate
cap on total links per user — additional pages simply continue the same ordering.

- `200 OK` — page of the caller's links (`code`, `alias`, `destination_url`, `is_active`,
  `expires_at`, `created_at`), plus pagination metadata (e.g. a cursor or page number and
  whether a next page exists).

## `GET /links/{code}`

The detail/confirmation page for a single link the caller owns (User Story 1's post-create
confirmation; extended by User Story 2 with edit/delete controls).

| Outcome | When | Response |
|---|---|---|
| Shown | Caller owns `code` | `200 OK` — the link's `code`, `alias`, `destination_url`, `is_active`, `expires_at`. |
| Rejected — not owner | `code` exists but `owner_id` ≠ caller | `403 Forbidden`, per contracts/links.md's Response Body Conventions (FR-010). |
| Rejected — not found | `code` doesn't exist | `404 Not Found`, per contracts/links.md's Response Body Conventions. |

## `GET /links/new` — carried-over submission from the public landing page (resolved 2026-08-17)

`/links/new` is still gated by the auth hook like every other `/links` route (no anonymous
access to the route itself). This entry only exists because the public landing page's shorten
form (research.md's "Public shorten-form: auth gating and continuation") may redirect an
authenticated user here with `?url=...&alias=...&expiresAt=...` query parameters, carried
through the Google sign-in `callbackUrl`. When present and the session is valid, the `load`
function completes creation server-side using the same validation as `POST /links/new` below
and redirects to the result page — the user never has to re-submit. If validation fails, the
page renders normally with the fields pre-filled from the query parameters and the errors
shown, exactly as a failed `POST` would.

## `POST /links/new` (form action)

Creates a link (User Story 1). The `code` is always system-generated — there is no way to
supply your own; `alias` is a separate, optional, cosmetic value. Also reachable, with
identical validation and outcomes, via the public landing page's shorten form when the caller
is already authenticated (research.md).

**Input**: `url` (required), `alias` (optional — SEO decoration, not a lookup key), `expiresAt`
(optional).

**Rate limiting**: checked first, before validation — keyed by account `id` (this route always
requires an existing session, per FR-001; research.md).

| Outcome | When | Response |
|---|---|---|
| Created | `url` valid and safe; `alias` (if given) well-formed; `expiresAt` (if given) not in the past | New link row (system-generated `code` + optional `alias`) + Redis write-through (FR-013, FR-014); redirect to the link's detail page. |
| Rejected — invalid URL | `url` malformed | `400 Bad Request`, form re-rendered with a validation error (FR-005, FR-019); no link created. |
| Rejected — unsafe URL | `url` fails structural checks (disallowed scheme or internal/private-network target) | `400 Bad Request`, form re-rendered with a validation error (FR-006, FR-019); no link created. |
| Rejected — malformed alias | `alias` given but not lowercase alphanumeric+hyphens, 3–32 chars | `400 Bad Request`, form re-rendered with a validation error (FR-007, FR-019); no link created. |
| Rejected — expiration in the past | `expiresAt` ≤ now | `400 Bad Request`, form re-rendered with a validation error (FR-023, FR-019); no link created. |
| Rejected — rate limited | Rate limit exceeded for the caller's account | `429 Too Many Requests` (FR-019), no link created. |

## `PATCH /links/{code}` (form action on the link's own page)

Updates a link the caller owns (User Story 2). Fields: `destinationUrl`, `alias`, `expiresAt`,
`isActive` (any subset; `isActive` is the deactivation mechanism, per data-model.md). Changing
`alias` never affects `code` — the code is immutable once created.

**Rate limiting**: checked first, same as create (FR-017) — keyed by account (this route
always requires an existing session, per FR-001/FR-010).

| Outcome | When | Response |
|---|---|---|
| Updated | Caller owns `code`; any new `destinationUrl` passes the same validation as create; any new `alias` is well-formed; any new `expiresAt` is not in the past | Row updated + Redis write-through with the full new state (FR-013, FR-014). |
| Rejected — not owner | `code` exists but `owner_id` ≠ caller | `403 Forbidden` (FR-010, FR-019); no change made. |
| Rejected — not found | `code` doesn't exist | `404 Not Found` (FR-019). |
| Rejected — invalid/unsafe URL | New `destinationUrl` fails validation | `400 Bad Request`, form re-rendered with a validation error (FR-019); existing link left unchanged (spec.md Acceptance Scenario 2.4). |
| Rejected — malformed alias | New `alias` given but not lowercase alphanumeric+hyphens, 3–32 chars | `400 Bad Request`, form re-rendered with a validation error (FR-007, FR-019); existing link left unchanged. |
| Rejected — expiration in the past | New `expiresAt` ≤ now | `400 Bad Request`, form re-rendered with a validation error (FR-023, FR-019); existing link left unchanged. |
| Rejected — rate limited | Rate limit exceeded for the caller's account | `429 Too Many Requests` (FR-017, FR-019); no change made. |

## `DELETE /links/{code}` (form action)

Permanently deletes a link the caller owns (User Story 2). Not rate-limited (FR-017).

| Outcome | When | Response |
|---|---|---|
| Deleted | Caller owns `code` | Row removed + Redis key removed (FR-013, FR-014, data-model.md); link is no longer resolvable by `redirect/` (reports 404, not 410, per data-model.md's not-found/gone distinction). |
| Rejected — not owner | `code` exists but `owner_id` ≠ caller | `403 Forbidden` (FR-010, FR-019); nothing deleted. |
| Rejected — not found | `code` doesn't exist | `404 Not Found` (FR-019). |

## Explicitly out of scope

- No bulk create/update/delete.
- No transfer of link ownership between accounts.
