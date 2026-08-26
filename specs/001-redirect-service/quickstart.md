# Quickstart: Redirect Service

Validates the feature end-to-end against real Redis and Postgres. See contracts/ for exact
request/response shapes and data-model.md for the Short Link / Click Event fields referenced
below.

## Prerequisites

- Go 1.23+
- Docker (for local Redis + Postgres, and for building/running the service's own image)
- A Postgres instance reachable from the service, with a links table and a click_events table
  already present (schema owned by `ui/` — see research.md's "schema ownership" note; for a
  standalone quickstart, apply whatever migration `ui/` provides, or hand-create matching
  columns per data-model.md)

## Setup

1. Start Redis and Postgres (e.g. via a local `docker compose up redis postgres`, or existing
   dev instances).
2. Seed rows in the links table directly in Postgres:
   - `code = "hello"`, `destination_url = "https://example.com"`, `is_active = true`,
     `expires_at = null`, `slug = null`
   - `code = "gone"`, same destination, `is_active = false` (deactivated)
   - `code = "old"`, same destination, `is_active = true`, `expires_at` in the past (expired)
   - `code = "seo"`, same destination, `is_active = true`, `slug = "my-article-title"`
3. Set the service's Redis/Postgres connection configuration and rate-limit thresholds (env
   vars, per `cmd/redirect`) and run it: `go run ./cmd/redirect`.

## Validate: cache-miss then cache-hit (User Story 1)

```bash
curl -i http://localhost:PORT/hello   # expect 302, Location: https://example.com
curl -i http://localhost:PORT/hello   # expect 302 again, now served from Redis
```

Expected: both requests return `302` with the same `Location`. After the first request, the
mapping for `hello` exists in Redis (inspect with `redis-cli GET`/`HGETALL` per the chosen key
shape) — confirming the cache was repopulated on miss (spec FR-004).

## Validate: cache down, Postgres still serves (User Story 1, edge case)

```bash
# stop/block Redis
curl -i http://localhost:PORT/hello   # expect 302 still, via Postgres fallback
```

Expected: redirect still succeeds with Redis unreachable (spec SC-006).

## Validate: not-found, expired, and deactivated (User Story 2)

```bash
curl -i http://localhost:PORT/does-not-exist   # expect 404
curl -i http://localhost:PORT/old              # expect 404 (expired)
curl -i http://localhost:PORT/gone             # expect 410 (deactivated)
```

Expected: exact status codes above, no `Location` header, no click event recorded for any of
these three (verify no new row is written to click_events for these codes).

## Validate: slug match and mismatch

```bash
curl -i http://localhost:PORT/seo/my-article-title   # expect 302, same destination as bare /seo
curl -i http://localhost:PORT/seo/wrong-slug          # expect 404
curl -i http://localhost:PORT/hello/anything          # expect 404 (code "hello" has no registered slug)
```

Expected: a matching slug behaves identically to the bare code; any mismatch — including any
slug at all on a code with none registered — is a flat 404, never a redirect and never a 410
(even for the deactivated `gone` code, a slug mismatch there should still be 404, not 410).

## Validate: click recording never blocks the redirect (User Story 1)

```bash
time curl -i http://localhost:PORT/hello
```

Expected: response time is unaffected by Postgres write latency for the click event (compare
against a run with Postgres briefly paused/blocked after the initial lookup path is warmed —
the redirect should still return promptly). Then confirm a corresponding row appears in
click_events shortly after (asynchronously).

## Validate: health check (User Story 3)

```bash
curl -i http://localhost:PORT/health   # expect 200, {"status":"ok","redis":"ok","postgres":"ok"}
# stop Redis
curl -i http://localhost:PORT/health   # expect 503, redis:"unreachable", postgres:"ok"
```

## Validate: rate limiting

```bash
for i in $(seq 1 <limit+10>); do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:PORT/hello; done
```

Expected: once the configured global limit is exceeded, subsequent responses in the burst
return `429` instead of `302`.

## Validate: QR code (User Story 4, moved from `ui/` 2026-08-24)

```bash
curl -i http://localhost:PORT/hello/qr -o hello-qr.png   # expect 200, Content-Type: image/png
# decode hello-qr.png with any QR reader — expect it resolves to {PUBLIC_BASE_URL}/hello

curl -i http://localhost:PORT/does-not-exist/qr          # expect 404
# deactivate/expire a seeded code, then:
curl -i http://localhost:PORT/<deactivated-code>/qr      # expect 410
curl -i http://localhost:PORT/<expired-code>/qr           # expect 404

# no ownership/auth check — any requester, no session/credentials needed, succeeds identically
curl -i http://localhost:PORT/hello/qr                     # still 200, same as above
```

## Validate: QR dots/corners/bg parameters (constitution v8.0.0, supersedes v7.0.0's `style`)

```bash
curl -i "http://localhost:PORT/hello/qr" -o hello-default.png                              # square dots, square corners, white bg
curl -i "http://localhost:PORT/hello/qr?dots=round&corners=round" -o hello-round.png        # circular dots, concentric-ring corner markers
curl -i "http://localhost:PORT/hello/qr?corners=half" -o hello-half.png                     # corner markers: 2 opposite corners rounded, 2 sharp
curl -i "http://localhost:PORT/hello/qr?bg=e4ff33" -o hello-voltage.png                     # Voltage background — ink auto-picked (should be navy, high contrast)
curl -i "http://localhost:PORT/hello/qr?bg=1a2b3b" -o hello-navy.png                        # Inkwell Navy background — ink auto-picked (should be light/Fog)
curl -i "http://localhost:PORT/hello/qr?dots=nonsense&corners=nonsense&bg=nonsense"          # expect 200, identical to the default — every param silently falls back, never a 400
curl -sD - "http://localhost:PORT/hello/qr" -o /dev/null | grep -i access-control            # expect Access-Control-Allow-Origin: *
```

Expected for each PNG: `200`, `Content-Type: image/png`, a valid image that decodes (visually
or via any QR reader) to `{PUBLIC_BASE_URL}/hello`. Open `hello-round.png` and `hello-half.png`
and confirm the three finder-pattern corner markers each read as one clean shape (concentric
circles, or a squircle with 2 rounded/2 sharp corners) — not a ring of individually-visible
dots. Confirm `hello-voltage.png`'s modules are dark (navy) and `hello-navy.png`'s modules are
light (Fog) — the auto-contrast picking the correct ink for each background.

## Automated tests

- Contract tests: `go test ./redirect/tests/contract/...` — handler-level, fast, no real
  dependencies.
- Integration tests: `go test ./redirect/tests/integration/...` — spins up real Redis and
  Postgres via `testcontainers-go` and exercises the scenarios above.
