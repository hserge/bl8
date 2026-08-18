# Contract: Authentication

Handled by `@auth/sveltekit` under `src/routes/auth/[...auth]/+server.ts`, Google as the only
configured provider (FR-015).

| Route (Auth.js convention) | Purpose |
|---|---|
| `GET /auth/signin` (or a "Sign in with Google" link that starts the flow) | Redirects to Google's OAuth consent screen. |
| `GET /auth/callback/google` | Google redirects back here after consent; on success, establishes a session and creates the user account on first login (FR-016) if `google_subject_id` doesn't already exist. |
| `POST /auth/signout` | Ends the session. |

## Session

Every other route in this app (links, analytics, QR) checks for a valid session server-side
before doing any work:

- No session → creation, update, delete, analytics, and QR routes all reject the request
  (FR-001, FR-010). Read-only pages redirect to sign-in; API-style routes (e.g. QR) return
  `401 Unauthorized`.
- Valid session → the session's user `id` is the `owner_id` used for every ownership check in
  every other contract below.

## Explicitly out of scope

- No password-based registration or login (FR-015).
- No other identity providers.
