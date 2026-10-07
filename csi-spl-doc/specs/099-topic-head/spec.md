# 099 Topic head: one stored row per topic, so a topic list stops walking messages

Version v1.0 (2026-10-07), the panel consensus. v0.1 (2026-10-06,
`71a2a4a9`) was the draft. Owner rule for a big change (HUM-10, t1 5901e226
msg 86dd343f): "1. The written spec and the run tests. 2. The proper spec
with the panel discussion. 3. The actual implementation." Steps 1 and 2 are
done:

- **Step 1:** the case table runs today, `test-results.md` (`a44a267b4`).
- **Step 2:** six seats, each an opinion file in this directory:

| seat | agent | opinion file | sha | verdict |
|---|---|---|---|---|
| agy-1 | a-459 | `agy-1-opinion.md` | `d363cac6c` | accept with changes |
| agy-2 | a-460 | `agy-2-opinion.md` | `a96d0aab2` | accept with changes |
| claude-1 | c-453 | `claude-1-opinion.md` | `72bb38a73` | accept with changes |
| claude-2 | c-454 | `claude-2-opinion.md` | `7fab60c10` | accept with changes |
| claude-3 | c-455 | `claude-3-opinion.md` | `9b8cb3a95` | accept with changes |
| claude-4 | c-456 | `claude-4-opinion.md` | `16504b6d3` | accept with changes |

Source row: ap-07 of `csi-spl-doc/doc/md/refactor-round-api-perf-plan-2026-10-06.md`.
Build tasks: `tasks.md`. Section 11 says what changed from v0.1 and who asked
for each change. Owner rule 2026-10-05 (consensus starts the build; the owner
reviews after): the build starts on this version. Every **prd** step still
needs the owner's go (repo CLAUDE.md: nothing mutates GCP without the owner;
Q4).

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`api/` = `csi-spl-api/src/go/spool-hub-api/`, `store/` =
`api/internal/store/`, `orc/` = `csi-spl-orc/src/bash/run/`.

## 1. Answer

1. **Today every topic list walks messages.** `viewTopicsSQL`
   (`store/view_postgres.go`) walks the tenant's messages newest first, one
   recursive step per listed topic, with an "is this the topic's latest line"
   probe per step. The numbers:
   - prd: 2 301 messages visited for 51 DM topics.
   - Topic lists: p50 150..350 ms, up to 1.5 s (n=446 in 8.4 h).
   - The walks cost 239.9 s/day of DB time (10.5 %).
   - Worst case today: a reader with no match walks the whole tenant. That is
     3.06 s at 200k messages (claude-2, local, n=20).
2. **Phase 1 (this build) stores the walk key, not the summary.** There is
   one head row per topic and one part row per channel or DM pair of it. A row
   holds the latest line, the archived flags, and an expiry bound.
   - A list walks the heads in key order and stops at `LIMIT`.
   - It then runs today's `summary()` for the listed topics only.
   - Measured (claude-4, 22k messages, n=20): p50 4.3..6.3x lower on the list
     shapes, rows equal to the walk.
3. **Phase 2 (the stored summary: count, kinds, parties, subject) is built
   only if phase 1's prd numbers leave a list shape above 100 ms p50**
   (section 10, Q9). The stored summary is where most of v0.1's correctness
   risk sat; the lab puts its extra gain at about 15 ms a list. Its design
   notes are kept in section 9 so nothing the panel found is lost.
4. **One writer, applied at COMMIT.**
   - Row triggers on `messages` only *mark* the topics a transaction touched.
   - One deferred constraint trigger applies the marks at COMMIT, in
     `(tenant_id, task_id)` order, as the last locks the transaction takes.
     This is rdb 0103's own pattern.
   - Immediate triggers, as in v0.1, lose an update (claude-1: 5 of 5) and
     deadlock the send path `InsertMirrored` (3 of 3).
5. **Expiry needs no write.** Each head carries `valid_until`: the earliest
   expiry among its KEY lines (the topic's latest, the DM latest, each part's
   latest). A head with `valid_until <= now` is "due" and is read the old
   exact way (section 5.3), so the answer equals today's to the second.
6. **The proof is the test set** (section 7): the case table against a
   reference oracle (it runs today), the diff and trigger controls, random
   sequences, concurrency, RLS, and the write cost. On prd: hot-measure n=20
   and 24 h route p50/p95.
7. **The rollout is reversible at every step** (section 8):
   1. DDL first.
   2. Backfill and verify (a per-tenant mark gates the read).
   3. Shadow on every request, comparing the hub's JSON in one snapshot.
   4. Switch on.

   A flag turns the read off again in one revision.

## 2. The list contract the head must keep

`TopicRow` (`store/view.go`) per listed topic, from `viewTopicsSQL`. Read rule
by rule from the code; `refTopicsSQL` (`store/topic_head_harness_test.go`)
states each one in plain SQL, and the walk equals it on every case (step 1).

