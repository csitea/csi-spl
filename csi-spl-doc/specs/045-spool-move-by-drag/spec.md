# Feature Specification: Move by Drag (a topic to a channel, a message to a topic)

**Feature ID**: `045-spool-move-by-drag` · **Milestone**: M3 · **Status**: Implemented (live dev + prd, `tasks.md` T001–T010)
**Created**: 2026-09-27 · **Lane**: MOVE-BY-DRAG (hub + DB + browser) · **Issue**: SPL-1024 (epic 51)
**Authority**: this file for the rule; `contracts/move-v1.md` for the wire; `tasks.md` for what is built and where.
**Closest pattern**: `041-spool-topic-archive-delete` (a topic-level operation on a card, the same
permission shape, the same live-frame audience).

Status vocabulary follows `../README.md` §2.3.

## 1. The owner's requests, verbatim

prd t1 `#spool-hub-devel`, 2026-09-27:

- topic `72557f61-4e4e-4378-b922-49f686873726` (20:47Z):
  > a starter of a topic should be able to just drag it to a different channel, provided he has
  > access to this channel
- topic `e615e3fd-ccda-4173-8644-3800d8b8890c` (20:47Z):
  > thread level msgs / cards should be draggable to a different topic, from the right-most panel
  > to the topic in the middle panel

Relayed by the orchestrator: the same actions from the card menu for keyboard and touch (drag is not
usable there), an undo for a few seconds, and the move recorded. It also fixes a post that landed in
the wrong channel (prd t1 topic `82bf9be6`, 2026-09-27).

## 2. Words

- **Card**, **topic of a card**, **children**: as `041` §2. A card here is always a **task opener**
  (the first message of a task that is not the lobby task); its topic is that task plus every
  message-rooted thread and sub-task under it (`store.walkTopic`).
- **Reply**: a row of a topic that is not its card (`is_parent = 0`, drawn in the right pane), or a row
  of a message-rooted thread on one of the topic's lines.
- **Home**: where a row was stored when it arrived. The signed envelope keeps it forever (a box signed
  it with a key the hub does not hold, so the hub cannot rewrite it; rdb `0060` has the same constraint
  for `kind`). A move is therefore **hub metadata beside the envelope**, like `edited_at` and
  `kind_set_by`.

## 3. Behaviour

### 3.1 Move a topic to another channel (request 1)

- **Gesture**: drag the topic's card from the middle list and drop it on a channel row of the left
  rail. Keyboard / touch: the card menu's **Move to channel…** opens a picker of the channels the
  caller may post in (the current one left out).
- **Effect**: every row of the topic (`walkTopic`: the card, its replies, every thread on its lines,
  their sub-tasks) gets `messages.channel` = the target. Nothing else changes: `task_id`, `msg_id`,
  `received_at`, reactions, revisions, kind changes and file references stay on the same rows, so they
  all move with them by construction (they key on `msg_id`, `041` §4).
- **Recorded**: every moved row gets `moved_at`, `moved_by` (the mover's v:1 id) and
  `moved_from_channel` (its **home** channel, kept on a second move). The card shows a small
  "moved from #x" note (the WUI draws it on the card only).
- **Deep links** to the old place keep resolving: `/t/<task>` and `?thread=` are task ids and do not
  change; a channel URL carrying the task (`/channel/<old>?in=<task>` or `?thread=<task>`) finds the
  task's channel from the topic read and replaces the URL with `/channel/<new>…` (a redirect, not an
  error).
- **Refused**: a DM topic (`409 not_in_channel`: a move would publish a private conversation), a lobby
  card or the lobby as a target (`409 lobby`: the lobby is ONE shared task, a topic cannot join or
  leave it as a unit), an issue's discussion (`409 issue_topic`, `041` §3.2), the reserved `issues`
  channel as a target (`404 unknown_channel`), the same channel (`409 same_place`). **INFERRED** — say
  so to lift any of them.

### 3.2 Move a message to another topic (request 2)

- **Gesture**: drag a reply from the right pane and drop it on a topic card in the middle list.
  Keyboard / touch: the reply's menu **Move to topic…** opens a picker of the topics of the channels
  the caller may post in (a search box, newest first).
- **Effect**: the row gets `task_id` = the target task, `parent_task_id` = NULL, `is_parent` = 0 (a
  reply), `channel` = the target's channel. Its own thread (`task_id` = its `msg_id`) and everything
  under it come with it: those rows keep their `task_id`, get `channel` = the target's, and a
  `parent_task_id` that pointed at the old topic now points at the target. So a later delete of the
  OLD topic does not take them (`041` walks `parent_task_id`).
- **Order**: a row is placed by `received_at`. A moved row older than the target's card would sort
  above it and become the target's "first message" (breaking `041`'s card test and the topic title).
  So `received_at` becomes `max(received_at, card.received_at + 1 ms)`: the row keeps its place in
  time when it can, and lands just under the card when it cannot. `expires_at` does not change.
- **Recorded**: the row gets `moved_at`, `moved_by`, `moved_from_task` (its home task) and
  `moved_from_channel`; its thread rows get `moved_at`, `moved_by`, `moved_from_channel`. The row shows
  "moved from <home topic>".
