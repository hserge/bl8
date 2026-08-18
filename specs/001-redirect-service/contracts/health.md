# Contract: `GET /health`

## Request

- Method: `GET`
- Path: `/health`
- No request body, headers, query parameters, or authentication required (spec FR-014).

## Behavior

On every call, the service performs a live reachability check against both Redis and Postgres
(spec SC-005: "reflects real-time reachability rather than a cached or stale status" — the
result is never memoized/cached from a prior check). "Reachable" means the service can
successfully establish a connection to and get a response from the dependency (spec.md
Assumptions) — not that every operation against it is guaranteed to succeed.

## Response

- Status: `200 OK` if both Redis and Postgres are reachable; `503 Service Unavailable` if
  either is not.
- Body (`application/json`):

```json
{
  "status": "ok",
  "redis": "ok",
  "postgres": "ok"
}
```

or, when a dependency is unreachable (spec FR-015 — the report distinguishes which dependency
is down):

```json
{
  "status": "unavailable",
  "redis": "unreachable",
  "postgres": "ok"
}
```

| Field | Values | Notes |
|---|---|---|
| `status` | `"ok"` \| `"unavailable"` | Overall summary; `"unavailable"` if either dependency check fails. |
| `redis` | `"ok"` \| `"unreachable"` | Independent of `postgres`'s value (spec FR-015). |
| `postgres` | `"ok"` \| `"unreachable"` | Independent of `redis`'s value (spec FR-015). |

## Explicitly out of scope

- No authentication (spec FR-014).
- No detail beyond reachability (e.g. no latency figures, no replication lag, no version
  info) — this is a minimal liveness/dependency check, not a diagnostics endpoint.
