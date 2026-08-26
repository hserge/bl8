# Implementation Plan: Redirect Service

**Branch**: `001-redirect-service` | **Date**: 2026-08-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-redirect-service/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

A stateless Go microservice with exactly three logical endpoints — the redirect lookup
(`GET /{code}`, and optionally `GET /{code}/{slug}` for a registered slug), a QR-code
image for the same code (`GET /{code}/qr`), and `GET /health`. Redirects use a cache-aside
pattern: Redis first, Postgres on miss (repopulating Redis on the way out); Postgres remains
the fallback of record so Redis can run `allkeys-lru` eviction with no correctness risk. Click
events are recorded to Postgres via a non-blocking, in-process async writer so they add no
latency to the redirect response. A single, environment-configurable global rate limiter and
status logic (404 not-found/expired/slug-mismatch, 410 deactivated) are applied inline in the
handlers — no auth or request-validation middleware, since the service is intentionally
unauthenticated, public, and has no write endpoints; the two narrow exceptions are the slug
equality check and the QR endpoint, both carved out explicitly in constitution Principle II.
Ships as a single static binary in a minimal Docker image, safe to run as many identical,
horizontally scaled instances with no shared state beyond Redis/Postgres.

**Amendment (2026-08-24, v6)**: Constitution v6.0.0 adds the QR endpoint, moved here from
`ui/` at the user's explicit request. It reuses the exact same cache-aside lookup and
active/expiry status logic as the redirect handler (extracted into a shared `lookupLink`
function in `internal/handler/`, since this is now a genuine second use) — no new business
logic, no auth. See research.md's "QR code generation" decision for the library choice and the
literal-vs-wildcard mux precedence this route depends on.

## Technical Context

**Language/Version**: Go 1.23+ (uses the stdlib `net/http` enhanced router from Go 1.22+:
method+pattern registration such as `"GET /{code}"` and `r.PathValue("code")`)

**Primary Dependencies**: stdlib `net/http` (no router framework); `github.com/redis/go-redis/v9`
(Redis client); `github.com/jackc/pgx/v5` with `pgxpool` (Postgres client); `golang.org/x/time/rate`
(in-process token-bucket rate limiter)

**Storage**: Redis (cache only, `allkeys-lru` eviction) fronting Postgres (durable source of
truth for link lookups and click events; the only two things this service ever reads or writes
in Postgres)

