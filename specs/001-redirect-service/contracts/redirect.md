# Contract: `GET /{code}` and `GET /{code}/{slug}`

## Request

- Method: `GET`
- Path: `/{code}` or `/{code}/{slug}` — both `code` and `slug` are opaque path segments,
  taken as-is; no format/schema validation is performed on either (spec FR-018). `slug`, when
  present, is only ever compared for exact equality against the looked-up record's registered
  slug (FR-020) — never parsed, normalized, or validated for format.
- No request body, headers, query parameters, or authentication are required or inspected,
  except the standard `Referer` header, which is read (not required) to populate the click
  event's `referrer` field (data-model.md).

## Responses

| Status | When | Body | Notes |
|---|---|---|---|
| `302 Found` | Code resolves to an active, unexpired link, and (if an `slug` segment was given) it exactly matches the code's registered slug | Empty | `Location` header set to the link's `destination_url`. A temporary redirect (not `301`), per spec.md Assumptions, so every visit reaches this service and can be counted as a click rather than being served from the visitor's browser cache. |
| `404 Not Found` | Code doesn't exist in Redis or Postgres, exists but is expired, or an `slug` segment was given that doesn't match the code's registered slug (FR-021) | Empty or minimal plain-text body | Spec FR-005, FR-006, FR-021. No distinction is exposed between "never existed," "expired," or "slug mismatch" — all are not-found from the caller's perspective. |
| `410 Gone` | Code exists and is deactivated (regardless of expiration) — only reachable when no `slug` segment was given, or it matched | Empty or minimal plain-text body | Spec FR-007, FR-008. Deactivation takes precedence over expiration. A slug mismatch is checked first and always yields 404, never 410 (data-model.md), so this status never reveals a deactivated link's existence to a wrong-slug request. |
| `429 Too Many Requests` | The global rate limit has been exceeded | Empty or minimal plain-text body | Spec FR-012, FR-013. Applies uniformly across all requesters; not per-visitor or per-code. |
| `503 Service Unavailable` | Both Redis and Postgres are unreachable, so no lookup can be completed | Empty or minimal plain-text body | Edge case from spec.md: the service reports unavailability rather than hanging or crashing. |

## Side effects

- On `302`, a click event is enqueued for asynchronous recording (data-model.md). This never
  affects the response above — the response is sent before, or independent of, whether the
  click event write succeeds (spec FR-009, FR-010, FR-011).
- On every other status, no click event is recorded (spec FR-005–FR-008 edge cases: "no
  redirect occurred").
- On a cache miss that is resolved via Postgres, the mapping is written back to Redis before
  responding is not required — the write-back may happen inline or fire-and-forget, but it MUST
  NOT be allowed to delay the `302` response beyond the Postgres lookup itself already in
  flight (spec FR-004; the write-back is a repopulation step, not a gate on responding).

## Explicitly out of scope

- No authentication of any kind (spec FR-017).
- No validation of `code` or `slug` beyond using them as a lookup key and an equality check,
  respectively (spec FR-018, FR-020).
- No partial/fuzzy slug matching, normalization, or redirecting a wrong slug to the correct
  one — mismatch is always a flat 404 (spec FR-021).
- No other HTTP methods on this path; no other paths exist besides `/{code}/qr` (contracts/qr.md)
  and `/health` (spec FR-019).
