# Contract: checkout-v1 — buy a tenant (M2, 006 T018–T021)

The HTTP surface a **thin checkout page** and a **success page** (WUI, the UI
lane) call to sell one tenant. The hub side is `internal/payments`. Companion
to `payment.md` (what is copied from csi-rel and why).

## 0. Principles

1. **No tenant before payment.** A checkout holds the slug (a `pending`
   `payment_checkouts` row); the `tenants` row is created — `active` — only by
   a verified paid event (signed webhook, or fake-pay on lde/dev). Nothing
   answers on `<slug>.<domain>` until then, so nobody can sign in to an
   unpaid slug and become its owner.
2. **No private key exists before the claim, and none is ever stored or
   emailed** (017 T008 / SEC-03). Checkout gives the slug a PLACEHOLDER root
   public key whose private half is discarded at once; the first successful
   claim mints the real keypair, rotates the tenant (and checkout) to its
   public half in one transaction, and returns the private half once.
3. **Two single-use claim tokens, stored as SHA-256 only.** The browser's
   `claim_token` (§1.2) and a link token minted when the checkout is paid and
   sent in the **one email** (tenant URL + claim link, no key). The first
   claim with either burns both; later claims are `410 claimed`. Both die at
   `SPOOL_HUB_PAYMENT_CLAIM_TTL` (default 24h) after payment → `410
   claim_expired`, and the operator re-keys (payment.md §Recovery).
4. **Verify before any write.** A webhook whose signature fails writes
   nothing (not even the dedup row) and answers `400` with no detail.
   A duplicate event id is `200 {"status":"duplicate"}` and changes nothing.
5. **Fail closed.** An unknown `SPOOL_HUB_PAYMENT_PROVIDER`,
   `SPOOL_HUB_ENABLE_FAKE_PAY=true` outside lde/dev, or PayPal on prd / in live
   mode **refuses to boot**. No rail (`""`) boots and checkout answers
   `503 payment_unavailable`; a card rail whose keys are unusable boots too
   (the hub carries every box) and checkout answers `503` with detail
   `payment_provider_misconfigured` (csi-rel F-17).
6. **Providers are csi-rel's** (owner direction 2026-09-19): the card rail is
   Stripe exactly as csi-rel does it (PaymentIntent + Payment Element + signed
   webhook); csi-rel's PayPal (Orders v2, approve-then-capture) is copied OFF
   by default and is **not live-tested**.

## 1. Routes

All routes answer on **any Host** (like `/api/v1/auth/*`): the WUI serves them
same-origin from the apex (`/api/*` → hub). JSON in and out; errors are the
hub error envelope `{"error":<token>,"detail":<text>}`.

### 1.1 `GET /api/v1/checkout/plan`

`200`:

```json
{"plan_id":"default","amount_cents":2000,"currency":"eur","rail":"card",
 "methods":["card","paypal"],"available":true,
 "publishable_key":"pk_…","paypal_client_id":"…"}
```

`rail` is the card rail: `none` (unavailable), `fake` (lde/dev fake-pay) or
`card` (Stripe: `publishable_key` for the Payment Element). `methods` lists
what §1.2 accepts; `paypal` only while PayPal is enabled (never prd), with
`paypal_client_id` for the PayPal JS SDK. `available` is false while the
card rail is guarded.

### 1.2 `POST /api/v1/checkout`

Request: `{"tenant_id":"acme","email":"buyer@example.com","method":"card","locale":"fi"}`
(`method` optional: `card` default, or `paypal`).
`tenant_id` follows `msg.ValidTenantID` (lower-case slug, reserved labels
refused). `email` is where the one email goes.
`locale` (optional, spec 021 T022) is the language the buyer is reading the
checkout in: the WUI's active locale, one of the 19 `internal/i18n` `Supported`
codes. It is kept on the checkout row (rdb 0025 `buyer_locale`) because the
claim mail is sent by the paid webhook, long after this request is gone; that
mail and the claim link's path prefix then follow it. It rides the BODY, not a
header, so the checkout never depends on a CORS allow-list. Precedence:
`locale` > `X-Locale` > `Accept-Language` > `SPOOL_HUB_DEFAULT_LOCALE` at send
time. A code the hub does not ship is DROPPED, never refused and never
reflected: the sale goes through and the mail falls back to the default.

