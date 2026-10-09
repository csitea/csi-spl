# 113 Workspace documents: tasks

Authority for what is built. `spec.md` holds the behaviour; this file
follows its sections 2-7. Each task names its layer, its dependency, the
files it owns, the sibling-project routine it ports (where it ports one), a
Done line (what runs, what it prints, and a control that must fail), a
vendor hint (spec 110 D5: doc and low-level = mistral, hardest coding and
secrets = claude, multilingual text = agy review last) and a box hint (new
lanes are placed by the orchestrator; Postgres tests need the box's docker
Postgres, browser e2e needs Chrome or runs in CI on the mock bundle).
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial /
in progress, `[x]` Planned).

Version **v1.0** (2026-10-09), matching spec v1.0.

"The sibling's" below = the sibling project's Perl API, read-only on this
box under its `src/perl/.../lib` tree. Port the behaviour, never its names,
paths or hosts, and never its nested-set arithmetic (spec section 3.6).

Order: T001 (DDL, applied to dev and prd first) -> T002 (store ops,
property, concurrent and timing tests) -> T003 (check / repair) and T004
(hub API) -> T005 (xls), T006 (WUI) and T007 (agents) -> T008 (export,
phase 2). T002's tests gate everything after it. T000b is independent.

## 1. Documentation and evidence

- [x] **T000**: `spec.md` + this file, v1.0 (the 24 seat changes folded,
  spec section 11), and the benchmark under `bench/`.
  - Depends: none.
  - Owns: `csi-spl-doc/specs/113-workspace-docs-qto/spec.md`, `tasks.md`, `bench/`.
  - Done: `grep -cE '^## 1[01]\.' spec.md` -> 2 (one each); `bash bench/tree-bench.sh` prints the spec 2.1 table with n = 5 and exits 0. Control: each model's planted broken row is reported as `CONTROL <model> caught` in the raw output (6 of 6).
- [ ] **T000b**: the bench gains a 1 x 10,000 wide-parent case (spec 2.1, seat 4 change 1).
  - Depends: none.
  - Owns: `bench/common.sql` (a wide seed), `bench/tree-bench.sh` (the case), a new `bench/result-<date>.md` + `raw-<date>.txt`.
  - Done: `BENCH_REPS=5 bash bench/tree-bench.sh` prints a row per model at 1 x 10,000 (insert first, append, move, read); adj insert-first lands in the 200-ms range seat 4 measured (218-233 ms, n = 3). Control: a planted gap in the wide seed is reported `CONTROL adj caught`.
  - Vendor: mistral (low-level sql/bash). Box: one with docker.

## 2. Data model

