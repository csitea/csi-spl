# Spec 039 FR-014 build round - plan v0.2 (9 rows, 6 batches)

Epic: SPL-2403  
Spec: csi-spl-doc/specs/039-spool-issues (v0.11.1, FR-014)  
Class: feature  
Kind: specs_and_docs  
Issue: SPL-6489  
Topic: 7132e969-243f-4199-9f2b-a7349bb74733  
Discussion: 7132e969-243f-4199-9f2b-a7349bb74733 (t1; the dispatch holder owns it; the planner reports on task `dispatch-7132e969`)

Owner HUM-10 directives and fleet rules, by pointer:

- t1 `7132e969`, 2026-11-24 (`msg 5c3eccd3`, `msg c92589ce`, `msg 45a3831a`):
  drag-and-drop ordering of epics in the Issues left panel (= their priority),
  sorter (alphabetical, priority, time modified, time created), and filter
  matching the right-hand issues sheet (specified in FR-014, SPL-6455,
  `csi-spl-doc/specs/039-spool-issues/spec.md:205-499`).
- t1 `7132e969`, 2026-11-25 07:29Z (`msg 934a8b8e`, form `52f857ff`): Answer
  **A** — *"The epic takes the priority (1..5) of the epic it lands above and
  keeps its exact place among those of the same priority, so the panel and the
  priority column always agree"*. FR-014 on `origin/master` is already written
  for A: no spec edit is needed.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 1-3 and 5),
  [developer-guide.md](developer-guide.md) (sections 2 and 5.1), and
  [fleet-rules-index.md](fleet-rules-index.md). The rulebook wins over this
  plan.

**What this round is.** Spec 039 `tasks.md:157-236` defines nine build rows,
**T017a-T017i**, for FR-014 (epic panel: drag to order = priority, sort,
filter). Nine rows sit within rulebook 1.1's hard cap of 10 rows. This plan
re-measures every target site on one `origin/master` sha, partitions
`T017a-T017i` into **6 batches of strictly disjoint files (R1)** (at most 3
rows live in Batch 1, 2 in Batch 6, 1 each in Batches 2-5), orders `T017b`
after `T017a`'s workflow 20 deploy (`do_spl_db_bootstrap` on `dev` and `prd`),
assigns each row's kind and author vendor per the fleet kind table, assigns a
cross-vendor R7 reviewer (never `mistral`), specifies red controls (C2) and R2
test columns, and proposes one brief per row. This planner writes no code and
edits no spec 039 file.

**Status: v0.2, revised after cross-vendor review (`c-433`, `claude`, FAIL
W1-W2, N1-N7 on v0.1 `742af3f59`).** Planner: `a-526` (`agy`, main for
`specs_and_docs`). Cross-vendor reviewer: `c-433` (`claude`; `mistral` sits on
no review seat and `grok` is off fleet-wide). Nothing lands on `master` until
`c-433` signs PASS and the dispatch holder gives GO.

**One sha.** Every file:line read is on **`136bcf31c`**
(`136bcf31ce50295e15a70abc7d982ee3b7a4edbe`, `origin/master` at
2026-11-25T10:07Z, after a fresh fetch), verified with `git show` / `git grep`
(n=1 per command; verified unchanged across all cited files on `222f6efe9` at
10:33Z). Lane map, spawn queue, and vendor mix are live state and carry their
own UTC timestamps.

No credential path, token, personal name, OS user name, box shorthand, host, or
customer name appears in this plan or in any proposed row brief.

## 1. Baseline

### 1.1 Nothing of FR-014 is built on `136bcf31c`

- `git grep -n -E 'epic_rank|issues_epics_sort|SetEpicPosition|useEpicPanelList|/position' 136bcf31c -- csi-spl-api/ csi-spl-rdb/ csi-spl-wui/src/ | grep -E 'epic|issues' | wc -l`
  -> **0**.
- **rdb head and claims.**
  `git ls-tree --name-only 136bcf31c csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`
  -> `0323_fleet_ask_queue_order.sql`;
  `git ls-remote origin 'refs/rdb-claims/*' | awk '{print $2}' | sort | tail -1`
  -> `refs/rdb-claims/0323`. `T017a` claims its exact number at work time with
  `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (developer guide
  2.8.3).
- **WUI locales and first-paint budget.**
  `git ls-tree --name-only 136bcf31c csi-spl-wui/i18n/locales/ | wc -l` -> **19**
  locale JSON files.
  `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`
  `metrics.ci_initial_gzip_kb` = **151.9 KB** (ceiling **155.0 KB**, ~3.1 KB
  box headroom / ~2.8 KB CI headroom). `IssueEpicsPanel.vue` is lazy-loaded
  behind `<LazyIssueEpicsPanel v-if="tab === 'issues'" />`
  (`wui:components/ChannelSidebar.vue:508`).

### 1.2 Sites, re-measured on `136bcf31c`

`api:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `rdb:` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `wui:` = `csi-spl-wui/src/`,
`doc:` = `csi-spl-doc/`.

