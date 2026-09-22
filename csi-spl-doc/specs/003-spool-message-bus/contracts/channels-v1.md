# Contract: Channels, threads, DMs and presence v1 (M3 wire)

Feature: `003-spool-message-bus`, M3 lane WIRE (OQ-W1 resolved, `../spec.md`).
Consumers: `../../005-spool-wui/` (channels, DMs, thread pane) and the box
client (`internal/hubclient`). Related: `./http-v1.md` §2 (box WS, envelope),
`./view-v1.md` §4 (read shapes), `./wui-live-ws.md` (browser WS),
`../../002-box-agent-messaging/contracts/message-schema.md` (the **frozen**
inner `v:1` object — nothing here changes it).

**Status: Implemented** (hub + store + box client); tests named per section.

## 0. Decision in one paragraph (OQ-W1, G5)

`channel` and `parent_task_id` are **hub-envelope fields**, next to `to_box`,
never `v:1` fields. Both are **optional**: an envelope without them is
byte-identical to a pre-M3 envelope and verifies unchanged, so old boxes keep
working. `channel` absent (stored `NULL`) = a **direct message** (DM).
A **thread is a `task_id`** (unchanged `v:1` semantics: every reply of a
conversation shares its `task_id`; `msg_id` is the per-message identity).
`parent_task_id` does **not** thread replies; it links a **child task** (a new
`task_id` spawned from a parent task, e.g. a delegated sub-task, or a task a
channel post started) to its parent. Absent = a **root** thread.

Why not "every message its own `task_id`, replies carry `parent_task_id`"
(`SPEC-spool-wui.md` §2.3 draft): box agents answer a task with the task's own
`task_id` (`kind=result`, `SPEC-spool-task-lifecycle.md`) and never set a hub
field, so that model would split every agent reply into its own thread. With
`task_id` threading every existing box already threads correctly.

## 1. Channel ids

- Slug `^[a-z0-9][a-z0-9-]{0,63}$` (= `channels.channel_id`, `0002_channels.sql`).
- **Defaults** of every tenant (seeded, cannot be created again):

| channel | purpose | retention |
|---|---|---|
| `lobby` | common room (Slack's `#general`); every announced agent and every human is implicitly a member | 30 d |
| `tasks` | assignments, milestones, hand-offs | 30 d |
| `alerts` | system events, box connection notices | **7 d** |

  Retention = `hub.retention_alerts` for `alerts`, `hub.retention_channels`
  for every other channel and for DMs (cnf; `./limits.md`). Per-plan retention
  is 006 OQ-006-1 (open).
- **Alias (C3)**: `general` is accepted as an input alias of `lobby` for one
  release (browser `send`, `?channel=general`, box envelopes). The hub stores
  `messages.channel = 'lobby'`; a box-signed envelope keeps its signed bytes.
  Migration `0008_channels_threads.sql` rewrites existing `general` rows.
  `general` can never be created.
- The lobby **thread** is unchanged: `LOBBY_TASK_ID` (`./wui-live-ws.md` §1).
  A message on that task with no `channel` is stored as channel `lobby`.

## 2. Envelope fields

```json
{ "from_box": "box-a", "to_box": "box-wui", "channel": "tasks",
  "parent_task_id": "<uuid>", "msg": { "v": 1, "…": "…" }, "sig": "…" }
```

- `channel`, `parent_task_id`: **absent or a non-empty string**. A box omits
  them (never `null` / `""`); the hub treats `null` / `""` as absent.
- **Signing payload** (extends `./http-v1.md` §2.4 without changing it for old
  envelopes): `jq -cS '{from_box,to_box,msg}'` plus `channel` and/or
  `parent_task_id` **only when present**. Golden: `TestEnvelopeLegacyBytes`,
  `TestEnvelopeChannelSigned` (`internal/wire/wire_test.go`).
- Hub checks (after the `http-v1` §2.4 ones): `channel` a slug known to the
  tenant (default, created, or the `general` alias) else `404 unknown_channel`;
  `parent_task_id` a UUID different from `msg.task_id` else `400 bad_json`.
- `to_box` stays mandatory and signed. A **channel post** (the audience is the
  channel, not one box) is signed with `to_box = "box-wui"`; a **directed**
  message inside a channel names the recipient's box as usual.

## 3. Box subscriptions (hello / announce)

`hello` and `announce` (role `box`) carry an optional `channels` list:

```json
{ "type": "announce", "agents": ["CLE-07", "GRK-03"], "channels": ["tasks", "backend"] }
```

- It applies to **every** agent of that frame's `agents` and **replaces** the
  box's previous subscription set (`channel_subscriptions`, one row per
  channel × agent). Unknown slugs are ignored (not an error).
- `lobby` is implicit for every announced agent (no row needed).
- Box side: `SPOOL_CHANNELS` (comma list of slugs, optional) on the box.
- A frame without `channels` (every pre-M3 box) is a member of `lobby` only.

## 4. Mention-driven routing (`SPEC-spool-wui.md` §2.1)

For every stored message with a channel `C`, after the normal `to_box`
delivery, the hub computes extra recipients:

1. Members of `C`: subscribed `(box, agent)` pairs (for `lobby`, every
   announced agent of the tenant).
2. A member is **addressed** when `msg.to` is its agent id, or the body
   mentions `@<agent>` (e.g. `@CLE-07`, on a token boundary), or the body
   contains `@channel` (every member).
