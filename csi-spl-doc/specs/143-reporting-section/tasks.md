# Tasks: Spec 143 — Reporting section of the WUI, beside Monitoring

Status vocabulary: `Implemented` (artifact exists and check passes), `Partial` (some exists), `Planned` (nothing built yet).  
Status: **Ready to build** (Spec complete, SPL-2324).  
Authority: [spec.md](spec.md) for requirements; this file for task status, acceptance gates, and red controls.  
Docs only: this task list defines the work; implementation lanes execute it ([README.md](../README.md) §2.4).

---

## 0. Inventory & baseline

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T001** | **Planned** | `rdb` | `reporting-schema` | **Database schema migration: `estate_deploys`** (§2.3.1). Forward-only migration `0202_estate_deploys.sql` creating table `estate_deploys` with primary key `deploy_id`, environment `env` (`dev`/`prd`), component (`hub`/`wui`), version tag, `commit_sha`, `deployed_at`, and `status`. Estate-wide table with public select and operator write RLS.<br>• *Gate*: `psql` applies migration cleanly; duplicate deploy ID fails unique constraint.<br>• *Red Control*: Non-operator insert fails RLS policy check. |
| **T002** | **Planned** | `rdb` | `reporting-schema` | **Database schema migration: `sql_query_audit`** (§3.5). Forward-only migration `0203_sql_query_audit.sql` creating table `sql_query_audit` (`audit_id`, `tenant_id`, `human_id`, `query_text`, `executed_at`, `duration_ms`, `row_count`, `truncated`, `error_message`, `client_ip`). Scoped by `tenant_id` with fail-closed tenant RLS.<br>• *Gate*: `psql` applies migration cleanly; query without tenant setting returns 0 rows.<br>• *Red Control*: Querying audit rows from another workspace returns 0 rows. |
| **T003** | **Planned** | `rdb` | `reporting-schema` | **Database schema migration: `activity_categories` & `fleet_asks` extension** (§4.3). Forward-only migration `0204_activity_categories.sql` creating table `activity_categories` (`category_path` PK, `parent_path` FK, `title`, `description`, `dimensions`, `is_active`) and adding `work_kind` and `category_path` columns to `fleet_asks`.<br>• *Gate*: Migration applies cleanly; invalid category path regex raises constraint violation.<br>• *Red Control*: Inserting category path with uppercase or invalid symbols fails check constraint. |

---

## 1. Phase 1: Section Navigation & Shell (`reporting-shell`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T010** | **Planned** | `wui` | `reporting-shell` | **Left rail navigation registration** (§1.1). Add `reporting` entry to `RAIL_TABS` in `csi-spl-wui/src/utils/rail-order.mjs` with icon `chart-column` and label key `sidebar.reporting`. Update rail tests and types (`types/mjs-shims.d.ts`).<br>• *Gate*: WUI unit test verifies `reporting` appears in rail tab list.<br>• *Red Control*: Removing `reporting` from `RAIL_TABS` causes navigation test to fail. |
| **T011** | **Planned** | `wui` | `reporting-shell` | **Tab routing utility: `utils/reporting-tabs.mjs`** (§1.2). Implement path-based tabs utility defining `REPORTING_TABS` (`releases` [ready: true], `sql` [ready: true, adminOnly: true], `tokens` [ready: false, operatorsOnly: true], `issues` [ready: false], `posts` [ready: false], `lanes` [ready: false, operatorsOnly: true]), `REPORTING_DEFAULT_PATH`, `visibleReportingTabs`, and `reportingTabFor`.<br>• *Gate*: Unit test `tests/unit/reporting-tabs.test.mjs` validates tab ordering, visibility rules for member vs admin vs operator admin, and default landing path.<br>• *Red Control*: Non-admin member seeing `sql` tab, or standard workspace admin seeing `tokens` tab in `visibleReportingTabs` fails test assertion. |
| **T012** | **Planned** | `wui` | `reporting-shell` | **Section page wrapper: `pages/reporting.vue`** (§1.3). Create section page shell with feed header, back button, section close button, title, tab navigation bar rendering `visibleReportingTabs`, and child `<NuxtPage />` outlet. In browser, navigate `/reporting` to `/reporting/releases` via replace.<br>• *Gate*: Component test mounts `pages/reporting.vue` and verifies active tab highlighting and route redirection.<br>• *Red Control*: Direct navigation to `/reporting` without redirecting to `/reporting/releases` fails assertion. |
| **T013** | **Planned** | `wui` | `reporting-shell` | **i18n translation strings** (§1.1, §1.2). Add translation keys for `sidebar.reporting`, `reporting.title`, `reporting.tabs_label`, and tab labels across all supported locales (`en.json`, etc.).<br>• *Gate*: `pnpm run test:i18n-parity` passes with zero missing keys.<br>• *Red Control*: Omitting translation key from any locale file fails `i18n-parity.test.mjs`. |

