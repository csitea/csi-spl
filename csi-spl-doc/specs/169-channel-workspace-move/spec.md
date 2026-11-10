# 169 Channel Workspace Move: move or copy a whole channel into another workspace

Version: v0.29 (2026-11-08). Status: **Draft** (part built: section 8.4's hub
steps are T7, section 10 lists the rows; the shell calls them, T9). Issue SPL-4393 · Epic SPL-2398 · Class feature · Kind
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
The R7 notes on v0.9 by c-073 are folded too: 5.1a quotes the Q5 poll
option the owner chose, not words he wrote; the Q5 row marks C21 as the
lead's hours stop; T13 records R3's timing.
v0.10 gives the two checks no row owned their own rows (c-001, 2026-11-02,
reply to c-002 msg 8d5be6ce): T4b takes R1 and W2's plan check off T4, and
T9b prints R4's two retention values from the shell plan path, because the
store cannot read them and a hub endpoint would need new IAM. Cases C22-C24.
v0.12 adds row T7b and widens T7's file list (c-001, SPL-4598): T7 refuses a post to a
moved task with the destination, the box client re-routes it, and expired
redirect rows stay until a sweep is decided.
v0.14 says what T7b does (c-932, SPL-4601): W3 and row T7b.

v0.11 names the one exception to the free-text scan printing 0 (c-001,
2026-11-02, msg b42a543c, its decision as orchestrator, on the T8 lane's
question): the fleet topic ids of 5.1 when `<SRC>` holds the fleet rows
(5.2, C14).
v0.13 adds T4d (owner HUM-10, t1 537d51e9, msg a36bb9cd): `plan` returns the
channel's full seat list, the source T9c's "run this plan on box X too" line
and T7's probes read; it had only the seats with no desk. Case C27.

v0.15 folds the T5 review rulings (c-001, 2026-11-02, msgs e635838b and
9712f542): the audit door's limit is named in P4, C18's sync-cycle half gets
its own row T7c, T13 runs P4 under the real runtime role, and `quota_counts`
stays in `<SRC>`. It also says what T4b means for T5: the plan under the lock
checks R1 and W2 again, so C28's sender branch (no live `<DST>` pin) cannot be
reached by a full move while R1 holds, and stays as a defence.

v0.16 corrects R1, F10 and C22 to what T4c measured (SPL-4599, c-001 msgs
5b72f83c and c8953637): a pinned box does not make a moved row verify.

v0.17 says what T7's step driver does (SPL-4598): section 8.4.

v0.18 settles section 7's two open points from the T11 lane (c-001,
2026-11-02, msgs fc977008 and 003d8136): a copied row gets its own envelope,
because the WUI, the box back-fill and the edit path all read the envelope; and
the list of what a copy carries. The comment in rdb 0250 ("keeps the original
env / env_sig") is history, superseded here.

v0.19 ticks T9 and T10 (L8 wiring, SPL-4771; c-001 rulings 12c58d30 and
8bd363e5): the action's default seam calls the T7 endpoint, and it prints the
plan's `.shared_files`, P4's and P7's `.report` and P7's `.kept`. P2 names
`TO_NAME` as a limit of the first move, and T13 measures P4 and P7 against
the box's 30 s client cap (`curl -m 30` in `spl_hub_operator_call`); the hub's
Cloud Run request timeout is 600 s.
v0.20 adds row T7d (c-001 ruling 12c58d30, c-894 items 4 and 5, msg
4b6b98a1): a plan or a step reads the owner's keep, keep_emails, leave_hours,
the box rule's doc and MOVE_CALLER from its `detail`, section 8.4.
v0.21 adds and ticks row T7h (c-894 item 2, msg 4b6b98a1; Q2 `333aea7b`,
W5): the web app's `/t/<uuid>` page follows the hub's `moved_to` to
`https://<DST_HOST>/t/<uuid>`; an expired redirect (no link) stays put.
v0.22 names the destination to a `<DST>` member only (W5; SPL-4818, R7
c-092 N3 on SPL-4781, msg ba5f6d6c): a `<SRC>` reader the move dropped (W1,
Q5) would otherwise learn a hidden workspace's id and host (11.1).
v0.23 ticks row T11b (SPL-4838, c-001 ruling e0203dc0 (1)): an owner go
found by `hub-tail` is also read as its messages row
(`spl_lane_issue_hub_row`); a copy, a row with no `copied_from` and a read
that fails file nothing.
v0.24 adds and ticks row T8b (c-894 items 3 and 6, msg 4b6b98a1; c-001
rulings a135a721 and 44111546): P7 proves the objects of 5.3 in the buckets
themselves, and dates each kept copy (5.6) as P4's `done_at` plus the days
the shell passes in P7's detail `retention_days`; with no value a row says
`not read: <reason>`. The shell half is a follow-up row (8.4).
v0.25 states row T11b's precondition (SPL-4871, R7 c-614 N1 and N2 on
SPL-4838): the copy check reads the env's hub database, and runs only
after the HUM-<n> sender check.
v0.26 adds and ticks row T8c (SPL-4888, R7 c-666 N1, N4, N5 on SPL-4837):
the shell sends P7's `retention_days` in days and prints each kept copy's
date and `.kept_until`; two more `bad_detail` tests; the note under T11 that
P7's `left in <SRC>` proof is a move's only.

v0.27 specifies the "Move to workspace" menu entry (SPL-4999; owner HUM-10, t1
035cb09e, msg a37901f1): section 8.5, cases C29-C35, rows T14-T20, risks R7 and
R8, the open questions Q9-Q11 (11.3). No row asked for it until now; the entry
is not built. T13 ran once on dev: [dev-rehearsal.md](dev-rehearsal.md). The rows moved, P7 failed
one proof, so T13 is not passed; R3 and R7 are measured, rows T13b and T13c are new.

v0.28 applies Q4 = A to the scan and dates the hub logs (SPL-5010, the
dispatch holder's rulings f9be5b57 and d7adb5e1, on T13's `proof scan
messages.body 1`): rows T13b and T13c, 5.2's second exception, 5.4, C14,
section 8.4's P7 notes, T8c's hub logs.

