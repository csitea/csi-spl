# 099 Topic head: one stored row per topic, so a topic list stops walking messages

Version v0.1 (2026-10-06). Draft, doc only. Owner order: t1 ea9dc09a, msg
436e8f6e ("yes" to "do you want a written spec and a test set first?").
Source row: ap-07 of
`csi-spl-doc/doc/md/refactor-round-api-perf-plan-2026-10-06.md` (section 4,
section 0.3). ap-09 (the subject through the covering index) folds into this
spec (section 3.4). Build tasks: `tasks.md`. Nothing here is built before the
owner answers section 10 ("as proposed" is enough).

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`api/` = `csi-spl-api/src/go/spool-hub-api/`, `store/` =
`api/internal/store/`, `orc/` = `csi-spl-orc/src/bash/run/`.

## 1. Answer

1. **Today every topic list walks messages.** `viewTopicsSQL`
   (`store/view_postgres.go:193`) walks the tenant's messages newest first, one
   recursive step per listed topic, and per step runs four or more probes
   (latest line, parties, read door, roots, archived). Then `summary()`
   (`:354`) aggregates every line of each listed topic for its count, kinds,
   parties and subject. prd: 2 301 messages visited for 51 DM topics (n=1
   plan); topic lists p50 150..350 ms, up to 1.5 s (n=446 in 8.4 h); walks
   239.9 s/day of DB time (10.5 %).
2. **The head keeps that summary stored, per topic and per part** (a part is
   one channel of the topic, or one DM pair of it). A list then reads about
   one head row per listed topic plus its parts, and never the messages.
3. **One writer: triggers on `messages`** (section 4.1), the same choice and
   reasoning as rdb 0103's change stamps: every Go writer, a later writer, a
   cascade and a hand-run psql are covered without anyone remembering it.
4. **Expiry needs no write.** A line stops being listed when `expires_at`
   passes, but the sweep deletes it only every 10 min (`cmd/spool/hub.go:54`).
   So each head carries `valid_until` (its earliest line expiry), and a list
   reads a head whose `valid_until <= now` the old exact way, per topic
   (section 5.3). The answer stays equal to today's to the second.
5. **The proof is the test set** (section 7): an oracle that compares the head
   read with today's walk for every case of section 6, on Postgres; a random
   sequence test; a concurrency test; the RLS test; and the perf proof with
   ap-00's `do_spl_db_hot_measure` n=20 and 24 h route p50/p95.
6. **The rollout is reversible at every step** (section 8): DDL first, then
   backfill and verify, then the hub in shadow (it serves today's walk and
   compares), then the read switch. A flag turns the read off again in one
   revision.

## 2. What the list answers today (the contract the head must keep)

`TopicRow` (`store/view.go:65`) per listed topic, from `viewTopicsSQL`. The
rules below are read from the code, and each one is a case in the oracle.

| field / filter | today's rule | what the head needs |
|---|---|---|
| order, cursor | the topic's latest **unexpired line under the message filters** (channel, DM), **not** under the read door; `(received_at DESC, task_id::text DESC)`; `before=` compares the same pair | `last_at`, `last_msg_id` per part and per topic; a DM-only latest per topic |
| `LastAt` | that same latest line | as above |
| `Count`, `Kinds` | every unexpired line passing the message filters **and the door per line** (`aggDoor`); the hub only counts kinds into a map (`hub/view.go:856`), so order does not matter | `n` and `kinds {kind: n}` per part |
| `Parties` | distinct `from_id@from_box` and `to_id@to_box` of the same lines | `parties {party: n}` per part (a count, so a removal knows when a party leaves) |
| `Channel`, `Parent`, `FirstAt`, `FirstMsg` | the first such line by `(received_at, msg_id::text)`; `FirstMsg` = `subjectSQL` of it | `first_at`, `first_msg_id`, `first_parent`, `first_subject` per part |
| read door (`Reader`) | listed if any line of the topic (message filters, no door) is in a public channel, a channel the reader is in, or a DM the reader is an end of | per part: its channel, or its DM pair |
| `Agent` (+`AgentBox`), `Viewer` | some line under the message filters (**no door**) is from or to that id (on that box) | parties per part |
| `Roots`, `Parent` | the first line under the message filters (**no door**) has no parent / has that parent | first per part |
| `NoIssues` | no `issues` row for the topic | unchanged: the cheap probe stays |
| archived (`archivedTopicHideSQL`) | hidden if the card `msg_id = task_id` is archived, or any row of the topic is archived and the topic is not the lobby; **no expiry check** on the archived row | `card_archived`, `archived_rows` per topic |
| `TaskIDs` (since= delta) | each listed topic read on its own index range | unchanged in phase 1 (Q5) |

