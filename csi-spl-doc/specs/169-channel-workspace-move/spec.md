# 169 Channel Workspace Move: move or copy a whole channel into another workspace

Version: v0.9 (2026-10-30). Status: **Draft** (plan only; nothing below is
built). Issue SPL-4393 · Epic SPL-2398 · Class feature · Kind
specs_and_docs · Placement slug `c002-channel-workspace-move-spec` · Lead
c-848.

History: v0.1 `568035cf1` (landed as a draft before its R7). v0.2 folds the
R7 review by c-882 (FAIL on v0.1: W1 missed tables, W2 copy ids; notes N3-N9)
and adds the build lane split (10.1). v0.3 folds the re-review of v0.2
(FAIL: P2b seated agents before the channel exists in `<DST>`; now P2b
proves only the desk with a probe DM, and the seat rows move in P4; notes on
the box's handling of a refusal, the allowed `<SRC>` writes in C13, and L8's
stub). v0.4 fixes the P2b probe's recipient (a DM from an agent to a
person on a new topic is refused by the hub's `dm_not_blocker` guard,
SPL-2584) and drops "re-seat" from T10, both raised by the L8 build lane.
v0.5 settles the four calls the T1 catalogue lane (L2) asked for, read from
the DDL: the hours plan, entries and the Google Calendar map (5.1a), invites
and embed visitors whose parent row does not move (5.1b), labels, fallback
deliveries and the audit binds; it adds Q8 (hours inside an approved period).
v0.6 folds the owner's answers (section 11.1: Q1-Q6, Q8 = A; Q7 = A
with the channel not named yet), the v0.5 review notes by
c-907 (N1: P2 refuses without a `<DST>` orchestrator seat; N2: members'
hours rows are never deleted silently) and the catalogue's fifth class,
Refuse, in C2 (from the T1 lane).
v0.7 folds the v0.6 review notes by c-907: the Q5 row says it is the
channel's people who are not `<DST>` members that come along only when the
owner adds them (W1 keeps existing `<DST>` members), and `plan` names the
reason for each hours stop (5.1a). Q7 stayed open: the channel was asked
again as a poll (11.1).
v0.8 folds the owner's Q7: the csitea channel named like the hidden
workspace `ws-hidden-17` moves first, into `ws-hidden-17` (11.1). Both names
are that workspace's slug, which the hygiene sweep keeps out of this public
repo (SPL-1874, SPL-1910), so the spec writes the overlay placeholder. v0.7
named the destination "the workspace created 2026-10-29"; the hub's
`tenants` row for `ws-hidden-17` reads created 2026-10-29 13:54Z, so the date
matches; the spec now writes the workspace the owner named.
v0.9 folds the v0.7 review notes by c-971 and the v0.8 notes by c-064:
the hours stop lines carry the row count and one line per reason (5.1a);
C21 tests the Q5 hours stop; "kept members (W1, Q5)" in 5.1; the Q5 hours
stop is marked the lead's choice, not an owner answer; the Q7 cell quotes
each answer by its msg id; the dev rehearsal before the first prd run is
its own build row, T13 in L8 (10, 10.1). The "18:03Z" c-971 flagged (N5)
left the spec with v0.8's Q7 row, which cites the owner's msg ids instead.

Number: the brief asked for 168; `git ls-tree origin/master csi-spl-doc/specs/`
showed `168-owner-order-ledger` already on master, so this is 169.

