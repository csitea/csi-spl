# Tasks: Spec 145 — Issues, GitSpecs and Qto: Bidirectional Synchronization and Unified Architecture

Status vocabulary: `Implemented` (artifact exists and check passes), `Partial` (some exists), `Planned` (nothing built yet), `Dropped` (retired by architectural decision).  
Status: **Ready to build (Consensus v0.3.1 — Send-Back Corrections Folded)**. Issue: SPL-2367.  
Authority: [spec.md](spec.md) for requirements, protocols, and data models; this file for task status, dependency ordering, acceptance gates, red controls, and parallel execution work groups.  
Docs only: this task list defines the build rows; implementation lanes execute it ([README.md](../README.md) §2.4).

---

## Path Prefixes

- `DOC/` is `csi-spl-doc/specs/145-issue-spec-qto-sync/`.
- `GO/` is `csi-spl-api/src/go/spool-hub-api/internal/`.
- `RDB/` is `csi-spl-rdb/src/sql/postgres/spool-hub/`.
- `RUN/` is `csi-spl-orc/src/bash/run/`.
- `SCR/` is `csi-spl-orc/src/bash/scripts/`.
- `TST/` is `csi-spl-orc/src/bash/tests/`.
- `WUI/` is `csi-spl-wui/src/`.
- `SA/` is `csi-spl-orc/src/bash/features/spawn-agents/`.

---

## 0. Phase 1: Database Schema & API Wire Models (`spec-schema`)

| ID | Status | Area | Lane | Summary, Gate & Red Control | Parallel Group |
|---|---|---|---|---|---|
| **T001** | **Implemented** | `rdb` | `spec-schema` | **Database schema migration: issue spec attributes** (§2.1). Built: rdb `0207_issue_spec_attributes.sql` (SPL-2452), store test `TestIssueSpecAttributes0207` (gate + `bad/path.txt` red control). Forward-only SQL migration taking the next free rdb prefix on origin/master at the lane's push (re-checked on final rebase, e.g. `<prefix>_issue_spec_attributes.sql`), adding columns `spec_path` (`text NOT NULL DEFAULT ''` with regex check for `csi-spl-doc/specs/...`) and `spec_task_id` (`text NOT NULL DEFAULT ''` with alphanumeric check) to `issues`, plus composite index `issues_spec_task_idx` on `(tenant_id, spec_path, spec_task_id)`. Implemented in `spec-schema` lane ordered with or combined with T002 to avoid racing for prefixes.<br>• *Gate*: `psql` applies migration cleanly; valid insert succeeds.<br>• *Red Control*: Inserting row with `spec_path = 'bad/path.txt'` fails check constraint. | Work Group 1 |
| **T002** | **Implemented** | `rdb` | `spec-schema` | **Database schema migration: `spec_sync_map` ledger** (§5.2). Built: rdb `0208_spec_sync_map.sql` (SPL-2452), store test `TestSpecSyncMap0208` (fail-closed RLS, cross-tenant, checks), seeded in `seedTenantAll`. The §5.2 sketch's bare `ON DELETE SET NULL` would null the NOT NULL `tenant_id`; the migration names the column (`SET NULL (issue_number)`, `(qto_doc_id)`, Postgres 15+). Forward-only SQL migration in `spec-schema` lane (ordered after T001 or combined in the same migration file, taking the next free rdb prefix on origin/master at push time, re-checked on final rebase, never two lanes racing for the same prefix). Create table `spec_sync_map` (`tenant_id`, `spec_path`, `spec_task_id`, `issue_number`, `qto_doc_id`, `qto_item_id`, `last_git_sha`, `last_sync_at`, `sync_status`) with foreign keys to `issues` and `workspace_doc`, fail-closed tenant RLS, and operator scope policy.<br>• *Gate*: Migration applies cleanly; cross-tenant query returns 0 rows under tenant RLS.<br>• *Red Control*: Query without tenant setting fails RLS policy check. | Work Group 1 |
| **T003** | **Planned** | `go` | `spec-schema` | **Hub store & wire model update: `issueJSON`** (§2.2). Update `issueJSON` in `GO/hub/issues.go` and `store.Issue` in `GO/store/` to include `SpecPath`, `SpecTaskID`, and computed `SpecRef`. Update database scanner and insert/update statements in `GO/store/issues.go`.<br>• *Gate*: Go unit test `internal/hub/issues_test.go` verifies round-trip JSON serialization with spec attributes.<br>• *Red Control*: Omitting `spec_path` from scan parameters causes database test assertion failure. | Work Group 2 |
| **T004** | **Planned** | `go` | `spec-schema` | **Hub API strict validation & CLI endpoints** (§2.2, Owner Decision 2: Option A). Update `POST /v1/issues` and `PATCH /v1/issues/{ref}` in `GO/hub/issues.go` to strictly validate that `spec_path` exists in repo/Qto AND `spec_task_id` exists in that spec's task grid; return 400 `bad_issue` if invalid. Update CLI `spool issue create/update` with `--spec-path` and `--spec-task`. Broadcast WebSocket `issue` frames with new fields.<br>• *Gate*: Integration test verifies `spool issue create` with valid spec+task succeeds, and invalid task ID returns HTTP 400.<br>• *Red Control*: Filing an issue with non-existent task ID `T999` returns HTTP 400 `spec_task_not_found`. | Work Group 2 |

