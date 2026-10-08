# 099 Topic head: tasks (v1.0)

This file decides what is built; `spec.md` v1.0 holds the design, the test
set and the panel's answers (section 10). Each task is one lane: one agent,
the files it owns, the tests that prove it, and its dependencies.

The build starts on this version (owner rule 2026-10-05: consensus starts the
build, and the owner reviews after). Every prd step still needs the owner's go
(Q4).

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`api/` = `csi-spl-api/src/go/spool-hub-api/`, `store/` =
`api/internal/store/`, `orc/` = `csi-spl-orc/src/bash/run/`,
`orct/` = `csi-spl-orc/src/bash/tests/`.

## Rules for every task

- Run `do_check_pre_push` before every push and again after the rebase.
  Every task here runs it with `PRE_PUSH_TIER=full`, because all of them
  touch `rdb/` or `store/` and run on Postgres.
- **DDL first.** T002 is applied on dev, and on prd through c-001 with the
  owner's go, before any hub task that reads the tables reaches that env.
  The hub never needs the tables: it probes for them (and for the tenant's
  backfill mark) and otherwise stays on the walk.
- The hub's JSON for `GET /v1/view/topics` stays byte-identical in every
  mode.
- New Go functions stay under the clean-code gate: 80 lines, depth 4,
  8 params.
- The whole 099 test set must fit 3 min in the pre-push tier. Long variants
  run nightly (T007).
- Keep the read serial with ap-03 and ap-09, which touch the same file,
  `view_postgres.go`: neither runs while T005 is open (spec Q7).
- No literal domain or host. The `/version` probe in T006 reads the host
  from cnf.

## Order

```
T001 (done) ─► T001b fixtures + controls ─► T002 rdb 0144 phase 1 ─┬─► T003 random + concurrency + RLS + cost
                                                                    ├─► T004 40P01 retry (only if C4 shows a cycle)
                                                                    ├─► T006 actions ─► T007 daily verify, restore, nightly
                                                                    └─► T005 head read + flag + shadow ─► T008 hot-measure
                                                                                                         └─► T009 rollout (c-001, owner go)
                                                                                                              └─► T010 phase 2 decision (Q9)
```

T001b, and T001c (the perf cell), need no product change and may run in
parallel with T002.

## Tasks

### T001 Case table vs the live walk (DONE, `a44a267b4`)

- What landed: `store/topic_head_harness_test.go`.
  - `TestTopicHeadCases` runs E01..E30. For each case, the walk equals
    `refTopicsSQL` on 288 shapes and every page.
  - `TestTopicHeadReferenceControl` runs 3 controls.
  - Two hooks: `topicHeadRead` and `headDiffEmpty`.
- Results: `test-results.md`.

### T001b More fixtures and controls (DONE, `c613cb647`)

- Files: `store/topic_head_harness_test.go`.
- What it adds:
  - E28 rewritten: 5 tied topics, and a page boundary inside the tie.
  - E20p: a due topic exactly at a page boundary.
  - E31..E41:
    - E31: a card that has left its topic is archived.
    - E32: one agent on two boxes.
    - E33: a child topic whose first line is in a created channel.
    - E34: a duplicate resend.
    - E35 and E35b: a DM card with a mirror is archived, then unarchived.
    - E36: a mirrored line is edited.
    - E37: a channel is unarchived.
    - E38: a topic that has a child is merged.
    - E39: an archived reply is moved.
    - E40: two lines at the same instant in one topic.
    - E41: an insert into a topic whose head rows are deleted. Today it is
      the same as E01; from T002 on it is a head miss.
  - Reference controls with paging, each a hard assertion on its case:
    - tie-break ASC;
    - cursor ignores the task;
    - card rule dropped;
    - agent box ignored;
    - first parent under the door.
- Test: green against today's walk, and each control is caught.
- Depends on: nothing.
- Result (Postgres 16, `c613cb647`, n=1 run): `TestTopicHeadCases` 44 cases
  green; `TestTopicHeadReferenceControl` pages every shape, and all 8
  controls are caught: tie-break ASC on E28 page 0, cursor ignores the task
  on E28 page 1, card rule on E31, agent box on E32 (`agent=AGT-1@box-a`),
  first parent on E33 (reader HUM-3, `parent=`).

### T001c The lab as a committed perf cell (DONE)