`201`:

```json
{"checkout_id":"co_…","claim_token":"…","method":"card","rail":"card",
 "amount_cents":2000,"currency":"eur","tenant_id":"acme",
 "tenant_url":"https://dev.<domain>/login?tenant=acme",
 "client_secret":"pi_…_secret_…","publishable_key":"pk_…"}
```

`rail=card`: mount the Stripe Payment Element with `client_secret` +
`publishable_key` and `confirmPayment` with `return_url` = the success page.
`rail=fake`: no secret; show the fake-pay button (§1.5). `method=paypal`:
`{"rail":"paypal","provider_order_id":"…","approve_url":"…"}` — render the
PayPal button for that order id; on approve call §1.7 (`approve_url` is the
no-popup fallback). The page MUST keep `checkout_id` and `claim_token` (e.g.
`sessionStorage`) before any redirect and MUST NOT put `claim_token` in any
URL (it would reach the provider and access logs).

| status | error | when |
|---|---|---|
| 400 | `bad_request` | body not JSON, email missing / malformed |
| 400 | `bad_method` | `method` is not `card` / `paypal` |
| 400 | `bad_tenant_id` | slug invalid or reserved |
| 409 | `tenant_taken` | the tenant exists, or another checkout holds the slug (hold = `SPOOL_HUB_PAYMENT_HOLD`, default 1h) |
| 503 | `payment_unavailable` | method not configured, card rail guarded (`payment_provider_misconfigured`), or the provider call failed |

### 1.3 `GET /api/v1/checkout/{checkout_id}`

Polling for the success page. `200`:
`{"checkout_id":"co_…","tenant_id":"acme","status":"pending|paid|failed|cancelled","claimed":false,
"tenant_host":"acme.dev.<domain>","host_status":"pending|ready|unknown"}`.
`host_status` (specs/024, only once `paid`): `pending` while the tenant's own
host (Cloud Run domain mapping + DNS record + certificate) is being provisioned
by the reconcile, `ready` once it answers, `unknown` when the hub cannot tell.
`404 not_found` for an unknown id. Carries no secret.

### 1.4 `POST /api/v1/checkout/claim`

Request: `{"checkout_id":"co_…","claim_token":"…"}`.

`claim_token` is either the browser's token (§1.2) or the emailed link's
token (§1.8). `200` (exactly once per checkout; the key is minted now):

```json
{"tenant_id":"acme","tenant_url":"https://dev.<domain>/login?tenant=acme",
 "tenant_host":"acme.dev.<domain>","host_status":"pending|ready|unknown",
 "root_private_key":"<base64 64-byte ed25519 private key>"}
```

`root_private_key` is the format `spool root-keygen` writes (save it 0600 and
point `$SPOOL_TENANT_ROOT_KEY` at it). Render it once, keep it in memory only,
never in storage, a URL or a log.

| status | error | when |
|---|---|---|
| 400 | `bad_request` | body not JSON |
| 404 | `not_found` | unknown checkout **or wrong claim token** (indistinguishable) |
| 409 | `not_paid` | still pending — poll §1.3 and retry |
| 410 | `claimed` | already claimed (by either token) |
| 410 | `claim_expired` | past `SPOOL_HUB_PAYMENT_CLAIM_TTL` |
| 409 | `conflict` | the tenant was re-keyed meanwhile (operator) |

### 1.5 `POST /api/v1/checkout/fake-pay` (lde/dev only)

Mounted only when fake-pay is allowed (`SPOOL_HUB_ENABLE_FAKE_PAY=true` with env
`lde`/`dev`; the hub refuses to boot with it in any other env, so the route
**does not exist on prd**). Request `{"checkout_id":"co_…"}`. Applies the same
paid transition a signed webhook applies.

