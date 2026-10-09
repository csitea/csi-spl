# 113 Workspace documents: tasks

Authority for what is built. `spec.md` holds the behaviour; this file
follows its sections 2-7. Each task names its layer, its dependency, the
files it owns, the sibling-project routine it ports (where it ports one),
and a Done line: what runs, what it prints, and its control.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial /
in progress in a live lane, `[ ]` Planned).

Version **v0.2** (2026-10-08).

"The sibling's" below = the sibling project's Perl API, read-only on this
box under its `src/perl/.../lib` tree. Port the behaviour, never its names,
paths or hosts, and never its nested-set arithmetic (spec section 3.6).

## Order

T001 (DDL) -> T002 (store ops + property test) -> T003 (check / repair
actions) -> T004 (hub API) and T005 (xls) -> T006 (WUI) and T007 (agents)
-> T008 (export, phase 2). T002's property test gates everything after it.

## Tasks

- [x] T000 **doc**: `spec.md` + this file, v0.2, and the benchmark under
  `bench/`.
  Done: `bash bench/tree-bench.sh` prints the section 2.1 table with n = 5
  and exits 0; control: each model's planted broken row is reported as
  `CONTROL <model> caught` in the raw output (6 of 6).
- [ ] T001 **rdb**. A new migration: `workspace_doc`, `workspace_doc_item`
  (adjacency + ordinal, spec 2.2), tenant RLS (`NULLIF` pattern), the
  section 3.2 constraints and the deferred constraint trigger.
  Ports: the sibling's SQL test hierarchy table and its `*_doc` tables,
  as the column list only (they carry no constraint to port).
  Files: `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_workspace_docs.sql` (*new*).
  Done: applied on dev and prd (DDL first, spec memory rule); a SQL test
  inserts a gap, an overlap, a cycle, a second root and a cross-doc parent
  and each is refused (prints the constraint name); control: the same five
  writes with the trigger dropped commit (9c).
- [ ] T002 **store (Go, pgx, under RLS)**: the structural ops of spec 3.3,
  each one transaction under `SELECT ... FOR UPDATE` on the `workspace_doc`
  row, plus the subtree reader.
  Ports: the sibling's DB writer hierarchical insert (~l.291-422) ->
  `DocItemAdd(sibling|parent|child)`; its hierarchical delete
  (~l.203-290) -> `DocItemDeleteSubtree`; its single-column update
  (~l.557) -> `DocItemUpdateField` (allow-listed column, item `rev`, 412);
  its DB reader branch select -> `DocSubtree` (recursive CTE, outline
  number derived); new: `DocItemMove`.
  Files: `csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs*.go` (*new*).
  Done: `go test ./internal/store -run 'WorkspaceDoc'` on Postgres runs the
  property test (>= 5,000 random ops x 5 seeds, invariants + model tree
  after every step) and the concurrent test (8 writers x 500 ops) green,
  printing ops/seed counts; control: with the test-only planted bug
  (delete skips the gap close; move reads positions before the lock) both
  go red and print the replay seed (9a, 9b).
- [ ] T003 **orc actions**: `do_spl_doc_tree_check`,
  `do_spl_doc_tree_repair` (spec 3.4), per-env SA, each with its `.tst.sh`.
  Files: `csi-spl-orc/src/bash/run/spl-doc-tree-check.func.sh`,
  `spl-doc-tree-repair.func.sh` (*new*) + tests.
  Done: `ENV=dev ./run -a do_spl_doc_tree_check` prints
  `violations=0 docs=<n> items=<n>` and exits 0; control: on a test DB with
  one planted gap it prints the violation and exits 1, and
  `DRY_RUN=0 do_spl_doc_tree_repair` then prints `renumbered=1` and the
  check returns to `violations=0` (9d).
- [ ] T004 **hub Go API**: doc tree CRUD (doc view), list/grid CRUD (grid
  view), 412 on a stale rev, spec 100 search indexing, topic link.
  Ports: the sibling's doc-view controller, grid (list) controller and the
  hierarchy create / delete / select controllers, onto the T002 store ops.
  Files: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs.go` (*new*) + test.
  Done: `go test ./internal/hub -run WorkspaceDoc` green: every route
  returns the outline in document order, a stale-rev write gets 412;
  control: a cross-tenant request returns 0 items (9e).
- [ ] T005 **xls import/export**: grid <-> xlsx.
  Ports: the sibling's xls import (xls -> table/DB) and export (DB -> xls).
  An import builds the tree through T002's ops only, in one transaction.
  Files: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs_xls.go` (*new*) + test.
  Done: export then import of a 3-level doc round-trips to the same
  outline md5; control: an xlsx row whose parent number does not exist is
  refused with its row number and nothing is written.
- [ ] T006 **WUI**: `WorkspaceDocView` and `WorkspaceGridView`, lazy; doc
  view context menu (add sibling / parent / child, move, indent / outdent,
  delete branch, print branch via print CSS); grid inline edit, filter,
  sort; i18n (agy reviews the locale text last).
  Files: `csi-spl-wui/src/pages/workspace/docs.vue` (*new*), components
  under `csi-spl-wui/src/components/workspace-docs/`.
  Done: `pnpm run typecheck` and the e2e drive add/move/delete in both
  views and read the same outline back; control: the initial-chunk budget
  test fails on an initial JS delta > 100 B (9g).
- [ ] T007 **agents**: spool `doc-read`, `doc-write`, `doc-list` verbs and
  their MCP tools, `doc-write` through T002's ops.
  Files: `csi-spl-api/src/go/spool-hub-api/internal/agent/doc_verbs.go` (*new*).
  Done: the verb test prints the outline it wrote and read back; control:
  an unauthenticated request fails (9h).
- [ ] T008 **export, phase 2** (spec 5): one-way DB -> markdown, layout
  mirroring 1 / 1.1 / 1.1.1, to the per-workspace bucket and/or a zip /
  repo commit, regenerated on each `workspace_doc.rev`.
  Files: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs_export.go` (*new*) + test.
  Done: the test exports a 3-level doc and lists the expected paths with
  the rev in each header; after an edit the export carries the new rev;
  control: an edited exported file changes nothing in the DB (9f).
