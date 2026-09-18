# Contract: Read-only viewer API v1 (the WUI's hub read dependency)

Feature: `003-spool-message-bus`, User Story 7. Consumer: `../../005-spool-wui/`
(it cites this file and does not restate it; seam in `../../README.md` §5).

**Status: Implemented except the view token (§2, OQ-16).** Routes in
`csi-spl-api/src/go/spool-hub-api/internal/hub/view.go`, store queries in
`internal/store/view.go` / `view_postgres.go`; tests `TestViewAPI`,
`TestViewDoorTokenFailsClosed`, `TestViewReads` (memory + Postgres).
Until OQ-16 is decided the `token` door **fails closed** (every request
`401 view_door`); lde runs with the door `off`.

Normative order: `../../002-box-agent-messaging/contracts/trust-modes.md`, then
`../spec.md` (FR-018 – FR-022), then this file, then `./http-v1.md` (shared
tenant, error and file rules).

## 0. What this is, and what it is not

- A **read-only window** onto what the hub already stores: the tenant's boxes
  and roster, and the message threads (`task_id`) with their envelopes.
- **Not a recv dialect.** OQ-02 deleted `GET /v1/messages?as=` and
  `POST /v1/recv`; they stay deleted. A viewer read never delivers, never
  drains or claims a queued `deliveries` row, never marks anything `sent`,
  never touches `roster`, `boxes.last_hello_at` or pins. Two reads of the same
  cursor return the same bytes.
- **Not a send path.** Human send (`HUM-<name>` via a hub-held `box-wui` key,
  `SPEC-spool-wui.md` §4) and channel creation are M3 **write** features of
  005 and are out of this contract. Nothing under `/v1/view/` accepts a body.
- **Not the box door.** The browser never opens `/v1/ws` (Ed25519 box door,
  `./http-v1.md` §2) and never holds a box key.

## 1. Endpoint inventory

```
GET  /v1/view/roster                      boxes, pins (pubkeys), announced agents, online    FR-019
GET  /v1/view/channels                    channels seen in stored messages, with counts      FR-019
GET  /v1/view/threads                     thread list, newest activity first, paged          FR-019
GET  /v1/view/threads/{task_id}           one thread's envelopes, oldest first, paged        FR-019
GET  /v1/files/{file_id}                  unchanged (./http-v1.md §3): tenant capability      FR-007
```

Every other method on `/v1/view/*` → `405 method_not_allowed`. Tenant = request
**Host**, exactly as `./http-v1.md` (006 owns the resolution; unknown →
`404 unknown_tenant`).

## 2. Door: the view token (FR-020)

Door mode is cnf `SPOOL_HUB_VIEW_DOOR`: `token` (default) or `off`. The hub
**refuses to start** with `off` unless `SPOOL_HUB_ENV=lde`, so dev/prd can
never run without a door. With `off`, no `Authorization` is checked.

`Authorization: Bearer <view_token>` on every `/v1/view/*` request. Missing,
malformed, expired, wrong scope or wrong tenant → `401 view_door`.

**PROPOSED — owner to confirm** (`../spec.md` OQ-16, raised 2026-09-18):

```
view_token = b64url(payload_json) "." b64url(sig)
payload    = { "tenant": "<tenant_id>", "scope": "view", "exp": "<RFC3339 UTC>" }
sig        = ed25519 by the tenant ROOT key over jq -cS '{exp,scope,tenant}'
```

- The hub verifies against `tenants.root_pubkey` (already stored for pin
  verification), requires `tenant` == Host tenant, `scope == "view"`,
  `now < exp ≤ now + hub.view_token_max_ttl` (cnf; default 12 h).
- Stateless: nothing stored, nothing minted by the hub, no new secret in
  Secret Manager. Revocation = rotate the tenant root (006) or wait for `exp`.
- Minted offline by the tenant owner with a new CLI verb
  `spool hub-view-token --ttl <dur>` (root key, never sent anywhere).
- The browser keeps it in memory / `sessionStorage`, never `localStorage`,
  never in a URL (so it never lands in an access log). The hub redacts the
  `Authorization` header in logs (Constitution VII).
- **M3 successor:** the social-auth session (spec `010-spool-social-auth`,
  mounted at `/api/v1/auth/*` since this version) becomes a second accepted
  door for the same endpoints; it does not change the response shapes. The
  view token remains for headless operators.
- **OQ-A1 (decided by 003, 2026-09-18):** option (a) — the session cookie is
  scoped to the product domain (`SPOOL_HUB_AUTH_COOKIE_DOMAIN`, cnf) so every
  tenant host receives it, and §3 CORS adds
  `Access-Control-Allow-Credentials: true` **for the allow-listed origins
  only** (the list stays exact-match, never reflected, never `*`).
  **Gate:** neither the session door nor credentialed CORS is switched on
  until spec 010 T013 exists — a session proves *who* signed in, not *which
  tenant* they may read; `session.t` is caller-supplied and is never an
  authorisation (010 SEC-001). Until then a session admits nothing here.

## 3. CORS (FR-021)

The WUI is served from Firebase Hosting, a different origin from the hub.