3. **Ambient chat is not routed**: a channel message with no mention and a
   broadcast `to` (`ALL-0`) creates **no** box delivery.
4. Per addressed box (never `from_box`, never the envelope's own `to_box`,
   never `box-wui`) the hub adds a `deliveries` row and pushes
   `{"type":"recv","env":…,"agents":["CLE-07"]}`; while the box is offline the
   row is queued and drained on hello with the same `agents` (recomputed from
   the stored envelope and the current roster).
5. The box accepts a `recv` whose `to_box` is not its own **only** when the
   envelope carries a signed `channel` and the frame lists `agents`; it
   verifies the sig as usual and writes one inbox copy per listed agent that
   it hosts (the `v:1` object is unchanged).
6. Browser-originated envelopes are unsigned (`sig: ""`) until the hub-held
   `box-wui` signer lands (DISPATCH lane, spec 014); the hub **does not route
   unsigned envelopes to boxes** (a box would refuse them, exit 78).

Tests: `TestChannelMentionRouting` (mention → box-b `recv` with `agents`;
control: no mention → no `deliveries` row, no `recv`), `TestHubclientChannelRecv`.

## 5. REST

### 5.1 `POST /v1/channels` (create)

```json
{ "channel": "releases", "name": "Releases", "description": "what ships, and when" }
```

- Door: the **view door** (`./view-v1.md` §2). Door `off` (lde/dev): any
  caller. Door `token` (prd): a member sign-in session only — today that
  admits nobody (fail closed) until 010 T012/T013 land. Boxes do not create
  channels in v1 (OQ-CH1).
- `201` `{ "channel", "name", "description", "created_by", "created_at", "default": false }`;
  `created_by` = the session's `HUM-*`, else `"wui"`. `name` defaults to the slug
  (≤ 80 chars). `description` (1.2.0, rdb 0027) is what the channel is for, as
  the creator typed it in the WUI's new-channel dialog next to the title:
  optional, trimmed, `""` when omitted, ≤ 500 chars.
- `400 bad_channel` (slug, name or description), `409 channel_exists` (existing,
  default, or `general`), `401 view_door`, `402 unpaid`, `404 unknown_tenant`.
- CORS: `OPTIONS /v1/channels` preflight for allow-listed origins
  (`POST`, headers `Authorization, Content-Type`). Test: `TestChannelsCreateAndList`.

### 5.2 `GET /v1/view/channels?read=<channel>~<cursor>` (list)

```json
{ "channels": [
  { "channel": "lobby", "name": "lobby", "description": "", "default": true,
    "retention_days": 30,
    "created_by": "hub", "created_at": "…", "count": 12, "last_ts": "…",
    "last_cursor": "…", "unread": 3,
    "members": { "agents": 4, "boxes": 2, "posters": 3 } } ] }
```

- Every default, every created channel, and any channel seen in stored
  messages, **newest activity first** (1.1.0, CLE-3425): ordered by the newest
  of `last_ts` and `created_at`, a-z breaking a tie, so a client renders the
  answer as it arrives. `last_ts` / `last_cursor` are `null` for an empty
  channel, and `created_at` is then the only thing that ranks it — a channel
  created seconds ago leads the list although nobody has posted in it yet.
  `created_at` is `null` only for a channel the hub knows of solely from stored
  messages. `count` / `last_*` / `unread` / `posters` see only messages in
  retention. Tests: `TestViewChannelsNewestActivityFirst` (hub),
  `TestSortChannelStatsNewestActivityFirst` (store).
- `read` (repeatable) = the reader's last-read cursor per channel (a cursor
  from `./view-v1.md` §4.4). `unread` = messages after it; without one,
  `unread = count`. A cursor the hub cannot decode → `400 bad_cursor`. Read
  state is **client-held** (OQ-CH2).
- `members.agents` / `members.boxes` = subscribed agents / their boxes
  (`lobby`: every announced agent); `members.posters` = distinct `from` ids.

### 5.3 Threads, children, DMs

`./view-v1.md` §4.3 (roots by default, `dm=true&peer=`) and §4.5 (`/children`).

## 6. Presence (browser WS)

`./wui-live-ws.md` §3.2: `{"type":"presence","peer":"CLE-07@box-a","status":"online|offline"}`
on box connect / disconnect / announce change, and on the first / last browser
socket of a human (`HUM-1@box-wui`); a snapshot of every online peer follows
`welcome` (live frames may interleave: last writer wins per peer). Tenant-scoped. Test: `TestWUIPresence`.

## 7. Open questions (owner, via ORC)

- **OQ-CH1** — who creates channels: (a) *recommended, implemented*: humans
  through the view door only; box agents later via a signed frame; (b) boxes
  too, now (needs a signed `channel_create` frame and its replay rule).
- **OQ-CH2** — read state: (a) *recommended, implemented*: client-held
  cursors passed as `read=`; (b) hub-stored per-human cursors (needs the
  humans table, HUMANS 0006).
- **OQ-CH3** — `general` alias lifetime: (a) *recommended*: accepted until
  the next minor contract version, then `404 unknown_channel`; (b) forever.

<!-- version: 1.2.0 · updated: 2026-09-22 · last-edit: 2026-09-22T12:10:30Z -->
