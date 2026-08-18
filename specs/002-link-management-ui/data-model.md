# Phase 1 Data Model: Link Management Web Application

This app owns the Postgres schema (research.md) and is the only writer of `users` and `links`.
It reads `click_events` (written by `redirect/`, per that service's data-model.md) but never
writes to it. It writes through to Redis on every `links` mutation but never reads from Redis.

## User Account

| Field | Type | Notes |
|---|---|---|
| `id` | identifier (PK) | Internal identifier; what `links.owner_id` references. |
| `google_subject_id` | string, unique | Google's stable `sub` claim — the actual identity key (spec.md Assumptions), not email. |
| `email` | string | From the Google profile; display/contact only, not used for identity matching. |
| `created_at` | timestamp | Set on first successful Google login (FR-016). |

**Creation**: Row is created automatically on first successful Google login if no existing row
matches the incoming `google_subject_id` (FR-016) — there is no separate registration form.

## Short Link

| Field | Type | Notes |
|---|---|---|
| `code` | string (PK) | Always system-generated (spec.md Assumptions); globally unique across all users — this is exactly the key `redirect/`'s data-model.md reads. Never user-chosen. |
| `alias` | string, nullable | Optional cosmetic SEO alias tied 1:1 to this `code` (FR-003); lowercase alphanumeric + hyphens, 3–32 characters (FR-007). No uniqueness constraint — different links (even different owners) may share the same alias text, since it's never a lookup key. |
| `owner_id` | identifier (FK → User Account) | Scopes every read/update/delete/analytics/QR action (FR-010). |
| `destination_url` | string | Must pass structural validation before being stored (FR-005, FR-006). |
| `is_active` | boolean | Defaults `true` on create; flipped via update (FR-008) — this is the deactivation mechanism (spec.md Assumptions). Matches `redirect/`'s `is_active` field exactly. |
| `expires_at` | timestamp, nullable | Optional at creation (FR-004); rejected if set in the past (spec.md Edge Cases). Matches `redirect/`'s `expires_at` field exactly. |
| `created_at` | timestamp | Set on creation. |
| `updated_at` | timestamp | Set on every update. |

**Uniqueness constraint**: `code` is globally unique (a database unique constraint, not an
application-level check alone) — this is what makes concurrent code generation safe. `alias`
has no uniqueness constraint at all (FR-007 is a format check, not a uniqueness check).

**Deletion**: Hard delete (spec.md Assumptions) — the row is removed entirely, distinct from
setting `is_active = false`. `redirect/` then reports the code as not-found (404) rather than
gone (410), matching the not-found/gone split already established in `redirect/`'s spec.
Deleting a `links` row also deletes its associated `click_events` rows via a database foreign
key (`click_events.code` → `links.code`, `ON DELETE CASCADE`) — click history is not retained
past its link's deletion (FR-022).

## Click Analytics (read-only view over `redirect/`'s data)

Not a table this app owns — a read/aggregation over the `click_events` rows `redirect/` writes
(see `redirect/`'s data-model.md: `code`, `occurred_at`, `referrer`).

| Derived value | Source | Notes |
|---|---|---|
| Click counts over time | `COUNT(*)` grouped by day (`DATE_TRUNC('day', occurred_at)`) over `click_events.occurred_at` for the link's `code` | Daily bucketing is fixed (Clarifications 2026-08-17); the retention/lookback window is an implementation default. |
| Referrer breakdown | `COUNT(*)` grouped by `click_events.referrer` for the link's `code` | Rows with a null referrer (direct traffic) are their own bucket. |

**Ownership check**: Every analytics query is scoped by joining through `links.owner_id` for
the requesting user's `id` (FR-010) — a user can never query another user's `code`.

## Write-through contract to Redis (this app → `redirect/`)

On create, update (including deactivation), or delete, this app writes to Redis in the same
operation as the Postgres write (FR-014), using the exact key/value shape `redirect/`'s cache
expects to read (its data-model.md — this is a shared contract; changes are a breaking-change
boundary per constitution Principle I): key `link:{code}`, value a single JSON string:

```json
{"destination_url": "https://example.com", "is_active": true, "expires_at": "2026-08-20T00:00:00Z", "alias": "my-article-title"}
```

`expires_at` and `alias` are both JSON `null` when not set, otherwise `expires_at` is an ISO
8601 UTC timestamp and `alias` is the raw alias string. Set via Redis `SET` (not a hash), so
both this app (TypeScript) and `redirect/` (Go) encode/decode the same unambiguous JSON on
either end, with no boolean/timestamp string-coercion surprises (resolved 2026-08-17).

| Postgres operation | Redis write-through |
|---|---|
| Create | `SET link:{code}` to the JSON encoding of its full current state. |
| Update | `SET link:{code}` to the JSON encoding of its full new state (whichever fields changed). |
| Delete | `DEL link:{code}` entirely, so `redirect/` reports not-found immediately rather than serving a stale cached mapping until eviction. |

If the Redis write fails after the Postgres write succeeds, the Postgres write still stands
(source of truth); `redirect/` will see the corrected state on its own next cache-miss fallback
(spec.md Edge Cases) — this app does not roll back or retry the Postgres write because of a
Redis failure.

## State transitions

- **User Account**: created once (first Google login), never updated or deleted by this
  application's in-scope stories.
- **Short Link**: `created → active ⇄ deactivated → (deleted)`. Both `active ⇄ deactivated`
  and the destination/expiration fields are changed via update (FR-008); deletion is terminal
  and irreversible (a new link with the same code could later be created once the code is
  free again, but that is a new row, not a resurrection of the old one).
