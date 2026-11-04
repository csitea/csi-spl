# Spec 171: Per-Workspace Git Repository for Reporting, Commits, Release Notes, and Commit Analysis

- **Status:** Draft — Q2..Q5 decided by owner (`HUM-10`, 2026-11-04, topic `f38888e7-27eb-4aad-b2fe-1736ffbb2f0e`); Q1 (`4b5869d5`, repos per workspace) awaiting owner answer
- **Date:** 2026-11-04
- **Track:** `SPL-4808` (epic `SPL-2400`)
- **Depends on:**
  - [Spec 065 — Release Notes Table (`release_notes`)](../065-release-notes-table/spec.md)
  - [Spec 098 — Tenant Settings JSONB (`tenants.settings`)](../098-tenant-settings-jsonb/spec.md)
  - [Spec 127 — Per-Workspace BYO Keys & KMS Envelope](../159-byo-ai-keys/spec.md)
  - [Spec 143 — Reporting Section (`/reporting/*`)](../143-reporting-section/spec.md)
  - [Spec 170 — Day-Tasks Reminder & To-Do View](../170-day-tasks-reminder/spec.md)
  - [Lane Issue & Docs Guide §5 — A lane in a workspace's own repo](../../doc/md/lane-issue-and-docs.md)
  - `SPL-4789` — Bidirectional Commit ↔ Issue ↔ Discussion Links (`origin/review/c-944-commit-links`, `8f1834b21..12f302fd9`)

---

## 1. The Owner's Words & Problem Statement

On 2026-11-04 (`HUM-10`, messages `5bb423dd`, `0fcabe44`, `76ce11aa`, `19402a08`, `d0f66e74`, `ecd8f77e`, `f211b11a`, `2a7e391e`), the owner opened `/reporting/releases` inside a non-`spool-hub` product workspace (`https://<WORKSPACE>.<BASE_DOMAIN>/bg/reporting/releases`) and attached screenshot `98a12d45392b60cdddcf2e9b5263c849835f50fb2c8753fe1c5ed8ebc396775f`:

> - `5bb423dd` (16:28:18Z): *"Wait why do I see the releases for the spool-hub here vs the releases for `<WORKSPACE>`"*
> - `0fcabe44` (16:28:32Z): *"Here we must see the commits for the `<WORKSPACE>` project explicitly"*
> - `76ce11aa` (16:29:00Z): *"Every workspace in a spool-hub instance other than the spool-hub workspace MUST follow its OWN git repo for the commits AND the analysis for it"*
> - `19402a08` (16:29:17Z): *"Spec it first clarify before building"*
> - `d0f66e74` (16:29:53Z): *"Let's configure the `<WORKSPACE>` repo first in this workspace"*
> - `ecd8f77e` (16:30:10Z): *"What do you need carefully plan first"*
> - `f211b11a` (16:31:01Z): *"Find the `<WORKSPACE>` project repo on github connected to the `<LIVE_URL>` site"*
> - `2a7e391e` (16:34:28Z): *"Same for this workspace we MUST track the `<WORKSPACE_2>` repository here NOT the spool-hub repository ... Ask the same team who works on the `<WORKSPACE>` workspace spec right now so we do it ONCE and set up at 2 places minimum"*

### Core invariant

1. **The `spool-hub` workspace (`t1`, slug `system`)** tracks the `csitea/csi-spl` repository (`spool-hub` itself).
2. **Every other workspace `<WORKSPACE>` on a `spool-hub` instance** tracks **its own configured git repository** (`<ORG>/<REPO>`), never `csitea/csi-spl`.
3. If a non-`t1` workspace has **no repository configured yet**, Reporting → Releases, Release Notes, and commit-hash linkification MUST show an explicit *"No git repository is connected to `<WORKSPACE>` yet"* empty state (and leave raw hex tokens unlinked) rather than falling back to `csitea/csi-spl` commits or deploys.

---

## 2. What a Non-`spool-hub` Workspace Shows Today (Measured on `origin/master` `504cafd15`)

Every statement below was verified against `origin/master` (`504cafd15`, tag `v8.2.6-c3`) and the in-flight `SPL-4789` review branch (`origin/review/c-944-commit-links`, head `12f302fd9`).

### 2.1 Summary matrix of surfaces

| Surface | URL / Component | What `<WORKSPACE>` shows today | Why (exact table & code) |
|---|---|---|---|
| **Reporting → Releases** | `/reporting/releases` (`csi-spl-wui/src/pages/reporting/releases.vue`) | `csi-spl` releases (`168`), `csi-spl` commits (`724`), `csi-spl` `dev`/`prd` deploys (`204`/`204`), `csi-spl` sub-project area pills (`orc`, `api`, `wui`, `iac`, `cnf`, `doc`, `rdb`), and `github.com/csitea/csi-spl/commit/<sha>` links | `release_notes` (`0108_release_note.sql:14-16`) and `estate_deploys` (`0202_estate_deploys.sql:11-13`) have **no `tenant_id` column** and no tenant RLS. `hub/reporting_releases.go:47` discards the caller's tenant (`_, hum, ok := s.humanTenant(w, r)`). `reporting-releases.ts:42` hardcodes `RELEASE_AREAS = ['orc','api','wui','iac','cnf','doc','rdb']`. |
| **Release Notes modal & page** | `ReleaseNotesDialog.vue`, `/releases/<ref>` (`pages/releases/[version].vue`) | `csi-spl` versions (`v8.2.6-c3`, …) and `csi-spl` commit notes (`Lay-*` / `Tech-*`) | `hub/release_notes.go:152-173` (`releaseReader`) validates that the workspace exists and then discards the tenant ID, querying global `release_notes` (`store/release_note_postgres.go:12-14, 108-186`). |
| **Commit hash linkification in messages, notes, and issue bodies** | `commit-links.client.ts`, `utils/commit-links.ts` | Any 7..40-char hex token in `<WORKSPACE>` chat or docs links to `https://github.com/csitea/csi-spl/commit/<sha>` | `commit-links.client.ts:13-14` reads `config.public.repoWebUrl` and `config.public.repoCommitPath` from static `/config.json`, which `csi-spl-cnf/csi-spl/all.env.yaml:1533-1535` pins instance-wide to `https://github.com/csitea/csi-spl` and `/commit/`. |
| **Commit ↔ Issue ↔ Discussion links (`SPL-4789`)** | `0261_release_note_issue_keys.sql`, `hub/issues.go` (`origin/review/c-944-commit-links`) | `release_notes` remains one global table; `env.hub.commit_issue_tenant: t1` stamps every ingested commit with `issue_tenant = 't1'` | `8f1834b21` adds `issue_tenant` + `issue_keys` to global `release_notes`, and `cb1b13f3c` sets `commit_issue_tenant: t1` in `all.env.yaml`. |
| **Reporting → SQL** | `/reporting/sql` (`hub/reporting_sql.go`, `store/reporting_sql.go`) | Workspace tables (`issues`, `threads`, `messages`, `usage_events`, …) are RLS-isolated to `<WORKSPACE>`, **except** `SELECT * FROM release_notes` and `SELECT * FROM estate_deploys` return `csi-spl` rows | `store/reporting_sql.go` sets `SET LOCAL app.tenant_id = <workspace>`, `app.rls_scope = 'tenant'`, but `release_notes` has no RLS (`0108_release_note.sql:16`) and `estate_deploys` has `USING (true)` (`0202_estate_deploys.sql:46-47`). |
| **Reporting → Costs / Marketing / Incomes / Finance** | `/reporting/{costs,marketing,incomes,finance}` | Workspace-scoped (filtered by `tenant_id = <WORKSPACE>` or staff/owner gate) | `hub/usage.go`, `hub/reporting_marketing.go`, `hub/reporting_incomes.go`, `hub/reporting_finance.go` pass the workspace `tenant` into store queries. |
| **Reporting → Issues / Posts / Lanes** | `/reporting/{issues,posts,lanes}` | Placeholder cards (`ready: false` in `reporting-tabs.mjs:39-42`) | `csi-spl-wui/src/utils/reporting-tabs.mjs:39-42` and `csi-spl-wui/src/pages/reporting/{issues,posts,lanes}.vue`. |

### 2.2 Exact database tables & columns that pin commits and releases to `csi-spl`

1. **`release_notes` (`csi-spl-rdb/src/sql/postgres/spool-hub/0108_release_note.sql:14-16, 24-41`)**
   - Command:
     ```bash
     nl -ba csi-spl-rdb/src/sql/postgres/spool-hub/0108_release_note.sql | sed -n '12,42p'
     ```
   - Lines `14-16`:
     ```sql
     --   * Estate-wide, NOT per tenant: every tenant runs the same code, so
     --     the table has no tenant_id and no row security. Reads go through
     --     the public /v1/release-notes endpoints; writes go through
     --     /v1/operator/release-notes gated by requireOperator Scope=release.
     ```
   - Columns (`0108_release_note.sql:24-41`, altered by `0114_release_note_cycle.sql:16-27` and `0177_release_notes_released_at.sql:14-18`):
     - `sha text PRIMARY KEY` (40-hex SHA; not scoped by `tenant_id` or `repo`)
     - `version text NULL` (`^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$`)
     - `committed_at timestamptz NOT NULL`
     - `released_at timestamptz NULL`
     - `kind text NOT NULL DEFAULT ''`
     - `area text NOT NULL DEFAULT ''`
     - `subject text NOT NULL`
     - `lay_what`, `lay_how`, `lay_why`, `tech_what`, `tech_how`, `tech_why` (`text NOT NULL DEFAULT ''`)
     - `state text NOT NULL` (`complete | partial | missing | revert | merge`)
     - `reverts text NULL`
     - `link text NOT NULL DEFAULT ''`
     - `ingested_at timestamptz NOT NULL DEFAULT now()`
   - On `origin/review/c-944-commit-links` (`8f1834b21`, `0261_release_note_issue_keys.sql:15-36`), two columns are added to `release_notes`: `issue_tenant text NULL REFERENCES tenants(id)` and `issue_keys text[] NOT NULL DEFAULT '{}'`, still on the single global `release_notes` table.

2. **`estate_deploys` (`csi-spl-rdb/src/sql/postgres/spool-hub/0202_estate_deploys.sql:11-13, 20-47`)**
   - Command:
     ```bash
     nl -ba csi-spl-rdb/src/sql/postgres/spool-hub/0202_estate_deploys.sql | sed -n '10,48p'
     ```
   - Lines `11-13` & `45-47`:
     ```sql
     -- Estate-wide table (no tenant_id): every workspace runs on the same
     -- hub + wui binaries per environment, and the Reporting -> Releases tab
     -- (spec 143 §2.2) is readable by any authenticated workspace user.
     ...
     ALTER TABLE estate_deploys ENABLE ROW LEVEL SECURITY;
     CREATE POLICY estate_deploys_read ON estate_deploys
         FOR SELECT TO PUBLIC USING (true);
     ```
   - Columns: `deploy_id bigserial PRIMARY KEY`, `env text NOT NULL` (`dev | prd`), `component text NOT NULL` (`hub | wui | inf`), `version text NOT NULL`, `commit_sha text NOT NULL`, `deployed_at timestamptz NOT NULL`, `status text NOT NULL`, `source text NOT NULL`, `workflow_run_id bigint`, `deployed_by text`.

3. **`commit_token_burn` (planned in `csi-spl-doc/specs/143-reporting-section/spec.md:884-913`, `SPL-3893`)**
   - Command:
     ```bash
     nl -ba csi-spl-doc/specs/143-reporting-section/spec.md | sed -n '884,913p'
     ```
   - Spec 143 §8.7 defines `commit_token_burn` with `sha text NOT NULL REFERENCES release_notes (sha) ON DELETE CASCADE` and `USING (current_setting('app.rls_scope', true) = 'operator')`, with no `tenant_id` column.

### 2.3 Exact Go API, Store, WUI, and Orc `file:line` citations

1. **Hub API — Reporting → Releases (`csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_releases.go`)**
   - Command:
     ```bash
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_releases.go | sed -n '36,58p;116,173p'
     ```
   - `reporting_releases.go:44-57` (`releaseReportReader`):
     ```go
     func (s *Server) releaseReportReader(w http.ResponseWriter, r *http.Request) (store.ReleaseReportStore, bool) {
     	if s.store == nil { ... }
     	_, hum, ok := s.humanTenant(w, r)
     	if !ok {
     		return nil, false
     	}
     	if hum == nil {
     		writeError(w, http.StatusForbidden, "human session required")
     		return nil, false
     	}
     	return s.store, true
     }
     ```
     The workspace `tenant` returned as the first value of `s.humanTenant(w, r)` is discarded (`_`).
   - `reporting_releases.go:116-143` (`handleReleasesDaily`) and `148-173` (`handleReleasesCommits`) call `rr.ReleaseDaily(r.Context(), f)` and `rr.ReleaseCommits(r.Context(), f)` without a tenant or repo argument.

2. **Hub Store — Reporting → Releases (`csi-spl-api/src/go/spool-hub-api/internal/store/reporting_releases.go`)**
   - Command:
     ```bash
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/store/reporting_releases.go | sed -n '15,35p;85,95p;211,271p'
     ```
   - `store/reporting_releases.go:15-19`:
     ```go
     // ReleaseReportStore serves the read-only Reporting -> Releases queries
     // over release_notes and estate_deploys (spec 143 §2.2). Both tables are
     // estate-wide, so no call takes a tenant id.
     ```
   - `store/reporting_releases.go:86-93`: strips `^csi-spl-` from `release_notes.area` in both Go (`strings.TrimPrefix(head, "csi-spl-")`) and SQL (`regexp_replace(lower(btrim(split_part(area, ',', 1))), '^csi-spl-', '')`).
   - `store/reporting_releases.go:211-271`: `ReleaseDaily`, `estateDeploys`, and `ReleaseCommits` query `FROM release_notes` and `FROM estate_deploys` directly on `s.pool` without `withTenant` or `WHERE tenant_id = ...`.

3. **Hub API & Store — Release Notes (`csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes.go` & `internal/store/release_note_postgres.go`)**
   - Command:
     ```bash
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes.go | sed -n '93,126p;152,268p'
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/store/release_note_postgres.go | sed -n '12,20p;69,186p'
     ```
   - `hub/release_notes.go:152-173` (`releaseReader`): checks `s.webCalendarTenant(r)` or `s.humanTenant(w, r)` solely to confirm the workspace exists, discards the tenant ID, and returns `s.store`.
   - `hub/release_notes.go:93-126` (`handleIngest`): `POST /v1/operator/release-notes` writes to the single global `release_notes` table.
   - `store/release_note_postgres.go:12-14`: `"Estate-wide table — no tenant_id, no withTenant transaction wrapper — so every query runs straight against s.pool."`

4. **WUI — Reporting → Releases, Release Notes Dialog, and Commit Links**
   - Command:
     ```bash
     nl -ba csi-spl-wui/src/utils/reporting-releases.ts | sed -n '38,45p'
     nl -ba csi-spl-wui/src/components/reporting/ReleasesDailyList.vue | sed -n '95,106p'
     nl -ba csi-spl-wui/src/components/ReleaseNotesDialog.vue | sed -n '265,298p'
     nl -ba csi-spl-wui/src/plugins/commit-links.client.ts | sed -n '1,23p'
     nl -ba csi-spl-cnf/csi-spl/all.env.yaml | sed -n '1530,1536p'
     ```
   - `csi-spl-wui/src/utils/reporting-releases.ts:40-42`:
     ```ts
     export const RELEASE_KINDS = Object.freeze(['feat', 'fix', 'docs', 'chore', 'perf', 'refactor', 'ci', 'test'])
     export const RELEASE_AREAS = Object.freeze(['orc', 'api', 'wui', 'iac', 'cnf', 'doc', 'rdb'])
     ```
   - `csi-spl-wui/src/components/reporting/ReleasesFilterBar.vue:23-48`: builds the Area pill cloud from `RELEASE_AREAS` (`orc`, `api`, `wui`, `iac`, `cnf`, `doc`, `rdb`), so any workspace repo whose commit scopes are e.g. `web`, `booking`, `cms`, `db`, `worker` would have all its area pills dropped or hidden unless areas come dynamically from the workspace's commits.
   - `csi-spl-wui/src/components/reporting/ReleasesDailyList.vue:101`: `areaOf` strips `^csi-spl-`.
   - `csi-spl-wui/src/components/ReleaseNotesDialog.vue:266, 273, 294-295`: uses `config.public.appVersion` (`running` badge) and `commitPrefix(config.public.repoWebUrl, config.public.repoCommitPath)` (`commitBase`) from static `/config.json`.
   - `csi-spl-wui/src/plugins/commit-links.client.ts:11-21`: initializes `setCommitLinkBase(config.public.repoWebUrl, config.public.repoCommitPath)` once at app boot from `/config.json` (`env.wui.repo_web_url: https://github.com/csitea/csi-spl` in `csi-spl-cnf/csi-spl/all.env.yaml:1534`). Because a single Firebase Hosting static bundle serves `*.<BASE_DOMAIN>` across all workspaces (`csi-spl-orc/src/bash/run/deploy-wui.func.sh:102-138`), `/config.json` is instance-wide, not per-workspace.

5. **Orc — Ingest, Deploy Record, and Box-Side `workspace-repos.tsv`**
   - Command:
     ```bash
     nl -ba csi-spl-orc/src/bash/run/release-note-ingest.func.sh | sed -n '35,45p;70,96p'
     nl -ba csi-spl-orc/src/bash/run/spl-deploy-record.func.sh | sed -n '34,68p'
     nl -ba csi-spl-orc/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh | sed -n '1,74p'
     ```
   - `release-note-ingest.func.sh:36-37, 73, 94`: runs `git -C "$APP_PATH"` (the `csi-spl` repo) during `.github/workflows/20_hub-build-deploy.yml` and posts to `/v1/operator/release-notes`.
   - `spl-deploy-record.func.sh:34-68` & `hub/operator_deploys.go:169-178`: records only `csi-spl` `hub`/`wui` deploys and probes the hub's `/version` and apex `/build.json`.
   - **What ALREADY exists on the box side (`workspace-repo.inc.sh:1-74` and `lane-issue-and-docs.md` §5):**
     `$SPOOL_ROOT/workspace-repos.tsv` already maps `<workspace> -> <env> <org/repo> <clone> <trunk> <live_url> <desk_agent> <desk_box>` so `do_spl_lane_issue` and `do_spl_issue_close_landed` (`ISSUE_CLOSE_WORKSPACE=<workspace>`) can walk `<clone>`'s git log and close landed `<PREFIX>-<n>` issues in `<workspace>`. However, **the hub database and API know nothing about `workspace-repos.tsv`**: commits from `<clone>` are never ingested into hub Postgres, and the hub API/WUI still serve `t1`'s `release_notes` and `estate_deploys` to every workspace.

---

## 3. Design: Per-Workspace Repository, Ingestion, Secret Custody, and Scoped Reads

### 3.1 Architecture overview

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Workspace Settings / cnf (`workspace_repos` table + `tenants.settings`)    │
│   tenant_id = '<WORKSPACE>'                                                │
│   repo_full_name = '<ORG>/<REPO>' (e.g. 'csitea/<REPO>')                   │
│   repo_web_url   = 'https://github.com/<ORG>/<REPO>'                       │
│   trunk_branch   = 'main' (or 'master')                                    │
│   live_url       = 'https://<LIVE_DOMAIN>'                                 │
│   auth_mode      = 'github_app' | 'pat_kms' | 'public'                     │
└───────────────┬───────────────────────────────────────────┬────────────────┘
                │                                           │
                ▼                                           ▼
┌───────────────────────────────────────────┐ ┌──────────────────────────────┐
│ Ingestion paths into Hub Postgres         │ │ Public / Tenant Config API   │
│  1. Hub background sync / GitHub webhook  │ │  GET /v1/tenant/public       │
│     (via internal/github App or KMS PAT)  │ │  returns workspace's own     │
│  2. Box / CI push (`do_release_note_      │ │  repo_web_url & commit_path  │
│     ingest --workspace <WORKSPACE>`)      │ │  (empty if unconfigured)     │
└───────────────┬───────────────────────────┘ └─────────────┬────────────────┘
                │                                           │
                ▼                                           ▼
┌───────────────────────────────────────────┐ ┌──────────────────────────────┐
│ Workspace-scoped Hub DB tables (RLS)      │ │ WUI & Hub Readers            │
│  - release_notes (tenant_id, sha PK)      │ │  - /reporting/releases       │
│  - estate_deploys (tenant_id, deploy_id)  │ │  - /v1/release-notes         │
│  - commit_token_burn (tenant_id, sha, ..) │ │  - commit-links.client.ts    │
│  - issues / issue_discussions (existing)  │ │  - Issue <-> Commit links    │
└───────────────────────────────────────────┘ └──────────────────────────────┘
```

### 3.2 Where a workspace names its git repository

We evaluate the storage location against [Spec 098 §7 (Promotion triggers from `tenants.settings` JSONB to first-class SQL)](../098-tenant-settings-jsonb/spec.md):

- Spec 098 §7 states that a setting belongs in `tenants.settings` JSONB only while it is read/written as a single-tenant document; **as soon as a background job scans across tenants, or SQL joins/foreign-keys against it, or multiple rows per workspace can exist, it must be a relational table/column**.
- Repository tracking requires:
  1. The hub's background sync / webhook router to look up which workspace(s) own `<ORG>/<REPO>` (`WHERE lower(repo_full_name) = lower($1)`).
  2. Support for either one primary repository per workspace today or multiple repositories (`repo_id`) per workspace in the future without another schema migration.
  3. Reconciling from `csi-spl-cnf` (`workspaces.yaml` / `$SPOOL_ROOT/workspace-repos.tsv`) AND reading/editing from Workspace Settings in the WUI (`PUT /v1/tenant/settings` / `GET /v1/tenant/public`).

#### Relational table: `workspace_repos` (`0262_workspace_repos.sql`)

```sql
CREATE TABLE workspace_repos (
    tenant_id        text        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    repo_slug        text        NOT NULL, -- e.g. 'csitea/<repo>' (lowercase owner/name)
    is_primary       boolean     NOT NULL DEFAULT true,
    provider         text        NOT NULL DEFAULT 'github'
                     CHECK (provider IN ('github', 'gitlab', 'gitea', 'other')),
    repo_web_url     text        NOT NULL, -- e.g. 'https://github.com/csitea/<repo>'
    repo_commit_path text        NOT NULL DEFAULT '/commit/',
    trunk_branch     text        NOT NULL DEFAULT 'main',
    live_url         text        NOT NULL DEFAULT '',
    version_tag_glob text        NOT NULL DEFAULT 'v*',
    area_strip_prefix text       NOT NULL DEFAULT '', -- 'csi-spl-' for t1; '' for other workspaces
    auth_mode        text        NOT NULL DEFAULT 'github_app'
                     CHECK (auth_mode IN ('github_app', 'pat_kms', 'public', 'ingest_only')),
    github_installation_id bigint NULL,
    last_synced_sha  text        NULL,
    last_synced_at   timestamptz NULL,
    sync_status      text        NOT NULL DEFAULT 'pending'
                     CHECK (sync_status IN ('pending', 'ok', 'error', 'disabled')),
    sync_error       text        NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, repo_slug),
    CONSTRAINT workspace_repos_slug_chk CHECK (repo_slug ~ '^[a-z0-9._-]+/[a-z0-9._-]+$')
);