- [x] **T001**: migration `<next>_workspace_docs.sql` (spec 2.2, 2.3, 3.2).
  - Depends: none. Applied to dev and prd before T002 ships (DDL first).
  - Owns: `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_workspace_docs.sql` (*new*; claim the number at build time), its SQL test.
  - Ports: the sibling's SQL test hierarchy table and its `*_doc` tables, as the column list only (they carry no constraint to port).
  - Content: `workspace_doc` with UNIQUE (tenant_id, id); `workspace_doc_item` with UNIQUE (tenant_id, doc_id, id), the composite FKs (tenant_id, doc_id) -> doc and (tenant_id, doc_id, parent_id) -> item ON DELETE RESTRICT, the partial unique root index, CHECK (ord >= 1), CHECK (parent_id IS NOT NULL OR ord = 1), UNIQUE (doc_id, parent_id, ord) DEFERRABLE INITIALLY IMMEDIATE; `workspace_doc_rev_log` UNIQUE (doc_id, rev), no UPDATE/DELETE grant; ENABLE and FORCE RLS + the `NULLIF` tenant and `operator_scope` policies (0107 shape) on all three; the deferred item trigger (AFTER INSERT, UPDATE OF (parent_id, ord, doc_id), DELETE; doc row `FOR UPDATE` first; OLD and NEW parent; count = 0 valid; `doc_id` change refused; cycle walk; once per (doc, parent) per tx) and the deferred root-required trigger on `workspace_doc` INSERT.
  - Done: the SQL test refuses a gap (incl. one left under OLD.parent_id by a delete), an overlap, a cycle, a second root, a doc without a root, a `doc_id` change and a cross-tenant `doc_id` insert, each printing the constraint or trigger name; deleting a last child passes (9c, 9e). Controls: the same writes with the trigger dropped commit; a raw-SQL writer that skips the doc lock (seat 5's tx1/tx2 repro) is refused at commit, 3 of 3 runs.
  - Vendor: claude. Box: one with docker Postgres.

## 3. Store

- [x] **T002**: the structural ops of spec 3.3 in Go (pgx, under RLS), each one transaction, plus the subtree reader and the three tests of spec 3.5.
  - Depends: T001.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs*.go` (*new*) and their `_test.go`.
  - Ports: the sibling's DB writer hierarchical insert (~l.291-422) -> `DocItemAdd(sibling|parent|child)`; its hierarchical delete (~l.203-290) -> `DocItemDeleteSubtree` (refuses the root); its single-column update (~l.557) -> `DocItemUpdateField` (allow-listed column, `WHERE id AND rev`, 0 rows -> 404 if gone else 412); its DB reader branch select -> `DocSubtree` (recursive CTE, outline number derived) and `DocChildren` (one node's children + ancestors' ord path); new: `DocItemMove`, which refuses a target inside the moved item's own subtree (I3).
  - Rules: doc row `FOR UPDATE` requiring exactly 1 row (0 -> 404, rollback); positions read after the lock; append at `max(ord) + 1`; shifts in one statement or under `SET CONSTRAINTS .. DEFERRED`, never `ord = -1` parking (the bench's `adj_move` is not the code to copy); the rev bump and its rev-log entry in the same tx; each op returns its outcome (committed + rev, 412, 404, refused); the doc lock is taken before any item row and reused by nested calls.
  - Done: `go test ./internal/store -run 'WorkspaceDoc'` on testkit Postgres runs (a) the property test, >= 5,000 random ops x 5 seeds, invariants + model tree after every step; (b) the concurrent test, 8 writers x 500 mixed ops, printing committed / 412 / 404 / refused, lock waits and `deadlock_detected`, replaying the rev log into the model; (i) the timing test at 11,111 items, 1 x 1,000 and 1 x 10,000 siblings, n = 5, median and max per op. Green means: invariants hold, model matches, lock waits > 0, deadlocks = 0, every op <= 50 ms at 11,111 items and 1 x 1,000 siblings. Controls, each behind a test-only switch and each turning the run red with the replay seed printed: a delete that skips the gap close; a move that reads positions before the lock; a store that ignores the lock's row count.
  - Vendor: claude. Box: one with docker Postgres.

## 4. Operations

- [x] **T003**: `do_spl_doc_tree_check`, `do_spl_doc_tree_repair` (spec 3.4), per-env SA, each with its `.tst.sh`.
  - Depends: T001 (T002 for the repair's lock helper, if shared).
  - Owns: `csi-spl-orc/src/bash/run/spl-doc-tree-check.func.sh`, `csi-spl-orc/src/bash/run/spl-doc-tree-repair.func.sh` (*new*), `csi-spl-orc/src/bash/tests/spl-doc-tree-check.tst.sh`, `csi-spl-orc/src/bash/tests/spl-doc-tree-repair.tst.sh` (*new*).
  - Done: `ENV=dev ./run -a do_spl_doc_tree_check` sets the operator scope and prints `violations=0 docs=<n> items=<n>`, exit 0. On a test DB with one planted gap and one unreachable cycle it prints both violations and exits 1; `DRY_RUN=0 do_spl_doc_tree_repair` (one tx under the doc lock) prints `renumbered=1 reattached=1` with the cut item's id and the check returns to `violations=0` (9d). Controls: a run without the operator scope sees `docs=0` and exits 2; `EXPECT_EMPTY=1` makes it exit 0. Repair `DRY_RUN=0` on prd is an owner go.
  - Vendor: mistral (low-level bash), claude reviews the SQL. Box: one with docker Postgres.

## 5. Hub API, xls, WUI, agents

- [x] **T004**: hub Go API: doc tree CRUD (doc view), list/grid CRUD (grid view), the four outcomes, spec 100 search indexing, topic link.
  - Depends: T002.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs.go` (*new*) + test.
  - Ports: the sibling's doc-view controller, grid (list) controller and the hierarchy create / delete / select controllers, onto the T002 store ops.
  - Done: `go test ./internal/hub -run WorkspaceDoc` green: the lazy route returns one node's children plus the ancestors' ord path; a whole-doc grid sort/filter returns the outline in document order up to 20,000 items and 413 above; a stale-rev write gets 412, a write to a deleted item 404. Control: a cross-tenant request returns 0 items and its structural op a 404 (9e).
  - Vendor: claude. Box: one with docker Postgres.
- [x] **T005**: xls import/export: grid <-> xlsx.
  - Depends: T002.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs_xls.go` (*new*) + test.
  - Ports: the sibling's xls import (xls -> table/DB) and export (DB -> xls).
  - Done: an import builds the tree through T002's ops only, in ONE transaction that takes the doc lock once at the top (nested op calls reuse it); export then import of a 3-level doc round-trips to the same outline md5. Control: an xlsx row whose parent number does not exist is refused with its row number and nothing is written.
  - Vendor: claude. Box: any with docker Postgres.
- [x] **T006**: WUI `WorkspaceDocView` and `WorkspaceGridView`, lazy (one node's children per load); doc view context menu (add sibling / parent / child, move, indent / outdent, delete branch, print branch via standard print CSS, D-Q2); grid inline edit, filter, sort; i18n.
  - Depends: T004.
  - Owns: `csi-spl-wui/src/pages/workspace/docs.vue` (*new*), components under `csi-spl-wui/src/components/workspace-docs/` (*new*), their locale keys.
  - Done: `pnpm run typecheck` and the e2e drive add/move/delete in both views and read the same outline back; a 412 shows a reload prompt. Control: the initial-chunk budget test fails on an initial JS delta > 100 B (9g).
  - Vendor: claude; agy reviews the locale text last. Box: Chrome, or CI on the mock bundle.
- [x] **T007**: spool `doc-read`, `doc-write`, `doc-list` verbs and their MCP tools, `doc-write` through T002's ops.
  - Depends: T004.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/agent/doc_verbs.go` (*new*) + test.
  - Done: the verb test prints the outline it wrote and read back, and an op's outcome (committed rev / 412 / 404 / refused). Control: an unauthenticated request fails (9h).
  - Vendor: claude. Box: any.

## 6. Export (phase 2)

- [x] **T008**: one-way DB -> markdown (spec 5), layout mirroring 1 / 1.1 / 1.1.1, to the per-workspace bucket and/or a zip / repo commit.
  - Depends: T002, T004.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs_export.go` (*new*) + test.
  - Done: regenerated (debounced) after any committed write, structural or text; reads the doc, its rev and the highest item rev in ONE REPEATABLE READ snapshot; the test exports a 3-level doc and lists the expected paths with `doc rev <n>, item rev <m>` in each header; after a text-only edit the export carries the new item rev. Control: an edited exported file changes nothing in the DB (9f).
  - Vendor: claude. Box: any with docker Postgres.