**Testing**: Go `testing` + `net/http/httptest` for handler-level contract tests;
`testcontainers-go` spinning up real Redis + Postgres for integration tests of the cache-aside
fallback path and the health check (per constitution Test-First — real dependencies, not mocks,
since the service's entire value is the interaction between two external systems)

**Target Platform**: Linux container (Docker), deployed as a single static binary
(`CGO_ENABLED=0`), horizontally scaled behind a load balancer, served on the bare `bl8.us`
domain (constitution: domain separation from `ui/`, which is on `admin.bl8.us`)

**Project Type**: Single backend microservice (Go); no frontend, no CLI beyond the server
binary itself

**Performance Goals**: Sub-10ms p95 added latency for cache-hit redirects; low double-digit ms
p95 for cache-miss redirects (bounded by one Postgres round trip); click recording adds
effectively zero latency to the redirect response (fire-and-forget)

**Constraints**: Fully stateless process — no state shared across instances except via
Redis/Postgres; click event writes MUST NOT block or delay the redirect response; the rate
limiter is a single global threshold enforced in-process per instance (not coordinated across
instances via Redis, per explicit scope decision — see Constitution Check), read from
environment variables at startup rather than hardcoded (constitution: no hardcoded tunable
parameters)

**Scale/Scope**: Exactly 3 logical endpoints (`GET /{code}` with an optional trailing
`/{slug}` segment, `GET /{code}/qr`, and `GET /health`); no other endpoints, ever

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Independent, Non-Overlapping Components | PASS | This plan touches only `redirect/`; no dependency on `ui/` source, no shared code. |
| II. Redirect Is a Minimal Read-Path Service | PASS | Exactly `GET /{code}` (optionally with a trailing `/{slug}` segment), `GET /{code}/qr`, and `GET /health`; no create/update/delete/list; no auth; no validation beyond the code lookup itself plus the two constitution-carved-out exceptions — the slug-equality check (FR-020/FR-021) and the QR endpoint reusing the same lookup/status rules with no new business logic (FR-022). |
| III. Cache-Aside Reads, Postgres as Source of Truth | PASS | Redis-first, Postgres-fallback-and-repopulate as designed; Redis is disposable (`allkeys-lru`), Postgres remains authoritative; redirects keep working if Redis is down. |
| IV. Non-Blocking Click Recording | PASS | Click events go through an in-process async writer (buffered channel + background goroutine); failures never surface to the client; see research.md for the accepted at-most-effort tradeoff. |
| V. UI Owns Writes and Business Logic | PASS | `redirect/` remains read-only; it only applies the configurable global rate limit, the slug-equality check, and the 404/410 status rules that fall directly out of serving a lookup, not business validation. Slug format/uniqueness rules live entirely in `ui/`. |
| VI. Simplicity Over Abstraction | PASS | stdlib `net/http` chosen over chi (no framework needed for 2 routes); direct `pgx`/`go-redis` clients, no repository/service-layer indirection; rate limiter applied inline, not as a middleware chain. |
| VII. Test-First Delivery | PASS (commitment) | Contract tests (httptest) and integration tests (testcontainers-go, real Redis+Postgres) are scoped in Project Structure below and required before any task is marked complete in `/speckit-tasks` → `/speckit-implement`. |

**Resolved scope decision**: The feature description for this plan said "no middleware for auth
or rate limiting." Clarified with the user: the global rate limiter required by the spec
(FR-012/FR-013) and constitution stays — it's implemented as an inline check in the handler
using `golang.org/x/time/rate`, not as a chained middleware layer. "No middleware" describes
code structure (and the genuine absence of auth), not the absence of rate limiting.

**Resolved (2026-08-17), constitution v2.0.0**: The rate limiter's threshold, previously
described as hardcoded, is now read from environment variables at startup (constitution: no
hardcoded tunable parameters) — still a single in-process `*rate.Limiter`, just configured
rather than compiled in.

**Resolved (2026-08-17), constitution v3.0.0**: Added support for an optional SEO-slug path
segment (`GET /{code}/{slug}`), carved out in the constitution as a narrow exception to "no
validation beyond code lookup" — an exact-equality check against a field already fetched as
part of the same lookup, not general validation.

**Resolved (2026-08-24), constitution v6.0.0**: Added `GET /{code}/qr`, moved here from `ui/`
at the user's explicit request. A literal `qr` path segment takes precedence over the sibling
`/{code}/{slug}` wildcard under Go 1.22+ `net/http.ServeMux`'s specificity rules (verified in
`tests/contract/mux_test.go`); this can never collide with a real slug since the slug format
rule requires at least 3 characters, making the 2-character `"qr"` an impossible slug value
independent of the route. The endpoint shares the redirect handler's `lookupLink` function
(extracted from `internal/handler/redirect.go` once a second concrete caller existed) and its
active/expiry status precedence, applying no ownership or auth check per FR-022.

No violations. Complexity Tracking table is empty and omitted below.

**Post-Phase 1 re-check**: data-model.md, contracts/, and quickstart.md introduce no new
dependencies, no write endpoints, no auth, and no validation beyond code lookup. The Click
Event's `referrer` field (added to satisfy `ui/`'s analytics spec) is captured from a header
already present on every request, not from new input validation. All seven principles above
still PASS unchanged after design.

## Project Structure

### Documentation (this feature)

```text
specs/001-redirect-service/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
redirect/
├── cmd/
│   └── redirect/
│       └── main.go          # wires config, Redis/Postgres clients, rate limiter, click
│                             # writer, and the http.ServeMux; starts the server
├── internal/
│   ├── handler/              # GET /{code}[/{slug}], GET /{code}/qr, and GET /health HTTP
│   │                          # handlers — redirect.go and qr.go share lookupLink() (added
│   │                          # constitution v6.0.0)
│   ├── linkcache/             # Redis cache-aside: Get(code), Set(code, link) — link includes slug
│   ├── linkstore/              # Postgres fallback lookup: GetByCode(code)
│   ├── clickwriter/            # non-blocking async click recorder (channel + goroutine)
│   ├── ratelimit/               # in-process global token-bucket wrapper
│   └── health/                   # Redis/Postgres reachability checks
├── go.mod
├── go.sum
├── Dockerfile                     # multi-stage, static binary, minimal runtime base
└── tests/
    ├── contract/                   # httptest-based handler tests
    └── integration/                 # testcontainers-go tests against real Redis+Postgres
```

**Structure Decision**: Single Go module rooted at `redirect/` (repository already separates
`redirect/` and `ui/` as independent, non-overlapping components per constitution Principle I).
Internal packages are split by responsibility (cache, store, click recording, rate limiting,
health) rather than by technical layer, matching the small, fixed scope of this service —
there is no `models`/`services`/`cli` split because there's no domain model beyond a link
lookup and a click event, and no business logic to separate from transport (constitution
Principle VI).

## Complexity Tracking

*No constitution violations — this section intentionally left empty.*