CREATE UNIQUE INDEX workspace_repos_one_primary_idx
    ON workspace_repos (tenant_id) WHERE is_primary;
CREATE INDEX workspace_repos_slug_idx
    ON workspace_repos (repo_slug);

ALTER TABLE workspace_repos ENABLE ROW LEVEL SECURITY;
CREATE POLICY workspace_repos_tenant_scope ON workspace_repos
    USING (
        current_setting('app.rls_scope', true) = 'operator'
        OR tenant_id = current_setting('app.tenant_id', true)
    );
```

- **Default seed for `t1` (`spool-hub`)**: Migration `0262` seeds `('t1', 'csitea/csi-spl', true, 'github', 'https://github.com/csitea/csi-spl', '/commit/', 'master', ..., 'csi-spl-', 'github_app')`.
- **Default for every other workspace (`t2`, `t3`, …)**: **No row until configured** (via `csi-spl-cnf` reconciler, operator CLI, or Workspace Settings UI). Never defaults to `csitea/csi-spl`.
- **Bridge with `$SPOOL_ROOT/workspace-repos.tsv` (`lane-issue-and-docs.md` §5.1)**:
  `do_workspace_repo_register` / `do_workspace_repo_reconcile` updates both `$SPOOL_ROOT/workspace-repos.tsv` on the desk box and `workspace_repos` in the hub API (`PUT /v1/operator/workspaces/{tenant}/repos`), so box-side `do_spl_lane_issue` / `do_spl_issue_close_landed` and hub-side `/reporting/releases` stay in lockstep from one registration command.
- **Public workspace metadata (`GET /v1/tenant/public` and `/v1/me`)**:
  Exposes the primary repo's non-secret display fields (`repo_slug`, `repo_web_url`, `repo_commit_path`, `trunk_branch`, `live_url`) so the WUI sets `setCommitLinkBase(tenant.repo_web_url, tenant.repo_commit_path)` dynamically whenever the active workspace resolves. If the workspace has no primary repo, `setCommitLinkBase('', '')` disables commit-hash linkification in that workspace.

### 3.3 Scoped database schema for `release_notes`, `estate_deploys`, and `commit_token_burn`

#### 3.3.1 `release_notes` becomes workspace-scoped (`0263_release_notes_tenant_scope.sql`)

1. Add `tenant_id text NOT NULL DEFAULT 't1' REFERENCES tenants(id) ON DELETE CASCADE` and `repo_slug text NOT NULL DEFAULT 'csitea/csi-spl'`.
2. Backfill existing `csi-spl` rows to `tenant_id = 't1'`, `repo_slug = 'csitea/csi-spl'`, and `issue_tenant = 't1'`.
3. Replace the single-column primary key `release_notes_pkey (sha)` with `PRIMARY KEY (tenant_id, sha)` (so two workspaces that share a commit or fork history never collide, and every query is index-prefixed by `tenant_id`).
4. Relax `release_notes_version_chk` (`0114_release_note_cycle.sql:23-26`) or allow arbitrary tag strings (`^v?[0-9]+\.[0-9]+.*$` or project-defined tags up to 64 chars) because non-`csi-spl` repositories may use `v1.0.0`, `v0.4.2-beta.1`, or date tags rather than `csi-spl`'s `-c2` cycle suffix, and commits on repositories that do not tag every push have `version IS NULL`.
5. Enable Row-Level Security on `release_notes`:
   ```sql
   ALTER TABLE release_notes ENABLE ROW LEVEL SECURITY;
   CREATE POLICY release_notes_tenant_scope ON release_notes
       USING (
           current_setting('app.rls_scope', true) = 'operator'
           OR tenant_id = current_setting('app.tenant_id', true)
       );
   ```
   This also closes the leak in **Reporting → SQL (`/reporting/sql`)**: an admin in `<WORKSPACE>` running `SELECT * FROM release_notes` under `app.tenant_id = '<WORKSPACE>'` now sees only `<WORKSPACE>`'s commits, never `t1`'s.

#### 3.3.2 `estate_deploys` becomes workspace-scoped (`0264_estate_deploys_tenant_scope.sql`)

1. Add `tenant_id text NOT NULL DEFAULT 't1' REFERENCES tenants(id) ON DELETE CASCADE` and `repo_slug text NOT NULL DEFAULT 'csitea/csi-spl'`.
2. Widen `component` check (`0202_estate_deploys.sql:23`) from `('hub', 'wui', 'inf')` to allow workspace-defined deploy targets (e.g. `^[a-z0-9][a-z0-9_-]{0,31}$`, such as `'web'`, `'site'`, `'api'`, `'app'`, `'hub'`, `'wui'`, `'inf'`).
3. Replace `CREATE POLICY estate_deploys_read ON estate_deploys FOR SELECT TO PUBLIC USING (true)` with tenant-scoped RLS:
   ```sql
   DROP POLICY IF EXISTS estate_deploys_read ON estate_deploys;
   CREATE POLICY estate_deploys_tenant_scope ON estate_deploys
       USING (
           current_setting('app.rls_scope', true) = 'operator'
           OR tenant_id = current_setting('app.tenant_id', true)
       );
   ```

#### 3.3.3 `commit_token_burn` (`SPL-3893`, Spec 143 §8.7) — Owner Decision Q5 (`msg 331b339b`, poll `a98c41db`)

- Add `tenant_id text NOT NULL DEFAULT 't1'` and foreign key `FOREIGN KEY (tenant_id, sha) REFERENCES release_notes (tenant_id, sha) ON DELETE CASCADE`.
- The slicer attributes a lane's token and currency burn to `( lane.workspace_tenant_id, commit.sha )`, so work run on `<WORKSPACE>`'s repo lands under `<WORKSPACE>`.
- **Visibility & RLS (Decided in Q5, `HUM-10` msg `331b339b`, 2026-11-04T21:53:42Z, poll `a98c41db` — *"C — Every signed-in member of the workspace"*):**
  - Instead of Spec 143 §8.7's operator-only RLS policy (`current_setting('app.rls_scope', true) = 'operator'`), `commit_token_burn` uses the tenant-scoped RLS policy so every signed-in member of `<WORKSPACE>` can read `<WORKSPACE>`'s per-commit token and EUR cost:
    ```sql
    ALTER TABLE commit_token_burn ENABLE ROW LEVEL SECURITY;
    CREATE POLICY commit_token_burn_tenant_scope ON commit_token_burn
        USING (
            current_setting('app.rls_scope', true) = 'operator'
            OR tenant_id = current_setting('app.tenant_id', true)
        );
    ```
  - `GET /v1/reporting/releases/daily` and `GET /v1/reporting/releases/commits` return the AI token count and EUR cost per commit and per Kind/Area pill to **every signed-in human member of the workspace** (no operator-only or `costs.read` gate on `/reporting/releases`).

### 3.4 Ingestion & GitHub Authentication / Secret Custody

#### 3.4.1 How the hub ingests a workspace's commits, tags, and releases — Owner Decision Q2 (`msg bbad7ba3`, poll `0636da66`)

Per owner decision Q2 (`HUM-10` msg `bbad7ba3`, 2026-11-04T21:54:13Z, poll `0636da66` — *"A — Recommended: both: the hub polls the repo on GitHub every 5 min (plus webhook and a \"Sync now\" button), and a box can push them too"*), we support **both complementary paths writing to the same idempotent store `PutReleaseNotes(ctx, tenantID, repoSlug, notes)`**:

1. **Hub-native GitHub sync (primary — zero CI setup required in the target repo)**:
   - The hub already has a pure-Go GitHub REST client in `csi-spl-api/src/go/spool-hub-api/internal/github/{client.go,jwt.go,repo.go,commits.go}` that authenticates as the fleet GitHub App (`SPOOL_GITHUB_APP_ID` / `SPOOL_GITHUB_INSTALLATION_ID` / `SPOOL_GITHUB_APP_KEY`).
   - We extend `internal/github` with:
     - `ListCommits(ctx, owner, repo, branch, sinceSHA)` (`GET /repos/{owner}/{repo}/commits`)
     - `ListTags(ctx, owner, repo)` (`GET /repos/{owner}/{repo}/tags`) and `ListReleases(ctx, owner, repo)` (`GET /repos/{owner}/{repo}/releases`)
   - **Trigger**:
     - **Background reconciler loop** in `spool-hub-api` (every 5 minutes, plus an immediate "Sync now" button/API for workspace admins) walks all active `workspace_repos` rows (`auth_mode IN ('github_app', 'pat_kms', 'public')`), fetches new commits on `trunk_branch` since `last_synced_sha` (or the initial backfill window, up to 2,000 commits), maps tag/release SHAs to `version` and `released_at`, parses conventional-commit `kind(area): subject`, optional `Lay-*`/`Tech-*` trailers, and `<PREFIX>-<n>` issue keys, and upserts into `release_notes` with `tenant_id = workspace.tenant_id`.
     - **Optional GitHub App webhook (`POST /v1/webhooks/github`)**: verifies `X-Hub-Signature-256` against the webhook secret in Secret Manager and triggers an immediate delta sync for the matching `workspace_repos.repo_slug` on `push` and `release` events.
2. **Box / CI push (`POST /v1/operator/release-notes?tenant=<WORKSPACE>&repo=<ORG>/<REPO>`)**:
   - `csi-spl-orc/src/bash/run/release-note-ingest.func.sh` gains `RELEASE_NOTE_TENANT` (default `t1`) and `RELEASE_NOTE_REPO_PATH` (default `$APP_PATH`, or the `<clone>` column from `$SPOOL_ROOT/workspace-repos.tsv`).
   - Desk cron (`do_spl_issue_close_landed` in `workspace-repo.inc.sh`) already runs `git -C "$clone" fetch --quiet origin "$trunk"` on the desk box for every row in `$SPOOL_ROOT/workspace-repos.tsv`; chaining `do_release_note_ingest` for each workspace repo ingests the full git log directly from the local clone as an immediate fallback even before any GitHub API change.

#### 3.4.2 How GitHub credentials are held (Secret Manager & KMS envelope per Spec 127 / Spec 159 — never in git) — Owner Decision Q3 (`msg d5b1366a`, poll `c21fd9b7`)

Per owner decision Q3 (`HUM-10` msg `d5b1366a`, 2026-11-04T21:54:03Z, poll `c21fd9b7` — *"A — Recommended: the existing fleet GitHub App for csitea repos (no new secret), plus an optional read-only token per workspace, encrypted with Cloud KMS, for repos in other GitHub orgs"*):

- **Case 1 — Repository in the `csitea` GitHub organization (e.g. `csitea/<REPO>`)**:
  - The hub's existing GitHub App (`SPOOL_GITHUB_APP_ID`, `SPOOL_GITHUB_INSTALLATION_ID`, private key held in GCP Secret Manager `spool-hub-github-app-key` mounted via `csi-spl-iac/src/terraform/030-cloud-run-hub/07-github-app-key.tf`) already belongs to the `csitea` org.
  - Granting that GitHub App installation read access (`Contents: Read-only`, `Metadata: Read-only`) to `csitea/<REPO>` requires **zero new secrets** — `workspace_repos.auth_mode = 'github_app'` works out of the box.
- **Case 2 — External customer GitHub organization or repository**:
  - **Option 2A (GitHub App installation)**: The external org installs the Spool GitHub App on `<ORG>/<REPO>` and records `github_installation_id` on `workspace_repos`. The hub mints installation tokens using its existing `spool-hub-github-app-key` in GCP Secret Manager.
  - **Option 2B (Per-workspace fine-grained GitHub PAT with KMS envelope encryption)**: If a workspace prefers a fine-grained read-only PAT (`Contents: Read`), it is stored in `tenant_vendor_keys` (or `workspace_repo_secrets`) sealed with GCP Cloud KMS (`057-gcp-kms-vendor-keys`, Spec 127 / Spec 159 `internal/kms`) with AAD `<tenant_id>|github|<repo_slug>`, **never** in git, `csi-spl-cnf`, or plaintext Postgres.

### 3.5 Hub API & WUI Reader Changes

1. **`GET /v1/reporting/releases/daily` and `GET /v1/reporting/releases/commits` (`hub/reporting_releases.go`)**:
   - `releaseReportReader` captures `tenant, hum, ok := s.humanTenant(w, r)` and passes `tenant` into `rr.ReleaseDaily(r.Context(), tenant, f)` and `rr.ReleaseCommits(r.Context(), tenant, f)`.
   - `store/reporting_releases.go` runs inside `s.withTenant(ctx, tenant, ...)` and filters `WHERE tenant_id = $1`.
   - The response top-level JSON adds:
     ```json
     "repo": {
       "configured": true,
       "repo_slug": "<org>/<repo>",
       "repo_web_url": "https://github.com/<org>/<repo>",
       "repo_commit_path": "/commit/",
       "trunk_branch": "main",
       "live_url": "https://<live_domain>",
       "last_synced_at": "2026-11-04T17:00:00Z"
     },
     "available_areas": ["web", "api", "cms", "db"],
     "available_kinds": ["feat", "fix", "docs", "chore"]
     ```
   - When `repo.configured == false` (no `workspace_repos` row for `tenant`), the endpoint returns `200 OK` with `repo.configured: false`, `days: []`, `totals: { releases_count: 0, commits_count: 0, ... }`, and the WUI renders an explicit empty-state card (*"No git repository is connected to `<WORKSPACE>` yet"*).
2. **`GET /v1/release-notes` and `GET /v1/release-notes/{ref}` (`hub/release_notes.go`)**:
   - `releaseReader` returns `(rs, tenant, ok)` from `s.webCalendarTenant(r)` or `s.humanTenant(w, r)` and passes `tenant` to `ListReleaseNotes(ctx, tenant, q)`, `ReleaseNotesOfVersion(ctx, tenant, version)`, and `ReleaseNote(ctx, tenant, sha)`.
3. **WUI Reporting → Releases & Release Notes (`csi-spl-wui`)**:
   - `ReleasesFilterBar.vue` and `reporting-releases.ts`: replace the hardcoded `RELEASE_AREAS = ['orc', 'api', 'wui', 'iac', 'cnf', 'doc', 'rdb']` with the dynamic `available_areas` returned by `/v1/reporting/releases/daily` (falling back to the distinct `area` values present in `days[].by_area`).
   - `ReleasesDailyList.vue` and `ReleaseNotesDialog.vue`: build commit links from the workspace's `repo.repo_web_url + repo.repo_commit_path` rather than static `/config.json`.
   - `commit-links.client.ts`: watches the active workspace profile (`GET /v1/tenant/public` / `/v1/me`) and calls `setCommitLinkBase(workspaceRepoWebUrl, workspaceRepoCommitPath)`. For `t1`, that is `https://github.com/csitea/csi-spl` + `/commit/`; for `<WORKSPACE>`, that is `https://github.com/<ORG>/<REPO>` + `/commit/`; for an unconfigured workspace, it is `''` (no false links to `csi-spl`).

