# Contract: Read-only viewer API v1 (the WUI's hub read dependency)

Feature: `003-spool-message-bus`, User Story 7. Consumer: `../../005-spool-wui/`
(it cites this file and does not restate it; seam in `../../README.md` §5).

**Status: Implemented** (session door; OQ-16 resolved 2026-09-19 — the view token of §2 was superseded and never built, T033). Routes renamed `threads` -> `topics` in `57f8a670` (2026-09-23): `grep -c 'HandleFunc("GET /v1/view/topics' csi-spl-api/src/go/spool-hub-api/internal/hub/view.go` -> 3; `/v1/view/threads` now answers `404`. v0.5 (M3 WIRE): channel list with unread + members (§4.2), roots / DMs (§4.3), children (§4.5) — `TestChannelEnvelopeStored`, `TestStoreChannels`. Routes in
`csi-spl-api/src/go/spool-hub-api/internal/hub/view.go`, store queries in
`internal/store/view.go` / `view_postgres.go`; tests `TestViewAPI`,
`TestViewDoorTokenFailsClosed`, `TestSessionDoorMemberReadsNonMemberRefused`,
`TestViewReads` (memory + Postgres). Dev and prd run `session`; the `token`
mode admits only a member session (no token parser exists; keep or remove is
owner question Q1 in `../spec.md`); lde runs with the door `off`.

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
- **Not a send path.** Human send (`./wui-live-ws.md`) and channel creation
  (`POST /v1/channels`, `./channels-v1.md` §5.1) live outside `/v1/view/`.
  The one call under `/v1/view/` that reads a body is `POST /v1/view/ids`
  (§4.6): a list of ids to resolve, not a message to store.
- **Not the box door.** The browser never opens `/v1/ws` (Ed25519 box door,
  `./http-v1.md` §2) and never holds a box key.

## 1. Endpoint inventory

```
GET  /v1/view/roster                      boxes, pins, agents, online; member humans + avatar FR-019
GET  /v1/view/channels                    defaults + created + seen channels, unread, members FR-019, FR-025
GET  /v1/view/topics                     root threads (or DMs), newest activity first, paged FR-019, FR-026
                                          (+ per_topic=N: each topic's newest N messages inline, §4.3)
GET  /v1/view/topics/{task_id}           one thread's envelopes, oldest first, paged        FR-019
GET  /v1/view/topics/{task_id}/children  child threads of a task (parent_task_id), paged    FR-026
GET  /v1/files/{file_id}                  ./http-v1.md §3: upload token or member session     FR-007
GET  /v1/view/search                      ./search-v1.md: one Gmail-style grammar, grouped     FR-029
GET  /v1/view/search/operators            ./search-v1.md §6: the grammar as data              FR-031
GET  /v1/view/me                          the reader's roles and permissions                  025
POST /v1/view/ids                         the ids quoted in one body, resolved (§4.6)          HUM-10
```

Every other method on `/v1/view/*` (`POST /v1/view/ids` excepted) → `405 method_not_allowed`; an unknown GET
path → `404 not_found`. Tenant = the member session's tenant (026,
`./http-v1.md` header note); unknown → `404 unknown_tenant`.

## 2. Door (FR-020): the member session; the view token is superseded

**Resolved (OQ-16, owner 2026-09-19):** dev and prd run `session` — member
sessions only, credentialed CORS for exact allow-listed origins (010 FR-009,
003 T033b). `yq -r '.env.hub.env.SPOOL_HUB_VIEW_DOOR' csi-spl-cnf/csi-spl/prd.env.yaml`
→ `session`. The token text below was never built and is kept for the record.

Door mode is cnf `SPOOL_HUB_VIEW_DOOR`: `token` (default), `session` or `off`
(`internal/config/config.go:254`, validated at `:362`–`:370`). The hub
**refuses to start** with `off` unless `SPOOL_HUB_ENV` is `lde` or `dev`
(ORC decision 2026-09-18: dev reads are open so the WUI renders now); **prd
never runs without a door**; prd runs `session` (OQ-16 resolved 2026-09-19). With `off`, no `Authorization` is checked.

`Authorization: Bearer <view_token>` on every `/v1/view/*` request. Missing,
malformed, expired, wrong scope or wrong tenant → `401 view_door`.

**SUPERSEDED — kept for the record** (was PROPOSED, `../spec.md` OQ-16, raised 2026-09-18):

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
  The door check is wired (`auth.SessionForTenant`, fail-closed on every
  error); it opens only when a membership check is configured.

## 3. CORS (FR-021)

The WUI is served from Firebase Hosting, a different origin from the hub.

- Allowed origins come from cnf `SPOOL_HUB_VIEW_CORS_ORIGINS` (comma list of
  bare `http(s)://host[:port]`, validated at start; **no default**;
  empty → no CORS headers, same-origin only). Never `*`.