---

## 2. Phase 2: Releases Tab (v1, Built First, `reporting-releases`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T020** | **Planned** | `api` | `reporting-releases` | **Hub read route: `GET /v1/reporting/releases/daily`** (§2.4.1). Aggregate `release_notes` rows per UTC day into commit totals, breakdown by `kind`, breakdown by `area`, and join with `estate_deploys` for dev/prd deployment stamps. Accepts `from`, `to`, `kind`, `area` query filters.<br>• *Gate*: `TestReportingReleasesDaily` verifies accurate day-by-day commit and deploy aggregation.<br>• *Red Control*: Request with invalid date format returns HTTP 400 `bad_query`. |
| **T021** | **Planned** | `api` | `reporting-releases` | **Hub read route: `GET /v1/reporting/releases/commits`** (§2.4.2). Return paginated, filterable commit notes from `release_notes` with `limit`, `offset`, `from`, `to`, `kind`, `area`, and free-text `search` parameters.<br>• *Gate*: `TestReportingReleasesCommits` verifies search filter matches subject, sha, and trailers.<br>• *Red Control*: Query with `limit=0` or `limit > 200` returns HTTP 400. |
| **T022** | **Planned** | `wui` | `reporting-releases` | **Top KPI cards component: `ReportingReleasesSummary.vue`** (§2.2). Render total releases count, total commits in window, average commits per day, and deploy counts badge.<br>• *Gate*: Component test renders formatted statistics with sample API response.<br>• *Red Control*: Missing or undefined stats object renders fallback dash (`—`) rather than `NaN`. |
| **T023** | **Planned** | `wui` | `reporting-releases` | **Releases filter bar component: `ReleasesFilterBar.vue`** (§2.2). Provide preset range pills (`Today`, `7d`, `30d`, `90d`), kind multi-select pills, area multi-select pills, and search text box with debounced filter reactivity.<br>• *Gate*: Filter bar emits update events on pill clicks and text input.<br>• *Red Control*: Clicking kind pill toggles active selection state correctly. |
| **T024** | **Planned** | `wui` | `reporting-releases` | **Daily commit breakdown list: `ReleasesDailyList.vue` & `pages/reporting/releases.vue`** (§2.2). Render day groups newest first. Header shows date, commit count, kind distribution, and dev/prd deploy chips (or neutral "not recorded" if absent). Under each day, render commit rows linking to `/releases/<ref>` with expandable Lay/Tech trailer drawer.<br>• *Gate*: Component test renders days, verifies commit rows link to `/releases/<ref>`, and asserts trailer expansion toggle works.<br>• *Red Control*: Commits list rendering out of chronological order fails test assertion. |

---