`200 {"checkout_id":"co_…","status":"paid","applied":true}`; a second call is
`applied:false`. `404 not_found`; `422 not_fake_checkout` for a checkout on a
real rail; `409 not_pending` for failed / cancelled.

### 1.6 Webhooks (csi-rel paths)

`POST /api/v1/webhooks/payment/stripe` — `Stripe-Signature` verified with the
endpoint secret (`t=,v1=` HMAC-SHA256, 5-minute tolerance, csi-rel
`VerifyStripe`). `payment_intent.succeeded` → paid; `charge.refunded` →
refund (tenant `unpaid`); `payment_intent.payment_failed` → acknowledged only
(the buyer may retry the same intent); `charge.dispute.*` → acknowledged +
CRITICAL log. The checkout is found by the intent id.

`POST /api/v1/webhooks/payment/paypal` (PayPal enabled only) — offline
RSA-SHA256 transmission signature over `id|time|webhook_id|crc32(body)`,
cert only from `*.paypal.com` (csi-rel). `PAYMENT.CAPTURE.COMPLETED` → paid;
`…REFUNDED` / `…REVERSED` → refund. The checkout is found by the order id.

| answer | when |
|---|---|
| `400 bad_request` (no detail) | signature missing / wrong / stale, or the rail is off — nothing written |
| `200 {"status":"duplicate"}` | this `(provider, event id)` was already processed |
| `200 {"status":"ok","action":"paid"}` | tenant created `active` (or re-activated) |
| `200 {"status":"ok","action":"refund"\|"ignored"\|"no_matching_checkout"\|"already_paid"\|"conflict"}` | acknowledged |

`conflict` = paid, but the slug was meanwhile taken by another buyer: logged
CRITICAL, refund by hand.

### 1.7 `POST /api/v1/checkout/paypal/capture` (PayPal enabled only)

`{"checkout_id":"co_…"}` → `202 {"status":"capturing"}`. Captures the approved
order (idempotent: PayPal-Request-Id = checkout id); the webhook, not this
answer, marks it paid — poll §1.3. `404` for a non-PayPal checkout.

### 1.8 The one email and the claim page (017 T008)

When a checkout turns paid (signed webhook or fake-pay) the hub mints the link
token and sends ONE mail (template `tenant_paid`): tenant URL + the link
`<SPOOL_HUB_PAYMENT_CLAIM_URL>#checkout=<checkout_id>&token=<token>`, no key.
The token rides in the URL **fragment**, so it never reaches a server or proxy
log. The WUI claim page reads the fragment, clears it from the address bar
(`history.replaceState`), and calls §1.4 once.

### 1.8a `tenant_url` = the WUI sign-in page (1.4, owner 2026-09-19 "tenant from identity")

No per-tenant host: `tenant_url` (§1.2, §1.4, the paid mail) is
`<WUI origin>/login?tenant=<id>`, the origin taken from
`SPOOL_HUB_PAYMENT_CLAIM_URL` (same shape as the invitation mail). `GET /plan`
no longer returns `tenant_url_pattern`; the WUI tolerates either.

### 1.9 M4 seats and the dedicated SKU (009 T002/T004/T005; additive, 1.3)

Only when cnf prices a seat kind (`SPOOL_HUB_PAYMENT_SEAT_USER_CENTS` /
`_SEAT_BOT_CENTS` > 0); the M2 plan is unchanged and names no seat (009 T001).

- `GET /plan` adds `seat_user_cents`, `seat_bot_cents`, `seats_max`, and
  `dedicated: true` when `SPOOL_HUB_PAYMENT_DEDICATED`.
- `POST /checkout` takes `seats_users`, `seats_bots` (per month): a priced
  kind 1..`seats_max`, an unpriced kind 0 (= unlimited). A dedicated plan
  also takes `org` + `app` (3-letter codes). Errors (400): `seats_not_sold`
  (seats on a plan that sells none), `bad_seats`, `bad_org_app`.