| field / filter | today's rule | phase 1 source |
|---|---|---|
| order, cursor | the topic's latest **unexpired** line under the message filters (channel, DM), **not** under the door; `(received_at DESC, task_id::text DESC)`; `before=` the same pair | head `last_at` (all), head `dm_last_at` (DM), part `last_at` (channel) |
| read door (`Reader`) | listed if some line under the message filters is in a public channel, a channel the reader is in, or a DM the reader is an end of | `EXISTS` over parts: channel in public / mine, or a DM part with the reader as `dm_a` or `dm_b` |
| `Count`, `Kinds`, `Parties`, `FirstAt`, `FirstMsg`, `Channel`, `Parent` | every unexpired line under the message filters AND the door per line | today's `summary()`, unchanged, for the listed topics |
| `Agent` (+box), `Viewer` | some line under the message filters (**no door**) is from or to that id (on that box) | today's probes on `messages`, per walked head; `dm=true` + `Viewer` is answered from DM part ends (exact: below) |
| `Roots`, `Parent` filter | the first line under the message filters (**no door**) has no parent / that parent | today's probes, per walked head; `parent=` keeps its `messages_parent` restriction |
| `NoIssues` | no `issues` row for the topic | unchanged probe |
| archived | hidden if the card (`msg_id = task_id`, in any topic) is archived, or any row of the topic is archived and the topic is not the lobby; **no expiry check** | head `card_archived`, `archived_rows` |
| `TaskIDs` (since=) | each listed topic on its own index range | unchanged in phase 1 (Q5) |

**A part is all visible or all hidden** to a reader (agy-1 F6). Every line
of a part has the same channel, or the same two DM ends. The door depends only
on those, so the door per part equals the door per line. For the same reason,
`dm=true` + `Viewer=v` holds exactly when some DM part has `v` as an end.

Three rules a careless head gets wrong, each with an oracle case and a
control (section 7.1):

- the order key ignores the door;
- `Count` applies the door per line;
- an archived row hides its topic even after it expired, and the card rule
  holds after the card has left its topic (E31).

## 3. The head (phase 1)

