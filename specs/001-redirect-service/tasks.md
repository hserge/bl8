---

description: "Task list template for feature implementation"
---

# Tasks: Redirect Service

**Input**: Design documents from `/specs/001-redirect-service/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. The constitution's Test-First Delivery principle requires every feature to
ship with tests before being marked complete, so contract tests (`net/http/httptest`, fakes at
the handler boundary) and integration tests (`testcontainers-go`, real Redis + Postgres) are
part of every user-story phase.

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P3) so each can be
implemented, tested, and demoed independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US3)
- File paths are relative to `redirect/` unless otherwise noted

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization per plan.md's Project Structure

- [X] T001 Initialize the Go module at `redirect/` (`go.mod`, Go 1.23+), per plan.md Technical Context
- [X] T002 Add dependencies to `redirect/go.mod`: `github.com/redis/go-redis/v9`, `github.com/jackc/pgx/v5` (+ `pgxpool`), `golang.org/x/time/rate`; dev/test deps `github.com/testcontainers/testcontainers-go` + its `postgres` and `redis` modules
- [X] T003 [P] Configure `gofmt`/`go vet` (and optionally `golangci-lint`) via `redirect/.golangci.yml` or a `Makefile`/`justfile` target
- [X] T004 [P] Write `redirect/Dockerfile`: multi-stage build (`CGO_ENABLED=0 GOOS=linux go build` in a `golang` build stage, static binary copied onto a `distroless/static` or `scratch` final stage), per research.md
- [X] T005 [P] Write `redirect/docker-compose.yml` wiring this service to local Redis + Postgres containers for standalone development/quickstart validation (per quickstart.md's Prerequisites — schema is `ui/`'s, so this compose file is for local Redis/Postgres only, not a shared stack with `ui/`)

**Checkpoint**: `go build ./...` succeeds on an empty module; `docker compose up` brings up Redis + Postgres.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T006 Implement environment-variable config loading in `redirect/internal/config/config.go`: `PORT`, `REDIS_ADDR`, `DATABASE_URL`, `RATE_LIMIT_RPS`, `RATE_LIMIT_BURST` — no hardcoded tunables (constitution; research.md's rate-limiting decision)
- [X] T007 [P] Implement the Redis cache-aside client in `redirect/internal/linkcache/linkcache.go`: `Get(ctx, code) (*Link, error)` and `Set(ctx, code, link)`, using the exact JSON shape from data-model.md's Cache representation (`destination_url`, `is_active`, `expires_at` ISO 8601 or `null`, `slug` or `null`) via Redis `GET`/`SET` on key `link:{code}` — no hash, per research.md
- [X] T008 [P] Implement the Postgres fallback lookup in `redirect/internal/linkstore/linkstore.go`: `GetByCode(ctx, code) (*Link, error)` using `pgxpool`, reading the existing `links` table `ui/` owns (no migrations, no schema definition here — research.md's confirmed schema-ownership note)
- [X] T009 [P] Implement the in-process global rate limiter wrapper in `redirect/internal/ratelimit/ratelimit.go`: one `*rate.Limiter` built from `RATE_LIMIT_RPS`/`RATE_LIMIT_BURST` (T006), with an `Allow() bool` method
- [X] T010 [P] Implement the dependency-reachability checks in `redirect/internal/health/health.go`: `CheckRedis(ctx) error` (`PING`) and `CheckPostgres(ctx) error` (`pgxpool.Ping`), each a live check, never memoized (contracts/health.md, SC-005)
- [X] T011 Wire config (T006), Redis/Postgres clients, the rate limiter (T009), and an `http.ServeMux` together in `redirect/cmd/redirect/main.go`, starting the HTTP server (depends on T006–T010)

**Checkpoint**: Foundation ready — config loads, cache/store/rate-limit/health modules exist and are wired into a runnable (still routeless) server.

---

## Phase 3: User Story 1 - Follow a short link to its destination (Priority: P1) 🎯 MVP

**Goal**: A visitor requesting an existing, active, unexpired short code (with or without a
matching slug segment) is redirected to its destination URL, with a click event recorded
asynchronously and with no perceptible added latency.

**Independent Test**: Request a known, active, unexpired short code (cached and not-yet-cached)
and confirm a `302` redirect to the correct destination, that Redis is repopulated on a cache
miss, that Postgres alone still serves redirects with Redis down, and that a click event is
recorded without delaying the response.

### Tests for User Story 1

- [X] T012 [P] [US1] Contract test for `GET /{code}` and `GET /{code}/{slug}` (cache-hit redirect, slug match, `503` when both dependencies are simulated unreachable) using `httptest` + fakes at the handler boundary, in `redirect/tests/contract/redirect_test.go`
- [X] T013 [P] [US1] Integration test for the cache-aside path: cache-miss → Postgres fallback → redirect → Redis repopulated; a second request served from cache; redirects continuing to succeed with Redis stopped and Postgres reachable (SC-006), via `testcontainers-go` real Redis + Postgres, in `redirect/tests/integration/redirect_cacheaside_test.go`
- [X] T014 [P] [US1] Integration test asserting click recording is non-blocking: response timing is unaffected by a deliberately slow/paused Postgres after the lookup completes, and a corresponding `click_events` row appears shortly after (asynchronously) (spec FR-010, FR-011, SC-003), in `redirect/tests/integration/clickwriter_test.go`

### Implementation for User Story 1

- [X] T015 [US1] Implement the non-blocking async click writer in `redirect/internal/clickwriter/clickwriter.go`: a bounded buffered channel fed by the handler, drained by a background goroutine that inserts into `click_events` (`code`, `occurred_at` set at write time, `referrer`); full channel drops rather than blocks (research.md's accepted tradeoff; FR-009–FR-011)
- [X] T016 [US1] Implement the `GET /{code}` / `GET /{code}/{slug}` handler in `redirect/internal/handler/redirect.go`, applying data-model.md's Derived redirect decision in order: cache-aside lookup (T007 then T008 on miss, repopulating via T007's `Set`) → not-found if no row → slug-mismatch → 404 (FR-020/FR-021, checked before active/expiry so a wrong slug never reveals link state) → deactivated → 410 (precedence over expiry) → expired → 404 → else `302` with `Location: destination_url` and enqueue a click event (T015) after/independent of sending the response
- [X] T017 [US1] Register `GET /{code}` and `GET /{code}/{slug}` on the mux in `redirect/cmd/redirect/main.go`, applying the rate limiter (T009) inline at the top of the handler (429 on exceeded, before any lookup) and wiring the click writer (T015) and cache/store clients into the handler (T016)

**Checkpoint**: User Story 1 is fully functional and independently testable/demoable.

---

## Phase 4: User Story 2 - Get a clear result for links that can't be followed (Priority: P2)

**Goal**: Requests for codes that never existed, have expired, or have been deactivated (or
carry a mismatched/unregistered slug) receive the correct distinct outcome — `404` or
`410` — with no redirect and no click event recorded.

**Independent Test**: Request a nonexistent code, an expired code, a deactivated code, a code
that's both expired and deactivated, and a valid code with a mismatched or unregistered slug;
confirm each produces its expected status with no `Location` header and no new `click_events`
row.

**Note**: T016 already implements the full derived-redirect-decision logic (including these
negative-outcome branches), since splitting it from the primary handler would be artificial —
they're the same code path. This phase adds the dedicated test coverage the constitution's
Test-First principle requires for those branches; no new production code beyond a follow-up fix
if a test here reveals a gap in T016.

### Tests for User Story 2

- [X] T018 [P] [US2] Contract test for `GET /{code}`: nonexistent code → `404`, expired code → `404`, deactivated code → `410`, both expired and deactivated → `410` (deactivation precedence, FR-008) — using fakes, in `redirect/tests/contract/redirect_notfound_test.go`
- [X] T019 [P] [US2] Integration test for the same four scenarios against real Postgres (seeded rows per quickstart.md's Setup), additionally asserting no `click_events` row is inserted for any of them, in `redirect/tests/integration/redirect_notfound_test.go`
- [X] T020 [P] [US2] Integration test for the slug mismatch/unregistered-slug paths (FR-021): a matching slug behaves identically to the bare code; a mismatched slug, a slug on a code with none registered, and a slug segment on a *deactivated* code (must still be `404`, never `410` — data-model.md) all return `404`, in `redirect/tests/integration/redirect_slug_test.go`

**Checkpoint**: User Stories 1 and 2 both verified; redirect outcomes are fully correct across every code/slug/state combination.

---

## Phase 5: User Story 3 - Confirm the service's dependencies are reachable (Priority: P3)

**Goal**: `GET /health` reports live, per-dependency reachability for Redis and Postgres, so an
operator or monitoring system can distinguish which dependency (if either) is down.

**Independent Test**: Call `/health` with both dependencies reachable (expect `200`,
`status: "ok"`), then again with one deliberately stopped (expect `503`, that dependency
reported `"unreachable"`, the other still `"ok"`).

### Tests for User Story 3

- [X] T021 [P] [US3] Contract test for `GET /health` (both reachable → `200`; one/both simulated unreachable → `503` with the correct per-dependency fields) using fakes, in `redirect/tests/contract/health_test.go`
- [X] T022 [P] [US3] Integration test for `GET /health` against real Redis + Postgres (both up → `200`), then with Redis stopped (→ `503`, `redis: "unreachable"`, `postgres: "ok"`) confirming SC-005's live (not cached) reachability, in `redirect/tests/integration/health_test.go`

### Implementation for User Story 3

- [X] T023 [US3] Implement the `GET /health` handler in `redirect/internal/handler/health.go`, calling T010's `CheckRedis`/`CheckPostgres` on every request and returning the exact JSON shape from contracts/health.md (`status`, `redis`, `postgres`)
- [X] T024 [US3] Register `GET /health` on the mux in `redirect/cmd/redirect/main.go` — no rate limiting applied to this route (research.md: the limiter is checked only in the redirect handler)

**Checkpoint**: All three user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Operational readiness and final validation across all stories

- [X] T025 [P] Write `redirect/README.md` covering local setup (`docker compose up`, seeding rows per quickstart.md, `go run ./cmd/redirect`) and how to run each test suite
- [X] T026 Run through quickstart.md's manual validation steps end-to-end against a Dockerized dev environment
- [X] T027 [P] Integration test for the click writer's bounded-channel backpressure: a full channel or slow Postgres causes dropped events, never a blocked/slowed redirect response (research.md's accepted tradeoff), in `redirect/tests/integration/clickwriter_backpressure_test.go`
- [X] T028 [P] Integration test for rate limiting: using a low `RATE_LIMIT_RPS`/`RATE_LIMIT_BURST` via env vars, confirm requests beyond the threshold receive `429` (FR-012, FR-013, SC-007), in `redirect/tests/integration/ratelimit_test.go`
- [X] T029 [P] Integration test for the both-dependencies-unreachable edge case: `GET /{code}` returns `503` rather than hanging or crashing, in `redirect/tests/integration/unavailable_test.go`
- [X] T030 [P] Verify `redirect/Dockerfile` builds a static binary and the resulting image runs correctly against real Redis/Postgres (`docker build` + `docker run`, curl a seeded code)

---

## Phase 7: User Story 4 - Get a scannable QR code for a short link (Priority: P4)

**Goal**: `GET /{code}/qr` returns a PNG QR code for any active, unexpired link — moved here
from `ui/` (constitution v6.0.0, user request "move qr code generation to redirector").

**Independent Test**: Request the QR route for an active code, confirm the returned image
decodes to that code's short URL; confirm the same 404/410 rules as the redirect route apply;
confirm no ownership/auth check exists.

- [X] T031 [P] [US4] Extract `lookupLink(ctx, cache, store, code)` as a package-level function
      in `redirect/internal/handler/redirect.go` (previously the `*Redirect.lookup` method),
      so both `Redirect` and the new `QR` handler share one cache-aside implementation
- [X] T032 [US4] Add `PublicBaseURL` to `redirect/internal/config/config.go`
      (env `PUBLIC_BASE_URL`, default `https://bl8.us`) — the scheme+host a QR code encodes