- The answer's `amount_cents` = plan + seats; `line_items`
  `[{name: tenant|user_seat|bot_seat, quantity, unit_cents}]` appears only
  with seats. The card rail carries the items as PaymentIntent metadata +
  description.
- The verified paid webhook applies them in the tenant's transaction: caps
  `tenants.seats_users/_bots`, the UTC month's `tenant_seat_periods` row
  (rdb 0016) and, dedicated, `project_id` = `{org}-{app}-{env}-{YYYYMMDDHHmm}`
  at the paid minute (a clash → the next minute, then a nonce).

## 2. Success page flow (WUI)

1. Plan page: `GET …/plan` → price; slug + email form → `POST …/checkout`.
2. Keep `checkout_id` + `claim_token`; `rail=card` → Stripe Payment Element,
   `confirmPayment({return_url: <success page>})`; `rail=fake` → a
   **"Pay (dev fake)"** button → `POST …/fake-pay`; `paypal` → PayPal button,
   onApprove → `POST …/paypal/capture`.
3. Success page: poll `GET …/{checkout_id}` until `paid`, then `POST …/claim` once.
4. Show tenant URL + root private key with copy/download and a clear "this is
   the only time it is shown; it is not emailed and the hub does not keep it"
   warning, then drop the `claim_token` from storage. While `host_status` is
   `pending`, say "your address <tenant_host> is being prepared" (specs/024:
   typically 15-30 min) and keep polling §1.3 until it reads `ready`.
5. Claim page (`/checkout/claim`, §1.8): same render as step 4 from the link;
   `410 claimed` → "already collected (on the success page or from this link)".

## 3. Config (cnf `hub.env`; secret via `payment.secret_env`)

| name | meaning |
|---|---|
| `SPOOL_HUB_PAYMENT_PROVIDER` | `""` none · `fake` · `stripe`; anything else refuses boot |
| `SPOOL_HUB_ENABLE_FAKE_PAY` | lde/dev only; `true` elsewhere refuses boot; with provider `""` it selects the fake rail |
| `SPOOL_HUB_PAYMENT_PLAN_ID` / `_PLAN_CENTS` / `_CURRENCY` | the M2 tenant plan |
| `SPOOL_HUB_PAYMENT_PUBLIC_SCHEME` | unused since 1.4 (`tenant_url` takes the claim page origin) |
| `SPOOL_HUB_PAYMENT_HOLD` | how long a pending checkout holds its slug (default `1h`) |
| `SPOOL_HUB_PAYMENT_CLAIM_URL` | the WUI claim page the mail links to; unset with a rail on → checkout 503 (guard); malformed → boot refused |
| `SPOOL_HUB_PAYMENT_CLAIM_TTL` | claim window after payment (default `24h`) |
| `SPOOL_HUB_STRIPE_PUBLISHABLE_KEY` | public, for the Payment Element |
| `SPOOL_HUB_STRIPE_API_BASE` / `_API_VERSION` | empty = the live API / the pinned version (a stripe-mock only in lde) |
| `SPOOL_HUB_STRIPE_SECRET_KEY` / `_WEBHOOK_SECRET` | **secrets** (slots `csi-spl-hub-stripe-secret-key`, `csi-spl-hub-stripe-webhook-secret`) |
| `SPOOL_HUB_ENABLE_PAYPAL` | default `false`; refused on prd and with `SPOOL_HUB_PAYPAL_MODE=live` |
| `SPOOL_HUB_PAYPAL_CLIENT_ID` / `_MODE` / `_API_BASE` / `_WEBHOOK_ID` | PayPal (sandbox) |
| `SPOOL_HUB_PAYPAL_CLIENT_SECRET` | **secret** (slot `csi-spl-hub-paypal-client-secret`) |

<!-- version: 1.4.0 · updated: 2026-09-19 (§1.8a tenant_url = WUI sign-in, tenant_url_pattern dropped) -->