- Applies to `/v1/view/*` and to browser file routes (`GET`/`POST`/`DELETE`
  `/v1/files`, `./wui-live-ws.md` §5). `/v1/ws` (box door) and `/v1/pins`
  never answer CORS. `OPTIONS /v1/files` and `OPTIONS /v1/files/{file_id}`
  → `204` with `Access-Control-Allow-Methods: GET, POST, DELETE`
  (`filesPreflight`; `command grep -n 'Allow-Methods", "GET, POST, DELETE"'
  csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go` → `wui.go:759`;
  `command grep -n 'OPTIONS /v1/files' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go`
  → `mux.HandleFunc("OPTIONS /v1/files", s.filesPreflight)`).
- View preflight `OPTIONS /v1/view/*` → `204` with `Access-Control-Allow-Methods: GET`,
  `Access-Control-Allow-Headers: Authorization, X-Locale` (`internal/hub/view.go:87`), `Access-Control-Max-Age: 600`,
  `Vary: Origin`. No credentials mode on the token door (the token is a header,
  not a cookie). Session-door credentialed CORS is 003 T033b.

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
    "agents": ["CLE-07", "GRK-03"],
    "facts_reported_at": "2026-10-04T12:00:00Z",
    "os": { "name": "Debian GNU/Linux", "version": "13",
            "pretty": "Debian GNU/Linux 13 (trixie)",
            "kernel": "6.12.111+deb13-cloud-amd64", "arch": "amd64" },
    "runtimes": { "go": "1.25.1", "node": "22.1.0", "python": "3.13.5",
                  "git": "2.47.3", "spool": "8.9.6", "claude": "2.1.3" },
    "system": { "hostname": "box-a", "timezone": "Europe/Helsinki",
                "boot_at": "2026-10-02T13:58:04Z", "cpus": 16,
                "cpu_model": "AMD EPYC 7B12", "load": "0.12 0.20 0.30",
                "mem_total_mb": 64305, "mem_avail_mb": 40756,
                "swap_total_mb": 2048, "swap_free_mb": 1024, "state": "running" },
    "network": { "ips": ["10.0.0.2"], "gateway": "10.0.0.1",
                 "dns": ["169.254.169.254"] },
    "agent_presence": {
      "CLE-07": { "state": "online", "last_seen": "2026-09-18T12:00:00Z" },
      "GRK-03": { "state": "online", "last_seen": "2026-09-18T12:00:00Z" } } } ],
  "humans": [
  { "human_id": "HUM-3", "avatar_file_id": "<sha256 hex, 64 chars>", "owner": true },
  { "human_id": "HUM-4", "avatar_file_id": null } ] }
```

`online` = a live `role=box` socket for that box on this instance (valid under
`max-instances=1`, FR-017). Revoked pins are listed with `revoked: true` and
`online: false`. `pubkey` lets a client re-verify envelope `sig`s it
received whole (a `tail_msg` frame; the hub already verified them at ingest).
The §4.4 view `env` carries no `sig` since DB payload cut 4.

`os`, `runtimes`, `system`, `network` and `facts_reported_at` are the box's
fact sheet (t1 f77c9f87, d1d9bcd3: what a Unix admin reads first when
troubleshooting a box), sent in the `host` field of its role=box hello. The
box collects it at most once a day (owner: "once per day - no more often"),
keeps it in `$SPOOL_ROOT/.hub/host-facts.json` and re-sends that sheet on
every hello; `facts_reported_at` is when it was collected, so `load`,
`mem_avail_mb`, `swap_free_mb` and `state` are snapshots of that moment.

- `os`: `name`, `version`, `pretty` (os-release), `kernel`, `arch`.
- `runtimes`: run-time or CLI name (`go`, `node`, `python`, `git`, `spool`,
  `docker`, `claude`, `grok`, `qwen`, `agy`) to version; one the box lacks is
  absent. `spool` is the version of the box's running spool binary.
- `system`: `hostname`, `timezone`, `boot_at`, `cpus`, `cpu_model`, `load`
  (1/5/15 min), `mem_total_mb`, `mem_avail_mb`, `swap_total_mb`,
  `swap_free_mb` (MiB), `state` (`systemctl is-system-running`).
- `network`: `ips` (the box's own addresses, primary first; no public-IP
  lookup), `gateway`, `dns`.

Disk per mount is not here (the box-stats sample). Every key is omitted for
a box that has not sent a sheet to this hub process ("not reported yet": an
older binary, or a fresh revision before the box redials). The box is
untrusted: the hub keeps printable ASCII only, each string cut to 64 bytes,
run-time names `^[a-z][a-z0-9_-]{0,23}$` and at most 16 of them, at most 8
`ips` and 4 `dns` that parse as addresses, numbers in range and times not in
the future; a hostile field is cut, never a refused hello.

`agent_presence` maps each agent of `agents` to `{state, last_seen}`: `state`
is `online` or `offline` with its box, `last_seen` the box's presence stamp
(`last_hello_at`, `null` = never). Omitted when `agents` is empty.

`humans` (010 T044, gap A5) lists the member `HUM-*` of **this tenant only**
(disabled humans excluded), sorted by `human_id`; `[]` when the hub has no
010 tables or no members. `avatar_file_id` is the sign-in IdP picture the hub
fetched and stored as a tenant blob, or `null` (no picture: the viewer draws
the deterministic default, SPEC-spool-avatars §2). The viewer loads it with
`GET /v1/files/{avatar_file_id}` on the same tenant host, like any
attachment: a tenant capability, so another tenant's `file_id` is `404`
there, and the only listing of it is that tenant's own door-guarded roster.
A viewer falls back to the default on `404` or any load error.

`owner: true` marks a business owner (tenant role `biz_owner`, not disabled);
the key is omitted for every other member, and no other role is ever
exposed. It exists so any member can tag the owner(s) in `#feedback`
(channels-v1 §1) even while they are offline (owner, 2026-09-25).

