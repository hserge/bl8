# Phase 1 Data Model: Redirect Service

This service owns no schema and performs no migrations — the schema is owned and operated
solely by `ui/` (see research.md: confirmed, not merely assumed). It reads one
existing entity and writes one existing entity, both defined here from the *reading/writing*
perspective this service needs, not as a schema authority.

## Short Link (read-only)

The record a code is resolved against. Written and owned elsewhere; this service only reads it.

| Field | Type | Notes |
|---|---|---|
| `code` | string | The short code from the URL path; lookup key in both Redis and Postgres. |
| `destination_url` | string | Where a valid request is redirected to. |
| `is_active` | boolean | `false` means deactivated → serve 410, regardless of expiration. |
| `expires_at` | timestamp, nullable | `null` means never expires. Past-dated and active → serve 404. |
| `alias` | string, nullable | Optional SEO alias (FR-020/FR-021). `null` means no alias is registered for this code. Format/uniqueness rules are `ui/`'s concern (`ui/`'s data-model.md); this service only ever compares it for exact equality. |

**Derived redirect decision** (evaluated in this order, per spec FR-005–FR-008, FR-020,
FR-021):

1. No row found (Redis miss + Postgres miss) → **404 not found**.
2. Row found, request included a second path segment, and it does not exactly equal the row's
   `alias` (including the case where `alias` is `null`) → **404 not found** (FR-021) —
   evaluated before the checks below, since a wrong alias means "this isn't the resource you
   think it is," regardless of the code's own state.
3. Row found, `is_active = false` → **410 gone** (deactivation takes precedence — checked
   before expiration).
4. Row found, `is_active = true`, `expires_at` not null and `expires_at <= now` → **404 not
   found** (expired).
5. Row found, `is_active = true`, and (`expires_at` is null or `expires_at > now`) →
   **redirect to `destination_url`**.

**Cache representation** (shared contract with `ui/` — see its data-model.md write-through
table; changes here are a breaking-change boundary per constitution Principle I): key
`link:{code}`, value a single JSON string (via Redis `GET`/`SET`, not a hash — a hash would
force every field to a string on both sides of the Go/TypeScript boundary, inviting
boolean/timestamp encoding mismatches) with exactly:

```json
{"destination_url": "https://example.com", "is_active": true, "expires_at": "2026-08-20T00:00:00Z", "alias": "my-article-title"}
```

`expires_at` and `alias` are both `null` (JSON null, not an empty string/omitted key) when not
set. `expires_at`, when set, is an ISO 8601 UTC timestamp — parseable natively by both Go's
`time.RFC3339` and JavaScript's `Date`. Including `alias` in the cached value is what lets the
alias-match check (FR-020/FR-021) be served entirely from cache, with no second lookup — this
is enough to make the full decision above from cache alone. A cache write happens only after a
successful Postgres lookup (FR-004); nothing is cached for a miss (a Postgres miss simply
results in a 404 with no cache entry written).

## Click Event (write-only, append-only)

A record that a short code was successfully resolved and redirected. Written by this service's
async click writer; never read back by this service (analytics reporting is `ui/`'s concern,
per its spec).

| Field | Type | Notes |
|---|---|---|
| `code` | string | Which short link was followed. |
| `occurred_at` | timestamp | When the redirect happened (set by this service at write time, not by the database default, so it reflects the actual click time even if the write is delayed by the async queue). |
| `referrer` | string, nullable | The requester's `Referer` header, if present. Carried here because `ui/`'s analytics report (per its own spec) breaks down clicks by referrer — this service is the only place that ever sees the raw request, so it's the only place that can capture this field. |

**Write path**: Inserted asynchronously via the click writer's internal queue (research.md);
never read, updated, or deleted by this service. A failed insert is logged/dropped, never
retried in a way that could apply backpressure to the redirect response (FR-011).

**Deletion (by `ui/`, not this service)**: `ui/` owns a foreign key from `code` to its `links`
table with `ON DELETE CASCADE` (`ui/`'s data-model.md) — when a link is deleted, its click
events are removed along with it. This service never performs or triggers that deletion; it's
purely a consequence of `ui/`'s schema.

## State transitions

Neither entity has state transitions *performed by this service* — both are read-only or
write-only from `redirect/`'s perspective:

- **Short Link**: transitions (created → active → deactivated/expired → deleted) are all
  performed by `ui/`. `redirect/` only observes the current state at lookup time.
- **Click Event**: append-only; created once, never modified or removed by this service.
