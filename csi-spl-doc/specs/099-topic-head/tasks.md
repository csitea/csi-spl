# 099 Topic head: tasks

Authority for what is built (`spec.md` holds the design, the test set and the
owner's questions, section 10). Each task is one lane: one agent, the files it
owns, the tests that prove it, its dependencies. Nothing here starts before
the owner answers Q1..Q8 ("as proposed" is enough), and not before ap-00
(the hot-measure action) has landed.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`api/` = `csi-spl-api/src/go/spool-hub-api/`, `store/` =
`api/internal/store/`, `orc/` = `csi-spl-orc/src/bash/run/`,
`orct/` = `csi-spl-orc/src/bash/tests/`.

## Rules for every task

- `do_check_pre_push` before every push and after the rebase;
  `PRE_PUSH_TIER=full` for every task here (all touch `rdb/` or `store/`
  and run on Postgres).
- **DDL first.** T002 is applied on dev, and on prd through c-001 with the
  owner's go, before any hub task that reads the tables reaches that env.
  The hub never needs the tables: it probes for them and stays on the walk.
- The hub's JSON for `GET /v1/view/topics` stays byte-identical in every mode.
- New Go functions stay under the clean-code gate (80 lines, depth 4,
  8 params).
- Serial with ap-03 and ap-09 (same file, `view_postgres.go`): neither runs
  while T005 is open (spec Q7).

## Order

```
T001 test harness ─► T002 rdb 0138 + functions ─► T003 oracle + random + RLS + concurrency tests
                                       │
                                       ├─► T004 40P01 retry (move/merge)
                                       ├─► T006 backfill + verify + triggers actions ─► T007 daily verify, restore rebuild
                                       └─► T005 head read + flag (off|shadow|on) ─► T008 hot-measure head statements
                                                                                   └─► T009 prd rollout (c-001, owner go)
```

## Tasks

### T001 Test harness for heads (no product change)

- Files: `store/topic_head_harness_test.go` (new): the case table E01..E28
  (spec 4.3) as data, each a seed plus a list of store calls; a `compareAll`
  helper running every `topicQueries()` shape and page through `viewTopicsSQL`
  and `oracleTopicsSQL` with `sameRows`.
- Test: on today's code every case passes walk == pre-027 oracle (proves
  the case table is right before any head exists).
- Depends on: nothing.

### T002 rdb 0138: tables, functions, triggers

- Files: `rdb/0138_topic_heads.sql` (number: next free at rebase).
  `topic_heads`, `topic_head_parts` (spec 3.1, 3.2) with RLS (3.3);
  `topic_head_subject`, `topic_head_add`, `topic_head_rebuild`,
  `topic_head_diff`, `topic_head_backfill(chunk)`; triggers
  `topic_head_ins`, `topic_head_upd`, `topic_head_del` (4.2).
- Tests: `store/topic_head_sql_test.go` (new): the migration applies twice
  through the migrate path (idempotent where the file says so);
  `topic_head_subject` equals Go `subjectSQL` on the
  `view_topics_subject_test.go` bodies plus n >= 2 000 random unicode
  bodies; one insert writes one head and one part; an update of a column
  that is not a head column rebuilds nothing (assert `rev` unchanged);
  `rls_failclosed_test.go` stays green with the two new tables in its
  catalogue.
- Depends on: T001. Owner go for prd (Q4).

### T003 The test set (spec 7.1 .. 7.5)

- Files: `store/topic_head_oracle_test.go`, `store/topic_head_random_test.go`,
  `store/topic_head_concurrency_test.go`, `store/topic_head_rls_test.go`
  (all new).
- Tests: every E01..E28 case `topic_head_diff` empty after its writes, plus
  the three controls (7.1); 20 seeds x 500 ops (7.2); C1..C5 (7.3); the RLS
  and runtime-role cases (7.4); `TestTopicHeadInsertCost` under
  `SPOOL_TEST_PERF=1`, added p95 < 5 ms n=20 (7.5).
