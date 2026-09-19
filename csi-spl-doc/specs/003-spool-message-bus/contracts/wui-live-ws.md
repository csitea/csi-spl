# Contract: WUI live WebSocket v1 (browser <-> hub live chat, #lobby, channels, presence)

Feature: `003-spool-message-bus`, owner goal "live-chat MVP" (2026-09-18).
**Single source of truth** for the browser <-> hub live protocol. Consumer:
`../../005-spool-wui/` (`csi-spl-wui/utils/live-ws.mjs`), which follows this
file and does not restate it.

Related: `./view-v1.md` (history / catch-up, same door, same CORS list),
`./http-v1.md` §3 (files), `../../002-box-agent-messaging/contracts/message-schema.md`
(the unchanged inner `v:1` object).

**Status: Implemented** — `internal/hub/wui.go`; tests `TestWUITwoSessionsLobbyLive`,
`TestWUIBoxAgentToLobby`, `TestWUIFilesUploadDownloadDelete`,
`TestWUIDoorAndReservedBox` (`internal/hub/wui_test.go`, also under `-race`).

**Tolerant parsing (0.2.0)**, so the ORC-described shape and 0.1.0 both work:
`hello.as` may be a display name (mapped to a stable `HUM-<n>` per tenant and
name; `welcome.as` is the id, `welcome.name` echoes the name); `kind:"chat"`
is stored as `note`; `"lobby"` is case-insensitive; a `files[]` item may omit
`mode`/`kind` (`blob`/`file` assumed); the `message` frame carries both
`envelope` (the v:1 object) and `env` (the stored envelope).

## 0. Trust in one paragraph

Local / dev are **unsigned** for browsers (owner goal). The browser is not a
box and holds no key: its messages are stored with `from_box = "box-wui"`,
`to_box = "box-wui"` and an **empty envelope `sig`**. The `from` agent id is
**asserted** by the browser (`hello.as`) and not proven; once a sign-in
session door is active (spec 010) the hub overrides it with the session's
`HUM-*` id. Box envelopes are unchanged (Ed25519, verified by the hub).
Delivery of browser messages to boxes is specified by
`../../014-spool-wui-dispatch/` (hub-signed `box-wui` envelopes, behind
`SPOOL_HUB_WUI_DISPATCH`); with that flag off they are stored and fanned out
to browser subscribers only.

## 1. Constants

| Name | Value | Where defined |
|---|---|---|
| `LOBBY_TASK_ID` | `00000000-0000-4000-8000-000000000001` | cnf `env.hub.env.SPOOL_HUB_LOBBY_TASK_ID` (`csi-spl-cnf/csi-spl/all.env.yaml`), **defined once** there; the hub reads the env var and publishes it in `welcome` |
| Lobby display name | `#lobby` | this file; lobby messages are stored with `channel = "lobby"` (v0.3; `general` stays an accepted input alias for one release and `0008` migrates stored rows, `./channels-v1.md` §1) |
| Browser virtual box | `box-wui` | reserved box id: never pinnable (`POST /v1/pins` refuses it); no pin check applies to it as a `to_box` |
| Broadcast addressee | `ALL-0` | the `to` of a lobby post when no single recipient is meant (a valid v:1 agent id) |

`LOBBY_TASK_ID` is a valid v:1 `task_id` (UUIDv4 shape: version nibble 4,
variant 8). It is the same in every env and tenant; each tenant has its own
lobby thread because every row is tenant-scoped. The thread needs no seed: it
exists from its first message, and `GET /v1/view/threads/{LOBBY_TASK_ID}`
answers `200` with `messages: []` before that (not 404). When the hub runs
without `SPOOL_HUB_LOBBY_TASK_ID`, the lobby is off: `welcome.lobby_task_id`
is absent and `subscribe`/`send` naming `LOBBY` fail with `lobby_disabled`.

## 2. Endpoint and door

```
WS  ws(s)://<tenant>.<fqdn>/v1/wui/ws        lde: ws://t1.localhost:58080/v1/wui/ws
```

