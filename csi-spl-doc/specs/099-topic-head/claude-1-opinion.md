# 099 Topic head: panel opinion, seat claude-1 (triggers, locks, concurrency)

Panel step 2 (HUM-10, t1 5901e226 msg 86dd343f). Scope: spec v0.1 sections
4.1, 4.2, 4.4 as a Postgres engineer. Opinion only: nothing else is edited.

Tree: `origin/master` at `ae42081c6`. Experiments: private
`postgres:16-alpine` (16.15), a minimal model of `messages` + `heads` with
the spec's triggers and lock rule (parts, kinds, parties left out: they change
no lock or snapshot question). The box was loaded, so cost numbers are medians
of interleaved rounds: order of magnitude, not prd.

## 1. Verdict

**Accept with changes.** The one reason: the lock rule of 4.4 loses an update
when a rebuild meets a topic's first insert (shown 5 of 5), and immediate
triggers add a head-lock-order deadlock to the hot send path (shown 3 of 3);
both are fixed by one change, applying the head at COMMIT in sorted order
(0103's own pattern), which the spec cites as precedent and then does not use.

## 2. Findings, most severe first

### F1. 4.4: the advisory-lock branch does not exclude the insert path: lost update

- **What is wrong.** When no head row exists, `topic_head_rebuild` takes
  `pg_advisory_xact_lock`, but `topic_head_add` never takes that lock. A
  rebuild that runs while the topic's first insert is uncommitted finds no head
  row to lock (`SELECT .. FOR UPDATE` does not wait for an uncommitted insert,
  it just sees nothing), reads `messages` without that line, then its
  `INSERT .. ON CONFLICT DO UPDATE` waits for the insert to commit and
  overwrites the insert's head with its own stale count.
- **When it happens.** A rebuild of a topic that has no head yet, while a line
  is being inserted into it: a move or promote into a new task
  (`MoveMessage` `toTask`, `PromoteMessage` `newTask`) racing the first reply,
  and every first write into an old topic during the backfill (step 8.2).
- **Evidence.** `e3.sh` (scratch, n=5): session A `BEGIN; INSERT` the first line
  of topic X, held 2 s; session B moves topic Y's only line into X (the
  statement trigger rebuilds X under the spec's rule). Result each time:
  `truth=2 head_n=1` (5 of 5).
- **Change for v1.0.** Make the head row itself the lock, always:
  `INSERT INTO topic_heads (..placeholder..) ON CONFLICT DO NOTHING`, then
  `SELECT .. FOR UPDATE`, then the new statement that reads `messages`; delete
  the head at the end when the topic has no row. `ON CONFLICT DO NOTHING`
  waits for an in-flight insert of the same key, so the race closes. Same
  experiment with that rebuild: `truth=2 head_n=2` (5 of 5). Drop the
  advisory lock from the spec. Add it as test C6.

### F2. 4.4: immediate triggers deadlock the send path (`InsertMirrored`)

- **What is wrong.** 4.4 says only the human-initiated multi-statement writers
  can deadlock and gives them one retry (T004). But `InsertMirrored`
  (`store/dm_mirror_postgres.go:35`) is a SEND: one transaction inserts the DM
  line into topic A and then its channel copy into topic B. With immediate
  triggers it locks head A, then head B, in insert order. Any one statement
  that rebuilds both (a `SetKind` or channel delete over the set, a merge
  stage, the sweep chunk) locks them in `(tenant_id, task_id)` order. When B
  sorts before A that is a cycle, and the loser is either a send or the
  human's move.
- **Evidence.** `e4.sh` (scratch, n=3): T1 = insert into A, sleep 1 s, insert
  into B; T2 = one `UPDATE` touching both topics. `ERROR: deadlock detected` in
  3 of 3 rounds. The cycle is head locks only (T2's UPDATE never sees T1's new
  rows).
- **Same class**, unchecked: `UnmergeTopic` (`topic_merge_postgres.go:85`),
  `DemoteTopic` (`topic_promote_postgres.go:74`) and `MergeTopic`'s 5-statement
  batch lock heads in statement order across the transaction, not sorted.
- **Change for v1.0.** Apply the head at COMMIT, sorted, as the last locks the
  transaction takes. This is exactly how rdb 0103 avoided the same problem
  (its header: "the stamp row lock is the LAST lock a transaction takes ... no
  lock-order deadlock with the rows the transaction wrote before it"):
  1. Immediate row triggers only MARK: `AFTER INSERT`, `AFTER DELETE`, and
     `AFTER UPDATE OF <head columns> FOR EACH ROW WHEN (old IS DISTINCT FROM
     new on those columns)` append `(tenant, task)` (and, for an insert, its
     `msg_id`) to a transaction-local set, held in a `set_config(.., true)`
     string the way 0103 holds `app.change_stamped`.
  2. One `CONSTRAINT TRIGGER .. DEFERRABLE INITIALLY DEFERRED FOR EACH ROW`
     drains the set at COMMIT on its first firing (later firings see it empty
     and return): sorted by `(tenant_id, task_id::text)`, an insert-only topic
     gets the incremental `topic_head_add` of its marked lines, any other
     topic gets one `topic_head_rebuild` (F1's lock).
  - Evidence it works (n=5): the same `e4.sh` under that variant
    (`defer.sql`, rebuild only) ran 5 of 5 rounds with no deadlock, and the
    stored heads equalled `count(*) GROUP BY task_id` (`drift=0`); `e3.sh`
    under it: `truth=2 head_n=2`, 3 of 3.
  - Side wins: a merge rebuilds A and B once, not once per head-column
    statement of its batch (2..5); T004's retry is not needed for head locks.
  - Inserts must stay incremental at the drain (one PK probe per marked
    line; I believe, unchecked, < 0.1 ms): my rebuild-only prototype paid +1.2 ms (F4).

### F3. 8.2 backfill: a topic written before the backfill reaches it stays wrong forever

- **What is wrong.** From the DDL on, the first insert into an OLD topic
  creates its head incrementally with `n = 1` (the add path does not know the
  topic has older lines). The backfill "rebuilds the next 500 topics with no
  head", so it skips that topic, and the head stays wrong until something
  rebuilds it. 8.2 says "a topic written during the backfill is right either
  way"; it is not.
- **Evidence.** Heads table emptied (as just after the DDL), then one insert
  into a 110-line topic under the spec's triggers:
  `backfill-hole truth=111 head_n=1` (n=1; deterministic by construction).
- **Change for v1.0.** Either (a) the add path, when its upsert INSERTED the
  head (not updated it), rebuilds the topic instead (one extra index probe,
  only on a topic's first head write), or (b) the backfill walks distinct
  `task_id`s of `messages` (keyset, 500 a chunk), rebuilding every topic it
  passes, head or not. I propose (a): it also makes rollback level 2
  re-enable safe for topics that got no write in between, and (b) for
  `REBUILD=all`, which must also delete heads whose topic has no row left
  (a topic deleted while the triggers were off). Test C8.

### F4. 4.1/7.5: the cost gate measures only the insert; the UPDATE trigger taxes every UPDATE

- **What is wrong.** Transition tables cannot be combined with a column list:
  `CREATE TRIGGER x AFTER UPDATE OF task_id ON messages REFERENCING OLD TABLE ..`
  gives `ERROR: transition tables cannot be specified for triggers with column
  lists` (n=1). So `topic_head_upd` fires and materialises the old and new
  rows of EVERY `UPDATE messages`: claims (`message_claim_postgres.go:76`,
  `:89`, `:114`, `:270`), the search_sig backfill (500 rows of 1 KB+ bodies a
  chunk), read state, all of it. 27 `UPDATE messages` sites in `store/`
  (`grep -rn "UPDATE messages SET" *.go | grep -v _test | wc -l` -> 27).
  It rebuilds nothing for those, but still pays the capture and the join.
- **Evidence.** pgbench, one client, 1 000 transactions a round, 5 interleaved
  rounds per config, 200 000 lines over 2 000 topics; median latency:

  | config | insert | claim-shape UPDATE (no head column) |
  |---|---|---|
  | no head triggers | 3.17 ms | 4.24 ms |
  | spec (row insert + statement update/delete with transition tables) | 3.60 ms (+0.43) | 4.47 ms (+0.23) |
  | F2 prototype (mark + deferred, rebuild on insert) | 4.41 ms (+1.24) | 4.41 ms (+0.17) |

  The spec's insert add is well under the 5 ms gate here. The row-level
  `UPDATE OF .. WHEN` mark does not fire for a claim at all; its remaining
  +0.17 is the always-firing deferred drain (returns at once) inside the
  noise of this box.
- **Change for v1.0.** (1) Use the row-level `UPDATE OF <cols> WHEN (..)`
  trigger of F2 for updates, not a statement trigger with transition tables.
  (2) 7.5 gates three numbers, not one: the insert, a claim-shape UPDATE, and
  a 5 000-row sweep chunk, each with and without the triggers, n=20, on a
  container limited to db-f1-micro's share (`docker run --cpus=0.2`; I
  believe, unchecked, the shared-core figure of f1-micro).

### F5. 4.4: the sweep chunk is 5 000 rows, not 500, and holds up to 5 000 topics' head locks

- **What is wrong.** `const sweepChunk = 5000` (`store/postgres.go:598`); 4.4
  says 500. One `DELETE` chunk spans every tenant, rebuilds every topic it
  touched one plpgsql call at a time, and holds each head lock until the chunk
  commits. Every send into one of those topics waits that long, holding one of
  the hub's 8 pool connections (`config.go:262`, `SPOOL_HUB_DB_MAX_CONNS`
  default 8) on a db with `max_connections` 25.
- **Evidence.** A 5 000-row chunk spread over 2 000 topics of ~100 lines:
  845 ms and 706 ms with the spec's triggers, 221 ms and 239 ms without
  (n=2 each, interleaved): +0.5..0.6 s, all of it under head locks.
- **Change for v1.0.** (1) The rebuild of a SET of topics is one set-based
  statement: lock the heads `ORDER BY tenant_id, task_id::text FOR UPDATE`,
  then one `INSERT .. SELECT .. GROUP BY task_id, part ON CONFLICT DO UPDATE`
  over `messages_task_received`, then one `DELETE` of the emptied heads and
  parts, instead of N plpgsql calls. (2) A purge only removes lines, so
  for a topic whose removed lines are neither its part's first nor last, `n`,
  `kinds` and `parties` can be decremented without reading the topic; the
  rebuild is needed only when a first/last/expiry bound moves. (3) The
  chunk's head-lock time is a 7.5 number; over ~100 ms on the f1-micro
  container, the purge gets its own smaller chunk.

### F6. 4.2: the snapshot claim is right, but only once F1 makes the lock real

- The claim "a new statement inside a VOLATILE plpgsql function sees a fresh
  READ COMMITTED snapshot" holds: with a head row present, A inserts a line
  into X and holds 2 s, B moves a line into X; B's `FOR UPDATE` waits, and the
  next statement counts A's line: `truth=3 head_n=3`, 5 of 5 (`e2.sh`). The
  documentation says the same (VOLATILE functions take a new snapshot per
  query). v1.0 should say the function MUST be VOLATILE (the default; a
  `STABLE` mark would silently reuse the outer snapshot) and that the
  transaction must be READ COMMITTED: a `REPEATABLE READ` caller would
  rebuild from its old snapshot. No store code opens one today
  (`grep -rln "RepeatableRead\|REPEATABLE\|Serializable" store/*.go | grep -v _test`
  -> no file), but F8's shadow compare would. The rebuild should raise unless
  `current_setting('transaction_isolation') = 'read committed'`.

### F7. 3.3: SECURITY INVOKER under FORCE RLS works; the tenant cascade wastes a rebuild

- **Evidence.** Non-superuser owner role + a runtime role with DML only,
  FORCE RLS on `tenants`, `messages`, `heads` in the 0021 NULLIF shape (n=1):
  the runtime role's insert under `app.tenant_id=t1` wrote its head (`n=1`);
  under t2, writing a t1 line failed `new row violates row-level security
  policy for table "messages"`; t2 and the empty scope saw 0 heads; deleting
  tenant t1 under the operator scope fired the delete trigger as
  `user=rt scope=operator` (the cascade runs the AFTER trigger as the
  deleter, in the deleter's scope) and left 0 heads.
- **Change for v1.0.** The trigger functions must never switch scope (unlike
  0103, which needs operator for its stamp rows; heads are per tenant). Skip
  topics whose tenant row is gone (`WHERE EXISTS (SELECT 1 FROM tenants ..)`,
  as 0023's `message_period_counts_sub` does): a tenant delete otherwise
  rebuilds every one of its topics just before the cascade drops the heads.
  E25 runs as the runtime role (a superuser bypasses RLS: proves nothing).

### F8. 5.1 shadow: a compare of two separate statements reports races as mismatches

- Shadow runs the walk, then the head read, as two statements; a send that
  commits between them makes them differ legitimately. On prd that would log
  `topic_head_mismatch` lines that are not defects, and the 0-mismatch gate of
  Q3 would fail on noise. Run both in one `REPEATABLE READ READ ONLY`
  transaction (one snapshot; it writes nothing, so F6's guard is not hit), or
  re-run both once on a mismatch and log only a repeat.

### F9. Small

- The migration number: `0138` is taken (`0138_messages_autovacuum.sql`); the
  last is `0143_messages_search_index.sql`, so the next free is 0144 (the
  spec already says "next free at rebase").
- 4.2 card rule: `archiveMirrorsTx` also stamps mirror rows in other topics;
  E13 should assert the mirror's topic head too, not only the card's.

## 3. Owner questions

| # | answer | why |
|---|---|---|
| Q1 triggers | **agree, with a change**: triggers, but mark immediately and apply at COMMIT, sorted (F2) | keeps the coverage argument of 4.1 and removes the deadlock class and the per-statement rebuild amplification |
| Q2 exact on expiry | **agree** | the due-head branch costs today's read only for due topics; F5 keeps the sweep that clears them short |
| Q3 shadow | **agree, with a change**: one snapshot per compare (F8) | otherwise the 0-mismatch gate fails on races |
| Q4 prd DDL go after dev | **agree**, plus: dev runs the F4/F5 cost numbers and 24 h of `pg_stat_database.deadlocks` delta = 0 before prd | the deadlock counter is the direct check of F2 |
| Q5 TaskIDs stays | **agree** | already one short probe per topic |
| Q6 budget | **change**: 5 ms p95 added on the insert AND on a claim-shape update, and the sweep chunk's head-lock time stated (F4, F5), measured on a cpu-limited container | the update path and the sweep are where the triggers cost, not the insert |
| Q7 drop ap-03/ap-09 | **agree** | both tune the walk the head removes |
| Q8 daily verify | **agree** | it is the only check for a write the triggers missed (a restore, `session_replication_role = replica`) |

## 4. tasks.md

- **T002 splits.** T002a: tables, RLS, `topic_head_subject`,
  `topic_head_rebuild` (F1 lock, F5 set-based), `topic_head_diff`; no
  triggers. T002b: the mark triggers + the deferred drain (F2), the
  first-head rebuild of the add path (F3), the tenant-gone skip (F7). T002b
  ships with T003's concurrency tests in the same push, not after.
- **T003 adds** C6 (first insert vs a move into the new topic: F1), C7
  (`InsertMirrored` vs a merge of the same two topics, 50 rounds, 0
  `40P01`: F2), C8 (an insert into a pre-DDL topic, then the backfill:
  `topic_head_diff` empty: F3), and in `TestTopicHeadInsertCost` the claim
  update and the 5 000-row sweep chunk (F4, F5), on a cpu-limited container.
  The existing hook `headDiffEmpty` covers C6..C8's assertion.
- **T004** becomes conditional: run C4 under F2 first; add the 40P01 retry
  only if a `messages`-row cycle still shows.
- **T005** shadow compare in one snapshot (F8).
- **T006** backfill per F3 (b) for `REBUILD=all`, including stale heads with no
  rows left; the triggers action's `OP=enable` runs that backfill itself.
- **T009** adds `SELECT deadlocks FROM pg_stat_database WHERE datname =
  current_database()` before and after each 24 h window to the report.

## 5. Re-running the experiments

Throwaway `postgres:16-alpine`; scripts in my session scratchpad, not
committed: `model.sql`/`trig.sql` (the spec's functions and triggers),
`fix.sql` (F1), `defer.sql` (F2), `e2.sh`/`e3.sh`/`e4.sh` (two sessions,
sleeps force the order), `ins.pgb`/`upd.pgb` (pgbench `-c 1 -t 1000`), the RLS
script. n is stated at each claim.
