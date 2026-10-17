# Tasks: Spec 145 — Issues, GitSpecs and Qto: Bidirectional Synchronization and Unified Architecture

Status vocabulary: `Implemented` (artifact exists and check passes), `Partial` (some exists), `Planned` (nothing built yet).  
Status: **Ready to build** (Spec complete, SPL-2367).  
Authority: [spec.md](spec.md) for requirements, protocols, and data models; this file for task status, dependency ordering, acceptance gates, and red controls.  
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

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T001** | **Planned** | `rdb` | `spec-schema` | **Database schema migration: `0205_issue_spec_attributes.sql`** (§2.1). Forward-only SQL adding columns `spec_path` (`text NOT NULL DEFAULT ''` with regex check for `csi-spl-doc/specs/...`) and `spec_task_id` (`text NOT NULL DEFAULT ''` with alphanumeric check) to `issues`, plus composite index `issues_spec_task_idx` on `(tenant_id, spec_path, spec_task_id)`.<br>• *Gate*: `psql` applies migration cleanly; valid insert succeeds.<br>• *Red Control*: Inserting row with `spec_path = 'bad/path.txt'` fails check constraint. |
| **T002** | **Planned** | `rdb` | `spec-schema` | **Database schema migration: `spec_sync_map` ledger** (§5.2). Create table `spec_sync_map` (`tenant_id`, `spec_path`, `spec_task_id`, `issue_number`, `qto_doc_id`, `qto_item_id`, `last_git_sha`, `last_sync_at`, `sync_status`) with foreign keys to `issues` and `workspace_doc`, fail-closed tenant RLS, and operator scope policy.<br>• *Gate*: Migration applies cleanly; cross-tenant query returns 0 rows under tenant RLS.<br>• *Red Control*: Query without tenant setting fails RLS policy check. |
| **T003** | **Planned** | `go` | `spec-schema` | **Hub store & wire model update: `issueJSON`** (§2.2). Update `issueJSON` in `GO/hub/issues.go` and `store.Issue` in `GO/store/` to include `SpecPath`, `SpecTaskID`, and computed `SpecRef`. Update database scanner and insert/update statements in `GO/store/issues.go`.<br>• *Gate*: Go unit test `internal/hub/issues_test.go` verifies round-trip JSON serialization with spec attributes.<br>• *Red Control*: Omitting `spec_path` from scan parameters causes database test assertion failure. |
| **T004** | **Planned** | `go` | `spec-schema` | **Hub API endpoints & CLI support for spec attributes** (§2.2). Update `POST /v1/issues` and `PATCH /v1/issues/{ref}` in `GO/hub/issues.go` to accept `spec_path` and `spec_task_id`. Update CLI `spool issue create` and `update` commands to support `--spec-path` and `--spec-task`. Broadcast WebSocket `issue` frames with new fields.<br>• *Gate*: Integration test verifies `spool issue create --spec-path ... --spec-task ...` stores and returns attributes.<br>• *Red Control*: Passing invalid spec path syntax through API returns 400 `bad_issue`. |

---

## 1. Phase 2: Lane Issue Filing & Historical Backfill (`spec-filing`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T010** | **Planned** | `orc` | `spec-filing` | **Update `do_spl_lane_issue` filing action** (§2.3). Modify `RUN/spl-lane-issue.func.sh` to extract `Spec:` and task ID from `brief.md` or lane environment, pass `--spec-path` and `--spec-task` to `spool issue create/update`, and eliminate `- spec: none` from restart card generation.<br>• *Gate*: `spl-lane-issue.tst.sh` verifies generated card references first-class attributes without `- spec: none`.<br>• *Red Control*: Calling `do_spl_lane_issue` without brief spec line when required exits with error. |
| **T011** | **Planned** | `orc` | `spec-filing` | **Historical backfill action: `do_spl_issue_spec_backfill`** (§2.4). Implement `RUN/spl-issue-spec-backfill.func.sh` and `SCR/issue-spec-backfill.py` to scan existing issues with empty `spec_path`, parse `- spec:` from description cards, match against `tasks.md` rows, and update database in rate-limited batches with undo journal.<br>• *Gate*: Verification run in dry-run mode against test snapshot correctly identifies and maps 100% of parsable cards.<br>• *Red Control*: Planted issue with corrupt card logs warning and skips without crashing. |
| **T012** | **Planned** | `orc` | `spec-filing` | **Enforce c-368 guard (no issue without epic + spec)** (§2.6). Update `SA/lib/lane-issue.inc.sh` and `c-368` guard script to verify that every Level-2 issue has non-null `parent_number` AND valid `spec_path` referencing existing `tasks.md`, and every Level-1 Epic links to `spec.md`.<br>• *Gate*: Guard check verifies compliance across all live issues and rejects non-compliant issues.<br>• *Red Control*: Inserting test issue with `spec_path = ''` causes `c-368` guard to exit with status 1. |