---

## 4. "The Analysis For It" — Commit & Release Analysis Per Workspace

In the `spool-hub` workspace (`t1`), commit history powers six distinct analysis layers. Here is how each works in `t1` today and how it carries over to every workspace `<WORKSPACE>` against `<ORG>/<REPO>`:

| # | Analysis capability in `t1` (`spool-hub`) today | Code & Spec today | How it works for `<WORKSPACE>`'s own repo (`<ORG>/<REPO>`) |
|---|---|---|---|
| **1** | **Velocity KPIs & Daily Activity Timeline** (`Releases`, `Commits`, `Commits / day`, `Deploys dev / prd`, per-day commit stream, version grouping) | Spec 143 §2.2, `store/reporting_releases.go:211-271`, `ReportingReleasesSummary.vue`, `ReleasesDailyList.vue` | Computed strictly over `release_notes WHERE tenant_id = '<WORKSPACE>'` and `estate_deploys WHERE tenant_id = '<WORKSPACE>'`. Commits without a version tag group under `unreleased` / their date bucket; when the repo uses git tags or GitHub Releases, `version` and `released_at` populate automatically. |
| **2** | **Conventional-commit `Kind` & `Area` Label Clouds** (`feat`, `fix`, `docs`, `chore`, `perf`, `refactor`, `ci`, `test` + scope pills with counts and multi-select filtering) | Spec 143 §2.2.1 (`SPL-3796`), `ReleasesFilterBar.vue:23-81`, `store/reporting_releases.go:64-93` | **Decided (Q4, `msg ab74f79d`, poll `9d1a183a`) — carries over per workspace with dynamic Area discovery**: the parser extracts `kind(area): subject` from each commit subject; if a commit has no `(area)` in its subject, the ingester derives `area` from the top-level directory of changed files (e.g. `web`, `src`, `supabase`, `docs`) and strips `workspace_repos.area_strip_prefix` (only `'csi-spl-'` in `t1`). The WUI renders the workspace's own top areas instead of hardcoded `orc/api/wui/...`. |
| **3** | **Lay / Tech Structured Release Notes** (`Lay-What/How/Why`, `Tech-What/How/Why` trailers, completeness `state` badge: `complete`, `partial`, `missing`, `revert`, `merge`) | Spec 065, `0108_release_note.sql`, `release-note-ingest.func.sh` | **Decided (Q4, `msg ab74f79d`, poll `9d1a183a`) — carries over cleanly**: commits created by fleet agents in `<WORKSPACE>` (per `lane-issue-and-docs.md` §5) can include `Lay-*` / `Tech-*` trailers; commits without those trailers show their commit subject and body summary cleanly without error. |
| **4** | **Bidirectional Commit ↔ Issue ↔ Discussion Links** (`SPL-4789`: commit row shows linked `<PREFIX>-<n>` issue chip + discussion thread link; issue drawer and discussion header list every commit that cites `<PREFIX>-<n>`) | `SPL-4789` (`origin/review/c-944-commit-links`, `8f1834b21..12f302fd9`), `0261_release_note_issue_keys.sql`, `commit-links.md` | **Carries over per workspace**: when ingesting commits for `<WORKSPACE>`, the ingester looks up `<WORKSPACE>`'s `tenants.issue_key_prefix` (e.g. `<PREFIX>`, or any `<PREFIX>-<n>` cited in the commit subject/body), sets `release_notes.tenant_id = '<WORKSPACE>'` and `release_notes.issue_tenant = '<WORKSPACE>'`, and populates `issue_keys`. Clicking an issue chip on `/reporting/releases` in `<WORKSPACE>` opens `<WORKSPACE>`'s own issue `<PREFIX>-<n>` and its linked `#development` discussion thread. |
| **5** | **Automated Issue Closure on Commit Landing & Spec 170 To-Do Deadlines** (`do_spl_issue_close_landed` scans trunk commits for `<PREFIX>-<n>` and transitions open `wip` issues to `done`, clearing them from active To-Do reminders) | `workspace-repo.inc.sh:1-74`, `issue-close-landed.func.sh`, [Spec 170](../170-day-tasks-reminder/spec.md) | **Already works on box clones via `workspace-repos.tsv` (`SPL-3528`/`SPL-3794`) and now unifies with the hub**: when the hub syncs new trunk commits for `<WORKSPACE>`, it can both insert `release_notes` rows (linking the closing commit SHA to `<PREFIX>-<n>`) and transition `<PREFIX>-<n>` to `done` with the landing commit SHA recorded on the issue closure event. |
| **6** | **Per-Commit & Per-Label Token and Currency Cost Attribution** (`SPL-3893`, Spec 143 §8: `commit_token_burn` attributes agent lane token burn and EUR cost across commits and displays `tokens · €cost` on each Kind/Area pill and commit row) | Spec 143 §8 (`spec.md:835-963`), `SPL-3893` | **Decided (Q5, `msg 331b339b`, poll `a98c41db`) — carries over per workspace and visible to every signed-in member of `<WORKSPACE>`**: when an agent lane runs with `Workspace: <WORKSPACE>` (targeting `<ORG>/<REPO>` and issue `<PREFIX>-<n>`), `do_commit_token_burn_slice` joins `usage_events` for that lane's `agent_id` and time window to the commits landed in `release_notes WHERE tenant_id = '<WORKSPACE>'` citing `<PREFIX>-<n>`, and every signed-in workspace member sees the AI token and EUR cost per commit and per Kind/Area pill on `/reporting/releases`. |
| **7** | **Live Deploy Tracking & Drift Reconciliation** (`estate_deploys`: dev/prd deploy counts and live version probe) | Spec 143 §2.2, `0202_estate_deploys.sql`, `hub/operator_deploys.go` | **Carries over per workspace**: `<WORKSPACE>` records deploys via `POST /v1/operator/deploys?tenant=<WORKSPACE>` (from its deploy script/workflow) or via periodic probe of `workspace_repos.live_url` (e.g. `/build.json` or `/version` when present). If `<WORKSPACE>` does not emit deploy events yet, the Deploys KPI card shows `0` (or `—`) for `<WORKSPACE>`, never `csi-spl`'s `hub`/`wui` deploy counts. |