Migration `rdb/<next>_topic_heads.sql`. The number is the next free one at
rebase: **0144** on 2026-10-07 (0143 is the last; v0.1's 0138 is taken).
Forward-only.

### 3.1 `topic_heads`: one row per topic

| column | type | meaning |
|---|---|---|
| `tenant_id` | text NOT NULL, FK `tenants` ON DELETE CASCADE | |
| `task_id` | uuid NOT NULL | the topic |
| `last_at`, `last_msg_id` | timestamptz, uuid NOT NULL | the topic's latest line (any part) |
| `dm_last_at`, `dm_last_msg_id` | timestamptz, uuid NULL | the latest DM line; NULL when the topic has no DM part |
| `valid_until` | timestamptz NOT NULL | min of `expires_at` over the KEY lines: the topic's latest, the DM latest, every part's latest |
| `card_archived` | boolean NOT NULL | the row `msg_id = task_id` (in any topic) is archived |
| `archived_rows` | integer NOT NULL | rows of the topic with `archived_at` set, expired or not |
| `rev` | bigint NOT NULL | +1 on every write of the head or its parts |
| `changed_at` | timestamptz NOT NULL | DB clock at the last write |

PK `(tenant_id, task_id)`. Indexes, all on the **uuid** `task_id` (section
5.2 orders by it):

- `(tenant_id, last_at DESC, task_id DESC)` (all topics);
- `(tenant_id, dm_last_at DESC, task_id DESC) WHERE dm_last_at IS NOT NULL`
  (DM);
- `(tenant_id, valid_until)` (the due set).

### 3.2 `topic_head_parts`: one row per channel or DM pair of a topic

| column | type | meaning |
|---|---|---|
| `tenant_id`, `task_id` | FK `(tenant_id, task_id)` -> `topic_heads` ON DELETE CASCADE | |
| `part` | text NOT NULL | `c:<channel>` or `d:<lesser id> <greater id>` |
| `channel` | text NULL | NULL = DM part |
| `dm_a`, `dm_b` | text NULL | the DM's ends, lesser and greater id; CHECK `(channel IS NULL) = (dm_a IS NOT NULL)` (claude-2 F7) |
| `last_at`, `last_msg_id` | timestamptz, uuid NOT NULL | the part's latest line |
| `valid_until` | timestamptz NOT NULL | `expires_at` of that latest line |
| `rev` | bigint NOT NULL | |

PK `(tenant_id, task_id, part)`. Index
`(tenant_id, channel, last_at DESC, task_id DESC) WHERE channel IS NOT NULL`
(the channel list).

**Why the key line's expiry is enough.** The order key is the latest
unexpired line. While the latest line is unexpired, it IS the key, whatever
older lines do. The summary reads `messages` live, with the expiry filter. So
a head is wrong only when a key line has expired, and that makes it due. Mixed
retention (`alerts` 168 h against 720 h) or a moved line that keeps its old
`expires_at` can expire a key line before an older one; the due path is exact
there too.

### 3.3 `topic_head_tenants`: the backfill mark

`(tenant_id PK, backfilled_at timestamptz NULL)`. The backfill sets it after
its last empty chunk for that tenant. The head read serves a tenant only when
the mark is set, so a topic with no head row can never vanish from a list
(claude-3 F10).

### 3.4 RLS and roles

- All three tables get RLS in the 0021 fail-closed NULLIF shape, exactly as
  `rdb/0127_quota_counts.sql`:
  - `ENABLE` + `FORCE ROW LEVEL SECURITY`;
  - policy `tenant_scope`;
  - policy `operator_scope` (the sweep, the backfill and a tenant cascade
    write as operator).
- `store/rls_failclosed_test.go` finds the tables by their `tenant_id`
  column.
- The owner / runtime split:
  - The migration runs as `spool_hub`.
  - `spool_hub_rt` gets DML and EXECUTE through the default privileges of
    `spool-hub-roles/runtime-grants.sql`.
  - The trigger functions are `SECURITY INVOKER` and never switch scope
    (unlike 0103, which switches for its stamp rows). So WITH CHECK holds a
    writer to its own tenant (claude-1 F7, shown on postgres:16).
- The drain skips topics whose tenant row is gone (as 0023's
  `message_period_counts_sub` does). A tenant delete then does not rebuild
  every topic just before the cascade drops its heads.
- No `tenant_change_stamps` trigger on the head tables: every head write is
  caused by a `messages` write in the same transaction, which 0103 already
  bumps.

## 4. How it stays correct

### 4.1 One writer: triggers (Q1)

Every writer of `messages` is covered without anyone remembering it:

- the 33 store statements (claude-3 F4 maps each one to a case);
- the 6 orc psql actions (`spl-msg-dedup`, `spl-topic-delete`,
  `spl-demo-wipe`, `spl-msg-wipe`, `spl-public-dataset-load`,
  `spl-search-seed`);
- the tenant cascade;
- every later migration that updates `messages`;
- a hand-run psql.

The alternative, a call in each Go writer, misses all of the non-Go writers
above. All six seats agree.

### 4.2 Mark now, apply at COMMIT (claude-1 F1, F2, F4)

1. **Mark (immediate, FOR EACH ROW).** These triggers mark the rows:
   - `topic_head_mark_ins`: AFTER INSERT;
   - `topic_head_mark_del`: AFTER DELETE;
   - `topic_head_mark_upd`: AFTER UPDATE OF `task_id, channel, from_id,
     to_id, received_at, expires_at, archived_at`, with `WHEN (old.* IS
     DISTINCT FROM new.*` on those columns`)`.

   Each one appends to a transaction-local set held in a `set_config(..,
   true)` string, as 0103 holds `app.change_stamped`. It appends `(tenant,
   task)` for the old and the new `task_id`, plus the topic whose `task_id` is
   the row's `msg_id` when `archived_at` changed or the row is deleted (the
   card rule). An insert also records its `msg_id`.
   - An edit, a kind change, a claim, the search_sig backfill and a replay
     never fire a mark: they change no head column.
   - A statement trigger with transition tables cannot take a column list
     (`ERROR: transition tables cannot be specified for triggers with column
     lists`, n=1). v0.1's statement triggers therefore taxed every
     `UPDATE messages` (27 sites).
2. **Apply (deferred).** `topic_head_apply` is a `CONSTRAINT TRIGGER ..
   DEFERRABLE INITIALLY DEFERRED FOR EACH ROW`.
   - Its first firing at COMMIT drains the set; later firings find it empty
     and return.
   - It takes the topics in `(tenant_id, task_id::text)` order.
   - A topic touched only by inserts gets the incremental add of its marked
     lines (`GREATEST` on the keys, `LEAST` on `valid_until`, `rev + 1`).
   - Any other topic gets one rebuild.
3. **The head row is the lock (claude-1 F1, agy-2 F1).** There is no
   advisory lock.
   1. Every apply first runs `INSERT .. ON CONFLICT DO NOTHING` of a
      placeholder head, which waits for an in-flight insert of the same key.
   2. It then runs `SELECT .. FOR UPDATE` on the head.
   3. Only then, in a NEW statement, does it read `messages`. A VOLATILE
      plpgsql function under READ COMMITTED gets a fresh snapshot per
      statement (claude-1 F6: 5 of 5).

   The function raises unless `transaction_isolation = 'read committed'`.
4. **A head miss rebuilds (claude-1 F3, claude-3 F1).** An add whose
   placeholder insert created the head runs the rebuild instead, when the
   topic has other rows. Without this, the first write into an old topic
   after the DDL makes a head with `n = 1` that a "no head yet" backfill
   never revisits.
5. **The rebuild is set-based (claude-1 F5).**
   1. Lock the heads of the whole set in order.
   2. One `INSERT .. SELECT .. GROUP BY task_id, part .. ON CONFLICT DO
      UPDATE` over `messages_task_received`.
   3. One `DELETE` of the emptied heads and parts.

   The narrow head needs only max-per-key and the archived counts, never a
   topic aggregate.

### 4.3 Every event