---

## 2. Phase 3: Web UI Representation & Interaction (`spec-wui`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T020** | **Planned** | `wui` | `spec-wui` | **Spec link badge component: `IssueSpecBadge.vue`** (§2.5). Create `WUI/components/IssueSpecBadge.vue` displaying formatted `spec: NNN/T001` badge. Clicking badge opens GitSpec preview in Docs section (`/docs/...`) or opens Qto editor (`/qto/...`).<br>• *Gate*: Component unit test verifies correct link URL generation and visual badge formatting.<br>• *Red Control*: Supplying empty `spec_path` causes badge to render nothing without errors. |
| **T021** | **Planned** | `wui` | `spec-wui` | **Add `spec` column to issue sheet table** (§2.5). Update `WUI/pages/issues.vue` and `WUI/utils/issue-columns-pref.mjs` to add configurable `spec` column displaying task ID, slug, and hover tooltip.<br>• *Gate*: WUI unit test verifies `spec` column renders in table and toggles via column preference menu.<br>• *Red Control*: Deselecting `spec` in column preferences hides column from DOM. |
| **T022** | **Planned** | `wui` | `spec-wui` | **GitSpec task selector in issue dialogs** (§2.5). Update `WUI/components/IssueDetailFrame.vue`, `IssueSubtaskDialog.vue`, and creation drawer in `issues.vue` with searchable dropdown to link/change GitSpec file and select task row.<br>• *Gate*: End-to-end test verifies selecting a task row populates `spec_path` and `spec_task_id` in form payload.<br>• *Red Control*: Submitting issue form with cleared spec field fails client-side validation. |

---

## 3. Phase 4: GitSpec <-> Issues Bidirectional Sync Engine (`spec-issue-sync`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T030** | **Planned** | `orc` | `spec-issue-sync` | **Direction 1: Issue -> GitSpec export (`do_spl_issue_export_spec`)** (§3.1). Implement `RUN/spl-issue-export-spec.func.sh` and `SCR/issue-export-spec.py` to parse `tasks.md`, locate row by `spec_task_id`, and update status checkbox, status column, and lane assignee while strictly preserving non-table text and formatting.<br>• *Gate*: Updating an issue status updates `tasks.md` row with zero diff on surrounding lines.<br>• *Red Control*: Corrupting table column count or delimiter in script output fails integrity check. |
| **T031** | **Planned** | `orc` | `spec-issue-sync` | **Direction 2: Epic -> GitSpec export (`do_spl_epic_export_spec`)** (§3.2). Implement `RUN/spl-epic-export-spec.func.sh` to generate a complete GitSpec directory `csi-spl-doc/specs/NNN-<slug>/` (`spec.md` + `tasks.md`) from an Epic and its child issues in the Hub.<br>• *Gate*: Exporting an Epic creates valid `spec.md` and `tasks.md` matching house style.<br>• *Red Control*: Generated `tasks.md` with missing headers or syntax errors fails linter. |
| **T032** | **Planned** | `orc` | `spec-issue-sync` | **Direction 3: GitSpec -> Issues import v2 (`do_spl_spec_import_issues`)** (§3.3). Upgrade `RUN/spl-spec-import-issues.func.sh` and `SCR/spec-import-issues.py` to populate first-class `spec_path` and `spec_task_id` attributes, link child issues to Epic parent, and run idempotently.<br>• *Gate*: Second run of importer after initial import reports 0 creations and 0 updates.<br>• *Red Control*: Running with altered task ID in `tasks.md` detects drift and flags update. |
| **T033** | **Planned** | `orc` | `spec-issue-sync` | **Bidirectional reconciliation daemon (`do_spl_spec_sync_cron`)** (§3.3, §5.3). Implement scheduled reconciliation runner detecting un-synchronized changes between git checkouts and Hub database, applying 3-way merge rules and writing audit journals.<br>• *Gate*: Cron executes cleanly and logs sync status to `spec_sync_map`.<br>• *Red Control*: Conflicting concurrent edits flag row as `conflict` and notify dispatch topic. |

---

