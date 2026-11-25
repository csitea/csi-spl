# Spec 195: Revoke a Message Card or a Whole Topic

Status: **Draft v0.1** (2026-11-25). Lane `c-210` (`claude`; agy, the main
vendor for `specs_and_docs`, is on its usage limit). Doc only.
Epic: **SPL-21**. Issue: **SPL-6448**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:8bdf63d0-a656-4841-9fbf-db81c926f4af` (`t1` #spool-hub-biz).
Builds on: [003 spool message bus](../003-spool-message-bus/spec.md) (the
v:1 message, the box wire), [041 archive and delete a topic](../041-spool-topic-archive-delete/spec.md)
(the topic set walk, the card menu's Archive / Delete, the issue follow),
[032 edit a message](../032-spool-message-edit/spec.md) (the author door and
the revision register) and [185 forward](../185-message-forward/spec.md)
(a hub-only marker column).

Line references were measured on `origin/master` `faae9f399`.
Number 195: `origin/master` ends at `194-workspace-google-drive-upload`
(193 is absent there); of every `origin/review/*` branch only
`review/c-774-spl6375-skills-per-kind` holds a folder above 192
(`193-skills-per-agent-kind`), so 195 is the next number no branch holds
(`git ls-tree --name-only <ref> csi-spl-doc/specs/` over all
`refs/remotes/origin/review/*`).

## 0. The owner's words (HUM-10, t1 8bdf63d0, 2026-11-24, verbatim)

- msg `50443123` (09:08:36Z): "we need the feature for revoking a msg card ,
  so that it will be visible in the ui , but he agents would know that once
  revoked it's txt must not be taken into the prompt and the history and
  actually if it has been prompting for actions those should be also revoked
  and undone or scheduled to be undone if possible"
- msg `f17ba61d` (09:09:10Z): "it could be on the right click menu on the msg
  card , the same should be possible to be done on entire topics as well ..."

Read as four requirements:

| R | requirement |
|---|---|
| R1 | A card can be revoked from its right-click menu; a topic from its menu. |
| R2 | A revoked card stays visible in the UI, marked as revoked. |
| R3 | No agent takes a revoked card's text into a prompt or a history again. |
| R4 | What the card asked for is undone, or scheduled to be undone, where possible; the rest is named. |

## 1. Decided by this spec (say so in the topic if any is wrong)

| D | decision | why |
|---|---|---|
| D1 | Revoke is **not a delete**: the row stays, with `revoked_at` / `revoked_by` / `revoke_id`; the text stays in the store. | R2 wants it visible; a hard delete already exists (`DELETE /v1/messages/{msg_id}`, `edit.go:387`) and removes the row for good. Keeping the text also lets an admin see what was revoked. |
| D2 | A revoke **can be undone** (Unrevoke), and both are recorded in an append-only log. Unrevoke makes the text readable again and tells the agents; it **never redoes** an action the revoke undid. | A topic revoke on the wrong row is costly; the log is the audit; redoing work is a new request, not an undo. Q3 asks the owner. |
| D3 | Agents are told with a normal v:1 message of kind `note` whose first line is `REVOKED <msg_id>` (or `REVOKED-TOPIC <task_id>`), never with the text. No new kind. | `validKinds` (`internal/msg/msg.go:52-57`) and the `messages.kind` CHECK would need widening, and an older reader refuses an unknown kind; a `note` reaches every reader today. |
| D4 | The hub tells box sidecars with a new frame `revoke`; an old sidecar ignores it. | The box client's frame switch falls through to `default:` (`internal/hubclient/hubclient.go:661`). |
| D5 | Local copies are **moved**, not deleted, into `<spool root>/<id>/revoked/`, which `recv` and `tail` never read. | Unrevoke (D2) moves them back; audit stays possible on the box. |
| D6 | A topic revoke is one `revoke_id` over the same set `DeleteTopic` walks (card + children, message-rooted threads, sub-tasks; `store/topic_archive_postgres.go:160`). | One walk, already tested; Unrevoke of the topic is one id. |
| D7 | Nothing that touches prd or git history is undone without the owner's go (section 6.2). | Owner rule for prd mutations and history. |

## 2. Terms

| term | meaning |
|---|---|
| card | any stored message drawn in a feed or a topic pane (spec 041 section 2 uses "card" for a level-1 row; here it is any message) |
| revoke | the act of marking a card (or every card of a topic) revoked |
| revoke id | the uuid of one revoke act; a topic revoke marks many rows with one id |
| copy | any place the card's text was written outside its `messages` row |
| effect | anything the card caused: an ask, a queued spawn, a lane, an issue, a post, a commit, a deploy, an apply |

## 3. What exists today (measured)

There is **no** revoke, tombstone or "deleted but shown" state for a
message: no migration adds a revoked or deleted column to `messages`
(`grep -hiE 'ALTER TABLE messages.*ADD COLUMN' csi-spl-rdb/src/sql/postgres/spool-hub/*.sql | grep -ciE 'revok|delet'`
-> 0; the one `revoked_at` in `0001_hub_core.sql:33` belongs to another
table, above `messages` at `:57`). `revoke` in code exists
only for invites, join tokens, seats, keys and operators
(`csi-spl-orc/src/bash/run/spl-box-operator-revoke.func.sh`,
`csi-spl-api/src/go/spool-hub-api/internal/hub/join_tokens.go`).

Paths below: `api/` = `csi-spl-api/src/go/spool-hub-api/`,
`orc/` = `csi-spl-orc/src/bash/`, `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`wui/` = `csi-spl-wui/src/`.

### 3.1 How cards and topics are stored, edited, archived and deleted

- **The row.** `messages` is created at `rdb/0001_hub_core.sql:57`
  (`body`, `files`, the signed `env` bytea and `env_sig`, `kind` CHECK at
  `:68`, `expires_at`). Later columns: `is_parent` (0034), `edited_at` /
  `edited_by` (`0026_message_revisions.sql:37-39`), `archived_at` /
  `archived_by` (`0065_messages_archived.sql:16-17`), `mirror_of` (0112),
  `copied_from` (0250). Highest migration on disk: `0323_fleet_ask_queue_order.sql`.
- **Edit.** `PATCH /v1/messages/{msg_id}` (`api/internal/hub/server.go:568`,
  `handleEditMessage`, `edit.go:67`): author only, "not the tenant owner,
  not an admin" (`edit.go:178-188`, 403 `not_author`); a box-signed
  envelope is `not_editable` (`edit.go:204`). Frame `message_edited`
  (`edit.go:44`). Every body is kept in `message_revisions`
  (`0026_message_revisions.sql:41-54`). The WUI shows "(edited)"
  (`wui/components/MessageCard.vue:163-167`).
- **Delete one message.** `DELETE /v1/messages/{msg_id}`
  (`server.go:569`, `handleDeleteMessage`, `edit.go:387`): author only
  (`edit.go:423`), browser-sent only (`edit.go:429`), hard delete with
  cascade (`api/internal/store/message_edit_postgres.go:168`). Frame
  `message_deleted` (`edit.go:381`); the WUI drops the row, no marker.
- **Archive / delete a topic (spec 041).** `PUT|DELETE /v1/messages/{msg_id}/archive`
  and `DELETE /v1/messages/{msg_id}/topic` (`server.go:580-582`). Delete
  needs `mayChangeTopic` (`topic_archive.go:188`: the card's author, the
  tenant owner, or role `admin`); archive follows the workspace setting
  `tenants.topic_archive_policy` (`everyone|admins|starter`,
  `rdb/0093_tenant_topic_archive_policy.sql:20-24`; `mayArchiveByPolicy`,
  `topic_archive.go:172`). Frames `topic_archived` / `topic_deleted`
  (`topic_archive.go:38-39`). Archive sends the topic's open issues to
  `diss` and Unarchive restores them (`api/internal/store/issue_follow.go:10-24`).
- **Hide.** `message_moderation.hidden` (`rdb/0128_message_moderation.sql:23-31`,
  `PUT|DELETE /v1/messages/{msg_id}/hidden`, `api/internal/hub/demo_moderation.go:216-217`)
  works in the demo workspace only (`demo_moderation.go:25-28`), and no box
  read filters on it.
- **The WUI card menu.** `msgMenuItems` (`wui/utils/msg-menu.mjs:102`)
  builds the entries; Edit at `:132`, Archive at `:137`, Delete topic at
  `:157`, Delete message at `:160`. The right-click is `MessageCard.vue:32`
  (`@contextmenu="onContextMenu"`); the handlers are in
  `wui/composables/useCardTopicActions.ts` (`onMenuArchive` `:64`,
  `onMenuDeleteTopic` `:87`, `onMenuDelete` `:100`). The topic menu on the
  left rail / Flow / Topics home is `wui/utils/topic-menu.mjs`
  (`topicMenuLocks` `:38`, `topicCardMenuOpts` `:78`). The WUI's admin roles
  are `['biz_owner','admin']` (`wui/utils/topic-archive.mjs:20`); the hub's
  topic delete checks `TenantOwner || Has(rbac.Admin)` only
  (`topic_archive.go:193`).

### 3.2 How an agent's prompt and history are built from cards

| path | where | reads |
|---|---|---|
| `spool recv` / MCP `spool_recv` | `api/cmd/spool/main.go:547` -> `api/internal/spool/spool.go:463`; MCP `api/internal/mcp/mcp.go:171` | local `<root>/<id>/inbox` files only; `--compact` prints the full body (`main.go:583`) |
| `spool tail --task` / MCP `spool_tail` | `main.go:624` -> `spool.go:540` (`allBoxes` `:551`); MCP `mcp.go:179` | inbox, outbox **and archive** of every agent on the box |
| `spool tail --url` / MCP `spool_read_link` | `api/internal/action/link.go:321`; MCP `mcp.go:198` | hub `tail` frame |
| `spool hub-tail` | `api/cmd/spool/hub.go:1481` | hub `tail` frame, `--follow` live |
| hub `tail` frame | `api/internal/hub/ws.go:1176` -> `BoxTaskEnvelopes` (`api/internal/store/postgres.go:670`) | `messages.env`, filtered by `expires_at` and delivery only |
| queued delivery | `QueuedFor` (`postgres.go:609`), `push` (`ws.go:483`) | `deliveries` state `queued` (`rdb/0001_hub_core.sql:93-94`: `queued|sent|expired`) |
| channel backfill | `ChannelBackfill` (`api/internal/store/backfill_postgres.go:32`) | channel rows since a time |
| hub fallback sweeps | `UnheardPosts` / `UnansweredPosts` / `ReescalatablePosts` (`api/internal/store/fallback_postgres.go:106,136,160`) | `messages.env`, re-delivered |
| desk sidecar into an inbox | `spool hub-run` (`orc/run/spl-desk-up.func.sh:95`) -> `receive` (`api/internal/hubclient/hubclient.go:1011`) -> `writeBoxRing` (`spool.go:416`), "the ONE place a message enters a local agent's inbox" (`spool.go:435-441`) | writes the file, then `notify.Deliver` |
| pane poke | `spool-notify.sh` / `spool_notify_render_prompt` (`orc/features/spawn-agents/lib/spool-notify.inc.sh:98`) | **types the body into the agent's TUI**: from there it is in the vendor transcript |
| orc unanswered sweep | `do_spl_unanswered_sweep` (`orc/run/spl-unanswered-sweep.func.sh:120`), `left(l.body, 400)` at `:575`, cache `dispatch/unanswered.rows` (`:86-87`) | body excerpt sent as a spool note |
| asks book | `fleet_asks.summary` (`rdb/0097_fleet_asks.sql:47`), `spool_ask_summary` (first line, <= 200 bytes, `orc/features/spawn-agents/lib/spool-asks.inc.sh:31`); local `<root>/asks/<id>.json` | re-sent by `do_spl_asks_tick` |
| search | `GET /v1/view/search` (`api/internal/hub/search.go:51`), `SearchMessages` (`api/internal/store/search_postgres.go:416`) | WUI only; already filters archived (`archivedHideSQL`, `:454`) |
| `spool_flow` | `mcp.go:188`; `api/internal/hub/flow_fold.go:35,56` | fold lines carry `Text` |

Nothing on the box handles a delete or an edit: the only `os.Remove` calls
in `api/internal/spool/` and `api/internal/hubclient/` remove temp, pending
and blob files. A hub-side delete therefore never reaches a copy already
delivered.

### 3.3 Every place a card's text is copied to

| copy | where | carries the source msg id? |
|---|---|---|
| inbox / archive / outbox files, FleetRoot bridge | `spool.go:416`, `:395`, `:501-505` | yes (the v:1 `id`) |
| `.hub/pending` (outgoing) | `api/internal/hubclient/flush.go:298` | yes |
| vendor transcript (one `.jsonl` per session under the vendor CLI's own home dir) | written by the vendor CLI after the poke | no: free text |
| a spawn brief | `<root>/dispatch/briefs/<slug>.md`, `spawn-remote/briefs/<msg_id>.md` (`orc/features/spawn-agents/scripts/spawn-remote.sh:49`), `lifetime/brief.md` | **no**: `Ask-Topic: <topic>` only (`orc/run/spl-spawn-place.func.sh:947-958`); the owner's words are quoted by hand with short msg ids |
| owner orders ledger + the brief section | `<root>/owner-orders/<repo>.jsonl` (`orc/run/spl-owner-order.func.sh:3-7`), `oo_section` (`orc/features/spawn-agents/lib/owner-orders.inc.sh:96`) | **yes**: keyed by the owner's full msg uuid |
| asks book | `fleet_asks.summary` | **no**: `ask_id` is the agent's ask message, `topic` the topic (`rdb/0097_fleet_asks.sql`) |
| issues | issue card `## Source /t/<topic>` (`orc/run/spl-lane-issue.func.sh:978-990`), comments | topic only; a msg id only via `ISSUE_OWNER_GO` (`orc/run/spl-issue-create.func.sh:28`) |
| forwards and copies | `mirror_of` (0112), `copied_from` (0250), spec 185 `fwd_of` | yes, a column |
| poll answers | a reply with `Poll: <msg_id>` (`wui/utils/poll.mjs:20-31`) | yes, the poll |
| unanswered rows cache, sweep notes | `dispatch/unanswered.rows` | per row |
| release notes, commit links | commit trailers (`csi-spl-doc/doc/help/release-notes.md`), commit -> issue -> topic (`orc/run/spl-commit-links-check.func.sh`) | no |
| topic PDF export | `GET /v1/topics/{task_id}/export.pdf` (`api/internal/hub/topic_export.go:37`) | n/a (a file the user saved) |

### 3.4 What already undoes an effect

- A spawn request not yet started: `spawn-remote.sh --cancel` (`spawn-cancel v1`, `spawn-remote.sh:92`).
- A queued ask: `spl_spawn_q_op decline` (`orc/run/spl-spawn-queue.func.sh:180`), used today when the row's topic is archived (`spl-spawn-place.func.sh:919-942`); `do_spl_ask_close` (done / declined with a reason, `orc/run/spl-ask-close.func.sh:18`). States `open|acked|queued|done|declined|dead` (`rdb/0180_fleet_asks_queue.sql:30-32`).
- A running lane: `do_spl_archived_seats_free` (`orc/run/spl-archived-seats-free.func.sh`) frees the seats of an archived topic, binding by `Ask-Topic:` / `Topic:` / `Discussion:` of `lifetime/brief.md`.
- An issue: archive -> `diss`, unarchive restores (`issue_follow.go`); `LANE_ISSUE_OP=end`.
- An owner order: `ORDER_CMD=lift` with the owner's lifting msg uuid (`spl-owner-order.func.sh:223-239`).
- A purge: `do_spl_msg_purge` / `do_spl_msg_purge_undo` (undo file first).

### 3.5 The gap

| G | missing |
|---|---|
| G1 | a revoked state on a row that keeps it visible (columns, log) |
| G2 | the revoke / unrevoke endpoints, the authz door, the frames |
| G3 | the WUI menu entries, the revoked rendering, the Unrevoke |
| G4 | every hub read that feeds an agent filtering revoked rows (tail, queued, backfill, fallback sweeps, flow, search) |
| G5 | the box learning of a revoke: the `revoke` frame, moving local copies, `recv` / `tail` skipping them |
| G6 | the agent notice and the seed rule that tells an agent what to do with it |
| G7 | the orc reads (unanswered sweep, asks book, its tick) dropping revoked text |
| G8 | the source message id carried by briefs, asks and issues, so a revoke can find its effects |
| G9 | the effect walker: per kind, undo, schedule, or flag to the owner |

## 4. Revoke a card, revoke a topic

### 4.1 Who may

| act | allowed to | why |
|---|---|---|
| revoke a card the person wrote (browser-sent) | its author | the person who said it may take it back |
| revoke any card, an agent's (box-signed) card included | tenant owner, role `admin` | an agent's card cannot be edited or deleted by anyone today (`edit.go:204`, `:429`); an admin must be able to stop what an agent said |
| revoke a topic | `mayChangeTopic` (`topic_archive.go:188`): the opening card's author, tenant owner, `admin` | the same door as Delete topic: a topic revoke reaches other people's cards |
| unrevoke | whoever may revoke it now | |
| an agent revokes | no one | a revoke is a person's act; an agent that wants its own card revoked asks the holder |

A new workspace setting `tenants.message_revoke_policy`
(`authors_and_admins` default | `admins`) narrows the first row, the way
`topic_archive_policy` does for archive. Fix the WUI / hub mismatch on the
way: the hub door counts `biz_owner` as admin if and only if the WUI does
(row T2; `topic-archive.mjs:20` vs `topic_archive.go:193`). Open: Q1.

An archived topic: revoke is **allowed** (it is not input; spec 041's
`topicOpenDoor` refuses input, `api/internal/hub/topic_archived_input.go:78`).

### 4.2 What the UI shows

- **Menu.** On the card's right-click / ⋯ menu, an entry "Revoke…" after
  Edit (`msg-menu.mjs:132`), danger-styled, gated with the `locks` pattern
  (disabled with the reason for a viewer who may not). On a revoked card it
  reads "Unrevoke". The topic menu (`topic-menu.mjs`, every topic list, and
  the opening card's menu) gets "Revoke topic…" next to Archive. The phone's
  long-press sheet lists both (unlike Forward): revoking is urgent. Q7.
- **Confirm.** A dialog: what is revoked (one card, or the topic and its N
  replies, the count from `GET /v1/view/messages/{msg_id}/topic`), an
  optional reason (<= 200 characters, Q4), and the list of effects the hub
  found (section 6), each with what will happen to it.
- **The revoked card.** Stays in place. Its body and files are replaced by
  one line: "Revoked by <name>, <time>" plus the reason, with a revoked
  icon. The author, the revoker, the tenant owner and admins see a "Show
  text" toggle that shows the original struck through; nobody else gets the
  text (the hub does not send it to them, 4.3). Reactions, the poll form and
  file links are not drawn. The composer stays open in the topic. Q2.
- **The revoked topic.** Its row in every list carries the revoked mark and
  stays (it is not archived); opening it shows every card revoked.
- **Live.** Every browser on the topic gets the frame and redraws the card
  at once.

### 4.3 Wire and store

- **rdb `<next>_messages_revoked.sql`** (take the number with
  `do_rdb_migration_next`):
  - `messages.revoked_at timestamptz NULL`, `revoked_by text NULL`,
    `revoke_id uuid NULL`; partial index `(tenant_id, revoke_id) WHERE revoke_id IS NOT NULL`.
  - `message_revocations` (append-only, RLS like every tenant table):
    `tenant_id`, `revoke_id`, `op` (`revoke|unrevoke`), `scope`
    (`card|topic`), `root_msg_id`, `n_rows`, `by`, `at`, `reason`
    (<= 200), `effects jsonb` (the walker's plan and its outcome per
    effect, section 6). One row per act; unrevoke writes its own row with
    the same `revoke_id`.
  - `tenants.message_revoke_policy text NULL` CHECK in
    (`authors_and_admins`, `admins`).
- **HTTP.** `PUT /v1/messages/{msg_id}/revoke` (body `{scope: card|topic, reason}`),
  `DELETE /v1/messages/{msg_id}/revoke` (unrevoke of that row's
  `revoke_id`), `GET /v1/messages/{msg_id}/revoke/effects` (the dry plan
  for the dialog). Errors: `not_found` (404, also for unreadable),
  `not_allowed` (403), `already_revoked` / `not_revoked` (409),
  `not_a_card` (409, topic scope on a non-opening row).
- **View rows.** A revoked row comes back with `revoked: {at, by, reason}`
  and, for the viewers allowed to see it, `body` / `files`; for everyone
  else `body: ""`, `files: []`.
- **WUI frames** (`wui-live-ws.md` section 3.2): `message_revoked`
  `{msg_id, task_id, channel, revoke_id, at, by, reason}`,
  `message_unrevoked` `{msg_id, task_id, revoke_id}`, `topic_revoked` /
  `topic_unrevoked` `{root_msg_id, task_ids[], revoke_id, at, by}`.
- **Box frame** `revoke` `{revoke_id, op, msg_ids[], task_ids[]}`, sent to
  every box that holds a delivery of any of the rows (`deliveries`) or is
  an end (`from_box` / `to_box`), and queued for an offline box like any
  delivery. An old sidecar ignores it (D4).
- **The revoke is recorded twice**: in `message_revocations`, and as the
  agent notice (D3) stored in the topic like any message, so it is in the
  topic's history in order.

## 5. Agents

### 5.1 The text never enters a prompt again

Every hub read that serves a box adds `AND m.revoked_at IS NULL` (or
blanks `env` for a revoked row where the read must keep its place):

| read | change |
|---|---|
| `BoxTaskEnvelopes` (`postgres.go:670`): hub `tail`, `hub-tail`, `spool_read_link` | skip revoked rows |
| `QueuedFor` (`postgres.go:609`) | skip; the revoke also sets those deliveries `expired` (no new state needed) |
| `ChannelBackfill` (`backfill_postgres.go:32`) | skip |
| `UnheardPosts` / `UnansweredPosts` / `ReescalatablePosts` (`fallback_postgres.go:106,136,160`) | skip: a revoked post is never "unanswered" |
| `spool_flow` fold (`flow_fold.go`) | the line's `Text` is blanked, `revoked: true` |
| `SearchMessages` (`search_postgres.go:416`) | a revoked row matches only for the viewers of 4.2 who may see the text |
| topic PDF export (`topic_export.go`) | the revoked line, never the text |
| orc unanswered sweep SQL (`spl-unanswered-sweep.func.sh:548-575`) | `AND l.revoked_at IS NULL`; a revoke frame on the desk drops the row from `dispatch/unanswered.rows` |
| asks book | an ask whose source message (G8) is revoked: `summary` is replaced by `revoked <revoke_id>`, the state goes `declined` with reason `revoked` (6.2) |

### 5.2 Copies already delivered

| copy | what happens | retract or flag |
|---|---|---|
| inbox / archive / outbox / FleetRoot files on each box | the sidecar, on the `revoke` frame, moves each file of the msg id into `<root>/<id>/revoked/` (D5); `recv` and `tail` (`spool.go:463`, `:540`) never read that dir | **retracted** |
| `.hub/pending` (an unsent outgoing card) | not possible: a revoke needs a stored row | n/a |
| the text already typed into a pane, the vendor transcript | cannot be removed: the transcript is the vendor's file, and editing a live session's file corrupts it | **flagged**: the agent gets the notice (5.4) |
| a brief that quoted the card | the brief files are not rewritten (a live lane holds `lifetime/brief.md`); the lane gets the notice; a brief not yet launched is refused by the placer (5.3) | flagged / refused |
| an owner order from the card | the ledger is append-only: the walker appends a `lift` with `ORDER_LIFT_MSG` = the revoke notice's msg id when the revoker is the owner; another revoker's revoke flags it to the owner | retracted by lift (owner) / flagged |
| issue description or comment that quoted it | flagged on the issue (a comment `revoked <msg_id>`); the text is not rewritten | flagged |
| forwards (`fwd_of`), copies (`copied_from`), DM mirrors (`mirror_of`) | revoked with the source in the same act (one hop by the column) | **retracted** |
| answers to a revoked poll | revoked with it | retracted |
| a saved PDF, an email, a chat post outside the hub | outside the hub | flagged |

### 5.3 What the placer and the dispatcher do

- **Source ids from now on (G8).** A brief carries one `Source-Msg: <uuid>`
  line per owner message it acts on (the placer writes them from the ask,
  the way `spl-spawn-place.func.sh:947` writes `Ask-Topic:`);
  `fleet_asks` gets `source_msg_ids uuid[]`; `do_spl_lane_issue place`
  records them on the issue. A brief without the line is bound by topic
  only (a topic revoke still finds it through `Ask-Topic:`).
- The placer refuses to launch a queued row whose `Source-Msg` is revoked
  (`decline`, reason `revoked <revoke_id>`), as it declines a row of an
  archived topic today (`spl-spawn-place.func.sh:919-942`).

### 5.4 How an agent mid-task is told

- The hub stores and delivers the notice (D3) on the revoked card's task,
  to every agent that holds a delivery of it, and to every lane whose brief
  names it (`Source-Msg`, or `Ask-Topic` for a topic revoke). Body:

  ```text
  REVOKED <msg_id>
  Revoke: <revoke_id> by <person> at <ts>
  Reason: <reason>
  Do not use the revoked text. Stop work it asked for; undo what is
  undoable per spec 195 section 6; report what you undid with kind result.
  ```

  The body never quotes the revoked text.
- Seed rule (T10): an agent that receives `REVOKED` stops using that text,
  does not cite it, and handles its own effects per section 6 (its
  unpushed commits dropped, its review branch closed, its open asks
  closed); a landed commit or a prd change is reported, never reverted by
  itself.
- An unrevoke sends `UNREVOKED <msg_id>`; the agent may read the text again
  but restarts nothing on its own (D2).

## 6. Actions the card prompted

### 6.1 Finding them (the effect walker)

`GET …/revoke/effects` and the revoke itself run the walker, hub side, over
what can be traced to the revoked msg ids (or, for a topic, its task ids):

| effect | traced by |
|---|---|
| replies, forwards, mirrors, copies, poll answers | `task_id`, `fwd_of`, `mirror_of`, `copied_from`, `Poll:` |
| asks | `fleet_asks.source_msg_ids` (G8), `fleet_asks.topic` |
| queued spawns | the ask's `placement`, state `queued` |
| lanes | hub lane rows by topic (`api/internal/hub/lanes_registration.go`), `Source-Msg` in the brief |
| issues | issues linked to the topic; `ISSUE_OWNER_GO` = the msg id |
| owner orders | the ledger's `order` = the msg uuid |
| posts by agents in reply | rows in the task after the card, from agents |
| commits, deploys | commit -> issue key -> topic (`spl-commit-links-check.func.sh`); release tags on those commits |
| terraform applies | a commit or an issue of the topic naming a step; flagged only |

The walker reports what it could not trace (a lane with no `Source-Msg`, a
copy outside the hub) as "unknown", never as "none": a control that only
detects what was guessed cannot prove absence.

### 6.2 Per kind

| effect | outcome | how |
|---|---|---|
| ask `open` / `acked` | **undone** | `do_spl_ask_close` state `declined`, reason `revoked <revoke_id>` |
| spawn `queued`, request not started | **undone** | `decline` / `spawn-cancel v1` |
| lane running | **scheduled** | the notice (5.4); the lane stops, ends its issue `diss` reason `revoked`, then the seat is freed like `do_spl_archived_seats_free`. Q5 |
| issue `eval`, `todo`, `wip`, `blocked`, `onhold` | **undone** | to `diss`, the previous status kept like the archive follow (`issue_follow.go`), restored on unrevoke |
| issue `done` | **flagged** | the work landed |
| agent posts and replies the card caused | **flagged**, revocable by an admin as one more revoke | they are the agent's words, not the revoked text |
| owner order | **undone** by the owner's revoke (lift) | else flagged |
| review branch, unpushed work | **scheduled** | the lane drops it on the notice |
| commit on master | **flagged, not undoable** | a revert is a new commit and needs the owner's go (D7); history is never rewritten |
| deploy dev / prd | **flagged, not undoable** | a rollback is a prd mutation: the owner's go |
| terraform apply | **flagged, not undoable** | the owner's go per call |
| email, chat, calendar, payment | **flagged, not undoable** | outside the hub |

Every flagged effect becomes one line of one post to the dispatch holder
(kind `note`, on the revoked card's task), who turns the ones that need the
owner into a form. The revoke never waits on them: the text is withdrawn at
once, the effects follow. Q6.

## 7. Build rows

Each row is one lane and codes against section 4.3 (the contract), not
against another row's branch. T1, T5, T9 and T11 can start together.

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| T1 | rdb: columns, log table, policy | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_revoked.sql` | none | applies twice on a throwaway postgres; `\d messages` lists the 3 columns; `message_revocations` has RLS (`TestRLSCoversEveryTenantTable`) | the RLS test fails with the policy line removed |
| T2 | hub: revoke / unrevoke / effects endpoints, door, log, WUI frames | new `api/internal/hub/revoke.go` + test, `server.go`, `api/internal/store` (postgres + memory), `openapi.json` | T1 (pg tests) | Go tests on postgres: an author revokes an own card; an admin revokes an agent's card; a member is refused 403; a topic revoke marks the 041 set with one id; unrevoke clears it; view rows blank the body for non-viewers | the non-admin revoke of an agent card must be 403: the test fails with the door removed |
| T3 | hub: every box-facing read filters revoked (5.1) | `postgres.go` (`BoxTaskEnvelopes`, `QueuedFor`), `backfill_postgres.go`, `fallback_postgres.go`, `search_postgres.go`, `flow_fold.go`, `topic_export.go` | T1 | one test per read: a revoked row is absent or blanked | each test fails with its filter removed |
| T4 | hub: the box `revoke` frame and the stored notice | `api/internal/wire`, the `ws.go` fan-out, the notice writer | T2 | a box with a delivery gets the frame (online and after a reconnect); the notice is stored on the task without the revoked text | the notice test greps the body for the revoked text: fails if quoted |
| T5 | box: the sidecar moves copies to `revoked/`; recv / tail skip it | `api/internal/hubclient`, `api/internal/spool/spool.go` | the 4.3 frame contract | unit test: inbox, archive, outbox and FleetRoot copies move; `recv` and `tail` do not print them; unrevoke moves them back | remove the move: the recv test prints the text |
| T6 | WUI: menu entries, the confirm with effects, the revoked card, Unrevoke, frames | `wui/utils/msg-menu.mjs`, `wui/utils/topic-menu.mjs`, `MessageCard.vue`, new `RevokeDialog.vue`, `wui/utils/live-ws.mjs`, `wui/composables/useLive.ts`, `spool-client(-mock).mjs`, `i18n/locales/*.json` | 4.3 | `msg-menu.test.mjs` (Revoke gated by `locks`), a unit test of the revoked render (no body for a non-viewer), typecheck, i18n gates | drop the gate: the locked-viewer assertion fails |
| T7 | WUI e2e | new `csi-spl-wui/tests/e2e/msg-revoke.test.mjs` | T6 | on the generated bundle, mock-served: revoke a reply, it shows "Revoked by…", the text hidden; unrevoke restores it | the e2e fails when the entry is absent |
| T8 | i18n final language check | the non-en locale files | T6 landed | the language rule's check | `i18n-untranslated.test.mjs` |
| T9 | orc: source ids (G8) | `orc/run/spl-spawn-place.func.sh` (`Source-Msg:`), `spool-asks.inc.sh` + an rdb migration for `fleet_asks.source_msg_ids`, `spl-lane-issue.func.sh` | none | a placed brief carries `Source-Msg:` for the ask's msg; the ask row stores it | the brief test fails without the line |
| T10 | orc: effect outcomes, the placer refusal, sweep + asks drop, seed rule | new `orc/run/spl-revoke-effects.func.sh` + test, `spl-unanswered-sweep.func.sh`, `spl-asks-tick.func.sh`, `spl-spawn-place.func.sh`, the seed rule text under `orc/features/spawn-agents/assets/` | T2, T9 | on a test spool root: an open ask is declined `revoked`; a queued row is refused; a lane gets the notice; a landed commit is flagged, never reverted; the seed carries the rule | a revoked ask still offered by the tick fails the test |
| T11 | docs | `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (frames), `view-v1.md` (the row field), `http-v1.md` (routes), the user help for the card menu | 4.3 | the contracts name every field, route and error of 4.3 | a doc link check on the new anchors |
| T12 | live proof | none (a run) | T2-T7 deployed dev + prd | in the prd `e2e` tenant and the dev test tenant: revoke a card an agent received; `spool recv` and `hub-tail` on that agent's box do not show it; `message_revocations` count +1 | the same run before T3 shows the text |

Split: hub T1-T4, box T5, WUI T6-T8, orc T9-T10, docs T11, proof T12.

## 8. Open questions for the owner

1. **Who may revoke** a card: (a) its author, plus the tenant owner and
   admins for any card, an agent's too (4.1); (b) the tenant owner and
   admins only; (c) anyone who may post in the topic.
2. **What others see** on a revoked card: (a) "Revoked by <name>, <time>"
   and the reason, the text only for the author, the revoker and admins
   (4.2); (b) the text struck through for everyone; (c) the card
   disappears for everyone but admins.
3. **Can a revoke be undone**: (a) yes, by whoever may revoke, never
   redoing undone actions (D2); (b) no, a revoke is final.
4. **Reason**: (a) optional; (b) required.
5. **Running lanes the card started**: (a) stopped at once and their issue
   ended `diss` (6.2); (b) asked first: the holder sends you a form per
   lane.
6. **A topic revoke on a topic with landed commits or deploys**: (a)
   revoke the text now and send you a form listing what cannot be undone
   (6.2); (b) refuse the topic revoke until you decide on each.
7. **Phone**: (a) Revoke on the long-press sheet too (4.2); (b) desktop
   only, like Forward.

## 9. Not in this spec

- Reverting commits, rolling back deploys, destroying terraform resources:
  each stays a separate change with the owner's go.
- Rewriting vendor transcripts or saved files.
- Revoking by an agent.