Each event's head effect, and the case that proves it. E-ids are those of
`topic_head_harness_test.go`; E31+ are added by T001b (claude-3 F3, F4).

| event | writer | head effect | case |
|---|---|---|---|
| insert, channel / DM line | `InsertMessage` | add | E01, E02 |
| insert, duplicate resend (`ON CONFLICT DO NOTHING`) | same | none | E34 |
| insert into a topic whose card is archived | same | add; `card_archived` from the probe | E03 |
| insert into an old topic with no head (after the DDL, before the backfill) | same | head miss -> rebuild | E41, C8 |
| edit, kind change | `ApplyEdit`, `SetKind` | none (no head column); `rev` unchanged | E04..E06 |
| move a line / a topic | `MoveMessage`, `MoveTopic` | rebuild old and new | E07..E09 |
| merge / unmerge a topic (with a child) | `MergeTopic`, `UnmergeTopic` | rebuild both (A's head deleted when empty) | E10, E11, E38 |
| promote / demote | `PromoteMessage`, `DemoteTopic` | rebuild both | E12, E12b |
| archive / unarchive a card, a reply, the lobby | `SetArchived` (+ `archiveMirrorsTx`) | rebuild the row's topic and the topic `task_id = msg_id` | E13..E15, E35, E35b |
| archive a card that has left its topic | same | the card rule alone hides | E31 |
| move an archived reply | `MoveMessage` | rebuild both | E39 |
| edit a mirrored line | `applyEditTx` per copy | none | E36 |
| delete a line, merge two lines | `DeleteMessage`, `MergeMessages` | rebuild | E16, E17 |
| delete a topic, a channel | `DeleteTopic`, `DeleteChannel` | rebuild / delete | E18, E19 |
| archive / unarchive a channel | `ArchiveChannel`, `UnarchiveChannel` | rebuild the stamped cards' topics | E29, E37 |
| a key line expires (no write) | none | the read treats the head as due | E20..E23, E20p |
| sweep purge (5 000-row chunks) | `Sweep` | rebuild, valid again | E24 |
| tenant deleted | cascade | heads cascade; the drain skips gone tenants | E25 |
| mixed channel + DM part; two DM pairs; one agent on two boxes | any | parts | E26, E27, E32 |
| child topic whose first line is in a created channel | any | roots ignore the door | E30, E33 |
| equal `received_at` across topics, inside a page | any | tie-break on the uuid | E28 (5 tied topics) |
| equal `received_at` inside one topic | any | first-line tie-break `msg_id::text` | E40 |
| a later migration updating `messages` | migration | marks; one apply at its COMMIT | T002 note |
| orc psql writers | operator / tenant scope | marks | their pg tests assert the diff (T006) |

### 4.4 Concurrency

- **Two inserts in one topic.** They serialise on the head row at COMMIT
  only, for the drain's duration (sub-ms), not for the insert statement.
  C1 checks the count; C1b times 2 x 200 inserts into one topic with and
  without the trigger (claude-4 F6).
- **Insert against a rebuild, or a first insert against a move into a new
  task.** Both take the same row lock (4.2 point 3). C2, C6.
- **Lock order.** The drain locks every head of the transaction last, in
  sorted order, so no head-lock cycle exists, including against
  `InsertMirrored` (C7: 50 rounds, 0 `40P01`). A cycle on `messages` rows
  between two multi-statement writers is still possible in principle. T004
  adds the one retry on `40P01` only if C4 shows one under this design.
- **The sweep.** One 5 000-row chunk applies its topics in one sorted,
  set-based rebuild at COMMIT. 7.5 gates its head-lock time.

## 5. The read

### 5.1 Switch

`SPOOL_HUB_TOPIC_HEADS = off | shadow | on` (default `off`). The store reads
heads only when the table exists and the tenant's backfill mark is set.
`GET /version` reports the mode, as `topic_heads` (agy-2 F2).

- `off`: today's walk.
- `shadow`: serve today's walk. For 1 request in
  `SPOOL_HUB_TOPIC_HEADS_SAMPLE` (default **1**, every request: claude-2,
  claude-3, claude-4, agy-2), also run the head read.
  - Both reads run in ONE `REPEATABLE READ READ ONLY` transaction, one
    snapshot, so a send committed between them is not a mismatch (claude-1
    F8).
  - The two **hub JSON bodies** of the topics response are compared byte for
    byte, never a `TopicRow` md5 (claude-2 F1, agy-2 F7).
  - The hub logs `topic_head_mismatch` with the tenant, the query shape and
    the task ids, never a body.
  - Every 10 min it logs `topic_head_shadow` with the count of compared and
    mismatched requests per shape.
- `on`: serve the head read.

### 5.2 The statement

`viewTopicsHeadSQL(tenant, q)` sits beside `viewTopicsSQL` and returns the
same `TopicRow` columns.

- **Walk.** Each shape walks one index:
  - channel: `topic_head_parts` on its channel index;
  - DM: `topic_heads` on `dm_last_at`;
  - all: `topic_heads` on `last_at`.

  Each is one row per topic: an ordered index scan with filters and `LIMIT`,
  no recursive step.
- **Order and cursor on the uuid** (claude-2 F5, claude-4 F7, agy-1 F5):
  - `ORDER BY k DESC, task_id DESC`;
  - the cursor is `k <= $at` as the index condition, plus
    `(k, task_id::text) < ($at, $task)` as a filter, so a non-canonical
    `before` id never reaches a `::uuid` cast.

  uuid order equals `task_id::text` order:
  - prd: en_US.UTF8, 1 871 ids, 0 differences (claude-2);
  - local: 200 000 random ids, 0 differences (claude-3).

  E28 pins it.
- **Filters on the walked head:**
  - `valid_until > now` (a due head goes to 5.3);
  - not archived: `NOT card_archived AND (archived_rows = 0 OR task_id::text
    = lobby)`. The channel walk probes the topic row by PK for this
    (claude-2 F10);
  - the door as an `EXISTS` over parts (section 2);
  - `Agent`, `Viewer`, `Roots`, `Parent`, `NoIssues` as today's per-topic
    probes;
  - the cursor.
- **Summary:** today's `summary(aggDoor)` over the walked topics, unchanged.
  So `Kinds` keeps its line order and `sameRows` compares the head read
  as it is.
- **Batch header:** its own. Tenant, `jit off` and
  `plan_cache_mode = force_custom_plan` as `pgScopeTenantNoJIT`;
  `enable_sort` and bitmap scans are decided by T005's A/B per shape (n=20,
  20k and 200k). The head read is not recursive, so a misestimate costs at
  most one pass over the heads (claude-2 F4).