---

## 1. Phase 2: Lane Issue Filing, Shared Area Specs & Historical Backfill (`spec-filing`)

| ID | Status | Area | Lane | Summary, Gate & Red Control | Parallel Group |
|---|---|---|---|---|---|
| **T010** | **Planned** | `orc` | `spec-filing` | **Update `do_spl_lane_issue` filing action** (§2.3). Modify `RUN/spl-lane-issue.func.sh` to extract `Spec:` and task ID from `brief.md` or lane environment, pass `--spec-path` and `--spec-task` to `spool issue create/update`, and eliminate `- spec: none` from restart card generation.<br>• *Gate*: `spl-lane-issue.tst.sh` verifies generated card references first-class attributes without `- spec: none`.<br>• *Red Control*: Calling `do_spl_lane_issue` without brief spec line when required exits with error. | Work Group 3 |
| **T011** | **Implemented**<br>(ee7dc6613) | `doc` | `spec-filing` | **Shared Area Specs provisioning** (§5.4, Owner Decision 4: Option A). Create initial area specs `csi-spl-doc/specs/000-quick-fixes/tasks.md` and `csi-spl-doc/specs/000-operations/tasks.md` with standard table headers and seed tasks. The `T011` lane files one level-1 epic per area spec (`Spec 000 - Quick fixes`, `Spec 000 - Operations`, the title form `do_spl_issue_epic_backfill` and the `c-368` guard map by) and names their keys.<br>• *Gate*: Area spec files exist on master with valid task tables and linked level-1 epics.<br>• *Red Control*: Missing required column in area spec task table fails table linter. | Work Group 1 |
| **T012** | **Planned** | `orc` | `spec-filing` | **Historical backfill action: `do_spl_issue_spec_backfill`** (§2.4). Implement `RUN/spl-issue-spec-backfill.func.sh` and `SCR/issue-spec-backfill.py` to scan existing issues with empty `spec_path`, parse `- spec:` from description cards, match against `tasks.md` rows, and update database in rate-limited batches with undo journal.<br>• *Gate*: Verification run in dry-run mode against test snapshot correctly identifies and maps 100% of parsable cards.<br>• *Red Control*: Planted issue with corrupt card logs warning and skips without crashing. | Work Group 3 |
| **T013** | **Planned** | `orc` | `spec-filing` | **Strict c-368 guard enforcement** (§2.6, Owner Decision 2: Option A). Update `SA/lib/lane-issue.inc.sh` and `c-368` guard script to verify that every Level-2 issue has non-null `parent_number` AND valid `spec_path` referencing existing `tasks.md` AND an existing `spec_task_id`, and every Level-1 Epic links to `spec.md`.<br>• *Gate*: Guard check verifies compliance across all live issues and rejects non-compliant issues.<br>• *Red Control*: Inserting test issue with `spec_path = ''` causes `c-368` guard to exit with status 1. | Work Group 5 |

---

## 2. Phase 3: Web UI Representation & Interaction (`spec-wui`)

