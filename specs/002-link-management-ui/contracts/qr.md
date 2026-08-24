# Contract: QR Code

**Moved (2026-08-24, constitution v6.0.0)**: QR generation no longer lives in `ui/`. It's now
`GET /{code}/qr` on `redirect/` (see `specs/001-redirect-service/contracts/` and
`redirect/internal/handler/qr.go`) — a public, unauthenticated endpoint with no ownership
check, since the URL it encodes is exactly the same already-public string `GET /{code}` itself
resolves. `ui/`'s link detail page links/embeds that endpoint directly
(`ui/src/lib/shortUrl.ts`'s `buildQrImageUrl`); it no longer serves or proxies the image
itself. This file is kept only so the prior `ui/`-owned contract (below) remains in the
history; it is no longer authoritative.

## Prior contract (superseded): `GET /links/{code}/qr`

Returned a QR code image encoding the link's short URL, for a link the caller owned.

| Outcome | When | Response |
|---|---|---|
| Image returned | Caller owns `code` | `200 OK`, `Content-Type: image/png`, a PNG image at least 512×512px that decodes to the short link's URL. |
| Rejected — not owner | `code` exists but `owner_id` ≠ caller | `403 Forbidden`. |
| Rejected — not found | `code` doesn't exist | `404 Not Found`. |

The ownership/auth check above is gone in the new contract — see the "Moved" note above for why.

## Explicitly out of scope (still applies to the new `redirect/`-owned endpoint)

- No customization (colors, logo embedding, size options) beyond a default, scannable QR code.
- No bulk QR export.
