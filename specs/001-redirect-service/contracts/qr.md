# Contract: `GET /{code}/qr`

Added 2026-08-24, constitution v6.0.0 — moved here from `ui/`'s prior `GET /links/{code}/qr`
(see `specs/002-link-management-ui/contracts/qr.md` for that history).

## Request

- Method: `GET`
- Path: `/{code}/qr` — `code` is an opaque path segment, taken as-is; no format/schema
  validation is performed on it (same as the redirect route, FR-018). The literal `qr` segment
  takes precedence over the sibling `/{code}/{alias}` pattern (Go 1.22+ `net/http.ServeMux`
  specificity rules — see research.md).
- No request body, headers, query parameters, or authentication are required or inspected.

## Responses

| Status | When | Body | Notes |
|---|---|---|---|
| `200 OK` | Code resolves to an active, unexpired link | PNG image, at least 512×512px, `Content-Type: image/png`, encoding `{PUBLIC_BASE_URL}/{code}` | FR-022. Uses the exact same lookup and active/expiry precedence as `GET /{code}` (contracts/redirect.md) — not a separate decision. |
| `404 Not Found` | Code doesn't exist in Redis or Postgres, or exists but is expired | Empty or minimal plain-text body | Same precedence as the redirect route: deactivation checked first. |
| `410 Gone` | Code exists and is deactivated (regardless of expiration) | Empty or minimal plain-text body | Same precedence as the redirect route. |
| `429 Too Many Requests` | The global rate limit has been exceeded | Empty or minimal plain-text body | Shares the same rate limiter instance as the redirect route (FR-012/FR-013) — QR encoding is more CPU work per request, so it must not bypass the limit. |
| `503 Service Unavailable` | Both Redis and Postgres are unreachable | Empty or minimal plain-text body | Same as the redirect route. |

## Side effects

- None. Unlike `GET /{code}`, a request to this route never enqueues a click event — scanning
  or fetching a QR image is not a click on the underlying link.

## Explicitly out of scope

- No authentication or ownership check of any kind (FR-022) — the encoded URL is exactly the
  same already-public string `GET /{code}` itself resolves, so there is no additional secret to
  protect.
- No customization (colors, logo embedding, size options, alternate image formats) beyond a
  fixed, default, scannable PNG.
- No alias-qualified variant (`/{code}/{alias}/qr`) — the encoded URL is always the bare
  `{PUBLIC_BASE_URL}/{code}` form, regardless of whether the code has a registered alias.