---

## 5. Owner Decisions & Open Questions (A/B/C Options)

On 2026-11-04 (`HUM-10`, topic `f38888e7-27eb-4aad-b2fe-1736ffbb2f0e`), the owner answered **Q2, Q3, Q4, and Q5**. **Q1** (poll in msg `4b5869d5`) remains open.

### Q1 — Repository cardinality per workspace (`workspace_repos`) — **OPEN (poll in msg `4b5869d5`, awaiting owner answer)**
- **A (Recommended):** Allow multiple repos in the schema (`PRIMARY KEY (tenant_id, repo_slug)` with one `is_primary = true`), UI/Reporting defaults to the primary repo with an optional repo switcher when `count > 1`.
- **B:** Strictly one git repository per workspace (`PRIMARY KEY (tenant_id)` on `workspace_repos`).
- **C:** Store a single `repo_url` string inside `tenants.settings` JSONB with no relational table.

### Q2 — How the hub ingests a workspace's git commits and tags — **DECIDED: A (`HUM-10` msg `bbad7ba3`, 2026-11-04T21:54:13Z, poll `0636da66`)**
- **Decision verbatim:** *"A — Recommended: both: the hub polls the repo on GitHub every 5 min (plus webhook and a \"Sync now\" button), and a box can push them too"*
- **A (Selected):** Both: the hub's GitHub App client (`internal/github`) polls `<ORG>/<REPO>` every 5 min (plus optional GitHub webhook + manual "Sync now"), AND box-side `do_release_note_ingest --workspace <WORKSPACE>` can push from the local clone in `workspace-repos.tsv`.
- **B:** Hub-side GitHub API polling + webhook only (no box-side git clone ingest).
- **C:** Box-side cron (`workspace-repos.tsv` local clone + `do_release_note_ingest`) only.