- [X] T033 [US4] Add `github.com/skip2/go-qrcode` to `redirect/go.mod`
- [X] T034 [US4] Implement `redirect/internal/handler/qr.go`: `QR` handler reusing
      `lookupLink` and the redirect handler's active/expiry precedence (410 deactivated before
      404 expired), rate-limited via the same shared limiter, encoding
      `{PublicBaseURL}/{code}` as a 512×512 PNG via `qrcode.Encode`, `Content-Type: image/png`,
      no slug check and no ownership/auth check (FR-022; contracts/qr.md)
- [X] T035 [US4] Register `GET /{code}/qr` on the mux in `redirect/cmd/redirect/main.go`,
      wiring the same cache/store/limiter instances as the redirect handler; document why the
      literal `qr` segment safely takes precedence over the sibling `/{code}/{slug}` wildcard
- [X] T036 [P] [US4] Contract tests for `GET /{code}/qr` (200+valid PNG, 404 not-found, 410
      deactivated, 404 expired, 429 rate-limited, 503 both-deps-unreachable) using fakes, in
      `redirect/tests/contract/qr_test.go`
- [X] T037 [P] [US4] Contract test confirming the literal `/{code}/qr` route wins over the
      `/{code}/{slug}` wildcard at the mux level, in `redirect/tests/contract/mux_test.go`