| ID | Status | Area | Lane | Summary, Gate & Red Control | Parallel Group |
|---|---|---|---|---|---|
| **T020** | **Planned** | `wui` | `spec-wui` | **Spec link badge component: `IssueSpecBadge.vue`** (§2.5). Create `WUI/components/IssueSpecBadge.vue` displaying formatted `spec: NNN/T001` badge. Clicking badge opens GitSpec preview in Docs section (`/docs/...`) or opens Qto editor (`/qto/...`).<br>• *Gate*: Component unit test verifies correct link URL generation and visual badge formatting.<br>• *Red Control*: Supplying empty `spec_path` causes badge to render nothing without errors. | Work Group 3 |
| **T021** | **Planned** | `wui` | `spec-wui` | **Add `spec` column to issue sheet table** (§2.5). Update `WUI/pages/issues.vue` and `WUI/utils/issue-columns-pref.mjs` to add configurable `spec` column displaying task ID, slug, and hover tooltip.<br>• *Gate*: WUI unit test verifies `spec` column renders in table and toggles via column preference menu.<br>• *Red Control*: Deselecting `spec` in column preferences hides column from DOM. | Work Group 3 |
| **T022** | **Planned** | `wui` | `spec-wui` | **GitSpec & Qto task selector in issue dialogs** (§2.5). Update `WUI/components/IssueDetailFrame.vue`, `IssueSubtaskDialog.vue`, and creation drawer in `issues.vue` with searchable dropdown to link/change GitSpec file and select verified task row.<br>• *Gate*: End-to-end test verifies selecting a task row populates `spec_path` and `spec_task_id` in form payload.<br>• *Red Control*: Submitting issue form with cleared spec field fails client-side validation. | Work Group 3 |

---

## 3. Phase 4: Qto-Primary Sync Engine & Instant Git Export (`spec-qto-sync`)

| ID | Status | Area | Lane | Summary, Gate & Red Control | Parallel Group |
|---|---|---|---|---|---|
| **T030** | **Dropped** | `orc` | `spec-qto-sync` | **[dropped: Qto-only primary decision B (msg 3ec25b38)] Direction 1: Issue -> GitSpec export (`do_spl_issue_export_spec`)** (§3.1). Formerly planned direct hand export from issues to git files; retired because Git `.md` files are strictly read-only exports generated by Qto export engine (`T035`/`T042`). History preserved. | — |
| **T031** | **Planned** | `orc` | `spec-qto-sync` | **Direction 2: Epic -> Qto Spec -> GitSpec export (`do_spl_epic_qto_create`)** (§3.2). Implement `RUN/spl-epic-qto-create.func.sh` to initialize a Qto document with outline structure and task grid when an Epic is created, registering it in `spec_sync_map` and generating initial export files.<br>• *Gate*: Creating an Epic initializes Qto document and exports valid `spec.md` and `tasks.md`.<br>• *Red Control*: Failing to create Qto document aborts Epic export with error. | Work Group 4 |
| **T032** | **Dropped** | `orc` | `spec-qto-sync` | **[dropped: Qto-only primary decision B (msg 3ec25b38)] Direction 3: GitSpec -> Issues import v2 (`do_spl_spec_import_issues`)** (§3.3). Formerly planned ongoing two-way parsing from Git checkouts into issues; retired because Qto is the primary authoring source. Replaced by one-time legacy migration `T041`. History preserved. | — |
| **T033** | **Dropped** | `orc` | `spec-qto-sync` | **[dropped: Qto-only primary decision B (msg 3ec25b38)] Bidirectional reconciliation daemon (`do_spl_spec_sync_cron`)** (§3.3, §5.3). Formerly planned 3-way merge daemon; retired because Git files are read-only exports and zero git merge conflicts occur on documentation. History preserved. | — |
| **T034** | **Planned** | `orc` | `spec-qto-sync` | **Agent Qto CLI update tool: `do_spl_qto_task_update`** (§3.4). Implement `RUN/spl-qto-task-update.func.sh` allowing agents in worktrees to update task status, gates, and criteria directly in Qto database without editing git `.md` files.<br>• *Gate*: `QTO_DOC=... TASK_ID=T001 STATUS=done ./run -a do_spl_qto_task_update` updates DB.<br>• *Red Control*: Supplying invalid task ID or status returns exit status 1. | Work Group 4 |
| **T035** | **Planned** | `orc` | `spec-qto-sync` | **Qto instant commit-on-change export runner** (§3.1, Owner Decision 3: Option B). Implement `RUN/spl-qto-instant-commit-export.func.sh` to generate Markdown exports for Qto docs and commit immediately to `origin/master` on every change. Enforce path isolation under `csi-spl-doc/specs/` to guarantee zero lane rebase conflicts.<br>• *Gate*: Triggering export creates an atomic commit on master with valid committer identity; concurrent lane rebase finishes with 0 conflicts.<br>• *Red Control*: Exporting to a path outside `csi-spl-doc/specs/` is aborted by path safety guard. | Work Group 4 |