- Tenant = request **Host**, as everywhere (`./http-v1.md`). The API host
  (`api.<fqdn>`) is API-only: `404 unknown_tenant` before the upgrade.
- **Door = the view door** (`./view-v1.md` §2): `SPOOL_HUB_VIEW_DOOR=off`
  (lde, dev) admits every browser; `token` (prd) admits a member sign-in
  session (spec 010) and otherwise refuses with HTTP `401 view_door` before
  the upgrade. A browser never sends a box key.
- **Origin**: the upgrade is accepted only from origins on
  `SPOOL_HUB_VIEW_CORS_ORIGINS` (same list as view-v1 §3) or same-origin.
- One JSON text message per frame, `type` discriminator. Unknown `type` ->
  `error` `bad_frame`, socket stays open. Liveness is WS ping/pong.

## 3. Frames

### 3.1 browser -> hub

| `type` | Fields | Rule |
|---|---|---|
| `hello` | `as?`, `token?` | **first frame**, within 10 s (else close `4408`). `as` = a v:1 agent id (`^[A-Z]{2,4}-[0-9]+$`, e.g. `HUM-1`); absent -> the hub assigns `HUM-<n>`. A display name that is not an id (`AgentA`) is refused: close `4400 bad_frame`. `token` is reserved for the prd view token (OQ-16) and ignored today |
| `subscribe` | `task_id` | a UUID, or the literal `"LOBBY"` (= `LOBBY_TASK_ID`). Idempotent. Reply `subscribed` |
| `unsubscribe` | `task_id` | idempotent. No reply |
| `send` | `msg_id?`, `task_id`, `kind?`, `body`, `files?`, `to?`, `channel?`, `parent_task_id?` | §4 |

### 3.2 hub -> browser