- Files: `store/view_topics_test.go` (`TestViewTopicsPerf`, which runs only
  under `SPOOL_TEST_PERF=1`).
- What it adds: the "narrow head" and the "walk key only" variants of
  claude-4's lab, so the phase 1 / phase 2 numbers can be re-run.
- What landed: the cell `TestViewTopicsPerf/head099` (`perfHeadLab`). It
  times today's walk (`walk`), the narrow head plus today's `summary()`
  (`head`), and the head walk alone (`key`). Before timing, it checks that
  the head rows equal the walk's.
  Run it alone with `-run 'TestViewTopicsPerf/head099'`.
- First run: tree `6cc79253` plus this cell, pg 16.15 (docker, non-superuser
  app role), 22k messages over 1 500 topics, 380 archived, n=20 after 3
  warm-ups, one seed. p50 / p95 in ms:

  | shape | walk | head | key |
  |---|---|---|---|
  | `dm=true`, reader HUM-1, limit 51 | 145.0 / 203.4 | 52.1 / 60.1 | 42.8 / 58.0 |
  | all, reader HUM-1, limit 51 | 173.1 / 240.5 | 54.0 / 62.9 | 51.0 / 59.5 |
  | `channel=c1`, limit 21 | 56.7 / 69.8 | 27.1 / 37.2 | 26.1 / 34.7 |
  | `dm=true&peer=AGT-1`, reader HUM-1, limit 21 | 286.1 / 379.4 | 52.7 / 64.6 | 49.9 / 70.1 |

  The rows were equal on all 4 shapes. The absolute numbers are higher than
  in claude-4's lab. This run's box was loaded (`uptime`: load 129 on 16
  cores), and it used another seed and another reader channel set.
  Compare the ratios, not the times: `head` cuts p50 2.1..5.4x, and `key`
  is only 1..10 ms below `head`.
- Depends on: nothing.

### T002 rdb 0144: phase 1 tables, functions, triggers (DONE)

- Files: `rdb/<next>_topic_heads.sql` (0144 on 2026-10-07; take the next
  free number at rebase) and `store/topic_head_sql_test.go`.
- What the migration creates:
  - Tables `topic_heads`, `topic_head_parts` (with `dm_a`/`dm_b`) and
    `topic_head_tenants`, each with RLS (spec 3.1..3.4).
  - Functions:
    - `topic_head_apply_marks`: the drain, sorted;
    - `topic_head_add`: incremental, and rebuilds on a head miss;
    - `topic_head_rebuild(set)`: set-based, with the head row as the lock
      (placeholder plus FOR UPDATE), and a READ COMMITTED guard;
    - `topic_head_diff`;
    - `topic_head_backfill(chunk, rebuild_all, after)`: a keyset walk that
      sets each tenant's mark.
  - Triggers: the row-level marks `topic_head_mark_ins`,
    `topic_head_mark_upd` (`UPDATE OF .. WHEN`) and `topic_head_mark_del`,
    plus the deferred constraint trigger `topic_head_apply`.
  - The drain skips a topic whose tenant is gone.
- Tests:
  - The migration applies through the migrate path.
  - One insert writes one head and one part.
  - An update of a column that is not a head column leaves `rev` unchanged
    (`TestTopicHeadNonHeadUpdatesKeepRev`).
  - `TestTopicHeadDiffDetectsEveryColumn` and `TestTopicHeadTriggerControls`
    (spec 7.1).
  - The race tests in the same push as the triggers: C6 (first insert vs a
    move into the new task), C7 (`InsertMirrored` vs a merge, 0 `40P01`) and
    C8 (an insert into a pre-DDL topic, then the backfill).
  - `TestTopicHeadCases` with `headDiffEmpty` now active: every case has an
    empty diff.
  - `rls_failclosed_test.go` stays green with the three new tables.
- Note for later migrations: a migration that updates `messages` marks its
  topics, and the apply runs once at its COMMIT.
- Depends on: T001b. The owner's go is needed for prd (Q4).
- Result (pg 16, the owner role FORCE RLS binds, as `hub-pg.tst.sh`):
  - `TestTopicHeadCases` 44 cases green, `topic_head_diff` empty after
    every case; the test now fails if the function is missing.
  - `topic_head_sql_test.go`: migrate twice; one insert = one head + one
    part; 8 non-head statements leave every `rev` (control: an `expires_at`
    update moves it); 19 corruptions, each named by the diff; 4 trigger
    controls caught, 3 baselines clean; REPEATABLE READ refused at COMMIT;
    C6 10 rounds, C7 50 rounds with 0 `40P01`, C8 with the backfill and
    `rebuild_all`.
  - `crosstenant_test.go` seeds `topic_head_tenants`. Heads and parts are
    seeded by the triggers.