| site | what lives there on `136bcf31c` | used by |
|---|---|---|
| `.github/workflows/20_hub-build-deploy.yml` | triggers on `csi-spl-rdb/src/sql/postgres/spool-hub/**` (`:59`), targets `wanted=(dev prd)` (`:172`), runs `ENV="$ENV" GCP_ACCOUNT="$DEPLOY_SA" DRY_RUN=0 ./csi-spl-orc/run -a do_spl_db_bootstrap` per env before rolling (`:649-665`; a migrate failure fails the deploy `:640-648`) | T017a, T017b (roll order) |
| `rdb:0323_fleet_ask_queue_order.sql` | template for nullable `bigint CHECK (... > 0)` rank + `_by`/`_at` columns under `SET LOCAL lock_timeout = '5s'` (`:22-31`) | T017a (reference) |
| `rdb:0181_issue_events.sql` | `issue_events_record()` function (`:65-110`) and AFTER INSERT/UPDATE trigger on `issues` (`:112-113`): records `'changed'` `'priority'` using `NEW.updated_by`/`NEW.updated_at` ONLY when `OLD.priority IS DISTINCT FROM NEW.priority`; rank-only UPDATEs write zero history rows | T017b (invariant) |
| `api:store/issues.go` | `Issue` struct `:128-165`, `IssuePatch` `:341`, `Issues` interface `:377-420`, Memory `UpdateIssue` `:781-828` (`if p.PriorityOwn && old.Priority != row.Priority` `:807`), Memory `ListIssues` `:939` | T017b |
| `api:store/issues_postgres.go` | `issueCols` `:15-16`, `issueSheetCols` `:20-21`, `scanIssue` `:23-28`, `scanIssueSheet` `:31-36`, Postgres `UpdateIssue` `:277-335` (`UPDATE issues` `:313-323`, `priority_set_at` `:318`), `ListIssueSheet` `:406`, `listIssueRows` `:410-426` (`archived_at IS NULL` `:416`) | T017b |
| `api:store/fleet_ask.go` | precedent for rank gap `AskRankGap = 1024` (`:565`) and ordered position helper `askPositions` (`:334`) | T017b (reference) |
| `api:hub/issues.go` | `toIssueJSON` `:134-148` (empty `assignee ""`, non-nil `labels []`, `deadline ""`), strict JSON decode returning 400 `bad_json` (`:247-249`), `spreadIssuePriority` call in PATCH `:468-470`, `type epicSummary` `:822-832`, `func epicSummaries` `:836-876` (`sort.SliceStable` `:865-870`), `routeIssues` `:880-901` (`OPTIONS` `:893-900`), `issueWriter` `:951-960`, `issuesPreflight` `:1242-1250` (`Access-Control-Allow-Methods: POST, PATCH, DELETE` `:1246`) | T017c |
| `api:hub/topic_priority_spread.go` & `topic_priority_follow.go` | `spreadIssuePriority` `:42`; `applyIssuePriority` `:280-286` (routes discussion priority changes through `UpdateIssue`, so D4 rank clear in `UpdateIssue` covers discussion priority automatically) | T017c / T017b |
| `api:hub/issues_test.go` | `TestIssuesPreflight` `:255-267` (asserts `POST, PATCH, DELETE` at `:267`, must update to `POST, PATCH, PUT, DELETE` + `/position`) | T017c |
| `api:hub/openapi.json` & `openapi_routes_test.go` | `/v1/issues/{ref}` `:6004`, `/v1/view/issues` `:22888`, `epics` schema `:22916-22968`; `TestOpenAPIRoutes` `:314` enforces every `/v1/` route is documented in canonical JSON (`TestOpenAPIRoutesFileForm` `:326`) | T017c |
| `doc:specs/039-spool-issues/contracts/issues-v1.md` | §1 Routes `:6-19` (`OPTIONS` `:19`), §8 `epics[]` summary `:278-280` | T017c |
| `api:auth/issues_sort.go` | `IssuesSortColumns` `:21-24`, `IssuesSortDirs` `:27`, `IsIssuesSort` `:30`, `parseIssuesSort` `:46-62`, `issuesSort` `:67-75` | T017d |
| `api:auth/settings.go` | `HumanSettings.IssuesSort` `:29`, `IssuesSort` struct `:59-62`, `MembershipSettings.IssuesSort` `:84`, `Overlay` `:155-157` | T017d |
| `api:auth/handler.go` | session reply `IssuesSort` `:565,:656`, `prefsRequest.IssuesSort` `:1132`, `parsedPrefs.sort` `:1213,:1243,:1271`, `PUT /api/v1/auth/preferences` write `:1441,:1463,:1478,:1531`, `nilSort` `:1580` | T017d |
| `api:auth/native.go` | native session reply `IssuesSort` `:439,:653` | T017d |
| `api:auth/preferences_test.go` & `api:store/membership_settings.go` / `_test.go` | `SetMembershipSettings` (Postgres `:85`, Memory `:125`, generic jsonb merge — needs no driver edit); `membership_settings_test.go:53-69` (tests both memory & Postgres drivers) | T017d |
| `wui:pages/issues.vue` | phone epic chip strip `[data-test="issues-epic-chips"]` `:111-124`; desktop filter row `.issues-frow` `:180-260` (status `:196-227`, priority `:228-233`, assignee `:240-251`, label `:252-257`, deadline `:259-260`); mobile filter sheet `[data-test="issues-filter-sheet"]` `:616-688` (status `:630-647`, priority `:648-654`, assignee `:662-672`, label `:673-679`, deadline `:680-683`); local `labels` ref `:1296` (assigned `:1421`), `epics = useState('issue-epics')` `:1336`, `refreshEpics` `:1610-1620`, `live.onIssue` `:1627-1634` | T017e, T017f |
| `wui:components/IssueEpicsPanel.vue` | 97 lines: `h2` `:9`, `.sidebar-scroll` `:12`, `NuxtLink` rows `:13-33`, `useState('issue-epics')` `:48`, `createLongPress` `:66` | T017f, T017g |
| `wui:components/ChannelSidebar.vue` & `wui:composables/useSidebarRailOnly.ts` | `<LazyIssueEpicsPanel v-if="tab === 'issues'" />` (`ChannelSidebar.vue:508`); `issuesRailOnly` reads `useState('issue-epics')` (`useSidebarRailOnly.ts:13-14`, untouched — must stay free of `useEpicPanelList` imports) | budget guard (T017e, T017f, T017g) |
| `wui:utils/issues.mjs` & `wui:types/mjs-shims.d.ts` | `matchIssue` (`issues.mjs:176-195`), `mockSummaries` (`:311-317`), `createMockIssues` (`:547-621`); `EpicSummary` (`mjs-shims.d.ts:1856-1866`) | T017f, T017g |
| `wui:utils/person-picker.mjs` & `wui:composables/useIssuePicker.ts` | SPL-4610 case/Greek-sigma folding & substring match `foldCase` / `personMatches` (`person-picker.mjs:8-24`); parent picker row shape `{ id: x.key, label: `${x.key} ${x.title}` }` (`useIssuePicker.ts:94`) | T017f (reuse) |
| `wui:stores/session.ts`, `wui:utils/auth-client-core.mjs`, `wui:composables/useAuthClient.ts` | `issues_sort` claim (`session.ts:53`), `setIssuesSort` (`:194-196,:218`), `saveIssuesSort` (`auth-client-core.mjs:356-359`, `useAuthClient.ts:21`) | T017f |
| `wui:utils/tree-drag.ts` | `TREE_DRAG_START_PX = 5` (`:19`), `TreeDropPlace` (`:23`), `dropWhere` (`:31-42`), `createTreeDrag` (`:108-177`; treats `pen` as `touch` `:139`) | T017g (reuse) |
| `wui:composables/useIssueCtxMenu.ts`, `useIssueMenu.ts`, `components/UiPointMenu.vue` | `menuItemsFor` (`useIssueCtxMenu.ts:45-62`: `tg.top` branch `:50-58`), `useRunIssueItem` (`:176-199`); `PointMenuItem` ALREADY supports `disabled?: boolean` and `hintKey?: string` (`UiPointMenu.vue:103-105`, no edit needed) | T017g |
| `wui:utils/spool-client.mjs` & `spool-client-lazy.mjs` | `listIssues` / `updateIssue` dispatch (`spool-client.mjs:139-143`, `spool-client-lazy.mjs:1736-1782,:2679-2683`) | T017g |
| `doc:doc/help/issues.md`, `doc:doc/md/qto-docs.tsv`, `wui:public/help-md/issues.md` | qto doc `9a453b0c-3925-45ac-9679-09fe841b4968` (`qto-docs.tsv:55`); Epics bullet (`issues.md:76`); `help-sync.test.mjs:20-22` enforces `wui:public/help-md/issues.md` matches `doc:doc/help/issues.md` via `node src/node/help/sync-help.mjs` | T017h |
| `csi-spl-wui/tests/e2e/issues-views-live.proof.mjs` | precedent for signed-in live proof (`dev t1`, `prd e2e`, deletes created rows, restores preferences) | T017i (reference) |

## 2. Rows

Kinds follow the fleet kind table
(`csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md`)
and `csi-spl-cnf/csi-spl/all.env.yaml:1567-1574`. Live
`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` and
`ENV=prd ./run -a do_spl_hub_agent_kinds` (`csi-spl-orc`, 2026-11-25T10:10Z):
`off [grok,qwen], paused [agy until 2026-11-25T14:03:42Z]`.

| kind | live pick at 10:10Z | main / backup | notes |
|---|---|---|---|
| `simple_coding` | `claude` | `claude` / `agy` | never `mistral` (`mistral_coding_allowed: false`, owner msg `91bf8278`; developer guide 5.1 for WUI) |
| `complex_coding` | `claude` | `claude` / `agy` | never `mistral` |
| `tests` | `claude` | `claude` / `agy` | never `mistral` |
| `specs_and_docs` | `claude` (while `agy` paused) | `agy` / `claude` | `T017h` updates `wui:public/help-md/issues.md` via `sync-help.mjs`, so never `mistral` (developer guide 5.1) |
| `i18n` (locale check) | `do_spl_lang_review_gct` | GCT required, `agy` optional | owner msg `36b3ff7f` (2026-11-21): Google Cloud Translation check + committed report under `csi-spl-wui/i18n/lang-review/<run>.json` + `Lang-review: gct <run id>` |

**R7 review (rulebook 2.7.2 & fleet ruling `dc84300a`).** Every row carries a
cross-vendor R7 reviewer before pushing to `master`: `agy` reviews
`claude`-authored rows; `claude` reviews `agy`-authored `T017h`. `mistral` sits
on no review seat (`mistral_review_allowed: false`, owner msgs `65a45673` and
`591ca574`); `grok` is off fleet-wide. Per fleet ruling `dc84300a`
(`refactor-round-98-plan.md:664-667`, `refactor-round-97-plan.md:473`), a
same-vendor `claude` backup waiver seat (rulebook 2.7.2/2.7.3) applies ONLY
while `agy` is out of quota (`2026-11-25T14:03:42Z` at plan time), with
`dc84300a` cited in the row brief if the `claude` backup is used; once `agy`
has quota, `agy` reviews every `claude` row.

### 2.1 Action table