**Checkpoint**: All four user stories (including the moved QR one) are independently
functional; `go build ./...`, `go vet ./...`, and `go test ./tests/contract/...` pass.

---

## Phase 8: QR Style Presets (constitution v7.0.0)

**Purpose**: `GET /{code}/qr?style=` selects a small, fixed preset visual style, per the user's
request for "a fancier qr generator which can generate by preset style" — clarified via
AskUserQuestion to mean a picker across presets, requiring a constitution amendment to the
narrow-exception framing T034 originally relied on (v6.0.0 explicitly forbade QR
"customization... beyond the fixed PNG"; v7.0.0 reverses that specific line for a closed enum
only). See research.md's "QR style presets" entry for the library swap and preset definitions.

- [X] T038 Replace `github.com/skip2/go-qrcode` with `github.com/yeqown/go-qrcode/v2` +
      `github.com/yeqown/go-qrcode/writer/standard` in `redirect/go.mod` (the prior library has
      no per-module shape/color options)
- [X] T039 [US4] Implement the `qrStyle` enum (`classic`/`rounded`/`dark`), `parseQRStyle`
      (unrecognized/missing → `classic`, never an error), and `renderQRPNG` (per-style
      color/shape options, explicit `PNG_FORMAT` — the library defaults to JPEG — and
      per-module width computed to clear the 512px floor for whatever QR version the content
      needs) in `redirect/internal/handler/qr.go` (FR-022; contracts/qr.md)