---

## 4. Phase 5: Qto Task Grid & Relational Engine (`spec-qto-grid`)

| ID | Status | Area | Lane | Summary, Gate & Red Control | Parallel Group |
|---|---|---|---|---|---|
| **T040** | **Planned** | `rdb` | `spec-qto-grid` | **Qto task grid attribute schema** (§4.1). Extend `workspace_doc_item` attribute validation to support structured task grid items (`attrs.spec_task_id`, `attrs.issue_key`, `attrs.task_status`, `attrs.gate_criteria`).<br>• *Gate*: Inserting task grid item into `workspace_doc_item` preserves structured attributes.<br>• *Red Control*: Inserting non-object attribute payload fails JSON type check. | Work Group 4 |
| **T041** | **Planned** | `orc` | `spec-qto-grid` | **Direction 3: Legacy GitSpec -> Qto one-time migration (`do_spl_spec_import_qto`)** (§3.3). Implement `RUN/spl-spec-import-qto.func.sh` to import pre-existing `spec.md` and `tasks.md` into Qto doctrees, convert task tables into interactive Qto Grids, stamp git files as read-only exports, and register in `spec_sync_map`.<br>• *Gate*: Importer populates Qto doc tree; grid items reflect all columns from `tasks.md`.<br>• *Red Control*: Running migration on already-migrated document aborts with error to prevent overwriting Qto store. | Work Group 4 |
| **T042** | **Planned** | `orc` | `spec-qto-grid` | **Direction 4: Qto -> GitSpec exporter v2 (`do_spl_doctree_export_md` v2)** (§3.1, §4.1). Upgrade `RUN/spl-doctree-export-md.func.sh` and `SCR/spl-doctree-md.py` to serialize Qto Task Grids into formatted GFM pipe tables with mandatory read-only generation banner.<br>• *Gate*: Exporting Qto task grid produces clean GFM table with immutable generation banner.<br>• *Red Control*: Dropping markdown table pipe delimiters causes export validation to fail. | Work Group 4 |
| **T043** | **Planned** | `go` | `spec-qto-grid` | **Qto live event listener for issue sync** (§3.1, §5.3). Implement background consumer in Spool Hub API listening to `workspace_doc_rev_log` events; on task grid mutation, immediately updates linked `issues` row in PostgreSQL.<br>• *Gate*: Editing a task status cell in Qto updates corresponding issue in Hub database within 500ms.<br>• *Red Control*: Severing event trigger causes sync latency test to time out and fail. | Work Group 4 |

---

## 5. Phase 6: Drift Gates, Pre-Push & CI Integration (`spec-gate`)

| ID | Status | Area | Lane | Summary, Gate & Red Control | Parallel Group |
|---|---|---|---|---|---|
| **T050** | **Planned** | `orc` | `spec-gate` | **Read-only hygiene & drift check action: `do_check_spec_issue_drift`** (§6). Implement `RUN/check-spec-issue-drift.func.sh` comparing live git `tasks.md` files against Hub `issues` table and checking for forbidden hand-edits to generated spec files in worktrees.<br>• *Gate*: Clean workspace with synced issues reports 0 drift.<br>• *Red Control*: Modifying generated spec export file by hand in worktree causes check to fail with exit 1. | Work Group 5 |
| **T051** | **Planned** | `iac` | `spec-gate` | **Pre-push hook & CI gate integration** (§6). Wire `do_check_spec_issue_drift` into `do_check_pre_push` and `.github/workflows/10_ci-quality.yml`. Refuse pushes carrying unsynced task/issue discrepancies or tainted spec exports.<br>• *Gate*: Pre-push gate runs drift check on touched spec files.<br>• *Red Control*: Pushing commit with mismatched `tasks.md` status fails pre-push gate. | Work Group 5 |
| **T052** | **Planned** | `orc` | `spec-gate` | **Comprehensive end-to-end test suite (`spec-issue-sync.tst.sh`)** (§6). Implement `TST/spec-issue-sync.tst.sh` testing all 8 acceptance criteria (AC-1 through AC-8) and verifying every red control.<br>• *Gate*: All test cases pass against clean test environment.<br>• *Red Control*: Intentionally failing any of AC-1..AC-8 causes test runner to fail. | Work Group 5 |