- Design changes found by the whole store package. A first cut timed it out
  at 10 min, against 304 s on trunk:
  - **INSERT and DELETE mark per statement** (transition tables), not per
    row: one append per bulk statement or sweep chunk. UPDATE stays per row
    with `UPDATE OF .. WHEN`.
  - **Marks in 8 KB chunks** (`app.topic_head_marks_<i>`). A 9 000-row,
    9 000-topic UPDATE took 11.7 s with one string, and 1.9 s with chunks.
  - **Every table read is driven from the topic set by LATERAL index
    probes, and heads are written by upserts.** Under RLS and fresh
    placeholders the planner read `topic_heads` as 1 row. A nested loop
    then took 40.5 M probes, and one 9 000-row INSERT's COMMIT took 22.1 s.
    It now takes 1.7 s, and `TestFlowMarkSweepPostgres` takes 4.29 s
    (trunk 4.96 s).
- Rollout: wf 20 runs `do_spl_db_bootstrap` on dev AND prd for any push
  touching `spool-hub/**`, so landing 0144 is its prd DDL. The owner gave
  that go on 2026-10-07, with no 24 h soak (t1 5901e226, msg 43ab3e20).
- Open for T005/T006: a tenant created after the backfill has no
  `topic_head_tenants` mark, so the head read never serves it until the
  backfill runs again.

### T003 The rest of the test set (spec 7.2 .. 7.5) (DONE)

- Files (all new):
  - `store/topic_head_random_test.go`;
  - `store/topic_head_concurrency_test.go`;
  - `store/topic_head_rls_test.go`;
  - `store/topic_head_cost_test.go`.
- Tests:
  - The random sequences: 4 seeds x 300 operations by default. Operations
    draw from sorted slices, and the purge is tenant-scoped.
  - C1, C1b, C2..C5, C4b and C9.
  - The RLS, runtime-role, operator and cross-tenant cases.
  - `TestTopicHeadCost` under `SPOOL_TEST_PERF=1`: n >= 200, interleaved,
    on a CPU-limited postgres. It covers the insert, a claim update, a sweep
    chunk's head-lock hold, contention, a hot topic and a bulk insert. The
    gates are in spec 7.5.