- **Bound, stated:** the worst page is one pass over the tenant's heads.
  Locally that is 41.6 ms at 16 666 topics for a reader with no match,
  against 3.06 s for today's walk (claude-2 F3). On prd, 485 of 489 DM ends
  are in fewer than 50 DM topics, so their DM page walks every DM head (994).
  - A per-end DM key, one row per (end, topic), is the later option if the
    T009 numbers ask for it (heads visited per listed row > 3 on the DM
    shapes; claude-4 F4).
  - The same goes for a `first_parent` index (agy-1 F2, claude-2 F4).

### 5.3 Due heads: a second statement, merged in Go (claude-2 F2, agy-1 F3)

The same batch (one round trip) carries two statements:

1. the head walk above, with `valid_until > now` and `LIMIT n`;
2. today's `listed()` + `summary()` (the `TaskIDs` path, which already
   applies every filter and the cursor), with its id source
   `SELECT task_id FROM topic_heads WHERE tenant_id = $1 AND valid_until <=
   $now`.
   - For `channel=`, the source is the parts of that channel with
     `valid_until <= now`.
   - For `dm=`, it is the heads with a DM part that is due.

Go merges the two by `(k DESC, task_id DESC)` and cuts at `n`. No Sort node
is added under `enable_sort = off`, and the exact path is tested code.

- The due set on prd is about 0 today: the TTL is a flat ~30 d, and 0 lines
  expire within a day (claude-2, prd read-only, 2026-10-07). E20..E23 and
  E20p (a due topic exactly at a page boundary) are its only proof until the
  data ages.
- T009 counts the due set hourly over a full day.

### 5.4 What is not switched

`ViewTopic`, `ViewTopicsMessages` (`per_topic=`), the memory store
(`Memory.ViewTopics` builds rows live, so no memory head is needed: claude-4
F9), and `TaskIDs` (Q5). The Flow list's walk is `viewTopicsSQL`, including
through `ViewTopicsUnlessClone` (`store/clones.go`), so the Flow list gains
too.

## 6. Cases

The E-cases of section 4.3, each run over every shape of `topicHeadShapes`
(`topic_head_harness_test.go`):

- 3 readers: none (door off), a member of a created channel, a member of
  none;
- all, a default channel, a created channel, DM;
- roots, agent= with and without a box, viewer=, parent=, NoIssues;
- `TaskIDs`;
- every `before=` page at limit 3.

The default grid is 288 shapes; `SPOOL_TEST_LONG=1` runs 576.

## 7. The test set

All on Postgres (`SPOOL_TEST_PG_DSN`, skipped without it), under
`PRE_PUSH_TIER=full`. The budget for the whole 099 set in the pre-push tier
is **3 min** (claude-3); the long variants run nightly (T007).

### 7.1 The oracle

`TestTopicHeadCases` (lands today, T001):

- The walk equals `refTopicsSQL` on every case, shape and page.
- Each case asserts on the plain list that it did what it names.
- `refTopicsSQL` replaces v0.1's pre-027 `oracleTopicsSQL`, which has no
  door, no archived hide and no NoIssues (test-results 1.2).
- T005 sets `topicHeadRead` and the same run then asserts
  head read == walk.
- From T002 on, `headDiffEmpty` asserts `topic_head_diff(tenant)` is empty
  after every case.

Controls (every test must be able to fail):