## 4. Phase 5: GitSpec <-> Qto Unified Engine (`spec-qto-sync`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T040** | **Planned** | `rdb` | `spec-qto-sync` | **Qto task grid attribute schema** (§3.4). Extend `workspace_doc_item` attribute validation to support structured task grid items (`attrs.spec_task_id`, `attrs.issue_key`, `attrs.task_status`, `attrs.gate_criteria`).<br>• *Gate*: Inserting task grid item into `workspace_doc_item` preserves structured attributes.<br>• *Red Control*: Inserting non-object attribute payload fails JSON type check. |
| **T041** | **Planned** | `orc` | `spec-qto-sync` | **Direction 4: GitSpec -> Qto importer (`do_spl_qto_spec_sync`)** (§3.4). Implement `RUN/spl-qto-spec-sync.func.sh` to import `spec.md` and `tasks.md` into `workspace_doc` and `workspace_doc_item`s, converting task tables into interactive Qto Grids.<br>• *Gate*: Importer populates Qto doc tree; grid items reflect all columns from `tasks.md`.<br>• *Red Control*: Omitting task rows during import fails node count check. |
| **T042** | **Planned** | `orc` | `spec-qto-sync` | **Direction 4: Qto -> GitSpec exporter (`do_spl_doctree_export_md` v2)** (§3.4). Upgrade `RUN/spl-doctree-export-md.func.sh` and `SCR/spl-doctree-md.py` to serialize Qto Task Grids into formatted GFM pipe tables with byte-for-byte round-trip fidelity.<br>• *Gate*: Exporting Qto task grid to Markdown matches original `tasks.md` table syntax.<br>• *Red Control*: Dropping markdown table pipe delimiters causes export validation to fail. |
| **T043** | **Planned** | `go` | `spec-qto-sync` | **Qto live event listener for issue sync** (§3.4, §4.2). Implement background consumer in Spool Hub API listening to `workspace_doc_rev_log` events; on task grid mutation, immediately updates linked `issues` row in PostgreSQL.<br>• *Gate*: Editing a task status cell in Qto updates corresponding issue in Hub database within 500ms.<br>• *Red Control*: Severing event trigger causes sync latency test to time out and fail. |

---

## 5. Phase 6: Drift Gates, Pre-Push & CI Integration (`spec-gate`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T050** | **Planned** | `orc` | `spec-gate` | **Drift check action: `do_check_spec_issue_drift`** (§6). Implement `RUN/check-spec-issue-drift.func.sh` comparing live git `tasks.md` files against Hub `issues` table; returns status 0 when in sync, status 1 on drift.<br>• *Gate*: Clean workspace with synced issues reports 0 drift.<br>• *Red Control*: Artificially modifying an issue status in DB without touching `tasks.md` causes drift check to fail with exit 1. |
| **T051** | **Planned** | `iac` | `spec-gate` | **Pre-push hook & CI gate integration** (§6). Wire `do_check_spec_issue_drift` into `do_check_pre_push` and `.github/workflows/10_ci-quality.yml`. Refuse pushes carrying unsynced task/issue discrepancies.<br>• *Gate*: Pre-push gate runs drift check on touched spec files.<br>• *Red Control*: Pushing commit with mismatched `tasks.md` status fails pre-push gate. |
| **T052** | **Planned** | `orc` | `spec-gate` | **Comprehensive end-to-end test suite (`spec-issue-sync.tst.sh`)** (§6). Implement `TST/spec-issue-sync.tst.sh` testing all 8 acceptance criteria (AC-1 through AC-8) and verifying every red control.<br>• *Gate*: All test cases pass against clean test environment.<br>• *Red Control*: Intentionally failing any of AC-1..AC-8 causes test runner to fail. |

---

## Dependency Order & Implementation Strategy

```
Phase 1: Database Schema & API Wire Models (T001 - T004)
   |
   +---> Phase 2: Lane Filing & Historical Backfill (T010 - T012)
   |        |
   |        +---> Phase 3: Web UI Representation & Badges (T020 - T022)
   |
   +---> Phase 4: GitSpec <-> Issues Bidirectional Engine (T030 - T033)
            |
            +---> Phase 5: GitSpec <-> Qto Unified Engine (T040 - T043)
                     |
                     +---> Phase 6: Drift Gates & CI Verification (T050 - T052)
```

1. **Schema First**: T001..T004 establish the database columns, models, and API contracts.
2. **Filing & Backfill**: T010..T012 update `do_spl_lane_issue`, backfill existing issues, and lock down `c-368`.
3. **WUI**: T020..T022 expose the badges, table columns, and task pickers.
4. **Bidirectional Sync**: T030..T033 implement Issue -> Spec and Epic -> Spec exports, upgrading import to v2.
5. **Qto Integration**: T040..T043 enable the dual outline/grid interactive editing in Qto.
6. **Hardening**: T050..T052 integrate the drift gates into CI and pre-push hooks.

---

<!-- version: 0.1.0 · updated: 2026-10-17 -->