### 4.2 `GET /v1/view/channels?read=<channel>~<cursor>`

```json
{ "channels": [ { "channel": "alerts", "name": "alerts", "description": "",
    "default": true,
    "retention_days": 7, "created_by": "hub", "count": 12, "last_ts": "…",
    "last_cursor": "…", "unread": 2,
    "members": { "agents": 3, "boxes": 2, "posters": 4 } } ] }
```

Every default channel (`lobby`, `alerts`, `feedback`), every created channel
(`channels` table) and any channel seen in stored messages, sorted by slug.
`channel` / `count` / `last_ts` keep their v0.4 meaning (`last_ts` is `null`
for an empty channel). `description` is `""` for a default channel and for
every channel created before rdb 0027. `read` (repeatable), `unread` and
`members`: `./channels-v1.md` §5.2.

### 4.3 `GET /v1/view/topics?limit=&before=&channel=&agent=&roots=&dm=&peer=`

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
`channel=` filters on `messages.channel` (`general` = `lobby`); `agent=` matches
`from_id` or `to_id`. Only messages still in retention (`./limits.md`) are counted.

- `parent_task_id` / `channel` are the **hub-envelope** fields of the thread's
  first message (`./channels-v1.md` §2), `null` when absent.
- **Roots by default** (v0.5): only threads whose `parent_task_id` is `null`.
  `roots=false` lists child threads too. Before M3 no message carries a
  parent, so the default list is unchanged for existing data.
- **DMs**: `dm=true` keeps only messages with no channel (`channel IS NULL`);
  `peer=<id>` or `peer=<id>@<box>` keeps threads with a message from or to that
  peer (`GET /v1/view/topics?dm=true&peer=CLE-07`). When the reader holds a
  member session (`HUM-*`), `dm=true` also requires the reader to be a party
  of the thread (private delivery); with door `off` there is no reader id and
  no such filter (lde/dev only). `dm` must be `true` or `false`, else
  `400 bad_json`.

- **`per_topic=N`** (1..50, v0.6.1, CLE-34985 - Implemented, hub
  `internal/hub/view.go` `inlineMessages`, store `ViewTopicsMessages`): every
  listed topic also carries `"messages"` and, when there are more,
  `"messages_next"` - byte-identical to that topic's
  `GET /v1/view/topics/{task_id}?order=desc&limit=N` `messages` / `next`
  (§4.4, same reader door, reactions and deliveries included). A channel page
  is then ONE request: before it the WUI made one §4.4 read per topic (7
  requests / 39 DB round trips for 6 topics; now 1 / 5, TestRoundTripsPerRequest).
  Without `per_topic` the shape is unchanged; `0`, `>50` or a non-number →
  `400 bad_json`. Oracle: `TestViewTopicsPerTopicMatchesTopicReads` (memory and
  Postgres). Also accepted on §4.5 `/children`.

### 4.4 `GET /v1/view/topics/{task_id}?limit=&after=` | `?order=desc&limit=&before=`

```json
{ "task_id": "…",
  "messages": [
    { "cursor": "…", "received_at": "…",
      "env": { "from_box": "box-a", "to_box": "box-b", "msg": { "v": 1, "…": "…" } },
      "deliveries": [ { "to_box": "box-b", "state": "sent" } ] } ],
  "next": "<cursor or null>" }
```

- Oldest first. `env` is the stored envelope as verified at ingest, less
  what **DB payload cut 4** (owner t1 66233cdc, 2026-10-02, hub `view.go`
  `trimEnv` / `viewMsgsIn`) leaves out of the view: `sig`, an empty
  `msg.files`, and `msg.task_id` when it equals this topic's `task_id`
  (kept on a moved row and on the archive cards, which span topics). The
  stored row, the WS frame and the spool keep the signed envelope whole.
  File refs only; bytes come from `GET /v1/files/{file_id}`.