- The head-read half of the oracle (head read == walk) is added in T005;
  here the oracle is "stored head == rebuild".
- Depends on: T002.

### T004 One retry on 40P01 for the two-topic writers

- Files: `store/topic_merge_postgres.go`, `store/message_move_postgres.go`,
  `store/topic_promote_postgres.go` (the transaction helper call only).
- Tests: C4 in `topic_head_concurrency_test.go` passes; `topic_merge_test.go`,
  `message_move_test.go`, `topic_promote_test.go` green.
- Depends on: T002.

### T005 The head read and its flag

- Files: `store/view_topics_head.go` (new: `viewTopicsHeadSQL`, the due-head
  branch reusing `listed()` + `summary()`), `store/view_postgres.go`
  (`ViewTopics` picks the builder; nothing else in the file),
  `store/clones.go` (`ViewTopicsUnlessClone` the same), `api/internal/config/config.go`
  (`SPOOL_HUB_TOPIC_HEADS`, `SPOOL_HUB_TOPIC_HEADS_SAMPLE`), the shadow
  compare and its `topic_head_mismatch` log in `api/internal/hub/view.go`.
- Tests: `TestTopicHeadMatchesWalk` (7.1, head read == walk == pre-027 oracle
  for E01..E28, every shape, every page); the random test adds the head read
  to its every-25-ops check; `view_topics_test.go`,
  `view_topics_subject_test.go`, `topic_archive_test.go`,
  `mixed_topic_door_test.go`, `view_test.go`, `internal/hub/channels_test.go`
  green in `off` and `on`; a hub test that `shadow` serves the walk's bytes and
  logs one mismatch for a hand-corrupted head.
- Depends on: T003.

### T006 Named actions: backfill, verify, triggers

- Files: `orc/spl-topic-head-backfill.func.sh`, `orc/spl-topic-head-verify.func.sh`,
  `orc/spl-topic-head-triggers.func.sh` (`OP=disable|enable`, refuses unless
  the hub's live revision has the flag at `off`) and their `orct/*.tst.sh`.
  As the env SA through the proxy, the same path as `do_spl_db_bootstrap`.
- Tests: the three `.tst.sh` with a stubbed psql (chunk loop stops on an empty
  chunk; verify exits 1 on one mismatch; triggers refuses with the flag on);
  one run each against a local postgres:16-alpine with 0138 applied.
- Depends on: T002.

### T007 Daily verify, rebuild after a restore

- Files: `.github/workflows/45_db-backup.yml` (one step: `do_spl_topic_head_verify`
  per env), `orc/spl-db-restore.func.sh` (after a restore:
  `REBUILD=all do_spl_topic_head_backfill`).
- Tests: the restore action's `.tst.sh` asserts the call; the workflow lint.
- Depends on: T006.

### T008 Hot-measure: the head statements

- Files: `orc/spl-db-hot-measure.func.sh` and its `.tst.sh` (`walk_dm_head`,
  `walk_all_head`, printed by the head builder through ap-00's
  `stmt_print_test.go`; the drift gate covers them).
- Tests: the drift gate is green; the printed md5 equals the builder's.
- Depends on: T005 and ap-00 landed.

### T009 Rollout on dev, then prd (c-001 runs prd, owner's go)

- No files. Steps and numbers of spec section 8 and 7.6: dev DDL (0138),
  backfill, verify (n topics, 0 mismatches), hub `shadow` 24 h; the due-set
  count on prd (`SELECT count(*) FROM topic_heads WHERE valid_until <= now()`,
  through `do_spl_db_query`); prd the same; before-numbers (hot-measure walk_dm /
  walk_all n=20 twice, routes p50/p95 24 h with `ROUTE_LIMIT=200000`,
  Insights insert mean); `on`; the after-numbers in the 24 h window.
- Report: one post with the before/after table (n, span, version, sha).
- Depends on: T005, T006, T008.