| row | what | kind | vendor | R7 reviewer | red control (C2) | depends on | batch |
|---|---|---|---|---|---|---|---|
| `T017a` | rdb migration: `issues.epic_rank bigint CHECK (epic_rank > 0)`, `epic_rank_by text`, `epic_rank_at timestamptz` under `SET LOCAL lock_timeout = '5s'`, number from `do_rdb_migration_next`; wf 20 runs `DRY_RUN=0 do_spl_db_bootstrap` on `dev` and `prd` before rolling | `simple_coding` | `claude` | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | `INSERT` with `epic_rank = 0` refused by CHECK on throwaway Postgres; accepted with CHECK removed (`lint-migration` green); `information_schema` lists the 3 columns in `dev` and `prd` after wf 20 | none | 1 |
| `T017d` | hub preference `issues_epics_sort` (`{col: manual\|title\|priority\|updated\|created, dir: asc\|desc}` or `null`) in `MembershipSettings`, session claims (`handler.go` + `native.go`), `PUT /api/v1/auth/preferences` | `simple_coding` | `claude` | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | `{col: "rank"}` refused 400 `unsupported_issues_epics_sort`; accepted with shape check removed (memory + Postgres) | none | 1 |
| `T017e` | WUI refactor (no behaviour change): extract status, priority, assignee, label, deadline filter controls from `pages/issues.vue` (`.issues-frow` + mobile filter sheet) into 5 shared components (`IssueFilter*.vue`) | `simple_coding` | `claude` (never `mistral`) | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | unit test asserting all 5 filter fields render via their single component in both desktop filter row and phone sheet: RED on parent inline controls, GREEN after extraction; `bundle-size.mjs` <= parent and <= 155.0 KB | none | 1 |
| `T017b` | hub store: `SetEpicPosition` on memory + Postgres (D1-D6: `FOR UPDATE` open level-1 rows, neighbour adjacency check, take priority of row below, rank unranked open rows above with no `epic_rank_by`/history, 1024 gap + in-tx renumber, single UPDATE for priority+rank+`priority_set_at`+history); `UpdateIssue` clears `epic_rank` on priority or kind change | `complex_coding` | `claude` | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | both drivers (`PRE_PUSH_TIER=full`): stale neighbour moves nothing; drop across priority writes that priority + history; priority PATCH clears `epic_rank` (RED with clear removed); kind change to `issue` clears `epic_rank` | `T017a` wf 20 green on `dev` + `prd` | 2 |
| `T017c` | hub route + summary + CORS + docs: `PUT /v1/issues/{ref}/position` (FR-014.5 refusals, `issueWriter`, `spreadIssuePriority`, `issue` frames), `OPTIONS /v1/issues/{ref}/position` + `PUT` in `issuesPreflight`, `epics[]` in manual order with 7 new fields (unset as `toIssueJSON`), `openapi.json`, `contracts/issues-v1.md` §1 & §8 | `complex_coding` | `claude` | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | preflight test RED with `PUT` omitted from `Access-Control-Allow-Methods`; spread test RED with `spreadIssuePriority` removed; every FR-014.5 refusal (400/403/404/409) verified | `T017b` | 3 |
| `T017f` | WUI epic panel toolbar: `useEpicPanelList` (`useState`) + `utils/epic-panel.mjs` (sort: manual/name/priority/updated/created, closed always last; persisted `issues_epics_sort`; filter: `matchIssue` + SPL-4610 text + kind + open/closed + T017e components; "n of m epics", Clear), phone sort/filter bottom sheets, phone chip strip reading same list (chips do not drag), 19 locales + `do_spl_lang_review_gct` | `complex_coding` | `claude` (never `mistral`) | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | sort unit test RED with closed rows sorted among open ones; `bundle-size.mjs` <= 155.0 KB with `useEpicPanelList` absent from entry chunk (throwaway-branch control: importing it from `ChannelSidebar.vue` fails the check) | `T017c`, `T017d`, `T017e` | 4 |
| `T017g` | WUI epic reorder: `tree-drag.ts` pointer drag (`before`/`after` only; mouse, touch/pen hold-then-move), `Alt+ArrowUp`/`Alt+ArrowDown`, Move up/down/to top in `useIssueCtxMenu.ts` (disabled + hint outside unfiltered manual order), `aria-live` announcement, optimistic move + 409 rollback + inline error, `setEpicPosition` client + mock, 19 locales + `do_spl_lang_review_gct` | `complex_coding` | `claude` (never `mistral`) | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | e2e drag RED with drag left enabled under non-manual sort; 409 e2e case RED with optimistic rollback removed; `bundle-size.mjs` <= 155.0 KB | `T017f` | 5 |
| `T017h` | help: update Epics section in qto doc `9a453b0c-3925-45ac-9679-09fe841b4968` -> `do_spl_doctree_export_md` (`doc/help/issues.md`) -> `node src/node/help/sync-help.mjs` (`wui:public/help-md/issues.md`) | `specs_and_docs` | `agy`, backup `claude` (never `mistral`) | `claude` if `agy` authored; `agy` (or `claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`) if `claude` authored; never `mistral` | `QTO_DRIFT_LIVE=1 ... do_check_qto_doc_drift` catches hand-edited md; `sync-help.mjs --check` fails if `wui:public/help-md/issues.md` drifts | `T017g` | 6 |
| `T017i` | live proof `csi-spl-wui/tests/e2e/issues-epic-order-live.proof.mjs`, run n=1 on `dev` (`t1`) and `prd` (`e2e`) after `T017c..g` are served: drag across priority line persists at hub, second tab updates live without reload, sort survives reload, cleans up created rows and restores sort preference | `tests` | `claude` (never `mistral`) | `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never `mistral`) | proof run against `dev` before `T017c` is served (or against an unknown `/position` route) fails step 1 with 404/405 | `T017c..T017g` served on `dev` and `prd` | 6 |

Row count: **9** (within rulebook 1.1's hard cap of 10). Max rows live in any
batch: **3** (Batch 1).

### 2.2 Batches and disjoint files (R1, R16)

No file path appears in two rows of any batch. Dependent batches place within
30 minutes of their prerequisites landing (R16).

- **Batch 1: `T017a`, `T017d`, `T017e`.**
  - **`T017a`** (`csi-spl-rdb/` only): new
    `rdb:<NNNN>_issue_epic_rank.sql` (number claimed via `do_rdb_migration_next`).
  - **`T017d`** (`api:auth/` + `api:store/membership_settings_test.go` only):
    `api:auth/issues_sort.go` (or new `api:auth/issues_epics_sort.go`),
    `api:auth/settings.go`, `api:auth/handler.go`, `api:auth/native.go`,
    `api:auth/preferences_test.go`, `api:store/membership_settings_test.go`.
  - **`T017e`** (`csi-spl-wui/` only): new
    `wui:components/IssueFilterStatus.vue`, `IssueFilterPriority.vue`,
    `IssueFilterAssignee.vue`, `IssueFilterLabel.vue`, `IssueFilterDeadline.vue`;
    `wui:pages/issues.vue`; new
    `csi-spl-wui/tests/unit/issue-filter-components.test.mjs`.
  - **Disjoint check:** `T017a` touches `csi-spl-rdb/`; `T017d` touches
    `api:auth/` + `api:store/membership_settings_test.go`; `T017e` touches
    `csi-spl-wui/`. Zero overlap.
- **Migration roll gate between Batch 1 and Batch 2 (N1):** `T017a`'s push to
  `master` triggers `.github/workflows/20_hub-build-deploy.yml` (`:59`,
  `wanted=(dev prd)` `:172`), which runs
  `ENV="$ENV" GCP_ACCOUNT="$DEPLOY_SA" DRY_RUN=0 ./csi-spl-orc/run -a do_spl_db_bootstrap`
  before rolling each env (`:649-665`). `T017b` places only after `T017a`'s
  workflow 20 run is green on both `dev` and `prd`
  (`gh run list --commit <T017a sha>`; `ENV=dev|prd ./run -a do_check_deploy_lag`)
  and `T017a`'s `information_schema` check confirms all three columns exist in
  both environments.
- **Batch 2: `T017b`** (after `T017a`'s wf 20 run is green on `dev` and `prd`).
  - **`T017b`** (`api:store/` only): `api:store/issues.go`,
    `api:store/issues_postgres.go`, new `api:store/issues_epic_position.go`,
    new `api:store/issues_epic_position_test.go`.
- **Batch 3: `T017c`** (after `T017b` lands).
  - **`T017c`** (`api:hub/` + `contracts/issues-v1.md` only):
    `api:hub/issues.go`, new `api:hub/issues_epic_position.go`,
    `api:hub/issues_test.go`, new `api:hub/issues_epic_position_test.go`,
    `api:hub/openapi.json`,
    `doc:specs/039-spool-issues/contracts/issues-v1.md`.
- **Batch 4: `T017f`** (after `T017c`, `T017d`, `T017e` land).
  - **`T017f`** (`csi-spl-wui/` only): new `wui:utils/epic-panel.mjs`, new
    `wui:composables/useEpicPanelList.ts`, `wui:components/IssueEpicsPanel.vue`,
    `wui:components/IssueFilterStatus.vue` (if `open`/`closed` group support
    was not already wired as an optional prop in `T017e`),
    `wui:pages/issues.vue` (phone chip strip + shared `issue-labels` state),
    `wui:stores/session.ts`, `wui:utils/auth-client-core.mjs`,
    `wui:composables/useAuthClient.ts`, `wui:utils/issues.mjs` (`mockSummaries`
    only), `wui:types/mjs-shims.d.ts`, all 19 `csi-spl-wui/i18n/locales/*.json`,
    new `csi-spl-wui/i18n/lang-review/<run>.json` (`do_spl_lang_review_gct`),
    new `csi-spl-wui/tests/unit/epic-panel.test.mjs`, new
    `csi-spl-wui/tests/e2e/issues-epic-panel.test.mjs`.
- **Batch 5: `T017g`** (after `T017f` lands — serialised because both edit
  `IssueEpicsPanel.vue`, `useEpicPanelList.ts`, `utils/issues.mjs`, and
  `i18n/locales/*.json`).
  - **`T017g`** (`csi-spl-wui/` only): `wui:components/IssueEpicsPanel.vue`,
    `wui:composables/useEpicPanelList.ts`, `wui:composables/useIssueCtxMenu.ts`,
    `wui:composables/useIssueMenu.ts`, `wui:utils/spool-client.mjs`,
    `wui:utils/spool-client-lazy.mjs`, `wui:utils/issues.mjs` (mock
    `setPosition`), `wui:types/mjs-shims.d.ts`, all 19
    `csi-spl-wui/i18n/locales/*.json`, new
    `csi-spl-wui/i18n/lang-review/<run>.json` (`do_spl_lang_review_gct`), new
    `csi-spl-wui/tests/unit/epic-reorder.test.mjs`, new
    `csi-spl-wui/tests/e2e/issues-epic-reorder.test.mjs`.
- **Batch 6: `T017h`, `T017i`** (after `T017c..T017g` are served on `dev` and
  `prd`).
  - **`T017h`**: `doc:doc/help/issues.md` (exported from qto doc
    `9a453b0c-3925-45ac-9679-09fe841b4968` via `do_spl_doctree_export_md`) and
    `wui:public/help-md/issues.md` (regenerated via
    `cd csi-spl-wui && node src/node/help/sync-help.mjs`).
  - **`T017i`**: new
    `csi-spl-wui/tests/e2e/issues-epic-order-live.proof.mjs`.
  - **Disjoint check:** `T017h` touches `doc/help/issues.md` +
    `wui:public/help-md/issues.md`; `T017i` touches
    `tests/e2e/issues-epic-order-live.proof.mjs`. Zero overlap.

### 2.3 R3: live and queued lanes, read 2026-11-25T10:10Z

`lane-map.sh --check <all 26 existing FR-014 target paths> --agent a-526`
(2026-11-25T10:10:55Z, n=1):

- **Direct ownership collisions (exit 3):** **0**. No live lane on any machine
  records any of the 26 existing paths.
- **Lanes with no files recorded (exit 4):** 15 live lanes on another fleet
  box (`c-029`, `c-041`, `c-086`, `c-146`, `c-187`, `c-341`, `c-385`, `c-398`,
  `c-403`, `c-405`, `c-728`, `c-927`, `c-936`, `c-957`, `c-965`). One of them
  is issue-adjacent: **`c-405`** (`c002-issue-comment-edit-mark`, brief read
  at 10:11Z: edits `IssueDetailFrame.vue`, `useCardEdit.ts`, `MessageCard.vue`,
  `IssueHistory.vue`, and `internal/store/issue_history.go`, plus an existing
  issue e2e file — NOT `IssueEpicsPanel.vue`, `issues.vue`, `store/issues.go`,
  or `hub/issues.go`). By rule, exit 4 is not free: the orchestrator re-runs
  `lane-map.sh --check` per row before each batch spawn (R3) and verifies
  `c-405` has landed or stayed disjoint before placing WUI/store rows.
- **Spawn queue (`do_spl_spawn_queue`, 10:10Z, 5 queued, 0 placing):**
  `4e9b7e69` (box link watch doc), `8743ca86` (calendar week multiday bars),
  `5b1b7d82` (s186 M9 qto-sync), `335da76e` (agent-cred-sync), `343c229b`
  (spec 149 review seat). None touches any FR-014 path.

### 2.4 Technical notes for the holder and rows (no owner question)

- **N1. Automatic CI migration roll (`20_hub-build-deploy.yml`) between `T017a`
  and `T017b`.** On `136bcf31c`, `.github/workflows/20_hub-build-deploy.yml:59`
  triggers on `csi-spl-rdb/src/sql/postgres/spool-hub/**`, runs
  `wanted=(dev prd)` (`:172`), and executes
  `ENV="$ENV" GCP_ACCOUNT="$DEPLOY_SA" DRY_RUN=0 ./csi-spl-orc/run -a do_spl_db_bootstrap`
  before rolling each env (`:649-665`; a migrate failure fails the deploy
  `:640-648`). No manual `do_spl_db_bootstrap` run or owner DB go is needed:
  `T017a`'s push migrates both `dev` and `prd` through CI, and `T017b`'s own
  wf 20 run also migrates before rolling. Still, `T017b` places only after
  `T017a`'s wf 20 run is green on both `dev` and `prd` (`do_check_deploy_lag`)
  and `information_schema` confirms the three columns in both environments
  (`tasks.md:162-165`).
- **N2. Postgres `issue_events_record` trigger (`rdb:0181:65-113`) & rank-only
  updates.** The trigger (`issue_events_record()` `:65-110`, `CREATE TRIGGER`
  `:112-113`) automatically inserts a `'changed'` `'priority'` history row
  using `NEW.updated_by` / `NEW.updated_at` when
  `OLD.priority IS DISTINCT FROM NEW.priority`, and writes zero history rows
  when only `epic_rank` / `epic_rank_by` / `epic_rank_at` change. Therefore,
  in `T017b`, a rank-only update (same-priority drop, auto-ranking unranked
  open rows above, or renumbering on gap exhaustion) MUST NOT overwrite
  `updated_by` or `updated_at` (so the "Updated" sort never jumps on a
  same-priority drag), whereas a cross-priority drop updates `priority`,
  `priority_set_at`, `updated_by`, `updated_at`, `epic_rank`, `epic_rank_by`,
  and `epic_rank_at` in one `UPDATE` statement (and mirrors `recordLocked` +
  `stampPriorityLocked` in the Memory driver).
- **N3. `T017h` must also run `sync-help.mjs` (never `mistral`).**
  `csi-spl-wui/tests/unit/help-sync.test.mjs:20-22` fails CI whenever
  `csi-spl-doc/doc/help/issues.md` changes without regenerating
  `csi-spl-wui/src/public/help-md/issues.md`. Therefore `T017h` edits qto doc
  `9a453b0c-3925-45ac-9679-09fe841b4968`, runs
  `cd csi-spl-orc && ./run -a do_spl_doctree_export_md`, and then runs
  `cd csi-spl-wui && node src/node/help/sync-help.mjs` in the same commit.
  Because it touches `csi-spl-wui/`, `T017h` never goes to `mistral`
  (developer guide 5.1).
- **N4. `UiPointMenu.vue` already supports disabled items with hints.**
  `PointMenuItem` (`wui:components/UiPointMenu.vue:103-105`) already has
  `disabled?: boolean` and `hintKey?: string`, so `T017g` sets them directly
  in `useIssueCtxMenu.ts` without modifying `UiPointMenu.vue`.
- **N5. `T017c` updates `openapi.json` and `TestIssuesPreflight`.**
  `TestOpenAPIRoutes` (`api:hub/openapi_routes_test.go:314`) fails unless
  `PUT /v1/issues/{ref}/position` is documented in canonical JSON in
  `api:hub/openapi.json` (plus the 7 new `epics[]` properties at `:22916`),
  and `TestIssuesPreflight` (`api:hub/issues_test.go:267`) asserts the exact
  `Access-Control-Allow-Methods` header (`POST, PATCH, PUT, DELETE`).
- **N6. Shared labels state for `IssueEpicsPanel.vue` (`T017f`).**
  On `136bcf31c`, `pages/issues.vue:1296` declares workspace `labels` as a
  local ref (assigned at `:1421`), whereas `epics` is shared via
  `useState('issue-epics')` (`:1336`). To render `IssueFilterLabel` inside
  `IssueEpicsPanel.vue` (which mounts in `ChannelSidebar.vue` outside
  `pages/issues.vue`), `T017f` promotes `labels` in `pages/issues.vue` to
  `useState<IssueLabel[]>('issue-labels', () => [])` so both the sheet and the
  panel share the same live label catalogue.
- **N7. `T017i` red-control timing and tenant safety.**
  Per spec 039 `tasks.md:230-236` and `issues-views-live.proof.mjs`, `T017i`
  runs on `dev` (`TENANT=t1`) and `prd` (`TENANT=e2e` at
  `https://e2e.<domain>`, never scripted sign-in on `prd t1`), deletes every
  epic it creates, and restores the test user's `issues_epics_sort`. Its red
  control ("first step fails 404/405 against a hub without `PUT
  /v1/issues/{ref}/position`") can be captured either by running the draft
  proof against `dev` before `T017c` rolls, or against a local/pre-`T017c` hub
  fixture.
- **N8. Clean-code ceilings (developer guide 2.2.1-2.2.2).**
  Every new or edited function stays at most 75 lines, nesting depth <= 4,
  parameters <= 7 (Go) / <= 5 (TS/Vue), no `SELECT *`. Splitting new Go code
  into `store/issues_epic_position.go` and `hub/issues_epic_position.go` and
  WUI logic into `utils/epic-panel.mjs`, `composables/useEpicPanelList.ts`, and
  the five `IssueFilter*.vue` components keeps every file well under the caps.

## 3. Proposed row briefs

Every row brief carries: `Epic: SPL-2403`,
`Spec: csi-spl-doc/specs/039-spool-issues`, `Class: feature`, its `Kind:`, its
section 2.1 action-table row verbatim (R4), its assigned R7 reviewer seat,
"re-measure every cited file:line on `origin/master` at work time", its red
control(s) and test column (R2), release-note trailers
(`csi-spl-doc/doc/help/release-notes.md`), and the fleet's standing Never list
(touch no file outside `Files: ONLY`, no prd writes/applies without owner go,
no installs, no keys, no owner-topic posts, public repo hygiene: no
customer/host/box/OS-user/personal name, commit as the repo's identity with no
AI trailers, explicit pathspecs, no force-push). Each row files its own issue
under epic `SPL-2403` at placement and cites it in its commit subject scope,
e.g. `feat(api, SPL-<n>): ... (spec 039 T017b)`.

### 3.1 `T017a` - rdb migration: `issues.epic_rank`, `epic_rank_by`, `epic_rank_at`

- **Kind:** `simple_coding`. **Vendor:** `claude`. **R7:** `agy` (`claude`
  backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never
  `mistral`). **Batch:** 1. `PRE_PUSH_TIER=full` (migration).
- **Files: ONLY** new `rdb:<NNNN>_issue_epic_rank.sql` (number claimed with
  `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`).
- **Work:**
  1. Claim the next migration number via `do_rdb_migration_next` (developer
     guide 2.8.3).
  2. Write the forward-only, idempotent DDL mirroring `rdb:0323`:
     `SET LOCAL lock_timeout = '5s';`
     `ALTER TABLE issues ADD COLUMN IF NOT EXISTS epic_rank bigint CHECK (epic_rank > 0);`
     `ALTER TABLE issues ADD COLUMN IF NOT EXISTS epic_rank_by text;`
     `ALTER TABLE issues ADD COLUMN IF NOT EXISTS epic_rank_at timestamptz;`
     Nullable, no backfill, no rewrite; existing `issues` RLS policies cover
     the new columns.
  3. After landing on `master`, watch `.github/workflows/20_hub-build-deploy.yml`
     (which triggers on `csi-spl-rdb/src/sql/postgres/spool-hub/**` `:59` and
     runs `DRY_RUN=0 ./csi-spl-orc/run -a do_spl_db_bootstrap` on `dev` and
     `prd` `:172,:649-665`), verify `ENV=dev ./run -a do_check_deploy_lag` and
     `ENV=prd ./run -a do_check_deploy_lag`, and confirm `information_schema`
     lists `epic_rank`, `epic_rank_by`, `epic_rank_at` in both environments
     (`tasks.md:164-165`) before reporting ready for Batch 2 (`T017b`).
- **Done and red control (C2):** `lint-migration` green; on a throwaway
  Postgres with the migration applied, `INSERT` with `epic_rank = 0` is refused
  by the CHECK constraint, and the same file with the CHECK removed accepts it
  (both outputs in commit body); `information_schema` check green on `dev` and
  `prd` after wf 20 completes. `Docs: none (DDL matches spec 039 FR-014.5)`.
- **Test column (R2):** `cd csi-spl-iac && ./run -a do_check_pre_push_lint`
  (`lint-migration`), `PRE_PUSH_TIER=full ./run -a do_check_pre_push`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (runs all migrations on
  Postgres, including `TestRLSCoversEveryTenantTable`), wf 20 green +
  `do_check_deploy_lag` on `dev` and `prd`.
- **Not touched:** `csi-spl-api/`, `csi-spl-wui/`, `csi-spl-orc/`,
  `csi-spl-doc/`.

### 3.2 `T017d` - hub preference `issues_epics_sort`

- **Kind:** `simple_coding`. **Vendor:** `claude`. **R7:** `agy` (`claude`
  backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never
  `mistral`). **Batch:** 1. `PRE_PUSH_TIER=full` (store membership settings
  test on Postgres).
- **Files: ONLY** `api:auth/issues_sort.go` (or new
  `api:auth/issues_epics_sort.go`), `api:auth/settings.go`,
  `api:auth/handler.go`, `api:auth/native.go`, `api:auth/preferences_test.go`,
  `api:store/membership_settings_test.go`.
- **Work:**
  1. Define `IssuesEpicsSortColumns = []string{"manual", "title", "priority", "updated", "created"}`,
     `IsIssuesEpicsSort`, `parseIssuesEpicsSort` (refusing unknown col, dir, or
     extra JSON field with 400 `unsupported_issues_epics_sort`; `null` clears),
     and `(h *Handler) issuesEpicsSort`, mirroring `api:auth/issues_sort.go:21-75`.
  2. Add `IssuesEpicsSort *IssuesSort` to `HumanSettings` (`settings.go:29`),
     `MembershipSettings` (`settings.go:84`, json `issues_epics_sort,omitempty`),
     and `Overlay` (`settings.go:155`).
  3. Wire `issues_epics_sort` into `handler.go` session reply (`:565,:656`),
     `native.go` session reply (`:439,:653`), and `PUT /api/v1/auth/preferences`
     (`handler.go:1132,:1213,:1243,:1271,:1441-1531`). No migration is needed
     (`tenant_memberships.settings` jsonb, rdb 0078).
- **Done and red control (C2):** `{col: "rank", dir: "asc"}` is refused with
  400 `unsupported_issues_epics_sort` (and accepted when the shape check is
  removed: RED then GREEN in commit body); valid values and `null` round-trip
  through both memory and Postgres `MembershipSettings` and appear on session
  claims. `Docs: none (preference contract already in spec 039 FR-014.2/FR-014.5)`.
- **Test column (R2):** `go test ./internal/auth/... ./internal/store -run 'TestPreferences|TestMembershipSettings'`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push`, plus `do_check_deploy_lag`
  on `dev` and `prd`.
- **Not touched:** `csi-spl-rdb/`, `api:store/issues*.go`, `api:hub/`,
  `csi-spl-wui/`.

### 3.3 `T017e` - WUI refactor: extract 5 shared filter field components

- **Kind:** `simple_coding`. **Vendor:** `claude` (never `mistral`). **R7:**
  `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling
  `dc84300a`; never `mistral`). **Batch:** 1.
- **Files: ONLY** new `wui:components/IssueFilterStatus.vue`,
  `wui:components/IssueFilterPriority.vue`,
  `wui:components/IssueFilterAssignee.vue`,
  `wui:components/IssueFilterLabel.vue`,
  `wui:components/IssueFilterDeadline.vue`; `wui:pages/issues.vue`; new
  `csi-spl-wui/tests/unit/issue-filter-components.test.mjs`.
- **Work:**
  1. Extract the five filter controls duplicated between `.issues-frow`
     (`wui:pages/issues.vue:196-260`) and `[data-test="issues-filter-sheet"]`
     (`:630-683`) into five focused components (`IssueFilterStatus`,
     `IssueFilterPriority`, `IssueFilterAssignee`, `IssueFilterLabel`,
     `IssueFilterDeadline`), each <= 75 lines/func and <= 5 params.
  2. Preserve every existing `data-test`, ARIA attribute, CSS class/style,
     keyboard flow, and mobile layout (`mode="sheet"` vs `mode="row"` for
     status radio chips vs dropdown; `tall` prop on `PersonPicker`) with ZERO
     behaviour change on the Issues sheet or phone filter sheet.
  3. Keep all five components imported ONLY by `pages/issues.vue` (never
     `ChannelSidebar.vue` or any layout) so the entry chunk does not grow.
- **Done and red control (C2):**
  - `tests/unit/issue-filter-components.test.mjs` asserts `pages/issues.vue`
    renders all five filter fields through their single shared component in
    both desktop `.issues-frow` and mobile `[data-test="issues-filter-sheet"]`
    (RED on parent tree with inline controls, GREEN after extraction).
  - `node src/node/test/bundle-size.mjs` on a mock generate reads
    `<= ci_initial_gzip_kb` (155.0 KB) and `<= parent`.
  - `Docs: none (pure UI component refactor, no behaviour change)`.
- **Test column (R2):** `pnpm run typecheck`, `pnpm run test:unit` (including
  `issue-filter-components`, `cleancode`, `unused-exports`, `font-size`,
  `focus-tokens`, `i18n-*`), Chrome mock e2e on generated bundle:
  `issues.test.mjs`, `issues-mobile.test.mjs`, `issues-frow-density.test.mjs`,
  `issues-list-url.test.mjs`, `issues-unread-filter.test.mjs`, plus every file
  selected by `WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`;
  `bundle-size.mjs`; `do_check_deploy_lag` on `dev` and `prd`.
- **Not touched:** `wui:components/IssueEpicsPanel.vue`,
  `wui:components/ChannelSidebar.vue`, `wui:composables/useIssueFilters.ts`,
  `wui:utils/issues.mjs`, `csi-spl-wui/i18n/`, `csi-spl-api/`, `csi-spl-rdb/`.

### 3.4 `T017b` - hub store: `SetEpicPosition` and rank clear on priority/kind update

- **Kind:** `complex_coding`. **Vendor:** `claude`. **R7:** `agy` (`claude`
  backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never
  `mistral`). **Batch:** 2 (after `T017a`'s wf 20 deploy is green on `dev` and
  `prd`, N1). `PRE_PUSH_TIER=full`.
- **Files: ONLY** `api:store/issues.go`, `api:store/issues_postgres.go`, new
  `api:store/issues_epic_position.go`, new
  `api:store/issues_epic_position_test.go`.
- **Work:**
  1. Add `EpicRank int64`, `EpicRankBy string`, `EpicRankAt time.Time` to
     `store.Issue` (`issues.go:128`), and read them in `issueCols`,
     `issueSheetCols`, `scanIssue`, and `scanIssueSheet`
     (`issues_postgres.go:15-36`).
  2. Add `EpicRankGap = 1024`, sentinel errors `ErrNotEpic`, `ErrBadPosition`,
     `ErrEpicClosed`, `ErrStalePosition`, `EpicPositionResult`, and
     `SetEpicPosition(ctx, tenant string, number, before, after int, by string, now time.Time) (EpicPositionResult, error)`
     to `store.Issues` (`issues.go:377`).
  3. Implement `SetEpicPosition` identically on Memory and Postgres
     (`issues_epic_position.go`, referencing `store/fleet_ask.go:334,565`):
     - In Postgres, lock all live open level-1 rows of `tenant` `FOR UPDATE`
       in one transaction; check `{ref}` exists (`ErrNotFound`), is level 1
       (`ErrNotEpic`), is open (`ErrEpicClosed`), `before`/`after` are not both
       0 and neither equals `number` (`ErrBadPosition`), any named neighbour is
       live open level-1 (`ErrEpicClosed` if closed, `ErrStalePosition` if
       gone/not epic), and the neighbours are adjacent in the current manual
       order (open -> priority asc -> ranked first, rank asc -> number asc;
       else `ErrStalePosition`, moving nothing).
     - Target priority = priority of `after` (the row it now sits directly
       above), or priority of `before` when `after == 0` (landed last).
     - Assign ranks (gap 1024) to any unranked open rows of that target
       priority sitting above the drop spot (no `epic_rank_by`, no
       `updated_by`/`updated_at`, no history row, N2); compute midpoint rank
       between neighbours, or renumber that priority's ranked rows by 1024 in
       the same transaction when the gap runs out.
     - Update the moved row in ONE `UPDATE`: if priority changed, write
       `priority`, `priority_set_at = now`, `updated_by = by`,
       `updated_at = now`, `epic_rank`, `epic_rank_by = by`, `epic_rank_at = now`
       (triggers `issue_events_record` in Postgres and `recordLocked` +
       `stampPriorityLocked` in Memory); if priority stayed the same, write
       ONLY `epic_rank`, `epic_rank_by = by`, `epic_rank_at = now` (no
       `updated_by`/`updated_at` change, no history row, N2).
     - Return the moved `Issue`, whether priority changed, every row whose
       priority or rank changed (for `T017c` frames), and all live rows (for
       `T017c` `epics[]`).
  4. In both Memory (`issues.go:781-828`) and Postgres
     (`issues_postgres.go:313-323`) `UpdateIssue`, clear `epic_rank = NULL`,
     `epic_rank_by = NULL`, `epic_rank_at = NULL` in the same update whenever
     priority changes (D4, covering PATCH, agent update, and
     `applyIssuePriority`) OR kind stops being level 1 (D6). Closed rows keep
     their rank (D5).
- **Done and red controls (C2):** both drivers (Memory + Postgres,
  `PRE_PUSH_TIER=full`) pass all D1-D6 cases, including:
  1. stale neighbour returns `ErrStalePosition` and changes zero rows;
  2. drop across a priority boundary updates priority, `priority_set_at`, and
     writes a `'priority'` history event; same-priority drop writes zero
     history events and leaves `updated_at` untouched;
  3. priority `UpdateIssue` clears `epic_rank` (RED with the clear removed,
     GREEN with it restored, both in commit body);
  4. gap exhaustion renumbers in-transaction cleanly; kind change from `epic`
     to `issue` clears `epic_rank`; reopen preserves rank.
  `Docs: none (store behaviour implements spec 039 FR-014.1 D1-D6)`.
- **Test column (R2):** `go test ./internal/store/...`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push`, `do_check_deploy_lag` on
  `dev` and `prd`.
- **Not touched:** `csi-spl-rdb/`, `api:auth/`, `api:hub/`, `csi-spl-wui/`.

### 3.5 `T017c` - hub route `PUT /v1/issues/{ref}/position`, `epics[]` summary, CORS, OpenAPI, contract

- **Kind:** `complex_coding`. **Vendor:** `claude`. **R7:** `agy` (`claude`
  backup waiver ONLY while `agy` is out of quota, ruling `dc84300a`; never
  `mistral`). **Batch:** 3 (after `T017b` lands). `PRE_PUSH_TIER=full`.
- **Files: ONLY** `api:hub/issues.go`, new `api:hub/issues_epic_position.go`,
  `api:hub/issues_test.go`, new `api:hub/issues_epic_position_test.go`,
  `api:hub/openapi.json`,
  `doc:specs/039-spool-issues/contracts/issues-v1.md`.
- **Work:**
  1. Extend `epicSummary` (`hub/issues.go:822-832`) and `epicSummaries`
     (`:836-876`) with `priority`, `rank` (`*int64`, JSON `null` when
     unranked), `assignee` (`""` when unset), `labels` (`[]string{}`, never
     `null`), `deadline` (`""` when unset), `created_at`, `updated_at`, and
     sort `epics[]` in manual order (FR-014.1: open before closed, priority
     asc, ranked first with rank asc, number asc).
  2. Register `PUT /v1/issues/{ref}/position` and
     `OPTIONS /v1/issues/{ref}/position` in `routeIssues` (`:880-901`), and
     update `issuesPreflight` (`:1246`) to `POST, PATCH, PUT, DELETE` (update
     `TestIssuesPreflight` at `issues_test.go:267`).
  3. Implement `handleSetEpicPosition` (`hub/issues_epic_position.go`):
     - Gate with `issueWriter` (`:951`, D7: 403 `forbidden`, 402 unpaid);
     - Decode `{"before": string|null, "after": string|null}` with
       `DisallowUnknownFields()` returning 400 `bad_json` on malformed JSON or
       unknown fields (author's choice, matching existing hub convention at
       `hub/issues.go:247-249` and `hub/fleet_ask_order.go:143`); an
       unparseable non-null neighbour ref string returns 400 `bad_position`
       (author's choice), while a parsed neighbour key that does not exist or
       is no longer adjacent returns 409 `stale_position` per FR-014.5;
     - Map store errors to FR-014.5 status/tokens: 400 `not_epic`, 400
       `bad_position`, 409 `epic_closed`, 409 `stale_position`, 404 `not_found`;
     - Fan out an `issue` `op: "update"` frame for every row whose priority or
       rank changed;
     - If priority changed, call `s.spreadIssuePriority(ctx, tenant, number, actor)`
       after the transaction commits (FR-014.1 D1, mirroring `:468-470`);
     - Answer 200 `{"issue": toIssueJSON(...), "epics": epicSummaries(...)}`.
  4. Document `PUT /v1/issues/{ref}/position` and the 7 new `epics[]` fields in
     `api:hub/openapi.json` (canonical JSON, `TestOpenAPIRoutes` &
     `TestOpenAPIRoutesFileForm` green) and update `contracts/issues-v1.md` §1
     and §8.
- **Done and red controls (C2):**
  1. Preflight test verifies `OPTIONS /v1/issues/SPL-1/position` returns 204
     with `PUT` in `Access-Control-Allow-Methods` (RED with `PUT` left out,
     GREEN with it in);
  2. Priority-spread test verifies moving an epic across a priority line
     spreads its new priority to linked discussions/issues (RED with
     `spreadIssuePriority` removed, GREEN with it in);
  3. Tests cover every FR-014.5 refusal (400/402/403/404/409), frame fan-out,
     and `epics[]` JSON shape (including `rank: null` and `labels: []`).
- **Test column (R2):** `go test ./internal/hub/...`,
  `TestOpenAPIRoutes`, `TestOpenAPIRoutesFileForm`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push`, `do_check_deploy_lag` on
  `dev` and `prd`.
- **Not touched:** `csi-spl-rdb/`, `api:store/`, `api:auth/`, `csi-spl-wui/`.

### 3.6 `T017f` - WUI epic panel toolbar: sort, filter, phone sheets, chip strip, 19 locales

- **Kind:** `complex_coding`. **Vendor:** `claude` (never `mistral`). **R7:**
  `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling
  `dc84300a`; never `mistral`). **Batch:** 4 (after `T017c`, `T017d`, `T017e`
  land).
- **Files: ONLY** new `wui:utils/epic-panel.mjs`, new
  `wui:composables/useEpicPanelList.ts`, `wui:components/IssueEpicsPanel.vue`,
  `wui:components/IssueFilterStatus.vue` (add optional `includeGroups` prop for
  Open / Closed if not already present from `T017e`), `wui:pages/issues.vue`
  (chip strip `:111-124` reads `useEpicPanelList` + share `labels` via
  `useState('issue-labels')`, N6), `wui:stores/session.ts`,
  `wui:utils/auth-client-core.mjs`, `wui:composables/useAuthClient.ts`,
  `wui:utils/issues.mjs` (`mockSummaries` `:311`), `wui:types/mjs-shims.d.ts`
  (`EpicSummary` `:1856`), all 19 `csi-spl-wui/i18n/locales/*.json`, new
  `csi-spl-wui/i18n/lang-review/<run>.json`, new
  `csi-spl-wui/tests/unit/epic-panel.test.mjs`, new
  `csi-spl-wui/tests/e2e/issues-epic-panel.test.mjs`.
- **Work:**
  1. Pure logic in `wui:utils/epic-panel.mjs`:
     - Sort modes (FR-014.2): `manual` (fixed direction, FR-014.1 order),
       `title` (`Intl.Collator(locale, { numeric: true })` per FR-014.2,
       default `asc`), `priority` (default `asc`, ties by manual order),
       `updated` (default `desc`, own `updated_at`), `created` (default `desc`,
       own `created_at`). Closed rows (`done`, `diss`) ALWAYS stay after open
       rows in every sort.
     - Filter (FR-014.3): reuse `matchIssue` (`utils/issues.mjs:176`) for
       priority, assignee (`me`, `none`, person), label, deadline (`<=` minute),
       and concrete statuses; handle `kind` (`epic`/`feature`/both), status
       groups `open` (not `done`/`diss`) and `closed`, and `text` using
       SPL-4610's `personMatches` (`utils/person-picker.mjs:20`) with the
       parent pickers' exact row shape `{ id: e.key, label: `${e.key} ${e.title}` }`
       (`useIssuePicker.ts:94`, so queries spanning key and title such as
       `"SPL-17 Fix"` match identically to the parent pickers).
  2. Shared composable `wui:composables/useEpicPanelList.ts` (`useState`):
     holds sort (hydrated from `session.claims.issues_epics_sort`, saved via
     `auth.saveIssuesEpicsSort` + `session.setIssuesEpicsSort`), ephemeral
     filter state (tab-local, never persisted, never in URL), `filteredEpics`,
     `filterActive`, `clearFilters`, and `isManualUnfiltered` (seam for
     `T017g`). Imported ONLY by `IssueEpicsPanel.vue` and `pages/issues.vue` —
     NEVER by `ChannelSidebar.vue` or any layout.
  3. UI in `IssueEpicsPanel.vue`: toolbar under heading with sort select,
     direction toggle button (hidden/disabled for Manual), filter button with
     active dot and popover holding the `T017e` filter components + text + kind
     + Clear, and `"n of m epics"` status line when filtered. On phones
     (`<= 820 px`), two 44 px icon buttons (sort, filter) open bottom sheets.
     `pages/issues.vue:111-124` chip strip renders `filteredEpics` ("All"
     first); **chips do not drag** (`spec.md:492-494`: reordering stays in the
     panel only).
  4. Update `mockSummaries` (`utils/issues.mjs:311`) and `EpicSummary`
     (`mjs-shims.d.ts:1856`) with the 7 new fields in manual order.
  5. Add all new UI strings across all 19 locale files (`developer-guide.md`
     2.7), run `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`,
     fold references, re-run, commit the report under
     `csi-spl-wui/i18n/lang-review/<run>.json`, and include
     `Lang-review: gct <run id>` in the commit message.
- **Done and red controls (C2):**
  1. Sort unit test fails when closed rows are sorted among open rows (RED then
     GREEN);
  2. `bundle-size.mjs` on a mock generate reads `<= ci_initial_gzip_kb`
     (155.0 KB) and proves `useEpicPanelList` is absent from 200.html's initial
     chunks (throwaway-branch control: importing `useEpicPanelList` from
     `ChannelSidebar.vue` fails the check);
  3. Chrome mock e2e (`issues-epic-panel.test.mjs`) passes at both `1280x800`
     and `412x915` (sort modes, direction flip, persisted sort, every filter
     field, `"n of m"`, Clear, chip strip parity).
  `Docs: none (UI help follows in T017h; spec 039 FR-014.2/FR-014.3 already current)`.
- **Test column (R2):** `pnpm run typecheck`, `pnpm run test:unit` (including
  `epic-panel`, `issues`, `i18n-parity`, `i18n-untranslated`,
  `i18n-no-raw-text`, `cleancode`, `unused-exports`, `font-size`,
  `focus-tokens`), `bundle-size.mjs`, mock e2e `issues-epic-panel.test.mjs`,
  `issues.test.mjs`, `issues-mobile.test.mjs`, `issues-epic-edit.test.mjs`,
  `issues-ctxmenu.test.mjs`, plus `WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`;
  `wui-lang-review` pre-push part; `do_check_deploy_lag` on `dev` and `prd`.
- **Not touched:** `wui:components/ChannelSidebar.vue`,
  `wui:composables/useSidebarRailOnly.ts`, `wui:utils/tree-drag.ts`,
  `wui:composables/useIssueCtxMenu.ts`, `csi-spl-api/`, `csi-spl-rdb/`.

### 3.7 `T017g` - WUI epic reorder: drag, keyboard, row menu, 409 rollback

- **Kind:** `complex_coding`. **Vendor:** `claude` (never `mistral`). **R7:**
  `agy` (`claude` backup waiver ONLY while `agy` is out of quota, ruling
  `dc84300a`; never `mistral`). **Batch:** 5 (after `T017f` lands).
- **Files: ONLY** `wui:components/IssueEpicsPanel.vue`,
  `wui:composables/useEpicPanelList.ts`, `wui:composables/useIssueCtxMenu.ts`,
  `wui:composables/useIssueMenu.ts`, `wui:utils/spool-client.mjs`,
  `wui:utils/spool-client-lazy.mjs`, `wui:utils/issues.mjs` (mock
  `setPosition`), `wui:types/mjs-shims.d.ts`, all 19
  `csi-spl-wui/i18n/locales/*.json`, new
  `csi-spl-wui/i18n/lang-review/<run>.json`, new
  `csi-spl-wui/tests/unit/epic-reorder.test.mjs`, new
  `csi-spl-wui/tests/e2e/issues-epic-reorder.test.mjs`.
- **Work:**
  1. Add `setEpicPosition(ref, { before, after })` to `spool-client.mjs` /
     `spool-client-lazy.mjs` (`PUT /v1/issues/{ref}/position`) and implement
     the mock twin in `utils/issues.mjs` (enforcing open-only, neighbour
     adjacency -> 409 `stale_position`, priority adoption, 1024-gap rank, and
     returning `{ issue, epics }`).
  2. Replace `createLongPress` in `IssueEpicsPanel.vue` with `createTreeDrag`
     (`utils/tree-drag.ts:108-177`) using only `before` / `after` drop places
     (never `into`): mouse lifts after `TREE_DRAG_START_PX` (5 px) with a
     drop indicator line and `Esc` cancel; touch/pen hold opens the row menu
     first and moving after hold lifts the row (D8). Closed rows never drag,
     and drops below the last open row land as the last open row (D5). Leave
     the phone epic chip strip in `pages/issues.vue` untouched (chips do not
     drag, `spec.md:492-494`).
  3. Add keyboard reorder on focused open rows (`Alt+ArrowUp` /
     `Alt+ArrowDown`) with an `aria-live="polite"` announcement
     (`"<KEY> moved to place <i+1> of <N>"`).
  4. Add **Move up**, **Move down**, and **Move to top** to `menuItemsFor` in
     `useIssueCtxMenu.ts` for `tg.top` open epics (reusing `PointMenuItem`'s
     existing `disabled` + `hintKey`, N4), all calling the same `moveEpic` path.
  5. Enforce FR-014.4: when sort is not Manual OR any epic filter is active,
     rows show no drag affordance, pointer press does not lift, `Alt+Arrow` is
     ignored, and Move menu items are disabled with hint `"Switch to Manual
     order and clear the filter to reorder"`.
  6. Optimistic reorder: move row immediately in `issueEpics`; on refusal (e.g.
     409 `stale_position`), restore prior order, re-read `epics[]`, and show
     the hub reason inline under the panel heading.
  7. Add all new strings across all 19 locales, run
     `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`, commit the
     report under `csi-spl-wui/i18n/lang-review/<run>.json`, and include
     `Lang-review: gct <run id>` in the commit message.
- **Done and red controls (C2):**
  1. `tests/unit/epic-reorder.test.mjs` drives `createTreeDrag` with fake
     timers (mouse lift, touch/pen hold-then-move, `Esc` cancel), neighbour
     calculation, and optimistic rollback;
  2. Mock e2e (`issues-epic-reorder.test.mjs`) covers mouse drag, touch/pen
     hold-then-move, `Alt+Arrow`, row menu Move up/down/to top, `aria-live`
     text, 409 rollback, and reorder disabled under non-manual sort or filter:
     - Red control 1: leaving drag enabled under a non-manual sort fails the
       e2e test (RED then GREEN);
     - Red control 2: removing rollback on 409 fails the 409 e2e test (RED
       then GREEN);
  3. `bundle-size.mjs` <= 155.0 KB (`ci_initial_gzip_kb`).
  `Docs: none (UI help follows in T017h; spec 039 FR-014.1/FR-014.4 already current)`.
- **Test column (R2):** `pnpm run typecheck`, `pnpm run test:unit` (including
  `epic-reorder`, `epic-panel`, `tree-drag`, `issues`, `i18n-*`, `cleancode`,
  `unused-exports`, `font-size`, `focus-tokens`), `bundle-size.mjs`, mock e2e
  `issues-epic-reorder.test.mjs`, `issues-epic-panel.test.mjs`,
  `issues-ctxmenu.test.mjs`, `issues-epic-edit.test.mjs`, `issues.test.mjs`,
  `issues-mobile.test.mjs`, plus `WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`;
  `wui-lang-review`; `do_check_deploy_lag` on `dev` and `prd`.
- **Not touched:** `wui:components/ChannelSidebar.vue`,
  `wui:components/UiPointMenu.vue`, `wui:utils/tree-drag.ts`,
  `wui:pages/issues.vue`, `csi-spl-api/`, `csi-spl-rdb/`.

### 3.8 `T017h` - user help: `doc/help/issues.md` via qto doc + `sync-help.mjs`

- **Kind:** `specs_and_docs`. **Vendor:** `agy`, backup `claude` (never
  `mistral`: `sync-help.mjs` writes under `csi-spl-wui/`, developer guide 5.1).
  **R7:** cross-vendor (`claude` if `agy` authored; `agy`, or `claude` backup
  waiver ONLY while `agy` is out of quota, ruling `dc84300a`, if `claude`
  authored; never `mistral`). **Batch:** 6 (after `T017g` lands).
- **Files: ONLY** `doc:doc/help/issues.md` (via qto doc
  `9a453b0c-3925-45ac-9679-09fe841b4968` + `do_spl_doctree_export_md`) and
  `wui:public/help-md/issues.md` (ONLY via `sync-help.mjs`, N3).
- **Work:**
  1. Update the Epics description (`issues.md:76`) in qto doc
     `9a453b0c-3925-45ac-9679-09fe841b4968` to document: the manual order IS
     the epics' priority (dragging above another epic takes its priority), how
     to reorder (drag, hold-then-drag on touch, `Alt+ArrowUp`/`Down`, row menu
     Move up/down/to top — only in Manual order with no filter), how to sort
     (remembered per workspace), and how to filter (text, kind, status
     including Open/Closed, priority, assignee, label, deadline).
  2. Export via `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` and
     regenerate the WUI help copy via
     `cd csi-spl-wui && node src/node/help/sync-help.mjs`.
- **Done and red controls (C2):**
  1. `QTO_DRIFT_LIVE=1 ... do_check_qto_doc_drift` rc 0 (red control: a hand
     edit of `doc/help/issues.md` alone is caught by the live drift check);
  2. `cd csi-spl-wui && node src/node/help/sync-help.mjs --check` rc 0 (red
     control: leaving `wui:public/help-md/issues.md` stale exits 1).
- **Test column (R2):** `node csi-spl-wui/tests/unit/help-sync.test.mjs`,
  `QTO_DRIFT_LIVE=1` `do_check_qto_doc_drift`,
  `cd csi-spl-iac && ./run -a do_check_dist_hygiene`,
  `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`,
  `cd csi-spl-iac && ./run -a do_check_pre_push`, `do_check_deploy_lag` on
  `dev` and `prd`.
- **Not touched:** any Go, Bash, or TypeScript/Vue source file.

### 3.9 `T017i` - live proof `issues-epic-order-live.proof.mjs`

- **Kind:** `tests`. **Vendor:** `claude` (never `mistral`, developer guide
  5.1). **R7:** `agy` (`claude` backup waiver ONLY while `agy` is out of quota,
  ruling `dc84300a`; never `mistral`). **Batch:** 6 (after `T017c..T017g` are
  served on `dev` and `prd`).
- **Files: ONLY** new `csi-spl-wui/tests/e2e/issues-epic-order-live.proof.mjs`.
- **Work:**
  1. Mirror `issues-views-live.proof.mjs` (`BASE`, `API`, `EMAIL`, `PW_FILE`,
     `OUT`, `TENANT`, host/tenant safety check refusing writes unless session
     claim and page host match `TENANT`; never scripted sign-in on `prd t1`).
  2. Create temporary epics at distinct priorities, drag one across a priority
     boundary in the panel, assert the hub stores the adopted priority and
     rank, verify a second browser tab updates to the new order live without a
     reload, change the panel sort and reload to verify `issues_epics_sort`
     persists, test filtering and disabled drag while filtered, then delete
     every temporary epic and restore the test user's original sort preference.
  3. Run n=1 against `dev` (`TENANT=t1`) and `prd` (`TENANT=e2e` at
     `https://e2e.<domain>`) and record both outputs in the commit body.
- **Done and red control (C2):**
  - Red control: running step 1 against a hub before `T017c` is served (or a
    pre-`T017c` target without `/v1/issues/{ref}/position`) fails step 1 with
    404/405 (seen RED then GREEN on deployed `dev` + `prd`, both in commit
    body).
  - Zero leftover test epics on `dev` (`t1`) and `prd` (`e2e`) after cleanup.
  - `Docs: none (live proof script per spec 039 tasks.md T017i)`.
- **Test column (R2):** `issues-epic-order-live.proof.mjs` n=1 on `dev` (`t1`)
  and `prd` (`e2e`), `cd csi-spl-iac && ./run -a do_check_pre_push_lint`
  (ESLint/hygiene on `.mjs`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
- **Not touched:** `csi-spl-api/`, `csi-spl-rdb/`, `csi-spl-wui/src/`,
  `csi-spl-doc/doc/help/`.

## 4. Consensus

| seat | vendor | sha | verdict |
|---|---|---|---|
| `c-433` | `claude` (cross-vendor to `agy` planner `a-526`) | `742af3f59` (v0.1) | FAIL (`W1`-`W2`, `N1`-`N7`) |
| `c-433` | `claude` (cross-vendor to `agy` planner `a-526`) | v0.2 (pending) | pending |
| dispatch holder (`c-002`) | `claude` | pending | pending |

## 5. Versions

| version | what |
|---|---|
| v0.1 | initial build round plan on `136bcf31c` (`origin/master`): 9 rows (`T017a`-`T017i`) in 6 disjoint batches, vendor mix per kind table, cross-vendor R7 (never `mistral`), red controls, R2 test columns |
| v0.2 | folded `c-433` (`claude`) FAIL on v0.1 `742af3f59`: **W1** replaced manual DDL gate + owner poll with wf 20's automatic `DRY_RUN=0 do_spl_db_bootstrap` per env (`20_hub-build-deploy.yml:59,:172,:640-665`) and dropped the unnecessary owner poll (section 6 = None); **W2** fixed `dc84300a` citations to `refactor-round-98-plan.md:664-667` and `refactor-round-97-plan.md:473`; **N1** fixed `0181_issue_events.sql` to function `:65-110` / trigger `:112-113`; **N2** fixed `pages/issues.vue` `labels` ref `:1296` (assigned `:1421`) and `live.onIssue` `:1627`; **N3** fixed `TestOpenAPIRoutesFileForm` to `:326`; **N4** fixed `SetMembershipSettings` to Postgres `:85` / Memory `:125`; **N5** dropped unstated `sensitivity: 'base'` from `T017f` collator and marked `400 bad_json` / `400 bad_position` vs `409 stale_position` in `T017c`; **N6** matched `useIssuePicker.ts:94` row shape `{ id: e.key, label: `${e.key} ${e.title}` }` in `T017f`; **N7** added explicit "chips do not drag" (`spec.md:492-494`) to `T017f` and `T017g` |

## 6. Open points for the owner

None. Spec 039 FR-014 is already settled by owner answer **A** on form
`52f857ff` (`msg 934a8b8e`), and `.github/workflows/20_hub-build-deploy.yml`
applies `T017a`'s additive nullable-column migration automatically on `dev` and
`prd` before rolling the hub (`:59,:172,:649-665`), so no owner decision is
open.