---

## Dependency Order & Parallel Execution Work Groups

```
+-----------------------------------------------------------------------------------+
| Work Group 1 (Foundation): T001 (Schema), T002 (Ledger - single lane/ordered), T011 (Area Specs)  |
+------------------------------------------+----------------------------------------+
                                           |
                                           v
               +------------------------------------------------------+
               | Work Group 2 (Hub Wire & CLI): T003 (Store), T004 (API)|
               +---------------------------+--------------------------+
                                           |
               +---------------------------+--------------------------+
               |                                                      |
               v                                                      v
+--------------------------------------------+  +--------------------------------------------+
| Work Group 3 (WUI & Issue Filing)          |  | Work Group 4 (Qto Engine & Instant Export) |
| T010 (Lane filing)                         |  | T040 (Grid Schema)                         |
| T012 (Historical backfill)                 |  | T031 (Epic Qto create)                     |
| T020 (Spec badge component)                |  | T034 (Agent Qto CLI tool)                  |
| T021 (Spec sheet table column)             |  | T035 (Instant commit export runner)        |
| T022 (Spec task selector dialog)           |  | T041 (Legacy spec migration)               |
|                                            |  | T042 (Exporter v2)                         |
|                                            |  | T043 (Live DB event listener)              |
+--------------------------------------------+  +--------------------------------------------+
               |                                                      |
               +---------------------------+--------------------------+
                                           |
                                           v
               +------------------------------------------------------+
               | Work Group 5 (Gates & CI Integration)                |
               | T013 (Strict c-368 guard enforcement)                |
               | T050 (Hygiene & drift check action)                  |
               | T051 (Pre-push & CI workflow integration)            |
               | T052 (Comprehensive E2E test suite)                  |
               +------------------------------------------------------+
```

### Detailed Work Group Parallelism

1. **Work Group 1 — Foundation (Can run immediately in parallel)**:
   - `T001` (RDB migration for `issues.spec_path` and `spec_task_id`) and `T002` (RDB migration for `spec_sync_map`) are executed in the single `spec-schema` lane (ordered or combined in one migration file, taking the next free rdb prefix on origin/master at push time, re-checked on final rebase, never two lanes racing for the same prefix). `T011` (Markdown templates and filing level-1 epics `Spec 000 - Quick fixes` and `Spec 000 - Operations`) touches `csi-spl-doc` and runs in parallel.
2. **Work Group 2 — Hub Wire & CLI API (Can run in parallel once T001 lands)**:
   - `T003` (Go structs, store scanning, database queries) and `T004` (API endpoint strict validation and CLI flags) proceed in parallel within `csi-spl-api`.
3. **Work Group 3 — WUI & Issue Filing (Can run fully in parallel across ORC and WUI lanes)**:
   - Once the API models exist, `T010` (bash lane filing) and `T012` (python backfill script) can be built in `csi-spl-orc` at the same time as `T020` (badge), `T021` (table column), and `T022` (selector dialog) in `csi-spl-wui`.
4. **Work Group 4 — Qto Engine, Agent Tools & Instant Export (Internal concurrency)**:
   - `T040` (Qto item JSON schema) unblocks `T041`, `T042`, and `T043`.
   - `T034` (Agent CLI `do_spl_qto_task_update`) and `T035` (Instant commit runner with low-churn path isolation) can develop concurrently with `T042`.
5. **Work Group 5 — Gates, CI & Quality Controls (Parallel verification and hook wiring)**:
   - `T013` (`c-368` guard enforcement), `T050` (drift action), `T051` (pre-push hook wiring), and `T052` (comprehensive E2E test suite) execute in parallel to harden the system before general availability.

---

## Row Count Summary

- **Active Implementation Tasks**: 21
- **Dropped Tasks (Historical Preservation)**: 3 (`T030`, `T032`, `T033` retired by Owner Decision 1: Option B)
- **Total Task Rows**: 24

---

<!-- version: 0.3.1 · updated: 2026-10-17 · owner-decisions-folded: 3ec25b38 · send-back-folded: 4a154c24 -->