- Depends on: T002.
- Result (pg 16 in docker, the owner role FORCE RLS binds, runtime role
  `spool_rt`; the host was loaded: load average 15..48 on 16 cores):
  - `TestTopicHeadRandomSequences`: 4 seeds x 300 ops, 16 writers (E01..E36,
    the clock, a tenant-scoped purge chunk). Per seed 189..207 ops applied
    (the rest refused by the store: a line already gone, a merge cycle);
    the diff is empty after every op, 16 shapes every 25 ops, the full grid
    at the end. A seed replays (`TOPIC_HEAD_SEED=3 TOPIC_HEAD_OPS=120`
    twice: the same tally). About 40 s.
  - Concurrency: C1 (2 x 200 inserts), C2 and C3 (5 rounds each), C4
    (50 rounds, 100 merge calls: 99..100 ok, 0..1 store refusal, **0
    `40P01`**), C4b (20 lockstep rounds, 0 `40P01`; its control, the drain
    made IMMEDIATE per statement as v0.1, deadlocks), C5 (a 5 000-row purge
    chunk over 1 000 topics against 100 inserts) and C9. C1b runs in the
    cost test only, because it toggles the triggers for the whole database.
  - `TestRLSTopicHeadScopes` (in the hub-pg `^TestRLS` gate),
    `TestTopicHeadRuntimeRole` (E01, E07, E13, E16, E18 and E25 as
    `spool_rt`), `TestTopicHeadOperatorWrites` (the Sweep, the orc topic
    delete, the orc wipe) and `TestCrossTenantTopicHeads`. Each has a
    control: FORCE RLS lifted, INSERT on the parts revoked, t1's own move.
  - Guard-removal controls, run on scratch migrations (n = 1 run each):
    - no `FOR UPDATE` in `topic_head_lock`: C4 and C4b fail. C1, C2, C3, C5,
      C6 and C9 stay green, because the upserts' ON CONFLICT row locks
      still serialize those writers;
    - no `topic_head_mark_del`: the random test (all 4 seeds), C5, the
      operator test and the runtime-role test fail;
    - no archived mark in `topic_head_mark_upd`: all 4 random seeds fail;
    - head locks in random order: C4b and C7 fail, and C4 does not.
  - **C4 verdict: T004 is not needed.** There were 0 `40P01` in 100 cross
    merges and in 20 lockstep rounds, while the controls show that both
    tests can see a cycle.
  - `TestTopicHeadCost` (`SPOOL_TEST_PERF=1`, run alone): **3 of the 4
    gates fail.** The table is the 1-CPU run (`--cpus=1`, load 18..38).
    Times are ms, as on / off / added:

    | cell | n | p50 | p95 | gate |
    |---|---|---|---|---|
    | one insert | 200 / 200 | 18.9 / 10.5 / +8.3 | 36.2 / 20.3 / +15.9 | FAIL (< 5) |
    | claim-shape UPDATE | 200 / 200 | 5.2 / 5.3 / -0.1 | 9.5 / 10.6 / -1.1 | PASS |
    | 5 000-row purge chunk, whole | 5 / 5 | 12 664 / 13 172 | 15 855 / 16 337 | printed |
    | its head-lock hold (COMMIT) | 5 | 308 | max 532 | FAIL (<= 100) |
    | C1b, per insert | 2 000 / 2 000 | 38.8 / 12.4 / +26.5 | 68.6 / 29.0 / +39.7 | FAIL (< 5) |
    | hot topic, one insert | 20 / 20 | 20.4 / 10.0 / +10.5 | 32.9 / 23.2 / +9.7 | printed |
    | bulk 1 000 rows, 100 topics | 5 / 5 | 498 / 217 / +281 | 591 / 276 / +316 | printed |

    The 2-CPU rerun (load 38..48) gives the same verdicts: insert +18.8,
    hold max 470 and C1b +44.0 at p95. Without the triggers, the purge
    chunk alone takes 13 s. That time is the DELETE, not the heads.
    Per spec 7.5, the purge gets its own smaller chunk. Rerun the insert and
    C1b gates on an idle host before T005 is decided.

### T004 One retry on 40P01 (conditional)

- Run C4 and C4b under T002's design first. Add the retry only if a cycle
  on `messages` rows still shows.
- Files, if needed: the transaction helper call in
  `store/topic_merge_postgres.go`, `store/message_move_postgres.go` and
  `store/topic_promote_postgres.go`.
- Tests: C4, plus `topic_merge_test.go`, `message_move_test.go` and
  `topic_promote_test.go` stay green.
- Depends on: T002 and T003.

### T005 The head read, its flag and the shadow (DONE, `f495e7cc`; default off on dev and prd)

- Files:
  - `store/view_topics_head.go` (new): `viewTopicsHeadSQL` (the head walk
    plus today's `summary()`), the due-head second statement (`listed()` fed
    by the due heads, or the due parts for a channel), the Go merge, and its
    own batch header.
  - `store/view_postgres.go`: `ViewTopics` picks the builder; nothing else
    in the file changes.
  - `store/clones.go`: the same pick in `ViewTopicsUnlessClone`.
  - `api/internal/config/config.go`: `SPOOL_HUB_TOPIC_HEADS` and
    `SPOOL_HUB_TOPIC_HEADS_SAMPLE` (default 1).
  - `api/internal/hub/view.go`: the shadow, which runs both reads in one
    `REPEATABLE READ READ ONLY` transaction, compares the hub JSON bytes,
    and logs `topic_head_mismatch` and a 10-minute `topic_head_shadow`
    counter.
  - `api/internal/hub/server.go`: `topic_heads` in `GET /version`.
- Tests:
  - `TestTopicHeadCases` with `topicHeadRead` set: head read == walk ==
    reference, for every case, shape and page.
  - The random test adds the head read to its every-25-operations check.
  - `TestTopicHeadReadFallsBackUntilBackfilled`.
  - The order of the uuid vs `task_id::text` on the test DB, with the edge
    ids `0…`, `9…`, `a…` and `f…`.
  - The existing view tests stay green in `off` and in `on`:
    `view_topics_test.go`, `view_topics_subject_test.go`,
    `topic_archive_test.go`, `mixed_topic_door_test.go`, `view_test.go` and
    `internal/hub/channels_test.go`.
  - A hub test that the `/v1/view/topics` JSON is byte-identical in `off`
    and `on`.
  - A hub test that `shadow` serves the walk's bytes and logs one mismatch
    for a hand-corrupted head.
  - An A/B of the batch header (`enable_sort`, bitmap scans) per shape,
    n=20, at 20k and 200k messages.
