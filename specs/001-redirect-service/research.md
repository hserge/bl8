# Phase 0 Research: Redirect Service

All Technical Context items were resolvable from the feature description, the ratified
constitution, and one resolved scope clarification (rate limiting stays, implemented inline
rather than as middleware — see plan.md's Constitution Check). No `NEEDS CLARIFICATION`
markers remain. This document records the decisions and why alternatives were rejected.

## HTTP routing

**Decision**: stdlib `net/http`, using the Go 1.22+ enhanced `ServeMux` (method+pattern
registration, e.g. `mux.HandleFunc("GET /{code}", ...)`, `r.PathValue("code")`). The optional
alias variant (`GET /{code}/{alias}`) is registered as a second pattern routing to the same
handler, which reads `r.PathValue("alias")` (empty when absent) and performs the equality
check (FR-020/FR-021) after the normal cache-aside lookup.

**Rationale**: The service has exactly two logical endpoints. The enhanced stdlib mux already
supports method matching and path parameters, which is all either route needs — no path-based
regex or wildcard matching required for the two-pattern redirect route.

**Alternatives considered**: chi router — offers middleware chaining, route grouping, and
richer param handling, none of which this service needs; adding it would be an unjustified
dependency and layer per constitution Principle VI (Simplicity Over Abstraction).

## Redis client

**Decision**: `github.com/redis/go-redis/v9`.

**Rationale**: The current de facto standard Go Redis client — actively maintained, supports
context cancellation and connection pooling out of the box, both needed to keep the cache
lookup on the hot path fast and bounded.

**Alternatives considered**: `gomodule/redigo` — older, lower-level, more boilerplate per call;
`redis/rueidis` — newer and faster in benchmarks but less battle-tested and adds API surface
this service's simple GET/SET-style access pattern doesn't need.

## Postgres client

**Decision**: `github.com/jackc/pgx/v5` with `pgxpool` for connection pooling.

**Rationale**: pgx is faster and more idiomatic than `database/sql` + `lib/pq`, and its native
pooling fits both of this service's Postgres access patterns well: occasional fallback reads
on cache miss, and steady background inserts from the click writer.

**Alternatives considered**: `database/sql` + `lib/pq` — more "standard library" but slower,
and would need an extra pooling story; not worth it since this service only ever talks to one
database driver and has no need for `database/sql`'s driver-agnosticism.

## Non-blocking click recording

**Decision**: A bounded, buffered Go channel fed by the redirect handler, drained by one (or a
small fixed pool of) background goroutine(s) started at process startup, which batches or
writes click events to Postgres.

**Rationale**: Satisfies "never block or slow down the redirect response" (spec FR-010, FR-011;
constitution Principle IV) with nothing beyond the standard library's concurrency primitives —
no external queue/broker needed, consistent with Simplicity Over Abstraction and with "no
shared state between instances beyond Redis/Postgres" (an external queue would be exactly such
shared state, and isn't warranted for a single-writer, best-effort analytics signal).

**Alternatives considered**: Synchronous write on the request path — explicitly rejected by the
spec. External message queue (e.g. Kafka/SQS/NATS) — over-engineered for what is fundamentally
one `INSERT` per click; adds an operational dependency this service has no other reason to
need.

**Accepted tradeoff**: Click events sitting in the in-memory channel are lost if the process
crashes or is killed before they're flushed. This is acceptable because the spec (FR-011) and
constitution (Principle IV) both state click-recording durability is secondary to redirect
latency — it is a documented tradeoff, not a defect. The channel MUST be bounded so a stalled
Postgres connection degrades to dropping the oldest/newest click events rather than growing
memory unboundedly; it must never become a backpressure mechanism that slows redirects.

## Rate limiting

**Decision**: `golang.org/x/time/rate`, one `*rate.Limiter` instance created at process
startup with limit/burst read from environment variables (e.g. `RATE_LIMIT_RPS`,
`RATE_LIMIT_BURST`), checked inline at the top of the redirect handler (both `GET /{code}` and
`GET /{code}/{alias}`; skipped for `GET /health`).

**Resolved (2026-08-17), constitution v2.0.0**: Previously described as hardcoded constants;
now must be environment-configurable per the constitution's "no hardcoded tunable parameters"
rule. Still a single in-process limiter — only the source of the threshold values changed, not
the mechanism.

**Rationale**: "Global" (spec FR-012) plus the resolved scope decision that this is implemented
inline rather than as chained middleware. A single in-process limiter needs no coordination
infrastructure, matching "no shared state between instances beyond Redis/Postgres."

**Alternatives considered**: A Redis-backed distributed limiter — would give a true fleet-wide
limit instead of a per-instance one, but adds a dependency and latency to the hot path for a
requirement that's explicitly scoped to per-instance coordination, independent of whether its
threshold is hardcoded or configurable.

**Note carried to data-model/contracts**: because the limit is enforced per instance, not
fleet-wide, the effective total limit scales with instance count. This is accepted as inherent
to "no shared state" rather than treated as a defect.

## SEO alias equality check

**Decision**: After a successful cache-aside lookup (Redis or Postgres), if the request
included a second path segment, compare it via simple string equality against the looked-up
record's `alias` field (already in hand — no extra Redis/Postgres round trip). Mismatch (or a
`null` stored alias) short-circuits directly to 404, before the active/deactivated/expiry
checks (data-model.md's Derived redirect decision, step 2) — so a wrong alias never reveals
whether the underlying code exists, is active, or is deactivated.

**Rationale**: Directly implements FR-020/FR-021 and the constitution's narrowly-scoped
Principle II exception. Checking against the same record already fetched for the code lookup
means this adds no additional dependency call and negligible latency — it's a single string
comparison, not a second query.

**Alternatives considered**: A separate Postgres/Redis lookup keyed by alias — rejected;
`code` remains the sole lookup key (per `ui/`'s design), so an alias-keyed lookup would need
its own index/cache entry for no benefit, since the code is always present in the URL anyway.
Normalizing or fuzzy-matching the alias (e.g. case-insensitive, trimming) — rejected; FR-021
calls for exact equality only, keeping this a trivial, un-surprising comparison rather than a
second place alias "business rules" could accumulate (constitution Principle V: `redirect/`
stays ignorant of business logic).

## Redis eviction and key shape

**Decision**: `allkeys-lru` eviction (as specified by the user); one key per short code
(`link:{code}`), value a single JSON string carrying the minimal fields needed to serve a
redirect decision without a second lookup: `destination_url`, `is_active`, `expires_at` (ISO
8601 UTC or JSON `null`) — see data-model.md's Cache representation for the exact shape, which
is a shared contract with `ui/`. No service-managed TTL.

**Resolved (2026-08-17)**: Value serialization was pinned down as JSON (via `GET`/`SET`) rather
than a Redis hash, specifically to avoid the boolean/timestamp string-encoding mismatches a
hash would invite across the Go/TypeScript boundary between `redirect/` and `ui/` — JSON is
unambiguous, human-debuggable via `redis-cli`, and has no serialization surprises on either
side.

**Rationale**: Matches the explicit instruction ("Redis uses allkeys-lru eviction since
Postgres is always the fallback of record"). Because every cache miss safely and correctly
falls back to Postgres, LRU-evicted entries self-heal on next access — no TTL bookkeeping is
needed to bound staleness beyond what `ui/`'s write-through on update/delete already provides
(constitution Principle III).

**Alternatives considered**: TTL-based expiry in addition to LRU — redundant given LRU handles
memory bounding and `ui/` already write-throughs on change; adds a tunable with no clear payoff
for v1.

## Deployment

**Decision**: Multi-stage Dockerfile — build stage compiles a static binary
(`CGO_ENABLED=0 GOOS=linux go build`), final stage copies only that binary onto a minimal
runtime base (`distroless/static` or `scratch`).

**Rationale**: Matches "deploy as a single static binary in Docker"; minimizes image size and
attack surface for a public, unauthenticated service; keeps the container itself stateless.

**Alternatives considered**: Alpine-based runtime image — smaller than a full distro but still
heavier and less minimal than distroless/scratch, and unnecessary since the binary has no
dynamic dependencies (`CGO_ENABLED=0`).

## Testing strategy

**Decision**: Go `testing` + `net/http/httptest` for fast handler/contract-level tests (route
matching, status codes, headers) using fakes only at the handler boundary; `testcontainers-go`
to spin up real Redis and Postgres containers for integration tests that exercise the actual
cache-aside fallback path and the health check.

**Rationale**: Constitution Principle VII requires tests before a feature is done. This
service's entire reason for existing is the interaction between two real external systems
(cache hit, cache miss + fallback + repopulate, health reachability); mocking those clients
would validate the mock's behavior, not the service's actual correctness against Redis/Postgres
semantics (e.g. real `redis.Nil` on miss, real connection-refused errors for the health check).

**Alternatives considered**: Mocking the Redis/Postgres clients — faster and simpler to write,
but risks tests passing against an incorrect assumption about client behavior while the real
integration is broken; rejected for the integration-critical paths (cache-aside, health).
Mocks remain acceptable only where a test's purpose is purely handler-level routing/status-code
behavior that doesn't depend on real client semantics.

## Confirmed: schema ownership

The Postgres schema (links table, click_events table) is owned and operated by `ui/` — `ui/`
alone defines it and runs its migrations — consistent with constitution Principle V (`ui/` owns
all writes and business logic, including link creation which implies schema ownership).
`redirect/` never runs migrations and never defines schema; it only reads from and inserts into
tables `ui/` already created, acting on the data it finds there. Confirmed directly with the
user 2026-08-17 (previously phrased as "`ui/` or a shared migration mechanism" — that
ambiguity is resolved: it's `ui/`, unconditionally). This is carried into data-model.md, not
re-litigated here.

## QR code generation (2026-08-24, constitution v6.0.0)

**Decision**: `github.com/skip2/go-qrcode` — `qrcode.Encode(baseURL+"/"+code, qrcode.Medium,
512)` — in a new `internal/handler/qr.go`, registered as `GET /{code}/qr`. Shares the redirect
handler's cache-aside lookup, extracted into a package-level `lookupLink(ctx, cache, store,
code)` function (previously a `*Redirect` method) now that a second concrete caller exists
(Principle VI: extraction needs a real second use, not speculation — this is that use). Applies
the same active/expiry precedence as the redirect handler (410 deactivated before 404 expired)
but no alias check (the QR route has no `{alias}` segment) and no ownership/auth check. The
base URL it encodes comes from a new `PUBLIC_BASE_URL` config value (default `https://bl8.us`),
not a hardcoded string, per the constitution's "no hardcoded tunables" rule — `ui/`'s prior
implementation hardcoded `bl8.us` directly, which was fine for a single-environment npm script
but not for a service meant to run identically across local/staging/prod.

**Mux precedence**: Go 1.22+'s `net/http.ServeMux` prefers a more-specific (literal) pattern
over a less-specific (wildcard) one at the same position, regardless of registration order, so
`GET /{code}/qr` is never shadowed by the sibling `GET /{code}/{alias}` — verified in
`tests/contract/mux_test.go`'s `TestMux_RoutesCodeAndAlias`. No collision with a real alias is
possible either way: `ui/`'s alias format rule requires at least 3 characters, and `"qr"` is
only 2 — it was already an impossible alias value before this route existed, so no reserved-word
list was added on the `ui/` side (would have been dead code).

**Rationale**: Reusing the exact lookup/status logic means a QR image can only ever be served
for a link that would actually redirect right now — there's no separate "does this code exist"
decision to keep in sync with the redirect handler's. Dropping ownership/auth (a real behavior
change from `ui/`'s prior implementation) is not a new risk: this service performs no
authentication by rule (FR-017), and the URL a QR code encodes is exactly the same
already-public string `GET /{code}` itself resolves — an owner-only check on the encoding was
never protecting a secret, since the underlying redirect was already reachable by anyone with
the code.

**Alternatives considered**: A separate lookup implementation for QR (not sharing
`lookupLink`) — rejected, would duplicate the cache-aside logic and risk the two handlers
drifting on 404/410 semantics over time. Keeping QR generation in `ui/` and having `redirect/`
merely validate the code exists — rejected; the user's request was to move generation itself,
and splitting "does it exist" (redirect/) from "render the image" (ui/) would need a network
call between two components the constitution says must share nothing but Postgres/Redis
(Principle I).
