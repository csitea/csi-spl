# SPEC: Rented spool-hub (product MVP)

Status: binding product goal  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/006-spool-hub-rental/`  
Related: `SPEC-spool-message-bus.md`, `SPEC-spool-box-api.md`, `SPEC-spool-identity-routing.md`

---

## 1. The product

Anyone can **pay** to rent a **spool-hub tenant**. That tenant is a mailbox in
the sky for their agents. Claude Code, Grok, and Antigravity talk to each
other through it using **only Ed25519 keypairs**. No GCP account, no IAM
user, no per-agent cloud key, no Slack, no vendor-specific API.

| Who | Has | Does not have |
|---|---|---|
| Paying renter (human) | bill, tenant URL, **tenant root** keypair | agent private keys (unless they also run an agent) |
| Each agent (CLE / GRK / AGY) | its own keypair + the tenant URL | a Google identity, a second API token |
| Us (host) | Cloud Run / Postgres / GCS | the renter’s agent private keys |

`ysg-box` is **not required**. A renter may run agents on a laptop, a VM, or
a box image. The box API is still `spool-send` / `spool-recv` / MCP.

Internal csitea fleet is **one tenant** of the same product, not a different
protocol.

---

## 2. What “rent” means

Payment (checkout via the configured payment provider — env, no baked vendor)
creates:

1. A **tenant id** (`^[a-z0-9][a-z0-9-]{0,31}$`).
2. A **tenant URL** (`$SPOOL_HUB_URL`), e.g. `https://<tenant>.<<run-time>>.csitea.net` — host from cnf, never a literal in code.
3. A **tenant root** Ed25519 keypair. The **private** root key is shown **once**
   to the renter (download / printed) and never stored on the hub. The public
   root is in `tenants.root_pubkey`.
4. A quota: messages / month, stored file bytes, pin count (cnf). Over quota
   → HTTP 429 / CLI exit `1` (`error: quota`), not `78`.

Unpaid / cancelled tenant: hub accepts **recv and get-file** for a grace
period (cnf, default 7 days) and **refuses send and pin** (`402` /
`error: unpaid`). After grace, data may be deleted (cnf retention).

Manual create (`./run -a do_spl_tenant_create`) is allowed before checkout
exists — same artefacts, `billing_status=manual`.

---

## 3. Agent plane = keys only

Intercommunication (send, recv, ack, get-file of a message’s attachments)
authenticates **only** with Ed25519:

| Action | Proof |
|---|---|
| `spool-send` | `v:1.sig` by `from`’s key; `from` pinned **in this tenant** |
| `spool-recv --as X` | signed recv request by X’s key (not an open GET) |
| `spool-pin` / revoke | signed by the **tenant root** key |
| `spool-put-file` | hashed bytes; upload is allowed if the following send will be accepted — implement as: put-file does not require a pin; unreferenced blobs GC by age (limits). Abuse: quota on PUT bytes per tenant. |

There is **no** renter API token, **no** GCP user, **no** OAuth for agents.

The tenant URL is **not a secret**. Knowing it only lets you hit the tenant.
Unpinned signatures are `400`. Recv without proving `as` is `401`.

### Signed recv (hub mode)

`GET /v1/messages?as=` is **not** the product API (anyone could drain an
inbox). Hub mode uses:

```
POST /v1/recv
{ "as": "CLE-07", "ack": false, "ts": "<RFC3339 Z>", "sig": "<base64>" }
```

Canonical payload: `jq -cS 'del(.sig)'` of that object (no `as` key missing).
Verify against pin of `as`. Clock: reject `|ts - now| > 5 minutes` (replay
window). Optional `nonce` stored 10 minutes.

CLI: `spool-recv --as CLE-07` does this when `$SPOOL_HUB_URL` is set.

### Pin mutations

```
POST /v1/pins
{ "id": "GRK-03", "pubkey": "<b64>", "ts": "...", "sig": "<b64>" }
```

`sig` is the **tenant root**, not GRK-03. An agent cannot pin itself onto a
paid tenant. `--force` and revoke: same, root-signed.

---

## 4. Tenant is the isolation boundary

Pins, messages, files, quotas are **per tenant**.

`CLE-07` in tenant `acme` is not `CLE-07` in tenant `other`. 004’s “globally
unique” means **unique inside one tenant**, not unique on Earth.

Routing: `$SPOOL_HUB_URL` selects the tenant (Host header or path prefix
`/t/<tenant>/` — one choice, cnf). No `tenant_id` field on `v:1` (the URL is
the namespace; putting tenant in the signed message would break 002 local).

Postgres: every mail table has `tenant_id`. GCS prefix: `t/<tenant>/files/<sha256>`.

A request that authenticates as tenant A must not read tenant B. Tests: two
tenants, same agent id, different keys; cross-GET is 404/401.

---

## 5. Hosting shield vs product door

Our Cloud Run may sit behind rate limits / bot protection. That is **our**
infra. It is **not** a credential we issue to renters.

**Rejected as the product door:** requiring each renter to have a GCP IAM
principal to POST. That contradicts “any user, against payment.”

003’s “IAM is the door” applies only to **private** deployments (one org,
Cloud Run `--no-allow-unauthenticated`). The **public rental** deployment
allows unauthenticated HTTP; Ed25519 is the author **and** the authorisation
to recv.

---

## 6. What the renter installs

On each machine that runs an agent:

```
export SPOOL_HUB_URL=https://<tenant>.<<run-time>>.csitea.net
# keys as in 002
spool-keygen --as GRK-03
# once, on the operator machine, with the tenant root key:
spool-pin --id GRK-03 --pubkey ...    # signs with $SPOOL_TENANT_ROOT_KEY
```

Claude / agy: `spool mcp` as today. Grok: CLI. Same verbs.

No ysg-box, no NATS sidecar required for MVP (poll `spool-recv`).

---

## 7. MVP cut (must ship)

1. 002 local signed send/recv (already specified).
2. Hub HTTP: send (body sig), recv (signed POST), files, pin (root sig).
3. Tenant create (manual action + later payment webhook).
4. Quota + unpaid behaviour.
5. Isolation tests (two tenants).

**Not in rental MVP:** NATS, WUI send, ysg-box adapter, git-rel, Kafka,
per-agent IAM, custom domains (later).

WUI (005) for a renter: read-only, auth = prove tenant root (or a `HUM-*`
pinned by root), still no GCP user required.

---

## 8. Payment

- Provider and prices live in cnf, not in this spec’s prose as a vendor name.
- Webhook (signed by the provider) → create/resume/cancel tenant.
- Hub never stores card numbers.
- Failure of the provider must not drop **recv** during grace.

---

## 9. Invariants

- Agents intercommunicate with Ed25519 only.
- Tenant root is the only key that can pin/revoke.
- Private keys never on the hub.
- `v:1` message schema unchanged (002 = 003 = 006 wire).
- Uniform box API (Constitution VIII).
- Payment gates **existence and quota**, not the meaning of `sig`.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
