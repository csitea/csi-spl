# 143: Reporting section of the WUI, beside Monitoring

Status: **Decided / Phased for build v0.3.0** (Releases label cost in currency and tokens addendum, SPL-3893; owner answers and schema 0202-0204 folded; issue SPL-2324).  
Authority: this file for the architecture and technical requirements; [tasks.md](tasks.md) for the phased build tasks.  
Status vocabulary: [README.md](../README.md) §2.3. Docs only: this spec builds nothing ([README.md](../README.md) §2.4).  
Topic: `af25a1f3-7291-4675-855e-c67101680955` (HUM-10, prd t1, 2026-10-17; topic owner c-002; poll `1dd28b0e`, poll `4a6cdf4e`, poll `e804e13a`, token-burn topic `e8ae0aad` poll `2fa7180c`, poll form `e5dc787b` / `a8bfcdd0`; label cost addendum topic `7adb4163-3c65-4a49-a9bb-d17acbe2cf95` msg `58730eea`, SPL-3893).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, RLS)
- [005 WUI](../005-spool-wui/spec.md) (Nuxt 3 web interface, theme variables, layout)
- [065 release notes table](../065-release-notes-table/spec.md) (`release_notes`, lay/tech trailers, `/v1/release-notes`)
- [074 operator workspace](../074-operator-workspace/spec.md) (operator tenant, operatorActor, operatorAuth)
- [097 calendar full editing](../097-calendar-full-editing/spec.md)
- [098 tenant settings jsonb](../098-tenant-settings-jsonb/spec.md)
- [107 hours tracking](../107-hours-tracking/spec.md)
- [121 sales channel & usage ledger](../121-sales-channel/spec.md) (usage_events, model_prices, rdb `0171`)
- [123 cost tracking](../123-cost-tracking/spec.md) (`spl-cost-tokens-read.func.sh`, daily transcripts extraction)
- [135 work process](../135-work-process/spec.md) (issue workflow, restart card, lane integration rules)
- [140 token burn](../140-token-burn/spec.md) (real-time token burn telemetry, `fleet_token_burn_events`, `GET /v1/operator/fleet-tokens`)
- Monitoring section pattern: `csi-spl-wui/src/utils/monitoring-tabs.mjs`, `csi-spl-wui/src/pages/monitoring.vue`

`<BASE_DOMAIN>`, `<tenant>`, `<workspace_id>`, `<human_id>`, `<org>`, `<app>`, and `<env>` are placeholders. No estate value appears as a literal to copy. Per the repository naming rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, terraform resources, or API headers.

---

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic af25a1f3)

The owner established the requirements in prd workspace `t1`, topic `af25a1f3-7291-4675-855e-c67101680955`, verbatim (2026-10-17):

| msg / poll | text / decision |
|---|---|
| 06:36Z | "we need a new reporting section , which will be next to the monitoring section" |
| 06:36Z | "reporting as the name suggests will be more interactive UI on the information which is stored in the db of the spool hub" |
| 06:36Z | "it must have several tabs , but let's start with the simplest possible ONE .." |
| poll `1dd28b0e` | Selected: **TOK, ISS, MSG, LAN, REL** (token burn and cost per vendor/agent/day; issues opened/closed/waiting per area and lane; posts and answer times per workspace and topic; lanes spawned/landed/failed tries/takeovers; releases and deploys per day). *Calendar NOT picked.* |
| poll `4a6cdf4e` | **First tab to build = REL, releases and deploys per day** |
| 06:40Z | "and there should be a simple sql tab, which provides a small \"run sql , get result set\" functionality" |
| `581d5d66` | "nothing too fancey , just a simple functionality t o be able to run sql queries and get up to 2000 rows in a generic alternative colouring result set table" |
| poll `e804e13a` | Selected: **ADM: workspace admins, each limited to their own workspace's data** (msg `4a94d599`) |
| `2295cba5` | "admins may use it - but it will be read only" |
| `c814b707` | "because it is part of the reporting .." (read-only is an owner requirement, not an option) |

From the token-burn topic `e8ae0aad-b8fb-4d3c-8377-072eec9cd404` (same owner, 2026-10-17):
| msg / poll | text / decision |
|---|---|
| `1b2269f7` | "we need for example to start tracking the different type of activities , because not all tokens are equal" |
| `52fddc9d` | "This has to be expandable in the future - aka more grained categories to be able to define .." |
| poll `2fa7180c` | Selected: **ALL FOUR splits: KND kind of work + CLS class + ROL role + ISS issue** (msg `e3e9a456`): the activity category tree must hold all four dimensions. |

From the design poll on open questions (HUM-10, t1 topic `af25a1f3`, 2026-10-17 09:42–09:45Z; poll form msg `e5dc787b-4207-48c7-9433-2930e3acdb8d`, newest form answer msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, confirmed by c-002 in msg `07a2acb7-a00d-4bad-a9f2-10409dc7581d`):
| msg / poll | text / decision |
|---|---|
| poll `a8bfcdd0` Q1 + msg `9c32201b` | **Decided: C (CSV and JSON download) PLUS Copy to clipboard** (2026-10-17 09:42Z; verbatim owner msg `9c32201b`: *"SQL tab: export of the result? and add copy to clipboard button as well"*). Three export buttons: Copy (clipboard), Download .csv, Download .json. |
| poll `a8bfcdd0` Q2 | **Decided: A (5 domains with sub-categories)** (2026-10-17 09:42Z). 5 areas with sub-categories: coding, review, specs and docs, tests, dispatch (the canonical tree in §4.2.1). |
| poll `a8bfcdd0` Q3 | **Decided: C (Deploy step reports it, plus hub reconcile check)** (2026-10-17 09:42Z). The CI deploy step reports it, plus a hub periodic reconciliation check that catches any missed deploy. |
| poll `a8bfcdd0` Q4 | **Decided: A (Operator admins only)** (2026-10-17 09:42Z). Token burn stays for operator admins only; standard workspace admins never see the Tokens tab. |

What they bind:
- **B1 (Placement beside Monitoring)**: The Reporting section lives at `/reporting` as a primary navigation entry in the left rail, positioned immediately adjacent to Monitoring.
- **B2 (Tab structure & order)**: The tab bar follows the path-based tab model established in `monitoring-tabs.mjs`. Tabs are:
  1. **Releases** (`/reporting/releases`, v1, built first)
  2. **SQL** (`/reporting/sql`)
  3. **Tokens** (`/reporting/tokens`)
  4. **Issues** (`/reporting/issues`)
  5. **Posts** (`/reporting/posts`)
  6. **Lanes** (`/reporting/lanes`)
- **B3 (Releases Tab v1)**: Visualises the hub table `release_notes` (6,760 rows in prd from 2026-09-17 to date, columns `sha`, `version`, `committed_at`, `kind`, `area`, `subject`, `lay_*`, `tech_*`, `state`, `reverts`, `link`, `ingested_at`, `released_at`) grouped per day: daily counts per kind/area, interactive filterable commit list, and direct links to `/releases/<ref>`.
- **B4 (Deploy tracking gap & interim UX)**: Deploys per environment (`dev`/`prd`) are not stored in the database today. This spec defines the minimal schema and ingestion lane to record them (`estate_deploys`) via both CI deploy webhook steps and a periodic hub reconciliation check (§2.3.2). Until that lane lands, the UI displays "not recorded" for deployment dates and statuses without breaking the rest of the tab.
- **B5 (SQL Tab simplicity)**: Provides a simple "run sql, get result set" interface. Results are rendered in a plain table with alternating row colours (zebra striping). Three export buttons: Copy (clipboard), Download .csv, and Download .json. No query builders, visual schema designers, or graph visualisers.
- **B6 (SQL Tab hard row cap)**: Queries are capped at exactly **2,000 rows** (owner requirement, msg `581d5d66`). Results exceeding 2,000 rows are truncated at 2,000 with a visible truncation badge.
- **B7 (SQL Tab read-only by construction)**: Queries execute strictly in a `READ ONLY` transaction on PostgreSQL. Any write (INSERT, UPDATE, DELETE, TRUNCATE) or DDL (CREATE, ALTER, DROP) is rejected by the database engine.
- **B8 (SQL Tab security & statement isolation)**:
  - Statement timeout: hard limit of **10 seconds** (`statement_timeout = '10s'`).
  - Single statement only: multi-statement payloads separated by semicolons are refused before execution.
  - Session and privilege manipulation (SET, RESET, SET ROLE, SET SESSION AUTHORIZATION, manipulating RLS settings) are strictly barred.
