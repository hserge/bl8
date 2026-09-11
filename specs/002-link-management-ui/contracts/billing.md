# Contract: Plan, Checkout, and Subscription Management

Added 2026-09-10 — not part of the original feature description (spec.md Clarifications,
Session 2026-09-09 through 2026-09-11). Two billing providers exist behind one interface:
Paddle (live) and Stripe (implemented, code-complete, currently on placeholder credentials
until a real Stripe account exists) — which one is active is operator configuration
(`BILLING_PROVIDER`), not a per-user choice.

## `GET /info/pricing`

Public, unauthenticated marketing/checkout entry point.

| Response field | Notes |
|---|---|
| `signedIn` | Whether the visitor has a session. Checkout requires one — see below. |
| `freeLinkLimit` | The current `FREE_PLAN_LINK_LIMIT` value (FR-031), shown so a visitor can see exactly what Free caps out at before upgrading. |
| `providerIsStripe` | Only present when signed in; tells the page which checkout initiation path to render (see below). |

## `POST /info/pricing?/upgrade` (form action) — Stripe path only

Only meaningful when the active provider is Stripe; Paddle's checkout is opened client-side
instead (see Client-initiated checkout below) and never posts here.

| Outcome | When | Response |
|---|---|---|
| Redirected to checkout | Caller has a session | `303` to a Stripe-hosted checkout session URL for this account. |
| Rejected | No session | `401 Unauthorized`. |

## Client-initiated checkout — Paddle path only

When the active provider is Paddle, checkout is opened directly from the browser (Paddle's own
overlay/inline checkout), not through a server form action — there is no equivalent server
route for this path. The account's identity is passed to Paddle at checkout open time so its
webhook (below) can attribute the resulting subscription correctly.

## `POST /webhooks/paddle`, `POST /webhooks/stripe`

The only place a `subscriptions` row (data-model.md) or `users.plan_id` is ever written
(FR-032) — this application never sets either directly in response to a user action; both are
entirely provider-driven.

| Outcome | When | Response |
|---|---|---|
| Subscription created/updated | A valid, verified event for a subscription becoming active | `subscriptions` row created/updated (provider, customer id, subscription id, status, current period end) and `users.plan_id` set to `'pro'` for that account. |
| Subscription canceled/lapsed | A valid, verified event for a subscription ending | `subscriptions.status` updated to reflect it; `users.plan_id` reverts to `'free'`. Already-active links stay active past the cap (spec.md Edge Cases) — the cap only blocks *new* active links from that point on. Existing API keys stop authenticating on their next use (contracts/api-keys.md) but are not deleted. |
| Rejected — unverified | Event fails the provider's own signature/webhook-secret verification | Rejected outright; no database change. Prevents a forged request from granting or revoking Pro for an arbitrary account. |

## `POST /app/profile?/manageBilling` (form action)

Hands the caller off to their billing provider's own hosted subscription-management portal —
this application builds no cancel/update-payment-method UI of its own (FR-032).

| Outcome | When | Response |
|---|---|---|
| Redirected to portal | Caller has a session and an existing `subscriptions` row | `303` to the provider's hosted portal (Stripe billing portal, or Paddle's customer portal), scoped to that account's own subscription. |
| Rejected — no subscription | Caller has no `subscriptions` row (e.g. still on Free) | `400 Bad Request` — `{ error: 'No subscription to manage yet.' }`. |
| Rejected — no session | Caller isn't logged in | `401 Unauthorized`. |

## Explicitly out of scope

- No payment card collection or storage of any kind by this application (spec.md Assumptions)
  — every payment detail lives with the billing provider.
- No in-app cancel/upgrade/downgrade UI beyond the redirect to the provider's own portal.
- No proration, coupon, or multi-tier pricing logic — exactly two plans, one price point for
  Pro, both defined by the provider's own product configuration, not this application.
