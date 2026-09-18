# Contract: Tenant layer over the hub wire

What 006 adds on top of 003's wire. The wire itself — WS `/v1/ws` hello
(nonce, `role=box|cli`), send envelope, recv/tail frames, REST files and pins
shapes, error envelope — is **003's** and is not restated here:
`../../003-spool-message-bus/contracts/http-v1.md`,
`../../003-spool-message-bus/contracts/error-envelope.md`. Pin semantics
(409, `--force`, revoke, sync) are **004's**. Trust:
`../../002-box-agent-messaging/contracts/trust-modes.md`.

## 1. Tenant resolution — **Implemented** (`internal/hub/server.go` `tenantOf`)

- Every request (REST and the WS upgrade) resolves its tenant from the
  **Host** header against `$SPOOL_HUB_TENANT_HOST_PATTERN` = `{tenant}.<fqdn>`
  (cnf, from `env.dns.fqdn`; lde `{tenant}.localhost`). The port is ignored.
- The label before the suffix must match `^[a-z0-9][a-z0-9-]{0,31}$`; a host
  outside the suffix, a dotted label, or an unknown id → `404 unknown_tenant`.
- There is **no** path-prefix (`/t/<tenant>/`) routing and **no** `tenant_id`
  in `v:1` or in the envelope: the URL is the namespace.
- Reserved labels (env names such as `dev`, infra hosts) are refused at tenant
  create — **Planned** (T016).

## 2. Root-signed pin authority — **Implemented** (`TestPinRESTRootSigned`)

`POST /v1/pins` and `DELETE /v1/pins/{box_id}` (shapes: 003 `http-v1.md` §4)
verify `sig` against **this tenant's** `tenants.root_pubkey`, with the 003 `ts`
skew window. Any other key → `400 bad_sig`. A box can never pin itself.

## 3. Billing gate — **Implemented** (`internal/billing`, `TestUnpaidSendPin402RecvInGrace`)

| `billing_status` | send (WS) · pin · revoke · PUT file | hello · recv · tail · GET file · GET pins |
|---|---|---|
| `active`, `internal` (and `manual`, Planned T001a) | allowed | allowed |
| `grace`, `unpaid` | `402 unpaid` (CLI exit 1) | allowed |

After `SPOOL_HUB_BILLING_GRACE` a `grace` tenant becomes `unpaid`, and after
cnf retention its data may be deleted — **Planned** (T013a).

## 4. Quota — **Implemented, deploy-wide** (`TestQuotaExceeded429`)

| Limit (cnf, 0 = unlimited) | Checked on | Response |
|---|---|---|
| `SPOOL_HUB_QUOTA_MESSAGES_PER_MONTH` (UTC calendar month) | WS send | `429 quota` |
| `SPOOL_HUB_QUOTA_PINS` | `POST /v1/pins` | `429 quota` |
| `SPOOL_HUB_QUOTA_FILE_BYTES` (stored bytes) | `POST /v1/files` | `429 quota` |

Recv is never quota-gated. Per-plan values (keyed by `tenants.plan_id`) are
**Planned** (T012a, OQ-006-1).

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:05:25Z -->
