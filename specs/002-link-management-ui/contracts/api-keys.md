# Contract: API Keys (Pro-only programmatic access)

Added 2026-09-10, extended 2026-09-11 (configurable key limit) — not part of the original
feature description (spec.md Clarifications, Session 2026-09-09 through 2026-09-11).

All management routes below require a valid session (see contracts/auth.md) and gate on the
caller's account being on the Pro plan (FR-033); `POST /api/links` is the one exception —
independent of session/cookie auth entirely, authenticated by the key itself.

## `POST /app/profile?/createApiKey` (form action)

Creates a new named API key for the caller (FR-033).

**Input**: `name` (required).

| Outcome | When | Response |
|---|---|---|
| Created | Caller is Pro; `name` non-empty; caller is under the active-key limit (FR-035) | New key row + the raw key value, returned exactly once as `{ createdKey: { name, rawKey } }`. Never persisted or re-displayed after this response. |
| Rejected — not Pro | Caller's account plan is not `'pro'` | `403 Forbidden` — `{ keyError: 'API access requires the Pro plan.' }`; no key created. |
| Rejected — no name | `name` missing or blank after trimming | `400 Bad Request` — `{ keyError: 'Give the key a name so you can recognize it later.' }`; no key created. |
| Rejected — limit reached | Caller already has `API_KEY_LIMIT` (default 10) active keys | `400 Bad Request` — `{ keyError: "You've reached the limit of {N} active keys. Revoke one before creating another." }`; no key created. |

## `POST /app/profile?/revokeApiKey` (form action)

Revokes one of the caller's own keys (FR-034).

**Input**: `keyId` (required, integer).

| Outcome | When | Response |
|---|---|---|
| Revoked | `keyId` is a valid integer | `{ revoked: true }`. Scoped to the caller's own account — a `keyId` that doesn't exist, is already revoked, or belongs to another account is a silent no-op with the same `{ revoked: true }` response, not an error (revocation is idempotent from the caller's point of view; it never leaks whether a given id belongs to someone else). |
| Rejected — malformed id | `keyId` missing or not an integer | `400 Bad Request` — `{ keyError: 'Invalid key.' }`. |

## `POST /api/links`

The Pro-only programmatic link-creation endpoint (FR-033) — the one route in this application
authenticated by something other than the session cookie.

**Authentication**: `Authorization: Bearer <raw key>` header. Re-verifies the key's owning
account is still on the Pro plan on *every* request, not only at the key's own creation, so a
lapsed subscription stops access immediately without the key itself needing to be revoked
(spec.md Assumptions).

**Input** (JSON body): `url` (required), `slug` (optional), `expiresAt` (optional) — identical
fields to `POST /app/links/new` (contracts/links.md).

| Outcome | When | Response |
|---|---|---|
| Created | Valid/active key; owning account is Pro; `url`/`slug`/`expiresAt` all pass the same validation as the UI create flow | `201`-equivalent JSON body describing the new link, via the exact same `createLink()` path the authenticated UI form uses (FR-033) — same validation, same rate limiter, same Free-plan active-link cap if the calling account were ever Free (in practice never, since key creation itself requires Pro). |
| Rejected — missing/malformed auth | No `Authorization` header, or not a `Bearer` value | `401 Unauthorized` — `{ error: 'Missing or malformed Authorization header. Use "Authorization: Bearer <api key>".' }`. |
| Rejected — invalid/revoked key | Key doesn't authenticate (unknown, or `revoked_at` set) | `401 Unauthorized` — `{ error: 'Invalid or revoked API key.' }`. |
| Rejected — not Pro | Key is valid but its owning account's current plan isn't `'pro'` | `403 Forbidden` — `{ error: 'API access requires the Pro plan.' }`. |
| Rejected — malformed body | Body isn't valid JSON | `400 Bad Request` — `{ error: 'Request body must be valid JSON.' }`. |
| Rejected — validation failure | `url`/`slug`/`expiresAt` fail the same checks as the UI create flow (FR-005–FR-007, FR-023) | `422 Unprocessable Entity` — `{ error: 'Validation failed.', details: {...} }`. |

## Explicitly out of scope

- No API routes for list/update/delete/analytics — `POST /api/links` is create-only (FR-033);
  everything else about a link still requires the authenticated UI.
- No API-key-scoped permissions (e.g. read-only keys, per-key rate limits) — a key can do
  exactly one thing: create a link as its owning account, nothing narrower or broader.
- No key rotation/regeneration — creating a new key and revoking the old one is the only path.