- **B9 (SQL Tab workspace scoping & RLS)**: Access is granted to workspace admins only (`admin` role in `tenant_members`). Execution runs under the caller's workspace RLS scope (`app.tenant_id = <workspace_id>`). It NEVER executes under operator scope (`app.rls_scope = 'operator'`). Workspace A admin querying `SELECT * FROM messages WHERE tenant_id = 'workspace-b'` receives exactly 0 rows. (In contrast, the Tokens tab is restricted to operator admins only; standard workspace admins never see it.)
- **B10 (SQL Tab full audit logging)**: Every query attempt is logged to an audit table (`sql_query_audit`): human ID, workspace ID, timestamp, full query text, execution duration (ms), returned row count, truncation status, and error message (if failed).
- **B11 (Activity categories data-defined tree)**: Activity categories are stored as a hierarchical tree in the hub database (`activity_categories`), editable and expandable via API without requiring any code changes or redeployments. Parents automatically aggregate/sum children.
- **B12 (Four-dimensional category alignment & placement)**: Holds all four owner splits: Kind (`knd`), Class (`cls`), Role (`rol`), and Issue (`iss`). Each lane receives its category path at placement time, recorded in `fleet_asks`. Token minutes join to categories via agent ID and time window. Historical rows with no category are labeled `'uncategorised'` (never guessed or fabricated).

---

## 1. Section navigation & shell architecture

### 1.1 Left rail integration

The Reporting section sits as a top-level rail item beside Monitoring:
- **Rail ID**: `'reporting'`
- **Target URL**: `/reporting` (redirects to `/reporting/releases`)
- **Icon**: `chart-column` (or `file-text` / `bar-chart` from `uiIcons.ts`)
- **Label Key**: `sidebar.reporting`
- **Rail order**: Inserted into `RAIL_TABS` (`csi-spl-wui/src/utils/rail-order.mjs`) immediately following or beside `monitoring`.

```typescript
// csi-spl-wui/src/utils/rail-order.mjs
Object.freeze({ id: 'reporting', icon: 'chart-column', labelKey: 'sidebar.reporting' })
```

### 1.2 Path-based tabs: `csi-spl-wui/src/utils/reporting-tabs.mjs`

Following the proven architecture of `monitoring-tabs.mjs`, each tab is its own independent sub-path (`/reporting/<tab_id>`), loaded on demand as a distinct chunk. Browser back and forward navigation history steps through visited tabs naturally.

```javascript
// csi-spl-wui/src/utils/reporting-tabs.mjs

import { productPath } from './signed-out-redirect.mjs'

export const REPORTING_TABS = Object.freeze([
  // Releases tab (v1: built first, visible to all signed-in workspace members)
  Object.freeze({ id: 'releases', path: '/reporting/releases', labelKey: 'reporting.tab.releases', adminOnly: false, ready: true }),
  // SQL tab (built second, visible to workspace admins only)
  Object.freeze({ id: 'sql', path: '/reporting/sql', labelKey: 'reporting.tab.sql', adminOnly: true, ready: true, perm: 'reporting.sql.run' }),
  // Future tabs reserved (ready: false hides them from the tab bar until implemented)
  Object.freeze({ id: 'tokens', path: '/reporting/tokens', labelKey: 'reporting.tab.tokens', operatorsOnly: true, ready: false }),
  Object.freeze({ id: 'issues', path: '/reporting/issues', labelKey: 'reporting.tab.issues', adminOnly: false, ready: false }),
  Object.freeze({ id: 'posts', path: '/reporting/posts', labelKey: 'reporting.tab.posts', adminOnly: false, ready: false }),
  Object.freeze({ id: 'lanes', path: '/reporting/lanes', labelKey: 'reporting.tab.lanes', adminOnly: true, ready: false }),
])

export const REPORTING_DEFAULT_PATH = REPORTING_TABS[0].path // /reporting/releases

export function visibleReportingTabs(who = {}) {
  return REPORTING_TABS.filter((tab) => {
    if (!tab.ready) return false
    if (tab.operatorsOnly && who.operator !== true) return false
    if (tab.adminOnly && who.admin !== true) return false
    if (tab.perm && (typeof who.can !== 'function' || who.can(tab.perm) !== true)) return false
    return true
  })
}

export function reportingTabFor(path) {
  const p = productPath(path)
  for (const tab of REPORTING_TABS) {
    if (p === tab.path || p.startsWith(tab.path + '/')) return tab.id
  }
  return null
}
```

### 1.3 Section page wrapper: `pages/reporting.vue`

`pages/reporting.vue` provides the standard feed layout, top bar with title and close affordances, tab navigation bar, and child route outlet (`<NuxtPage />`):

```vue
<!-- csi-spl-wui/src/pages/reporting.vue -->
<template>
  <div class="feed-col reporting-page" data-test="reporting-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="reporting-heading">{{ t('reporting.title') }}</h2>
      <SectionClose side="end" />
    </header>
    <nav class="reporting-tabs" :aria-label="t('reporting.tabs_label')" data-test="reporting-tabs">
      <NuxtLink
        v-for="tab in tabs"
        :key="tab.id"
        :to="localePath(tab.path)"
        class="reporting-tab"
        :class="{ 'reporting-tab--active': active === tab.id }"
        :aria-current="active === tab.id ? 'page' : undefined"
        :data-test="'reporting-tab-' + tab.id"
      >{{ t(tab.labelKey) }}</NuxtLink>
    </nav>
    <div class="feed-body reporting-body">
      <NuxtPage />
    </div>
  </div>
</template>
```

When a user visits `/reporting`, the page replaces the route immediately to `/reporting/releases`.

---

## 2. Tab 1: Releases & Deploys (v1, built first)

### 2.1 Overview & data sources

The Releases tab delivers an interactive timeline and analytical view of development and delivery velocity across the estate.

It combines two data sources:
1. **Commit Release Notes (`release_notes`)**: The established hub table holding commit metadata, Lay/Tech trailers, semantic kind, area, and release tags (`v<X.Y.Z>`). Contains 6,760+ rows from 2026-09-17 onwards.
2. **Estate Deploys (`estate_deploys`)**: A new minimal table tracking environment deployment events (`dev` and `prd`).

### 2.2 Interactive user interface: `pages/reporting/releases.vue`

The Releases tab features three integrated UI sections:
1. **Top KPI Strip**:
   - Total releases minted (`v<X.Y.Z>` count).
   - Total commits landed within the selected period.
   - Commits per day average.
   - Deploys count (`dev` vs `prd`).
2. **Filter & Time Range Control Bar**:
   - **Time Range Selector**: `Today`, `Last 7 Days` (default), `Last 30 Days`, `Last 90 Days`, `Custom Range`.
   - **Kind Selector**: Multi-select pills (`feat`, `fix`, `docs`, `chore`, `perf`, `refactor`, `ci`, `test`).
   - **Area Selector**: Multi-select pills (`orc`, `api`, `wui`, `iac`, `cnf`, `doc`, `rdb`).
   - **Search Input**: Live filter across commit subject, SHA, version tag, and Lay/Tech summaries.
3. **Daily Breakdown & Commit List**:
   - Days rendered newest first.
   - Each day header displays: UTC Date, total commits, pill breakdown by kind (`feat: 3`, `fix: 2`, `docs: 5`), deploy badges (e.g. `[dev: v1.7.0 14:22 UTC]`, `[prd: v1.7.0 14:35 UTC]`). If deploy data is absent, a neutral `[Deploys: not recorded]` badge is shown.
   - Under each day: an interactive list of commit rows. Each row displays:
     - 7-character short SHA linking to `/releases/<sha>`.
     - Version badge (e.g. `v1.7.0`) linking to `/releases/<version>`.
     - Area chip and Kind chip.
     - Subject line.
     - Expandable toggle showing Lay What/How/Why and Tech What/How/Why trailers.

#### 2.2.1 The kind and area pills as a label cloud (SPL-3796)

Owner HUM-10, t1 topic 58c4aa4b, msgs 27cb5bc0 and d7fdbbcd: the labels
"should be scattered" like a label cloud, "their sizes shoud reflect the
amount of the label type used in the commits .. and the biggest one should be
in the center", and a click on a label "will show the commits of that lable
only".

- **Counts**: per label, the commits of the range and search that carry it,
  summed over the `kinds` / `areas` maps of `GET /v1/reporting/releases/daily`
  (`labelCounts`). No new endpoint. With no kind or area picked the page's
  own daily read gives them; while one is picked the page reads the daily
  answer once more without the picks, only when the range or the search
  changed, so the cloud keeps its sizes and places while labels are toggled.
- **Layout** (`labelCloud` in `csi-spl-wui/src/utils/reporting-releases.ts`):
  the most used label in the centre of its row, the next ones placed right,
  left, right ... of it; ties keep the pill order. Rows are centred and wrap
  at 390 px; two pills of every three drift a few pixels up or down.
- **Size**: six class steps, `rf-step-0` (no commit carries it: smallest,
  muted, dashed) to `rf-step-5` (the most used); a step grows with the square
  root of the label's share of the top one. Classes only, never `:style`
  (CSP). The count is shown in the pill, so a screen reader hears it too.