- [X] T040 [US4] Wire `?style=` parsing into `QR.ServeHTTP`, applied after the same
      lookup/active/expiry checks T034 already made (style never affects whether a code is
      renderable, only how)
- [X] T041 [P] [US4] Contract tests for all three presets (200 + valid PNG) and for an
      unrecognized style value falling back to 200 rather than erroring, in
      `redirect/tests/contract/qr_test.go`

**Checkpoint**: `go build ./...`, `go vet ./...`, `go mod tidy` (confirms the old QR library is
fully dropped, not just unused), and `go test ./tests/contract/...` all pass.

---

## Phase 9: QR dots/corners/bg Parameters (constitution v8.0.0, supersedes Phase 8's `style` enum)

**Purpose**: Replace the single `style` preset with three independent parameters, per the
user's request for finer-grained control, plus fix the finder-pattern rendering (per-module
dots → one unified shape per marker) along the way. See research.md's "QR dots/corners/bg
parameters" entry.

- [X] T042 [US4] Implement `internal/handler/qrshape.go`: `qrDotShape`/`qrCornerShape` enums +
      parsers (unrecognized → default, never an error); `customShape` implementing
      `standard.IShape`, detecting each finder pattern's fixed origin module and drawing it as
      one layered shape (outer/gap/inner) instead of per-module dots; `drawSquircleTwoCorners`
      for the `half` corner style using `gg.QuadraticTo`
