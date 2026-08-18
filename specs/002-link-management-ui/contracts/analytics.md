# Contract: Click Analytics Report

## `GET /links/{code}/analytics`

Read-only report for a link the caller owns (User Story 3).

| Outcome | When | Response |
|---|---|---|
| Report shown | Caller owns `code` | `200 OK` — click counts over time (bucketed) and a referrer breakdown (FR-011), derived from `redirect/`'s `click_events` rows for this `code` (data-model.md). A link with zero recorded clicks returns an empty/zero report, not an error (spec.md Acceptance Scenario 3.2). |
| Rejected — not owner | `code` exists but `owner_id` ≠ caller | `403 Forbidden`; no data returned (FR-010, spec.md Acceptance Scenario 3.3). Body shape per contracts/links.md's Response Body Conventions. |
| Rejected — not found | `code` doesn't exist (e.g. already deleted) | `404 Not Found`. Body shape per contracts/links.md's Response Body Conventions. |

## Explicitly out of scope

- No cross-link aggregate/account-wide analytics view (only per-link, per FR-011).
- No export (CSV/API) beyond the report itself.
- No real-time/streaming updates — a page load reflects `click_events` as of that request.
