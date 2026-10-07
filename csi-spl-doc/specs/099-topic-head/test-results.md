# 099 Topic head: acceptance tests and their results

Step 1 of the owner rule (HUM-10, t1 5901e226 msg 86dd343f): "1. The written
spec and the run tests." This file maps every test spec.md section 7 asks for
to a file, says which ones run today, and records the runs.

## 1. What runs today: T001, the case table against the live walk

`csi-spl-api/src/go/spool-hub-api/internal/store/topic_head_harness_test.go`

- **`TestTopicHeadCases`**: one subtest per case of spec 4.3 (E01..E28, the
  undo cases E12b and E13b, and E29, E30, which spec v0.1 does not list). Each
  case seeds its own tenant (a lobby task, a #lobby topic with a card and 2
  replies, a topic in a created channel #crew, a DM topic, a child topic, an
  issue discussion with its `issues` row). It applies the case's writes
  through the store's own methods (never raw SQL), then for every list shape
  and every page (limit 3) compares the live walk `ViewTopics` with
  `refTopicsSQL`.
- **`refTopicsSQL`** is a whole-tenant aggregate that states every rule of
  spec section 2 in plain SQL: the read door per line, the order key without
  the door, the archived hide (card or any row, the lobby excepted, no expiry
  check), roots / parent= / NoIssues, the `before=` cursor and `TaskIDs`.
- **Each case asserts it did what its name says** on the plain list (for
  example E10: A has 5 lines and B is gone), so no case can pass vacuously,
  and at least 50 shapes must list a topic.
- **`TestTopicHeadReferenceControl`** shows the reference can fail. It
  breaks one rule at a time in a copy of the reference (no door per line, no
  archived hide, order key under the door) and asserts the walk then differs
  on at least one shape.
- **Shapes.** There are 3 readers (none = door off; HUM-1 in #crew; HUM-3 in
  no created channel). The places are all, #lobby, #crew and DM. The filters
  are roots, agent= (with and without a box), viewer=, parent= and NoIssues,
  plus `TaskIDs` per reader. The default grid is 288 shapes;
  `SPOOL_TEST_LONG=1` runs all 576.
- **Hooks for later tasks:** `topicHeadRead` (nil today; T005 sets it and the
  same run then compares head read == walk), and `headDiffEmpty`, which
  asserts `topic_head_diff(tenant)` is empty once T002's function exists.

### 1.1 Runs

| run | tree | config | n | result |
|---|---|---|---|---|
| full grid | base `fd504c40e` + the harness | postgres:16-alpine (docker), non-superuser CREATEROLE app role (the hub-pg.tst.sh shape), `SPOOL_TEST_LONG` grid (576 shapes) | 31 cases, 19 571 pages (3 statements each) | **PASS**, 115 s |
| default grid | same | same, 288 shapes | 31 cases, about 314 pages a case | **PASS**, 57 s |
| controls | same | same | 3 broken references | **PASS**: each was caught |
| neighbours | same | same | `TestViewTopicsMatchesOracle`, `TestViewTopicsViewerAndTenant`, `TestMixedTopicHidesTheDMHalf`, `TestTopicArchive*` | **PASS** |

Command (from `csi-spl-api/src/go/spool-hub-api`, with Go 1.25.14 on PATH):

```bash
SPOOL_TEST_PG_DSN='postgres://spool_app:spool_app@127.0.0.1:<port>/spool_hub_app?sslmode=disable' go test ./internal/store -run TestTopicHead -count=1 -v
```

### 1.2 What the run found

1. **The pre-027 oracle cannot be the third answer of spec 7.1.**
   `oracleTopicsSQL` (`store/view_topics_test.go`) has no read door, no
   archived hide and no NoIssues (`grep -cE 'archived|Reader|issues'` on
   the constant -> 0). So for every reader shape, and for every archived
   case, it differs from the walk by design. `refTopicsSQL` replaces it as
   the oracle. spec v1.0 must say so.
2. **A writer spec 4.3 does not list: `ArchiveChannel`**
   (`store/channels_postgres.go:126`). It stamps `archived_at` on the opener
   (`is_parent = 1`) of every topic in the channel, and `UnarchiveChannel`
   clears it. The triggers cover it, but the case list did not: it is now
   E29. A head that keyed `card_archived` on `msg_id = task_id` alone would
   still be right, because the walk hides on the same rule; the case pins that
   down.
3. **Archive mirrors** (`archiveMirrorsTx`, spec 067 edge 3): `SetArchived`
   also stamps a card's mirror rows. These are more rows the trigger must
   see. E13 covers them through the store call.
4. **Sweep is global.** `Sweep(now)` purges every tenant. E24 runs serially
   so it cannot purge the expired-but-unswept lines of E20..E23 while they
   run. T003's random test must do the same, or give each seed its own
   database.
5. **Cost.** At about 15 ms a page (walk + reference) on a small tenant, the
   default grid costs about 1 min of store-suite time under
   `PRE_PUSH_TIER=full`. The full grid runs only with `SPOOL_TEST_LONG=1`.

## 2. The rest of section 7: where each test lives, and why it waits

| spec | test | file | runs when |
|---|---|---|---|
| 7.1 oracle, head read == walk == reference | `TestTopicHeadCases` with `topicHeadRead` set | `topic_head_harness_test.go` (today) | T005 sets the hook |
| 7.1 stored head == rebuild | `headDiffEmpty` per case | same | T002 creates `topic_head_diff` |
| 7.1 controls: corrupt `n`, drop a party, a wrong `valid_until`; disable `topic_head_upd` -> E07 fails | `TestTopicHeadDiffControls` | `topic_head_oracle_test.go` | T003 |
| 7.2 20 seeds x 500 ops | `TestTopicHeadRandomSequences` | `topic_head_random_test.go` | T003 (`TOPIC_HEAD_SEED`, `SPOOL_TEST_LONG=1` = 200 seeds) |
| 7.3 C1..C5 | `TestTopicHeadConcurrency` | `topic_head_concurrency_test.go` | T003 (C4 needs T004) |
| 7.4 RLS + runtime role | `TestTopicHeadRLS`, plus the catalogue in `rls_failclosed_test.go` | `topic_head_rls_test.go` | T002/T003 |
| 7.5 insert cost < 5 ms p95 added | `TestTopicHeadInsertCost` | `topic_head_cost_test.go` | T003, `SPOOL_TEST_PERF=1` |
| 7.6 prd before/after | hot-measure n=20, route p50/p95 24 h, Insights | named actions | T008/T009 |
| E25 tenant delete | head rows cascade | `topic_head_rls_test.go` | T002 (nothing to compare before a head exists) |
| 3.4 subject function == Go `subjectSQL` | `TestTopicHeadSubject` | `topic_head_sql_test.go` | T002 |
