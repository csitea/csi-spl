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

## 4. Membership routing (owner rule 2026-09-22)

> "Whenever I select an agent in the ui and send him a msg this msg should be
> received only by this agent if this is direct msg" — "if we are in a channel
> - all of the participants in the channel will receive the msg"

For every stored message with a channel `C`, after the normal `to_box`
delivery, the hub computes extra recipients:

1. Members of `C`: subscribed `(box, agent)` pairs (for `lobby`, every
   announced agent of the tenant).
2. **Every member is addressed.** Membership IS the address: a plain post, an
   `@CLE-07` mention and `@channel` all reach the same set, and nothing parses
   the body. A leading `@AGENT` still picks the `to_box` of a browser send
   (`../../014-spool-wui-dispatch/contracts/wui-dispatch.md` §3) and `msg.to`
   still names the agent the `to_box` delivery is for — neither narrows the
   channel.
3. Per member box the hub adds a `deliveries` row and pushes
   `{"type":"recv","env":…,"agents":["CLE-07","CLE-08"]}`; while the box is
   offline the row is queued and drained on hello with the same `agents`
   (recomputed from the stored envelope and the current subscriptions).
   Skipped: `box-wui` (the browser audience, served by the WUI fan-out) and
   `from_box` (its own agents wrote the post). An **agent-origin** envelope
   also skips its `to_box`, which the shared commit path already delivered; a
   **browser-origin** one does not — `box-wui` owns no agent, so the `to_box`
   of a dispatch is just another member box, and the members sitting next to
   the dispatched agent are exactly what the owner rule is about. `Enqueue` is
   idempotent per `(msg_id, box)`, so that second row is a no-op insert and
   only the recv frame's `agents` list changes.
4. A box accepts a `recv` whose `to_box` is not its own **only** when the
   envelope carries a signed `channel` and the frame lists `agents`; it
   verifies the sig as usual and writes one inbox copy per listed agent that
   it hosts (the `v:1` object is unchanged). A channel frame addressed to the
   box **itself** carries that list too, and those copies are written as well
   as `msg.to`'s.
5. A **DM** (no channel) is routed to exactly one box, unchanged: `to` is
   resolved to one box or the send is refused. Nothing here widens it.
6. The hub **does not box-route an unsigned envelope** (a box would refuse it,
   exit 78). A browser channel post is therefore signed with the hub-held
   `box-wui` key before it is committed — `to_box` `box-wui`, since no single
   box owns a channel post — and every receiving box verifies it against the
   tenant's `box-wui` pin with the same code it runs on any envelope. One
   trust path, the DISPATCH lane's (spec 014). A tenant that has not pinned
   `box-wui` keeps the browser-only post rather than getting a refusal.

**Permission** (`../../025-spool-tenant-rbac/`): posting stays `notes.send`,
and the **fan-out** is what `agents.command` buys. `#lobby` has every announced
agent as a member, so raising the post itself to `agents.command` would stop a
`tester` chatting at all; without the permission the post is stored and reaches
every browser exactly as before, and no box delivery is built. The identity
rule is a dispatch's (014 §3 step 1): a signed-in member, never a door-off
anonymous socket.

**Cost**: the fan-out multiplies `deliveries` rows, not messages — the 006
message quota is counted once per message in `admit()`, and `QueueMaxPerBox`
caps per `(tenant, box)`, so each member box is capped independently. One
`Enqueue` batch (one round trip) per member box, per post.

**What changed** (was: "mention-driven routing", M3): ambient chat used to
route nowhere, so a channel post with no mention reached no agent at all, and
a browser post reached none whatever it said.

Tests: `TestChannelMembershipRouting` (a plain line reaches every member;
controls: a channel the box did not join reaches nobody, a DM is not
channel-routed), `TestHubclientChannelRecv` (the real box client writes one
copy per member), `TestWUIChannelPostReachesEveryMemberBox` (the browser half,
end to end), `TestWUIChannelPostWithoutAgentsCommandStaysBrowserOnly` (the
permission control).

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

## 7. The read door — who may read a channel (rdb 0028)

Owner's call, 2026-09-23, after a member of tenant `t1` opened another
member's DM with an agent through `/channel/<name>?thread=<uuid>`:

> "fix the fact that all of the messaging is public [...] the messages should
> be public only if both of the users are in the same channel"

Until 0028 the only gate on a read was `rbac.threads.read`, a **tenant-wide**
role. `channel_subscriptions` (§4) is the AGENT half — where a post must be
delivered — and there was no human membership at all, so any signed-in member
of a tenant could read any thread of it by its `task_id`.

### 7.1 The two rules

| the message is | readable by |
|---|---|
| in a **default** channel (`#lobby`, `#tasks`, `#alerts`) | every member of the tenant |
| in a **created** channel | the humans in `channel_humans` for it |
| **untagged** (a DM) | the two ends of that message |