## 3. Phase 2b: Deploy Recording Lane (`reporting-deploys`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T025** | **Planned** | `api` | `reporting-deploys` | **Hub deploy ingest route: `POST /v1/operator/deploys`** (§2.3.2). Ingest deploy record (`env`, `component`, `version`, `commit_sha`, `status`, `workflow_run_id`). Requires operator SA authentication (`operatorAuth`). Inserts into `estate_deploys`.<br>• *Gate*: `TestOperatorDeploysIngest` verifies valid payload inserts row into `estate_deploys`.<br>• *Red Control*: Request without valid operator bearer token returns HTTP 401/403. |
| **T026** | **Planned** | `iac` | `reporting-deploys` | **CI deploy recording webhook steps** (§2.3.2). Add deploy reporting curl step to `.github/workflows/20_hub-build-deploy.yml` and `30_wui-build-deploy.yml` calling `POST /v1/operator/deploys` on deployment completion with SA ID token.<br>• *Gate*: CI workflow dry-run verifies presence and correct argument formatting of webhook step.<br>• *Red Control*: Workflow step omitted allows builds to land without recording deployment stamp. |
| **T027** | **Planned** | `api` | `reporting-deploys` | **Hub periodic deploy reconciliation check** (§2.3.2). Periodic background check running every 2 minutes that compares live served version endpoints (`/version` on Cloud Run, `build.json` on Firebase) in dev and prd against the latest row in `estate_deploys` for that `(env, component)`. If a missed deploy is detected, inserts a reconciliation row into `estate_deploys` with `deployed_by = 'hub-reconcile'` and `workflow_run_id = 'reconcile'`.<br>• *Gate*: `TestDeployReconcileProbe` simulates a live version update omitted by CI webhook and verifies reconciliation worker inserts row marked with `deployed_by = 'hub-reconcile'`.<br>• *Red Control*: Reconcile worker failing to detect a missed deployment or overwriting an existing valid webhook record fails test assertion. |

---

## 4. Phase 3: SQL Tab & Secure Query Engine (`reporting-sql`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T030** | **Planned** | `api` | `reporting-sql` | **SQL static guard & statement interceptor** (§3.1, §3.2). Implement parser in `internal/hub/reporting_sql.go` that inspects incoming query string. Rejects semicolons (multi-statement), comments containing command patterns, non-SELECT keywords (INSERT, UPDATE, DELETE, DROP, ALTER, SET, RESET, etc.), and transaction commands.<br>• *Gate*: Unit test `TestSQLStaticGuard` validates rejection of 20+ malicious/forbidden statement variants.<br>• *Red Control*: Payload `SELECT 1; DROP TABLE messages;` passes static guard -> test fails. |
| **T031** | **Planned** | `api` | `reporting-sql` | **Secure read-only executor with RLS & timeout** (§3.1, §3.3). Execute query inside transaction: `BEGIN TRANSACTION READ ONLY`, `SET LOCAL statement_timeout = '10s'`, and `SELECT set_config('app.tenant_id', $1, true)`. Never set operator scope. Stream results with hard row cap of 2,000. Record query attempt and timing to `sql_query_audit`.<br>• *Gate*: `TestSQLExecutorIsolation` verifies Workspace A admin cannot read Workspace B records.<br>• *Red Control*: Query executing `INSERT` or taking > 10 s is terminated with error; query returning > 2,000 rows sets `truncated: true` and returns exactly 2,000 rows. |
| **T032** | **Planned** | `api` | `reporting-sql` | **Hub route: `POST /v1/reporting/sql`** (§3.7). Mount endpoint under member router, gate with workspace admin role (`admin` in `tenant_members`). Passes query to executor, returns JSON result set (`columns`, `rows`, `row_count`, `truncated`, `duration_ms`).<br>• *Gate*: Endpoint test verifies valid SELECT returns expected columns and rows array.<br>• *Red Control*: Non-admin member calling route receives HTTP 403 Forbidden. |
| **T033** | **Planned** | `wui` | `reporting-sql` | **SQL tab editor & result table component: `pages/reporting/sql.vue`** (§3.6). Monospaced query textarea, "Run Query" button (`Ctrl+Enter` shortcut), execution spinner, status line (execution ms, row count, truncation badge), and three export buttons: Copy (clipboard), Download .csv, Download .json (§3.6). Renders result set in generic HTML table with alternating zebra row styling (`.row--even` / `.row--odd`) and sticky column headers. All three export buttons operate on the returned in-memory result set (up to 2,000 rows).<br>• *Gate*: (1) Copy button writes formatted TSV/CSV text of returned rows (capped at 2,000) to system clipboard; (2) Download .csv button initiates browser download of valid CSV blob with headers for returned rows (capped at 2,000); (3) Download .json button initiates browser download of valid JSON array blob for returned rows (capped at 2,000).<br>• *Red Control*: (1) Copy button failing to copy or attempting to copy >2,000 rows on truncated result fails assertion; (2) Download .csv button producing malformed CSV or downloading >2,000 rows on truncated result fails assertion; (3) Download .json button generating invalid JSON or exporting >2,000 rows on truncated result fails assertion. |

