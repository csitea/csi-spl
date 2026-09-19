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
2. **The hub cannot read the root private key.** The keypair is minted at
   checkout. The hub keeps the PUBLIC half, and the private half only
   **sealed** (AES-256-GCM) under a key derived from a `claim_token` that is
   returned to the buyer's browser once and stored by the hub only as a
   SHA-256 hash. The seal is wiped on the first successful claim.
3. **Shown once, sent once.** The first successful claim returns the key to
   the success page and sends **one** email (tenant URL + root private key).
   A second claim is `410 claimed`. Losing the claim token before claiming
   loses the key: the operator re-keys out of band (payment.md §Recovery).
4. **Verify before any write.** A webhook whose signature fails writes
   nothing (not even the dedup row) and answers `400` with no detail.
   A duplicate event id is `200 {"status":"duplicate"}` and changes nothing.
5. **Fail closed.** An unknown `SPOOL_HUB_PAYMENT_PROVIDER`, a named rail with
   a missing / placeholder secret or URL, or `SPOOL_HUB_ENABLE_FAKE_PAY=true`
   outside lde/dev **refuses to boot**. No rail configured (`""`) boots, and
   `POST /api/v1/checkout` answers `503 payment_unavailable`.

## 1. Routes

All routes answer on **any Host** (like `/api/v1/auth/*`): the WUI serves them
same-origin from the apex (`/api/*` → hub). JSON in and out; errors are the
hub error envelope `{"error":<token>,"detail":<text>}`.

### 1.1 `GET /api/v1/checkout/plan`

`200`:

```json
{"plan_id":"default","amount_cents":2000,"currency":"eur","rail":"fake",
 "tenant_url_pattern":"https://{tenant}.dev.<domain>"}
```

`rail` is `none` (checkout unavailable), `fake` (lde/dev fake-pay) or
`hosted` (the buyer is redirected to the provider's hosted payment page).

### 1.2 `POST /api/v1/checkout`

Request: `{"tenant_id":"acme","email":"buyer@example.com"}`.
`tenant_id` follows `msg.ValidTenantID` (lower-case slug, reserved labels
refused). `email` is where the one email goes.

`201`:

```json
{"checkout_id":"co_…","claim_token":"…","rail":"hosted",
 "amount_cents":2000,"currency":"eur","tenant_id":"acme",
 "tenant_url":"https://acme.dev.<domain>",
 "redirect_url":"https://<provider hosted page>"}
```

`redirect_url` only for `rail=hosted`. The page MUST keep `checkout_id` and
`claim_token` (e.g. `sessionStorage`) before redirecting and MUST NOT put
`claim_token` in any URL (it would reach the provider and access logs).

| status | error | when |
|---|---|---|
| 400 | `bad_request` | body not JSON, email missing / malformed |
| 400 | `bad_tenant_id` | slug invalid or reserved |
| 409 | `tenant_taken` | the tenant exists, or another checkout holds the slug (hold = `SPOOL_HUB_PAYMENT_HOLD`, default 1h) |
| 503 | `payment_unavailable` | no rail configured / provider call failed |

### 1.3 `GET /api/v1/checkout/{checkout_id}`

Polling for the success page. `200`:
`{"checkout_id":"co_…","tenant_id":"acme","status":"pending|paid|failed|cancelled","claimed":false}`.
`404 not_found` for an unknown id. Carries no secret.

### 1.4 `POST /api/v1/checkout/claim`

Request: `{"checkout_id":"co_…","claim_token":"…"}`.

`200` (exactly once per checkout):

```json
{"tenant_id":"acme","tenant_url":"https://acme.dev.<domain>",
 "root_private_key":"<base64 64-byte ed25519 private key>","emailed":true}
```

`root_private_key` is the format `spool root-keygen` writes (save it 0600 and
point `$SPOOL_TENANT_ROOT_KEY` at it). `emailed` is false when the mail
transport is `none`/`log` or the send failed (the key is still shown).

| status | error | when |
|---|---|---|
| 400 | `bad_request` | body not JSON |
| 404 | `not_found` | unknown checkout **or wrong claim token** (indistinguishable) |
| 409 | `not_paid` | still pending — poll §1.3 and retry |
| 410 | `claimed` | already claimed: the key is gone from the hub |

### 1.5 `POST /api/v1/checkout/fake-pay` (lde/dev only)

Mounted only when fake-pay is allowed (`SPOOL_HUB_ENABLE_FAKE_PAY=true` with env
`lde`/`dev`; the hub refuses to boot with it in any other env, so the route
**does not exist on prd**). Request `{"checkout_id":"co_…"}`. Applies the same
paid transition a signed webhook applies.

`200 {"checkout_id":"co_…","status":"paid","applied":true}`; a second call is
`applied:false`. `404 not_found`; `422 not_fake_checkout` for a checkout on a
real rail; `409 not_pending` for failed / cancelled.

### 1.6 `POST|GET /api/v1/webhooks/payment`

The provider's server-to-server callback (`SPOOL_HUB_PAYMENT_CALLBACK_URL`
points here). Signature: HMAC over the `checkout-*` fields plus body, keyed by
`SPOOL_HUB_PAYMENT_SECRET_KEY` (csi-rel 069 scheme). Fields come from headers
(POST) or the query string (GET redirect callback).