- **Refused**: the card of a topic (`409 is_card`: move the whole topic with 3.1 instead), a row of the
  lobby task or a lobby target (`409 lobby`), a DM row or a DM target (`409 not_in_channel`), an
  issue's discussion either way (`409 issue_topic`), the same topic (`409 same_place`), a target that
  is not a card (`409 not_a_card`), a target inside the row's own thread (`409 cycle`).

### 3.3 Undo, and moving back

- After a move the WUI shows "Moved to … · **Undo**" for 8 s. Undo is the same endpoint with the
  previous place as the target (the answer carries it as `undo`).
- A move whose target is the row's **home** clears the `moved_*` columns: the row is exactly where its
  envelope says it is again, so the view needs no override. A second move keeps the first home. The
  note therefore always names the home, and "moved" means "not at home".

### 3.4 Who may (the `041` §3.3 shape)

| who | Move a topic (3.1) | Move a message (3.2) |
|---|---|---|
| the author of the card / the row (`from_id` = the caller's member id) | yes | yes |
| the tenant owner (`biz_owner`, `TenantOwner`) | yes | yes |
| `admin` | yes | yes |
| any other member | no — the entry is not offered, the row is not draggable | no |
| an agent / a box | no — no box route exists | no |

Plus, in the hub and not only in the UI:

- the **source** is read through the message door (a row the caller may not read is `404`);
- the **target channel** (3.1) or the **target topic's channel** (3.2) must be one the caller may post
  in: it exists and is not deleted, and the caller may read it (`404 unknown_channel` otherwise — the
  rdb 0028 rule: a members-only channel the caller is not in is answered exactly like a missing one);
  the target topic itself must be readable (`404 not_found`);
- the caller's role grants `notes.send` (`403 forbidden`), billing allows writes (`402`).

The browser learns what it may offer from `GET /v1/view/me` (role) plus the row's author, and for the
exact answer from `GET /v1/view/messages/{msg_id}/move` (contract §4), never from a guess on the screen.

### 3.5 Reply counts (SPL-1008), search, deliveries, fallback

- **Reply counts** are counted from `messages.task_id` on every read (`listMessages` totals, the topic
  list, `041`'s `TopicReplies`), so they follow the move with no counter to fix. The live frame (3.6)
  makes open tabs re-read the topics / lists involved. `message_period_counts` (rdb 0023) counts SENDS
  for the quota and is not touched: a move is not a send.
- **Search** reads `messages.channel` / `task_id`, so a moved topic is found under its new channel and
  a moved row under its new topic from the moment of the move. `search_tsv` is generated from `body`,
  which a move does not change.
- **Deliveries**: none are added or removed. A move is not a send: the agents of the new channel are
  not delivered the old rows, and nobody is poked. Queued deliveries stay queued. A new reply on a moved
  topic is stored in the topic's CURRENT channel (3.7) and routed from there like any reply.
- **Fallback responder** (SPL-997) looks at a window of recent `received_at`; a move changes
  `received_at` only under the 3.2 order rule, so a moved row enters the window only when it lands
  under a card younger than the window. **INFERRED** acceptable.
- **Retention**: `expires_at` is kept. A topic moved into `#alerts` keeps its 30-day expiry.

### 3.6 Live

One frame per move to every browser socket that was shown the rows at the old place OR is shown them at
the new place (the `041` audience, taken for both):

- `topic_moved` `{msg_id, task_id, channel, from_channel, moved_by, moved_at, msg_ids}`
- `message_moved` `{msg_id, task_id, from_task, channel, from_channel, moved_by, moved_at, msg_ids}`

A feed drops the rows that left it and re-reads a list the rows joined; an open topic pane on
`from_task` drops the row, one on `task_id` re-reads.

### 3.7 A reply to a moved topic

A reply sent from a tab that still shows the old channel, or from an agent whose delivery named the
old channel, carries the old channel tag. The hub stores it in the topic's CURRENT channel when the task
has moved rows (the partial index `messages_moved` keeps the extra lookup to one probe of a tiny
index). The envelope keeps its tag, as every moved row does. A browser reply is signed with the
current channel. An agent's reply keeps its own signed tag, and the box fan-out goes by what the signed
envelope claims (channels-v1 §4.5), so the old channel's member agents get it: stored and shown in the
new channel, delivered as the agent addressed it.

### 3.8 Drag a channel to set your own order (SPL-1034)

Owner, prd t1 topic `49a2588c-3e19-453c-a7b4-e7a644db9de1`, 2026-09-28: "one should be able to drag and
drop the channels to define their order".

- The same drag layer as 3.1, two gestures on the Channels list of the left panel: a drag of a CHANNEL
  row reorders the list (pointer drag, already built, until now forgotten on reload); a drag of a TOPIC
  card onto a channel row moves the topic (3.1).
- The order is **per person and per tenant** (a channel id means nothing in another tenant), kept on the
  membership: `tenant_memberships.channel_order text[]` (rdb `0073`). NULL = never set = today's order.
- Rendering: the stored ids first, in their order; a channel the list does not name (new, or created by
  someone else later) follows them in today's order, so it appears at the END; a stored id that no
  longer exists (deleted, or no longer readable) is ignored.
- Keyboard / touch: the channel row menu gets **Move up** and **Move down**; each stores the whole
  displayed order. Phones use the menu (a long-press drag is not offered: it fights the list's scroll).
- Nobody else is affected: another member's order is their own row.

Wire (`contracts/move-v1.md` §7):

- `GET /v1/view/me` answers `channel_order: [ids] | null` beside `role`.
- `PUT /v1/me/channel-order` `{"channel_order": ["a", "b", ...]}` -> `200 {"channel_order": [...]}`,
  normalized (`#` dropped, lower case), duplicates removed, at most 200 ids, each a valid channel id
  (else `400 bad_json`); `[]` clears it (`null`). A signed-in member only (`403 forbidden`); a person
  with no membership row in this tenant `404 not_member`. No billing gate: it is a view preference.

## 4. Data (rdb `0069`)

`messages` gets five nullable columns and one partial index; nothing is backfilled.

| column | set by | meaning |
|---|---|---|
| `moved_at timestamptz` | every move; NULL again when a row returns home | the latest move |
| `moved_by text` | idem | the mover's v:1 id |
| `moved_from_channel text` | the first move of a row | its home channel |
| `moved_from_task uuid` | the first message move of a row | its home task (3.2 rows only) |
| `moved_from_parent uuid` | idem | its home `parent_task_id`, restored when it moves back home |

`messages_moved ON messages (tenant_id, task_id) WHERE moved_at IS NOT NULL` — only moved rows, used by
3.7. The runtime role already has `UPDATE` on `messages` (the archive and kind paths use it).

## 5. Functional requirements

| id | requirement | status |
|---|---|---|
| FR-MV-001 | rdb 0069: the five columns and `messages_moved`; applied dev + prd before any hub reads them | Implemented — `tasks.md` |
| FR-MV-002 | `POST /v1/messages/{msg_id}/move` `{to_channel}` moves a topic (3.1) in ONE transaction; §3.4 gate; the 3.1 refusals | Implemented — `tasks.md` |
| FR-MV-003 | `POST /v1/messages/{msg_id}/move` `{to_task}` moves a reply and its thread (3.2) in ONE transaction; §3.4 gate; the 3.2 refusals; the order rule | Implemented — `tasks.md` |
| FR-MV-004 | a move back home clears the stamp (3.3); the answer carries `undo` | Implemented — `tasks.md` |
| FR-MV-005 | every view element of a moved row carries `channel`, `task_id`, `parent_task_id`, `moved_at`, `moved_by`, `moved_from_channel`, `moved_from_task?` beside the envelope; the WUI lets them win over `env` | Implemented — `tasks.md` |
| FR-MV-006 | `GET /v1/view/messages/{msg_id}/move` answers what the caller may do with the row | Implemented — `tasks.md` |
| FR-MV-007 | live frames `topic_moved` / `message_moved` (3.6) | Implemented — `tasks.md` |
| FR-MV-008 | a tagged reply on a moved topic is stored in the topic's current channel (3.7) | Implemented — `tasks.md` |
| FR-MV-009 | WUI: drag a middle card onto a left-rail channel; drag a right-pane reply onto a middle card; drop targets highlight only where the move is allowed | Implemented — `tasks.md` |
| FR-MV-010 | WUI: card menu **Move to channel…** / **Move to topic…** with a picker (keyboard and touch path) | Implemented — `tasks.md` |
| FR-MV-011 | WUI: "Moved to … · Undo" for 8 s; the "moved from …" note | Implemented — `tasks.md` |
| FR-MV-012 | WUI: an old channel URL of a moved topic redirects to the new channel | Implemented — `tasks.md` |
| FR-MV-013 | every new string in all 19 locales | Implemented — `tasks.md` |
| FR-MV-014 | rdb 0073 `tenant_memberships.channel_order`; `GET /v1/view/me` carries it; `PUT /v1/me/channel-order` (3.8) | Planned |
| FR-MV-015 | WUI: the Channels list renders the stored order (new channels at the end), a drag stores it, Move up / Move down in the row menu (3.8) | Planned |

## 6. Success criteria

- **SC-MV-1**: hub tests on memory + Postgres: a topic move changes the channel of every row of the
  topic and nothing else; a message move re-homes the row and its thread; move-home clears the stamp;
  one refused case per row of §3.4 and per refusal of 3.1 / 3.2 (a control: the same case passes with
  the gate removed); a reply with the old tag lands in the new channel.
- **SC-MV-2**: WUI e2e: both drags, the menu path, the undo, and a refused drop (a non-author's card is
  not draggable; a channel the caller may not post in is not a drop target).
- **SC-MV-3**: live proof in the prd `e2e` tenant and the dev test tenant only, with a DB count of the
  rows per channel / task before and after, and screenshots posted in both owner topics.

<!-- version: 0.3.0 · updated: 2026-09-28 · last-edit: 2026-09-28T06:20:00Z -->