### Q3 — How private workspace repositories authenticate with GitHub — **DECIDED: A (`HUM-10` msg `d5b1366a`, 2026-11-04T21:54:03Z, poll `c21fd9b7`)**
- **Decision verbatim:** *"A — Recommended: the existing fleet GitHub App for csitea repos (no new secret), plus an optional read-only token per workspace, encrypted with Cloud KMS, for repos in other GitHub orgs"*
- **A (Selected):** Use the existing fleet GitHub App (`spool-hub-github-app-key` in GCP Secret Manager) for orgs where the App is installed (such as `csitea/*`), plus optional per-workspace fine-grained PAT encrypted with GCP Cloud KMS (`057-gcp-kms-vendor-keys`) for external orgs.
- **B:** GitHub App installations only (every workspace repo must install the Spool GitHub App).
- **C:** Per-workspace PAT in GCP KMS / Secret Manager for every workspace repo.

### Q4 — How `Area` pills and commits without `Lay-*` / `Tech-*` trailers behave in workspace repos — **DECIDED: A (`HUM-10` msg `ab74f79d`, 2026-11-04T21:53:53Z, poll `9d1a183a`)**
- **Decision verbatim:** *"A — Recommended: Area from the commit scope kind(area):, else the top folder changed; commits without trailers show their subject and body"*
- **A (Selected):** Derive `Area` dynamically from the commit's conventional scope `kind(area):` (falling back to the top-level changed directory when scope is omitted), and render commits without `Lay-*`/`Tech-*` trailers cleanly using their commit subject and body.
- **B:** Derive `Area` only from explicit `kind(area):` conventional scopes (leave `area` empty if omitted) and show subject/body when trailers are absent.
- **C:** Require `Lay-*`/`Tech-*` trailers on all workspace repos and flag non-trailer commits as incomplete warnings.