| answer | when |
|---|---|
| `400 bad_request` (no detail) | signature missing / wrong, or required fields missing — nothing written |
| `200 {"status":"duplicate"}` | this `(provider, event id)` was already processed |
| `200 {"status":"ok","action":"paid"}` | tenant created `active` (or re-activated) |
| `200 {"status":"ok","action":"failed"\|"refund"\|"ignored"\|"no_matching_checkout"\|"conflict"}` | acknowledged |

`conflict` = paid, but the slug was meanwhile taken by another buyer: logged
CRITICAL, refund by hand.

## 2. Success page flow (WUI)

1. Plan page: `GET …/plan` → price; slug + email form → `POST …/checkout`.
2. Keep `checkout_id` + `claim_token`; `rail=hosted` → `location = redirect_url`;
   `rail=fake` → a **"Pay (dev fake)"** button → `POST …/fake-pay`.
3. Success page (the provider returns the browser to `SPOOL_HUB_PAYMENT_SUCCESS_URL`):
   poll `GET …/{checkout_id}` until `paid`, then `POST …/claim` once.
4. Show tenant URL + root private key with copy/download, and a clear "this is
   the only time we show it; it was also emailed" warning, then drop the
   `claim_token` from storage.

## 3. Config (cnf `hub.env`; secret via `payment.secret_env`)

| name | meaning |
|---|---|
| `SPOOL_HUB_PAYMENT_PROVIDER` | `""` none · `fake` · `hosted-hmac`; anything else refuses boot |
| `SPOOL_HUB_ENABLE_FAKE_PAY` | lde/dev only; `true` elsewhere refuses boot; with provider `""` it selects the fake rail |
| `SPOOL_HUB_PAYMENT_PLAN_ID` / `_PLAN_CENTS` / `_CURRENCY` | the M2 tenant plan |
| `SPOOL_HUB_PAYMENT_PUBLIC_SCHEME` | scheme of `tenant_url` |
| `SPOOL_HUB_PAYMENT_HOLD` | how long a pending checkout holds its slug (default `1h`) |
| `SPOOL_HUB_PAYMENT_API_BASE` | provider API base (no baked host) — `hosted-hmac` |
| `SPOOL_HUB_PAYMENT_MERCHANT_ID` | provider account id — `hosted-hmac` |
| `SPOOL_HUB_PAYMENT_SUCCESS_URL` / `_CANCEL_URL` / `_CALLBACK_URL` | browser returns + webhook URL — `hosted-hmac` |
| `SPOOL_HUB_PAYMENT_SECRET_KEY` | **secret** (Secret Manager slot `csi-spl-hub-payment-secret-key`) — `hosted-hmac` |

<!-- version: 1.0.0 · updated: 2026-09-19 -->