- **Unchanged**: each pill is a `<button>` with `aria-pressed`, the
  `releases-kind-<k>` / `releases-area-<a>` hooks, and a click toggles the
  label in or out of the filter (one label on = that label's commits only).
  No new UI text.
- **Tests**: `csi-spl-wui/tests/unit/reporting-releases.test.mjs` (the
  helpers, the centre pill, the steps) and `tests/e2e/reporting.test.mjs`
  (1440 and 390 px: the most used kind is the centre and largest pill, a
  click shows its commits only, the cloud keeps its places).
- **Cost in currency and tokens (Addendum v0.3.0, SPL-3893)**:
  Each label pill in the cloud carries its total cost in tokens and currency
  (EUR/USD per active currency), summed across all commits carrying that label
  within the active time range. Full specification of commit token attribution,
  multi-commit/multi-label splitting, daily estate rate pricing, and untracked
  commit handling is in [§8. Releases label cost in currency and tokens](#8-releases-label-cost-in-currency-and-tokens-addendum-v030-spl-3893).

### 2.3 Deploy recording lane (`estate_deploys`)

#### 2.3.1 Database schema migration: `0202_estate_deploys.sql`

Column `source` (`ci` vs `reconcile`) records whether the row was written by the CI deploy workflow or the hub's periodic reconcile check per owner poll 3 (`0202_estate_deploys.sql`).

```sql
-- 0202_estate_deploys.sql - deploy events per environment (spec 143 B4)
-- Records hub and WUI deployments to dev and prd. Forward-only.

CREATE TABLE estate_deploys (
    deploy_id       text        PRIMARY KEY CHECK (deploy_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    env             text        NOT NULL CHECK (env IN ('dev', 'prd')),
    component       text        NOT NULL CHECK (component IN ('hub', 'wui', 'inf')),
    version         text        NOT NULL CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$'),
    commit_sha      text        NOT NULL CHECK (commit_sha ~ '^[0-9a-f]{40}$'),
    deployed_at     timestamptz NOT NULL DEFAULT now(),
    status          text        NOT NULL CHECK (status IN ('success', 'failed')),
    source          text        NOT NULL DEFAULT 'ci' CHECK (source IN ('ci', 'reconcile')),
    workflow_run_id text        NOT NULL DEFAULT '' CHECK (length(workflow_run_id) <= 64),
    deployed_by     text        NOT NULL DEFAULT '' CHECK (length(deployed_by) <= 128)
);

CREATE INDEX estate_deploys_env_day ON estate_deploys (env, ((deployed_at AT TIME ZONE 'UTC')::date), deployed_at DESC);
CREATE INDEX estate_deploys_env_component ON estate_deploys (env, component, deployed_at DESC);
CREATE INDEX estate_deploys_sha ON estate_deploys (commit_sha);

-- Estate-wide table, like release_notes: no tenant_id, read by all authenticated members
ALTER TABLE estate_deploys ENABLE ROW LEVEL SECURITY;
ALTER TABLE estate_deploys FORCE ROW LEVEL SECURITY;

CREATE POLICY estate_deploys_read ON estate_deploys
    FOR SELECT TO PUBLIC USING (true);

CREATE POLICY operator_scope ON estate_deploys
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

#### 2.3.2 Ingestion mechanism

Deploy recording uses a two-tier ingestion model (Owner decision Poll 3 Choice C, HUM-10 msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17): the CI deploy workflow step reports the deploy immediately as the primary source, and a scheduled hub reconciliation worker periodically checks live served endpoints to catch any missed deploys.

##### 1. Primary: CI deploy recording webhook step
A webhook/curl step is added to `.github/workflows/20_hub-build-deploy.yml` and `30_wui-build-deploy.yml`:
- **Trigger**: Immediately following successful Cloud Run (`hub`) or Firebase Hosting (`wui`) deployment.
- **Authentication**: Cloud Run deployment Service Account Google ID token (`Authorization: Bearer <id_token>`).
- **Endpoint**: `POST /v1/operator/deploys`

**Both envs on every hub (SPL-2848).** Each hub keeps the estate's deploys,
dev and prd, so one Reporting page counts both (the 2.4.1 payload). The step
reports each deploy twice: to its own env's hub, and to the other env's hub
as THAT env's project SA (step "Record the deploy on the other env's hub",
the key `GCP_KEY_CSI_SPL_<OTHER>` into a credentials file only), because each
hub's operator allow-list holds only its own env's SA. The row's `env` is the
deployed env (`do_spl_deploy_record` `DEPLOY_ENV`), the hub called is `ENV`.
Before this, a hub refused another env's row (400 `wrong_env`) and the prd
page read "Deploys 0 on dev" while dev deployed. No IAM or cnf change; rows
from before it are not copied across.

Request payload:
```json
{
  "env": "prd",
  "component": "hub",
  "version": "v1.7.1-c3",
  "commit_sha": "590297d4fa16b0b2e3c0429f40078b668d2a6a12",
  "status": "success",
  "workflow_run_id": "185623910"
}
```

##### 2. Fallback: Hub periodic deploy reconciliation check
A background ticker inside the hub periodically probes served environments to reconcile any missed deployment events (e.g. CI webhook timeout, network interruption, or manual rollouts):
- **How often**: Runs on a background ticker every **2 minutes**.
- **What it compares**: For each environment (`dev`, `prd`) and component (`hub`, `wui`), queries the live served endpoints:
  - Hub: `GET /version` on Cloud Run, returning `{ "version": "v1.7.1-c3", "sha": "590297d..." }`.
  - WUI: `GET /build.json` on Firebase Hosting, returning `{ "version": "v1.7.1-c3", "commit_sha": "590297d..." }`.
  The worker compares the returned live `version` and `commit_sha` against the most recent row in `estate_deploys` for that `(env, component)`. It reads and fills only its own hub's env; the other env's rows come from the CI step alone.
- **How it marks a deploy it filled in**: When a mismatch is detected (the served version/sha is newer or differs from the latest recorded deploy), the reconciler inserts a new record into `estate_deploys` with:
  - `deployed_by = 'hub-reconcile'` (clearly marking the record as filled in by the reconciler rather than the CI webhook).
  - `workflow_run_id = 'reconcile'`.
  - `deployed_at = now()`.
  - `status = 'success'`.

### 2.4 Hub API endpoints

#### 2.4.1 Daily aggregation: `GET /v1/reporting/releases/daily`
- **Access**: Any signed-in workspace member (`humanTenant` auth).
- **Query parameters**:
  - `from`: RFC3339 date/time (default: 30 days ago).
  - `to`: RFC3339 date/time (default: now).
  - `kind`: Comma-separated kinds filter.
  - `area`: Comma-separated areas filter.

Response payload:
```json
{
  "days": [
    {
      "date": "2026-10-17",
      "commits_count": 42,
      "kinds": { "feat": 12, "fix": 18, "docs": 8, "refactor": 4 },
      "areas": { "orc": 15, "api": 14, "wui": 10, "doc": 3 },
      "deploys": [
        { "env": "dev", "component": "hub", "version": "v1.7.2-c3", "deployed_at": "2026-10-17T08:15:00Z", "status": "success" },
        { "env": "prd", "component": "hub", "version": "v1.7.1-c3", "deployed_at": "2026-10-17T07:30:00Z", "status": "success" }
      ]
    }
  ],
  "total_commits": 42,
  "total_versions": 2
}
```

#### 2.4.2 Paginated commits list: `GET /v1/reporting/releases/commits`
- **Access**: Any signed-in workspace member.
- **Query parameters**:
  - `from`, `to`, `kind`, `area`, `search`: String filters.
  - `limit`: Integer (1..200, default: 50).
  - `offset`: Integer (default: 0).

Response payload:
```json
{
  "total": 6760,
  "limit": 50,
  "offset": 0,
  "notes": [
    {
      "sha": "590297d4fa16b0b2e3c0429f40078b668d2a6a12",
      "version": "v1.7.1-c3",
      "committed_at": "2026-10-17T06:55:00Z",
      "kind": "fix",
      "area": "api",
      "subject": "fix(api, SPL-2318): doctree edit --field attrs.src/lang works on an item that already holds a src",
      "lay_what": "Fixes document tree attribute replacement",
      "lay_how": "Preserves existing src field when modifying lang",
      "lay_why": "Prevent document link corruption during language changes",
      "tech_what": "Update SQL jsonb_set expression in doc tree updater",
      "tech_how": "Apply conditional coalesce on jsonb attribute paths",
      "tech_why": "Idempotent update handling in store/doc_tree.go",
      "state": "ok",
      "reverts": null,
      "link": "https://github.com/csitea/csi-spl/commit/590297d4fa16b0b2e3c0429f40078b668d2a6a12"
    }
  ]
}
```

---

## 3. Tab 2: SQL Tab (Read-Only Query Engine)

### 3.1 Architecture & Security by Construction

The SQL tab is designed to satisfy the owner's exact mandate:
> "nothing too fancey , just a simple functionality t o be able to run sql queries and get up to 2000 rows in a generic alternative colouring result set table" (msg 581d5d66)  
> "admins may use it - but it will be read only" (msgs 4a94d599, 2295cba5)

To guarantee that queries cannot compromise data integrity or bypass tenant isolation, security is enforced across five discrete layers:

```
[ WUI Admin Browser ]
         │ (POST /v1/reporting/sql with query string)
         ▼
[ Layer 1: Hub RBAC & Token Auth ]
         │ Rejects non-admin users with HTTP 403
         ▼
[ Layer 2: SQL Lexical & AST Static Guard ]
         │ Rejects multi-statements (;), comments hiding commands,
         │ and forbidden keywords (INSERT, UPDATE, DELETE, DROP, SET, etc.)
         ▼
[ Layer 3: Transaction Read-Only & Budget Envelope ]
         │ BEGIN TRANSACTION READ ONLY;
         │ SET LOCAL statement_timeout = '10s';
         │ SET LOCAL default_transaction_read_only = on;
         ▼
[ Layer 4: Strict PostgreSQL Row-Level Security (RLS) ]
         │ SELECT set_config('app.tenant_id', '<authenticated_workspace>', true);
         │ (NEVER sets app.rls_scope = 'operator')
         ▼
[ Layer 5: Hard Row Cap & Streaming Interceptor ]
         │ Streams max 2,001 rows:
         │ If row count == 2,001: discard 2,001st row, set truncated = true
         ▼
[ Result Set & Audit Row Committed ]
```

### 3.2 Refusal rules (What must be rejected)

The query engine rejects queries violating any of the following constraints:
1. **Mutation statements**: Any statement starting with or containing `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `MERGE`.
2. **Data Definition (DDL)**: Any statement with `CREATE`, `ALTER`, `DROP`, `RENAME`, `COMMENT`.
3. **Session & Security manipulation**: Any command with `SET`, `RESET`, `SET ROLE`, `SET SESSION AUTHORIZATION`, `SET TRANSACTION`, `LISTEN`, `NOTIFY`.
4. **Procedural & Code execution**: `CALL`, `DO`, `PREPARE`, `EXECUTE`, `DEALLOCATE`.
5. **Data import/export**: `COPY`, `\copy`.
6. **Multi-statement queries**: Any payload containing a semicolon `;` followed by non-whitespace characters.
7. **Timeout**: Any query taking longer than **10 seconds** is terminated by PostgreSQL with error code `57014` (`query_canceled`).

### 3.3 Strict workspace RLS scoping

The SQL tab is accessible exclusively to workspace admins. The query executes inside the transaction under that workspace's RLS scope:
```sql
SELECT set_config('app.tenant_id', $1, true);
```
Crucially, `app.rls_scope = 'operator'` is **NEVER** set for queries executed through the SQL tab.
- All PostgreSQL policies enforcing `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')` apply automatically.
- A query such as `SELECT * FROM messages WHERE tenant_id = 'other-workspace'` returns zero rows.
- System catalogue tables and unshared metadata are protected by database role privileges.

### 3.4 Row cap & truncation

The engine caps results at **2,000 rows**.
Implementation in Go pgx handler:
```go
const SQLQueryRowCap = 2000

// Fetch up to SQLQueryRowCap + 1 rows
for rows.Next() {
    if count == SQLQueryRowCap {
        truncated = true
        break
    }
    // process row
    count++
}
```
If 2,000 rows are reached and additional rows exist, `truncated` is marked `true`, and the result set returns exactly 2,000 rows.

### 3.5 Query audit logging: `sql_query_audit`

Every execution attempt (successful or rejected) is audited to a durable table. Policy `tenant_scope` is `FOR ALL` with the 0174 append-only trigger so workspaces can insert their own audit rows while satisfying `TestRLSPoliciesFailClosed` (`0203_sql_query_audit.sql`).

```sql
-- 0203_sql_query_audit.sql - audit log for reporting SQL queries (spec 143 B10)
CREATE TABLE sql_query_audit (
    audit_id      text        PRIMARY KEY CHECK (audit_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id      text        NOT NULL CHECK (length(human_id) BETWEEN 1 AND 200),
    query_text    text        NOT NULL CHECK (length(query_text) <= 100000),
    executed_at   timestamptz NOT NULL DEFAULT now(),
    duration_ms   integer     NOT NULL CHECK (duration_ms >= 0),
    row_count     integer     NOT NULL DEFAULT 0 CHECK (row_count >= 0),
    truncated     boolean     NOT NULL DEFAULT false,
    error_message text        NOT NULL DEFAULT '' CHECK (length(error_message) <= 2000),
    client_ip     text        NOT NULL DEFAULT '' CHECK (length(client_ip) <= 64)
);

CREATE INDEX sql_query_audit_tenant_time ON sql_query_audit (tenant_id, executed_at DESC);

ALTER TABLE sql_query_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE sql_query_audit FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON sql_query_audit
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

CREATE POLICY operator_scope ON sql_query_audit
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Append-only audit: no UPDATE ever; a DELETE only as a tenant delete's cascade.
CREATE FUNCTION sql_query_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'sql_query_audit is append-only: % refused (only a tenant delete removes rows)', TG_OP;
END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON sql_query_audit
    FOR EACH ROW EXECUTE FUNCTION sql_query_audit_append_only();
```

### 3.6 User interface: `pages/reporting/sql.vue`

The UI consists of:
1. **SQL Editor Pane**:
   - Monospaced `<textarea>` (or lightweight syntax editor).
   - "Run Query" button with keyboard shortcut (`Ctrl+Enter` / `Cmd+Enter`).
   - "Clear" button.
   - Status indicators: execution spinner, execution time (e.g. `14 ms`), row count (`42 rows`), truncation warning badge (`Capped at 2,000 rows`).
2. **Results Table**:
   - Generic table rendering dynamic column headers returned by PostgreSQL.
   - Alternating row background colours (`.row--even` / `.row--odd` striped styling) for legibility.
   - Sticky header row on vertical scroll.
   - Horizontally scrollable container with fixed column alignment.
   - Null values formatted distinctly (`NULL` in subdued italic).
   - **Export affordances (three buttons)**: Dedicated export toolbar immediately above the results table (Owner decision Poll 1 Choice C plus msg `9c32201b-c261-4c9f-888d-e7c636d1c893`, 2026-10-17):
     1. **Copy** (Copy to clipboard): Copies the in-memory result set to the system clipboard formatted as tab-delimited text (TSV) with column headers. Allows immediate pasting into spreadsheets (Excel, Google Sheets). Shows a brief toast confirmation upon copy.
     2. **Download .csv**: Triggers a client-side browser blob download of `<timestamp>-query-result.csv` containing the result set formatted as standard RFC 4180 CSV with header row and escaped quotes/commas.
     3. **Download .json**: Triggers a client-side browser blob download of `<timestamp>-query-result.json` containing the result set formatted as a pretty-printed JSON array of objects (`[{"col1": "val1", ...}, ...]`).
   - **Treatment of truncated 2,000-row results**: When a query hits the 2,000-row engine limit (`truncated = true`), all three export affordances operate strictly on the 2,000 returned rows already held in client memory. They never issue a secondary un-capped query to the backend. The UI displays an amber truncation badge (`Capped at 2,000 rows`) beside the row counter, and all three export functions preserve this limit, exporting exactly the 2,000 rows returned.

### 3.7 Hub API route: `POST /v1/reporting/sql`

Request:
```json
{
  "query": "SELECT channel_id, name, created_at FROM channels ORDER BY created_at DESC"
}
```

Response (HTTP 200 OK):
```json
{
  "columns": [
    { "name": "channel_id", "type": "text" },
    { "name": "name", "type": "text" },
    { "name": "created_at", "type": "timestamptz" }
  ],
  "rows": [
    ["c-8f921a", "general", "2026-09-18T10:00:00Z"],
    ["c-1a02be", "announcements", "2026-09-18T10:05:00Z"]
  ],
  "row_count": 2,
  "truncated": false,
  "duration_ms": 12
}
```

Error responses:
- `HTTP 400 Bad Request` (`code: "read_only_violation"`): Query contains forbidden write or DDL statement.
- `HTTP 400 Bad Request` (`code: "single_statement_only"`): Multiple statements separated by semicolon detected.
- `HTTP 400 Bad Request` (`code: "syntax_error"`): PostgreSQL query syntax error.
- `HTTP 403 Forbidden` (`code: "admin_required"`): Caller is not a workspace admin.
- `HTTP 408 Request Timeout` (`code: "query_timeout"`): Query exceeded 10-second statement budget.

---

## 4. Section 4b: Activity categories (Hierarchical category tree)

### 4.1 Business context & owner mandate

From the token burn topic `e8ae0aad` (HUM-10):
- "we need for example to start tracking the different type of activities , because not all tokens are equal" (msg `1b2269f7`)
- "This has to be expandable in the future - aka more grained categories to be able to define .." (msg `52fddc9d`)
- Poll `2fa7180c` answer: **ALL FOUR splits: KND kind of work + CLS class + ROL role + ISS issue** (msg `e3e9a456`).

Today, fleet tasks and token consumption suffer from an activity attribution gap:
- `fleet_asks.class` is stored on only 399 asks (`ci`, `refactor`, `bug`, `feature`), with 895 older rows blank.
- `fleet_asks.kind` records only `'task'` or `'blocker'`. The true kind of work (`specs_and_docs`, `tests`, `simple_coding`, `complex_coding`, `i18n`, `secret`, `review`, `dispatch`) is not stored in the database.
- Role is derived ad-hoc from agent ID prefixes.
- `issue_key` exists on `fleet_asks` (SPL-1817 / rdb 0183), but fill rate is unstandardised.
- Consequently, tokens consumed in `fleet_token_burn_events` cannot be analysed by activity type.

### 4.2 Data-defined hierarchical tree architecture

To guarantee future extensibility without code deployments, activity categories are defined as **database rows** in a hierarchical tree:
- New categories or finer child categories are created simply by inserting a row.
- Categories use path notation (`parent/child/grandchild`), with forward slashes delimiting hierarchy depth.
- Parent nodes automatically roll up and sum the token consumption and activity metrics of all child nodes.
- A query grouping by depth level 1 aggregates across broad activity domains (e.g. `coding`, `review`, `specs_and_docs`), while level 2 or 3 provides fine-grained drill-down.

#### 4.2.1 Canonical tree structure (Initial seed)

The initial seed tree below is the decided canonical tree structure (Owner decision Poll 2 Choice A, HUM-10 msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17: 5 areas with sub-categories: `coding`, `review`, `specs_and_docs`, `tests`, `dispatch`). Migration `0204_activity_categories.sql` seeds exactly these 5 top-level domains and their initial child categories.

```
activity_categories
├── coding
│   ├── coding/simple         (small bug fixes, routine edits, minor tweaks)
│   ├── coding/hard           (complex features, algorithmic work, large refactors)
│   └── coding/i18n           (translations, locale sync, untranslated gates)
├── review
│   ├── review/r7             (R7 peer review rounds)
│   └── review/gate           (pre-push verification, CI gate triage)
├── specs_and_docs
│   ├── specs_and_docs/spec   (system architecture specs, spec-kit plans)
│   └── specs_and_docs/doc    (developer guide, user manuals, release documentation)
├── tests
│   ├── tests/unit            (Go, JS/TS unit tests)
│   └── tests/e2e             (Playwright e2e, integration verification)
└── dispatch
    ├── dispatch/triage       (topic triage, issue filing, owner clarification)
    └── dispatch/placement    (lane placement, queue scheduling)
```

### 4.3 Database schema migration: `0204_activity_categories.sql`

`fleet_asks.category_path` is `NULL` (meaning uncategorised) instead of `NOT NULL DEFAULT ''` because `''` is not a category node and would violate the foreign key on existing asks (`0204_activity_categories.sql`).

```sql
-- 0204_activity_categories.sql - hierarchical activity categories (spec 143 Section 4b)
-- Data-defined, expandable tree of activities holding four dimensions. Forward-only.

CREATE TABLE activity_categories (
    category_path text        PRIMARY KEY CHECK (category_path ~ '^[a-z0-9_]+(/[a-z0-9_]+)*$'),
    parent_path   text        NULL REFERENCES activity_categories (category_path) ON DELETE CASCADE,
    title         text        NOT NULL CHECK (length(title) BETWEEN 1 AND 100),
    description   text        NOT NULL DEFAULT '' CHECK (length(description) <= 500),
    dimensions    jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(dimensions) = 'object'),
    is_active     boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT activity_categories_parent_check CHECK (
        parent_path IS NOT DISTINCT FROM NULLIF(regexp_replace(category_path, '/[^/]+$', ''), category_path))
);

CREATE INDEX activity_categories_parent ON activity_categories (parent_path);

-- Estate-wide lookup table: read by all, mutated by operator admin
ALTER TABLE activity_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_categories FORCE ROW LEVEL SECURITY;

CREATE POLICY activity_categories_read ON activity_categories
    FOR SELECT TO PUBLIC USING (true);

CREATE POLICY operator_scope ON activity_categories
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Extend fleet_asks to store work kind and assigned category path
ALTER TABLE fleet_asks ADD COLUMN work_kind text NOT NULL DEFAULT ''
    CHECK (work_kind IN ('', 'specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret', 'review', 'dispatch'));

ALTER TABLE fleet_asks ADD COLUMN category_path text NULL
    REFERENCES activity_categories (category_path);

CREATE INDEX fleet_asks_category ON fleet_asks (category_path) WHERE category_path IS NOT NULL;
```

### 4.4 Lane placement & category assignment

1. **Ask Enqueueing**: When an orchestrator or dispatcher creates a spawn request in `fleet_asks` (`do_spl_spawn_place` or `spawn-window.sh`), it supplies the `category_path` and `work_kind` matching the brief.
2. **Placement Injection**: The claimed `category_path` is recorded into the lane's metadata directory (`/var/spool-hub/<agent_id>/lifetime/category.json` and `lifetime/brief.md`).
3. **Token Minute Join Logic**:
   - `fleet_token_burn_events` records consumption per `(box_tag, agent_id, minute_bucket)`.
   - The reporting engine joins `fleet_token_burn_events` with `fleet_asks` on:
     ```sql
     fleet_token_burn_events e
     LEFT JOIN fleet_asks a ON a.from_agent = e.agent_id
       AND e.minute_bucket >= a.created_at
       AND (a.updated_at IS NULL OR e.minute_bucket <= a.updated_at + interval '10 minutes')
     ```
   - **Handling of Uncategorised Rows**: Any token minute that does not match an active placed ask with a category is reported as `'uncategorised'` (display label "Uncategorised"). Old rows are NEVER backfilled with guessed categories.
4. **Hierarchical Rollup Query**:
   Parents automatically aggregate their descendants using prefix matching:
   ```sql
   SELECT
     c.category_path,
     c.title,
     sum(e.tokens_in + e.tokens_out) AS total_tokens,
     sum(e.cost_micros) / 1000000.0 AS total_cost_eur
   FROM activity_categories c
   JOIN fleet_asks a ON a.category_path = c.category_path OR a.category_path LIKE c.category_path || '/%'
   JOIN fleet_token_burn_events e ON a.from_agent = e.agent_id
   WHERE e.minute_bucket >= $1 AND e.minute_bucket < $2
   GROUP BY c.category_path, c.title
   ORDER BY total_cost_eur DESC;
   ```

### 4.5 Hub API routes for categories

1. `GET /v1/reporting/categories`
   - Returns the full active category tree with hierarchical nesting and metadata.
   - Publicly readable by all signed-in members.
2. `POST /v1/operator/categories`
   - Operator auth required.
   - Adds a new category node to the tree without code modifications.
3. `PUT /v1/operator/categories/{path...}`
   - Operator auth required.
   - Updates title, description, dimensions mapping, or active status.
4. `GET /v1/reporting/tokens/by-category`
   - Returns token burn and cost aggregated across category paths for a specified time range, with support for depth filtering (`?depth=1` or `?depth=2`).

---

## 5. Future tabs architecture (Tokens, Issues, Posts, Lanes)

The remaining tabs defined in poll `1dd28b0e` are phased for subsequent implementation lanes:

### 5.1 Tab 3: Tokens (`/reporting/tokens`)
- **Access**: Operator admins only (Owner decision Poll 4 Choice A, HUM-10 msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17). Standard workspace admins and members never see this tab (`operatorsOnly: true` in tab routing; standard workspace requests return HTTP 403 Forbidden). Token burn telemetry remains strictly within operator administration.
- **Focus**: Multi-dimensional token consumption and expenditure analytics.
- **Visualisations**:
  - Breakdown by Activity Category (using the hierarchical tree rollup from Section 4).
  - Breakdown by Agent Type / Vendor (`claude`, `grok`, `mistral`, `agy`, `qwen`).
  - Breakdown by Class (`ci`, `refactor`, `bug`, `feature`).
  - Breakdown by Role (`orch`, `coder`, `doc`, `test`, `review`).
  - Top 10 most expensive issues (`issue_key`).
- **Data sources**: Joins `fleet_token_burn_events` (spec 140) with `activity_categories` and `fleet_asks`. Reuses existing route `GET /v1/operator/fleet-tokens`.

### 5.2 Tab 4: Issues (`/reporting/issues`)
- **Focus**: Operational delivery cycle and issue flow efficiency.
- **Visualisations**:
  - Issues opened vs closed per day / week.
  - Cycle time distribution (time from `eval`/`wip` to `done` on master).
  - Status backlog distribution (`open`, `wip`, `blocked`, `needs-owner`, `qas`, `done`).
  - Breakdown by Area (`orc`, `api`, `wui`, `iac`, `cnf`, `doc`, `rdb`).
- **Data sources**: Hub table `issues` (spec 135) and `issue_events` (rdb `0181`).

### 5.3 Tab 5: Posts & Communication (`/reporting/posts`)
- **Focus**: Workspace communication patterns and agent responsiveness.
- **Visualisations**:
  - Posts per day per channel and per topic.
  - Turnaround / answer latency (time from question post to first peer/agent reply).
  - Escalation rate (frequency of dead-letters and owner escalation).
  - Most active topics and threads.
- **Data sources**: Hub tables `messages` and `topic_heads` (spec 099).

### 5.4 Tab 6: Lanes & Fleet Orchestration (`/reporting/lanes`)
- **Focus**: Agent lifecycle execution and fleet reliability.
- **Visualisations**:
  - Lanes spawned per day.
  - Landing success rate (first-pass success vs failed tries vs takeovers).
  - Average execution duration per work kind.
  - Box runner distribution and hardware load correlation.
- **Data sources**: Hub table `fleet_asks`, `box_beats`, and runner agent registry logs.

---

## 6. Security, access control & privacy

### 6.1 Role-Based Access Control (RBAC) Matrix

| Route / Tab | Allowed Roles | Authentication Mechanism | Scope Enforcement |
|---|---|---|---|
| `/reporting` (Shell) | All signed-in members | Member session cookie / Bearer | Redirects to `/reporting/releases` |
| `/reporting/releases` | All signed-in members | Member session (`humanTenant`) | Estate-wide data (`release_notes`) |
| `/reporting/sql` | Workspace Admins (`admin`) | Member session + `reporting.sql.run` | Workspace RLS (`app.tenant_id`) |
| `/reporting/tokens` | Operator Admins only | Operator Auth (`operatorActor`) | Fleet operator scope (operator workspace only; standard workspace admins never see it) |
| `/reporting/issues` | All signed-in members | Member session (`humanTenant`) | Workspace scope |
| `/reporting/posts` | All signed-in members | Member session (`humanTenant`) | Workspace scope |
| `/reporting/lanes` | Operator Admins | Operator Auth (`operatorActor`) | Fleet estate scope |
| `POST /v1/reporting/sql` | Workspace Admins (`admin`) | Member session + RBAC check | Transaction READ ONLY, workspace RLS |
| `POST /v1/operator/deploys` | CI Deployment SA | Google ID Token (`operatorAuth`) | Operator scope |
| `POST /v1/operator/categories` | Operator Admins | Google ID Token (`operatorAuth`) | Operator scope |

### 6.2 Data protection & hygiene rules

1. **No Personal Data Leaks**: Release notes, query audit logs, and category definitions must pass the distribution hygiene filter (`CLAUDE.md`). No personal emails, passwords, or runner box machine names may appear in audit messages or UI previews.
2. **Read-Only Invariant**: The SQL tab cannot modify state. Tests must prove that write queries fail at the database level even if a caller bypasses the application parser.
3. **Workspace Isolation**: A workspace admin is strictly confined to their own workspace's records in the SQL tab. A test must verify that an admin of Workspace A receives 0 rows when attempting to select records from Workspace B.

---

## 7. Owner decisions (HUM-10, t1 topic af25a1f3, 2026-10-17)

The owner decided all four design questions in prd workspace `t1`, topic `af25a1f3-7291-4675-855e-c67101680955` on 2026-10-17 (poll form msg `e5dc787b-4207-48c7-9433-2930e3acdb8d`, newest form answer msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 09:42–09:45Z; confirmed by c-002 in msg `07a2acb7-a00d-4bad-a9f2-10409dc7581d`):

### Poll 1: SQL Tab Result Export Affordances
Which export formats should the SQL tab result table support for workspace admins?
- **Choice A (Minimal)**: Copy to clipboard as formatted TSV/CSV text only.
- **Choice B (CSV Download)**: Dedicated "Download .csv" button generating browser blob download.
- **Choice C (CSV + JSON)**: Buttons for both CSV download and raw JSON array download.

**Owner Decision**: **Choice C (CSV and JSON download) PLUS Copy to clipboard** (msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17 09:42Z; plus owner msg `9c32201b-c261-4c9f-888d-e7c636d1c893`, 09:42Z verbatim: *"SQL tab: export of the result? and add copy to clipboard button as well"*).  
Three export buttons are provided: Copy (clipboard), Download .csv, Download .json. All three operate on the returned in-memory result set (capped at 2,000 rows).

### Poll 2: Activity Category Initial Tree Seed
How should the initial category tree be seeded in production migration `0204_activity_categories.sql`?
- **Choice A (Standard 5 domains)**: Seed the 5 primary domains (`coding`, `review`, `specs_and_docs`, `tests`, `dispatch`) with standard subcategories.
- **Choice B (Minimal 2 levels)**: Seed only top-level domains (`coding`, `docs`, `ops`) and let operators create finer child categories on the fly.
- **Choice C (All 4 dimensions explicit)**: Seed explicit matrix combinations of Kind and Class (e.g. `coding/feature`, `coding/bug`, `doc/spec`).

**Owner Decision**: **Choice A (5 areas with sub-categories)** (msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17 09:42Z).  
Seed the 5 primary domains (`coding`, `review`, `specs_and_docs`, `tests`, `dispatch`) as specified in §4.2.1.

### Poll 3: Estate Deploy Ingest Source
What should be the primary trigger for recording deployment events in `estate_deploys`?
- **Choice A (CI Workflow Webhook)**: Curl command at the end of `.github/workflows/20_hub-build-deploy.yml` and `30_wui-build-deploy.yml` calling `POST /v1/operator/deploys` with the deployment SA ID token.
- **Choice B (Hub Periodic Probe)**: Scheduled hub background task every 2 minutes that probes `/version` and Firebase `build.json`, recording a new deploy when the SHA changes.
- **Choice C (Both)**: CI workflow curl as primary, with hub periodic probe as reconciliation fallback.

**Owner Decision**: **Choice C (The deploy step reports it, plus a hub check that catches a missed one)** (msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17 09:42Z).  
Both the CI deploy step AND a hub reconciliation check running every 2 minutes that compares live served endpoints against `estate_deploys` and fills in missed deploys with `deployed_by = 'hub-reconcile'`.

### Poll 4: Tokens Tab Scope for Standard Workspace Admins
When the Tokens tab (`/reporting/tokens`) is implemented:
- **Choice A (Operator Admins only)**: Fleet token burn is visible exclusively to operator workspace admins; standard workspace admins see an empty/hidden tab.
- **Choice B (Workspace-scoped token burn)**: Standard workspace admins see token burn consumed exclusively by agents and AI assistants acting within their own workspace.

**Owner Decision**: **Choice A (No: token burn stays for operator admins only)** (msg `a8bfcdd0-62d1-46ba-8708-e303cf93f1f7`, 2026-10-17 09:42Z).  
The Tokens tab is restricted to operator workspace admins only (`operatorsOnly: true`); standard workspace admins never see it.

---

## 8. Releases label cost in currency and tokens (Addendum v0.3.0, SPL-3893)

### 8.1 Context & Owner Request

In prd workspace `t1`, topic `7adb4163-3c65-4a49-a9bb-d17acbe2cf95` (msg `58730eea-c431-4969-84c8-4722cdea94c5`, 2026-10-27 18:10Z), accompanied by a screenshot of `/reporting/releases` (Time window: Last 7 days), the owner requested:

> "the long term in the reporting should be this view , but having both the costs in currency and tokens for each label"

The Releases tab label cloud live since SPL-3796 (§2.2.1) renders two pill clusters:
1. **Kind labels**: `perf`, `test`, `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`
2. **Area labels**: `rdb`, `iac`, `wui`, `orc`, `doc`, `api`, `cnf`

Currently, each pill displays its label name and commit count (e.g. `feat 42`), sized by its share of total commits, followed by the daily commit breakdown. Under this addendum, each pill expands to present its accumulated resource consumption across both primary telemetry dimensions:
- **Tokens**: Total metered tokens burned (input + output + cache-write) to deliver commits bearing that label within the selected window.
- **Currency**: Actual money spent in the active currency (USD or EUR, matching the Costs section currency setting), derived from daily estate paid AI subscription rates.

### 8.2 Finding a Commit's Tokens: The Attribution Chain

Tokens are attributed to landed commits through a deterministic, auditable three-link chain:
$$\text{Lane} \longrightarrow \text{Issue} \longrightarrow \text{Commit(s)}$$

1. **Lane Placement**:
   When an agent lane is spawned (e.g., `agent_id = 'a-452'` on box `sat`), `do_spl_spawn_place` and `do_spl_lane_issue place` link the lane to an assigned issue `SPL-n`:
   - Records `a-452` in `fleet_asks` (`from_agent`, `created_at`, `work_kind`, `category_path`).
   - Inserts active entry in `fleet_lanes` (`agent_id`, `state = 'live'`, `updated_at`).
   - Transitions issue `SPL-n` to `status = 'wip'`, writing an audit comment: `Lane a-452 placed on SPL-n, status wip.`
   - Writes `lifetime/issue` with key `SPL-n`.
   - The lane's start timestamp $t_{\text{start}}$ is stamped from the `wip` transition.

2. **Telemetry Accumulation**:
   While the agent runs, the on-box collector records minute-by-minute token burn in `fleet_token_burn_events` with columns `(box_tag, agent_id, minute_bucket, vendor, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, is_metered, work_tenant)`. These events roll up daily into `fleet_token_burn_daily`.
   The lane's token burn consists of all metered tokens burned by `agent_id` during its active lifespan:
   $$T_{\text{lane}} = \sum_{t \in [t_{\text{start}}, t_{\text{end}}]} (\text{input\_tokens} + \text{output\_tokens} + \text{cache\_write\_tokens})$$
   Consistent with S3 (§3.3.1) and spec 140 §3.8, prompt cache reads are excluded from cost attribution calculations, as cache reads carry negligible or zero marginal billing impact on AI subscriptions.

3. **Landing & Closure**:
   When the lane completes its task, it pushes commit(s) to `master`. Each commit carries the issue key in its subject scope (e.g. `feat(api, SPL-n): ...`) or in a `Closes: SPL-n` trailer.
   - The commit lands on `master` and is ingested into `release_notes` (`sha`, `version`, `committed_at`, `kind`, `area`, `subject`).
   - The automated closer (`do_spl_issue_close_landed`, running every 5 min) detects the landed commit citing `SPL-n`, records the closing SHA in `issue_events`, and transitions `issues.status` to `'done'`.
   - The lane exits cleanly via `/exit-clean` (`LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done`), setting $t_{\text{end}} = \text{committed\_at}$ of the landing commit (or the lane exit timestamp).

### 8.3 Token & Cost Allocation for Multi-Commit and Multi-Label Lanes

1. **Multi-Commit Lanes (Equal $1/N$ Split)**:
   When a lane lands $N \ge 1$ commits $\{c_1, c_2, \dots, c_N\}$ associated with its issue `SPL-n`:
   - The lane's total token burn $T_{\text{lane}}$ is divided equally among the $N$ landed commits:
     $$T(c_j) = \frac{T_{\text{lane}}}{N} \quad \text{for each } j \in \{1, \dots, N\}$$
   - If the lane operated across multiple calendar days $d \in D$, the day-by-day burn $T_{\text{lane}}(d)$ is partitioned equally:
     $$T(c_j, d) = \frac{T_{\text{lane}}(d)}{N}$$
   - **Rationale**: Agent lanes rebase and push their work atomically at lane exit. Intermediate git commit timestamps reflect local checkpoints rather than isolated reasoning cycles. Equal division ($1/N$) is mathematically rigorous, deterministic, requires no speculative AST or line-count churn heuristics, and strictly guarantees conservation of tokens: $\sum_{j=1}^N T(c_j) = T_{\text{lane}}$.

2. **Orthogonal Label Dimensions (`kind` and `area`)**:
   Every commit $c_j$ stored in `release_notes` possesses exactly one semantic `kind` (e.g. `feat`) and one architectural `area` (e.g. `api`).
   - The commit's full token count $T(c_j)$ and currency cost $\text{Cost}(c_j)$ are attributed in full to its `kind` label:
     $$T(K) = \sum_{c \in \text{commits}(K)} T(c), \quad \text{Cost}(K) = \sum_{c \in \text{commits}(K)} \text{Cost}(c)$$
   - The commit's full token count $T(c_j)$ and currency cost $\text{Cost}(c_j)$ are attributed in full to its `area` label:
     $$T(A) = \sum_{c \in \text{commits}(A)} T(c), \quad \text{Cost}(A) = \sum_{c \in \text{commits}(A)} \text{Cost}(c)$$
   - **Conservation Invariant**: `kind` and `area` represent orthogonal taxonomy views over the same commit population. The sum of tokens across all kind labels equals the sum across all area labels, which equals total tracked commit tokens:
     $$\sum_{K} T(K) = \sum_{A} T(A) = \sum_{c \in \text{tracked}} T(c)$$

### 8.4 Calculating Currency Costs (Estate-Wide AI Daily Rate & FX Conversion)

Currency costs follow the S3 paid-AI month read architecture (`csi-spl-api/.../internal/store/cost_ai_paid.go`, SPL-3810) and implement the owner's foundational cost allocation rule:

> "the amount of tokens spent vis the total tokens spent in the spool-hub and than just divice the money"  
> (Owner HUM-10, prd t1 topic `739e1622`, msg `ff770270`)

1. **Daily Estate Rate Formulation**:
   For each UTC calendar day $d$:
   - Total paid AI expenditure for day $d$ is the sum of daily USD micros across all active subscriptions and top-ups in `fleet_token_paid` paying for day $d$:
     $$\text{USD\_micros}_{\text{estate}}(d) = \sum_{i \in \text{active}(d)} \text{AIPaidDailyMicros}(i, \text{rate}(i))$$
   - Total metered tokens burned across the estate by all agents on day $d$ is:
     $$T_{\text{estate}}(d) = \sum_{\text{all lanes}} T(\text{lane}, d)$$
   - The estate's effective token rate for day $d$ is:
     $$R(d) = \frac{\text{USD\_micros}_{\text{estate}}(d)}{T_{\text{estate}}(d)} \quad (\mu\text{USD per token})$$
   - Where broken down per agent vendor/model $v$, the rate applies per-vendor matching S3's `AIShareSplit`:
     $$\text{USD\_micros}(L, v, d) = \left\lfloor \text{USD\_micros}_{\text{estate}}(v, d) \times \frac{T(L, v, d)}{T_{\text{estate}}(v, d)} \right\rfloor$$

2. **Commit Currency Cost**:
   For commit $c_j$ produced by lane $L$ over days $D$:
   $$\text{USD\_micros}(c_j) = \frac{1}{N} \sum_{d \in D} \text{USD\_micros}(L, d)$$

3. **Second Currency Conversion (EUR)**:
   Consistent with S3 and spec 123 §5.4, currency conversion is performed day-by-day using that specific UTC day's ECB reference exchange rate ($\text{Rate}_{\text{USD}\to\text{EUR}}(d)$ via `secondFXDays`):
   $$\text{EUR\_micros}(c_j) = \frac{1}{N} \sum_{d \in D} \left\lfloor \text{USD\_micros}(L, d) \times \text{Rate}_{\text{USD}\to\text{EUR}}(d) \right\rfloor$$
   The Releases page reacts immediately to the currency selector in the header (USD or EUR), summing the appropriate daily micros.

### 8.5 Label Cloud Presentation & Time Windows

1. **Time Range Scopes**:
   The Releases tab supports preset time filters:
   - `Today` (current UTC day since 00:00Z)
   - `Last 7 Days` (default)
   - `Last 30 Days`
   - `Last 90 Days`
   - `Custom Range` (`from` and `to` dates)
   Label costs are computed strictly over the commits whose `committed_at` falls within the chosen window.

2. **Pill Visual Formatting**:
   In `ReleasesFilterBar.vue`, each Kind and Area pill renders a structured composite badge:
   - **Primary label & count**: e.g., `feat 42`
   - **Token burn**: e.g., `· 12.8M tok` (formatted with metric suffixes: `k` for $\ge 10^3$, `M` for $\ge 10^6$, `B` for $\ge 10^9$)
   - **Currency cost**: e.g., `· $19.45` or `· €17.80` (formatted to two decimal places in the active currency)
   Example rendered pill text:
   `[ feat 42 · 12.8M tok · $19.45 ]`

3. **Layout & Sizing Preservation (SPL-3796)**:
   - Sizing steps (`rf-step-0` to `rf-step-5`) default to scaling with commit count square root ($\sqrt{\text{count}/\text{max}}$), preserving visual stability.
   - The center-pill placement algorithm (`labelCloud` in `csi-spl-wui/src/utils/reporting-releases.ts`) remains active: the largest label occupies the center of the cloud, with subsequent labels alternating right and left.
   - Interactive filtering is preserved: clicking any label pill toggles that label, filtering the commit list below while keeping cloud dimensions and counts fixed.

### 8.6 Handling Untracked / Human Commits and Telemetry Gaps

In adherence to the repository's TRUTH FIRST mandate, costs are never estimated, guessed, or fabricated where telemetry does not exist.

1. **Identified Telemetry Gaps**:
   - **Human Commits**: Commits authored directly by human operators (e.g., initial bootstrap commits, emergency fixes, out-of-band administrative patches).
   - **Unlinked Commits**: Commits whose subject scope contains no recognized issue key (`SPL-n`), or whose issue records no active agent lane in `fleet_asks` / `fleet_lanes`.
   - **Historical Commits**: Commits landed before token telemetry infrastructure was established (pre-rdb `0199`/`0229`).
   - **Unmetered Models**: Agent sessions executed on providers or mock environments flagged as `not_metered` (spec 140 §3.8).

2. **Visual Treatment in WUI**:
   - **Daily Commit List**:
     - Tracked commits display a distinct cost badge: `[ 350k tok · $0.54 ]`.
     - Untracked commits display a muted neutral badge: `[ — · untracked ]` or `[ human / no lane ]`. Clicking or hovering reveals an explanatory tooltip: `"No agent lane telemetry recorded for this commit."`
   - **Label Cloud Pills**:
     - A label's token and currency totals represent the sum of its *tracked* commits.
     - When a label contains a mix of tracked and untracked commits (e.g. 38 tracked, 4 untracked), the pill displays a coverage indicator: e.g., tooltip `"38 of 42 commits tracked (90%)"`.
     - When all commits in a label are untracked (e.g., a chore completed entirely by human maintainers), the pill displays `[ chore 5 · — · untracked ]`.

### 8.7 Implementation Architecture: Database Ledger, Hub API & WUI Integration

1. **Database Schema: `commit_token_burn` Ledger**:
   Querying minute-by-minute `fleet_token_burn_events` across a 90-day window on every UI request is computationally prohibitive, and `events` are pruned after 30 days. Because landed commits and historical lane burns are immutable, a forward-only migration `0236_commit_token_burn.sql` introduces a persistent ledger:

   ```sql
   -- 0236_commit_token_burn.sql - landed commit token and cost ledger (spec 143 addendum §8.7, SPL-3893)
   CREATE TABLE commit_token_burn (
       sha                text        PRIMARY KEY REFERENCES release_notes (sha) ON DELETE CASCADE,
       issue_key          text        NOT NULL,
       agent_id           text        NOT NULL,
       tokens_metered     bigint      NOT NULL CHECK (tokens_metered >= 0),
       tokens_cache_read  bigint      NOT NULL DEFAULT 0 CHECK (tokens_cache_read >= 0),
       usd_micros         bigint      NOT NULL CHECK (usd_micros >= 0),
       computed_at        timestamptz NOT NULL DEFAULT now()
   );

   CREATE INDEX commit_token_burn_issue ON commit_token_burn (issue_key);
   CREATE INDEX commit_token_burn_agent ON commit_token_burn (agent_id);

   ALTER TABLE commit_token_burn ENABLE ROW LEVEL SECURITY;
   ALTER TABLE commit_token_burn FORCE ROW LEVEL SECURITY;
   CREATE POLICY public_select ON commit_token_burn FOR SELECT USING (true);
   CREATE POLICY operator_write ON commit_token_burn FOR ALL
       USING (current_setting('app.rls_scope', true) = 'operator')
       WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
   ```

2. **Ingestion & Historical Backfill**:
   - **Automated Ingestion**: `do_spl_issue_close_landed` is extended to invoke the attribution calculator when closing an issue upon commit landing, inserting records into `commit_token_burn`.
   - **Reconciliation Worker**: A hub background task computes and records rows for newly ingested commits in `release_notes` that cite closed issues.
   - **Backfill**: A one-time backfill script processes historical commits within the 365-day `fleet_token_burn_daily` retention window.

3. **Hub API Routes**:
   - `GET /v1/reporting/releases/daily`: Extended to include aggregated cost maps:
     ```json
     {
       "days": [ ... ],
       "kinds": { "feat": 42, "fix": 15 },
       "areas": { "api": 25, "wui": 32 },
       "costs": {
         "currency": "USD",
         "tokens_by_kind": { "feat": 12800000, "fix": 4200000 },
         "usd_micros_by_kind": { "feat": 19450000, "fix": 6380000 },
         "tokens_by_area": { "api": 8500000, "wui": 8500000 },
         "usd_micros_by_area": { "api": 12900000, "wui": 12930000 },
         "tracked_by_kind": { "feat": 42, "fix": 14 },
         "tracked_by_area": { "api": 25, "wui": 31 }
       }
     }
     ```
   - `GET /v1/reporting/releases/commits`: Each commit item in the returned array carries:
     ```json
     {
       "sha": "1759dd7e2...",
       "subject": "feat(api, SPL-3796): ...",
       "tokens_metered": 350000,
       "usd_micros": 532000,
       "tracked": true,
       "lane_id": "a-452"
     }
     ```
     For untracked commits, `tokens_metered` and `usd_micros` are `null`, and `tracked` is `false`.

4. **WUI Architecture**:
   - `csi-spl-wui/src/utils/reporting-releases.ts`: Updated to compute `labelTokenCounts` and `labelCostAmounts` from API responses, formatting token strings with compact engineering suffixes (`12.8M`) and money strings with locale currency symbols (`$19.45` / `€17.80`).
   - `ReleasesFilterBar.vue`: Displays tokens and currency inside pills, reacting to window and currency updates.
   - `ReleasesDailyList.vue`: Renders the cost badge on each commit row.

### 8.8 Phased Build Tasks (One Row = One Lane)

The implementation is structured into seven discrete, test-guarded lane tasks:

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T070** | **Planned** | `rdb` | `reporting-label-cost` | **Database schema migration: `commit_token_burn`** (§8.7). Forward-only migration `0236_commit_token_burn.sql` creating table `commit_token_burn` (`sha` PK REFERENCES `release_notes`, `issue_key`, `agent_id`, `tokens_metered`, `tokens_cache_read`, `usd_micros`, `computed_at`). Estate-wide table with public select and operator write RLS.<br>• *Gate*: `psql` applies migration cleanly; foreign key enforces valid SHA in `release_notes`.<br>• *Red Control*: Inserting duplicate SHA fails primary key constraint. |
| **T071** | **Planned** | `api` | `reporting-label-cost` | **Store implementation & token attribution engine** (§8.2, §8.3, §8.4). Implement Go store in `internal/store/commit_token_burn.go` computing lane token burn from `fleet_token_burn_events` / `fleet_token_burn_daily` between placement and landing, applying equal $1/N$ split per commit, and pricing USD micros via daily estate paid rate from `cost_ai_paid.go`.<br>• *Gate*: Unit test verifies accurate token and money split across multi-commit lanes and correct pricing against daily paid items.<br>• *Red Control*: Dividing by zero on day with zero total tokens falls back safely to zero without panic. |
| **T072** | **Planned** | `api` | `reporting-label-cost` | **Ingestion hook in `issue-close-landed` & historical backfill** (§8.2, §8.7). Extend `issue-close-landed` to compute and write `commit_token_burn` rows as issues close upon commit landing. Provide backfill routine for existing commits.<br>• *Gate*: Test verifies closing issue triggers insertion into `commit_token_burn`.<br>• *Red Control*: Re-closing an already processed issue is idempotent and does not overwrite existing rows. |
| **T073** | **Planned** | `api` | `reporting-label-cost` | **Hub read route extensions: releases daily & commits** (§8.7). Extend `GET /v1/reporting/releases/daily` with token and USD/EUR breakdowns per kind and area label, and `GET /v1/reporting/releases/commits` with commit-level token and cost fields.<br>• *Gate*: Endpoint test asserts returned label sums match sum of constituent commit costs.<br>• *Red Control*: Querying with unsupported currency code returns HTTP 400 `bad_currency`. |
| **T074** | **Planned** | `wui` | `reporting-label-cost` | **Releases label cloud cost formatting: `reporting-releases.ts` & `ReleasesFilterBar.vue`** (§8.5). Render token burn and currency cost within each Kind and Area pill, maintaining centered cloud distribution and responsive 390px layout.<br>• *Gate*: Component test verifies pills display formatted tokens and money, and retain selection toggle behavior.<br>• *Red Control*: Missing cost data renders gracefully without crashing pill layout. |
| **T075** | **Planned** | `wui` | `reporting-label-cost` | **Commit list row cost pills & currency switcher: `ReleasesDailyList.vue`** (§8.5, §8.6). Render `[tokens · cost]` badge on tracked commits and neutral `[— · untracked]` on untracked/human commits. Support header currency toggle (USD/EUR).<br>• *Gate*: Component test verifies tracked commits display cost pills and untracked commits display neutral badges.<br>• *Red Control*: Untracked commit displaying fabricated non-zero cost fails test assertion. |
| **T076** | **Planned** | `test` | `reporting-label-cost` | **End-to-end integration and verification tests** (§8.5, §8.6). Integration tests in `tests/e2e/reporting.test.mjs` verifying label cloud cost display, currency toggling, commit list cost badges, and untracked commit rendering across desktop and mobile viewports.<br>• *Gate*: E2E test suite passes cleanly.<br>• *Red Control*: Any mismatch between label cost total and daily commit sum fails assertion. |

### 8.9 Open Owner Questions

```poll
Q1 What sizes the pills in the Releases label cloud?
(A) Keep commit count (square root of commit count, as today; tokens and money are displayed inside the pill) (recommended)
(B) Size by token burn (largest pill = highest token consumption in the window)
(C) Size by total money spent (largest pill = highest currency cost in the window)
Q2 When a lane produces multiple commits, how are its tokens and money divided across them?
(A) Equal split across the lane's landed commits (1/N per commit), full share to kind and area (recommended)
(B) Split proportionally by file churn (lines added and deleted in each commit's diff)
(C) Require lanes to record token shares explicitly in git trailers (e.g. Tokens: 3.5M)
Q3 How should untracked commits (human commits, legacy commits before token tracking) be reflected?
(A) Show neutral badge [— · untracked] on commit rows and a coverage indicator on label pills (e.g. 37/42 tracked) (recommended)
(B) Add a dedicated (human / untracked) pill in the cloud grouping all unattributed commits
(C) Estimate their cost using the average cost per commit of tracked commits in the same label
```

---

<!-- version: 0.3.0 · updated: 2026-10-27 · last-edit: 2026-10-27T23:30:00Z -->