v0.29 folds the owner's answers to Q9, Q10 and Q11 (SPL-5046; owner HUM-10, t1
035cb09e, msg a271ca2c, poll 9ac73227): A to each, the recommended answers 8.5 already
followed. They move from 11.3 to the 11.1 table; 8.5 states them as decided; T14, T15,
L14 and L15 wait for no answer. The order of section 10 does not change.

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
| F10 | A signed envelope (`messages.env`, `env_sig`) carries no tenant: its fields are `v, msg_id, task_id, ts, from, to, kind, body, files, ref_task_id, accepts, sig` (encrypted form: `enc, for, ct`). A moved row keeps the envelope and the signature of its `<SRC>` key, and verifies only against that key. `pins_pubkey_live_unique` (rdb 0154) and `keyLiveElsewhere` stop a key being live in two workspaces, so the same-named box in `<DST>` normally holds ANOTHER key: its pre-move agent rows do not verify there. Same key only if its `<SRC>` pin was revoked first. Human rows pass (box-wui's key is the hub's in every workspace). So after a move: back-fill withholds those rows and counts them in its summary; no box may edit, delete or move them (`boxSignedRow`, `pins_history` does not move); a box reads them by tail only where tail shows them, and unsigned rows stay open by name (section 7). `spool_enc` rows: 0 on dev and prd (T4c), none tested. | `api/msg/msg.go` struct tags |
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
| `fleet_lanes`, `fleet_asks` (M11) | issue keys rewritten to the new keys (`fleet_lanes.issue_key` and `origin_issue`, `fleet_asks.issue_key`); topic ids unchanged (they live in the fleet's own workspace, not in `<SRC>`, unless `<SRC>` is that workspace) | `WHERE issue_key=ANY(<old keys>)` |
| aggregate counters (`message_period_counts`, `topic_head_tenants`, `tenant_change_stamps`) | recomputed for `<SRC>` and `<DST>` from the rows after the move; change stamps bumped so every cached view refetches | the recompute equals a fresh count (C9) |
| `quota_counts` | left in `<SRC>`: per-person rate windows (rdb 0127), it names no channel. The catalogue keeps its class `Recomputed` so the proof skips the table | not in C9 |

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
  The Q5 stop is the lead's choice, not an owner answer: the Q5 option he chose
  reads "They lose access; the move lists them and you add whom you
  want", and leaving the rows in `<SRC>` would also fit it. The spec stops because
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
- One exception to that scan printing 0: when `<SRC>` is the workspace holding
  the fleet rows, hits on `fleet_lanes.topic` and `fleet_asks.topic` are
  reported as known with their count, never as a failure, the same way 5.1a
  treats rows left by the owner's word; 5.1 keeps those topic ids unchanged.
  Any other column stays a failure, `issue_key` on those two tables included.
  The scan's caller (T7) counts those rows in `<SRC>` by the set's task ids and
  passes the two counts as known; with none passed, the hits fail.
- A second exception: the mentions of 5.4, which Q4 = A leaves in place. A hit in
  `messages.body` or `workspace_doc_item.body` is known only on a staying row
  (the catalogue's Set does not find it: the same rows `plan` lists), and only
  when every full task or msg UUID of the set in that body has a live
  `channel_move_redirects` row of this move. A name or channel id hit is known
  too: 5.4 says "name `#<CHANNEL>`, or quote it", and no redirect row can cover
  a name.
- `messages.msg` holds a post's text a second time, so a real post hits it too
  (T13's seed wrote `'{}'` there and could not show this). A hit there is known
  only on a row already known by its body, when `msg->>'body'` equals `body` and
  `msg` without its `body` key holds no hit. It is the same post, counted once.
- Every other hit stays a failure: a moved row left behind, a set UUID with no
  live redirect row of this move, a Qto item in a moved doc, and every other
  column, `message_revisions.body` included (`plan` does not list it), which
  reads `proof scan message_revisions.body <n>`.
- P7 lists the known rows by id (a msg id, or a doc and item id), with counts by
  class, `uuid with redirect` and `name or channel id`, never their text. A row
  with both is the first class. The word match is wider than `plan`'s `#<CHANNEL>`
  (a channel named `ops` hits the plain word), so the name count can be large,
  and P7's list can hold rows `plan` did not list.

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
author, line). What happens to them is Q4: A, they stay, and P7 lists them too
(5.2's second exception, which says which of them P7 accepts).

### 5.5 Shared items

A file, Qto doc, issue or epic that the set uses AND something staying in
`<SRC>` also uses. `plan` lists them; what the move does with them is Q6.

### 5.6 What is kept, and why (the owner accepts or rejects, Q3)

| store | holds | why it cannot simply be deleted | gone by |
|---|---|---|---|
| daily DB dumps (045) | the whole `<SRC>` database | a dump is one file for every workspace; editing it destroys the backup's integrity | its retention (30 days) |
| off-project copy (046) | the same dumps | its writer SA may add, never delete (by design, so a stolen key cannot wipe the backups); only the owner by hand can remove an object | its retention (30 / 90 days) |
| Cloud SQL automated backups | the whole database | managed by Cloud SQL, not per row | their retention (`plan` prints it: T9b, R4) |
| `<SRC>` Qto daily export (052 `backup/`) | `<SRC>`'s docs | one file per day per workspace | 30 days |
| box-state copy (056) | transcripts, the spool root | one nightly archive per box | 30 days |
| hub logs (Cloud Logging) | request lines with ids | logs are append-only by design | the log bucket's retention (`plan` prints it: T9b, R4) |
| mail and notifications already sent | text sent to people | outside the system | never |
| git history of this repo | commit subjects, specs and dispatch notes that cite a task id or an issue key | history is forward-only; no force-push (developer guide 4) | never |
| hours rows the owner said to leave (5.1a) | a member's time record that names the channel | it is the member's signed or kept time sheet, and the owner chose to leave it (Q8 = A, or a member not brought along under Q5) | never, unless the owner deletes it |
| box spool archives, transcripts, worktrees | copies of the channel's posts on the boxes | they are the agents' working memory, and "the whole work should be possible to continue" needs them; they name no workspace (F10) | spec 167's cleanup if the channel also leaves its box |

## 6. "The whole work should be possible to continue"

| # | what | how |
|---|---|---|
| W1 | Members | Humans of the channel who are members of `<DST>` keep their channel membership, read state and order. Others are listed by `plan`; the owner adds them to `<DST>` or not (Q5). The new workspace today is owner-only (msg f81b2742), so the default adds no one. |
| W2 | Agent seats | Each agent seated in the channel (M5, F14) needs a desk in `<DST>` on its box before the switch: `plan` checks `roster` / `agent_seats` in `<DST>` and refuses with the missing desks named. The `<DST>` DESK is proved in P2b, BEFORE the P4 commit (spec 167 W3): the agent sends one probe DM through its `<DST>` desk to the `<DST>` orchestrator seat (an agent, not a person: the hub's human post guard refuses an agent's DM to a person on a topic the person did not start unless it is a blocker, `dm_not_blocker`, `api/hub/human_post_guard.go`, SPL-2584), on the probe topic (task id = the journal's `move_id`; a DM needs no channel, so it works while `<CHANNEL>` does not yet exist in `<DST>`), and the journal records its msg id. The body names the `move_id` and the agent, so no two probes are equal. P2 refuses when `<DST>` has no orchestrator seat. The channel SEAT is not added by `do_spl_channel_agent_add_op` before P4: that action needs the channel to exist (`orc/run/spl-channel-agent-add-op.func.sh`). The seat rows (`dedicated_agents`, `channel_humans`, `channel_invites`, M5) move inside the P4 transaction like every other row of the set. After P4, P5 rewrites the box rule row's tenant column, so the box posts through the `<DST>` desk. Window: between the P4 commit and P5, a post from a lane through its `<SRC>` desk into a moved task is refused by the hub (C8); whether the box retries a refusal or files it as rejected is not checked on master, and T10 tests it and the operator page (T12) says which. P5 follows P4 at once, in the same run. |
| W3 | Lanes and spool task ids | Task UUIDs and msg UUIDs do not change (F4, F10), so a lane's `--task <uuid>`, its brief and its dispatch files stay valid; only the desk the post goes through changes (W2). A post into a moved task at `<SRC>` must not create a new `<SRC>` topic with that id: the hub refuses it (T7), and for the 30 days of Q2 the box client re-routes it (T7b): the same inner msg, once, through the sending agent's own `<DST>` desk, under that desk's key. There is no re-route with no desk or seat for that agent in that workspace on this box, on an expired redirect (404), on a detail `ParseMovedDetail` refuses, or on a second `topic_moved` from `<DST>` (one hop): the post is not sent, it moves to `rejected/` with its reason, and the agent's inbox and the caller's error carry the token and any destination. A failed read (503, `moved_check_failed`) stays pending and retries; an answer is never queued, so its caller gets the error. |
| W4 | Issue keys | Each moved issue gets a new `<DST>` key (F6). The move posts every lane whose `fleet_lanes.issue_key` changed a note with old -> new key; its commits cite the new key. The closer maps an old key to the new one while the redirect lives (Q2, which covers issue keys too); after that an old key closes nothing. |
| W5 | Permalinks | A moved topic's link is `https://<DST_HOST>/t/<uuid>` (same uuid). An old `https://<SRC_HOST>/t/<uuid>` link: Q2. The hub names the destination (`moved_to`, `moved_to_tenant`, the `wire.MovedDetail` of a browser post's refusal) only to a reader who is a `<DST>` member; any other reader, and every reader once the redirect has expired, gets the bare 404 `topic_moved` with no workspace and no link. A `<SRC>` member the move dropped (W1, Q5) must not learn a hidden `<DST>` (11.1). A box post's refusal keeps the destination: the box client re-routes only through its own `<DST>` desk (T7b). Code: `dstMember` in `api/hub/channel_move.go`; test `TestChannelMoveNonMemberNoDestination`. |
| W6 | Open polls, claims, parked rows | Columns travel with the row (`responsible`, `locked_until`, `claim_state`, `parked_until`, `wait_token`; polls in `message_answers`): an open poll can be answered in `<DST>` the minute after the move. |
| W7 | Live clients | Bumped change stamps (5.1) make every open WUI refetch; a `<SRC>` client drops the channel, a `<DST>` client shows it. A browser that is offline keeps its local cache of `<SRC>` until it next loads (kept: other people's devices). |

## 7. Copy (replicate)

The owner's words leave one thing open: is the copy a snapshot that lives on
by itself, or kept in sync with the source (Q1)? The plan below is the
snapshot; a sync would be its own spec.

- Same set (section 4), same order; `<SRC>` is only read.
- Pre-move and pre-copy agent rows normally fail against the box's `<DST>` pin
  (F10), so a new seat is not sent them. Tail, unverified as tail is today, is
  its only box-side way to read them, and tail shows a box only rows it sent,
  was addressed by or had delivered: a row from ANOTHER box with no delivery
  to this box reads 0 rows (`TestBackfillWithheldRowByTail`). So a seat added
  after a move cannot read other boxes' pre-move agent rows through spool at
  all; people read them in the browser, and the box summary says so.
- An agent's issue comment is unsigned by design (`hub/issues_agent.go:321`,
  `Sig: ""`, channel `issues`; prd 3163 rows on 2026-11-02, dev 0). With no
  signature to check, such a row moved into `<DST>` stays editable, deletable
  and movable by a same-named box there, by name only.
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
- The signed envelope (F10) holds the OLD msg and task ids, and every reader
  takes ids and body from the envelope (the WUI: `hub/view.go` `trimEnv`; a box:
  `hubclient/backfill.go`; an edit: `hub/edit.go` `reEnvelope`). So a copied row
  gets its own envelope: `env.msg` and `messages.msg` are rewritten with the new
  ids and links, `env_sig` is `''`, and `copied_from` names the source row. The
  signed original stays in `<SRC>`, which a copy leaves unchanged. A
  `ref_task_id`, `mirror_of` or 045 move column that points outside the set is
  cleared. Supersedes the comment in rdb 0250.
- What a box sees: a box gets a copied row only with the new ids, or not at all.
  An unsigned row is not back-filled (`ChannelBackfill`), and `UnsignedWUIPosts`
  leaves a copied post out, so replay never re-signs it. Later replies in the
  copy are ordinary posts.
- A copied post is nobody's word in `<DST>`: a reader that takes a message id as
  someone's authority refuses a row with `copied_from` set: `approval()`,
  `_spl_oo_hub` (and the owner-order gate on it), `channelMoveGoRefusal`,
  `do_spl_wine_box_tester_tf`, `spl_lane_issue_hub_row` (owner and ACCEPTED
  evidence). Three more are ruled (c-001 e0203dc0):
  - `spl_issue_owner_go_from` reads `hub-tail`, which does not return the
    column: row T11b, not in T11. It must refuse a copy and a reply that does
    not say. No prd copy before T11b lands.
  - `spl-review-go`'s `Owner-go:` reads box spool files: a named limit, no code.
    It is safe only while a copy reaches no box; any change that delivers copies
    must add the check here.
  - `ResignMessage` has no `copied_from` condition: a named limit, no code. Its
    one production caller is fed by the filtered list `UnsignedWUIPosts`.
- What a copy carries, beyond the ids above:
  - new ids through the map: `calendar_events` and, for the people who are
    `<DST>` members, `calendar_guests` (an agent guest stays behind);
    `hours_jobs` under a new job id. A copied event reaches nobody: no
    `remind_at`, no stored reminders, no Google map row, and a `source_key` in
    the `gcal:` family the Out half never pushes without one, which also makes
    it read-only in `<DST>`.
  - not carried, per person or per box: `deliveries`, `delivery_live_acks`,
    `fallback_deliveries`, `read_marks`, `channel_subscriptions`,
    `dedicated_agents`, `channel_invites`, `flow_watches`, `flow_events`,
    `issue_opens`.
  - not carried, time records: `hours_minutes`, `hours_entries`,
    `hours_entry_spans`, `hours_adjustments`, `hours_plan`.
  - not carried, the audit trail: `usage_events`, `token_budgets`,
    `workspace_events`, `operator_audit`, `demo_post_audit`, `sql_query_audit`.
    The audit door (rdb 0251) stays shut. `<DST>` gets one `channel.copied` event.
  - not carried, a link a snapshot must not follow: `spec_sync_map`.
  - sections 5 and 6 list `hours_plan`, `flow_events` and `spec_sync_map` as
    moved. That is the move. A copy leaves all three in `<SRC>` and writes none
    in `<DST>`.
  - `search_tsv` keeps the source row's value, so a search in `<DST>` for an old
    id can still find the copied post. A search hit is not authority.
  - a copied post's claim is done, so no later seat is offered it.

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
| P1 | `plan`, freeze the set in the journal (in `<DST>`), for the P2 check; P4's re-plan under the lock is the set moved (8.3) | drop the journal |
| P2 | Check: `<DST>` exists, the caller is allowed, no channel `<CHANNEL>` in `<DST>` (else `TO_NAME=<new id>`; a named limit for the first move: a step or mark with a `TO_NAME` other than the channel's id answers 501 `not_built`, `api/hub/channel_move.go`, so the name must be free in `<DST>`), quotas fit, every seat has a `<DST>` desk, `<DST>` has an orchestrator seat (W2, the P2b probe's recipient), shared items resolved (5.5), no unresolved hours rows (5.1a) | nothing changed |
| P2b | Prove each agent's `<DST>` desk: one probe DM to the `<DST>` orchestrator seat on the probe topic (task id = `move_id`), msg id recorded in the journal (W2). No seat is added here | nothing to undo but the probe DMs, which stay in `<DST>` as part of the journal's record |
| P3 | Copy blobs and Qto objects to `<DST>` (idempotent) | delete the `<DST>` copies |
| P4 | **One database transaction**, asOperator, with `app.channel_move = 'on'` set transaction-local: the one door through the append-only guards of `usage_events`, `sql_query_audit` and `demo_post_audit`, a DELETE only and only in the operator scope (rdb 0251). The limit of that door: a session on the runtime login can erase rows of those 3 audit tables with no copy and no trace, and nothing detects it; 0251 adds this for `usage_events` and `sql_query_audit`. Insert every row of the set under `<DST>` (parents first), rewrite `channel_order`, NULL the DM `ref_task_id`s, write the redirect rows (Q2); for a move, delete the set in `<SRC>` (children first, F5); recompute counters; bump change stamps. 3,650 posts (F13) is the largest set today (timing: R3). | the transaction rolls back as a whole |
| P5 | Box steps, at once after P4: rewrite the rule rows' tenant column, lane notes for new keys (W4). The seat rows already moved in P4 | journal-driven: a re-run resumes at the first step not marked done |
| P6 | Move only: delete `<SRC>` blobs and Qto objects no `<SRC>` row lists | none: by now `<DST>` is the only home |
| P7 | Run every proof of section 5 and write the results into the journal; print the kept list (5.6) with the date each copy expires | n/a |

P1-P4 (with P2b) can be re-run until P4 commits; P5-P7 resume from the journal.
The box lock is per box and the hub holds no step lock, so a second P4 from
another box can pass the gate while the first commits. Its start never
clears a done P4: the journal keeps the done mark and the start answers 409
(SPL-5075, `api/store/channel_move_journal_postgres.go`
`StartChannelMoveStep`; test `TestStartChannelMoveStepKeepsCommittedP4`, on
Postgres, with a start after the commit and one that waits on it).

### 8.3 The journal

A `<DST>` table (T2): `move_id`, mode, `<SRC>` slug, channel id, the frozen
id lists, the owner's GO msg id, one row per step with `started_at`,
`done_at`, counts and the proof results. It lives in `<DST>` on purpose: it
is the record that the channel came from somewhere, kept where the channel
now is.

P1 freezes the set for the check. P4's re-plan under the channel lock is the
set moved: it replaces the frozen lists, and that is what "frozen" means
wherever the proofs read it. A stop that re-plan finds and P2 did not clear
refuses P4; a differing GO refuses it; its step counts record each list's P1
and moved size; after P4 commits nothing replaces them.

### 8.4 What the hub's steps check (T7)

`op step` runs P1, P2, P3, P4, P6 and P7; `op mark` records the box's P2b and
P5. Every call carries the owner's GO; after P1 it also carries the journal's
`move_id` and the journal's GO.

- Each step needs the step before it done (8.2). P2, P2b, P3 and P4 close once
  P4 commits. A refused step answers 409 with the reason and stays not done.
- P2 refuses on the plan's stops, a name taken in `<DST>`, an attachment total
  over `<DST>`'s file quota (Qto pictures are not counted), and no agent with
  the orchestrator number on `<DST>`'s roster; when the detail names the
  `caller` (`MOVE_CALLER`), that agent, on that box when it names one (T7d).
- The P2b mark needs a stored message per seat, from that agent on the move's
  topic in `<DST>`. P4 refuses a seat with no probe, so a seat P2 found on a
  re-run is probed first.
- P4 reads the lanes on the frozen issue keys before the transaction: afterwards
  a new key can equal a staying issue's key in `<SRC>`. A lane filed on a moved
  key after P1 gets no note. `op journal` lists only lanes whose key changed.
- P6 copies from what P4 moved, then deletes: a post can land between P3 and P4.
- P7 proves the objects of 5.3 in both buckets (T8b): per kind (M4 files, M8
  Qto pictures) a `left in <SRC>` and a `missing in <DST>` count. A shared
  object a staying `<SRC>` row lists (5.5) is a known hit; a bucket P7 cannot
  read fails the step, never a 0.
- P7 passes the `fleet_lanes` and `fleet_asks` topic counts and the mentions of
  5.4 as known (5.2), read in one REPEATABLE READ snapshot with the scan, so a post
  landing between the reads neither hides a hit nor fails P7. The
  shell fails on any `.proofs` count that is not 0, so a known hit is answered as
  count 0 with its count in the name. A failed proof answers 200 with the counts
  and P7 stays not done.
- The hub-wide log names the move id and the step, never a channel, a slug or an
  error text (C13). The reason goes to the operator in the answer.

The `detail` of a plan or a step (T7d) is
`{keep, keep_emails, leave_hours, rule_doc, caller, retention_days}`, every field optional: the
HUM ids the owner adds to `<DST>` (Q5), the channel invites' emails that move
(5.1b), the HUM ids whose hours rows stay in `<SRC>` (Q5, Q8: it clears their
hours stops in plan, P2 and P4), the Qto doc of column 3 of the box rule row
(F14), the `MOVE_CALLER` seat, and for P7 the days of each kept row of 5.6
that ends with a retention (T8b: P7 dates it from P4's `done_at`; the shell
sends what it can read, T8c). An unknown field or a malformed value answers
400 `bad_detail`. An absent value is the safe side: nobody kept, every invite
deleted, every hours stop stands. P2 records the detail in its step, and P4
refuses a detail that is not the one P2 checked. A mark's `detail` stays its own
(the probes). The shell does not send this detail yet.

### 8.5 The "Move to workspace" menu entry

The owner's words (t1 035cb09e, 2026-11-07), a37901f1: "There is no "move to
workspace" option in the menu for the "enable whole channel movement to another
workspace" option". Read on origin/master `0b2f05cb1`:
`git grep -ciE 'move.to.workspace|channel-moves|moveToWorkspace' -- csi-spl-wui/src`
finds nothing, and no row of section 10 asked for it before this version. Today the
only door is the shell action, called as the env's service account.

Not built yet: everything in this section. The owner decided Q9, Q10 and Q11 (11.1,
msg a271ca2c): A to each, the answers the text below was written for.

#### 8.5.1 Where it sits

One item, `Move to workspace`, in the channel row's menu of the sidebar:
`rowMenuItems` in `csi-spl-wui/src/utils/sidebar-row-menu.mjs`, inside its channel
branch, after `properties` and before `archive-channel`, emitted through
`SidebarRowMenu.vue` and handled in `ChannelSidebar.vue`, as `archive-channel` is.
A default channel never shows it (`store.ChannelPublic`: the hub answers 400
`bad_channel`). Its dialog loads lazily, like `LazyChannelConfirmDialog`, so it
stays off the initial script. The dialog offers no copy (the hub answers 501
`not_built`, T11) and no new name (`TO_NAME` answers 501 on a step, P2).

#### 8.5.2 Who sees it

Decided (Q11 A, 11.1): only the owner of the operator workspace sees it, on any channel of a
workspace the owner is in.

A person, never the service account, and only the person whose click is a GO:

- signed in, a member of `<SRC>`, and the **biz owner of the operator workspace**:
  the same test the GO check already makes (`channelMoveOwner`,
  `api/hub/channel_move.go:361`, `MemberRole(from, op) == rbac.BizOwner`). The
  operator console's test is a different one, `Admin` (`operatorActor`,
  `api/hub/operator_workspaces.go:103`), and is not reused: an admin who is not
  the biz owner could press a button whose answer the hub then refuses;
- the WUI cannot read that role, so the item shows only after the hub said so
  (8.5.3), the way the operator console shows only after its list answered
  (`stores/operator-pane.ts`). A failed or refused probe hides the item. The probe
  runs when the channel's menu opens, as `note.probe()` does, not at page load;
- the hub remains the gate. A hidden item is a convenience, not the check, and every
  route below checks again.

Targets: only the workspaces where this person is a member (Q10 A, decided, 11.1). A
hidden workspace the person is not in is never listed, the same reason as W5.

#### 8.5.3 What browser auth the hub needs

`POST /v1/operator/channel-moves` cannot serve a browser, and does not change: it
takes a Google ID token on the operator allow-list (`operatorAuth`,
`api/hub/operator.go:43`), which a browser does not hold. New routes, on the member
session, in `<SRC>`'s host:

| route | what it does | answers |
|---|---|---|
| `GET /v1/channels/{channel}/workspace-move` | the probe and the targets (T14) | 200 `{allowed: true, targets: [{slug, name}]}`; 403 `channel_move_owner` for anyone else |
| `POST /v1/channels/{channel}/workspace-move/plan` | `{dst, keep, keep_emails, leave_hours}`: the plan, and the stops P2 adds (T14) | 200 the plan with `.blocked`; never writes |
| `POST /v1/channels/{channel}/workspace-move` | the confirm: writes the GO, runs P1 (T15) | 200 `{move_id, topic}`; 403; 409 with the stops |
| `GET /v1/channel-moves/{move_id}` | where a move stands (T17), read in `<DST>` | 200 the steps and the reason; 404 to anyone who is not the biz owner of the operator workspace |

Each takes `humanTenant`, then the owner test of 8.5.2, then `channelMoveValid`'s
checks, and a CORS preflight like `channelArchivePreflight`
(`api/hub/channel_members.go:90`). None of them takes a `step` or a `mark`: the browser
never drives P2 to P7 (8.5.5). A service account has no member session, so it cannot
reach them, and a person cannot reach the operator route: neither door opens the other.

#### 8.5.4 The steps shown

Three screens in one dialog:

1. **Plan.** The target (a list from 8.5.2), then the plan as the shell prints it
   (`channelMovePlanAnswer`): the counts in words, the mentions left in place (Q4), the
   shared files, the kept list (5.6). Each person in `.members_lost` has a checkbox "add
   to `<DST>`", which is T7d's `keep` (Q5); each channel invite's email likewise is
   `keep_emails` (5.1b).
2. **Blocked.** Shown instead of a confirm while anything stops the move, each line with
   what clears it (the table in the operator page's section 2.3): a seat with no desk, a
   box with no pin, a shared item, a name taken in `<DST>`, hours rows. An hours stop has
   a "leave these rows" choice, T7d's `leave_hours` (5.1a). This list must include what
   the plan answer leaves out today: **the orchestrator seat and the file quota are only
   checked at P2** (`dstHasOrchestrator` and `fileUsage.over`,
   `api/hub/channel_move_steps.go:251`), so T14 runs both and adds them to `.blocked`.
   One stop it cannot show: the box rule (T9c, C25) lives on a box and the hub cannot read
   it, so that one can only appear as a stuck move (8.5.6).
3. **Confirm.** The channel, the target, the counts, the people who lose access, and "this
   cannot be undone once the rows have moved" (8.2: P4 has no undo after it commits). One
   button, enabled only with nothing blocked. No typed name: the owner's rule is one click
   (how-to-post section 7).

#### 8.5.5 What the confirm does

The hub cannot run the whole move: **P2b and P5 are box steps** (the desks and
`channel-rules.tsv` live on a box, W2, F14; `_spl_cwm_probe_all`, `_spl_cwm_box_p5`). So
the click only records the GO and starts the journal, and a box does the rest:

1. On the click the hub writes, in a new topic of the operator workspace, a poll form that
   names `<SRC>/<CHANNEL>` and `<DST>` as whole slugs, and the person's answer `Poll: <form>`
   / `Answer: GO`, as that person from `box-wui`. Then `channelMoveGo` checks it like any
   other, so the check stays in one place, and the answer's msg id goes in the journal (8.3)
   (Q9 A, decided, 11.1: the confirm click is the GO). The click is the person's own, on
   their own session; no agent and no service account can write this answer, because the
   route needs the session.
2. The hub runs P1 with the dialog's `detail`, and keeps that detail for P2 (8.4: P4 refuses
   a detail other than the one P2 checked).
3. A box action, `do_spl_channel_move_pickup`, from cron every 5 minutes on the box holding
   the orch lease (T16), reads the open journals through a new operator op, `open`, and runs
   `do_spl_channel_workspace_move` for each with the journal's GO, its detail and
   `MOVE_CALLER` = `<DST>`'s orchestrator seat. It sends the `detail` the shell does not send
   yet (8.4; the operator page's section 2.4 lists what waits on this).

A named limit: P2b probes only the desks of the machine that runs the move, so a seat whose
`<DST>` desk is on another box stops that move before P3, and it shows as stuck. Spec 167
first (R5). Choosing the box per move is not built here.

#### 8.5.6 What a stuck move shows

`channelMoveFail` answers a refusal to its caller and stores nothing, so today only the
shell's log knows why a move stopped. T17 stores the last refusal in the step's row in
`<DST>` (`channel_move_steps.detail`), never in a hub-wide log (C13). The status has one home
that survives the move: the topic of the GO in the operator workspace, because after P4 the
channel has left `<SRC>`'s sidebar and its menu with it. The hub posts one line there on each
change of state. The dialog, reopened from the menu before P4, reads the same route.

| state read from the journal | what the person sees |
|---|---|
| P1 done, no step started for 15 minutes | "Waiting for a box to pick this up. Nothing has moved." Also one `#alerts` line |
| a step of P2 to P3, or P4, refused | "Not moved. Nothing of the channel changed." The reason, and that a re-run comes with the next pick-up |
| P4 done, P5 or P6 refused | "The channel is in `<DST>`, the clean-up did not finish." A link to it, the reason |
| P7: a proof that is not 0 | "The channel is in `<DST>`, but `<SRC>` still holds traces." Each proof's name and count. Never "done" |
| `.done_at` set | "Moved." The link, and the kept list with its dates (P7's `.kept`) |

Nothing is shown as done before `channel_move_journal.done_at` is set. The browser has no retry
and no cancel: before P4 a re-run comes with the pick-up, after it there is nothing to cancel.

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
| C8 | Old permalink and a lane post to a moved task at `<SRC>`: never create a `<SRC>` row. Both Q2 variants are tested (redirect on: a box post and a browser post are refused with the destination, no row in `<SRC>` or `<DST>`, and the permalink answers the link; off: 404 and refused), so the case does not wait for Q2; the re-route is T7b's | post to the moved task id at `<SRC>` -> a new `<SRC>` topic appears |
| C9 | Counters equal a fresh count after the move, in both workspaces (`quota_counts` is left, not recomputed) | skip the recompute -> `<SRC>` counts still include the channel |
| C10 | A moved file read from `<SRC>` -> 404; from `<DST>` -> the bytes | serve from the LRU without the DB check -> 200 |
| C11 | Seats: a channel agent without a `<DST>` desk makes `plan` refuse, naming it; a desk whose P2b probe DM fails stops the move before P4, nothing changed; after P4 the seat rows are in `<DST>` and none in `<SRC>` | drop the check -> the agent cannot post after the move (spec 167 W3); skip the probe -> a dead `<DST>` desk passes P2b |
| C12 | Issue keys: the new issue carries the old key in its first event; a lane gets one note old -> new | skip the note -> the lane's next commit cites a dead key |
| C13 | No `<SRC>` audit row and no hub-wide row naming the channel; one `<DST>` audit row. The only `<SRC>` writes besides the deletes of the set are the named NULL / removal updates: M6b `moved_from_*`, M9 `ref_task_id`, the `channel_order` entry, the shared-item resolutions the owner chose (5.5), the topic-head recompute and the counters and change stamps (5.1); a diff of `<SRC>` before and after shows no other changed row | the default audit writer -> a `<SRC>` row names the channel; an extra `<SRC>` UPDATE -> the diff names it |
| C14 | Free-text scan (5.2) prints 0 for the channel id, name and every UUID, over text, jsonb, uuid and array columns; the exceptions are the fleet topic ids of 5.2, reported as known with their count, and the mentions of 5.4 under 5.2's conditions (`messages.body`, its copy in `messages.msg`, `workspace_doc_item.body`), listed by id and counted by class | plant the channel id in a `<SRC>` `workspace_events.message` -> 1; plant a moved task id in a staying post's `moved_from_task` (uuid) -> 1 |
| C15 | Caller: `DRY_RUN=0` without the owner's GO msg id is refused before any change | run as a lane agent -> refused, exit 3 |
| C16 | Copy: `<SRC>` row counts unchanged; `<DST>` ids are all new (task, msg, issue number, doc, doc item, doc node; rev log under the new doc id); a link inside a copied post points at the copied topic; a box gets a copied row only with the new ids, or not at all; a copied event with a guest makes 0 Google writes and 0 reminders (counted, with a control that a normal event makes 1 of each) | keep the old `workspace_doc_item.id` -> PK violation; keep the old UUIDs in the links -> the `<DST>` link resolves to nothing |
| C17 | Re-run after a crash in P5 resumes at the first undone step and finishes | re-run from P1 -> refused: the journal says P4 committed |
| C18 | Google Calendar: a moved event mapped in a `<SRC>` member's connection; after the move and one sync cycle of that connection, `<SRC>` has no event with that `source_key` and no map row, and the Google event is gone | skip the pre-P4 Google delete -> the In half imports it back into `<SRC>` |
| C19 | Hours: a job with plan rows and entries `job:<job>`, `t:<task>`, `ch:<CHANNEL>` moves whole; an entry inside an `approved` `<SRC>` period makes `plan` refuse, naming it (Q8 default) | drop the period check -> the approved period's stored total no longer matches its rows |
| C20 | Rows whose parent does not move: a channel invite for a kept email moves with its new `<DST>` workspace invite; a channel with an `embed_visitors` row makes `plan` refuse | insert the invite without its `<DST>` parent -> the FK refuses and P4 rolls back |
| C21 | Hours, Q5 stop: a channel member who is not a `<DST>` member and not added by the owner, with entries `t:<task>` and `ch:<CHANNEL>`, makes `plan` refuse with `hours: <member> 2 rows not coming to <DST> (Q5)`; the same member also inside an `approved` period prints the Q8 line too; adding the member clears only the Q5 line | drop the member check -> the move goes on and the member's rows are moved into a workspace they cannot read |
| C28 | Deliveries (c-001 650d3fff, bc05e46a): after P4 no agent row the addressee's box cannot verify stays queued. A queued or unacked delivery of a moved row is `expired` when the live `<DST>` pin of `from_box` is missing or differs from its `<SRC>` pin (`deliveries_expired`), or when `to_box` has no live `<DST>` pin, whoever wrote it (`deliveries_expired_no_pin`). It keeps its state when `to_box` is `box-wui`, when the row is a person's from `box-wui`, and when the sender's key is the one live in `<DST>` (its `<SRC>` pin revoked). Both counts are in the P4 step and the operator's move report. Limit: current pins only, so a row signed before its box re-keyed is refused by the box and lost, uncounted. | `TestApplyChannelMoveC28Deliveries`; control: the same rows with the expiry skipped stay queued |
| C22 | Pins (R1): a set row whose `from_box` is not pinned in `<DST>` makes `plan` refuse, naming the box; pinning it clears the line | drop the pin check -> `plan` passes a box with no pin in `<DST>`. C22 proves the pin exists, NOT that a row verifies against it (F10) |
| C23 | Desks (W2): a seat with no `<DST>` desk on its box makes `plan` refuse, naming the seat and the box | drop the desk check -> `plan` passes and the move stops only at P2b |
| C24 | Retention (R4): `plan` prints the Cloud SQL backup retention and the hub log bucket's retention, as the per-env service account; a value it cannot read prints as `not read: <reason>`, and the plan finishes with its usual exit code. Shell test with a stubbed `gcloud` | remove the read -> the line is missing |
| C25 | Box rule (W2, F14): a move whose `<SRC>` rule row on this box names a desk agent with no `<DST>` desk on this box makes `plan` and `MOVE_CMD=run` refuse, exit 3, naming the agent and the box; seating the desk clears it. A map that exists but cannot be read, or a malformed row, also refuses: unread is not "no row". Shell test on a sandboxed `SPOOL_ROOT` | drop the check -> `plan` passes and the move stops only at P2b, or goes on with a row whose agent has no `<DST>` desk |
| C26 | Box rule, what does not refuse and what is said: no row, no map, a row for another env, and a copy (no seat moves, section 7) each pass; every `plan` prints the box and the file it read and that other boxes are not read, and names the seats' other boxes; `plan` leaves the rule file byte-equal with no lock or temp file beside it. Shell test | refuse on an absent row -> a channel with no rule row can never move; drop the printed box -> a clean `plan` on the wrong box reads as a clean move |
| C27 | Seats: `plan` lists a seat that HAS its `<DST>` desk and it refuses nothing; a seat by invite and as a dedicated agent is one seat; the list is sorted; a removed seat and a seat of a staying channel are not listed; an old `announce` row on a default channel is no seat, on a created channel it is one; it marshals as `.seats[].agent` and `.seats[].box`, and as `[]` on a channel with no seat; `plan` has no mode (a copy lists them too) | list only the seats with no desk -> T9c's line never prints and T7 probes no desk; drop the announce predicate -> the default channel lists the old row; drop every announce row -> the created channel loses its seat; drop the json tags -> jq reads no seat; a mode field on the request -> the no-mode test fails until a copy's seats are decided |
| C29 | Who (8.5.2): the probe, the plan and the confirm answer 403 to a member of `<SRC>` who is not the operator workspace's biz owner, an admin included, and to no session at all | answer `Admin` too -> the admin gets a button whose GO the hub refuses |
| C30 | Targets: the probe lists only the person's own workspaces, never a hidden one they are not in | list every workspace -> a hidden slug in the answer |
| C31 | Blocked (8.5.4): no orchestrator seat in `<DST>`, and a file total over its quota, are both in `.blocked` before the confirm | plan's stops alone -> the confirm passes and the move stops only at P2 |
| C32 | The confirm's GO (8.5.5): the form and the answer it writes pass `channelMoveGo` unchanged, the answer's author is the session's person, the journal holds that msg id; a replay with another `dst` is refused | a form that does not name `<DST>` -> 403 `go_required` |
| C33 | The browser has no step: every route of 8.5.3 refuses a body with `step` or `mark`; a service-account token is refused on all of them, and a member session on the operator route | accept `step` -> a browser drives P4 |
| C34 | Pick-up: an open journal runs once, under the lock, with its GO and detail; a lease it does not hold runs nothing; a done journal is not read; a refusal is stored (8.5.6) and a re-run resumes | drop the lease check -> two boxes pick up one move and the second stops on the lock, read as stuck |
| C35 | Stuck (8.5.6): each row of the table, from a seeded journal; nothing says "Moved" before `done_at`; P4 done with P7 failed shows the proof names, in Chrome | show "Moved" on P4 done -> a move with traces reads as done |

All cases run on PostgreSQL (`PRE_PUSH_TIER=full`), with two test workspaces
on the hub's test database; none touches dev or prd. C24, C25 and C26 are the
exceptions: shell tests, no database.

## 10. Build rows

Each row is one small task; files named are where it lands.

| # | task | files |
|---|---|---|
| T1 | Move catalogue: one Go table of every `tenant_id` table with its class, the predicate that finds the set's rows and the parent rows it `Needs` in `<DST>` (5.1b); the gate C2 | `api/channelmove/catalogue.go`, `catalogue_test.go` |
| T2 | Migration: the `<DST>` journal table and the hub-wide redirect table (Q2), with RLS and the tenant isolation test | `csi-spl-rdb/src/sql/postgres/spool-hub/<head+1>_channel_move_journal.sql`, an entry in `api/store/rls_test.go` |
| T3 | Migration: `messages.copied_from` (nullable, catalog-only) for copies | `csi-spl-rdb/src/sql/postgres/spool-hub/<head+2>_messages_copied_from.sql` |
| T4 | Store: `PlanChannelMove` (read-only set, shared items, mentions) and its tests C1, C7 | `api/store/channel_move_plan.go` (+ `_postgres`, `_memory`, `_test`) |
| T4b | Store: `PlanChannelMove` checks each `from_box` is pinned in `<DST>` (R1) and refuses naming the missing desks (W2); tests C22, C23 | `api/store/channel_move_plan*.go` |
| T4d | Store: `ChannelMovePlan.Seats` lists every seat `plan` reads, sorted and once each, with a `<DST>` desk or without one; `MissingDesks` and `Refused` do not change. `plan` takes no mode, so it lists them for a copy too (section 7: a copy carries no seat; the caller decides, and T11 decides W2 for a copy). T7 wires the field into `.seats` and `ChannelMoveApplyRequest.Seats`; test C27 | `api/store/channel_move_plan*.go` |
| T5 | Store: `ApplyChannelMove` P4 frame: one transaction, insert-then-delete in catalogue order, counters and stamps, the messages family, hours, calendar and invites (5.1a, 5.1b) with the pre-P4 Google delete; tests C3a, C4, C5, C9, C18 store half, C19, C20, C21 | `api/store/channel_move_apply_postgres.go`, `_test.go` |
| T5b | Store: the issues part of P4 (renumber, events, discussions, `spec_sync_map`); test C3b | `api/store/channel_move_issues_postgres.go`, `_test.go` |
| T5c | Store: the Qto part of P4 (doc, item, node, ACL, rev log, re-placed in `<DST>`'s tree); test C3c | `api/store/channel_move_docs_postgres.go`, `_test.go` |
| T6 | Blob and Qto object copy/delete P3/P6, the shared-file rule; tests C6, C10 | `api/channelmove/objects.go`, `_test.go` |
| T7 | Hub operator endpoint (owner GO msg id required) and the moved-task refusal / redirect; tests C8, C15 | `api/hub/channel_move.go`, `_test.go`, `openapi.json`; the refusal lines in `api/hub/channels.go`, `ws.go`, `wui.go`, `view.go`; `api/store/channel_move_journal*.go` and one field in `memory.go`; `api/wire/topic_moved.go` |
| T7b | Box client: on the `topic_moved` refusal, send the post through the agent's `<DST>` desk key (W2, W3), the re-route of Q2. Every path: `spool send` by dial and by sidecar, a channel post, an answer, a queued post at flush. The desk is `<dir>/<tenant>/<box>`, `<dir>` being `$SPOOL_DESKS` or the desks dir of this spool root, read from its live `hub-run` as `spool_reply` does: a desk of another OS user is unreadable, so it counts as no desk and the post is refused. Nothing is remembered: each post asks `<SRC>` first, so on day 31 it gets the 404 and is refused and reported. A retry is the same envelope, which the hub stores once per `(tenant, msg_id)`. A prerequisite of the first prd move | `internal/hubclient/reroute.go`, `flush.go`, `hubclient.go`; `internal/action/link.go`, `action.go`; `cmd/spool/hub.go`; tests `reroute_test.go`, `moved_desk_test.go`, `internal/hub/channel_move_reroute_test.go` |
| T7c | Hub: C18's sync-cycle half: after the move and one In-half run on the member's connection, `<SRC>` has no event with that `source_key`, no map row, and the Google event is gone; control: skip the pre-P4 Google delete -> the In half imports it back. T13 and the first prd move wait for T7c; T5 does not | built (SPL-4609): `internal/hub/channel_move_gcal_test.go`, the move through the step endpoint and one sync cycle on fakegcal; the control drops the pre-P4 `events.delete` in the test's transport to the fake, so neither store nor hub has a door for it |
| T7d | Hub: a step reads Keep, KeepEmails, LeaveHours and RuleDoc from its detail, and MOVE_CALLER so P2 checks that seat; the plan request passes RuleDoc | built (SPL-4773): `api/hub/channel_move*.go`, `_test.go` (`channel_move_inputs.go`, `channel_move_inputs_test.go`) |
| T7g | The closer maps an old issue key to the new one while the redirect lives; after that an old key closes nothing | orc/scripts/issue-close-landed.py, its read path, its test. Built (SPL-4774): the agent issue op `moved` (`api/hub/issues_agent_moved.go`; `IssueMoves` in `api/store/channel_move_journal*.go`), `spl_icl_plan` in `orc/run/spl-issue-close-landed.func.sh`, case 22 of `orc/tests/spl-issue-close-landed.tst.sh`, `api/hub/issues_agent_moved_test.go`; M11 rewrites `fleet_lanes.origin_issue` too (`channel_move_issues_postgres.go`, C3b) |
| T7h | WUI: an old /t/<uuid> link at <SRC> takes the reader to the hub's moved_to; test it in a browser | built (SPL-4781): csi-spl-wui, its e2e test: `src/pages/t/[task_id].vue` follows only a `/t/<uuid>` link on its own origin or on a workspace host of this env (the apex or `<tenant>.<apex>`, never any other https host; R7 N1), once per navigation (the followed link carries `#moved`, and a page opened with it follows no further; R7 N4) (`src/utils/topic-moved.mjs`), `src/utils/spool-client.mjs` keeps `moved_to` on a 404 `topic_moved` only (R7 N2); `tests/e2e/topic-moved-link.test.mjs`, `tests/unit/topic-moved.test.mjs` |
| T8 | Proofs P7 and the free-text scan; tests C13, C14 | `api/channelmove/proof.go`, `_test.go` |
| T8b | P7 proves the objects of 5.3 (each moved object gone from <SRC>, present in <DST>) and prints the date each kept copy expires | built (SPL-4837): `api/hub/channel_move_steps.go` (`objectProofs`, `channelMoveKeptDates`), `api/channelmove/objects.go` (`Prove`); the detail field `retention_days` in `api/hub/channel_move_inputs.go`; P4's `done_at` read as `ChannelMoveStep.DoneAt` (`api/store/channel_move_journal.go`, `_postgres.go`); tests `objects_prove_test.go` (red control: an object planted back in <SRC>; an unreadable bucket holds), `api/hub/channel_move_p7_test.go`, `channel_move_inputs_test.go`. P7's `.kept` rows that end with a retention carry `expires` (a date, or `not read: <reason>`) and say it in `gone_by`; `.kept_until` is the last date (Q3). The shell sends `retention_days`: row T8c |
| T8c | The shell sends P7's `retention_days` in days and the report prints `kept_until`; tests for 36501 and 30.5 | built (SPL-4888): `orc/run/spl-channel-workspace-move.func.sh` (`_spl_cwm_p7_detail`): per kept copy of 5.6 that ends with a retention, from P4's `done_at` to the day its last copy made before P4 is gone for good. The four bucket copies from the cnf (045, 046, 052, 056: the lifecycle age, plus the noncurrent days of a versioned bucket, plus the soft delete rounded up to whole days); Cloud SQL's backup COUNT as days at its one backup a day (`startTime`), or the point-in-time log days when they are longer. A copy it cannot read (the hub logs until T13c; another unit, no daily window, a failed read) is not sent and prints `RETENTION <copy>: not read: <reason>`. P7 prints `KEPT <store> until <expires>` and `KEPT_UNTIL <kept_until>`. Tests: case 13 of `orc/tests/spl-channel-workspace-move.tst.sh`; `api/hub/channel_move_inputs_test.go` (36501 and 30.5 answer `bad_detail`; both already did, no defect) |
| T9 | Shell action `do_spl_channel_workspace_move` (plan, DRY_RUN, journal resume) and its test C17. With no `CHANNEL_MOVE_HUB_CMD` (now a test seam) it calls the T7 endpoint, `POST /v1/operator/channel-moves` on the env's hub as the per-env service account (`spl_hub_operator_call`), any code but 200 a refusal; C24 is proved through it too. It prints the plan's `.shared_files` as `PLAN` lines, P4's `.report`, and P7's `.report` and `.kept`; none of them refuses | built (SPL-4404 the action, SPL-4771 the wiring): `orc/run/spl-channel-workspace-move.func.sh`, `orc/tests/spl-channel-workspace-move.tst.sh` |
| T9b | The shell plan path reads and prints the Cloud SQL backup retention and the hub log bucket's retention (R4, 5.6): it only prints and refuses nothing; it prints every log bucket of the project, because the cnf names none; test C24 | `orc/run/spl-channel-workspace-move.func.sh`, `orc/tests/spl-channel-workspace-move.tst.sh` |
| T9c | The shell plan path does W2's F14 half, which the hub cannot read (T4b checks only `channel_subscriptions` and channel-scope `dedicated_agents`): it reads the channel's row in this box's `channel-rules.tsv` through `channel-rules.inc.sh` and refuses when that desk agent has no `<DST>` desk on this box, naming it and the box. No row is no refusal; a copy checks nothing (no seat moves, section 7); a row of another env is said, not checked. Read-only: P5 rewrites the file, not `plan`. A box reads only its own file, and `plan` prints which box and file it read. The other box is covered by the operator, not by this row: run `plan` on every box that works the channel, and `plan` names the boxes of the hub's seats other than its own; nothing makes `MOVE_CMD=run` wait for that; tests C25, C26 | `orc/run/spl-channel-workspace-move.func.sh`, `orc/tests/spl-channel-workspace-move.tst.sh` |
| T10 | Box steps: the P2b probe DMs, the P5 rule-row rewrite (no action writes `channel-rules.tsv` today, so it lives here), lane key notes; no re-seat (the seat rows move in P4); tests C11, C12 | built (SPL-4404, ticked by SPL-4771): `orc/features/spawn-agents/scripts/channel-workspace-move-box.sh`, its test |
| T11 | Copy mode: new UUIDs, link rewrite, `copied_from`; test C16 | `api/store/channel_copy_apply_postgres.go`, `_test.go` |
| T11b | `spl_issue_owner_go_from` refuses a copy and a reply that does not say whether it is one; `hub-tail` does not return `copied_from` today. Control: remove the check -> the test goes red. c-001 writes its brief after T11 lands; no prd copy until T11b lands | built (SPL-4838): `spl_issue_owner_go_copy` in `orc/run/spl-issue-create.func.sh` reads the go's messages row through `spl_lane_issue_hub_row` (as the env's service account, in the desk's tenant) once `hub-tail` found it in a linked discussion and its sender is a HUM-<n>; a copy, a row that does not say and a failed read are refused; the T11b cases of `orc/tests/desk-actions.tst.sh`. The check needs a database read: with `DRY_RUN=0`, once `hub-tail` found the go and its sender is a HUM-<n> (a non-human sender is refused first and reads nothing), `do_spl_db_message_show` reads its `messages` row in the `ENV` hub's Postgres. So `ENV` is `dev` or `prd` (`ENV=self` has no cnf and no database: the read is refused, so is the go), and, on the gcp provider (the default), the box needs gcloud, psql, python3 and jq on PATH, the env's service-account key `$HOME/.gcp/.csi/key-csi-spl-<env>.json` (or `SPL_SA_KEY`) that can read the hub DSN secret, and the Cloud SQL Auth Proxy (`cloud-sql-proxy` on PATH, else docker with the cnf proxy image); with `env.cloud.provider: none`, psql, python3, jq and `SPOOL_HUB_DB_DSN`. Any of them missing: the read fails and nothing is filed (SPL-4871) |
| T12 | Docs: operator page (how to plan, run and read the kept list) | `csi-spl-doc/doc/md/channel-workspace-move.md` |
| T13 | Dev rehearsal, the gate before the first prd run: on dev, `plan` then `DRY_RUN=0` of a seeded channel between two dev test workspaces with the owner's GO msg id (C15), P7 prints 0, the journal read back; it also records R3's T5 timing on the 3,650-post seeded channel (12), runs P4 under the real runtime role with its real grants, and checks TEMP there; T11b lands before the first prd copy, no prd copy until then; measure P4 and P7 on the seeded 3,650-post channel against the box's 30 s client cap (`curl -m 30`, `spl_hub_operator_call`; the hub's Cloud Run request timeout is 600 s); over 30 s means a bug row before the first prd move, and SPL-5067 is that row: every channel-move call now waits the cnf's `hub.cloud_run.timeout_seconds` (`SPL_HUB_OP_MAX_TIME`); the record of the run | `csi-spl-doc/specs/169-channel-workspace-move/dev-rehearsal.md` |
| T13b | P7's free-text scan and Q4's mentions: T13 measured `proof scan messages.body 1` on one staying post that links a moved topic | built (SPL-5010): `api/channelmove/mentions.go` (`ReadMentions`), `api/hub/channel_move_steps.go` (`p7`), `api/store/rls.go` (`asOperatorSnapshot`), `orc/run/spl-channel-workspace-move.func.sh` (`MENTIONS`, `MENTION` lines); tests `api/channelmove/proof_test.go` (`TestMentionsPostgres`), `api/hub/channel_move_p7_test.go`, `api/store/channel_move_journal_test.go`. Not re-run on dev: a second T13 needs the owner's new GO |
| T13c | `KEPT_UNTIL` printed `not read: no date for hub logs` (T13), so Q3's last date never printed | built (SPL-5010): cnf `hub.log_bucket`; `_spl_cwm_retention_log_days` sends that bucket's days only after it reads a line of the hub's service back from it (dev read 2026-11-07: two sinks, `_Default` 30 days, the hub's `requests` and `stderr` lines there; prd not read), else `not read: <why>`; case 13 of `orc/tests/spl-channel-workspace-move.tst.sh` |
| T14 | Hub: the probe and the plan for a member session (8.5.2, 8.5.3, 8.5.4): owner test, the person's targets, the plan with the orchestrator seat and the quota added as `.blocked`. Reads only. Tests C29, C30, C31 | `api/hub/channel_move_browser.go`, `_test.go`, `openapi.json` |
| T15 | Hub: the confirm (8.5.5 items 1, 2): form and answer in a new topic of the operator workspace, then P1, the detail kept for P2. Tests C32, C33 | `api/hub/channel_move_confirm.go`, `_test.go`, `api/hub/channel_move_steps.go`, `openapi.json` |
| T16 | Shell: `do_spl_channel_move_pickup` and the operator op `open` (8.5.5 item 3); `do_spl_channel_workspace_move` sends the journal's `detail` at P1 and P2. Test C34 | `orc/run/spl-channel-move-pickup.func.sh`, `orc/run/spl-channel-workspace-move.func.sh`, their tests; the op in `api/hub/channel_move.go` |
| T17 | Hub: the stored refusal and `GET /v1/channel-moves/{move_id}`, the status line in the GO's topic, the `#alerts` line (8.5.6). Test C35's store and hub half | `api/hub/channel_move_status.go`, `_test.go`, `api/store/channel_move_journal*.go` |
| T18 | WUI: the menu item and its probe (8.5.1, 8.5.2), keys in every locale | `src/utils/sidebar-row-menu.mjs`, `src/components/SidebarRowMenu.vue`, `ChannelSidebar.vue`, `tests/unit/`, `i18n/locales/*` |
| T19 | WUI: the dialog's three screens and the stuck table (8.5.4, 8.5.6), lazy, proven in Chrome on phone and desktop. Test C35's browser half | `src/components/ChannelWorkspaceMoveDialog.vue`, `tests/e2e/channel-workspace-move.test.mjs`, `i18n/locales/*`, a help page |
| T20 | agy's final language review of T18's and T19's strings in every locale, before they ship (the language rule) | `i18n/locales/*` |

Note under row T11 (T8c, R7 c-666 N1): P7's `left in <SRC>` proof is a move's only; a copy (T11) runs only `missing in <DST>`.

Order: T1 first (it is the inventory in code); T2 before T5 (the journal);
T4 before T5; T4 before T4b; T4b before T4d; T4d before T7's seat wiring; T5 before T5b and T5c; T3 before T11; T6 and T8
before T7; T7 before T9; T9, T10, T7, T7c and T7d before T13; T5 before T7c; T4b, T4d, T9b and T9c before T13. T13b before T13's second run, and that before T14; T14 before T15 and T18; T15 and
T17 before T16 and T19; T18 and T19 before T20.

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
| L10 | T4b (queued after T4 lands) |
| L11 | T9b |
| L12 | T9c |
| L13 | T4d |
| L13b | T13b, T13c (claude) |
| L14 | T14 (claude) |
| L15 | T15 (claude) |
| L16 | T16 (claude) |
| L17 | T17 (claude) |
| L18 | T18 (claude, then agy reviews its strings in T20) |
| L19 | T19 (claude, then agy reviews its strings in T20) |
| L20 | T20 (agy) |

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
| Q2 | A, 30 days of redirect, re-route and old issue key map, then 404 | `333aea7b` (poll `502a793f`) | W3-W5, C8 with the redirect on; T2's redirect table expires rows after 30 days. T7 refuses with the destination (to a `<DST>` member only, W5; token `topic_moved`; `wire.MovedDetail` gives the workspace and the link, never the channel); the re-route itself is the box client's, T7b, because a box key is live in one workspace only (rdb 0154). Expired rows refuse and stay until a sweep is decided; deleting them reopens C8's red, so a sweep needs the owner's answer first |
| Q3 | A, keep until they expire | `d2c97186` | 5.6 as written; P7 prints the last expiry date |
| Q4 | A, leave them and list them | `d2c97186` | 5.4: `plan` lists, nothing edited |
| Q5 | A, they lose access; the move lists them and the owner adds whom he wants | `0c58c916` (poll `dfa0234a`) | W1, 5.1 (`channel_humans`, `channel_invites`, `channel_subscriptions`, `read_marks`), 5.1a hours, 5.1b invites, calendar guests: of the channel's people who are not `<DST>` members, only those the owner adds to `<DST>` come along; existing `<DST>` members keep their access (W1); the move adds no one by itself; C21 (the lead's hours stop, 5.1a) |
| Q6 | A, stop and list | `d2c97186` | 5.5, C7: `plan` refuses on a shared item |
| Q7 | J (`f6f94c97`): the csitea channel named like `ws-hidden-17`; destination (`e4cc2662`): `ws-hidden-17` | `f6f94c97` and `e4cc2662` (poll `c5dc7cea`) | the first move: `<SRC>` = csitea, `<CHANNEL>` = the csitea channel named like `ws-hidden-17`, `<DST>` = `ws-hidden-17` (the slug stays in the overlay); the first prd run waits only for the build (10.1 critical path, T13 the dev rehearsal last), no longer for a name |
| Q8 | A, stop and list | `85eb389c` (poll `53f98bf8`) | 5.1a, C19 |
| Q9 | A, that click is your Go: the hub records it and a box starts the move | `a271ca2c` (poll `9ac73227`, t1 `035cb09e`) | 8.5.5: the dialog's confirm writes the form and the owner's `Answer: GO` in the operator workspace, `channelMoveGo` checks it (C32), a box picks the move up (T16); no second form, T15 |
| Q10 | A, only workspaces you are a member of | `a271ca2c` (poll `9ac73227`) | 8.5.2: the targets are the person's own workspaces; a hidden workspace the person is not in is never listed (W5), T14 |
| Q11 | A, only you, the owner of the operator workspace | `a271ca2c` (poll `9ac73227`) | 8.5.2: the item shows only to the biz owner of the operator workspace (`channelMoveOwner`), on any channel of a workspace the owner is in; the GO rule of 8.1 does not change, T14 |

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

### 11.3 The menu entry's questions (8.5), as asked

No question is open for 8.5: the owner answered A to Q9, Q10 and Q11 on 2026-11-08
(msg a271ca2c, poll 9ac73227; 11.1). As asked, by c-002 in t1 035cb09e on 2026-11-07:

```poll
Q9 "Move to workspace": what should your click on the dialog's Confirm do? I recommend A.
(A) That click is your Go: the hub records it in the operator workspace and a box starts the move
(B) It opens a separate form in the operator workspace, and you click Go there too
Q10 Which workspaces can you pick as the target? I recommend A.
(A) Only workspaces you are a member of
(B) Every workspace on this hub
Q11 Who sees "Move to workspace"? I recommend A.
(A) Only you, the owner of the operator workspace, on any channel of a workspace you are in
(B) Also each workspace's own owner, for that workspace's channels (a customer could then move their own channels; the Go rule has to change first)
```

- Q9: A keeps the one GO check (C32) and asks for one click, the owner's own rule (how-to-post
  section 7). B needs no new form-writing code, but asks twice for one decision.
- Q10: B would list hidden workspaces in a dialog, and could move a channel somewhere the owner
  cannot read it.
- Q11: B is a change to the rule of 8.1, "`DRY_RUN=0` needs the owner", so it is a decision, not a
  detail of this row.

## 12. Risks and open checks

| # | risk / open check | what settles it |
|---|---|---|
| R1 | The pins (`pins`, per workspace) hold the box keys that signed and encrypted the posts (F10). A row moved to a workspace can be stored but not verified unless its box's pin there is the key that signed it, which is normally not so (F10), pinned or not. | `plan` checks each `from_box` is pinned in `<DST>` and refuses, naming the missing ones (T4b); that does not make its rows verify. The hub withholds them from a new seat and counts them (T4c) |
| R2 | Encrypted posts (`enc`, `for`) are readable only by the boxes named in `for`; a move does not change that. | stated in the operator page (T12) |
| R3 | A move of the largest channel inside one transaction locks its rows for the length of P4. | measured by T13 on dev, n=1: P4 4.42 s on 3,650 posts, under the 30 s client cap ([dev-rehearsal.md](dev-rehearsal.md)). P7 about 9 s, with 5 messages in `<SRC>`: its scan follows the size of `<SRC>` and the hub, so P7 on a populated `<SRC>` is not measured. SPL-5067 (2026-11-08, local Postgres, a `pg_sleep` trigger as the slow step, client cap 1 s, 12 hang-ups): a client that leaves rolls P4 back, in a statement (6 of 6) and inside COMMIT (6 of 6), so a P4 over the cap could never finish; no commit after a hang-up was seen, which n=12 does not exclude. The channel-move calls now wait the cnf's `hub.cloud_run.timeout_seconds`, the request's limit; one statement keeps its own ceiling (300 s in P4's apply, the copy's apply and P7's read, the runtime login's 30 s elsewhere). The shell skips a step the journal has done, and the hub refuses P4 once done (409) |
| R4 | Not checked here: Cloud SQL backup retention and the hub log bucket's retention (5.6). | `plan` reads both and prints them (T9b) |
| R5 | Spec 167 moves a channel's work between boxes; a move between workspaces that is also a move between boxes runs 167 first, then this. | operator page (T12) |
| R6 | The free-text scan (5.2) proves absence of exact strings only. | stated; not claimed further |
| R7 | Q4 leaves mentions in place, and the free-text scan (5.2) must print 0 for every task UUID, with the fleet topic ids as its only known hits (`channelMoveFleetTopics`): so a channel stops at P7 when a row left in `<SRC>`, or in a hub-wide table (one with no `tenant_id`, read unfiltered), holds a full task or msg UUID of the set, or the channel's id or name as a whole word, in a column the scan reads; the fleet topic ids are excepted. Measured by T13, n=1, one full link: `proof scan messages.body 1`. | row T13b |
| R8 | The GO's form names `<SRC>/<CHANNEL>` and lives in the operator workspace (8.1). When `<SRC>` IS the operator workspace, the form is a trace the scan reads, and it cannot be deleted without losing the GO's record. Read from the code; not measured: T13's `<SRC>` is not the operator workspace. | Until a row decides it, T14 refuses `<SRC>` = the operator workspace, naming why |