| `type` | Fields | When |
|---|---|---|
| `welcome` | `as`, `lobby_task_id?`, `upload_token`, `upload_token_expires_at` | after `hello`. `as` is the id the hub will stamp as `from`. The upload token is for `POST /v1/files` (§5), bound to (tenant, `box-wui`), TTL 5 min |
| `subscribed` | `task_id` | after `subscribe` (always the UUID, also for `"LOBBY"`) |
| `token` | `upload_token`, `upload_token_expires_at` | reply to a browser `{type:"token"}` (fresh upload token) |
| `message` | `task_id`, `cursor`, `received_at`, `envelope`, `env` | **live fan-out**: every message stored for a subscribed `task_id` in this tenant — from a browser, a box agent, or the hub — pushed to **every** subscribed socket (the sender's own included). `env` = the stored envelope `{from_box,to_box,msg,sig}` byte-for-byte, the same element shape as `view-v1` §4.4 (`msg` is the v:1 object); `envelope` = that v:1 object alone. For the sender, its own `message` echo arrives **before** its `ack` |
| `ack` | `msg_id`, `task_id`, `cursor`, `received_at` | after a `send` is stored |
| `presence` | `peer`, `status` | `peer` = `<agent>@<box>` (`CLE-07@box-a`) or `<HUM-n>@box-wui`; `status` ∈ `online`, `offline`. Pushed to every browser socket of the tenant when a `role=box` session is accepted (each announced agent `online`), closes (`offline`; a superseded socket emits nothing), or re-announces (the difference), and when a human's **first** browser socket opens / **last** one closes. Right after `welcome` the hub sends one `online` frame per peer online at that moment (snapshot; a live frame of another socket may interleave, so treat presence as last-writer-wins per peer) (`./channels-v1.md` §6) |
| `error` | `error`, `status`, `detail`, `msg_id?` | stable token (`./error-envelope.md`); socket stays open |

Browser -> hub `{"type":"token"}` asks for a fresh upload token.

Presence example (v0.3):

```json
{ "type": "presence", "peer": "CLE-07@box-a", "status": "online" }
```

## 4. Send

```json
{ "type": "send", "msg_id": "<uuid, optional>", "task_id": "LOBBY",
  "kind": "note", "body": "hello #general", "to": "ALL-0",
  "files": [ { "mode": "blob", "kind": "file", "file_id": "<sha256>",
               "name": "notes.txt", "bytes": 12, "sha256": "<sha256>" } ] }
```

- `msg_id`: client-minted UUID for correlation (idempotent: the same
  `msg_id` with the same content is stored once and acked again; different
  content -> `409 conflict_msg`). Absent -> the hub mints one.
- `task_id`: UUID or `"LOBBY"`. Any task may be posted to; only subscribers
  see it live (and `view-v1` shows it later).
- `kind`: a **v:1 kind** (`task|result|note|reject`), default `note`. There is
  **no `chat` kind** (v:1 is not forked, NFR-003): send `note` or omit it.
- `to`: a v:1 agent id; default `ALL-0`.
- `channel` (v0.3): a channel slug known to the tenant (`./channels-v1.md` §1;
  `general` = `lobby`), else `404 unknown_channel`. Absent: `lobby` when
  `task_id` is the lobby, else **no channel = a DM** (stored `NULL`).
- `parent_task_id` (v0.3): a UUID ≠ `task_id` linking this task to a parent
  task (child thread, `./channels-v1.md` §0), else `400 bad_json`. Absent = a
  root. Replies to a thread use the thread's `task_id`, not this field.
- Both are **hub-envelope** fields: they are stored beside `to_box`
  (`{from_box,to_box,channel?,parent_task_id?,msg,sig}`), never inside the v:1
  object.
- `files`: v:1 blob attachments; every `file_id` must already be uploaded
  (`400 missing_file` otherwise). Limits as `./limits.md` (body 64 KiB, 16 files).
- The hub builds the v:1 object (`v:1`, `ts` = hub time, `from` = `welcome.as`),
  wraps it as `{from_box:"box-wui", to_box:"box-wui", msg, sig:""}` and stores
  it through the **same store path as box sends** (`messages` row + a
  `deliveries` row, state `sent`: the fan-out is its delivery). Billing/quota
  rules of 006 apply (`402 unpaid`, `429 quota`).

## 5. Files (browser)

- Upload: `POST /v1/files`, raw bytes, `Authorization: Bearer <welcome.upload_token>`
  -> `201 {file_id, sha256, bytes}` (`./http-v1.md` §3). CORS: allowed for the
  view origins, with `Authorization` and `Content-Type` headers.
- Download: `GET /v1/files/{file_id}` (tenant capability, no token), streamed
  from GCS; CORS without credentials.
- **Delete** (owner-requested, beyond the original no-delete default):
  `DELETE /v1/files/{file_id}` with a valid upload token of the tenant (box or
  `box-wui`) -> `204`; absent -> `404 not_found`; another tenant's id -> `404`.
  Messages that referenced it keep the ref; a later GET is `404`.

## 6. Box agents in the lobby

A box agent posts to `#lobby` with the normal send path:

```
spool send --from CLE-07 --to ALL-0 --to-box box-wui --task 00000000-0000-4000-8000-000000000001 --kind note --body "build is green"
```

The envelope is box-signed and verified as usual; `to_box = box-wui` needs no
pin. It is stored, gets a `sent` delivery row, and fans out to every browser
subscribed to the lobby. Boxes do not receive lobby traffic in this MVP.

## 7. Catch-up

Subscribe first, then read history with `GET /v1/view/threads/{task_id}`
(`after=<last cursor>` after a reconnect); de-duplicate by `msg.msg_id`. On
reconnect the browser sends `hello` again and re-subscribes.

## 8. Errors (new tokens)

`lobby_disabled` (400), `unknown_channel` (404, v0.3), plus the existing `bad_frame`, `bad_json`,
`missing_file`, `conflict_msg`, `unpaid`, `quota`, `view_door`,
`unknown_tenant`.

<!-- version: 0.3.0 · updated: 2026-09-19 · last-edit: 2026-09-19T06:05:00Z -->