---

## 5. Phase 4: Activity Categories & Placement Integration (`reporting-categories`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T040** | **Planned** | `api` | `reporting-categories` | **Store implementation: `activity_categories` store** (§4.3). Implement Go store interface in `internal/store/categories.go` (`ListCategories`, `CreateCategory`, `UpdateCategory`). Pre-seed canonical root domains (`coding`, `review`, `specs_and_docs`, `tests`, `dispatch`).<br>• *Gate*: Unit test verifies CRUD operations and hierarchical parent-child linking.<br>• *Red Control*: Deleting parent category with active child categories without cascade fails foreign key check. |
| **T041** | **Planned** | `api` | `reporting-categories` | **Hub routes: Category tree API** (§4.5). Mount `GET /v1/reporting/categories` (public to signed-in members), `POST /v1/operator/categories` (operator SA), and `PUT /v1/operator/categories/{path...}` (operator SA).<br>• *Gate*: Test verifies operator can add new child category and read back hierarchical JSON representation.<br>• *Red Control*: Non-operator user attempting to create category returns HTTP 403. |
| **T042** | **Planned** | `orc` | `reporting-categories` | **Lane placement category recording** (§4.4). Update `do_spl_spawn_place` and `spawn-window.sh` to extract `work_kind` and `category_path` from brief header, record them into `fleet_asks` row, and write `lifetime/category.json`.<br>• *Gate*: Spawn placer test verifies placed lane records valid category path in database.<br>• *Red Control*: Placing ask with non-existent category path fails foreign key constraint. |
| **T043** | **Planned** | `api` | `reporting-categories` | **Hierarchical token rollup query: `GET /v1/reporting/tokens/by-category`** (§4.4, §4.5). Aggregate token minutes from `fleet_token_burn_events` joined with `fleet_asks` grouped by category path prefix. Unmatched minutes are grouped under `'uncategorised'`. Supports `depth` parameter (`1`, `2`, or leaf).<br>• *Gate*: `TestTokensByCategoryRollup` verifies child category tokens correctly roll up into parent sum.<br>• *Red Control*: Historical tokens without matching category are labeled 'uncategorised' and never dropped. |

---

## 6. Phase 5: Future Tabs Reservation (`reporting-tabs-future`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T050** | **Planned** | `wui` | `reporting-tabs-future` | **Tokens tab stub (operator-only): `pages/reporting/tokens.vue`** (§5.1, §6.1). Placeholder page component wired to `GET /v1/operator/fleet-tokens` and `GET /v1/reporting/tokens/by-category`. Reserved with `ready: false` in `reporting-tabs.mjs` for operator admins only (`operatorsOnly: true`; standard workspace admins never see it).<br>• *Gate*: Stub route compiles without syntax errors; tab is visible only to operator admins.<br>• *Red Control*: Standard workspace admin or non-operator user viewing or accessing Tokens tab fails assertion. |
| **T051** | **Planned** | `wui` | `reporting-tabs-future` | **Issues tab stub: `pages/reporting/issues.vue`** (§5.2). Placeholder page component for issue cycle time and flow metrics. Reserved with `ready: false`.<br>• *Gate*: Stub route compiles cleanly.<br>• *Red Control*: Hidden while `ready: false`. |
| **T052** | **Planned** | `wui` | `reporting-tabs-future` | **Posts tab stub: `pages/reporting/posts.vue`** (§5.3). Placeholder page component for communication velocity and response times. Reserved with `ready: false`.<br>• *Gate*: Stub route compiles cleanly.<br>• *Red Control*: Hidden while `ready: false`. |
| **T053** | **Planned** | `wui` | `reporting-tabs-future` | **Lanes tab stub: `pages/reporting/lanes.vue`** (§5.4). Placeholder page component for fleet lane operations and success rates. Reserved with `ready: false`.<br>• *Gate*: Stub route compiles cleanly.<br>• *Red Control*: Hidden while `ready: false`. |

