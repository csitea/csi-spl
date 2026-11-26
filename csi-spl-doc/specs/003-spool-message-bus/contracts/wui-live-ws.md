# Contract: WUI live WebSocket v1 (browser <-> hub live chat, #lobby, channels, presence)

Feature: `003-spool-message-bus`, owner goal "live-chat MVP" (2026-09-18).
**Single source of truth** for the browser <-> hub live protocol. Consumer:
`../../005-spool-wui/` (`csi-spl-wui/src/utils/live-ws.mjs`), which follows this
file and does not restate it.

Related: `./view-v1.md` (history / catch-up, same door, same CORS list),
`./http-v1.md` §3 (files), `../../002-box-agent-messaging/contracts/message-schema.md`
(the unchanged inner `v:1` object).

**Status: Implemented** — `internal/hub/wui.go`; tests `TestWUITwoSessionsLobbyLive`,
`TestWUIBoxAgentToLobby`, `TestWUIFilesUploadDownloadDelete`,
`TestWUIDoorAndReservedBox`, `TestWUIResendAcrossSecond`, `TestWUIChannelSubscribeNewRoot`,
`TestWUIPeerSubscribeDM`, `TestWUIAllSubscribe`
(`internal/hub/wui_test.go`, also under `-race`). v0.8 (sync 2026-09-25) adds the
`message_edited` / `message_deleted` (032) and `message_reaction` (FR-033) rows to
§3.2; they were live before this file named them.

**Tolerant parsing (0.2.0)**, so the ORC-described shape and 0.1.0 both work:
`hello.as` may be a display name (mapped to a stable guest id `GST-<n>` per
tenant and name, v0.4.1; `welcome.as` is the id, `welcome.name` echoes the name); `kind:"chat"`
is stored as `note`; `"lobby"` is case-insensitive; a `files[]` item may omit
`mode`/`kind` (`blob`/`file` assumed); the `message` frame carries `env`
(the stored envelope; the v:1 object is `env.msg`). Its `envelope` copy of
`env.msg` was dropped on 2026-10-02 (db-payload-audit cut 3, 1 101 -> 706 B).

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
exists from its first message, and `GET /v1/view/topics/{LOBBY_TASK_ID}`
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
| `hello` | `as?`, `token?` | **first frame**, within 10 s (else close `4408`). `as` = a v:1 agent id (`^[A-Z]{2,4}-[0-9]+$`, e.g. `HUM-1`) used as `from`; absent -> the hub assigns a guest id `GST-<n>`. A display name that is not an id (`AgentA`) is mapped to a stable `GST-<n>` per (tenant, name) — `welcome.as` is the id, `welcome.name` echoes the name (0.2.0). **Guest ids (v0.4.1, gap H5)** are disjoint from member ids: members are `HUM-<n>` (rdb 0006 CHECK `^HUM-[0-9]+$`), so a door-off guest never renders with a member's identity or picture, and a `GST-*` is never a dispatch target. A `hello.as` that already is a v:1 id (`HUM-2`) is still taken as asserted (§0; door off only). Live: `TestWUITwoSessionsLobbyLive` dials `as:"AgentA"` and asserts `welcome.as == "GST-1"`; `TestWUIAnonymousIDDisjointFromMembers` admits member `HUM-1` first, then asserts an anonymous hello never gets a `^HUM-[0-9]+$` id. Close `4400 bad_frame` only when the first frame is not a well-formed `hello` (or `as` > 64 chars). `token` is reserved and ignored (the OQ-16 view token was superseded by the session door) |
| `subscribe` | `task_id` \| `channel` | `task_id`: a UUID, or the literal `"LOBBY"` (= `LOBBY_TASK_ID`). `channel` (v0.4): a channel slug known to the tenant (`general` = `lobby`), else `404 unknown_channel`; the socket then gets **every** message stored in that channel, including a new root thread (a new `task_id`) someone else starts there. When `channel` is set, `task_id` is ignored. Idempotent. Reply `subscribed` |
| `subscribe` | `peer` (v0.5) | DM follow: `peer` = `<agent-id>` or `<agent-id>@<box-id>` (else `400 bad_frame`). The socket gets every message stored **with no channel** whose `from` or `to` is that peer (and its box, when given) — new DM roots included. A socket with a member session gets only the ones it is party to (`from` or `to` is its own id), the same rule as `view-v1` §4.3 `dm=true`. Reply `subscribed {peer}` |
| `subscribe` | `all: true` (v0.5) | thread-list follow: every message stored in the tenant; a DM (no channel) only when the socket's own id is its `from` or `to`. Reply `subscribed {all:true}` |
| `unsubscribe` | `task_id` \| `channel` \| `peer` \| `all` | idempotent. No reply |
| `send` | `msg_id?`, `task_id`, `kind?`, `body`, `files?`, `to?`, `channel?`, `parent_task_id?`, `is_parent?`, `mc_id?` | §4 (`mc_id`: spec 186 M2) |
| `topic_select` | `req_id`, `action`, `task_ids?`, `patterns?` | §4.1 (Planned, spec 186 M4): resolve ticked topics and title patterns on the hub |
| `multicast_check` | `req_id`, `task_ids`, `files?`, `body` | §4.1 (Planned, spec 186 M4): read-only dry run for a multicast send |