A non-member cannot learn a created channel exists: it is absent from
`GET /v1/view/channels` and from search, its threads answer **404**, and a
`subscribe` to it is refused with the same `unknown_channel` a channel that
does not exist gets. 404 and not 403 — a refusal that tells the two apart is
an oracle for which private channels exist.

### 7.2 Per MESSAGE, not per thread

One thread can hold both kinds: the WUI posts a reply from whichever channel
page it is on, so a DM thread picks up a channel-tagged message the moment
someone answers it from a channel view (dev `t1`
`57e6f191-582e-45b1-a08e-389c0b034803` is exactly that, and is the thread the
defect was reported from). Access is therefore **not** a property of the
thread. `GET /v1/view/threads/{task_id}` opens when at least one message in it
is readable, and then returns **only** the readable ones — filtered in the
statement, so `limit` counts what comes back. Were it per thread, appending
one message to a DM would buy the whole private history before it.
Test: `TestMixedThreadHidesTheDMHalf`.

### 7.3 Where it is applied

`GET /v1/view/threads/{task_id}` and `/children`, `GET /v1/view/threads`,
`GET /v1/view/channels`, `GET /v1/search`, and on the browser socket:
`subscribe` (by channel and by `task_id`), `send`, the message fan-out, the
edit fan-out and the `channel` created-frame. Posting into a channel you are
not in is refused for the same reason reading it is.

A socket or request with **no** member session filters nothing: that is the
door-off rig (`SPOOL_HUB_VIEW_DOOR=off`, lde only), and it is the rule the DM
filter has always used. In the session door `humanTenant` has already refused
anything without a session.

### 7.4 Membership

`channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)`,
tenant-scoped RLS in the 0021 fail-closed form.

- `GET /v1/channels/{channel}/members` — members only.
- `POST /v1/channels/{channel}/members` `{human_id}` — needs `channels.manage`
  **and** membership; the target must already be a member of the tenant.
- `DELETE /v1/channels/{channel}/members/{human_id}` — `channels.manage`, or
  yourself (leaving needs no permission).
- Creating a channel puts its creator in it; a members-only channel born empty
  would be lost the moment it was made.
- A default channel has no membership: both writes answer `409 channel_public`.

**Backfill (0028).** Membership is derived from evidence, never from "everyone
in the tenant" — that would carry the leak forward under a new name. Each
created channel admits its creator plus every human who posted in it or was
addressed in it. Anyone else is out on the first deploy and has to be added.

### 7.5 Attachments (rdb 0030)

`GET /v1/files/{file_id}` was scoped to the TENANT and nothing else, so 0028
left one way round itself: a signed-in member who knew a `file_id` could fetch
an attachment out of a channel they were never in, or out of another member's
DM. The id is a sha256 you can normally only learn by reading the message that
carries it — but "they would have to know it" is an assumption about the
attacker, not a control, and ids travel in links, logs and screenshots.

A file is readable when **any** of:

| | |
|---|---|
| a message carrying it is one this principal may read | the §7.1 rules, per message |
| it is a member's `avatar_file_id` | `GET /v1/view/roster` already lists every member's avatar to every member, so the picture is exactly as private as the roster |
| **no** message in retention carries it | an upload whose message has not been sent yet — a box uploads, then sends, and must be able to fetch back what it just produced |

Principals: a **box**, by its upload token — a message with that box at either
end, or delivered to it (a channel post is addressed to `box-wui` and reaches
member boxes as delivery rows). **`box-wui` is not a principal here**: a
browser holds a `box-wui` upload token from its `welcome` frame and downloads
with its session cookie, never that token, so honouring it would hand every
member a key that walks past the human door standing next to it. A **human
session** gets the §7.1 rules. No session at all filters nothing (door-off
lde), as everywhere else.

404, never 403 — "not yours" and "no such file" must not be distinguishable.

`messages.files` had no index, so this question would have scanned every
message of the tenant on every download, avatars included. 0030 adds
`gin (files jsonb_path_ops)`, which indexes exactly the one containment shape
this asks (`files @> '[{"file_id": "..."}]'`).

**Known limit.** The third rule is keyed on retention: once a message expires
out of the window its attachment stops being "carried" by anything and becomes
readable again to any member who has the id. Closing that means having the
retention sweep delete the blob with the message; until then it is a real if
slow re-opening, and it is written down here rather than left to be
rediscovered.

## 8. Open questions (owner, via ORC)

- **OQ-CH1** — who creates channels: (a) *recommended, implemented*: humans
  through the view door only; box agents later via a signed frame; (b) boxes
  too, now (needs a signed `channel_create` frame and its replay rule).
- **OQ-CH2** — read state: (a) *recommended, implemented*: client-held
  cursors passed as `read=`; (b) hub-stored per-human cursors (needs the
  humans table, HUMANS 0006).
- **OQ-CH3** — `general` alias lifetime: (a) *recommended*: accepted until
  the next minor contract version, then `404 unknown_channel`; (b) forever.

<!-- version: 1.5.0 · updated: 2026-09-23 · last-edit: 2026-09-23T18:40:00Z -->
