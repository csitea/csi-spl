# Spec 195: Revoke a Message Card or a Whole Topic

Status: **Draft v0.2** (2026-11-25). Lane `c-210` (`claude`; agy, the main
vendor for `specs_and_docs`, is on its usage limit). Doc only.
v0.1 `540e607d8`; v0.2 folds the spec review's W1-W6 and N1-N3 (a-353,
agy FAIL on v0.1, msg `c4ccdeb3`; holder send-back msg `a67f5dce`):
section 10.
Epic: **SPL-21**. Issue: **SPL-6448**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:8bdf63d0-a656-4841-9fbf-db81c926f4af` (`t1` #spool-hub-biz).
Builds on: [003 spool message bus](../003-spool-message-bus/spec.md) (the
v:1 message, the box wire), [041 archive and delete a topic](../041-spool-topic-archive-delete/spec.md)
(the topic set walk, the card menu's Archive / Delete, the issue follow),
[032 edit a message](../032-spool-message-edit/spec.md) (the author door and
the revision register). Touches [185 forward](../185-message-forward/spec.md)
(draft): its `fwd_of` column does not exist yet (5.2).

Line references were measured on `origin/master` `1bc99663b`.
Number 195: `origin/master` ends at `194-workspace-google-drive-upload`
(193 `skills-per-agent-kind` landed after v0.1), and no `origin/review/*`
branch holds a folder above 194 (`git ls-tree --name-only <ref> csi-spl-doc/specs/`
over all `refs/remotes/origin/review/*`).

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
| D4 | The hub sends the new box frame `revoke` **only to a box whose `hello` announced it** (a `caps` list on the hello frame, the way `MsgVersions` is announced, `internal/wire/wire.go:296`). A box that did not announce it gets no frame; its copies are flagged (5.2). | An old sidecar does **not** ignore an unknown frame: its `default:` case hands the frame to `s.replies` (`internal/hubclient/hubclient.go:661-665`, buffer 64, `:429`) and waits up to the client timeout, so 64 unasked frames would stall its read loop. |
| D5 | Local copies are **moved**, not deleted, into `<spool root>/<id>/revoked/<subdir>/<file>`, `<subdir>` being the one it came from (`inbox`, `archive`, `outbox`), FleetRoot copies the same under the FleetRoot. `recv`, `tail`, the hook and `agent-inbox.sh` never read `revoked/`. | Unrevoke (D2) moves each file back to its own subdir; audit stays possible on the box. |
| D6 | A topic revoke is one `revoke_id` over the same set `DeleteTopic` walks (card + children, message-rooted threads, sub-tasks; `store/topic_archive_postgres.go:160`). The topic revoke is undone only as a whole, on its root, by someone who may revoke the topic (4.1). | One walk, already tested; a reply's author cannot lift a topic revoke through the shared id. |
| D7 | Nothing that touches prd or git history is undone without the owner's go (section 6.2). | Owner rule for prd mutations and history. |

## 2. Terms

| term | meaning |
|---|---|
| card | any stored message drawn in a feed or a topic pane (spec 041 section 2 uses "card" for a level-1 row; here it is any message) |
| revoke | the act of marking a card (or every card of a topic) revoked |
| revoke id | the uuid of one revoke act; a topic revoke marks many rows with one id |
| copy | any place the card's text was written outside its `messages` row |
| effect | anything the card caused: an ask, a queued spawn, a lane, an issue, a post, a commit, a deploy, an apply |
| reader | any code that reads a message's `body` or `env` for someone other than the store |

## 3. What exists today (measured)

There is **no** revoke, tombstone or "deleted but shown" state for a
message: no migration adds a revoked or deleted column to `messages`
(`grep -hiE 'ALTER TABLE messages.*ADD COLUMN' csi-spl-rdb/src/sql/postgres/spool-hub/*.sql | grep -ciE 'revok|delet'`
-> 0; the one `revoked_at` in `0001_hub_core.sql:33` belongs to `pins`,
above `messages` at `:57`). `revoke` in code exists only for invites, join
tokens, seats, keys and operators
(`csi-spl-orc/src/bash/run/spl-box-operator-revoke.func.sh`,
`csi-spl-api/src/go/spool-hub-api/internal/hub/join_tokens.go`).

Paths below: `api/` = `csi-spl-api/src/go/spool-hub-api/`,
`orc/` = `csi-spl-orc/src/bash/`, `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`wui/` = `csi-spl-wui/src/`, `spawn/` = `orc/features/spawn-agents/`.

### 3.1 How cards and topics are stored, edited, archived and deleted

- **The row.** `messages` is created at `rdb/0001_hub_core.sql:57`
  (`body`, `files`, the signed `env` bytea and `env_sig`, `kind` CHECK at
  `:68`, `expires_at`). Later columns: `is_parent` (0034), `edited_at` /
  `edited_by` (`0026_message_revisions.sql:37-39`), `archived_at` /
  `archived_by` (`0065_messages_archived.sql:16-17`), `mirror_of` (0112),
  `copied_from` (0250). Highest migration on disk: `0323_fleet_ask_queue_order.sql`.
- **Topic heads.** `topic_heads` (`rdb/0144_topic_heads.sql`) keeps a
  topic list row per topic without body text; topic lists read it
  (`api/internal/store/view_topics_head.go`).
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
  and `DELETE /v1/messages/{msg_id}/topic` (`server.go:580-582`), with
  their CORS preflights (`server.go:570`, `:583-584`). Delete needs
  `mayChangeTopic` (`topic_archive.go:188`: the card's author, the tenant
  owner, or role `admin`); archive follows the workspace setting
  `tenants.topic_archive_policy` (`everyone|admins|starter`,
  `rdb/0093_tenant_topic_archive_policy.sql:20-24`; `mayArchiveByPolicy`,
  `topic_archive.go:172`). Frames `topic_archived` / `topic_deleted`
  (`topic_archive.go:38-39`). Archive sends the topic's open issues to
  `diss` and Unarchive restores them (`api/internal/store/issue_follow.go:10-24`).
  A reconnecting browser catches up through `ViewChanges`
  (`api/internal/store/view_changes_postgres.go:28-36`: kinds `new`,
  `edit`, `kind`, `archive`, ...; no revoke kind).
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
- **The box wire.** The sidecar's frame loop (`api/internal/hubclient/hubclient.go:615-668`)
  handles `recv`, `backfill_end`, `roster`, `box_sample`, `signin_relay`,
  `queue_end`; any other frame goes to `s.replies` (`:661-665`). Queued
  delivery to an offline box exists only for `messages` rows: `deliveries`
  references `messages` (`rdb/0001_hub_core.sql:88-100`).

### 3.2 Every reader that can put card text in front of an agent

Box-facing hub readers (the text leaves the hub towards a box):

| reader | where | reads |
|---|---|---|
| hub `tail` frame, `spool hub-tail`, `spool tail --url`, MCP `spool_read_link` | `api/internal/hub/ws.go:1176` -> `BoxTaskEnvelopes` (`api/internal/store/postgres.go:670`); `api/cmd/spool/hub.go:1481`; `api/internal/action/link.go:321`; `api/internal/mcp/mcp.go:198` | `messages.env` by task and delivery |
| `TaskEnvelopes` (`postgres.go:656`) | callers: `onTailCount` (`ws.go:1192`, a count), the topic loop's prompt (`api/internal/hub/topic_loop_fire.go:400`), reply routing (`topic_reply.go:31`, `:97`, `:99`), the retired-seat reply (`retired_reply.go:43`), the calendar operator (`calendar_operator.go:160`) | every `env` of a task |
| queued delivery, one box | `QueuedFor` (`postgres.go:609`), called on hello (`ws.go:466`) and by `push` (`ws.go:483`) | `deliveries` state `queued` (`rdb/0001_hub_core.sql:93-94`: `queued|sent|expired`) |
| queued delivery, relay tick | `QueuedForBoxes` (`postgres.go:636`), called by `api/internal/hub/relay.go:267` | the same, for many boxes |
| channel backfill | `ChannelBackfill` (`api/internal/store/backfill_postgres.go:32`) | channel rows since a time |
| fallback sweeps | `UnheardPosts` / `UnansweredPosts` / `ReescalatablePosts` (`api/internal/store/fallback_postgres.go:106,136,160`) | `env`, re-delivered |
| nacked re-delivery | `NackedPosts` (`api/internal/store/live_acks.go:81`), called by `api/internal/hub/live_ack.go:67` | `env`, re-delivered |
| unsigned WUI replay | `UnsignedWUIPosts` (`api/internal/store/replay_postgres.go:12`), called by `api/internal/hub/replay_unsigned.go:90` | unsigned WUI rows (`archived_at IS NULL` only) |
| agent topic list | `topic_list` frame (`api/internal/hub/topics_agent.go:53`, `:106`) | `agentTopic.Subject` (`:35`, `:121`), from the opening card's body |
| `spool_flow` | `mcp.go:188`; `api/internal/hub/flow_fold.go:35,56`; its SQL `api/internal/store/flow_fold.go:347` (`left(r.body, 400)` as the title) | fold lines' `Title` / `Text` |
| `spool_topic_pdf` | `mcp.go:208`; `GET /v1/topics/{task_id}/export.pdf` (`api/internal/hub/topic_export.go:37`) | the whole topic |

Box-local readers (the text is already on the box):

| reader | where | reads |
|---|---|---|
| `spool recv` / MCP `spool_recv` | `api/cmd/spool/main.go:547` -> `api/internal/spool/spool.go:463`; `mcp.go:171` | `<root>/<id>/inbox`; `--compact` prints the full body (`main.go:583`) |
| `spool tail --task` / MCP `spool_tail` | `main.go:624` -> `spool.go:540` (`allBoxes` `:551`); `mcp.go:179` | inbox, outbox **and archive** of every agent on the box |
| the agent hook | `spawn/scripts/spool-agent-hook.sh` (`inject`, `:20-24`; `inbox()` `:452-460`) | inbox files straight into the vendor's `additionalContext` on SessionStart / UserPromptSubmit / PostToolUse, without `spool recv` |
| `agent-inbox.sh` | `spawn/scripts/agent-inbox.sh` | the inbox dir |
| desk sidecar into an inbox | `spool hub-run` (`orc/run/spl-desk-up.func.sh:95`) -> `receive` (`hubclient.go:1011`) -> `writeBoxRing` (`spool.go:416`), "the ONE place a message enters a local agent's inbox" (`spool.go:435-441`) | writes the file, then `notify.Deliver` |
| pane poke | `spool-notify.sh` / `spool_notify_render_prompt` (`spawn/lib/spool-notify.inc.sh:98`) | **types the body into the agent's TUI**: from there it is in the vendor transcript |
| brief topic text | `spawn/scripts/topic-text.sh` (`:2-19`), called from `spawn/scripts/spawn-core.inc.sh:560` | **automatically** appends up to 20 human posts / 6144 bytes per linked topic, read with `spool hub-tail`, to the lane's `lifetime/brief.md` |
| orc unanswered sweep | `do_spl_unanswered_sweep` (`orc/run/spl-unanswered-sweep.func.sh:120`), `left(l.body, 400)` at `:575`, cache `dispatch/unanswered.rows` (`:86-87`) | body excerpt sent as a spool note |
| asks book | `fleet_asks.summary` (`rdb/0097_fleet_asks.sql:47`), `spool_ask_summary` (first line, <= 200 bytes, `spawn/lib/spool-asks.inc.sh:31`); local `<root>/asks/<id>.json` | re-sent by `do_spl_asks_tick` |

People-facing readers (WUI, view, embed) that a revoke must also cover
(4.3):

| reader | where | reads |
|---|---|---|
| topic read, lists | `GET /v1/view/topics/{task_id}` (`api/internal/hub/view.go:55`), lists from `topic_heads` | rows, subjects |
| reconnect delta | `ViewChanges` (`view_changes_postgres.go:28-36`, `GET /v1/view/topics?since=`) | change kinds |
| search | `GET /v1/view/search` (`api/internal/hub/search.go:51`), `SearchMessages` (`api/internal/store/search_postgres.go:416`; archived already hidden, `archivedHideSQL` `:454`) | body |
| link previews | `PreviewRows` (`api/internal/store/link_preview.go:103`, `POST /v1/view/previews`) | `left(m.body, $5)` |
| issue discussions | `DiscussionStates` (`api/internal/store/issue_discussions.go:387`, the read at `:383`) | `left(m.body, 2000)` |
| blocker answers | `BlockerAnswer` (`api/internal/store/blocker_issue.go:303`, the read at `:311`) | body, to decide an answer closes a blocker |
| embed visitors | `EmbedVisitorMessages` (`api/internal/store/embed_visitor_messages.go:44`, the read at `:48`) | body |

Nothing on the box handles a delete or an edit: the only `os.Remove` calls
in `api/internal/spool/` and `api/internal/hubclient/` remove temp, pending
and blob files. A hub-side delete therefore never reaches a copy already
delivered.

How the list was made, so a reviewer can re-run it:
`git grep -n -E 'FROM[[:space:]]+messages|JOIN[[:space:]]+messages' origin/master -- 'csi-spl-api/src/go/spool-hub-api/internal/store/*.go'`,
plus the MCP tools (`mcp.go:171-208`), the hub frames (`ws.go:164`) and
`grep -rln 'inbox' csi-spl-orc/src/bash/features/spawn-agents/scripts/`.
A reader the grep does not reach (a new one) is caught by T3's guard test,
not by this list.

### 3.3 Every place a card's text is copied to

| copy | where | carries the source msg id? |
|---|---|---|
| inbox / archive / outbox files, FleetRoot bridge | `spool.go:416`, `:395`, `:501-505` | yes (the v:1 `id`) |
| `.hub/pending` (outgoing) | `api/internal/hubclient/flush.go:298` | yes |
| vendor transcript (one `.jsonl` per session under the vendor CLI's own home dir) | written by the vendor CLI after the poke or the hook | no: free text |
| a spawn brief | `<root>/dispatch/briefs/<slug>.md`, `spawn-remote/briefs/<msg_id>.md` (`spawn/scripts/spawn-remote.sh:49`), `lifetime/brief.md` | **no**: `Ask-Topic: <topic>` only (`orc/run/spl-spawn-place.func.sh:947-958`) |
| a brief's "Topic text" section | `topic-text.sh`, appended at launch | **no**: the posts' text, read from the topic |
| owner orders ledger + the brief section | `<root>/owner-orders/<repo>.jsonl` (`orc/run/spl-owner-order.func.sh:3-7`), `oo_section` (`spawn/lib/owner-orders.inc.sh:96`) | **yes**: keyed by the owner's full msg uuid |
| asks book | `fleet_asks.summary` | **no**: `ask_id` is the agent's ask message, `topic` the topic (`rdb/0097_fleet_asks.sql`) |
| issues | issue card `## Source /t/<topic>` (`orc/run/spl-lane-issue.func.sh:978-990`), comments | topic only; a msg id only via `ISSUE_OWNER_GO` (`orc/run/spl-issue-create.func.sh:28`) |
| copies and mirrors | `mirror_of` (0112), `copied_from` (0250) | yes, a column |
| forwards | none yet: spec 185's `fwd_of` is a draft (`git grep -n fwd_of origin/master -- csi-spl-rdb/ csi-spl-api/` -> 0) | n/a until it lands |
| poll answers | a reply with `Poll: <msg_id>` (`wui/utils/poll.mjs:20-31`) | yes, the poll |
| unanswered rows cache, sweep notes | `dispatch/unanswered.rows` | per row |
| release notes, commit links | commit trailers (`csi-spl-doc/doc/help/release-notes.md`), commit -> issue -> topic (`orc/run/spl-commit-links-check.func.sh`) | no |
| topic PDF export | `topic_export.go:37`, also through MCP `spool_topic_pdf` | n/a (a file already saved) |

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
| G2 | the revoke / unrevoke endpoints, the authz door, the frames, the reconnect delta |
| G3 | the WUI menu entries, the revoked rendering, the Unrevoke |
| G4 | every reader of 3.2 skipping or blanking revoked rows |
| G5 | the box learning of a revoke: a capability-gated `revoke` frame, a queue for offline boxes, moving local copies, every local reader skipping them |
| G6 | the agent notice and the seed rule that tells an agent what to do with it |
| G7 | the orc reads (unanswered sweep, asks book, its tick, topic text) dropping revoked text |
| G8 | the source message id carried by briefs, asks and issues, so a revoke can find its effects |
| G9 | the effect walker: hub side (synchronous) and box side (asynchronous); per kind, undo, schedule, or flag to the owner |

## 4. Revoke a card, revoke a topic

### 4.1 Who may

| act | allowed to | why |
|---|---|---|
| revoke a card the person wrote (browser-sent) | its author | the person who said it may take it back |
| revoke any card, an agent's (box-signed) card included | tenant owner, role `admin` | an agent's card cannot be edited or deleted by anyone today (`edit.go:204`, `:429`); an admin must be able to stop what an agent said |
| revoke a topic | `mayChangeTopic` (`topic_archive.go:188`): the opening card's author, tenant owner, `admin` | the same door as Delete topic: a topic revoke reaches other people's cards |
| unrevoke a card revoke (`scope = card`) | whoever may revoke that card now | |
| unrevoke a topic revoke (`scope = topic`) | `mayChangeTopic` on the revoke's `root_msg_id`, read from `message_revocations`, never from the row the call names | D6: a reply's author must not lift the whole topic's revoke |
| an agent revokes | no one | a revoke is a person's act; an agent that wants its own card revoked asks the holder |

A new workspace setting `tenants.message_revoke_policy`
(`authors_and_admins` default | `admins`) narrows the first row, the way
`topic_archive_policy` does for archive. Fix the WUI / hub mismatch on the
way: the hub door counts `biz_owner` as admin if and only if the WUI does
(row T2; `topic-archive.mjs:20` vs `topic_archive.go:193`). Q1.

An archived topic: revoke is **allowed** (it is not input; spec 041's
`topicOpenDoor` refuses input, `api/internal/hub/topic_archived_input.go:78`).

A card inside a topic that is revoked as a whole cannot be revoked or
unrevoked on its own (`409 topic_revoked`) until the topic revoke is lifted.

### 4.2 What the UI shows

- **Menu.** On the card's right-click / ⋯ menu, an entry "Revoke…" after
  Edit (`msg-menu.mjs:132`), danger-styled, gated with the `locks` pattern
  (disabled with the reason for a viewer who may not). On a revoked card it
  reads "Unrevoke". The topic menu (`topic-menu.mjs`, every topic list, and
  the opening card's menu) gets "Revoke topic…" next to Archive; the
  opening card's menu therefore offers both. The phone's long-press sheet
  lists both. Q7.
- **Confirm.** A dialog: what is revoked (one card, or the topic and its N
  replies, the count from `GET /v1/view/messages/{msg_id}/topic`), a
  reason (optional, <= 200 characters; Q4), and the effects the hub found
  (`GET …/revoke/effects?scope=`, section 6.1), each with what will happen
  to it, the box-side ones listed as "checked after the revoke".
- **The revoked card.** Stays in place. Its body and files are replaced by
  one line: "Revoked by <name>, <time>" plus the reason, with a revoked
  icon. The author, the revoker, the tenant owner and admins see a "Show
  text" toggle that shows the original struck through; nobody else gets the
  text (the hub does not send it to them, 4.3). Reactions, the poll form,
  link previews and file links are not drawn. The composer stays open in
  the topic. Q2.
- **The revoked topic.** Its row in every list carries the revoked mark and
  stays (it is not archived); its subject reads "Revoked topic" for
  everyone without the "Show text" right; opening it shows every card
  revoked.
- **Live and on reconnect.** Every browser on the topic gets the frame and
  redraws at once; a browser that was offline gets the change from the
  reconnect delta (`ViewChanges`, kinds `revoke` / `unrevoke`).

### 4.3 Wire and store

- **rdb `<next>_messages_revoked.sql`** (take the number with
  `do_rdb_migration_next`):
  - `messages.revoked_at timestamptz NULL`, `revoked_by text NULL`,
    `revoke_id uuid NULL`; partial index `(tenant_id, revoke_id) WHERE revoke_id IS NOT NULL`
    and `(tenant_id, revoked_at) WHERE revoked_at IS NOT NULL` (for
    `ViewChanges`).
  - `message_revocations` (append-only, RLS like every tenant table):
    `tenant_id`, `revoke_id`, `op` (`revoke|unrevoke`), `scope`
    (`card|topic`), `root_msg_id`, `n_rows`, `by`, `at`, `reason`
    (<= 200), `effects jsonb` (the walker's plan and the outcome per
    effect, section 6). One row per act; unrevoke writes its own row with
    the same `revoke_id`.
  - `box_revokes` (RLS): `tenant_id`, `revoke_id`, `op`, `to_box`, `state`
    (`queued|sent`), `created_at`, `sent_at`; primary key
    (`tenant_id`, `revoke_id`, `op`, `to_box`). The queue of `revoke`
    frames for boxes that were offline (`deliveries` cannot hold them: it
    references `messages`).
  - `tenants.message_revoke_policy text NULL` CHECK in
    (`authors_and_admins`, `admins`).
- **HTTP.**
  - `PUT /v1/messages/{msg_id}/revoke`, body `{scope: card|topic, reason}`.
  - `DELETE /v1/messages/{msg_id}/revoke`: unrevoke. For a topic revoke
    it is accepted only on `root_msg_id` (`409 not_revoke_root` on a reply),
    authorized by 4.1 from the log row.
  - `GET /v1/messages/{msg_id}/revoke/effects?scope=card|topic` (default
    `card`): the dry plan for the dialog (6.1 part a).
  - `OPTIONS /v1/messages/{msg_id}/revoke` and
    `OPTIONS /v1/messages/{msg_id}/revoke/effects`, the preflights, as
    `server.go:570`, `:583-584` do for edit and archive.
  - Errors: `not_found` (404, also for unreadable), `not_allowed` (403),
    `already_revoked` / `not_revoked` (409), `not_a_card` (409, topic
    scope on a non-opening row), `not_revoke_root` (409), `topic_revoked`
    (409, 4.1), `bad_scope` (400).
- **View rows.** A revoked row comes back with `revoked: {at, by, reason}`
  and, for the viewers allowed to see it, `body` / `files`; for everyone
  else `body: ""`, `files: []`. The same blanking in every people-facing
  reader of 3.2: topic read, search, link previews (`PreviewRows`),
  `DiscussionStates`, embed visitors. Topic list rows join the opening
  card's `revoked_at` (`topic_heads` holds no body, so only the badge and
  the subject change).
- **WUI frames** (`wui-live-ws.md` section 3.2): `message_revoked`
  `{msg_id, task_id, channel, revoke_id, at, by, reason}`,
  `message_unrevoked` `{msg_id, task_id, revoke_id}`, `topic_revoked` /
  `topic_unrevoked` `{root_msg_id, task_ids[], revoke_id, at, by}`.
  `ViewChanges` gains kinds `revoke` / `unrevoke` from `message_revocations`.
- **Box frames.**
  - The box's `hello` gains `caps: ["revoke"]` (optional field, as
    `MsgVersions`, `wire.go:296`). The hub sends a box a `revoke` frame
    only when its current session announced the cap (D4).
  - `revoke` `{revoke_id, op, msg_ids[], task_ids[]}`: to every box that
    holds a delivery of any of the rows (`deliveries`) or is an end
    (`from_box` / `to_box`). Written first as `box_revokes` rows
    `queued`; sent at once to a connected box with the cap.
  - The box answers `revoke_ack {revoke_id, op}` once its local move is
    done; the hub sets the row `sent`. On `hello` the hub drains the box's
    `queued` rows after `QueuedFor`, oldest first, the same way.
  - A box without the cap keeps its `box_revokes` rows `queued`; the walker
    lists that box's copies as "flagged: box sidecar too old" (5.2).
- **The revoke is recorded twice**: in `message_revocations`, and as the
  agent notice (D3) stored in the topic like any message, so it is in the
  topic's history in order.

## 5. Agents

### 5.1 The text never enters a prompt again

Every reader of 3.2 changes as follows (`revoked` = `m.revoked_at IS NOT NULL`):

| reader | change |
|---|---|
| `BoxTaskEnvelopes` (`postgres.go:670`): hub `tail`, `hub-tail`, `spool_read_link` | skip revoked rows |
| `TaskEnvelopes` (`postgres.go:656`) | skips revoked rows for every caller: `onTailCount` counts only what `tail` returns; the topic loop (`topic_loop_fire.go:400`) never builds a prompt from a revoked card; reply routing (`topic_reply.go`) never routes to a revoked card's sender because of that card; `retired_reply.go` and `calendar_operator.go` likewise |
| `QueuedFor` (`postgres.go:609`), `QueuedForBoxes` (`postgres.go:636`) | skip; the revoke also sets those deliveries `expired` (no new state) |
| `ChannelBackfill` (`backfill_postgres.go:32`) | skip |
| `UnheardPosts` / `UnansweredPosts` / `ReescalatablePosts` (`fallback_postgres.go:106,136,160`), `NackedPosts` (`live_acks.go:81`) | skip: a revoked post is never "unanswered" nor re-delivered |
| `UnsignedWUIPosts` (`replay_postgres.go:12`) | skip, next to its `archived_at IS NULL` |
| `topic_list` (`topics_agent.go:106`) | a revoked opening card's subject is sent as `revoked` |
| `spool_flow`: `store/flow_fold.go:347` and `hub/flow_fold.go:56` | the SQL title is blanked for a revoked row; the line carries `revoked: true` and no `Text` |
| `spool_topic_pdf` / `topic_export.go` | the revoked line, never the text |
| `BlockerAnswer` (`blocker_issue.go:311`) | a revoked reply never answers (or closes) a blocker |
| orc unanswered sweep SQL (`spl-unanswered-sweep.func.sh:548-575`) | `AND l.revoked_at IS NULL`; the `revoke` frame on the desk drops the row from `dispatch/unanswered.rows` |
| asks book | an ask whose source message (G8) is revoked: `summary` becomes `revoked <revoke_id>`, the state goes `declined` with reason `revoked` (6.2) |
| `topic-text.sh` | reads through `hub-tail`, so it is covered by `BoxTaskEnvelopes`; a brief already written is flagged (5.2) |

### 5.2 Copies already delivered

| copy | what happens | retract or flag |
|---|---|---|
| inbox / archive / outbox / FleetRoot files on a box with the cap | the sidecar, on the `revoke` frame, moves each file of the msg id to `revoked/<subdir>/` (D5) and acks; `recv`, `tail` (`spool.go:463`, `:540`), the hook `inject` and `agent-inbox.sh` never read `revoked/` | **retracted** |
| the same on a box without the cap | the frame waits in `box_revokes` until the box announces the cap | **flagged** to the holder ("box sidecar too old"), retracted once it upgrades |
| a file the hook injected, or the poke typed, before the frame arrived; the vendor transcript | cannot be removed: the transcript is the vendor's file, and editing a live session's file corrupts it | **flagged**: the agent gets the notice (5.4) |
| `.hub/pending` (an unsent outgoing card) | not possible: a revoke needs a stored row | n/a |
| a brief that quoted the card, by hand or through `topic-text.sh` | the brief files are not rewritten (a live lane holds `lifetime/brief.md`); the lane gets the notice; a brief not yet launched is refused by the placer (5.3), and `topic-text.sh` at launch no longer sees the card | flagged / refused |
| an owner order from the card | the ledger is append-only: the walker appends a `lift` with `ORDER_LIFT_MSG` = the revoke notice's msg id when the revoker is the owner; another revoker's revoke flags it to the owner | retracted by lift (owner) / flagged |
| issue description or comment that quoted it | flagged on the issue (a comment `revoked <msg_id>`); the text is not rewritten | flagged |
| copies (`copied_from`), DM mirrors (`mirror_of`) | revoked with the source in the same act (one hop by the column) | **retracted** |
| forwards | when spec 185 has landed its `fwd_of` column (its row F1), they are revoked with the source the same way; until then there is no forward to follow | retracted after spec 185 F1 |
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
  to every agent that holds a delivery of it, and to every lane whose
  brief names it (box side, 6.1 part b: `Source-Msg`, or `Ask-Topic` for a
  topic revoke). Body:

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

### 6.1 Finding them: two walkers

**(a) Hub side, synchronous.** `GET …/revoke/effects?scope=` returns, and
the revoke itself acts on, what the hub's Postgres can trace:

| effect | traced by |
|---|---|
| replies, mirrors, copies, poll answers | `task_id`, `mirror_of`, `copied_from`, `Poll:`; `fwd_of` once spec 185 F1 lands |
| asks, queued spawns | `fleet_asks.source_msg_ids` (G8), `fleet_asks.topic`, state `queued` |
| lanes | hub lane rows by topic (`api/internal/hub/lanes_registration.go`) |
| issues | issues linked to the topic; `ISSUE_OWNER_GO` = the msg id |
| posts by agents in reply | rows in the task after the card, from agents |
| commits, release tags | commit -> issue key -> topic (the commit links the hub holds, `api/internal/hub/release_links.go`) |

**(b) Box side, asynchronous.** The hub cannot read box files. On the
`revoke` frame, the box's orc walker (`do_spl_revoke_effects`, T10) runs
on every box that got it and reports back with kind `result` on the
revoked card's task:

| effect | traced by |
|---|---|
| lanes by brief | `Source-Msg` / `Ask-Topic` in `<root>/<id>/lifetime/brief.md` |
| briefs not yet launched | `<root>/dispatch/briefs/`, `spawn-remote/briefs/` |
| owner orders | `<root>/owner-orders/<repo>.jsonl`, `order` = the msg uuid |
| terraform applies | an issue or commit of the topic naming a step; flagged only |

The dialog lists part (b) as "checked after the revoke", and the
`effects` column of `message_revocations` is completed when the box
reports come in. Both walkers report what they could not trace (a lane
with no `Source-Msg`, a copy outside the hub, a box that did not report)
as "unknown", never as "none": a control that only detects what was
guessed cannot prove absence.

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
against another row's branch. T1, T5, T9 and T11 can start together. The
cap gate (D4) means T4 can deploy before or after T5.

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| T1 | rdb: columns, `message_revocations`, `box_revokes`, policy | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_messages_revoked.sql` | none | applies twice on a throwaway postgres; `\d messages` lists the 3 columns; both tables have RLS (`TestRLSCoversEveryTenantTable`) | the RLS test fails with a policy line removed |
| T2 | hub: revoke / unrevoke / effects endpoints with preflights, the door, the log, the hub-side walker (6.1 a), WUI frames, `ViewChanges` kinds, people-facing blanking | new `api/internal/hub/revoke.go` + test, `api/internal/hub/server.go`, `api/internal/store` (postgres + memory; `view_changes_postgres.go`, `view_topics_head.go`, `link_preview.go`, `issue_discussions.go`, `embed_visitor_messages.go`, `search_postgres.go`), `api/internal/hub/openapi.json` | T1 (pg tests) | Go tests on postgres: an author revokes an own card; an admin revokes an agent's card; a member is refused 403; a topic revoke marks the 041 set with one id; a reply's author's `DELETE` on a topic revoke answers `409 not_revoke_root`, and on the root `403`; `?scope=topic` previews the topic set; `ViewChanges` returns `revoke`; every people-facing reader blanks the body for a non-viewer | remove the root check: the reply-author unrevoke test fails; remove a blanking: its reader's test prints the text |
| T3 | hub: every box-facing reader of 5.1 filters or blanks revoked rows, plus a guard | `postgres.go` (`BoxTaskEnvelopes`, `TaskEnvelopes`, `QueuedFor`, `QueuedForBoxes`), `backfill_postgres.go`, `fallback_postgres.go`, `live_acks.go`, `replay_postgres.go`, `store/flow_fold.go`, `hub/flow_fold.go`, `topics_agent.go`, `topic_export.go`, `blocker_issue.go` | T1 | one test per reader: a revoked row is absent or blanked; a revoked reply does not answer a blocker; and a guard test that lists every function in `internal/store` whose SQL reads `messages.body` or `messages.env` and fails on one not in its reviewed list | each test fails with its filter removed; the guard fails when a new `SELECT … m.body FROM messages` function is added without being listed |
| T4 | hub: the cap, `box_revokes`, the `revoke` frame, the drain on hello, `revoke_ack`, the stored notice | `api/internal/wire` (`caps`, `revoke`, `revoke_ack`), `ws.go` (fan-out, hello drain), the notice writer | T2 | a box with the cap gets the frame online, and after a reconnect from `box_revokes`; the ack marks the row `sent`; a box without the cap gets no frame and stays `queued`; the notice is stored on the task without the revoked text | a box without the cap getting a frame fails the test; the notice test greps the body for the revoked text |
| T5 | box: announce the cap; on `revoke` move copies to `revoked/<subdir>/`, ack; every local reader skips `revoked/` | `api/internal/hubclient`, `api/internal/spool/spool.go`, `spawn/scripts/spool-agent-hook.sh`, `spawn/scripts/agent-inbox.sh` | the 4.3 frame contract | unit test: inbox, archive, outbox and FleetRoot copies move to their own subdirs; `recv`, `tail`, the hook `inject` and `agent-inbox.sh` do not show them; unrevoke moves each back to its own subdir | remove the move: the recv test prints the text; flatten the subdir: the unrevoke test finds the archive copy in inbox |
| T6 | WUI: menu entries, the confirm with effects, the revoked card and topic row, Unrevoke, frames, reconnect | `wui/utils/msg-menu.mjs`, `wui/utils/topic-menu.mjs`, `wui/components/MessageCard.vue`, new `RevokeDialog.vue`, `wui/composables/useCardTopicActions.ts`, `wui/utils/live-ws.mjs`, `wui/composables/useLive.ts`, `wui/stores/live.ts`, `spool-client(-mock).mjs`, `csi-spl-wui/i18n/locales/*.json` | 4.3 | `msg-menu.test.mjs` (Revoke gated by `locks`), a unit test of the revoked render (no body for a non-viewer), typecheck, i18n gates | drop the gate: the locked-viewer assertion fails |
| T7 | WUI e2e | new `csi-spl-wui/tests/e2e/msg-revoke.test.mjs` | T6 | on the generated bundle, mock-served: revoke a reply, it shows "Revoked by…", the text hidden; unrevoke restores it | the e2e fails when the entry is absent |
| T8 | i18n final language check | the non-en locale files | T6 landed | `do_spl_lang_review_gct` on the new keys; the i18n gates green | leave one new key in English in a non-en locale: `i18n-untranslated.test.mjs` fails |
| T9 | orc: source ids (G8) | `orc/run/spl-spawn-place.func.sh` (`Source-Msg:`), `spawn/lib/spool-asks.inc.sh` + an rdb migration for `fleet_asks.source_msg_ids`, `orc/run/spl-lane-issue.func.sh` | none | a placed brief carries `Source-Msg:` for the ask's msg; the ask row stores it | the brief test fails without the line |
| T10 | orc: the box-side walker (6.1 b), outcomes, the placer refusal, sweep + asks drop, seed rule | new `orc/run/spl-revoke-effects.func.sh` + test, `spl-unanswered-sweep.func.sh`, `spl-asks-tick.func.sh`, `spl-spawn-place.func.sh`, the seed rule text under `spawn/assets/` | T2, T9 | on a test spool root: an open ask is declined `revoked`; a queued row is refused; a lane whose brief names the msg gets the notice; an owner order is lifted only on the owner's revoke; a landed commit is flagged, never reverted; the seed carries the rule | a revoked ask still offered by the tick fails the test |
| T11 | docs | `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md` (frames), `view-v1.md` (the row field, the delta kinds), `http-v1.md` (routes, preflights, errors), the box wire contract (`caps`, `revoke`, `revoke_ack`), the user help for the card menu | 4.3 | the contracts name every field, route, frame and error of 4.3 | break one new anchor link: `lint-mdlinks` fails |
| T12 | live proof | none (a run) | T2-T7 deployed dev + prd | in the prd `e2e` tenant and the dev test tenant: revoke a card an agent received; `spool recv` and `hub-tail` on that agent's box do not show it; `message_revocations` count +1; `box_revokes` row `sent` | the same run before T3 shows the text |

Split: hub T1-T4, box T5, WUI T6-T8, orc T9-T10, docs T11, proof T12.

## 8. Open questions for the owner

Each question is meant for one `poll` form (how-to-post section 7); the
recommended option is listed first with its one-line why, and each option
says what it changes here.

1. **Who may revoke a card?** I recommend **(A)**: the author can take back
   their own words, and only admins can stop an agent's.
   - (A) Its author, plus the workspace owner and admins for any card, an
     agent's too: section 4.1 as written.
   - (B) Workspace owner and admins only: 4.1 drops the author row and
     `message_revoke_policy`; T2's author test becomes a 403 test.
   - (C) Anyone who may post in the topic: 4.1's door becomes the post
     door; T2's member-refused test is dropped.
2. **What do others see on a revoked card?** I recommend **(A)**: it stays
   visible, as you asked, without spreading the text.
   - (A) "Revoked by <name>, <time>" and the reason; the text only for the
     author, the revoker and admins: section 4.2 as written.
   - (B) The text struck through, for everyone: the view rows keep the
     body (T2 drops the blanking), T6 renders it struck.
   - (C) The card disappears for everyone but admins: T6 hides the row;
     the topic keeps a gap marker only for admins.
3. **Can a revoke be undone?** I recommend **(A)**: a wrong topic revoke is
   costly, and an undo never restarts work.
   - (A) Yes, by whoever may revoke it; undone actions are not redone (D2).
   - (B) No, a revoke is final: `DELETE …/revoke`, the unrevoke frames and
     the unrevoke parts of T2, T4, T5, T6 and T7 are dropped.
4. **Is a reason required?** I recommend **(A)**: a quick revoke of a wrong
   message should not be held up by typing.
   - (A) Optional (4.2, 4.3).
   - (B) Required: `PUT …/revoke` answers `400 reason_required` on an
     empty reason; the dialog's Revoke button stays disabled until it is
     filled.
5. **Running lanes the card started?** I recommend **(A)**: the point of a
   revoke is to stop the work.
   - (A) Stopped at once, their issue ended `diss` (6.2).
   - (B) Asked first: the holder sends you one form per lane, and each lane
     keeps working until you answer.
6. **A topic revoke on a topic with landed commits or deploys?** I
   recommend **(A)**: the text is withdrawn at once and nothing on prd
   moves without you.
   - (A) Revoke the text now and send you a form listing what cannot be
     undone (6.2).
   - (B) Refuse the topic revoke (`409 has_landed_effects`) until you have
     decided on each landed effect.
7. **Revoke on the phone?** I recommend **(A)**: revoking is urgent, and
   you are often on the phone.
   - (A) On the long-press sheet too (4.2).
   - (B) Desktop menu only, like Forward: the phone sheet does not list it
     (T6's touch assertion flips).

## 9. Not in this spec

- Reverting commits, rolling back deploys, destroying terraform resources:
  each stays a separate change with the owner's go.
- Rewriting vendor transcripts or saved files.
- Revoking by an agent.

## 10. Changes from v0.1

The review a-353 (agy, FAIL on `540e607d8`, msg `c4ccdeb3`), item by item:

| item | what changed |
|---|---|
| W1 | 3.2 rewritten as three tables (box-facing hub readers, box-local readers, people-facing readers) adding `QueuedForBoxes`, `NackedPosts`, `UnsignedWUIPosts`, `topic_list`, `spool_topic_pdf`, every `TaskEnvelopes` caller, `spool-agent-hook.sh`, `agent-inbox.sh`, `topic-text.sh`, `PreviewRows`, `DiscussionStates`, `store/flow_fold.go`, `BlockerAnswer`, `EmbedVisitorMessages`, `ViewChanges`, with the grep that made the list; 3.3 adds the automatic topic-text copy; 5.1, 4.3, T2, T3 and T5 cover each; T3 adds a guard test for a reader not on the list |
| W2 | `fwd_of` removed from "exists today" (3.3 says it does not); 5.2, 6.1 follow forwards only after spec 185 F1 lands; T2 does not name it |
| W3 | D4 corrected (an old sidecar does not ignore an unknown frame, `hubclient.go:661-665`): the frame is gated on a `caps` hello field; `box_revokes` is the offline queue with a drain on hello and `revoke_ack` (4.3, T1, T4); D5 and T5 keep the origin subdir |
| W4 | the topic unrevoke is authorized from the log row and accepted only on the root (4.1, 4.3, D6, `not_revoke_root`); `?scope=` on the effects read; the two `OPTIONS` preflights |
| W5 | 6.1 split into the hub-side synchronous walker and the box-side asynchronous one, with the dialog marking part (b) as checked after |
| W6 | section 8 rewritten for the form: recommended option first with its why, what each answer changes, `(A)` / `(B)` / `(C)` options one per line |
| N1 | the numbering note updated: 193 has landed; measured on `1bc99663b` |
| N2 | T8 names `do_spl_lang_review_gct` and the planted English key; T11's red control is a broken anchor in `lint-mdlinks`; T2 names `api/internal/hub/openapi.json`; T6 adds `useCardTopicActions.ts` and `wui/stores/live.ts` |
| N3 | `topic_heads` noted (3.1, 4.3): no body there; topic list rows join the opening card's `revoked_at` for the badge and subject |