### 3.2 hub -> browser

| `type` | Fields | When |
|---|---|---|
| `welcome` | `as`, `name?`, `lobby_task_id?`, `upload_token`, `upload_token_expires_at` | after `hello`. `as` is the id the hub will stamp as `from`; `name` echoes the display name from `hello.as` when it was not already an id. The upload token is for `POST /v1/files` (§5), bound to (tenant, `box-wui`), TTL 5 min |
| `subscribed` | `task_id` \| `channel` | after `subscribe`: `task_id` is always the UUID (also for `"LOBBY"`); `channel` is the stored slug (`general` answers `lobby`) |
| `token` | `upload_token`, `upload_token_expires_at` | reply to a browser `{type:"token"}` (fresh upload token) |
| `topic_selected` | `req_id`, `ok`, `error?`, `detail?`, `topics` | §4.1 (Planned, spec 186 M4): reply to `topic_select` |
| `multicast_checked` | `req_id`, `ok`, `error?`, `detail?`, `targets` | §4.1 (Planned, spec 186 M4): reply to `multicast_check` |
| `message` | `task_id`, `cursor`, `received_at`, `env`, `channel?`, `parent_task_id?` | **live fan-out**: every message stored for a subscribed `task_id`, a subscribed `channel`, a subscribed DM `peer`, or under `all` in this tenant (once per socket when several match) — from a browser, a box agent, or the hub — pushed to **every** subscribed socket (the sender's own included). `env` = the stored envelope `{from_box,to_box,msg,sig}` byte-for-byte, the same element shape as `view-v1` §4.4 (`msg` is the v:1 object; there is no separate `envelope` copy since 2026-10-02). `cursor` is the stored row's cursor (the same value as the sender's `ack` and as `view-v1`), so a client advances its read cursor from it. `channel` is the stored channel (absent for a DM), `parent_task_id` the hub-envelope link (absent for a root). For the sender, its own `message` echo arrives **before** its `ack` |
| `ack` | `msg_id`, `task_id`, `cursor`, `received_at` | after a `send` is stored |
| `presence` | `peer`, `status` | `peer` = `<agent>@<box>` (`CLE-07@box-a`) or `<HUM-n>@box-wui`; `status` ∈ `online`, `offline`. Pushed to every browser socket of the tenant when a `role=box` session is accepted (each announced agent `online`), closes (`offline`; a superseded socket emits nothing), or re-announces (the difference), and when a human's **first** browser socket opens / **last** one closes. Right after `welcome` the hub sends one `online` frame per peer online at that moment (snapshot; a live frame of another socket may interleave, so treat presence as last-writer-wins per peer) (`./channels-v1.md` §6) |
| `status` | `peer`, `state`, `note`?, `until`? | A member's manual status (spec 096; view-v1 §4.1.1), a separate frame so a tab that knows only `presence` ignores it. `peer` = `<HUM-n>@box-wui`; `state` ∈ `busy`, `unavailable`, `available` (= cleared: no `note`, no `until`); `note` and `until` (RFC 3339 UTC) omitted when unset. Pushed to every browser socket of the workspace when the member sets or clears it, and when the hub's sweep deletes an expired one. Right after the presence snapshot the hub sends one frame per live status. A tab on another hub instance learns a change at its next roster read; the client also drops a status whose `until` has passed. |
| `channel` | `channel`, `name`, `description`, `created_by`, `created_at` | **v0.6** (CLE-3425; `description` v0.7): a channel was created in this tenant (`POST /v1/channels`, `./channels-v1.md` §5.1). Pushed to **every** browser socket of the tenant — no subscription, because a fresh channel holds no message, so the `message` fan-out cannot carry it and a sidebar would otherwise learn of it only on a reload or a reconnect. It says nothing a member cannot read from `GET /v1/view/channels`. Test: `TestWUIChannelFrameOnCreate` (with the CONTROL that a socket of another tenant gets nothing) |
| `channel_deleted` | `channel` | SPL-72: the channel's creator deleted it (`DELETE /v1/channels/{channel}`, `./channels-v1.md` §5.4, a soft delete). Sent to the browser sockets of the channel's **members only**, read before the delete; a non-member gets nothing, because the frame names a channel it must not learn exists. The sidebar drops the row, and a member reading the channel is taken to #lobby. Test: `TestDeleteChannelLive` (with the CONTROL that a non-member socket stays quiet) |
| `message_edited` | `task_id`, `msg_id`, `cursor`, `received_at`, `envelope`, `env`, `channel?`, `parent_task_id?`, `edited_at`, `edited_by`, `revision?` | a stored message was edited (`PATCH /v1/messages/{msg_id}`, 032 `contracts/message-edit-v1.md`); a separate type because a second `message` frame for a held `msg_id` is dropped. `internal/hub/edit.go:42` |
| `message_deleted` | `task_id`, `msg_id`, `channel?` | a stored message was deleted (`DELETE /v1/messages/{msg_id}`, 032); every open topic drops the row. `internal/hub/edit.go:278` |
| `message_reaction` | `task_id`, `msg_id`, `reactions` (`[{emoji, actors[]}]`, `[]` when none), `channel?` | a member added or removed an emoji (FR-033, `./http-v1.md` §1a); sent to every socket shown the message, the actor's other tabs included. `internal/hub/reactions.go:19`; `TestReactionOnOpeningAndReply` |
| `error` | `error`, `status`, `detail`, `msg_id?` | stable token (`./error-envelope.md`); socket stays open |

Browser -> hub `{"type":"token"}` asks for a fresh upload token.

Presence example (v0.3):

```json
{ "type": "presence", "peer": "CLE-07@box-a", "status": "online" }
{ "type": "status", "peer": "HUM-12@box-wui", "state": "unavailable", "note": "On leave", "until": "2026-10-07T12:00:00Z" }
```

## 4. Send

```json
{ "type": "send", "msg_id": "<uuid, optional>", "task_id": "LOBBY",
  "kind": "note", "body": "hello #general", "to": "ALL-0",
  "files": [ { "mode": "blob", "kind": "file", "file_id": "<sha256>",
               "name": "notes.txt", "bytes": 12, "sha256": "<sha256>" } ] }
```

- `msg_id`: client-minted UUID for correlation (idempotent: the same
  `msg_id` with the same content is stored once and acked again, also in a
  later second, with the stored row's `cursor`; different
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
- `mc_id` (spec 186 §7.1.1 / §7.1.3, M2; live: `TestMulticast*Send*`,
  `TestMulticastNoTopic`, `TestMulticastBadFrames`, `TestMulticastRoutesAsAPost`
  in `internal/hub/wui_multicast_test.go`): optional client-minted UUID
  shared by every copy of one multicast, sent on one ordinary `send` frame per
  target (`is_parent: 0`, each copy carrying its own `msg_id`, the target's
  `task_id` and `channel`, and shared `files` refs; patterns never travel on a
  `send` frame). Stored on the `messages` row as a hub-only column — never
  inside the v:1 object and absent from view rows and `message` frames. Absent
  = an ordinary send, unchanged.
  - **Refusals for `mc_id`**:
    - Non-UUID value, or an `mc_id` already stored with a different `from` ->
      `400 bad_json`.
    - `is_parent` must be `0` and `task_id` must name an existing channel
      topic the author may read (`canReadTopic`); `is_parent` != 0, an unknown
      `task_id`, a DM topic, or an existing topic the author may not read all
      answer `404` with
      `multicast_no_topic`
      using the same token and detail (never reveals whether a topic exists).
      Its `error` frame names only its own `msg_id`; other copies are untouched.
    - No per-multicast copy cap (spec 186 R2 QTA): each copy counts as one
      message in the tenant's monthly quota (`429 quota`), and every existing
      `wuiSend` refusal (`topic_archived`, `unknown_channel`, `forbidden`,
      `402 unpaid`, `missing_file`, token budget, demo checks) applies per copy
      unchanged. Resending an already-stored `msg_id` re-acks and is never
      refused by the quota or by `topic_archived`.

### 4.1 Multicast select and pre-check frames (Planned, spec 186 §7.1.2, M4)

Both frames are read-only: they store nothing, send nothing to any box, and
echo `req_id` so the client drops answers to superseded requests. At most one
frame of each kind may be in flight per connection; a newer frame of the same
kind cancels the running one (which then sends no reply).

**`topic_select` -> `topic_selected`** (shared resolver for bulk topic actions):

```json
{ "type": "topic_select", "req_id": "<uuid>", "action": "multicast",
  "task_ids": ["<uuid>"], "patterns": ["*", "^release"] }
```

```json
{ "type": "topic_selected", "req_id": "<same>",
  "ok": true, "error": "<optional token>", "detail": "<optional text>",
  "topics": [{ "task_id": "<uuid>", "channel": "<slug>", "title": "<subject>" }] }
```

- `patterns`: at most 10 entries, each at most 256 bytes. The hub trims each
  line (`strings.TrimSpace`) and drops empty lines. A trimmed `*` matches every
  in-scope topic; any other line is a Go RE2 regex matched case-insensitively
  (`(?i)`) and unanchored (`MatchString`) against the topic's title (first line
  of its opening message, trimmed, max 140 runes).
- `task_ids`: no separate count cap (deduplicated; bounded by the socket's
  512 KiB `maxFrameBytes` read limit). Both `task_ids` and `patterns` empty, or
  an unknown `action`, answer `400 bad_json`. This contract defines
  `action: "multicast"`; later bulk actions (such as spec 153) register their
  own action names and permission filters.
- **Scope**: pages `ViewTopics` for the author (`NoIssues`, `DM` false, 200 per
  page until the end; `#lobby` and `general` included), filters out topics
  hidden by the box owner lock (`hidesSeat`, lobby exempt) before reading
  titles, and keeps only channels where the author holds the action's
  permission (`multicast`: `notes.send`). Ticked `task_id`s outside that scope
  are omitted from `topics` (never revealed as existing).
- **Replies and errors**:
  - A pattern that fails RE2 compilation answers `ok: false` with error token
    `topic_select_bad_pattern`
    (status `400`, `detail` naming the bad line) and adds nothing.
  - `ok: true` with `topics: []` is a valid empty match.

**`multicast_check` -> `multicast_checked`** (dry run before sending):

```json
{ "type": "multicast_check", "req_id": "<uuid>",
  "task_ids": ["<uuid>"], "files": [], "body": "<text>" }
```

```json
{ "type": "multicast_checked", "req_id": "<same>",
  "ok": true, "error": "<optional token>", "detail": "<optional text>",
  "targets": [{ "task_id": "<uuid>", "channel": "<slug>", "title": "<subject>",
                "ok": true, "error": "<optional token>" }] }
```

- Accepts explicit `task_ids` only (no patterns; bounded by `maxFrameBytes`).
  An empty `task_ids` list answers `ok: false` with error token
  `multicast_none`
  (no targets selected).
- Each `task_id` is checked against the `multicast` scope (out-of-scope targets
  return `ok: false` with `multicast_no_topic`) and the read-only `wuiSend`
  checks for `body` and `files` (archived, moved, door, `notes.send` /
  `agents.command`, billing, `missing_file`, and token budget when an agent
  will act).
- The tenant's monthly message quota is checked once for the whole target
  count: if the count exceeds remaining messages (when the plan is capped), the
  whole check answers `ok: false` with `error: "quota"` (status `429`, `detail`
  giving the target count and remaining messages) and `targets` as far as the
  check got. Otherwise top-level `ok` is `true` only when every target is
  `ok: true`.
- The check is point-in-time: each subsequent `send` frame is still validated
  independently on arrival.

## 5. Files (browser)

- Upload: `POST /v1/files`, raw bytes, `Authorization: Bearer <welcome.upload_token>`
  -> `201 {file_id, sha256, bytes}` (`./http-v1.md` §3). CORS: allowed for the
  view origins, with `Authorization` and `Content-Type` headers.
- Download: `GET /v1/files/{file_id}` (tenant capability, no token), streamed
  from GCS; CORS without credentials.
- **Delete** (owner-requested, beyond the original no-delete default):
  `DELETE /v1/files/{file_id}` with a valid upload token of the tenant (box or
  `box-wui`) -> `204`; absent -> `404 not_found`; another tenant's id -> `404`.
  Only the uploader deletes (SPL-5570): a box deletes a file only when every
  message in retention that carries it was sent by that box; a browser
  (`box-wui` token plus the member session) only when the signed-in member is
  the author of every carrier. Any other caller, a reader of the file
  included, gets the same `404` as for an absent file. A file no message
  carries yet (a fresh upload) follows the read door.
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

Subscribe first, then read history with `GET /v1/view/topics/{task_id}`
(`after=<last cursor>` after a reconnect); de-duplicate by `msg.msg_id`. On
reconnect the browser sends `hello` again and re-subscribes. For a channel,
DM or `all` subscription the catch-up is the matching `GET /v1/view/topics`
list (first page), merged by `task_id` (v0.5).

## 8. Errors (new tokens)

`lobby_disabled` (400), `unknown_channel` (404, v0.3), plus the existing `bad_frame`, `bad_json`,
`missing_file`, `conflict_msg`, `unpaid`, `quota`, `view_door`,
`unknown_tenant`, `multicast_no_topic` (404, spec 186 §7.1.1: a `send` with
`mc_id`; also a `multicast_checked` target token), and Planned (spec 186 §7.1):
`topic_select_bad_pattern` (400, reply token), `multicast_none` (reply token,
`ok: false`).

<!-- version: 0.10.2 · updated: 2026-11-26 · last-edit: 2026-11-26T06:10:00Z -->