- **Reference controls** (`TestTopicHeadReferenceControl`). Each breaks one
  rule in a copy of the reference and pages the case that needs it, as a
  hard assertion:
  - door per line;
  - archived hide;
  - order key under the door;
  - tie-break ASC (E28);
  - cursor ignores the task id (E28);
  - card rule dropped (E31);
  - agent box ignored (E32);
  - first parent under the door (E33).

  Today the first three are caught. The other five are not, because their
  fixtures cannot fail them (claude-3 F3, n=1 each), so T001b adds the
  fixtures.
- **Diff controls** (`TestTopicHeadDiffDetectsEveryColumn`):
  - corrupt each column of 3.1 and 3.2 on one head, as operator; the diff
    names that topic;
  - plus a missing head, an orphan head, a missing part and an orphan part.
- **Trigger controls** (`TestTopicHeadTriggerControls`): disable each
  trigger in turn and one case fails:
  - mark_ins -> E01;
  - mark_upd -> E07;
  - mark_del -> E16;
  - apply -> every case.
- `TestTopicHeadNonHeadUpdatesKeepRev`: each non-head statement (the claim
  x4, replay env, search_sig) leaves `rev` unchanged.

### 7.2 Random sequences

`TestTopicHeadRandomSequences`, default **4 seeds x 300 operations**:

- `topic_head_diff` is empty after every operation;
- 16 seeded shapes are checked every 25 operations, and the full grid at
  the end.

The operations:

- every E-case writer, as one op each;
- advance the clock past one key line;
- a tenant-scoped purge: the sweep's chunk `DELETE` plus `tenant_id`. The
  global `Sweep` would hit other tests' rows.

Operations draw from sorted slices only, never a Go map, so a seed replays.
`TOPIC_HEAD_SEED` / `TOPIC_HEAD_OPS` replay a prefix. `SPOOL_TEST_LONG=1`
runs 200 seeds, nightly (T007).

### 7.3 Concurrency

| id | test | passes when |
|---|---|---|
| C1 | 2 goroutines x 200 inserts into one topic | head right, diff empty |
| C1b | the same with and without the triggers, n=5 rounds | wall time printed; the 7.5 gate applies to the added p95 |
| C2 | inserts into A while A's lines are moved | diff empty, no lost line |
| C3 | inserts into A and B while A merges into B | diff empty |
| C4 | merge A->B and B->A at once, 50 rounds | every call ends ok; retries seen are counted and logged |
| C4b | two transactions in lockstep (a barrier between statements) that would cycle on head locks under v0.1 | no `40P01` (the drain is sorted and last) |
| C5 | a 5 000-row purge chunk over 1 000 topics against inserts into them | diff empty; longest head-lock hold printed |
| C6 | a topic's first insert against a move into that new task | diff empty (claude-1 F1: lost 5 of 5 under v0.1) |
| C7 | `InsertMirrored` against a merge of the same two topics, 50 rounds | 0 `40P01` (claude-1 F2: deadlocked 3 of 3 under v0.1) |
| C8 | an insert into a pre-DDL topic, then the backfill | diff empty |
| C9 | two tenants with the SAME task uuid written at once | each head right, other `rev` unchanged |

### 7.4 RLS and roles

`store/topic_head_rls_test.go` plus the catalogue of `rls_failclosed_test.go`:

- t2's scope reads 0 head, part and mark rows of t1;
- a t1 write under t2's scope fails WITH CHECK;
- an empty scope reads 0 rows;
- the operator reads all.

`TestTopicHeadRuntimeRole` runs E01, E07, E13, E16, E18 as `spool_hub_rt`
under tenant scope, and the diff is empty. `TestTopicHeadOperatorWrites` runs
the sweep and an orc-style operator delete. E25 (the tenant delete) runs as
the runtime role, because a superuser bypasses RLS and proves nothing.

### 7.5 Write cost (Q6)

`TestTopicHeadCost` (`SPOOL_TEST_PERF=1`). The method:

- on a CPU-limited postgres:16-alpine;
- n >= 200 per arm, interleaved with and without the triggers;
- the seed loaded by `INSERT .. SELECT` with the triggers off, then the
  backfill.

The gates (claude-1 F4, F5; claude-3 F8; claude-4 F6):

| number | gate |
|---|---|
| one insert, added p50 and p95 | p95 < **5 ms** |
| a claim-shape `UPDATE` (no head column), added p95 | < 5 ms |
| a 5 000-row purge chunk: added time and longest head-lock hold | hold <= 100 ms, else the purge gets its own smaller chunk |
| C1b contention, added p95 | < 5 ms |
| hot topic (5 000 lines, 200 parties) and bulk (1 000-row `INSERT .. SELECT`) | printed |

### 7.6 Perf proof on prd (before / after, through c-001)

From `csi-spl-orc`, as the env SA:

- **Per call:** `ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20
  MEASURE_ONLY=walk_dm ./run -a do_spl_db_hot_measure`, the same with
  `walk_all`, and T008's `walk_dm_head`, `walk_all_head`, the worst reader
  (`walk_dm_head` for a reader in no DM) and `parent=`. Twice before and
  twice after, 10 min apart.