Three of these rules differ in a way a careless head would get wrong, and
each has its own oracle case: the order key ignores the door, `Count` applies
the door per line, and an archived row hides its topic even after it expired.

## 3. The head

Migration `rdb/0138_topic_heads.sql` (number provisional: ap-01a takes 0136
and ap-04 0137; the next free number at rebase). Forward-only.

### 3.1 `topic_heads`: one row per topic

| column | type | meaning |
|---|---|---|
| `tenant_id` | text NOT NULL, FK `tenants` ON DELETE CASCADE | |
| `task_id` | uuid NOT NULL | the topic |
| `last_at`, `last_msg_id` | timestamptz, uuid NOT NULL | the latest line of the topic (any part) |
| `dm_last_at`, `dm_last_msg_id` | timestamptz, uuid NULL | the latest DM line; NULL when the topic has no DM part |
| `valid_until` | timestamptz NOT NULL | the earliest `expires_at` of any line of the topic |
| `card_archived` | boolean NOT NULL | the message `msg_id = task_id` is archived |
| `archived_rows` | integer NOT NULL | rows of the topic with `archived_at` set (expired or not) |
| `rev` | bigint NOT NULL | the change stamp: +1 on every write of this head or its parts |
| `changed_at` | timestamptz NOT NULL | DB clock at the last write |

PK `(tenant_id, task_id)`. Indexes:
`(tenant_id, last_at DESC, task_id DESC)` (the all-topics list),
`(tenant_id, dm_last_at DESC, task_id DESC) WHERE dm_last_at IS NOT NULL`
(the DM list), `(tenant_id, valid_until)` (the due set, section 5.3).

### 3.2 `topic_head_parts`: one row per channel or DM pair of a topic