Source: owner HUM-10, prd t1 topics `3a618e79-8ecc-4154-9ec8-58ed6261b1e8`
(move) and `537d51e9-432b-45d5-862e-4c1565d1a8e6` (copy).
Related, not the same: [spec 167 channel box move](../167-channel-box-move/spec.md)
(a channel's work to another BOX, same workspace),
[spec 045 move by drag](../045-spool-move-by-drag/spec.md) (a topic to another
channel inside one workspace), [spec 069 section 8.4](../069-ysg-box-out/spec.md)
(`do_spl_desk_move`), [spec 158 new workspace](../158-new-workspace-automatic/spec.md)
(seating a new workspace), [spec 114](../114-workspace-doc-privacy-sharing/spec.md)
(Qto doc privacy and sharing), [private overlay](../../doc/md/private-overlay.md)
(hidden workspaces).

Placeholders, because the repo is public: `<SRC>` the workspace (tenant) the
channel leaves, `<DST>` the workspace it goes to, `<CHANNEL>` the channel id,
`<SRC_HOST>` / `<DST_HOST>` their web hosts. A hidden workspace is named only
by its overlay placeholder (`ws-hidden-NN`). Paths: `api/` =
`csi-spl-api/src/go/spool-hub-api/internal/`, `orc/` = `csi-spl-orc/src/bash/`.
Every file named was read on origin/master `2ef8d310f`; every table fact was
read from the prd hub database on 2026-10-30 through `do_spl_db_query`
(read-only `SELECT`s, quoted with each fact).

## 1. The owner's words (verbatim)

prd t1 topic 3a618e79, 2026-10-29, HUM-10:

- b82564a2 (16:25:59Z): "I want to be able to move entire channels into new
  workspaces .. so that the old workspaces will not have even a trace of the
  channels they had"
- 0c9aad1f (16:26:14Z): "and the whole work should be possible to continue in
  the new workspaces"
- 513169d6 (16:26:34Z): "so I would like to be able to move channels between
  workspaces .."

prd t1 topic 537d51e9, 2026-10-29, HUM-10:

- 6e794fd0 (16:26:59Z): "I would like to able to copy replicate entire
  channels from one workspace to another"

Context, the same topic 3a618e79, minutes earlier: a new workspace was created
that day; the owner asked to be its sole admin (0a9bd92b: "add me as the sole
admin of this workspace") and (f81b2742) "nobody else should have access to
this workspace than me - from the humans , and it should have at least 4
dedicated agents + the orchestrators and the dispatchers". The likely first
move is one channel of the csitea workspace into that new workspace; the owner
has since said which (Q7, 11.1): the csitea channel named like
`ws-hidden-17`, into `ws-hidden-17`.

## 2. Words

- **Move**: the channel and everything in its set (section 4) end up in
  `<DST>`; afterwards `<SRC>` holds no row, object or index entry that names
  them (section 5), except what the owner accepts in section 5.6.
- **Copy** (the owner's "copy replicate"): `<DST>` gets its own channel with
  the set; `<SRC>` keeps everything unchanged (section 7).
- **The set**: the channel row and every row, object and link that belongs to
  it (section 4). Computed once by `plan`, frozen in the journal.
- **Journal**: the move's own record, one row per step, kept in `<DST>`
  (section 8.3). The proof queries of section 5 read the ids to look for from
  it, because after the move `<SRC>` must not hold them.
- **Shared item**: something the channel uses that another `<SRC>` channel
  also uses (a file, a Qto doc, an issue, an epic). Section 5.5.

## 3. Today: what exists on master

| # | fact | where / how checked |
|---|---|---|
| F1 | Nothing moves or copies a channel across workspaces. | `git grep -n -i 'workspace.move\|channel.workspace' origin/master -- csi-spl-api csi-spl-orc` -> 0 action, 0 handler |
| F2 | Every workspace row is keyed by `tenant_id`; RLS is forced on every tenant table, and a statement without a tenant reads no row. | developer guide 2.6.4; `api/store/rls_test.go` |
| F3 | The prd database has 151 base tables; all but a handful carry `tenant_id`. | `information_schema.columns` join `tables`, `table_type='BASE TABLE'` -> 151 rows |
| F4 | `messages` is keyed `(tenant_id, msg_id)`; `channel` holds the channel id; a topic is a `task_id`; threads use `parent_task_id`; DMs about a topic carry `ref_task_id`; a channel copy of a DM answer carries `mirror_of` (rdb 0112). | `pg_constraint` `messages_pkey`; `csi-spl-rdb/src/sql/postgres/spool-hub/0112_dm_ref_task.sql` |
| F5 | The tenant foreign keys are composite and have no `ON UPDATE CASCADE`: `deliveries`, `message_answers`, `message_reactions` reference `messages(tenant_id, msg_id)`; `issue_discussions` and `issues.parent_number` reference `issues(tenant_id, number)`; `workspace_doc_node` references its own tenant's tree. So an `UPDATE ... SET tenant_id` on a parent row is refused: a move is insert-into-`<DST>`, then delete-from-`<SRC>`, children first. | `pg_get_constraintdef` on those tables |
| F6 | Issue numbers are per workspace (`issues_pkey (tenant_id, number)`), each workspace has its own key prefix (`issue_counters (tenant_id, prefix, last_number)`, 11 rows, one per workspace). A moved issue gets a new number and a new key. | `pg_constraint`; `select count(*), count(distinct tenant_id) from issue_counters` -> 11, 11 |
| F7 | Qto docs have a hub-wide primary key (`workspace_doc_pkey (id)`) and a per-workspace nested-set tree (`workspace_doc_node`, `lft`/`rgt` unique per tenant). Docs are not tied to a channel by a column; a channel reaches them by links in posts and by the doc id in column 3 of its box rule row (spec 167 T1). | `pg_constraint` |
| F8 | Attachments are content-addressed blobs at `t/<tenant>/files/<sha256>` in the files bucket (step 050), one copy per workspace however many posts carry it; a post lists them in `messages.files` (jsonb array of `{file_id, sha256, name, bytes, mode}`). An in-flight upload is `tmp/<tenant>/<nonce>`. The hub keeps a small in-memory LRU of blobs by key. | `api/blob/blob.go` `Key`, `TmpKey`; `api/blob/cached.go` |
| F9 | Search is inside the rows: `messages.search_tsv`, `messages.search_sig` (rdb 0135), `workspace_doc_item.search_tsv`. No separate index table. | `information_schema.columns`; `0135_messages_search_sig.sql` |
| F10 | A signed envelope (`messages.env`, `env_sig`) carries no tenant: its fields are `v, msg_id, task_id, ts, from, to, kind, body, files, ref_task_id, accepts, sig` (encrypted form: `enc, for, ct`). Moving a row keeps it verifiable by the same box key. | `api/msg/msg.go` struct tags |
| F11 | A hard channel delete exists inside one workspace: `DeleteChannel` deletes `messages WHERE channel = <id>` then the `channels` row, in one tenant transaction (`channel_humans`, `channel_subscriptions` cascade). It deletes nothing else by name. | `api/store/channels_postgres.go` `DeleteChannel` |
| F12 | Copies outside the live database: the daily DB dumps (step 045) and their off-project copy (step 046, writer SA may add, never read or delete; `retention_days: 30`, `max_age_days: 90` in prd cnf), each workspace's daily Qto export under `backup/` of its own docs bucket (step 052, `backup_retention_days: 30`), the nightly box-state copy with transcripts and the spool root (step 056, `retention_days: 30`), bucket soft delete (`soft_delete_retention_seconds` 7 or 30 days). | `csi-spl-cnf/csi-spl/all.env.yaml`, `prd.env.yaml` |
| F13 | Size: the largest channel on prd holds 3,650 messages; the median is 13.5 (86 channels). | `select max(n), percentile_cont(0.5) ... from (select tenant_id, channel, count(*) n from messages where channel is not null group by 1,2) s` |
| F14 | A channel's seat and desk live on a box: `$SPOOL_ROOT/channel-rules.tsv` (`<tenant> <channel> <doc id> <env> <desk agent> [<sole seat>]`), one desk sidecar per workspace per box. Channel-scoped agents are `dedicated_agents` rows with `scope_type = 'channel'` (4 on prd). | `orc/features/spawn-agents/lib/channel-rules.inc.sh`; spec 167 T1, T9; `select scope_type, count(*) from dedicated_agents group by 1` |

## 4. What a channel's set is

`plan` computes it in `<SRC>`, asOperator, in one read transaction:

| # | item | how it is found |
|---|---|---|
| M1 | the channel | `channels (tenant_id, channel_id)` |
| M2 | its topics and posts | `messages WHERE channel = <CHANNEL>`, then every row whose `task_id` or `parent_task_id` is one of those tasks (threads, sub-tasks; the same walk as `store.walkTopic`, spec 045) |
| M3 | posts' children | `message_revisions`, `message_reactions`, `message_kind_changes`, `message_moderation`, `message_answers` (polls and their answers), `deliveries`, `delivery_live_acks` (rdb 0186, FK to `messages` ON DELETE CASCADE), `fallback_deliveries`, `read_marks` on those posts and topics |
| M4 | attachments | every `file_id` of a `mode: "blob"` item in `messages.files` of M2 -> blob `t/<SRC>/files/<sha256>`. A `mode: "path"` item names an on-box path and has no blob (`api/msg/msg.go` `Attachment`): it travels inside the row and nothing is copied |
| M5 | members and seats | `channel_humans`, `channel_invites`, `channel_subscriptions`, `dedicated_agents` with `scope_type = 'channel'` and `scope_id = <CHANNEL>`, `tenant_memberships.channel_order` entries |
| M6 | topic state | `topic_heads`, `topic_head_parts`, `topic_priorities`, `flow_watches`, `flow_events`, `calendar_events.topic_id` with their `calendar_guests` (rdb 0139), `hours_jobs.task_id` (rdb 0216, a job that names an M2 topic) with its `hours_plan` rows (FK `ON DELETE CASCADE`) |
| M6c | hours that name the set | `hours_minutes`, `hours_entries` (+ `hours_entry_spans`, FK to the entry) and `hours_adjustments` whose `target` is `ch:<CHANNEL>`, `t:<M2 task>`, `cal:<moved event>` or `job:<moved job>` (rdb 0151, 0176, 0215, 0218: a text column, no FK, so no cascade finds them) |
| M6b | move history that points INTO the set | `messages` OUTSIDE M2 (staying in `<SRC>`) whose `moved_from_channel = <CHANNEL>` or whose `moved_from_task` / `moved_from_parent` is an M2 task (rdb 0069: a post spec 045 moved OUT of the channel keeps its home there) |
| M7 | issues | `issues` whose `task_id` is an M2 topic, or that `issue_discussions` links to an M2 topic; their `issue_events`, `issue_opens`, `issue_discussions` rows, and the `spec_sync_map` rows whose `issue_number` is one of them (rdb 0208; its `spec_task_id` is a tasks.md row id such as `T001`, at most 32 characters, not a topic id) |
| M8 | Qto docs | the doc in the channel's box rule (F14 column 3) and every doc linked only from M2 posts (a doc linked from another channel too is a shared item, 5.5); their `workspace_doc_*` rows and their objects in `<SRC>`'s docs bucket |
| M9 | DM links | DMs whose `ref_task_id` is an M2 topic; channel rows with `mirror_of` move with M2 |
| M10 | usage and budget | `usage_events`, `token_budgets`, `embed_visitors` with `channel_id = <CHANNEL>` (an embed visitor's own channel, rdb 0169: one visitor per channel) |
| M11 | fleet refs | `fleet_lanes.topic` / `issue_key`, `fleet_asks.topic` / `issue_key` pointing at M2 topics or M7 keys |
| M12 | box state | the F14 rule row, the desk seats of the channel's agents, the spool and dispatch files that name M2 task ids (spec 167 section 4.2 manifest, reused) |

The plan prints the count of every item, the shared items (5.5) and the
mentions found outside the set (5.4), and changes nothing.

## 5. "Not even a trace": the inventory

Every store that can name the channel or a row of its set, what the move does
with it, and the proof that `<SRC>` holds zero after. `<ids>` = the frozen id
lists from the journal (channel id, task ids, msg ids, file ids, old issue
numbers, doc ids). Every proof runs in `<SRC>` asOperator and must print 0.
This list is the v0.2 reading of the DDL, not a proof that nothing else
names the set: v0.1 claimed so and the R7 review found four tables it missed.
What makes it complete is the catalogue gate C2 (T1): every `tenant_id` table
is classified there, the build fails on an unclassified one, and that holds
for every table added later. Columns that look related but are not:
`marketing_*.channel_id` (a social-media channel, rdb 0187) and
`gcal_connections.watch_channel_id` (a calendar push channel); C2 records
both as "not about spool channels".

### 5.1 Hub database, rows of the set

| store | action | proof (count must be 0) |
|---|---|---|
| `channels` | moved | `WHERE tenant_id=<SRC> AND channel_id=<CHANNEL>` |
| `messages` (M2, incl. `mirror_of` copies) | moved, same `msg_id` and `task_id` | `WHERE tenant_id=<SRC> AND (channel=<CHANNEL> OR task_id=ANY(<tasks>) OR parent_task_id=ANY(<tasks>) OR msg_id=ANY(<msgs>))` |
| staying `messages` with move history into the set (M6b) | `moved_from_channel`, `moved_from_task`, `moved_from_parent` set to NULL: the post's old home has left `<SRC>`, so it is at home where it is now (the same state a move back home leaves, rdb 0069) | `WHERE tenant_id=<SRC> AND (moved_from_channel=<CHANNEL> OR moved_from_task=ANY(<tasks>) OR moved_from_parent=ANY(<tasks>))` |
| `hours_jobs` naming an M2 topic, with its `hours_plan` rows | moved together: the plan rows are inserted under `<DST>` with the job, before the job's `<SRC>` delete cascades to them (else members' planned slots are lost) | `WHERE tenant_id=<SRC> AND task_id=ANY(<tasks as text>)`; `hours_plan WHERE tenant_id=<SRC> AND job_id=ANY(<jobs>)` |
| hours rows that name the set (M6c) | see 5.1a | `WHERE tenant_id=<SRC> AND target=ANY(<targets>)` per table |
| `message_revisions`, `message_reactions`, `message_kind_changes`, `message_moderation`, `message_answers`, `deliveries`, `delivery_live_acks`, `fallback_deliveries` | moved with their post (F5: inserted under `<DST>` before the parent's delete cascades in `<SRC>`) | `WHERE tenant_id=<SRC> AND msg_id=ANY(<msgs>)` (`answers` / `answer_msg_id` for `message_answers`) |
| `channel_humans`, `channel_invites`, `channel_subscriptions` | moved for kept members (W1, Q5); deleted for the rest | `WHERE tenant_id=<SRC> AND channel_id=<CHANNEL>` |
| `dedicated_agents` (channel scope) | moved | `WHERE tenant_id=<SRC> AND scope_type='channel' AND scope_id=<CHANNEL>` |
| `tenant_memberships.channel_order` | the id is removed from every `<SRC>` array | `WHERE tenant_id=<SRC> AND <CHANNEL> = ANY(channel_order)` |
| `read_marks` | moved for kept members (W1, Q5); deleted for the rest | `WHERE tenant_id=<SRC> AND (msg_id=ANY(<msgs>) OR mark_key LIKE ANY(<channel and task keys>))` |
| `topic_heads`, `topic_head_parts`, `topic_priorities`, `flow_watches`, `flow_events` | moved | `WHERE tenant_id=<SRC> AND task_id=ANY(<tasks>)` (`topic_head_parts` also `channel=<CHANNEL>`); and, for heads of topics that stay (a DM thread about a moved topic), `last_msg_id` / `dm_last_msg_id` `=ANY(<msgs>)` -> 0, recomputed from the remaining rows |
| `calendar_events` with an M2 `topic_id`, with their `calendar_guests` | moved together (guests are the event's children, FK `ON DELETE CASCADE`); a guest who is not a `<DST>` member follows Q5 | `WHERE tenant_id=<SRC> AND topic_id=ANY(<tasks as text>)`; `calendar_guests WHERE tenant_id=<SRC> AND event_id=ANY(<events>)` |
| `gcal_event_map` of a moved event | not carried; see 5.1a | `WHERE tenant_id=<SRC> AND event_id=ANY(<events>)` |
| `issues`, `issue_events`, `issue_opens`, `issue_discussions`, `spec_sync_map` | moved, renumbered under `<DST>`'s prefix (F6); the old key is written into the new issue's first event. A `spec_sync_map` row that a STAYING issue or doc also needs is a shared item (5.5): its FK to `issues` is `ON DELETE SET NULL (issue_number)` (rdb 0208), so deleting the moved issue would null the staying row's link without an error; `plan` lists it and the move refuses until it is resolved (Q6) | `WHERE tenant_id=<SRC> AND number=ANY(<old numbers>)` per table (`issue_number` in `spec_sync_map`) |
| `workspace_doc`, `_item`, `_node`, `_acl`, `_rev_log` | moved, re-placed in `<DST>`'s tree under a folder named for the channel | `WHERE tenant_id=<SRC> AND (id=ANY(<docs>) OR doc_id=ANY(<docs>))` |
| `usage_events`, `token_budgets` | moved | `WHERE tenant_id=<SRC> AND channel_id=<CHANNEL>` |
| `embed_visitors` | see 5.1b: `plan` refuses | `WHERE tenant_id=<SRC> AND channel_id=<CHANNEL>` |
| `fallback_deliveries` | moved with its post (row above); its `channel_id` column also names the channel, so the proof reads both | `WHERE tenant_id=<SRC> AND (msg_id=ANY(<msgs>) OR channel_id=<CHANNEL>)` |
| `issue_labels` | not about channels: a workspace's label catalogue. A moved issue's `labels` values are `label_id`s, so T5b creates each missing `label_id` in `<DST>` (name and colour copied) before the issue insert; `<SRC>`'s catalogue is kept | none (C2 records the class) |
| DMs with `ref_task_id` in M2 (M9) | the DM stays (it is two people's DM, not the channel's); `ref_task_id` set to NULL in `<SRC>`, so the DM no longer points at the channel | `WHERE tenant_id=<SRC> AND ref_task_id=ANY(<tasks>)` |
| `fleet_lanes`, `fleet_asks` (M11) | issue keys rewritten to the new keys; topic ids unchanged (they live in the fleet's own workspace, not in `<SRC>`, unless `<SRC>` is that workspace) | `WHERE issue_key=ANY(<old keys>)` |
| aggregate counters (`message_period_counts`, `quota_counts`, `topic_head_tenants`, `tenant_change_stamps`) | recomputed for `<SRC>` and `<DST>` from the rows after the move; change stamps bumped so every cached view refetches | the recompute equals a fresh count (C9) |

#### 5.1a Hours and the Google Calendar map

- **Hours rows (M6c)** are members' time records, not the channel's, but
  their `target` names it, and the scan (5.2) would find them. They move
  with the set for members who come along to `<DST>` (Q5). They are never
  deleted silently (N2): a person's time record is theirs, not the
  channel's. Two cases make `plan` list the rows and the move stop until
  the owner says, per member, what happens to them:
  - the member does not come along to `<DST>` (Q5): the owner adds the
    member to `<DST>` (the rows then move) or tells us to leave the rows in
    `<SRC>`;
  - a row whose `(member_id, day)` falls inside an `hours_periods` row of
    `<SRC>` in state `frozen` or `approved` belongs to a time sheet already
    signed off, whose `minutes` total is stored; moving it would change an
    approved sheet. Q8 = A: the owner reopens the sheet (the rows then
    move) or tells us to leave the rows.

  `plan` prints one line per member and reason, with the row count:
  `hours: <member> <n> rows not coming to <DST> (Q5)` and
  `hours: <member> <n> rows inside a frozen or approved sheet (Q8)`. A
  member who hits both cases gets both lines, and each is cleared on its
  own: adding the member to `<DST>` clears the Q5 line, not the Q8 one.
  The Q5 stop is the lead's choice, not an owner answer: his Q5 words are
  "they lose access; the move lists them and you add whom you want", and
  leaving the rows in `<SRC>` would also fit them. The spec stops because
  a person's time record is never moved or left without a word (N2); the
  owner overrides it by saying "leave the rows", and the output says why
  it stops rather than only that it stops.

  Rows left by the owner's word stay in `<SRC>` naming the channel; they
  are a kept item (5.6), and the scan (5.2) reports them as known, not as a
  failure.
- **`gcal_event_map`** (rdb 0217) ties a moved calendar event to the Google
  event in a `<SRC>` member's connected calendar. It cannot be carried: its
  `connection_id` is a `<SRC>` connection. Letting the cascade delete it is
  NOT enough: the Google event stays in the member's calendar, and the next
  In half of the sync (`api/hub/gcal_sync_in.go`: "unmapped: imported ... as
  the member's private event") imports it back into `<SRC>` as a new event,
  with the moved event's title. So T5 does it in two steps: before P4, for
  each map row of a moved event, it claims that member's connection
  (`ClaimGcalMember`, so no sync cycle runs in between) and deletes the
  Google event the way the Out half deletes one; P4's cascade then removes
  the map row. A Google call that fails stops the move before P4. In
  `<DST>`, the normal Out half writes the moved events to the calendars of
  `<DST>`'s connected members.

#### 5.1b Rows whose parent row does not move

- **`channel_invites`** (rdb 0231) has a FK to `tenant_invites (tenant_id,
  email)`. A `<DST>` row needs a `<DST>` workspace invite for that email,
  and writing one invites a person into `<DST>`: that is Q5. With Q5 = A,
  an invite is moved only for an email the owner keeps (the move first
  writes its `<DST>` `tenant_invites` row), and deleted otherwise. `<SRC>`'s
  `tenant_invites` row is kept: it is the workspace's invite, not the
  channel's.
- **`embed_visitors`** (rdb 0169) has a FK to `embed_customers (tenant_id,
  embed_id)`, and `embed_id` is a hub-wide primary key that sits in the
  customer's iframe URL. `<DST>` cannot hold a second row with the same
  `embed_id`, and moving the `embed_customers` row moves the customer's
  website chat for every visitor channel it has. So a channel with an
  `embed_visitors` row is a shared item (5.5): `plan` lists it and the move
  refuses (Q6). A copy does not carry `embed_visitors`: the copy is not the
  visitor's chat.

### 5.2 Hub database, free text and audit

`operator_audit.detail`, `workspace_events.message` / `origin_ref`,
`system_events`, `human_events`, `sql_query_audit.error_message`,
`demo_post_audit`, `repo_doc_edits.target_ref`, and the bodies of posts in
other `<SRC>` channels can quote the channel id, its name, a task or msg UUID
or a permalink.

- Audit and event rows that are ABOUT the set (their `origin_ref` or `detail`
  names an id of the set) are moved to `<DST>` with it: they are the channel's
  history. The catalogue finds them by binds, not by a channel column:
  `workspace_events`, `operator_audit`, `demo_post_audit` and
  `sql_query_audit` by the set's ids (`@ids`) and `LIKE` patterns on them
  (`@id_likes`). `repo_doc_edits` is not about channels (its `path` is a
  repo file, its `target_ref` a git ref); the scan (T8) still reads it.
- The move's own audit row is written in `<DST>`; in `<SRC>` the move writes
  no audit or event row (its other `<SRC>` writes are the deletes and the
  named updates of C13). The hub-wide operator log gets one row with the journal id only,
  no channel id, name or tenant slug of `<SRC>` (C13).
- Proof: a scan of every `text`, `jsonb`, `uuid` and `uuid[]` (and `text[]`)
  column of every `<SRC>` table for the channel id, the channel name, every
  task UUID and every msg UUID. The uuid columns matter: `moved_from_task`,
  `ref_task_id`, `answer_msg_id`, `topic_heads.last_msg_id` and
  `dm_last_msg_id` (rdb 0144) are uuid, and a text-only scan never reads them.
  The column list is read from `information_schema` at run time, not
  hard-coded.

This scan proves only that those exact strings are absent. It cannot prove
that nobody paraphrased the channel ("the project chat") in a post, and the
spec does not claim it does.

### 5.3 Objects outside the database

| store | action | proof |
|---|---|---|
| files bucket `t/<SRC>/files/<sha256>` (M4) | copied to `t/<DST>/files/<sha256>` before the DB step (idempotent: same name = same bytes), deleted in `<SRC>` after the DB commit, but only where no remaining `<SRC>` row lists that `file_id` (5.5) | `gcloud storage ls` of each `<SRC>` key -> not found; `messages.files @> '[{"file_id": ...}]'` in `<SRC>` -> 0 |
| upload scratch `tmp/<SRC>/...` | not touched: it names no channel, and the bucket's `tmp/` lifecycle rule sweeps it | none needed |
| hub blob LRU (F8) | keys carry the tenant; the read path must ask the database first, which no longer lists the file in `<SRC>` | C10 reads a moved `file_id` from `<SRC>` -> 404 |
| `<SRC>`'s docs bucket (step 052) objects of M8 docs | copied to `<DST>`'s bucket, deleted in `<SRC>` | `gcloud storage ls` of each object -> not found |
| soft-deleted copies of those objects | kept until soft delete expires (7 days, step 052 cnf), or purged at once on the owner's answer to Q3 | `gcloud storage ls --soft-deleted` |

### 5.4 Mentions outside the set

Posts in OTHER `<SRC>` channels, other people's DMs, and Qto docs that stay in
`<SRC>` may link a moved topic (`/t/<uuid>`), name `#<CHANNEL>`, or quote it.
They are not the channel's; editing them changes other people's words and
leaves a revision row with the old text anyway. `plan` lists each one (link,
author, line). What happens to them is Q4.

### 5.5 Shared items

A file, Qto doc, issue or epic that the set uses AND something staying in
`<SRC>` also uses. `plan` lists them; what the move does with them is Q6.

### 5.6 What is kept, and why (the owner accepts or rejects, Q3)

| store | holds | why it cannot simply be deleted | gone by |
|---|---|---|---|
| daily DB dumps (045) | the whole `<SRC>` database | a dump is one file for every workspace; editing it destroys the backup's integrity | its retention (30 days) |
| off-project copy (046) | the same dumps | its writer SA may add, never delete (by design, so a stolen key cannot wipe the backups); only the owner by hand can remove an object | its retention (30 / 90 days) |
| Cloud SQL automated backups | the whole database | managed by Cloud SQL, not per row | their retention (not checked here: open check R4) |
| `<SRC>` Qto daily export (052 `backup/`) | `<SRC>`'s docs | one file per day per workspace | 30 days |
| box-state copy (056) | transcripts, the spool root | one nightly archive per box | 30 days |
| hub logs (Cloud Logging) | request lines with ids | logs are append-only by design | the log bucket's retention (not checked: open check R4) |
| mail and notifications already sent | text sent to people | outside the system | never |
| git history of this repo | commit subjects, specs and dispatch notes that cite a task id or an issue key | history is forward-only; no force-push (developer guide 4) | never |
| hours rows the owner said to leave (5.1a) | a member's time record that names the channel | it is the member's signed or kept time sheet, and the owner chose to leave it (Q8 = A, or a member not brought along under Q5) | never, unless the owner deletes it |
| box spool archives, transcripts, worktrees | copies of the channel's posts on the boxes | they are the agents' working memory, and "the whole work should be possible to continue" needs them; they name no workspace (F10) | spec 167's cleanup if the channel also leaves its box |

## 6. "The whole work should be possible to continue"

| # | what | how |
|---|---|---|
| W1 | Members | Humans of the channel who are members of `<DST>` keep their channel membership, read state and order. Others are listed by `plan`; the owner adds them to `<DST>` or not (Q5). The new workspace today is owner-only (msg f81b2742), so the default adds no one. |
| W2 | Agent seats | Each agent seated in the channel (M5, F14) needs a desk in `<DST>` on its box before the switch: `plan` checks `roster` / `agent_seats` in `<DST>` and refuses with the missing desks named. The `<DST>` DESK is proved in P2b, BEFORE the P4 commit (spec 167 W3): the agent sends one probe DM through its `<DST>` desk to the `<DST>` orchestrator seat (an agent, not a person: the hub's human post guard refuses an agent's DM to a person on a topic the person did not start unless it is a blocker, `dm_not_blocker`, `api/hub/human_post_guard.go`, SPL-2584), on the probe topic (task id = the journal's `move_id`; a DM needs no channel, so it works while `<CHANNEL>` does not yet exist in `<DST>`), and the journal records its msg id. The body names the `move_id` and the agent, so no two probes are equal. P2 refuses when `<DST>` has no orchestrator seat. The channel SEAT is not added by `do_spl_channel_agent_add_op` before P4: that action needs the channel to exist (`orc/run/spl-channel-agent-add-op.func.sh`). The seat rows (`dedicated_agents`, `channel_humans`, `channel_invites`, M5) move inside the P4 transaction like every other row of the set. After P4, P5 rewrites the box rule row's tenant column, so the box posts through the `<DST>` desk. Window: between the P4 commit and P5, a post from a lane through its `<SRC>` desk into a moved task is refused by the hub (C8); whether the box retries a refusal or files it as rejected is not checked on master, and T10 tests it and the operator page (T12) says which. P5 follows P4 at once, in the same run. |
| W3 | Lanes and spool task ids | Task UUIDs and msg UUIDs do not change (F4, F10), so a lane's `--task <uuid>`, its brief and its dispatch files stay valid; only the desk the post goes through changes (W2). A post into a moved task at `<SRC>` must not create a new `<SRC>` topic with that id: the hub refuses it (Q2 decides whether it also re-routes it). |
| W4 | Issue keys | Each moved issue gets a new `<DST>` key (F6). The move posts every lane whose `fleet_lanes.issue_key` changed a note with old -> new key; its commits cite the new key. The closer maps an old key to the new one while the redirect lives (Q2, which covers issue keys too); after that an old key closes nothing. |
| W5 | Permalinks | A moved topic's link is `https://<DST_HOST>/t/<uuid>` (same uuid). An old `https://<SRC_HOST>/t/<uuid>` link: Q2. |
| W6 | Open polls, claims, parked rows | Columns travel with the row (`responsible`, `locked_until`, `claim_state`, `parked_until`, `wait_token`; polls in `message_answers`): an open poll can be answered in `<DST>` the minute after the move. |
| W7 | Live clients | Bumped change stamps (5.1) make every open WUI refetch; a `<SRC>` client drops the channel, a `<DST>` client shows it. A browser that is offline keeps its local cache of `<SRC>` until it next loads (kept: other people's devices). |

## 7. Copy (replicate)

The owner's words leave one thing open: is the copy a snapshot that lives on
by itself, or kept in sync with the source (Q1)? The plan below is the
snapshot; a sync would be its own spec.

- Same set (section 4), same order; `<SRC>` is only read.
- New identities in `<DST>`: new task and msg UUIDs (a map old -> new in the
  journal), so a lane's `--task` can never be ambiguous between the two, and
  links inside the copied posts that point at copied topics are rewritten to
  the new UUIDs. New issue numbers. New Qto ids for the doc AND every row
  under it: `workspace_doc.id` (F7), `workspace_doc_item.id` (rdb 0157) and
  `workspace_doc_node.id` (rdb 0165) are hub-wide uuid primary keys, and
  `workspace_doc_rev_log` is keyed `(doc_id, rev)` with no tenant, so each is
  re-keyed through the journal's old -> new map (item `parent_id`, node
  `parent_id` and the rev log under the new doc id). Keeping any old id is a
  primary-key violation in `<DST>`.
- Files: the blob is copied to `t/<DST>/files/<sha256>` (the same name; the
  content address does not change). `<DST>`'s file quota counts it.
- Members, seats and lanes are NOT copied: the copy starts with the owner as
  its only member, and seats are added in `<DST>` by hand or by spec 158.
- The signed envelope (F10) holds the OLD msg and task ids, so a copied row
  keeps the original `env` / `env_sig` as provenance and the hub marks the row
  `copied_from` (new column, T3); the copied row's own ids are hub metadata,
  the same way spec 045 keeps a move beside the envelope.
- What a box sees: a box that receives a copied row must file it under the
  row's NEW task id, not the envelope's old one, or the copy lands in the
  source topic on that box. Not checked on master which id the delivery path
  uses today; T11 reads it and, if it is the envelope's, sends the hub's ids
  beside the envelope. C16 asserts it on a box spool, not only in hub rows.

## 8. The action

### 8.1 One command

```
cd csi-spl-orc && CHANNEL=<SRC>/<CHANNEL> TO=<DST> ./run -a do_spl_channel_workspace_move
```

```
cd csi-spl-orc && CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_MODE=copy ./run -a do_spl_channel_workspace_move
```

- `MOVE_CMD=plan` is the default and the dry run: prints the set (section 4),
  shared items, mentions, missing desks and members, the kept list (5.6) and
  the proof queries; changes nothing.
- `DRY_RUN=0` needs the owner: an owner-only operator action. The
  orchestrator seat may run `plan`; it runs `DRY_RUN=0` only with an owner
  `(GO) Go` poll answer for THAT channel and target, whose msg id is recorded
  in the journal (the same caller rule as spec 167 section 4.1, D1).
- The hub does the database and bucket work through one new operator endpoint
  (T7); the shell action drives it and does the box steps.

### 8.2 The order

| step | what | undo |
|---|---|---|
| P1 | `plan`, freeze the set in the journal (in `<DST>`) | drop the journal |
| P2 | Check: `<DST>` exists, the caller is allowed, no channel `<CHANNEL>` in `<DST>` (else `TO_NAME=<new id>`), quotas fit, every seat has a `<DST>` desk, `<DST>` has an orchestrator seat (W2, the P2b probe's recipient), shared items resolved (5.5), no unresolved hours rows (5.1a) | nothing changed |
| P2b | Prove each agent's `<DST>` desk: one probe DM to the `<DST>` orchestrator seat on the probe topic (task id = `move_id`), msg id recorded in the journal (W2). No seat is added here | nothing to undo but the probe DMs, which stay in `<DST>` as part of the journal's record |
| P3 | Copy blobs and Qto objects to `<DST>` (idempotent) | delete the `<DST>` copies |
| P4 | **One database transaction**, asOperator: insert every row of the set under `<DST>` (parents first), rewrite `channel_order`, NULL the DM `ref_task_id`s, write the redirect rows (Q2); for a move, delete the set in `<SRC>` (children first, F5); recompute counters; bump change stamps. 3,650 posts (F13) is the largest set today (timing: R3). | the transaction rolls back as a whole |
| P5 | Box steps, at once after P4: rewrite the rule rows' tenant column, lane notes for new keys (W4). The seat rows already moved in P4 | journal-driven: a re-run resumes at the first step not marked done |
| P6 | Move only: delete `<SRC>` blobs and Qto objects no `<SRC>` row lists | none: by now `<DST>` is the only home |
| P7 | Run every proof of section 5 and write the results into the journal; print the kept list (5.6) with the date each copy expires | n/a |

P1-P4 (with P2b) can be re-run until P4 commits; P5-P7 resume from the journal.

### 8.3 The journal

A `<DST>` table (T2): `move_id`, mode, `<SRC>` slug, channel id, the frozen
id lists, the owner's GO msg id, one row per step with `started_at`,
`done_at`, counts and the proof results. It lives in `<DST>` on purpose: it
is the record that the channel came from somewhere, kept where the channel
now is.

## 9. Cases (each lands with its red control)

| # | case | red control |
|---|---|---|
| C1 | `plan` changes nothing: a row count of every tenant table before and after is equal | a `plan` that writes the journal in `<SRC>` -> the count differs |
| C2 | Catalogue gate: every table with `tenant_id` is classified in the move catalogue (moved / rewritten / recomputed / not about channels / refuse, with its reason; refuse = a row of the set makes `plan` stop, e.g. `embed_visitors`, 5.1b), like `TestRLSCoversEveryTenantTable` | add a test table with `tenant_id` and no entry -> red |
| C3a | Move, messages family: a seeded channel with topics, threads, a poll with answers, reactions, revisions, live acks, read marks, a `path` attachment, a DM about a topic, and a post spec 045 moved out of it into a staying channel: every 5.1 messages proof is 0 in `<SRC>`, every row is in `<DST>` with equal counts, the staying post's `moved_from_*` is NULL | skip the `delivery_live_acks` copy -> the `<DST>` count differs and the cascaded `<SRC>` delete has lost them |
| C3b | Move, issues: issues with an epic in the set, their events, discussions and `spec_sync_map` rows; a `spec_sync_map` row a staying issue also needs makes `plan` refuse | drop the shared check -> the staying row's `issue_number` is NULL after the move |
| C3c | Move, Qto docs: doc, items, nodes, ACL and rev log in `<DST>`'s tree; 0 in `<SRC>` | skip the rev-log copy -> the `<DST>` rev count differs |
| C4 | F5 order: the move never does `UPDATE ... SET tenant_id` on a parent | swap to an UPDATE -> the FK refuses, the transaction rolls back, `<SRC>` unchanged |
| C5 | A failure in P4 leaves both workspaces exactly as before | inject an error after half the inserts -> counts equal to C1's before |
| C6 | Shared file: a blob also attached in a staying channel is copied, not deleted in `<SRC>` | delete it anyway -> the staying post's file 404s |
| C7 | Shared item rule (Q6): with the default, an issue linked to topics in two channels refuses the move, naming it | remove the check -> the other channel loses its issue link |
| C8 | Old permalink and a lane post to a moved task at `<SRC>`: never create a `<SRC>` row. Both Q2 variants are tested (redirect on: redirect and re-route; off: 404 and refused), so the case does not wait for Q2 | post to the moved task id at `<SRC>` -> a new `<SRC>` topic appears |
| C9 | Counters equal a fresh count after the move, in both workspaces | skip the recompute -> `<SRC>` counts still include the channel |
| C10 | A moved file read from `<SRC>` -> 404; from `<DST>` -> the bytes | serve from the LRU without the DB check -> 200 |
| C11 | Seats: a channel agent without a `<DST>` desk makes `plan` refuse, naming it; a desk whose P2b probe DM fails stops the move before P4, nothing changed; after P4 the seat rows are in `<DST>` and none in `<SRC>` | drop the check -> the agent cannot post after the move (spec 167 W3); skip the probe -> a dead `<DST>` desk passes P2b |
| C12 | Issue keys: the new issue carries the old key in its first event; a lane gets one note old -> new | skip the note -> the lane's next commit cites a dead key |
| C13 | No `<SRC>` audit row and no hub-wide row naming the channel; one `<DST>` audit row. The only `<SRC>` writes besides the deletes of the set are the named NULL / removal updates: M6b `moved_from_*`, M9 `ref_task_id`, the `channel_order` entry, the shared-item resolutions the owner chose (5.5), the topic-head recompute and the counters and change stamps (5.1); a diff of `<SRC>` before and after shows no other changed row | the default audit writer -> a `<SRC>` row names the channel; an extra `<SRC>` UPDATE -> the diff names it |
| C14 | Free-text scan (5.2) prints 0 for the channel id, name and every UUID, over text, jsonb, uuid and array columns | plant the channel id in a `<SRC>` `workspace_events.message` -> 1; plant a moved task id in a staying post's `moved_from_task` (uuid) -> 1 |
| C15 | Caller: `DRY_RUN=0` without the owner's GO msg id is refused before any change | run as a lane agent -> refused, exit 3 |
| C16 | Copy: `<SRC>` row counts unchanged; `<DST>` ids are all new (task, msg, issue number, doc, doc item, doc node; rev log under the new doc id); a link inside a copied post points at the copied topic; a box receiving a copied row files it under the new task id | keep the old `workspace_doc_item.id` -> PK violation; keep the old UUIDs in the links -> the `<DST>` link resolves to nothing |
| C17 | Re-run after a crash in P5 resumes at the first undone step and finishes | re-run from P1 -> refused: the journal says P4 committed |
| C18 | Google Calendar: a moved event mapped in a `<SRC>` member's connection; after the move and one sync cycle of that connection, `<SRC>` has no event with that `source_key` and no map row, and the Google event is gone | skip the pre-P4 Google delete -> the In half imports it back into `<SRC>` |
| C19 | Hours: a job with plan rows and entries `job:<job>`, `t:<task>`, `ch:<CHANNEL>` moves whole; an entry inside an `approved` `<SRC>` period makes `plan` refuse, naming it (Q8 default) | drop the period check -> the approved period's stored total no longer matches its rows |
| C20 | Rows whose parent does not move: a channel invite for a kept email moves with its new `<DST>` workspace invite; a channel with an `embed_visitors` row makes `plan` refuse | insert the invite without its `<DST>` parent -> the FK refuses and P4 rolls back |
| C21 | Hours, Q5 stop: a channel member who is not a `<DST>` member and not added by the owner, with entries `t:<task>` and `ch:<CHANNEL>`, makes `plan` refuse with `hours: <member> 2 rows not coming to <DST> (Q5)`; the same member also inside an `approved` period prints the Q8 line too; adding the member clears only the Q5 line | drop the member check -> the move goes on and the member's rows are moved into a workspace they cannot read |

All cases run on PostgreSQL (`PRE_PUSH_TIER=full`), with two test workspaces
on the hub's test database; none touches dev or prd.

## 10. Build rows

Each row is one small task; files named are where it lands.

| # | task | files |
|---|---|---|
| T1 | Move catalogue: one Go table of every `tenant_id` table with its class, the predicate that finds the set's rows and the parent rows it `Needs` in `<DST>` (5.1b); the gate C2 | `api/channelmove/catalogue.go`, `catalogue_test.go` |
| T2 | Migration: the `<DST>` journal table and the hub-wide redirect table (Q2), with RLS and the tenant isolation test | `csi-spl-rdb/src/sql/postgres/spool-hub/<head+1>_channel_move_journal.sql`, an entry in `api/store/rls_test.go` |
| T3 | Migration: `messages.copied_from` (nullable, catalog-only) for copies | `csi-spl-rdb/src/sql/postgres/spool-hub/<head+2>_messages_copied_from.sql` |
| T4 | Store: `PlanChannelMove` (read-only set, shared items, mentions) and its tests C1, C7 | `api/store/channel_move_plan.go` (+ `_postgres`, `_memory`, `_test`) |
| T5 | Store: `ApplyChannelMove` P4 frame: one transaction, insert-then-delete in catalogue order, counters and stamps, the messages family, hours, calendar and invites (5.1a, 5.1b) with the pre-P4 Google delete; tests C3a, C4, C5, C9, C18, C19, C20, C21 | `api/store/channel_move_apply_postgres.go`, `_test.go` |
| T5b | Store: the issues part of P4 (renumber, events, discussions, `spec_sync_map`); test C3b | `api/store/channel_move_issues_postgres.go`, `_test.go` |
| T5c | Store: the Qto part of P4 (doc, item, node, ACL, rev log, re-placed in `<DST>`'s tree); test C3c | `api/store/channel_move_docs_postgres.go`, `_test.go` |
| T6 | Blob and Qto object copy/delete P3/P6, the shared-file rule; tests C6, C10 | `api/channelmove/objects.go`, `_test.go` |
| T7 | Hub operator endpoint (owner GO msg id required) and the moved-task refusal / redirect; tests C8, C15 | `api/hub/channel_move.go`, `_test.go` |
| T8 | Proofs P7 and the free-text scan; tests C13, C14 | `api/channelmove/proof.go`, `_test.go` |
| T9 | Shell action `do_spl_channel_workspace_move` (plan, DRY_RUN, journal resume) and its test C17 | `orc/run/spl-channel-workspace-move.func.sh`, `orc/tests/spl-channel-workspace-move.tst.sh` |
| T10 | Box steps: the P2b probe DMs, the P5 rule-row rewrite (no action writes `channel-rules.tsv` today, so it lives here), lane key notes; no re-seat (the seat rows move in P4); tests C11, C12 | `orc/features/spawn-agents/scripts/channel-workspace-move-box.sh`, its test |
| T11 | Copy mode: new UUIDs, link rewrite, `copied_from`; test C16 | `api/store/channel_copy_apply_postgres.go`, `_test.go` |
| T12 | Docs: operator page (how to plan, run and read the kept list) | `csi-spl-doc/doc/md/channel-workspace-move.md` |
| T13 | Dev rehearsal, the gate before the first prd run: on dev, `plan` then `DRY_RUN=0` of a seeded channel between two dev test workspaces with the owner's GO msg id (C15), P7 prints 0, the journal read back; the record of the run | `csi-spl-doc/specs/169-channel-workspace-move/dev-rehearsal.md` |

Order: T1 first (it is the inventory in code); T2 before T5 (the journal);
T4 before T5; T5 before T5b and T5c; T3 before T11; T6 and T8 before T7; T7
before T9; T9, T10 and T7 before T13.

### 10.1 Lanes

The split sent to the dispatch holder on 2026-10-30 (msg 25f67404), for the
owner's weekend deadline: lanes with no files in common.

| lane | rows |
|---|---|
| L1 | T2, T3 (rdb; one lane, so two lanes never race for a migration number) |
| L2 | T1 |
| L3 | T6 |
| L4 | T4 |
| L5 | T8 |
| L6 | T5, T5b, T5c, T11 |
| L7 | T7 |
| L8 | T9, T10, T13 |
| L9 | T12 |

L8's stub is the plan-only path of T9 (`MOVE_CMD=plan`, journal resume
skeleton), so it can land before T7; its wiring to the T7 endpoint and T10
come in wave 4.

Waves: 1 = L1, L2, L3, L8 (stub), L9; 2 = L4, L5; 3 = L6; 4 = L7, then L8's
wiring, then T13 (the dev rehearsal). Critical path for the first move:
L2 > L4 > L6 > L7 > L8 (T13 last), with L1's DDL live on dev and prd first.
Copy (T11) is not on the first move's path.

## 11. Owner questions

### 11.1 Decisions

Read from the owner's own answers in prd t1 topic
`3a618e79-8ecc-4154-9ec8-58ed6261b1e8` on 2026-10-30
(`do_spl_db_query`, `from_id='HUM-10'`).

| Q | answer | owner msg | what the spec does |
|---|---|---|---|
| Q1 | A, a snapshot | `d2c97186` (poll `0d78f4d9`) | section 7 as written; no sync |
| Q2 | A, 30 days of redirect, re-route and old issue key map, then 404 | `333aea7b` (poll `502a793f`) | W3-W5, C8 with the redirect on; T2's redirect table expires rows after 30 days |
| Q3 | A, keep until they expire | `d2c97186` | 5.6 as written; P7 prints the last expiry date |
| Q4 | A, leave them and list them | `d2c97186` | 5.4: `plan` lists, nothing edited |
| Q5 | A, they lose access; the move lists them and the owner adds whom he wants | `0c58c916` (poll `dfa0234a`) | W1, 5.1 (`channel_humans`, `channel_invites`, `channel_subscriptions`, `read_marks`), 5.1a hours, 5.1b invites, calendar guests: of the channel's people who are not `<DST>` members, only those the owner adds to `<DST>` come along; existing `<DST>` members keep their access (W1); the move adds no one by itself; C21 |
| Q6 | A, stop and list | `d2c97186` | 5.5, C7: `plan` refuses on a shared item |
| Q7 | J (`f6f94c97`): the csitea channel named like `ws-hidden-17`; destination (`e4cc2662`): `ws-hidden-17` | `f6f94c97` and `e4cc2662` (poll `c5dc7cea`) | the first move: `<SRC>` = csitea, `<CHANNEL>` = the csitea channel named like `ws-hidden-17`, `<DST>` = `ws-hidden-17` (the slug stays in the overlay); the first prd run waits only for the build (10.1 critical path, T13 the dev rehearsal last), no longer for a name |
| Q8 | A, stop and list | `85eb389c` (poll `53f98bf8`) | 5.1a, C19 |

### 11.2 The polls as asked

Asked as one poll, recommended option first in each:

```poll
Q1 Copy: what should a copied channel be? I recommend A.
(A) A snapshot: it lives on by itself after the copy
(B) Kept in sync: new posts in the source keep arriving in the copy
Q2 After a move, an old link, a post to a moved topic, or an old issue key, in the old workspace: I recommend A.
(A) For 30 days a hub-wide note (ids only, no names) redirects the link, re-routes the post and maps the old issue key to the new one; then nothing, 404
(B) Nothing at once: 404, and a post there is refused
(C) Redirect forever
Q3 Backups, logs and copies that already hold the channel (section 5.6): I recommend A.
(A) Keep them until they expire on their own; the move prints the date the last one goes
(B) Purge what can be purged now; you remove the off-project backup copies by hand
Q4 Posts in OTHER channels of the old workspace that link or name the moved channel: I recommend A.
(A) Leave them; the move lists them for you
(B) Replace each link with a plain "moved" note (edits other people's posts)
Q5 People in the channel who are not members of the new workspace: I recommend A.
(A) They lose access; the move lists them and you add whom you want
(B) Add them all to the new workspace
Q6 Things the channel shares with channels that stay (a file, a doc, an issue): I recommend A.
(A) The move stops and lists them, you decide each one
(B) Copy them into the new workspace, the old one keeps its own
(C) Move them; the other channels lose them
Q7 The first move: I recommend A.
(A) A csitea channel into the new workspace created 2026-10-29: tell us which channel
(B) Not now: build it first, then you pick
```

Asked after v0.4, as its own poll, since Q1-Q7 were already out:

```poll
Q8 Hours that members logged on the moved channel inside a time sheet already approved or frozen in the old workspace: I recommend A.
(A) The move stops and lists them; you reopen those sheets or tell us to leave the rows
(B) Move them anyway; the old sheet's approved total no longer matches its rows
(C) Leave them in the old workspace; they keep naming the channel
```

## 12. Risks and open checks

| # | risk / open check | what settles it |
|---|---|---|
| R1 | The pins (`pins`, per workspace) hold the box keys that signed and encrypted the posts (F10). A row moved to a workspace where its box is not pinned can be stored but not re-verified. | `plan` checks each `from_box` is pinned in `<DST>` and lists the missing ones (T4) |
| R2 | Encrypted posts (`enc`, `for`) are readable only by the boxes named in `for`; a move does not change that. | stated in the operator page (T12) |
| R3 | A move of the largest channel inside one transaction locks its rows for the length of P4. Not measured. | a T5 timing test on a 3,650-post seeded channel before the first prd run |
| R4 | Not checked here: Cloud SQL backup retention and the hub log bucket's retention (5.6). | `plan` reads both and prints them |
| R5 | Spec 167 moves a channel's work between boxes; a move between workspaces that is also a move between boxes runs 167 first, then this. | operator page (T12) |
| R6 | The free-text scan (5.2) proves absence of exact strings only. | stated; not claimed further |