- Depends on: T003, and T006's verify printing 0 mismatches on dev.

### T006 Named actions: backfill, verify, triggers, shadow report

- Files: `orc/spl-topic-head-backfill.func.sh`,
  `orc/spl-topic-head-verify.func.sh`, `orc/spl-topic-head-triggers.func.sh`
  and `orc/spl-topic-head-shadow-report.func.sh`, each with its
  `orct/*.tst.sh`.
  - All run as the env SA through the proxy, the same path as
    `do_spl_db_bootstrap`.
  - The backfill takes chunks of 100, `lock_timeout 5s`, and `REBUILD=all`.
  - The triggers action takes `OP=disable|enable`. It refuses unless
    `/version` reports `topic_heads: off`, and `enable` runs
    `REBUILD=all` itself.
- Also: the existing pg tests `msg-dedup`, `topic-delete`, `demo-wipe` and
  `msg-wipe` assert `topic_head_diff` is empty after their run, once 0144
  exists.
- Tests:
  - The four `.tst.sh` with a stubbed psql / curl: the chunk loop stops on
    an empty chunk; verify exits 1 on one mismatch; triggers refuses when the
    flag is not `off`; the report counts compares and mismatches.
  - One run of each against a local postgres:16-alpine with 0144 applied.
- Depends on: T002.

### T007 Daily verify, restore rebuild, nightly long run

- Files:
  - `.github/workflows/45_db-backup.yml`: one step,
    `do_spl_topic_head_verify` against the restored throwaway container, per
    env.
  - `orc/spl-db-restore.func.sh`: after a restore into an env, it runs
    `REBUILD=all do_spl_topic_head_backfill` (`TARGET=env` only).
  - A nightly job runs `SPOOL_TEST_LONG=1 go test -run TestTopicHead` (200
    seeds, the full grid).
- Tests: the restore action's `.tst.sh` asserts the call, and the workflow
  lint passes.
- Depends on: T006.

### T008 Hot-measure: the head statements (DONE, `36e748d5`)

- Files: `orc/spl-db-hot-measure.func.sh` and its `.tst.sh`.
  - New statements: `walk_dm_head`, `walk_all_head`, a worst reader (a
    reader in no DM) and `parent=`.
  - The head builder prints them through ap-00's `stmt_print_test.go`, and
    the drift gate covers them.
- Tests: the drift gate is green, and the printed md5 equals the builder's.
- Depends on: T005, and ap-00 landed.

### T009 Rollout on dev, then prd (c-001 runs prd, with the owner's go)

- No files. The steps of spec section 8 and the numbers of spec 7.6.
- On dev:
  1. The DDL.
  2. The backfill.
  3. The verify: n topics, 0 mismatches.
  4. `shadow`.
  5. `pg_stat_database.deadlocks` delta of 0 over 24 h.
- On prd: the same steps. The shadow runs until n >= 500 compares over all
  six shapes with 0 mismatches, and for at least 24 h. Read it with
  `do_spl_topic_head_shadow_report`.
- The due set is counted hourly for a day through `do_spl_db_query`.
- The before-numbers:
  - hot-measure, n=20, twice;
  - the routes' p50/p95 over 24 h;
  - the Insights insert mean.
- Then `on`, and the after-numbers from that 24 h window, plus heads visited
  per row and `summary()`'s share per shape.
- Report: one post with the before/after table (n, span, version, sha).
- Depends on: T005, T006 and T008.

### T010 The phase 2 decision (Q9)

- No files. From T009's numbers: does any list shape stay above 100 ms p50
  over 24 h on prd?
  - **No:** phase 2 is not built. ap-03 is dropped, and ap-09 is
    re-measured once and then dropped or kept on its own numbers.
  - **Yes:** write the phase 2 tasks from spec section 9. `Kinds` as counts
    comes first, as its own task.
- The result is reported to the owner as information.
- Depends on: T009.
