# SPEC: Rented spool-hub (product MVP)

Status: binding product goal  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/006-spool-hub-rental/`  
Related: `SPEC-spool-milestones.md`, `SPEC-spool-trust-modes.md`, `SPEC-spool-message-bus.md`

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

## 3. Agent plane (see SPEC-spool-trust-modes.md)

**Local (no hub):** no keys. Unsigned `v:1` files, POSIX trust.

**Hub:** one Ed25519 **keypair per box**. `from`/`to` stay agent ids.
Commander signs with the **box private key**; commandee has that **box
public key** (SSH `authorized_keys`, synced from tenant pins). Tenant
**root** is the only key that may publish a box pubkey.

Send/recv travel on **HTTPS WebSocket** to the tenant host. Files and pins
stay **REST**. Hub stores **plaintext** JSON (sign only).

| Action | Proof (hub mode) |
|---|---|
| WS hello / send | box key `sig`; box pinned in this tenant |
| Recv on WS | same box hello; hub routes inboxes for agents this box announced |
| `spool-pin` / revoke | **tenant root** (pins **box** pubkeys) |
| `spool-put-file` | REST; tenant quota |

There is **no** renter API token, **no** GCP user, **no** per-agent hub key.

The tenant URL is not a secret. Unknown box hello is closed. Unpinned send
is refused.

## 3.1 Peer mesh — any agent commands any agent

The hub is a **mailbox**, not an orchestrator. It does not parse `body`, pick
a worker, or privilege one vendor.

Inside one tenant, **every pinned id is a peer**:

| Allowed | Forbidden in MVP |
|---|---|
| `GRK-03` → `CLE-07` `kind=task` | Hub-enforced allowlists (“only HUM may send task”) |
| `CLE-07` → `GRK-03` `kind=task` | Kind-of-agent ACLs (Grok may command Claude but not vice versa) |
| `AGY-01` → `CLE-07` and `CLE-07` → `AGY-01` | A distinguished “controller” role in the protocol |
| `HUM-1` → any pinned agent, if HUM is pinned | Requiring a human on every thread |
| `CLE-07` → `CLE-12` (same kind) | Interpreting the command on the hub |

**Pin of a box = that box may speak and be spoken to.** No second ACL. Unpin
the box to cut off every agent on it.

A **command** is a `v:1` `kind=task` (body + optional files). Local: unsigned
file. Hub: box-signed envelope on WebSocket.
Spool delivers it. The **assignee agent** decides whether to run it (`result` /
`reject` / `note`). Spool never starts Claude/Grok/agy for you.

Unicast: one `to` per message. Command two peers → two `task` messages.

Location does not matter: peers may sit on different laptops, as long as each
has its key and `$SPOOL_HUB_URL`. Same-machine 002 still works without the hub.

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
export SPOOL_BOX_ID=box-a
spool-keygen --box            # box keypair
# renter, once, with tenant root:
spool-pin --box-id box-a --pubkey ...
```

Claude / agy: `spool mcp` as today. Grok: CLI. Same verbs.

No ysg-box, no NATS sidecar required for MVP (poll `spool-recv`).

---

## 7. Milestone 1 (must ship first)

See `SPEC-spool-milestones.md`. Non-WUI: cross-box mail + user command if the
commandee box has the commander’s **public** key. Manual tenant. Payment and
WUI are later milestones.

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

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:00:00Z -->
