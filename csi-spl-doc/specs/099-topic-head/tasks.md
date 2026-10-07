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

### T001b More fixtures and controls (no product change)

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

### T001c The lab as a committed perf cell

- Files: `store/view_topics_test.go` (`TestViewTopicsPerf`, which runs only
  under `SPOOL_TEST_PERF=1`).
- What it adds: the "narrow head" and the "walk key only" variants of
  claude-4's lab, so the phase 1 / phase 2 numbers can be re-run.
- Depends on: nothing.

### T002 rdb 0144: phase 1 tables, functions, triggers

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

### T003 The rest of the test set (spec 7.2 .. 7.5)

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

### T004 One retry on 40P01 (conditional)

- Run C4 and C4b under T002's design first. Add the retry only if a cycle
  on `messages` rows still shows.
- Files, if needed: the transaction helper call in
  `store/topic_merge_postgres.go`, `store/message_move_postgres.go` and
  `store/topic_promote_postgres.go`.
- Tests: C4, plus `topic_merge_test.go`, `message_move_test.go` and
  `topic_promote_test.go` stay green.
- Depends on: T002 and T003.

### T005 The head read, its flag and the shadow

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

### T008 Hot-measure: the head statements

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
