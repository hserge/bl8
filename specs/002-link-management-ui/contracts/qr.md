# Contract: QR Code

## `GET /links/{code}/qr`

Returns a QR code image encoding the link's short URL, for a link the caller owns (User
Story 4).

| Outcome | When | Response |
|---|---|---|
| Image returned | Caller owns `code` | `200 OK`, `Content-Type: image/png`, a PNG image at least 512×512px that decodes to the short link's URL (FR-012). |
| Rejected — not owner | `code` exists but `owner_id` ≠ caller | `403 Forbidden`; no image returned (FR-010, spec.md Acceptance Scenario 4.2). Body shape per contracts/links.md's Response Body Conventions. |
| Rejected — not found | `code` doesn't exist | `404 Not Found`. Body shape per contracts/links.md's Response Body Conventions. |

## Explicitly out of scope

- No customization (colors, logo embedding, size options) beyond a default, scannable QR code.
- No bulk QR export.