---

## 7. Phase 6: End-to-End Verification & Verification Gates (`reporting-proof`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T060** | **Planned** | `test` | `reporting-proof` | **SQL Tab security red controls test** (§3.1, §3.3). Dedicated test script verifying all 7 red controls: cross-tenant data leak (Workspace A admin querying Workspace B), write attempt rejection, DDL rejection, multi-statement rejection, `SET ROLE` rejection, query timeout at 10s, and non-admin access rejection.<br>• *Gate*: Test suite runs all 7 red controls; all pass with expected error codes.<br>• *Red Control*: If any red control succeeds in executing an unauthorized query, test exits non-zero. |
| **T061** | **Planned** | `test` | `reporting-proof` | **End-to-end WUI integration test** (§1.2, §2.2, §3.6). Playwright/e2e test navigating to `/reporting`, asserting redirect to `/reporting/releases`, verifying commit rows render with links to `/releases/<ref>`, navigating to `/reporting/sql`, executing test query, and verifying zebra-striped results table.<br>• *Gate*: `pnpm run test:e2e` passes for reporting section routes.<br>• *Red Control*: Failure of tab navigation or query table rendering fails test run. |
| **T062** | **Planned** | `test` | `reporting-proof` | **Hygiene and drift check** (§6.2). Run `./run -a do_check_dist_hygiene` and `./run -a do_check_fleet_rules_drift` to ensure no prohibited literals, personal names, or unhedged tenant identifiers exist.<br>• *Gate*: Both hygiene actions exit with status 0.<br>• *Red Control*: Unpinned or prohibited literal triggers hygiene check failure. |

---

## 8. Parallel Lane Groups (Disjoint File Sets)

To allow multiple agent lanes to work concurrently without git rebase collisions, tasks are partitioned into independent lane groups with disjoint target paths:

| Lane Group | Task IDs | Target File Paths | Concurrent With |
|---|---|---|---|
| **`reporting-schema`** | `T001`, `T002`, `T003` | `csi-spl-rdb/src/sql/postgres/spool-hub/0202_estate_deploys.sql`<br>`csi-spl-rdb/src/sql/postgres/spool-hub/0203_sql_query_audit.sql`<br>`csi-spl-rdb/src/sql/postgres/spool-hub/0204_activity_categories.sql` | Runs first as foundational migrations. |
| **`reporting-shell`** | `T010`, `T011`, `T012`, `T013` | `csi-spl-wui/src/utils/rail-order.mjs`<br>`csi-spl-wui/src/utils/reporting-tabs.mjs`<br>`csi-spl-wui/src/pages/reporting.vue`<br>`csi-spl-wui/i18n/locales/*.json` | Can build in parallel with `reporting-releases` API. |
| **`reporting-releases`** | `T020`, `T021`, `T022`, `T023`, `T024` | `csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_releases.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/reporting_releases.go`<br>`csi-spl-wui/src/pages/reporting/releases.vue`<br>`csi-spl-wui/src/components/reporting/*` | Starts as soon as `reporting-shell` lands. |
| **`reporting-deploys`** | `T025`, `T026`, `T027` | `csi-spl-api/src/go/spool-hub-api/internal/hub/operator_deploys.go`<br>`.github/workflows/20_hub-build-deploy.yml`<br>`.github/workflows/30_wui-build-deploy.yml` | Can build independently of WUI. |
| **`reporting-sql`** | `T030`, `T031`, `T032`, `T033` | `csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_sql.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/reporting_sql.go`<br>`csi-spl-wui/src/pages/reporting/sql.vue` | Independent lane; requires `T002`. |
| **`reporting-categories`** | `T040`, `T041`, `T042`, `T043` | `csi-spl-api/src/go/spool-hub-api/internal/hub/categories.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/categories.go`<br>`csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`<br>`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh` | Independent backend/orc lane; requires `T003`. |
| **`reporting-proof`** | `T060`, `T061`, `T062` | `csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_sql_test.go`<br>`csi-spl-wui/src/tests/e2e/reporting.test.mjs` | Runs after respective feature lanes land. |