### Q5 — Visibility of per-commit / per-label AI token & EUR cost attribution (`SPL-3893`) on `/reporting/releases` — **DECIDED: C (`HUM-10` msg `331b339b`, 2026-11-04T21:53:42Z, poll `a98c41db`)**
- **Decision verbatim:** *"C — Every signed-in member of the workspace"* (overrides initial recommendation A: AI token and EUR cost per commit is visible to every signed-in member of the workspace).
- **A (Initial recommendation, not selected):** Show token burn and EUR cost on `/reporting/releases` to operators (`t1` staff) and to workspace owners/admins who hold `costs.read` in `<WORKSPACE>`, hidden from regular workspace members.
- **B:** Operator-only (`t1` staff) in all workspaces, matching Spec 143 §8's initial operator gate.
- **C (Selected):** Visible to all signed-in human members of `<WORKSPACE>` who can open `/reporting/releases`.

---

## 6. Phased Implementation Plan (Q2..Q5 Decided; Q1 `4b5869d5` Open)

Q2..Q5 are decided (`bbad7ba3`, `d5b1366a`, `ab74f79d`, `331b339b`); only Q1 (`4b5869d5`, repos per workspace cardinality on `workspace_repos`) remains open. Once Q1 is answered, the work splits into five small, file-disjoint lanes:

| Phase | Scope | Files touched | Verification |
|---|---|---|---|
| **Lane 1 — RDB migrations (`0262`–`0264`)** | Create `workspace_repos` (cardinality per Q1); add `tenant_id` + `repo_slug` + tenant RLS to `release_notes`, `estate_deploys`, and `commit_token_burn` (readable by every signed-in member of the workspace per Q5 `331b339b`); relax `release_notes.version` check for standard semver/tags; seed `t1 -> csitea/csi-spl`. | `csi-spl-rdb/src/sql/postgres/spool-hub/0262_workspace_repos.sql`, `0263_release_notes_tenant_scope.sql`, `0264_estate_deploys_tenant_scope.sql` | Migration apply + pgTAP / Go store tests verifying tenant isolation (`t2` sees 0 rows of `t1`'s `release_notes` and `estate_deploys`, including via `/reporting/sql`, and every signed-in `t2` member reads `t2`'s `commit_token_burn`). |
| **Lane 2 — Hub Store & API scoping + Workspace Repo API** | Thread `tenant` into `ReleaseReportStore`, `ReleaseNoteStore`, and `OperatorDeployStore`; return `repo` metadata + dynamic `available_areas` (Q4 `ab74f79d`) + per-commit/per-pill AI token & EUR cost to every signed-in workspace member (Q5 `331b339b`); expose `repo_web_url` and `repo_commit_path` on `/v1/tenant/public`; add operator/admin workspace repo registration + KMS-encrypted PAT storage (Q3 `d5b1366a`). | `csi-spl-api/src/go/spool-hub-api/internal/store/{reporting_releases.go,release_note_postgres.go,operator_deploys.go}`, `internal/hub/{reporting_releases.go,release_notes.go,tenant_settings.go}` | `go test ./internal/store/... ./internal/hub/...` covering `t1` (`csitea/csi-spl`), a configured workspace (`<ORG>/<REPO>`), an unconfigured workspace (`configured: false`, 0 rows), and member-visible commit cost figures. |
| **Lane 3 — Hub GitHub Sync & Box Ingest (`do_release_note_ingest`)** | Extend `internal/github` (fleet GitHub App for `csitea/*` + KMS PAT for external orgs per Q3 `d5b1366a`) + 5-min background sync worker + webhook + "Sync now" button AND box-side `--workspace <WORKSPACE>` push in `release-note-ingest.func.sh` / `workspace-repo.inc.sh` (per Q2 `bbad7ba3`); derive `Area` from `kind(area):` else top changed folder, and ingest trailer-free commits cleanly with subject + body (per Q4 `ab74f79d`). | `csi-spl-api/src/go/spool-hub-api/internal/github/...`, `csi-spl-orc/src/bash/run/release-note-ingest.func.sh`, `csi-spl-orc/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh` | Unit + integration test ingesting a non-`t1` workspace repo and verifying `release_notes.tenant_id`, `issue_tenant`, `issue_keys`, dynamic `area` fallback from top folder, and trailer-free subject/body display. |
| **Lane 4 — WUI dynamic areas, workspace commit links, member-visible commit cost, and unconfigured empty state** | Replace hardcoded `RELEASE_AREAS` with `available_areas` from the API; render trailer-free commits with subject + body (Q4 `ab74f79d`); show per-commit and per-pill AI token & EUR cost to every signed-in workspace member (Q5 `331b339b`); bind `ReleaseNotesDialog.vue`, `ReleasesDailyList.vue`, and `commit-links.client.ts` to the active workspace's `repo_web_url`; render the unconfigured-repo empty state. | `csi-spl-wui/src/utils/reporting-releases.ts`, `src/components/reporting/{ReleasesFilterBar.vue,ReleasesDailyList.vue}`, `src/pages/reporting/releases.vue`, `src/components/ReleaseNotesDialog.vue`, `src/plugins/commit-links.client.ts` | Vitest unit tests + Playwright check on a non-`t1` workspace. |
| **Lane 5 — Onboard the first two production workspaces** | Register the two customer/product workspace repositories in `workspace_repos` and `workspace-repos.tsv`, run initial commit + tag backfill, and verify `/reporting/releases`, commit links, and `<PREFIX>-<n>` issue links live on both workspaces. | Ops / `workspace-repos.tsv` / hub operator API | Live curl + browser verification on both workspaces showing their own commits, tags, areas, and issue links with zero `csi-spl` rows. |