- **Per route:** `ENV=prd ROUTE_HOURS=24 ROUTE_TOP=40 ROUTE_LIMIT=200000
  ROUTE_QUERY=1 ./run -a do_spl_hub_route_latency`, for
  `GET /v1/view/topics` per shape, p50/p95 with n and the span.
- **Insert side:** `ENV=prd INSIGHTS_HOURS=24 INSIGHTS_TOP=25 ./run -a
  do_spl_db_insights`, the `INSERT INTO messages` mean, before and after.
- **Deadlocks:** `pg_stat_database.deadlocks` before and after each 24 h
  window (claude-1).
- **Phase 2 inputs:** heads visited per listed row per shape, and
  `summary()`'s share of each shape's time (claude-4 F1, F4).

## 8. Rollout, backfill, rollback

DDL before hub. Every prd step needs the owner's go (Q4); c-001 runs them.

1. **DDL on dev** (the `do_spl_db_bootstrap` path, as the env SA): the
   tables, functions and triggers. From then on, every write keeps its
   topics' heads right (head miss -> rebuild, 4.2 point 4). The old hub
   ignores the tables.
2. **Backfill.** `ENV=dev ./run -a do_spl_topic_head_backfill`
   (`orc/spl-topic-head-backfill.func.sh` + `.tst.sh`).
   - It runs in the operator scope.
   - It loops `SELECT topic_head_backfill(chunk => 100, rebuild_all =>
     $REBUILD_ALL, after => $cursor)`, a keyset walk over the distinct
     `(tenant_id, task_id)` of `messages` that rebuilds every topic it
     passes, head or not (claude-1 F3, agy-2 F6).
   - `REBUILD=all` also deletes heads whose topic has no row left.
   - Each chunk is one short transaction under `lock_timeout = 5s` (agy-2).
   - It sets each tenant's mark when that tenant's last chunk is empty, and
     prints chunks and topics.
   - prd scale: 19 955 messages, 1 621 topics (claude-2, 2026-10-07).
3. **Verify.** `ENV=dev ./run -a do_spl_topic_head_verify` runs
   `topic_head_diff` for every tenant, prints the topics checked (n) and the
   mismatches, and exits 1 on any. It runs after every dev DDL deploy, not
   only daily.
4. **Shadow on dev, then 1..4 on prd.** prd shadow runs until **n >= 500
   compared requests** cover all six route shapes, with **0 mismatches**, and
   for at least 24 h.
   - Read it with `ENV=prd ./run -a do_spl_topic_head_shadow_report`, a named
     action over the `topic_head_shadow` / `topic_head_mismatch` log lines
     (agy-2 F3).
   - At ~1 270 lists a day, 1-in-1 reaches n=500 within a day. A defect that
     hits 2 % of lists escapes 1 270 compares with p < 1e-11; with v0.1's
     1-in-10 (127 compares) it escapes with p = 7.7 % (claude-3).
5. **`on`**: dev, then prd. One revision, alone in its 24 h window. The 7.6
   after-numbers come from that window.
6. **Daily check.** `do_spl_topic_head_verify` runs as a step of
   `.github/workflows/45_db-backup.yml`, **against the restored throwaway
   container** that the workflow already starts. That proves the backup and
   the heads, with no load on the live Cloud SQL (agy-2 F5).

Rollback, each level reversible:

| level | action | effect |
|---|---|---|
| 1 | `SPOOL_HUB_TOPIC_HEADS=off` (one hub revision) | reads back on the walk; heads still kept |
| 2 | `ENV=<env> OP=disable ./run -a do_spl_topic_head_triggers` (named action, owner go) | the trigger cost is gone and heads go stale; the action reads `topic_heads` from `GET /version` (host from cnf, never a literal) and refuses unless it is `off` |
| 3 | a forward migration dropping the triggers, functions and tables | gone; the hub's probe finds no table and stays on the walk |

Re-enabling after level 2: `OP=enable`, which runs the backfill with
`REBUILD=all` itself, then verify, then shadow again.

**Restore:** `do_spl_db_restore` runs `REBUILD=all` after a restore into an
env (`TARGET=env` only).

## 9. Phase 2: the stored summary (built only if Q9's gate trips)

Kept so nothing the panel found is lost. Each item is required IF phase 2 is
built:

1. **`Kinds` as counts first.** `TopicRow.Kinds` becomes `map[string]int`:
   the walk emits `jsonb_object_agg`, and `sameRows` compares maps. The hub
   JSON is unchanged, since `kinds` is already a map. Its own task lands
   before any summary head. A head holds `{kind: n}` and cannot rebuild line
   order: as v0.1 stood, 7 of 7 shapes differed raw and were equal as a
   multiset (claude-2 F1, claude-3 F2, agy-1 F4).
2. **Parties as `{id: {box: n}}`**, so viewer is `parties ? $id` and
   agent+box is `parties -> $id ? $box`. A flat `"id@box"` needs a key-prefix
   scan, and `LIKE` treats `_`/`%` in an id as wildcards (claude-2 F6, agy-1
   F1).
