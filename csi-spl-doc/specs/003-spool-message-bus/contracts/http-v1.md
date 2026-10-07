# Contract: Hub transport v1 (box CLI hides this; agents never call it)

Stateless Cloud Run, **HTTPS + WebSocket**. The box CLI/MCP is the only client;
agents never call these endpoints directly (Constitution VIII).

Normative sources, in order: `../../002-box-agent-messaging/contracts/trust-modes.md` §4–§5
(binding owner decision), then the OQ decisions recorded in `../spec.md`
(**Resolved decisions**), then this file, then
`../../006-spool-hub-rental/contracts/http-rental.md` (tenant, pins, billing).
The inner message is the frozen 002 object
(`../../002-box-agent-messaging/contracts/message-schema.md`), unchanged.

Tenant = request **Host** (`<tenant>.<product-domain>`, domain from cnf). No
path prefix, and no `tenant_id` field in `v:1`.
**Amended by 026 (2026-09-19):** the tenant comes from the identity. Box
requests name it in `X-Spool-Tenant` (`boxTenant`), browser requests take it
from the member session (`humanTenant`), both in `internal/hub/resolve.go`; a
Host that disagrees → `403 tenant_mismatch`, none named → `tenant_required`.
The Host rules in this section are kept for the record.

**Reserved labels are the API host, never a tenant.** `api`, `www`, `dev` (and
the rest of `msg.ValidTenantID`'s reserved list, owned by 004/006) never
resolve to a tenant, nor does any host with an extra label (`dev.api.<fqdn>`).
On such a host the non-tenant routes answer (`/`, `/version`, `/healthz`,
`/v1/health`, `/api/v1/auth/*`); every tenant-scoped route (`/v1/ws`,
`/v1/files`, `/v1/pins`, `/v1/view/*`) is `404 unknown_tenant`
(`TestReservedHostIsAPIHostNotTenant`).
The API host is **API-only in M1** (ORC decision 2026-09-18): tenant data is
read on `<tenant>.<fqdn>` only. A path or header tenant carrier on the API
host is a post-M1 item, if ever.

**Two planes (sync 2026-09-25).** *Box plane*: send and recv are WebSocket
only (`/v1/ws`, OQ-02); box REST is files and pins only. *Browser/admin plane*:
live chat on WS `/v1/wui/ws` plus the REST routes in §1 (view, channels,
message edit/delete/reactions, members, auth, keys, checkout), each owned by the
spec named in its row. Neither plane has a REST send/recv dialect:
`grep -c '"POST /v1/messages\|"GET /v1/messages\|/v1/recv' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go` → 0.

## 1. Endpoint inventory (every route the hub mounts, with its owning spec)

Source (sync 2026-09-25, tree `bbe04d26`):
`grep -rn 'HandleFunc' csi-spl-api/src/go/spool-hub-api/internal/hub csi-spl-api/src/go/spool-hub-api/internal/auth csi-spl-api/src/go/spool-hub-api/internal/payments --include=*.go | grep -v _test | grep -v fakeidp`.
Routes marked *(cond)* are mounted only when that feature is configured.

### 1.1 Box plane (box CLI / MCP only)

```
WS     /v1/ws                     challenge, hello, roster, send envelope, recv + tail frames   003 FR-001, FR-003–006
POST   /v1/files                  upload bytes, WS-issued upload token → { file_id, sha256, bytes }   003 FR-007
GET    /v1/files/{file_id}        the bytes; upload token or member session                      003 FR-007, 017 FR-SEC-002
GET    /v1/pins                   tenant box pubkeys (authorized_keys sync), upload token        004
POST   /v1/pins                   pin a box pubkey, tenant-root signed                           004 / 006
DELETE /v1/pins/{box_id}          revoke a box pin, tenant-root signed                           004 / 006
POST   /v1/cicd-logs              CI log ingest (cond: CICD configured)                          008
```

### 1.2 Public and probes

```
GET    /                          text/plain "spool-hub <env> ok" — public hello at the root     003 FR-001
GET    /healthz                   liveness                                                       003 FR-001
GET    /v1/health                 liveness, Cloud Run / LB-safe path (same body as /healthz)     003 FR-023
GET    /version                   { version, commit, built_at } — public; deploy acceptance      003 FR-001
GET    /v1/debug/client-ip        client-ip probe (cond: probe flag)                             017
GET    /api/v1/auth/client-ip     the same probe under the auth prefix (cond: probe flag)        017
```

### 1.3 Browser plane: live and read

```
WS     /v1/wui/ws                          browser live chat → ./wui-live-ws.md             003 (owner goal), FR-028
GET    /v1/wui/pubkey                      public key of the hub-held box-wui key           014
GET    /v1/view/roster                     → ./view-v1.md §4                                003 FR-018
GET    /v1/view/channels                   → ./channels-v1.md §5.2                          003 FR-025
GET    /v1/view/topics                     → ./view-v1.md §4.3 (was /threads, 57f8a670)     003 FR-018, FR-026
GET    /v1/view/topics/{task_id}           → ./view-v1.md §4.4                              003 FR-018
GET    /v1/view/topics/{task_id}/children  → ./view-v1.md §4.5                              003 FR-026
GET    /v1/view/search                     → ./search-v1.md                                 003 FR-029
GET    /v1/view/search/operators           → ./search-v1.md §6                              003 FR-031
GET    /v1/view/me                         the reader's roles and permissions               025
*      /v1/view/* (anything else)          404 on GET/HEAD, 405 method_not_allowed else     003 FR-019
```

### 1.4 Browser plane: writes

```
DELETE /v1/files/{file_id}                        upload token; 204 / 404 → ./wui-live-ws.md §5   003 (owner goal)
POST   /v1/channels                               create → ./channels-v1.md §5.1                   003 FR-025
PATCH  /v1/channels/{channel}                     members_open_invite → ./channels-v1.md §7.4      003
GET    /v1/channels/{channel}/members             → ./channels-v1.md §7.4                          003, 025
POST   /v1/channels/{channel}/members             add a human → ./channels-v1.md §7.4              003
DELETE /v1/channels/{channel}/members/{human_id}  remove a human → ./channels-v1.md §7.4           003
POST   /v1/channels/{channel}/agents              seat an agent → ./channels-v1.md §7.4            003, 038
DELETE /v1/channels/{channel}/agents/{box}/{id}   take an agent out → ./channels-v1.md §7.4        003
PATCH  /v1/messages/{msg_id}                      edit                                             032
DELETE /v1/messages/{msg_id}                      delete                                           032
PUT    /v1/messages/{msg_id}/reactions            add an emoji → §1a                               003 FR-033 (owner: Q3)
DELETE /v1/messages/{msg_id}/reactions            remove an emoji → §1a                            003 FR-033 (owner: Q3)
GET    /v1/members                                tenant members                                   025
POST   /v1/members/invites                        invite                                           025
DELETE /v1/members/invites                        revoke an invite                                 025
PUT    /v1/members/{human_id}/role                set a role                                       025
DELETE /v1/members/{human_id}                     remove a member                                  025
POST   /v1/members/{human_id}/password-reset      mail a reset link, sign out (t1 ea0af569)        025
OPTIONS (preflight for each browser route above)  CORS, allow-listed origins only                  003 FR-021
```

### 1.5 Account and checkout (not tenant-scoped)

```
GET    /api/v1/auth/providers | session | avatar                           (cond: auth)      010
POST   /api/v1/auth/logout ; PUT /api/v1/auth/preferences                  (cond: auth)      010, 021
GET    /api/v1/auth/{provider}/start | /{provider}/callback                (cond: auth)      010, 018, 019
POST   /api/v1/auth/facebook/deauthorize | data-deletion ; GET …/data-deletion   (cond: auth)  010
POST   /api/v1/auth/register | email/verify | login | password/forgot | password/reset | password/change   (cond: auth)  015
GET    /api/v1/auth/keys ; POST /api/v1/auth/keys ; GET …/keys/{id}/public ; POST …/keys/{id}/revoke      (cond: auth)  023
GET    /api/v1/checkout/plan ; POST /api/v1/checkout ; GET /api/v1/checkout/{checkout_id} ; POST …/claim  (cond: payments)  006, 009
POST   /api/v1/checkout/fake-pay (never prd) | /api/v1/checkout/paypal/capture (PayPal on)               (cond: payments)  006
POST   /api/v1/webhooks/payment/stripe | /api/v1/webhooks/payment/paypal                                   (cond: payments)  006
```

`/healthz` on Cloud Run: Cloud Run reserves some URL paths ending in `z`, and
on the deployed dev service the ingress is `internal-and-cloud-load-balancing`
with no LB yet (007 step 10), so a direct `curl …/healthz` on the `run.app`
URL returns a Google 404 page today (measured 2026-09-18, n=1). Whether
`/healthz` survives behind the LB is unverified, so `GET /v1/health` is the
path for the LB health check (T032).

**Removed** (OQ-02, OQ-04). They are listed so that nobody implements them from
an old copy:

| Endpoint | Why removed |
|---|---|
| `POST /v1/messages` | send is the WS envelope (OQ-02); no per-agent `sig` exists in hub mode |
| `GET /v1/messages?as=&task_id=` | recv is WS frames after the box hello (OQ-02) |
| `POST /v1/recv` | same; 006 T008–T010 are rewritten to WS |
| `GET /v1/events` (SSE) | live tail is frames on the existing WS (OQ-04) |

`PATCH` / `DELETE /v1/messages/{msg_id}` (032) and the reaction routes (§1a)
act on a stored message; they do not revive `POST /v1/messages`.

## 1a. Reactions (FR-033, contract note, sync 2026-09-25)

Documents the implemented behaviour (`374a36e0`, `internal/hub/reactions.go`);
the owning spec is owner question Q3 in `../spec.md`.

- `PUT /v1/messages/{msg_id}/reactions` adds, `DELETE` removes; body `{"emoji":"<glyph>"}`
  either way. `msg_id` is a UUID (else `400 bad_json`); the glyph must be one the
  WUI offers (`validEmoji`, else `400 bad_emoji`).
- Door: a member session (none → `403`); the message must be readable under the
  topic read door (`canReadTopic`), otherwise `404 not_found`, so a refusal does
  not confirm the message exists. Unpaid tenant → `402 unpaid`.
- `200` body: `{ "msg_id", "task_id", "reactions": [ { "emoji", "actors": ["HUM-…"] } ] }`,
  one entry per emoji in first-added order, actors sorted; `[]` when none remain.
- Idempotent: re-adding the same emoji is a no-op (PK `(tenant_id, msg_id, actor, emoji)`,
  rdb `0037_message_reactions`); deleting the message deletes its reactions.
- Live: a `message_reaction` frame (`./wui-live-ws.md` §3.2) to every browser
  socket that was shown the message, the actor's other tabs included.
- CORS preflight `OPTIONS …/reactions` → `Access-Control-Allow-Methods: PUT, DELETE`.
- Check: `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -run 'TestReactionOnOpeningAndReply|TestValidEmoji' ./internal/hub`
  → PASS (n=1, memory store, 2026-09-25, tree `bbe04d26`).

## 2. WS `/v1/ws`

Every frame is one JSON text message with a `type` discriminator. Unknown
`type` → error frame `bad_frame`; the socket stays open.

### 2.1 Frame catalogue

| # | Direction | `type` | Fields | Hub rule |
|---|---|---|---|---|
| 1 | hub → box | `challenge` | `nonce` | sent once, immediately after the upgrade. `nonce` = 32 random bytes, base64. Single use, bound to this socket |
| 2 | box → hub | `hello` | `box_id`, `ts`, `nonce`, `sig`, `role`, `agents`, `channels?` | first frame, within 10 s, else close `4408`. See §2.2 |
| 3 | hub → box | `welcome` | `box_id`, `upload_token`, `upload_token_expires_at`, `roster` | hello accepted. `roster` = tenant roster (§2.3) |
| 4 | box → hub | `announce` | `agents`, `channels?` | `role=box` only. Replaces this box's announced set (and, M3, its channel subscriptions: `./channels-v1.md` §3). Duplicate id in the list → error `roster_duplicate` (409) |
| 5 | hub → box | `roster` | `roster` | pushed to every `role=box` socket of the tenant when any box's set changes |
| 6 | box → hub | `send` | `env` | §2.4. Reply is frame 7 or an `error` frame carrying the same `msg_id` |
| 7 | hub → box | `sent` | `msg_id`, `task_id`, `ts`, `to_box`, `delivery` | `delivery` ∈ `sent`, `queued` |
| 8 | hub → box | `recv` | `env`, `agents?` | the stored envelope, byte-for-byte as the sender signed it. Only to `role=box` sockets. `agents` (M3) is set only on a mention-routed channel delivery whose `to_box` is another box: the local agents addressed (`./channels-v1.md` §4) |
| 8a | hub → box | `queue_end` | `count` | after the queued `recv` frames that follow a `role=box` welcome; lets a one-shot `hub-sync` stop |
| 9 | box → hub | `tail` | `task_id`, `follow` | tenant-scoped read of one task |
| 10 | hub → box | `tail_msg` | `env` | one per stored message of the task, oldest first |
| 11 | hub → box | `tail_end` | `task_id`, `count` | end of the stored part; with `follow=true` live `tail_msg` frames continue |
| 12 | box → hub | `token` | — | asks for a fresh upload token |
| 13 | hub → box | `token` | `upload_token`, `upload_token_expires_at` | |
| 14 | hub → box | `error` | `error`, `status`, `detail`, `msg_id?` | stable token per `./error-envelope.md` |

Liveness uses WebSocket ping/pong control frames, not JSON frames.

### 2.2 Hello: challenge-response (OQ-03b)

```json
{ "type": "hello", "box_id": "box-a", "ts": "2026-09-18T12:00:00Z",
  "nonce": "<the challenge nonce>", "role": "box",
  "agents": ["CLE-07", "GRK-03"], "sig": "<base64 ed25519>" }
```

- `sig` = Ed25519 by the **box** key over `jq -cS '{box_id,nonce,ts}'`
  (002 `contracts/canonical-json.md`).
- `nonce` must equal the one this socket was challenged with, so a captured
  hello cannot be replayed on another socket (`4401 bad_nonce`).
- `|hub clock − ts| ≤ 300 s`, else close `4401 stale_hello`.
- The pin `(tenant, box_id)` must exist and not be revoked, else close
  `4401 unpinned_box`. A bad `sig` closes `4401 bad_sig`. Nothing is stored
  for a refused hello.
- `role`:
  - `box` — the box's **session** socket, held by the box daemon
    (`spool hub-run`) or a one-shot `spool hub-sync`. It receives `recv`
    frames, announces the `roster`, and drains the hub queue. **Last hello
    wins**: a newer `role=box` hello for the same `box_id` closes the older
    socket with `4409 superseded`.
  - `cli` — a one-shot sender (a `spool send` process). It may `send`, `tail`
    and ask for a `token`. It never receives `recv` frames, never announces a
    roster, and never evicts the session socket. *(ORC clarification
    2026-09-18, also noted in trust-modes §4: without this, every CLI send
    would evict the box daemon under last-hello-wins.)*
- On accept the hub updates `boxes.last_hello_at`, replies `welcome`, then
  (for `role=box`) pushes every queued `recv` frame for this box, oldest
  first, followed by `queue_end`.

### 2.3 Roster

The tenant roster is `{ "<box_id>": ["<agent_id>", ...], ... }`, from each
box's last announcement (persisted, so it survives the box going offline). The
box caches it (`$SPOOL_ROOT/.hub/roster.json`) so it can resolve `to_box`
while the hub is unreachable. Same id on two boxes is legal (`CLE-07@box-a` ≠
`CLE-07@box-b`).

### 2.4 Send envelope (OQ-03a)

```json
{ "type": "send",
  "env": { "from_box": "box-a", "to_box": "box-b",
           "msg": { "v": 1, "msg_id": "…", "from": "GRK-03", "to": "CLE-07", "…": "…" },
           "sig": "<base64 ed25519 of jq -cS '{from_box,to_box,msg}'>" } }
```

- The **sender resolves `to_box` locally** (explicit `--to-box`, else the
  cached roster) and includes it **before signing**. The hub **never** fills
  or rewrites a signed field.
- Hub checks, in order: `from_box` == hello box (`bad_sig`, 400); `msg`
  validates as `v:1` (`bad_json`, 400); `sig` verifies against the `from_box`
  pin (`bad_sig`, 400); `to_box` present (`missing_to_box`, 400) — when it is
  absent and `msg.to` is announced on more than one box the error is
  `ambiguous_to_box` (409); `to_box` pinned in the tenant (`unpinned_box`,
  404); every `blob` `file_id` is held by the hub unless
  `hub.allow_text_only_when_file_missing` is true (`missing_file`, 400; OQ-11);
  idempotent insert on `(tenant_id, msg_id)` (`conflict_msg`, 409 when the
  canonical envelope differs; same canonical → the original result again).
- Then: `to_box` has a live `role=box` socket → push `recv`, reply
  `delivery=sent`. Otherwise store a `deliveries` row (7-day TTL) and reply
  `delivery=queued`. Either way the send is a success.
- The hub's responsibility **ends at frame delivery** (OQ-08). There is no ack
  frame; `spool-recv --ack` archives on the box only.
- **M3 optional fields** (`./channels-v1.md` §2): the envelope may carry
  `channel` and `parent_task_id` beside `to_box`. When present they are
  signed too (`jq -cS` of `{from_box,to_box,msg}` plus each present field);
  when absent the envelope and its signing payload are exactly the ones above,
  so every pre-M3 box and envelope keeps working.
- The receiving box re-verifies `sig` over the exact `{from_box,to_box,msg}`
  against its **locally synced** pin (`$SPOOL_ROOT/pins/box-<id>.pub`).
  Missing pin or bad `sig` → it refuses the frame (`78`) and writes nothing,
  even though the hub stored it.

### 2.5 Close codes

| code | token | when |
|---|---|---|
| `1000` | — | normal close |
| `1001` | — | hub shutdown (graceful drain) |
| `4400` | `bad_frame` | first frame not a well-formed `hello` |
| `4401` | `unpinned_box` / `bad_sig` / `stale_hello` / `bad_nonce` | hello refused |
| `4404` | `unknown_tenant` | Host does not resolve to a tenant (refused before the upgrade as HTTP 404) |
| `4408` | `hello_timeout` | no hello within 10 s |
| `4409` | `superseded` | a newer `role=box` hello for the same `box_id` (last hello wins) |

### 2.6 Reconnect contract (OQ-05)

- M1 runs Cloud Run with **`max-instances=1`** (cnf, overridable), so every
  box socket terminates on one instance and no cross-instance fan-out exists.
- Cloud Run caps a WS at its request timeout (≤ 60 min). The box reconnects on
  any close or read error with exponential backoff (1 s doubling, cap
  **30 s**, jitter), then re-hellos with a fresh nonce, re-announces its
  roster, re-syncs pins, and **flushes** its pending outbox (`./flush.md`).
  The backoff resets after an accepted hello. A socket closed `4409
  superseded` does not reconnect: a newer session owns the box.
- Cross-instance fan-out (Postgres `LISTEN/NOTIFY` or Pub/Sub) is **post-M1**.

## 3. POST /v1/files / GET /v1/files/{file_id}

- POST requires `Authorization: Bearer <upload_token>` (OQ-10). The token is
  minted by the hub on `welcome` / `token`, bound to `(tenant, box_id)`, TTL
  **5 minutes**, reusable until expiry, never logged. It is held in hub memory
  (valid under `max-instances=1`; a restart simply makes the box ask again).
  No or bad token → `401 door`. Anonymous PUT is forbidden.
- Body = raw bytes (`application/octet-stream`), ≤ the per-file limit
  (`./limits.md`), else `413 limit_file`.
- Bytes stored at `t/<tenant_id>/files/<sha256>` in **one** bucket. No
  metadata object. The hub computes `file_id` = sha256 of the received bytes
  and replies `201 { "file_id", "sha256", "bytes" }`.
- GET needs a caller credential of the Host tenant (017 FR-SEC-002; the
  sha256 alone is **not** a capability): `Authorization: Bearer <upload_token>`
  (a pinned box or `box-wui`, as for POST) or a member session cookie (view
  door `session`). None, a bad/expired token or another tenant's →
  `401 view_door`, checked before the lookup (no existence oracle). With a
  credential, another tenant's `file_id` → 404. View door `off` (lde only)
  admits anonymous GET.
- M1 GET streams the bytes. A short-lived signed URL (TTL in `./limits.md`)
  is allowed later; it is never logged or persisted (Constitution VII). The box
  CLI re-hashes and refuses a mismatch (`78`) without writing a partial file.

## 4. Pins (owned by 004 / 006, hosted here)

- `GET /v1/pins` with the upload token → `{ "pins": [ { "box_id", "pubkey" } ] }`
  (base64 raw 32-byte keys, revoked pins omitted). The box writes each to
  `$SPOOL_ROOT/pins/box-<id>.pub`.
- `POST /v1/pins` body `{ "box_id", "pubkey", "ts", "force", "sig" }`, `sig` =
  tenant **root** key over `jq -cS '{box_id,force,pubkey,ts}'`, `ts` ± 300 s.
  Same key → 200; different key without `force` → `409 pin_conflict` (also
  any key onto a **revoked** pin without `force`). A signed `ts` not later
  than the pin's last op → `409 stale_pin_op` (replay). Semantics of record:
  `../../004-spool-identity-routing/contracts/pin-semantics.md` §2, §5.
- `DELETE /v1/pins/{box_id}` body `{ "box_id", "ts", "sig" }`, `sig` over
  `jq -cS '{box_id,op:"revoke",ts}'`. A revoked box's hello is refused.
  Revoking an already revoked pin → 200 no-op; a stale `ts` → `409 stale_pin_op`.

## 5. Trust & ingress

- **Box key** is both the door and the author: hello (challenge-response),
  envelope, and — through the WS-issued token — the file PUT. The hub does not
  verify agent identity; `from` is asserted by the box.
- **Tenant root key** only pins/revokes box pubkeys.
- **IAM/OIDC** is not in M1 (OQ-06). `boxes.iam_principal` is reserved.
- Same-box mail does not touch the hub (`delivery=local`) unless
  `$SPOOL_MIRROR_LOCAL` is true (`./flush.md`).

## 6. Failure semantics

| Failure | Response |
|---|---|
| unpinned or revoked box at hello | close `4401 unpinned_box`; nothing stored |
| bad envelope `sig`, or `from_box` ≠ hello box | error `bad_sig`, nothing stored; CLI exit `78` |
| `to_box` absent and `to` ambiguous | error `ambiguous_to_box` (409), nothing stored |
| `to_box` has no live socket | persist with 7-day TTL, `delivery=queued` (not an error) |
| `file_id` not held by the hub | error `missing_file` (400) unless the cnf flag allows text-only |
| GCS down | refuse file PUT (exit `1`) |
| hub unreachable | box keeps cross-box sends pending-flush, `delivery=pending`, exit `0` (`./flush.md`) |

## 7. Invariants

- Same inner `v:1` JSON on the wire as `002` writes to disk (no migration).
- The hub stores and forwards the envelope it verified; it never mutates a
  signed field.
- Cloud Run is stateless: no mail, queue or file bytes on container disk. The
  live-socket map and upload tokens are per-process memory, rebuilt on reconnect.
- Kind of agent is not a field, only the `from`/`to` id prefix. No per-kind routes.
- The only browser-facing surface is `./view-v1.md` (read-only). It never
  reintroduces the removed REST send/recv rows of §1.

<!-- version: 0.6.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:26:14Z -->
