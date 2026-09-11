# Contract: `GET /{code}/qr`

Added 2026-08-24, constitution v6.0.0 — moved here from `ui/`'s prior `GET /links/{code}/qr`
(see `specs/002-link-management-ui/contracts/qr.md` for that history).

## Request

- Method: `GET`
- Path: `/{code}/qr` — `code` is an opaque path segment, taken as-is; no format/schema
  validation is performed on it (same as the redirect route, FR-018). The literal `qr` segment
  takes precedence over the sibling `/{code}/{slug}` pattern (Go 1.22+ `net/http.ServeMux`
  specificity rules — see research.md).
- Optional query parameters (constitution v9.0.0, superseding v8.0.0's "foreground is never a
  parameter"):
  - `dots`: `square` (default) or `round` — data-module shape.
  - `corners`: `square` (default), `round`, or `half` (2 of the marker's own 4 corners
    rounded, 2 sharp) — finder-pattern ("corner marker") shape, rendered as one unified layered
    shape per marker, not per-module.
  - `bg`: any 3- or 6-digit hex color, with or without a leading `#` (e.g. `e4ff33`,
    `#e4ff33`, `abc`) — background fill. Unlike `dots`/`corners`, this is not an enum: color is
    format-validated, not membership-checked.
  - `fg`: same format as `bg` — foreground/ink color. When omitted or malformed, it falls back
    to being derived from `bg`'s luminance (Inkwell Navy on light backgrounds, Fog on dark ones),
    exactly as it always did before this parameter existed — so a caller supplying only `bg`
    still can't end up with an unreadable code by omission. A caller who explicitly supplies
    both `bg` and `fg` is trusted to have picked a readable pair (constitution v9.0.0).
  - Any parameter's absence, or an unrecognized/malformed value, is treated identically to
    omitting it (falls back to the default); this is never a 400, since every one of these is
    cosmetic, not a validated input (FR-022).
- No request body or authentication are required or inspected.

## Responses

| Status | When | Body | Notes |
|---|---|---|---|
| `200 OK` | Code resolves to an active, unexpired link | PNG image, at least 512×512px, `Content-Type: image/png`, `Access-Control-Allow-Origin: *`, encoding `{PUBLIC_BASE_URL}/{code}` per the requested (or default) `dots`/`corners`/`bg`/`fg` | FR-022. Uses the exact same lookup and active/expiry precedence as `GET /{code}` (contracts/redirect.md) — not a separate decision. The permissive CORS header exists so `ui/`'s cross-origin download button can `fetch()` the image as a blob. |
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
- No customization beyond `dots`/`corners`/`bg`/`fg` above — no free-form shapes, no logo
  embedding, size options, or alternate image formats (constitution v9.0.0).
- No slug-qualified variant (`/{code}/{slug}/qr`) — the encoded URL is always the bare
  `{PUBLIC_BASE_URL}/{code}` form, regardless of whether the code has a registered slug.