- Allowed origins come from cnf `SPOOL_HUB_VIEW_CORS_ORIGINS` (comma list of
  bare `http(s)://host[:port]`, validated at start; **no default**;
  empty → no CORS headers, same-origin only). Never `*`.
- Applies to `/v1/view/*` and `GET /v1/files/{file_id}` only. `/v1/ws`,
  `POST /v1/files` and `/v1/pins` never answer CORS.
- (Until the OQ-A1 gate opens.) Preflight `OPTIONS` → `204` with `Access-Control-Allow-Methods: GET`,
  `Access-Control-Allow-Headers: Authorization`, `Access-Control-Max-Age: 600`,
  `Vary: Origin`. No credentials mode (the token is a header, not a cookie).

## 4. Shapes

Times are RFC3339 UTC; `first_ts` / `last_ts` / `received_at` are **hub receive
times** (the message's own `ts` is inside `env.msg`). Cursors are **opaque** strings (the hub encodes
`(received_at, msg_id)`); a cursor the hub cannot decode → `400 bad_cursor`.
`limit` default 50, max 200 (`./limits.md`); above max → clamped, not an error.

### 4.1 `GET /v1/view/roster`

```json
{ "boxes": [
  { "box_id": "box-a", "pubkey": "<base64 32 bytes>", "revoked": false,
    "last_hello_at": "2026-09-18T12:00:00Z", "online": true,
    "agents": ["CLE-07", "GRK-03"] } ] }
```

`online` = a live `role=box` socket for that box on this instance (valid under
`max-instances=1`, FR-017). Revoked pins are listed with `revoked: true` and
`online: false`. `pubkey` lets the viewer re-verify envelope `sig`s
client-side (optional; the hub already verified them at ingest).

### 4.2 `GET /v1/view/channels`

```json
{ "channels": [ { "channel": "alerts", "count": 12, "last_ts": "…" } ] }
```

Distinct non-null `messages.channel` in retention. In M1 `channel` is always
NULL, so the list is empty; M3 channel metadata (`channels` table,
`0002_channels.sql`) is joined in when 005 starts writing it.

### 4.3 `GET /v1/view/threads?limit=&before=&channel=&agent=`

```json
{ "threads": [
  { "task_id": "…", "parent_task_id": null, "channel": null,
    "first_ts": "…", "last_ts": "…", "count": 4,
    "kinds": { "task": 1, "result": 1, "note": 2 },
    "participants": ["GRK-03@box-a", "CLE-07@box-b"],
    "subject": "<first line of the first body, ≤ 140 chars>" } ],
  "next": "<cursor or null>" }
```

Ordered by `last_ts` descending; `before` pages to older threads.
`channel=` filters on `messages.channel`; `agent=` matches `from_id` or
`to_id`. Only messages still in retention (`./limits.md`) are counted.

### 4.4 `GET /v1/view/threads/{task_id}?limit=&after=`

```json
{ "task_id": "…",
  "messages": [
    { "cursor": "…", "received_at": "…",
      "env": { "from_box": "box-a", "to_box": "box-b", "msg": { "v": 1, "…": "…" }, "sig": "…" },
      "deliveries": [ { "to_box": "box-b", "state": "sent" } ] } ],
  "next": "<cursor or null>" }
```

- Oldest first. `env` is the stored envelope **byte-for-byte** as verified at
  ingest (the same bytes a `tail_msg` frame carries). File refs only; bytes
  come from `GET /v1/files/{file_id}`.
- `deliveries[].state` ∈ `queued | sent | expired` (the hub-side row,
  `../data-model.md` §2a) — shown, never changed.
- Unknown or purged `task_id` → `404 not_found`.
- **Live updates** (first cut): the viewer polls with `after=<last cursor>`
  no more often than every 2 s. A browser tail socket (`/v1/view/ws`, reusing
  the `tail_msg` frame shape) is **post-first-cut** and needs its own FR.

## 5. Hygiene and limits

- Tenant-scoped on every query (FR-015); a `task_id` of another tenant is
  `404 not_found`, never `403`.
- No file bytes, no signed URLs, no tokens in any response or log line
  (FR-011, FR-014).
- The hub may answer `429 quota` per 006's quota rules; the viewer backs off.

## 6. Error tokens added by this contract

`view_door` (401), `bad_cursor` (400), `method_not_allowed` (405). Existing
tokens reused: `unknown_tenant`, `not_found`, `quota`, `unpaid` (006 decides
whether reads are gated while `unpaid`; this contract does not gate them).

## 7. The WUI client today (drift to close in 005, not here)

Measured on trunk `bbc41e7`: `grep -c "/v1/messages\|/v1/channels" csi-spl-wui/utils/spool-client.mjs -> 4`
(`live('/v1/channels')`, `live('/v1/messages?…')`, a `POST /v1/messages`,
a `POST /v1/channels`). None of those routes exists on the hub
(`grep -c 'v1/messages\|v1/channels' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go -> 0`).
The read calls map onto §4.2–§4.4; the two POSTs are 005 M3 write features.

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:35:34Z -->