| column | type | meaning |
|---|---|---|
| `tenant_id`, `task_id` | as above, FK `(tenant_id, task_id)` to `topic_heads` ON DELETE CASCADE | |
| `part` | text NOT NULL | `c:<channel>` or `d:<lesser id> <greater id>` (the DM's two ends, ids only, as the door compares them) |
| `channel` | text NULL | NULL = DM part |
| `n` | integer NOT NULL | lines |
| `kinds` | jsonb NOT NULL | `{kind: n}` |
| `parties` | jsonb NOT NULL | `{"id@box": n}` |
| `first_at`, `first_msg_id`, `first_parent`, `first_subject` | timestamptz, uuid, uuid NULL, jsonb | the first line: time, id, `parent_task_id`, `topic_head_subject(msg)` |
| `last_at`, `last_msg_id` | timestamptz, uuid | the latest line of the part |
| `valid_until` | timestamptz | the earliest expiry of the part |
| `rev` | bigint | as above |

PK `(tenant_id, task_id, part)`. Index
`(tenant_id, channel, last_at DESC, task_id DESC) WHERE channel IS NOT NULL`
(the channel list).

A head counts the rows that **exist**, expired or not. It is exact while
`valid_until > now`; after that the read does not trust it (section 5.3) until
the sweep's delete rebuilds it.

### 3.3 RLS and roles

- RLS in the 0021 fail-closed NULLIF shape on both tables, exactly as
  `rdb/0127_quota_counts.sql`: `ENABLE` + `FORCE ROW LEVEL SECURITY`, policy
  `tenant_scope` `USING / WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))`,
  policy `operator_scope` on `app.rls_scope = 'operator'` (the sweep and the
  backfill write as operator).
- `store/rls_failclosed_test.go` finds both tables by their `tenant_id`
  column, so the catalogue gate covers them with no edit; T002 adds the
  isolation cases of section 7.4.
- Owner / runtime split: the migration runs as the owner role (`spool_hub`).
  The runtime role (`spool_hub_rt`) gets DML on the tables and EXECUTE on the
  functions from the default privileges of
  `spool-hub-roles/runtime-grants.sql`; no grant line is added. The trigger
  functions are `SECURITY INVOKER`: they write under the writer's own tenant
  scope, so WITH CHECK still holds a writer to its own tenant.
- No `tenant_change_stamps` trigger on the head tables: every head write is
  caused by a `messages` write in the same transaction, which 0103 already
  bumps.

### 3.4 The subject (ap-09 folded in)

`topic_head_subject(msg jsonb) RETURNS jsonb IMMUTABLE` is today's
`subjectSQL` (`store/view_postgres.go:375`) as a SQL function, so the subject
is cut once at write time and read as one column. ap-09 (pick the subject
row through the covering index) then has nothing left to win and is dropped
(Q7). The Go constant and the function must stay equal: T002's test runs both
on the `view_topics_subject_test.go` bodies plus random unicode bodies
(n >= 2 000).

## 4. How it stays correct

### 4.1 One writer: triggers, not the store path

| | triggers on `messages` (proposed) | a call in each Go writer |
|---|---|---|
| coverage | every writer: insert, edit, kind, move x2, merge, unmerge, promote, demote, archive, delete message, delete topic, merge messages, channel delete (`channels_postgres.go:114`), the sweep purge (`postgres.go:622`), a tenant cascade, psql | 14 call sites today; the 15th is forgotten |
| testability | tested on Postgres only (the memory store keeps its own live summary) | testable per writer |
| insert cost | one upsert of a head row and a part row in the insert transaction | the same |
| precedent | rdb 0103 change stamps ("a writer added later is covered") | none |
| risk | a slow trigger slows every write; a bug breaks writes, not only reads | a missed writer silently corrupts the head |

Proposed (Q1): **triggers**. The insert cost is gated (section 7.5).

### 4.2 The functions

- `topic_head_add(row)`: the insert path, incremental. Upsert the topic row
  (`last_*`, `dm_last_*` by `GREATEST` on `(received_at, msg_id)`,
  `valid_until` by `LEAST`, `rev + 1`) and the part row (`n + 1`,
  `kinds[kind] + 1`, `parties[from] + 1`, `parties[to] + 1`, `first_*` /
  `last_*` by tuple compare). On the topic's first insert it also probes the
  card (`EXISTS` an archived row with `msg_id = task_id`), so a topic created
  after its card was archived starts hidden.
- `topic_head_rebuild(tenant, task)`: lock the topic (4.4), then in a NEW
  statement recompute the topic row and all its parts from `messages` on
  `messages_task_received`; delete parts that no longer have a row, and the
  head when the topic has none.
- Triggers (immediate, AFTER):
  - `topic_head_ins` AFTER INSERT FOR EACH ROW -> `topic_head_add`.
  - `topic_head_upd` AFTER UPDATE FOR EACH STATEMENT, REFERENCING OLD TABLE
    and NEW TABLE: join old to new on `msg_id`, keep only rows where a head
    column changed (`task_id`, `channel`, `kind`, `from_*`, `to_*`,
    `received_at`, `expires_at`, `archived_at`, `parent_task_id`, `msg`),
    collect the affected topics, rebuild each once, in `(tenant_id, task_id)`
    order. An update that touches no head column (the search_sig backfill,
    a claim) rebuilds nothing.
  - `topic_head_del` AFTER DELETE FOR EACH STATEMENT, REFERENCING OLD TABLE:
    the same, for the old rows.
  - Three triggers, not one: Postgres refuses transition tables on a trigger
    with more than one event (postgres:16-alpine, 2026-10-06: `ERROR:
    transition tables cannot be specified for triggers with more than one
    event`, n=1).
- Affected topics of a changed row: its old and new `task_id`; plus, when
  `archived_at` changed or the row is deleted, the topic whose `task_id` is
  its `msg_id` (the card rule).

### 4.3 Every event

| event | writer today | head effect | oracle case |
|---|---|---|---|
| insert, channel line | `insertMessageSQL` (`postgres.go:375`) | add: topic + `c:<ch>` part | E01 |
| insert, DM line | same | add: topic + `d:<a> <b>` part, `dm_last_*` | E02 |
| insert into a topic whose card is archived | same | add, `card_archived` from the probe | E03 |
| edit (body) | `applyEditTx` (`message_edit_postgres.go:129`) | rebuild (the subject changes only when the line is its part's first) | E04 first line, E05 other line |
| kind change | `SetKind` (`message_kind_postgres.go:39`) | rebuild | E06 |
| move one line to another channel / topic | `MoveMessage` (`message_move_postgres.go:154`) | rebuild old and new topic | E07, E08 |
| move a whole topic | `MoveTopic` (`:71`) | rebuild | E09 |
| merge topic A into B, unmerge | `MergeTopic`, `UnmergeTopic` (`topic_merge_postgres.go`) | rebuild A and B (A's head is deleted when empty) | E10, E11 |
| promote a line to a topic, demote | `PromoteMessage`, `DemoteTopic` | rebuild both | E12 |
| archive / unarchive the card | `SetArchived` (`topic_archive_postgres.go:75`) | rebuild the card's own topic and the topic `task_id = msg_id` | E13 |
| archive a reply in the topic; the lobby | same | `archived_rows`; the lobby exception is applied at read | E14, E15 |
| delete a line, merge two lines | `DeleteMessage`, `MergeMessages` | rebuild | E16, E17 |
| delete a topic | `DeleteTopic` (`:161`) | head deleted | E18 |
| delete a channel | `channels_postgres.go:114` | rebuild every topic with a row there | E19 |
| a line expires (no write) | none | none: the read treats the head as due (5.3) | E20 latest line, E21 first line (subject moves), E22 the only line, E23 an archived row expires |
| sweep purge | `Sweep` (`postgres.go:622`, 500 rows a chunk, operator) | rebuild, head valid again | E24 |
| tenant deleted | cascade | heads cascade | E25 |
| a topic with a channel part and a DM part (the door case of `mixed_topic_door_test.go`) | any | two parts | E26 |
| one topic, two DM pairs | any | two `d:` parts | E27 |
| equal `received_at` ties across topics | any | tie-break `task_id::text` | E28 |

### 4.4 Concurrency

- **Two inserts in one topic.** Each upserts the same head and part rows;
  `INSERT .. ON CONFLICT DO UPDATE` takes the row lock, so the second waits for
  the first to commit and then increments the committed value. Both lines are
  counted once (test C1).
- **An insert against a rebuild.** The rebuild must not compute from a
  snapshot that misses an insert that commits before the rebuild writes. So
  `topic_head_rebuild` first locks the head row (`SELECT .. FOR UPDATE`, or
  `pg_advisory_xact_lock` on the topic when no head row exists yet), and only
  then, in a new statement of the VOLATILE plpgsql function and so a new
  READ COMMITTED snapshot, reads `messages`. An insert that already holds the
  lock is waited for and then seen; an insert that comes later waits for the
  rebuild and increments its result (tests C2, C3).
- **Two topics in one transaction** (merge, move, promote): one statement locks
  its topics in `(tenant_id, task_id)` order. A MULTI-statement transaction
  that touches A then B, against another that touches B then A, can still
  deadlock on the `messages` row locks it holds between statements; Postgres
  detects it (`deadlock_timeout`) and aborts one with `40P01`. Those writers
  are human-initiated and rare; T004 makes the move/merge store calls retry
  once on `40P01` (test C4).
- Lock time: the head lock lives until the writer commits. An insert
  transaction is short; a 500-row sweep chunk holds up to 500 head locks
  for one chunk.

## 5. The read

### 5.1 Switch

`SPOOL_HUB_TOPIC_HEADS = off | shadow | on` (default `off`), and the store
reads heads only when it also finds the table (a probe, like `hasSearchSig`).

- `off`: today's walk.
- `shadow`: serve today's walk; for 1 request in `SPOOL_HUB_TOPIC_HEADS_SAMPLE`
  (default 10) also run the head read and compare the rows' md5; log
  `topic_head_mismatch` with the tenant, the query shape and the task ids,
  never a body.
- `on`: serve the head read.

### 5.2 The statement, per shape

`viewTopicsHeadSQL(tenant, q)` beside `viewTopicsSQL`, same `TopicRow` columns,
same args order rule, same `pgScopeTenantNoJIT` batch.

- **Walk key.** Channel list: `topic_head_parts` on its channel index. DM
  list: `topic_heads` on `dm_last_at`. All topics: `topic_heads` on
  `last_at`. Each is ONE row per topic, so the walk is an ordered index scan
  with filters and `LIMIT`, no recursive "is this its latest line" step.
- **Filters on the walked head:** `valid_until > now`; not archived
  (`NOT card_archived AND (archived_rows = 0 OR task_id::text = lobby)`);
  read door = an `EXISTS` over its parts (channel in public or reader's
  channels, or a `d:` part with the reader as an end); `Agent`/`Viewer` = an
  `EXISTS` over parts in the message filters whose `parties` has the key
  (`id@box`, or any `id@` key); `Roots`/`Parent` on the first part by
  `(first_at, first_msg_id::text)` in the message filters; `NoIssues` as
  today; the `before=` cursor on the walk key.
- **Summary:** over the parts in the message filters AND the door: `n` summed,
  `kinds` summed per key, `parties` the keys with `n > 0`, sorted,
  `first_*` of the first such part. No `messages` row is read.

### 5.3 Due heads (a line expired, not yet swept)

A head with `valid_until <= now` is "due". The statement takes the due heads
of the tenant from `(tenant_id, valid_until)` and reads each the exact way
today's `listed()` already does for `TaskIDs` (each topic on its own
`messages_task_received` range, every filter, the full `summary()`), then
merges them with the head rows by the walk key and applies the `LIMIT`. The
due set is the topics with a line that expired since the last sweep, so it is
small (T009 counts it on prd before the switch). The answer is equal to
today's at every second (oracle cases E20..E23); a due head costs today's read
for that one topic.

### 5.4 What is not switched

`ViewTopic` (one topic's lines), `ViewTopicsMessages` (`per_topic=`, the
Flow list's lines), the memory store, and `TaskIDs` deltas in phase 1 (Q5).
The Flow list's walk is `viewTopicsSQL` (also through
`ViewTopicsUnlessClone`, `store/clones.go:207`), so it gains; its per-topic
lines do not change.

## 6. Cases

Section 4.3's E01..E28, each run over the query shapes of `topicQueries()`
(`store/view_topics_test.go:152`): all, `channel=`, `dm=true`, `peer=` with
and without a box, `roots`, `parent=`, `NoIssues`, a reader in no channel, a
reader in a created channel, a NULL reader (door off), and every `before=`
page.

## 7. The test set (the core deliverable)

All on Postgres (`SPOOL_TEST_PG_DSN`; skipped without it, as
`view_topics_test.go` is), under `PRE_PUSH_TIER=full`.

### 7.1 The oracle: head read == today's walk

`store/topic_head_oracle_test.go`, `TestTopicHeadMatchesWalk`.

- Per case E01..E28: seed a tenant (`seedTopics` plus the case's own rows),
  apply the case's writes through the store's own methods (never raw SQL, so
  the triggers see what prd sees), then for every shape of section 6 and
  every page compare three answers with `sameRows`: today's `viewTopicsSQL`,
  the head read, and the pre-027 `oracleTopicsSQL`.
- Expiry cases set `Now` past the line's `expires_at` without a sweep, then
  run the sweep and compare again (E24).
- `topic_head_diff(tenant)` (a SQL function, T002) returns every topic whose
  stored head differs from a rebuild; each case also asserts it returns 0 rows.
- CONTROLS (the test must be able to fail): corrupt one head row by hand
  (`n + 1`, then a dropped party, then a wrong `valid_until`) and assert the
  oracle reports the mismatch; disable `topic_head_upd` and assert E07 fails.

### 7.2 Random sequences

`TestTopicHeadRandomSequences`: 20 seeds x 500 operations drawn from {insert
channel line, insert DM line, edit, kind, move line, move topic, merge,
unmerge, promote, demote, archive, unarchive, delete line, delete topic,
delete channel, advance the clock past one line's expiry, sweep}, over 6
channels, 4 agents on 2 boxes, 2 humans, a lobby. After every operation
`topic_head_diff` is empty; every 25 operations the oracle of 7.1 holds for
every shape. The seed is printed on failure, and `TOPIC_HEAD_SEED` /
`TOPIC_HEAD_OPS` replay one prefix. `SPOOL_TEST_LONG=1` runs 200 seeds.

### 7.3 Concurrency

| id | test | passes when |
|---|---|---|
| C1 | 2 goroutines x 200 inserts into one topic | `n = 400`, diff empty |
| C2 | inserts into A while A's lines are moved to another channel | diff empty, no lost line |
| C3 | inserts into A and B while A merges into B | diff empty |
| C4 | merge A->B and B->A at once, 50 rounds | every call ends ok, or `40P01` and its retry ok; diff empty |
| C5 | a sweep purge chunk against inserts into the swept topics | diff empty |

### 7.4 RLS and roles

In `store/topic_head_rls_test.go` and the catalogue of
`rls_failclosed_test.go`: tenant t2's scope reads 0 head and 0 part rows of
t1; a write of a t1 row under t2's scope fails WITH CHECK; an empty
`app.tenant_id` reads 0 rows (fail closed); the operator scope reads both;
an insert through the runtime role (`spool_hub_rt`) writes its head (the
default privileges reached the new tables and functions); a tenant delete
leaves no head row.

### 7.5 Write cost

`TestTopicHeadInsertCost` (`SPOOL_TEST_PERF=1`): one message insert with and
without the triggers, n=20 each, at 200k messages: the added p95 is under
**5 ms** (the plan's gate), and a 500-row sweep chunk's added time is printed.

### 7.6 Perf proof on prd (before / after, through c-001)

From `csi-spl-orc`, as the env SA:

- Per call, the gating number, twice before and twice after, 10 min apart:
  `ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20 MEASURE_ONLY=walk_dm ./run -a do_spl_db_hot_measure`,
  and the same with `MEASURE_ONLY=walk_all`, after ap-00 has made the action
  run the builders' text. T008 adds `walk_dm_head` and `walk_all_head`
  statements printed by the head builder.
- Per route, reported (the 24 h before the switch, and the 24 h after it):
  `ENV=prd ROUTE_HOURS=24 ROUTE_TOP=40 ROUTE_LIMIT=200000 ROUTE_QUERY=1 ./run -a do_spl_hub_route_latency`
  for `GET /v1/view/topics` per shape (channel, dm, all, per_topic), p50 and
  p95, with n and the `first..last` span stated (the ap-00 rule).
- Insert side: `ENV=prd INSIGHTS_HOURS=24 INSIGHTS_TOP=25 ./run -a do_spl_db_insights`,
  the `INSERT INTO messages` mean before and after.
- Expected (estimate, not a gate): walk work -80..90 %; a topic list well under
  100 ms p50.

## 8. Rollout, backfill, rollback

Deploy order: **DDL before hub**. Every prd step needs the owner's go (Q4).

1. **DDL on dev** (`do_spl_db_bootstrap` path, as the env SA): 0138 creates the
   tables, functions and triggers. From that commit on, every write keeps the
   heads of the topics it touches right; old topics have no head yet, and the
   old hub ignores the tables.
2. **Backfill** `ENV=dev ./run -a do_spl_topic_head_backfill` (new named action,
   `orc/spl-topic-head-backfill.func.sh` + `.tst.sh`): operator scope, loops
   `SELECT topic_head_backfill(500)`, which rebuilds the next 500 topics
   with no head, one short transaction per chunk, each topic under its own
   lock (4.4), so no long lock and no table lock; it prints the chunk count
   and stops when a chunk is empty. A topic written during the backfill is
   right either way. prd scale: ~22 400 messages (`n_tup_ins`, plan 0.2 row 4).
3. **Verify** `ENV=dev ./run -a do_spl_topic_head_verify`: `topic_head_diff`
   for every tenant; prints topics checked (n) and mismatches; exit 1 on any.
4. **Hub with `SPOOL_HUB_TOPIC_HEADS=shadow`** on dev, then the same 1..4 on prd.
   Shadow runs 24 h on prd: 0 `topic_head_mismatch` lines, with the number of
   compared requests stated.
5. **`on`** on dev, then prd (one revision, alone in its 24 h window, as ap-05).
   The 7.6 after-numbers come from that window.
6. **Daily check:** the verify action runs as a step of the daily
   `.github/workflows/45_db-backup.yml`, so a drift is red within a day.

Rollback, each level reversible:

| level | action | effect |
|---|---|---|
| 1 | `SPOOL_HUB_TOPIC_HEADS=off` (one hub revision) | reads back on the walk; heads still kept |
| 2 | `ENV=<env> OP=disable ./run -a do_spl_topic_head_triggers` (named action, owner go) | the insert cost is gone and heads go stale; the action refuses unless the hub's live revision has the flag at `off` |
| 3 | a forward migration dropping the triggers, functions and tables | gone; the hub's probe finds no table and stays on the walk |

Re-enabling after level 2: `OP=enable`, then the backfill with `REBUILD=all`,
then verify, then shadow again.

## 9. Risks

| risk | guard |
|---|---|
| a write the triggers do not see (triggers disabled during a restore) | the daily verify (8.6); `do_spl_db_restore` runs the backfill with `REBUILD=all` after a restore (T007) |
| the trigger slows every insert | 7.5 gate; Insights mean before/after; rollback level 2 |
| a deadlock between two multi-statement topic writers | 4.4: sorted locks per statement, one retry on `40P01`, test C4 |
| the `task_id` tie-break: a `uuid` index orders as `task_id::text` only if both compare the same | E28 pins equal `last_at` ties; if it fails, the indexes take `(task_id::text)` instead |
| the planner picks a bad plan for the new read | it runs under `pgScopeTenantNoJIT` as today; ap-00 n=20 on prd gates the switch |
| the due set grows (a retention change expires many lines at once) | each due head costs today's per-topic read; T009 counts the due set on prd |

## 10. Owner questions (each with a proposal)

| # | question | proposal |
|---|---|---|
| Q1 | Who writes the head: triggers on `messages`, or a call in each Go writer? | **Triggers** (4.1), as rdb 0103 did. |
| Q2 | When a line expires but is not yet swept (up to 10 min), must the list be exact at once, or may it lag until the sweep? | **Exact**: due heads are read the old way (5.3). |
| Q3 | Shadow before the switch? | **Yes**: 24 h of shadow on prd with 0 mismatches, 1 in 10 requests compared, then `on`. |
| Q4 | prd DDL go (0138: two tables, three triggers on `messages`) and the backfill + verify on prd? | **Go after dev**: dev DDL, backfill, verify and 24 h of shadow green first; c-001 runs the prd steps. |
| Q5 | Switch every list shape at once, or leave `since=` deltas (`TaskIDs`) on today's per-topic read? | **Every walk shape at once; `TaskIDs` stays** (it is already one short probe per topic). |
| Q6 | Insert cost budget? | **Under 5 ms added p95** (n=20, 7.5); over it, the build stops and reports. |
| Q7 | ap-03 (archived OR split) and ap-09 (subject index)? | **Dropped** once the head is `on`: both tune the walk the head removes (plan 0.3 already gates ap-03 on "ap-07 deferred"). |
| Q8 | Run the verify every day (a step of workflow 45)? | **Yes** (8.6). |