- Also omitted while they hold their default (cut 4): `reactions` when
  nobody reacted (read `[]`), and `deliveries` when it is exactly
  `[{"to_box":"box-wui","state":"sent"}]`. A message with no delivery at all
  still sends `deliveries: []`. The WUI puts every default back in
  `utils/view-api.mjs` `normalizeViewMessage(el, topic)`.
- `deliveries[].state` ∈ `queued | sent | expired` (the hub-side row,
  `../data-model.md` §2a) — shown, never changed.
- Unknown or purged `task_id` → `404 not_found`.
- **Newest-first windows** (chat-reverse, `SPEC-spool-chat-reverse.md` §3):
  `order=desc` returns the newest `limit` messages **newest first**; `next` is
  the cursor of the oldest one returned — pass it as `before=` for the next
  older window, until `next` is `null`. `order` is `asc` (default) or `desc`,
  else `400 bad_json`. `after=` is **asc only** (reconnect catch-up) and
  `before=` is **desc only**; the wrong pairing is `400 bad_json`
  (`TestViewTopicDescWindows`, `TestViewReads`).
- **Live updates**: the browser socket is `/v1/wui/ws` (`./wui-live-ws.md`;
  `command grep -n "WS_PATH" csi-spl-wui/src/utils/live-ws.mjs` →
  `export const WS_PATH = '/v1/wui/ws'`). Reconnect catch-up may poll this
  section with `after=<last cursor>`.

### 4.5 `GET /v1/view/topics/{task_id}/children?limit=&before=`

Same shape and paging as §4.3 (`threads`, `next`), listing the threads whose
`parent_task_id` is `{task_id}`, newest activity first. Replies **within** a
thread are the thread's own messages (§4.4 pages them); children are the
separate tasks it spawned (`./channels-v1.md` §0). A parent with no children
answers `200 {"threads": [], "next": null}`; a non-UUID `task_id` is
`404 not_found`.

### 4.6 `POST /v1/view/ids` (HUM-10, topic cd357c76)

The ids quoted in ONE rendered body, resolved in one call, so an id the tab
has not loaded still becomes a link. Request `{"ids": [...]}`: up to 50
distinct tokens, each a uuid or its first 8 hex digits (any case);
anything else, or more than 50, is `400 bad_id` / `400 too_many`. Body
`application/json` (preflight: `POST`, `Content-Type`).

```json
{"ids": [{"id": "<token as asked>", "kind": "topic|message", "task_id": "<uuid>",
          "msg_id": "<uuid, message only>", "channel": "<id, omitted for a DM>",
          "peer": "<other DM end, id or id@box>", "archived": false}]}
```

- The door is a topic read's (§4.4): the session's tenant, an archived topic
  or message answers, a DM only to one of its ends, a channel row only to a
  reader of that channel. An id the reader may not read is left out, exactly
  like an unknown one.
- A topic id is `topic` even when a message carries the same string. A reply
  is `message` with its parent topic as `task_id`. A topic opens in its first
  channel the reader may read, else as their DM with `peer`.
- An 8-hex token names the topic when exactly one topic starts with it, else
  (no topic) the message when exactly one does; the count is over every row,
  so it is the same for every reader.
- One statement per call whatever the id count
  (`TestNPlus1RoundTripsViewIDs`).

## 5. Hygiene and limits

- Tenant-scoped on every query (FR-015); a `task_id` of another tenant is
  `404 not_found`, never `403`.
- No file bytes, no signed URLs, no tokens in any response or log line
  (FR-011, FR-014).
- The hub may answer `429 quota` per 006's quota rules; the viewer backs off.

## 6. Error tokens added by this contract

`view_door` (401), `bad_cursor` (400), `method_not_allowed` (405), and
`bad_channel` (400), `channel_exists` (409), `unknown_channel` (404) from
`./channels-v1.md`. Existing
tokens reused: `unknown_tenant`, `not_found`, `quota`, `unpaid` (006 decides
whether reads are gated while `unpaid`; this contract does not gate them).

## 7. The WUI client (005 closed the invented-route drift)

Measured on trunk `8ffb93c` (sources under `src/` since `fff663d`):
`command grep -c "/v1/messages\|/v1/channels" csi-spl-wui/src/utils/spool-client.mjs -> 0`.
Live reads go to `/v1/view/*`. Live send / channel-create still throw
`ReadOnlyError` (005 phase-3 / A1). The pre-`src/` path
`csi-spl-wui/utils/spool-client.mjs` does not exist.

<!-- version: 0.7.2 · updated: 2026-10-04 · last-edit: 2026-10-04T16:40:00Z -->