3. **The subject function** `topic_head_subject(msg)` equals Go's
   `subjectSQL`, tested on n >= 2 000 bodies.
4. **One LATERAL over the parts** for the whole summary (claude-2 F8); a
   `first_parent` partial index; Roots/Parent on the first part under the
   message filters, without the door, while the summary's `Parent` comes
   from the first part under the door (agy-1 F7).
5. **The purge decrements** `n`/`kinds`/`parties` without reading the topic
   when the removed line is neither its part's first nor last (claude-1 F5).
6. **`TaskIDs` as head PK lookups** (agy-1 F8).
7. **ap-09** (the subject index) is re-measured after phase 1 and folds away
   only if phase 2 is built.

## 10. Owner questions (the panel's answers; the build starts on them, the owner may still change any)

| # | question | v1.0 answer | seats |
|---|---|---|---|
| Q1 | Who writes the head? | **Triggers**: mark per row, apply at COMMIT in sorted order (4.2) | 6 of 6 agree on triggers; claude-1's mark-and-defer is adopted for its shown race and deadlock |
| Q2 | Exact at once when a line expires, or lag until the sweep? | **Exact**: due heads are read the old way (5.3) | 6 of 6 |
| Q3 | Shadow before the switch? | **Yes**: every request, one snapshot, hub JSON compared; n >= 500 over all shapes, 0 mismatches, >= 24 h | 6 of 6 yes; 4 seats asked for 1-in-1 |
| Q4 | The prd DDL, backfill and verify? | **After dev**: dev DDL, backfill, verify, 24 h shadow and `deadlocks` delta 0 first; c-001 runs prd with the owner's go | 6 of 6 |
| Q5 | Every shape at once; `TaskIDs` stays? | **Yes** | 6 of 6 |
| Q6 | Write cost budget? | **< 5 ms added p95** on an insert AND on a claim-shape update, n >= 200, CPU-limited; sweep-chunk head-lock hold <= 100 ms (7.5) | 6 of 6 keep 5 ms; 3 widen what is measured |
| Q7 | ap-03 and ap-09? | **ap-03 dropped** once `on` has held 24 h (claude-4 lab: -13..+2 %, p95 worse on `all`); **ap-09 parked** until the Q9 decision | 4 drop both; claude-4 and claude-2 park first |
| Q8 | Daily verify? | **Yes**, in workflow 45 against the restored container, and after every dev DDL deploy | 6 of 6; agy-2's target |
| Q9 (new) | When is phase 2 built? | Only if a list shape stays **above 100 ms p50** over 24 h on prd after `on` | claude-4; the other seats reviewed the full head and found it workable but fragile |

## 11. What changed from v0.1, and who asked

| change | v0.1 | v1.0 | from |
|---|---|---|---|
| scope | full stored summary | phase 1 = walk key + archived + parts with DM ends; summary = phase 2 behind Q9 | claude-4 (lab), lead decision |
| write path | immediate row insert + statement update/delete triggers | mark per row, apply at COMMIT, sorted; row-level `UPDATE OF .. WHEN` | claude-1 F2, F4 |
| lock | head row or advisory lock | head row always (placeholder + FOR UPDATE) | claude-1 F1, agy-2 F1 |
| head miss | treated as an empty topic | rebuild | claude-1 F3, claude-3 F1 |
| backfill | "topics with no head", 500 | keyset over every topic, 100 a chunk, lock_timeout, `REBUILD=all`, per-tenant mark | claude-1 F3, agy-2 F6, claude-3 F10 |
| sweep chunk | "500" | 5 000 (`store/postgres.go`, `sweepChunk`); set-based rebuild; hold gated | claude-1 F5, claude-4 F3 |
| `valid_until` | earliest line of the topic | earliest KEY line | claude-4 F5 |
| order / indexes | `task_id::text` fallback | uuid order, text cursor filter | claude-2 F5, claude-4 F7, agy-1 F5 |
| due heads | merged inside the SQL | second statement, merged in Go; per channel part | claude-2 F2, agy-1 F3 |
| shadow | 1 in 10, `TopicRow` md5 | 1 in 1, hub JSON, one snapshot, counters, report action | claude-1 F8, claude-2 F1, claude-3, claude-4, agy-2 F3, F4, F7 |
| switch guard | table probe | table probe + backfill mark | claude-3 F10 |
| rollback 2 | refusal rule not checkable | `/version` reports the mode | agy-2 F2 |
| daily verify | live DB | restored container in wf45 | agy-2 F5 |
| oracle | pre-027 `oracleTopicsSQL` | `refTopicsSQL` | test-results 1.2 |
| cases | E01..E28 | + E12b, E13b, E20p, E29..E41, E25 as runtime role | test-results, claude-3 F3, F4 |
| cost gate | insert, n=20 | insert + claim update + sweep hold + contention, n >= 200 | claude-1 F4, claude-3 F8, claude-4 F6 |
| migration | 0138 | next free (0144 today) | claude-4, claude-1, agy-2 |