- [X] T043 [US4] Implement `parseBgColor` (format-validated hex, 3- or 6-digit, with/without
      `#`, invalid → white) and `contrastingForeground` (luminance-based Navy/Fog choice) in
      `internal/handler/qr.go`; wire `dots`/`corners`/`bg` query parsing into `QR.ServeHTTP`
      and `standard.WithCustomShape(shape)` into `renderQRPNG`
- [X] T044 Add `Access-Control-Allow-Origin: *` to the QR response, required for `ui/`'s
      cross-origin download button
- [X] T045 [P] [US4] Contract tests: all `dots`×`corners` combinations render valid PNGs;
      unrecognized shape values fall back without erroring; a custom `bg` measurably changes
      the rendered bytes (including a one-hex-digit-different control case); invalid `bg` falls
      back to white without erroring — in `redirect/tests/contract/qr_test.go`

**Checkpoint**: `go build ./...`, `go vet ./...`, and `go test ./tests/contract/...` all pass;
manually generated and visually inspected every shape combination plus two custom-background
cases before considering this done (not just PNG-validity-checked).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational only
- **User Story 2 (Phase 4)**: Depends on Foundational and User Story 1 (T016's handler already
  implements the paths this phase tests) — not independently *implementable* before US1, but
  independently *testable/demoable* once both are done
- **User Story 3 (Phase 5)**: Depends on Foundational only; independent of US1/US2 code (health
  checks share no code with the redirect handler) — could be implemented in parallel with US1/US2
- **Polish (Phase 6)**: Depends on all desired user stories being complete

### Within Each User Story

- Tests are written first and must fail before implementation (constitution Test-First Delivery)
- Shared modules (linkcache, linkstore, ratelimit, clickwriter) before the handler that calls them
- Handler implementation before mux registration

### Parallel Opportunities

- All Setup tasks marked [P] (T003–T005) in parallel
- T007, T008, T009, T010 in Foundational in parallel (different files); T006 first (the others
  read config); T011 depends on T006–T010
- Within US1: T012–T014 (tests) in parallel; T015 (clickwriter) and the start of T016 can
  proceed in parallel, but T016's full implementation depends on T007/T008 (Foundational) and
  benefits from T015 existing first; T017 depends on T015 and T016
- Within US2: T018–T020 (tests) all in parallel (different files, no new production code)
- Within US3: T021/T022 (tests) in parallel; T023 depends on T010; T024 depends on T023
- Once Foundational (Phase 2) is done, US3 can proceed fully in parallel with US1/US2 if
  staffed, since it shares no code with the redirect handler

---

## Parallel Example: User Story 1

```bash
# Tests together:
Task: "Contract test for GET /{code} in redirect/tests/contract/redirect_test.go"
Task: "Integration test for cache-aside path in redirect/tests/integration/redirect_cacheaside_test.go"
Task: "Integration test for non-blocking click recording in redirect/tests/integration/clickwriter_test.go"

# Shared modules together (Foundational):
Task: "Implement linkcache in redirect/internal/linkcache/linkcache.go"
Task: "Implement linkstore in redirect/internal/linkstore/linkstore.go"
Task: "Implement ratelimit in redirect/internal/ratelimit/ratelimit.go"
Task: "Implement health checks in redirect/internal/health/health.go"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (blocks everything)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: run T012–T014 and confirm the independent test criteria above
5. Deploy/demo if ready — the core redirect path works, cache-aside and all

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. User Story 1 → validate → deploy/demo (MVP)
3. User Story 2 → validate → deploy/demo (correct not-found/gone/slug-mismatch behavior)
4. User Story 3 → validate → deploy/demo (health checks)
5. Polish (Phase 6)

### Parallel Team Strategy

After Foundational is done:
- Developer A: User Story 1, then User Story 2 (2 depends on 1's handler)
- Developer B: User Story 3 (independent)

---

## Notes

- [P] tasks touch different files with no unmet dependencies
- [Story] labels map every user-story-phase task back to spec.md for traceability
- Verify each test fails before implementing the task it covers
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently
- `redirect/` performs no Postgres migrations and defines no schema — `ui/` owns it entirely
  (research.md's confirmed schema-ownership note); do not add a migration tool or schema files
  to this module
