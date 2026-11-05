# Spec 171: Per-Workspace Git Repository for Reporting, Commits, Release Notes, and Commit Analysis

- **Status:** Draft — Q2..Q5 decided by owner (`HUM-10`, 2026-11-04, topic `f38888e7-27eb-4aad-b2fe-1736ffbb2f0e`); Q1 (`4b5869d5`, repos per workspace) awaiting owner answer
- **Date:** 2026-11-04
- **Track:** `SPL-4808` (epic `SPL-2400`)
- **Depends on:**
  - [Spec 065 — Release Notes Table (`release_notes`)](../065-release-notes-table/spec.md)
  - [Spec 098 — Tenant Settings JSONB (`tenants.settings`)](../098-tenant-settings-jsonb/spec.md)
  - [Spec 127 — Workspace Vendor Keys (`workspace_vendor_keys`)](../127-workspace-vendor-keys/spec.md)
  - [Spec 143 — Reporting Section (`/reporting/*`)](../143-reporting-section/spec.md)
  - [Spec 159 — Per-Workspace BYO AI Keys & KMS Envelope](../159-byo-ai-keys/spec.md)
  - [Spec 170 — Day-Tasks Reminder & To-Do View](../170-day-tasks-reminder/spec.md)
  - [Lane Issue & Docs Guide §5 — A lane in a workspace's own repo](../../doc/md/lane-issue-and-docs.md)
  - `SPL-4789` — Bidirectional Commit ↔ Issue ↔ Discussion Links (landed on `origin/master` in `8f1834b21..b4e38052a`, `0261_release_note_issue_keys.sql`)

---

## 1. The Owner's Words & Problem Statement

On 2026-11-04 (`HUM-10`, messages `5bb423dd`, `0fcabe44`, `76ce11aa`, `19402a08`, `d0f66e74`, `ecd8f77e`, `f211b11a`, `2a7e391e`), the owner opened `/reporting/releases` inside a non-`spool-hub` product workspace (`https://<WORKSPACE>.<BASE_DOMAIN>/bg/reporting/releases`) and attached screenshot `98a12d45392b60cdddcf2e9b5263c849835f50fb2c8753fe1c5ed8ebc396775f`:

> - `5bb423dd` (10:33:52Z): *"we need to figure out how-to implement the tracking of the releases and the commits of the software projects , such as `https://<LIVE_DOMAIN>/` in an workspace different than the spool-hub workspace"*
> - `0fcabe44` (10:34:49Z): *"that is the in the non-spool-hub workspace the reports and commits should show the commits of the workspace project and not the spool-hub"*
> - `76ce11aa` (10:35:57Z): *"should show the commits of this one `https://github.com/csitea/<REPO>`"*
> - `19402a08` (10:36:09Z): *"and the analysis for it"*
> - `d0f66e74` (10:36:24Z): *"becuase IT IS the sole reason this workspace exists"*
> - `ecd8f77e` (10:35:11Z): *"this one"* + screenshot `98a12d45392b60cdddcf2e9b5263c849835f50fb2c8753fe1c5ed8ebc396775f`
> - `f211b11a` (10:36:48Z): *"check the following discussion `https://<WORKSPACE>.<BASE_DOMAIN>/bg/channel/development?topic=f38888e7-27eb-4aad-b2fe-1736ffbb2f0e`"*
> - `2a7e391e` (10:37:29Z): *"we need to create the respective setup for this workspace for the `https://github.com/csitea/<REPO_2>/commits/master/` project"*

### Core invariant

1. **The `spool-hub` workspace (`t1`, slug `system`)** tracks the `csitea/csi-spl` repository (`spool-hub` itself).
2. **Every other workspace `<WORKSPACE>` on a `spool-hub` instance** tracks **its own configured git repository** (`<ORG>/<REPO>`), never `csitea/csi-spl`.
3. If a non-`t1` workspace has **no repository configured yet**, Reporting → Releases, Release Notes, Flow release lines, and commit-hash linkification MUST show an explicit *"No git repository is connected to `<WORKSPACE>` yet"* empty state (and leave raw hex tokens unlinked) rather than falling back to `csitea/csi-spl` commits or deploys.

---

## 2. What a Non-`spool-hub` Workspace Shows Today (Measured on `origin/master`)

Every statement below was verified against `origin/master` at `e696477ab` (where `SPL-4789` `0261_release_note_issue_keys.sql` is landed).

### 2.1 Summary matrix of surfaces

| Surface | URL / Component | What `<WORKSPACE>` shows today | Why (exact table & code) |
|---|---|---|---|
| **Reporting → Releases** | `/reporting/releases` (`csi-spl-wui/src/pages/reporting/releases.vue`) | `csi-spl` releases (`168` in screenshot `98a12d45…`), `csi-spl` commits (`724` in screenshot `98a12d45…`), `csi-spl` `dev`/`prd` deploys (`204`/`204` in screenshot `98a12d45…`), `csi-spl` sub-project area pills (`orc`, `api`, `wui`, `iac`, `cnf`, `doc`, `rdb`), and `github.com/csitea/csi-spl/commit/<sha>` links | `release_notes` (`0108_release_note.sql:14-17`) and `estate_deploys` (`0202_estate_deploys.sql:11-14`) have **no `tenant_id` column** and no tenant RLS (`estate_deploys` has `USING (true)` at `0202_estate_deploys.sql:42-43`). `hub/reporting_releases.go:47` discards the caller's tenant (`_, hum, ok := s.humanTenant(w, r)`). `reporting-releases.ts:48` hardcodes `RELEASE_AREAS = ['orc','api','wui','iac','cnf','doc','rdb']`. |
| **Release Notes modal & page** | `ReleaseNotesDialog.vue`, `/releases/<ref>` (`csi-spl-wui/src/pages/releases/[ref].vue`) | `csi-spl` versions (`v8.2.6-c3`, …) and `csi-spl` commit notes (`Lay-*` / `Tech-*`) | `hub/release_notes.go:186-207` (`releaseReader`) validates that the workspace exists and then discards the tenant ID, querying global `release_notes` (`store/release_note_postgres.go:12-14, 105-190`). |
| **Flow → release lines and badge** | `csi-spl-wui/src/components/FlowList.vue`, `csi-spl-wui/src/utils/flow-fold.mjs:72` | `csi-spl` versions as release lines (`f:rel:<version>`), counted unread in the Flow badge | `store/flow_fold.go:352-357` (`flowReleasesSQL`) and `store/flow_postgres.go:264-266` read global `release_notes` with no tenant filter inside `queryTenant` (`store/flow_fold.go:392`). |
| **Commit hash linkification in messages, notes, and issue bodies** | `commit-links.client.ts`, `utils/commit-links.ts` | Any 7..40-char hex token in `<WORKSPACE>` chat or docs links to `https://github.com/csitea/csi-spl/commit/<sha>` | `commit-links.client.ts:12-22` reads `pub.repoWebUrl` and `pub.repoCommitPath` from static `/config.json` and binds `setCommitLinkProvider(() => linker.value)` with `m.commitLinker(webUrl, commitPath)`, which `csi-spl-cnf/csi-spl/all.env.yaml:1546-1548` pins instance-wide to `https://github.com/csitea/csi-spl` and `/commit/`. |
| **Commit ↔ Issue ↔ Discussion links (`SPL-4789`)** | `0261_release_note_issue_keys.sql`, `hub/issues.go` (on `origin/master`) | `release_notes` remains one global table; `env.hub.commit_issue_tenant: t1` (`all.env.yaml:722`) stamps every ingested commit with `issue_tenant = 't1'` | `8f1834b21` adds `issue_tenant` + `issue_keys` to global `release_notes` (`0261_release_note_issue_keys.sql:25-29`), and `cb1b13f3c` sets `commit_issue_tenant: t1` in `all.env.yaml:722`. |
| **Reporting → SQL** | `/reporting/sql` (`hub/reporting_sql.go`, `store/reporting_sql.go`) | Workspace tables (`issues`, `threads`, `messages`, `usage_events`, …) are RLS-isolated to `<WORKSPACE>`; `release_notes` and `estate_deploys` have no `tenant_id` column (`0108_release_note.sql:14-15`, `0202_estate_deploys.sql:11`), so `pgReportingSQLRelations` (`store/reporting_sql.go:68-75`) excludes them from workspace SQL queries | `store/reporting_sql.go:51-52, 68-75` sets `app.tenant_id = <workspace>` and `app.rls_scope = ''`, and requires `relrowsecurity AND relforcerowsecurity` plus a `tenant_id` column on every relation read in `/reporting/sql`. |
| **Reporting → Costs / Marketing / Incomes / Finance** | `/reporting/{costs,marketing,incomes,finance}` | Workspace-scoped (`t.ID` passed into store queries, plus role/owner gates) | `hub/cost_read.go:141-175` (`GET /v1/tenant/costs`), `hub/cost_cloud_days.go:12-35` (`GET /v1/tenant/costs/cloud`), `hub/reporting_marketing.go:52-55`, `hub/reporting_incomes.go:40-45`, and `hub/netvisor.go:73-75, 118-130` (`GET /v1/view/netvisor/{forecast,card-costs}`) scope reads to `t.ID`. |
| **Reporting → Issues / Posts / Lanes** | `/reporting/{issues,posts,lanes}` | Placeholder cards (`ready: false` in `reporting-tabs.mjs:39-42`) | `csi-spl-wui/src/utils/reporting-tabs.mjs:39-42` and `csi-spl-wui/src/pages/reporting/{issues,posts,lanes}.vue`. |

### 2.2 Exact database tables & columns that pin commits and releases to `csi-spl`

1. **`release_notes` (`csi-spl-rdb/src/sql/postgres/spool-hub/0108_release_note.sql:14-17, 24-41`)**
   - Command:
     ```bash
     nl -ba csi-spl-rdb/src/sql/postgres/spool-hub/0108_release_note.sql | sed -n '12,42p'
     ```
   - Lines `14-17`:
     ```sql
     -- Estate-wide, NOT per tenant: every tenant runs the same code, so the table
     -- has no tenant_id and no row security, like rbac_permissions (0021). It holds
     -- no personal data; the ingest runs the distribution-hygiene filter on the
     -- trailer text before a row is written (spec 3, option C).
     ```
   - Columns (`0108_release_note.sql:24-41`, altered by `0114_release_note_cycle.sql:16-27` and `0177_flow_v2.sql:31-34`):
     - `sha text PRIMARY KEY CHECK (sha ~ '^[0-9a-f]{40}$')` (not scoped by `tenant_id` or `repo`)
     - `version text NULL` (constraint `release_notes_version_check` at `0114_release_note_cycle.sql:16-18`: `CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$')`, indexed by `release_notes_release_key` at `0114_release_note_cycle.sql:23-27`)
     - `committed_at timestamptz NOT NULL`
     - `released_at timestamptz NULL` (added in `0177_flow_v2.sql:31`)
     - `kind text NOT NULL DEFAULT ''`
     - `area text NOT NULL DEFAULT ''`
     - `subject text NOT NULL`
     - `lay_what`, `lay_how`, `lay_why`, `tech_what`, `tech_how`, `tech_why` (`text NOT NULL DEFAULT ''`)
     - `state text NOT NULL CHECK (state IN ('ok', 'missing', 'skip', 'revert', 'backfill'))` (`0108_release_note.sql:37`)
     - `reverts text NULL`
     - `link text NOT NULL DEFAULT ''`
     - `ingested_at timestamptz NOT NULL DEFAULT now()`
   - On `origin/master` (`8f1834b21`, `0261_release_note_issue_keys.sql:25-29`), two columns are added to `release_notes`: `issue_tenant text NULL CHECK (length(issue_tenant) BETWEEN 1 AND 64)` and `issue_keys text[] NOT NULL DEFAULT '{}'`, still on the single global `release_notes` table.

2. **`estate_deploys` (`csi-spl-rdb/src/sql/postgres/spool-hub/0202_estate_deploys.sql:11-14, 20-47`)**
   - Command:
     ```bash
     nl -ba csi-spl-rdb/src/sql/postgres/spool-hub/0202_estate_deploys.sql | sed -n '10,48p'
     ```
   - Lines `11-14` & `39-47`:
     ```sql
     -- Estate-wide, like release_notes: no tenant_id. Every scope may READ (the
     -- Releases tab shows the deploy stamps to every member); only the operator
     -- scope writes (the hub's operator route and its reconcile check). No
     -- personal data: ids, versions, shas and a workflow actor name.
     ...
     ALTER TABLE estate_deploys ENABLE ROW LEVEL SECURITY;
     ALTER TABLE estate_deploys FORCE ROW LEVEL SECURITY;

     CREATE POLICY estate_deploys_read ON estate_deploys
         FOR SELECT TO PUBLIC USING (true);

     CREATE POLICY operator_scope ON estate_deploys
         USING (current_setting('app.rls_scope', true) = 'operator')
         WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
     ```
   - Columns (`0202_estate_deploys.sql:20-31`): `deploy_id text PRIMARY KEY` (UUID CHECK), `env text NOT NULL` (`dev | prd`), `component text NOT NULL` (`hub | wui | inf`), `version text NOT NULL` (`CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$')`), `commit_sha text NOT NULL`, `deployed_at timestamptz NOT NULL DEFAULT now()`, `status text NOT NULL` (`success | failed`), `source text NOT NULL DEFAULT 'ci'` (`ci | reconcile`), `workflow_run_id text NOT NULL DEFAULT ''`, `deployed_by text NOT NULL DEFAULT ''`.

3. **`commit_token_burn` (planned in `csi-spl-doc/specs/143-reporting-section/spec.md:985-1017`, `SPL-3893`; not yet on `origin/master`)**
   - Command:
     ```bash
     nl -ba csi-spl-doc/specs/143-reporting-section/spec.md | sed -n '985,1017p'
     ```
   - Spec 143 §8.7 (`spec.md:985-1017`) defines `commit_token_burn` (not yet created in `csi-spl-rdb` on `origin/master`) with `sha text NOT NULL REFERENCES release_notes (sha) ON DELETE CASCADE`, `PRIMARY KEY (sha, vendor, day_bucket, part)` (`spec.md:1003`), and two operator-only RLS policies (`operator_select FOR SELECT` and `operator_write FOR ALL` at `spec.md:1012-1016`), with no `tenant_id` column.

### 2.3 Exact Go API, Store, WUI, and Orc `file:line` citations

1. **Hub API — Reporting → Releases (`csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_releases.go`)**
   - Command:
     ```bash
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/hub/reporting_releases.go | sed -n '43,58p;116,173p'
     ```
   - `reporting_releases.go:44-57` (`releaseReportReader`):
     ```go
     func (s *Server) releaseReportReader(w http.ResponseWriter, r *http.Request) (store.ReleaseReports, bool) {
     	s.allowOrigin(w, r)
     	w.Header().Set("Cache-Control", "no-store")
     	_, hum, ok := s.humanTenant(w, r)
     	if !ok {
     		return nil, false
     	}
     	if hum == "" {
     		writeForbidden(w, rbac.TopicsRead, "the reporting section needs a signed-in member session")
     		return nil, false
     	}
     	rr, _ := s.o.Store.(store.ReleaseReports)
     	return rr, true
     }
     ```
     The workspace `tenant` returned as the first value of `s.humanTenant(w, r)` is discarded (`_`).
   - `reporting_releases.go:116-136` (`handleReleasesDaily`) and `147-173` (`handleReleasesCommits`) call `rr.ReleaseDaily(r.Context(), f)` and `rr.ReleaseCommits(r.Context(), f)` without a tenant or repo argument.

2. **Hub Store — Reporting → Releases (`csi-spl-api/src/go/spool-hub-api/internal/store/reporting_releases.go`)**
   - Command:
     ```bash
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/store/reporting_releases.go | sed -n '15,20p;85,95p;211,271p'
     ```
   - `store/reporting_releases.go:15-17`:
     ```go
     // The Releases report of the Reporting section (spec 143 section 2.4, tasks
     // T020 and T021): two reads over release_notes (rdb 0108) and estate_deploys
     // (rdb 0202). Both tables are estate-wide, so no call takes a tenant id.
     ```
   - `store/reporting_releases.go:86-93`: strips `^csi-spl-` from `release_notes.area` in both Go (`strings.TrimPrefix(head, "csi-spl-")`) and SQL (`regexp_replace(lower(btrim(split_part(area, ',', 1))), '^csi-spl-', '')`).
   - `store/reporting_releases.go:211-271`: `ReleaseDaily`, `estateDeploys`, and `ReleaseCommits` query `FROM release_notes` and `FROM estate_deploys` directly on `s.pool` without `inTenant`/`queryTenant` or `WHERE tenant_id = ...`.

3. **Hub API & Store — Release Notes & Flow (`csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes.go`, `internal/store/release_note_postgres.go`, `internal/store/flow_fold.go`, `internal/store/flow_postgres.go`)**
   - Command:
     ```bash
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes.go | sed -n '98,135p;186,207p'
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/store/release_note_postgres.go | sed -n '12,35p;105,190p'
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/store/flow_fold.go | sed -n '349,357p;390,395p'
     nl -ba csi-spl-api/src/go/spool-hub-api/internal/store/flow_postgres.go | sed -n '264,266p'
     ```
   - `hub/release_notes.go:186-207` (`releaseReader`): checks `s.webCalendarTenant(r)` or `s.humanTenant(w, r)` solely to confirm the workspace exists, discards the tenant ID, and returns `rs, _ := s.o.Store.(store.ReleaseNotes)`.
   - `hub/release_notes.go:98-135` (`handleIngest`): `POST /v1/operator/release-notes` writes to the single global `release_notes` table.
   - `store/release_note_postgres.go:12-14`:
     ```go
     // Postgres side of rdb 0108. release_notes has no tenant_id and no row
     // security (estate-wide, like human_identities), so the statements run on the
     // pool, not in a tenant or operator scope.
     ```
   - `store/flow_fold.go:349-357, 392` and `store/flow_postgres.go:264-266`: `flowReleasesSQL` and the Flow unread badge count query `FROM release_notes r` with no tenant filter inside `s.queryTenant(ctx, q.Tenant, ...)`.

4. **WUI — Reporting → Releases, Release Notes Dialog, and Commit Links**
   - Command:
     ```bash
     nl -ba csi-spl-wui/src/utils/reporting-releases.ts | sed -n '46,49p'
     nl -ba csi-spl-wui/src/components/reporting/ReleasesFilterBar.vue | sed -n '44,48p;62,82p'
     nl -ba csi-spl-wui/src/components/reporting/ReleasesDailyList.vue | sed -n '96,106p'
     nl -ba csi-spl-wui/src/components/ReleaseNotesDialog.vue | sed -n '264,298p'
     nl -ba csi-spl-wui/src/plugins/commit-links.client.ts | sed -n '1,23p'
     nl -ba csi-spl-cnf/csi-spl/all.env.yaml | sed -n '1545,1550p'
     ```
   - `csi-spl-wui/src/utils/reporting-releases.ts:47-48`:
     ```ts
     export const RELEASE_KINDS = Object.freeze(['feat', 'fix', 'docs', 'chore', 'perf', 'refactor', 'ci', 'test'])
     export const RELEASE_AREAS = Object.freeze(['orc', 'api', 'wui', 'iac', 'cnf', 'doc', 'rdb'])
     ```
   - `csi-spl-wui/src/components/reporting/ReleasesFilterBar.vue:46, 64, 81`: builds and toggles the Area pill cloud from `RELEASE_AREAS` (`orc`, `api`, `wui`, `iac`, `cnf`, `doc`, `rdb`), so any workspace repo whose commit scopes are e.g. `web`, `booking`, `cms`, `db`, `worker` would have all its area pills dropped or hidden unless areas come dynamically from the workspace's commits.
   - `csi-spl-wui/src/components/reporting/ReleasesDailyList.vue:105`: `areaOf` strips `^csi-spl-`.
   - `csi-spl-wui/src/components/ReleaseNotesDialog.vue:268, 275, 296-297`: uses `config.public.appVersion` (`running` badge) and `commitPrefix(config.public.repoWebUrl, config.public.repoCommitPath)` (`commitBase` at line `296`, `commitUrl` at line `297`) from static `/config.json`.
   - `csi-spl-wui/src/plugins/commit-links.client.ts:11-23`: reads `pub.repoWebUrl` and `pub.repoCommitPath` from `/config.json` (`env.wui.repo_web_url: https://github.com/csitea/csi-spl` in `csi-spl-cnf/csi-spl/all.env.yaml:1546`), returns early at line `15` when either is empty, and binds `setCommitLinkProvider(() => linker.value)` with `m.commitLinker(webUrl, commitPath)` once on boot. Because a single Firebase Hosting static bundle serves `*.<BASE_DOMAIN>` across all workspaces (`csi-spl-orc/src/bash/run/deploy-wui.func.sh:102-138`), `/config.json` is instance-wide, not per-workspace.

5. **Orc — Ingest, Deploy Record, and Box-Side `workspace-repos.tsv`**
   - Command:
     ```bash
     nl -ba csi-spl-orc/src/bash/run/release-note-ingest.func.sh | sed -n '28,48p;75,103p'
     nl -ba csi-spl-orc/src/bash/run/spl-deploy-record.func.sh | sed -n '34,68p'
     nl -ba csi-spl-orc/src/bash/run/spl-issue-close-landed.func.sh | sed -n '86,95p;163,167p'
     nl -ba csi-spl-orc/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh | sed -n '1,30p'
     ```
   - `release-note-ingest.func.sh:41, 81, 96-103`: runs `git -C "$APP_PATH"` (the `csi-spl` repo, line `41`) during `.github/workflows/20_hub-build-deploy.yml`, resolves `RELEASE_ISSUE_TENANT` (defaulting to `env.hub.commit_issue_tenant`, lines `32, 96-103`), and posts to `/v1/operator/release-notes` (line `81`).
   - `spl-deploy-record.func.sh:34-68` & `hub/operator_deploys.go:169-178`: records only `csi-spl` `hub`/`wui` deploys and probes the hub's `/version` and apex `/build.json`.
   - **What ALREADY exists on the box side (`workspace-repo.inc.sh:1-28`, `spl-issue-close-landed.func.sh:86-95, 163-167`, and `lane-issue-and-docs.md` §5):**
     `$SPOOL_ROOT/workspace-repos.tsv` (`workspace-repo.inc.sh:14-23`) already maps `<tenant> -> <env> <repo> <clone> <trunk> <live_url> <desk_agent> <desk_box>` (where `repo` is the repo's short name for comments, `workspace-repo.inc.sh:18`) so `do_spl_lane_issue` and `do_spl_issue_close_landed` (`ISSUE_CLOSE_WORKSPACE=<workspace>`, `spl-issue-close-landed.func.sh:86-95`) can fetch `<clone>` (`spl_icl_fetch` at `spl-issue-close-landed.func.sh:164-167`), walk its git log, and close landed `<PREFIX>-<n>` issues in `<workspace>`. However, **the hub database and API know nothing about `workspace-repos.tsv`**: commits from `<clone>` are never ingested into hub Postgres, and the hub API/WUI still serve `t1`'s `release_notes` and `estate_deploys` to every workspace.

---

## 3. Design: Per-Workspace Repository, Ingestion, Secret Custody, and Scoped Reads

### 3.1 Architecture overview

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Workspace Repo Registry (`workspace_repos` table + `$SPOOL_ROOT/*.tsv`)    │
│   tenant_id = '<WORKSPACE>'                                                │
│   repo_slug = '<org>/<repo>' (e.g. 'csitea/<repo>')                        │
│   repo_web_url   = 'https://github.com/<ORG>/<REPO>'                       │
│   trunk_branch   = 'main' (or 'master')                                    │
│   live_url       = 'https://<LIVE_DOMAIN>'                                 │
│   auth_mode      = 'github_app' | 'pat_kms' | 'public' | 'ingest_only'     │
└───────────────┬───────────────────────────────────────────┬────────────────┘
                │                                           │
                ▼                                           ▼
┌───────────────────────────────────────────┐ ┌──────────────────────────────┐
│ Ingestion paths into Hub Postgres         │ │ Workspace Settings API       │
│  1. Hub background sync / GitHub webhook  │ │  GET /v1/tenant/settings     │
│     (via internal/github App or KMS PAT)  │ │  returns workspace's own     │
│  2. Box / CI push (`RELEASE_NOTE_TENANT=  │ │  repo_web_url & commit_path  │
│     <WORKSPACE> ./run -a do_release_...`) │ │  (empty if unconfigured)     │
└───────────────┬───────────────────────────┘ └─────────────┬────────────────┘
                │                                           │
                ▼                                           ▼
┌───────────────────────────────────────────┐ ┌──────────────────────────────┐
│ Workspace-scoped Hub DB tables (RLS)      │ │ WUI & Hub Readers            │
│  - release_notes (tenant_id, sha PK)      │ │  - /reporting/releases       │
│  - estate_deploys (tenant_id, deploy_id)  │ │  - /v1/release-notes & Flow  │
│  - commit_token_burn (tenant_id, sha, ..) │ │  - commit-links.client.ts    │
│  - issues / issue_discussions (existing)  │ │  - Issue <-> Commit links    │
└───────────────────────────────────────────┘ └──────────────────────────────┘
```

### 3.2 Where a workspace names its git repository

We evaluate the storage location against [Spec 098 §7 (Promotion triggers from `tenants.settings` JSONB to first-class SQL)](../098-tenant-settings-jsonb/spec.md):

- Spec 098 §7 states that a setting belongs in `tenants.settings` JSONB only while it is read/written as a single-tenant document; **as soon as a background job scans across tenants, or SQL joins/foreign-keys against it, or multiple rows per workspace can exist, it must be a relational table/column**.
- Repository tracking requires:
  1. The hub's background sync / webhook router to look up which workspace(s) own `<ORG>/<REPO>` (`WHERE repo_slug = lower($1)`).
  2. Support for either one primary repository per workspace today or multiple repositories (`repo_slug`) per workspace in the future without another schema migration.
  3. Registering `repo_slug`, `auth_mode`, and `github_installation_id` strictly through the operator API (`PUT /v1/operator/workspaces/{id}/repos`) and box-side `$SPOOL_ROOT/workspace-repos.tsv` (while allowing workspace admins to edit display fields `repo_web_url`, `repo_commit_path`, `trunk_branch`, and `live_url` via `PATCH /v1/tenant/settings`, and exposing the primary repo's display metadata on `GET /v1/tenant/settings`) — **never in `csi-spl-cnf` or any git-tracked file**, because per `lane-issue-and-docs.md` §5 *"a customer's tenant, repo and host do not ship in this public repo"*. Only the `t1 -> csitea/csi-spl` seed lives in a migration.

#### Relational table: `workspace_repos` (`<head+1>_workspace_repos.sql`)

```sql
CREATE TABLE workspace_repos (
    tenant_id              text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    repo_slug              text        NOT NULL, -- e.g. 'csitea/<repo>' (lowercase owner/name)
    is_primary             boolean     NOT NULL DEFAULT true,
    provider               text        NOT NULL DEFAULT 'github'
                           CHECK (provider IN ('github', 'gitlab', 'gitea', 'other')),
    repo_web_url           text        NOT NULL, -- e.g. 'https://github.com/csitea/<repo>'
    repo_commit_path       text        NOT NULL DEFAULT '/commit/',
    trunk_branch           text        NOT NULL DEFAULT 'main',
    live_url               text        NOT NULL DEFAULT '',
    version_tag_glob       text        NOT NULL DEFAULT 'v*',
    area_strip_prefix      text        NOT NULL DEFAULT '', -- 'csi-spl-' for t1; '' for other workspaces
    auth_mode              text        NOT NULL DEFAULT 'github_app'
                           CHECK (auth_mode IN ('github_app', 'pat_kms', 'public', 'ingest_only')),
    github_installation_id bigint      NULL,
    last_synced_sha        text        NULL,
    last_synced_at         timestamptz NULL,
    sync_status            text        NOT NULL DEFAULT 'pending'
                           CHECK (sync_status IN ('pending', 'ok', 'error', 'disabled')),
    sync_error             text        NOT NULL DEFAULT '',
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, repo_slug),
    CONSTRAINT workspace_repos_slug_chk CHECK (repo_slug ~ '^[a-z0-9._-]+/[a-z0-9._-]+$')
);

CREATE UNIQUE INDEX workspace_repos_one_primary_idx
    ON workspace_repos (tenant_id) WHERE is_primary;
CREATE UNIQUE INDEX workspace_repos_primary_slug_idx
    ON workspace_repos (repo_slug) WHERE is_primary;
CREATE INDEX workspace_repos_slug_idx
    ON workspace_repos (repo_slug);

ALTER TABLE workspace_repos ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_repos FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_repos_tenant_scope ON workspace_repos
    USING (
        current_setting('app.rls_scope', true) = 'operator'
        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
    )
    WITH CHECK (
        current_setting('app.rls_scope', true) = 'operator'
        OR tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
    );
```

- **Column-level write separation & cross-tenant `repo_slug` guard**:
  - A workspace admin may edit only `repo_web_url`, `repo_commit_path`, `trunk_branch`, and `live_url` through `PATCH /v1/tenant/settings` (`hub/tenant_settings.go:107`, which requires `rbac.TenantSettings` and runs inside `s.inTenant(ctx, tenant, ...)`).
  - `repo_slug`, `auth_mode`, and `github_installation_id` are set only through `PUT /v1/operator/workspaces/{id}/repos` (operator scope), so a workspace admin can never point the fleet GitHub App at another workspace's private `csitea/*` repository.
  - The hub refuses a registration or sync whose `repo_slug` is registered as primary for another tenant (`workspace_repos_primary_slug_idx`). This is enforced in the hub handler, in the DB unique index, and in a store test, not only in RLS (because RLS cannot restrict columns).
- **Default seed for `t1` (`spool-hub`)**: The migration seeds `('t1', 'csitea/csi-spl', true, 'github', 'https://github.com/csitea/csi-spl', '/commit/', 'master', ..., 'csi-spl-', 'github_app')`.
- **Default for every other workspace (`t2`, `t3`, …)**: **No row until registered** (via the operator API `PUT /v1/operator/workspaces/{id}/repos` or box-side `do_workspace_repo_register`). Never defaults to `csitea/csi-spl`, and customer workspace repo mappings are never committed to `csi-spl-cnf` or git.
- **Bridge with `$SPOOL_ROOT/workspace-repos.tsv` (`lane-issue-and-docs.md` §5.1)**:
  Because the existing `repo` column in `$SPOOL_ROOT/workspace-repos.tsv` holds the repo's short name for comments (`workspace-repo.inc.sh:14, 18`), `do_workspace_repo_register` takes `WORKSPACE_REPO_SLUG=<ORG>/<REPO>` (and derives `repo=${WORKSPACE_REPO_SLUG#*/}` for the TSV short name, or reads `git -C "$clone" remote get-url origin`) to update both `$SPOOL_ROOT/workspace-repos.tsv` on the desk box and `workspace_repos` in the hub API (`PUT /v1/operator/workspaces/{id}/repos`). Box-side `do_spl_lane_issue` / `do_spl_issue_close_landed` and hub-side `/reporting/releases` stay in lockstep from one registration command without placing customer mappings in git.
- **Workspace settings metadata (`GET /v1/tenant/settings`, `hub/tenant_settings.go:685`)**:
  Exposes the primary repo's non-secret display fields (`repo_slug`, `repo_web_url`, `repo_commit_path`, `trunk_branch`, `live_url`) on `GET /v1/tenant/settings` (while `PATCH /v1/tenant/settings` at `hub/tenant_settings.go:107, 686` updates only `repo_web_url`, `repo_commit_path`, `trunk_branch`, and `live_url` on an existing primary row). `commit-links.client.ts` is restructured so `setCommitLinkProvider` re-binds `commitLinker(repoWebUrl, repoCommitPath)` when the active workspace's repo resolves; if the workspace has no primary repo, `linker.value` stays `null` so commit hashes remain plain text in that workspace.

### 3.3 Scoped database schema & zero-downtime expand/contract deploy order for `release_notes`, `estate_deploys`, and `commit_token_burn`

#### 3.3.0 Zero-downtime expand / hub-deploy / contract order

The hub database role runs with `NOBYPASSRLS` (`csi-spl-api/src/docker/pg-init.sh:15`, `cmd/spool/hub.go:494-498`), and today's running hub executes `release_notes` and `estate_deploys` statements directly on `s.pool` with no tenant/operator scope (`store/release_note_postgres.go:33, 115-119, 155, 179-186`; `store/reporting_releases.go:218, 243, 265, 268`) and `ON CONFLICT (sha)` (`store/release_note_postgres.go:119`). Because migrations apply **before** the new hub container goes live in CI (`20_hub-build-deploy.yml:617`), swapping the primary key or enabling `FORCE ROW LEVEL SECURITY` in a single migration before the hub code is updated would break the old hub's `ON CONFLICT (sha)` and cause its unscoped pool reads to return `0` rows on `prd`.

Therefore, the schema transition is split into an **expand migration** (Lane 1, before/with the hub code in Lane 2) and a **contract migration** (Lane 2b, only after the Lane 2 hub is deployed and serving on both `dev` and `prd`):

1. **Step A — Expand migration (`<head+1>_workspace_repos.sql` and `<head+2>_release_notes_deploys_expand.sql`, Lane 1)**:
   - Create `workspace_repos` and seed `t1 -> csitea/csi-spl`.
   - On `release_notes`: add `tenant_id text NOT NULL DEFAULT 't1' REFERENCES tenants (tenant_id) ON DELETE CASCADE` and `repo_slug text NOT NULL DEFAULT 'csitea/csi-spl'`; backfill existing rows to `tenant_id = 't1'`, `repo_slug = 'csitea/csi-spl'`, `issue_tenant = 't1'`; create `CREATE UNIQUE INDEX release_notes_tenant_sha ON release_notes (tenant_id, sha)` alongside the existing `release_notes_pkey (sha)` so both old `ON CONFLICT (sha)` and new `ON CONFLICT (tenant_id, sha)` succeed; relax `release_notes_version_check` and rebuild `release_notes_release_key` with a guarded `CASE WHEN` expression (§3.3.1 step 4). Do **not** enable RLS on `release_notes` yet.
   - On `estate_deploys`: add `tenant_id text NOT NULL DEFAULT 't1' REFERENCES tenants (tenant_id) ON DELETE CASCADE` and `repo_slug text NOT NULL DEFAULT 'csitea/csi-spl'`; widen `component` and `version` checks (§3.3.2 steps 2–3). Keep `estate_deploys_read` (`USING (true)`) until Step C.
   - **Tenant-table gate handling during Step A (`store/rls_test.go`, `store/rls_failclosed_test.go`, `store/crosstenant_test.go`)**:
     Because `TestRLSCoversEveryTenantTable` (`store/rls_test.go:83-113`), `TestRLSPoliciesFailClosed` (`store/rls_failclosed_test.go:197-199`), and `TestCrossTenantEveryTable` (`store/crosstenant_test.go:776-790`) inspect the PostgreSQL catalog after every migration, Lane 1 adds `workspace_repos` to `rlsTables` (`store/rls_test.go:68`) and `seedTenantAll` (`store/crosstenant_test.go:779`), and adds `release_notes` and `estate_deploys` to a time-boxed exemption in `store/rls_test.go`, `store/rls_failclosed_test.go`, and `store/crosstenant_test.go`. Each entry carries a comment naming `SPL-4808` and Lane 2b.
2. **Step B — Hub store & API release (Lane 2)**:
   - Update `store/release_note_postgres.go` so ingest writes run in `s.asOperator(ctx, ...)` (`store/rls.go:339`) using `ON CONFLICT (tenant_id, sha)`, and reads (`ReleaseNote`, `ListReleaseNotes`, `ReleaseNotesOfVersion`) run in `s.inTenant` / `s.queryTenant` (`store/rls.go:44, 270`) with `WHERE tenant_id = $1`. Relax `releaseVersionRe` / `CheckReleaseNote` (`store/release_note.go:31, 116-117`) and update `ListReleaseNotes`, `ReleaseNotesOfVersion`, and `checkBefore` to order and page by `(release key NULLS LAST, coalesce(released_at, committed_at) DESC, sha)` (§3.3.1 step 4).
   - Update `store/reporting_releases.go` (`ReleaseDaily`, `estateDeploys`, `ReleaseCommits`) to run in `s.inTenant` / `s.queryTenant` with `WHERE tenant_id = $1`, and `store/estate_deploys.go` (`estateDeployPut` at `:99-109`, `estateDeployFill` and its subselect at `:112-115`, `LatestEstateDeploy` at `:144-149`, and `CheckEstateDeploy` at `:77-80`) to include `tenant_id` and `repo_slug` inside `s.asOperator`. Register the new `asOperator` callers in `operatorCallers` (`TestOperatorScopeCallers` in `store/operator_scope_test.go:138`) with their reason.
   - Update `store/flow_fold.go:352-357` and `store/flow_postgres.go:264-266` (which already run in `s.queryTenant`) to include `WHERE r.tenant_id = $3` (and `r.tenant_id = ` + tenant).
   - Deploy Lane 2 to `dev` and `prd` (`do_check_deploy_lag`).
3. **Step C — Contract migration (`<head+3>_release_notes_deploys_rls_contract.sql`, Lane 2b, after Lane 2 is live on `dev` and `prd`)**:
   - On `release_notes`: drop `DEFAULT 't1'` (`ALTER COLUMN tenant_id DROP DEFAULT`, `ALTER COLUMN repo_slug DROP DEFAULT`), replace `release_notes_pkey (sha)` with `PRIMARY KEY USING INDEX release_notes_tenant_sha`, then `ENABLE ROW LEVEL SECURITY`, `FORCE ROW LEVEL SECURITY`, and create the fail-closed `FOR SELECT` tenant policy and `FOR ALL` `operator_scope` policy (§3.3.1 step 5).
   - On `estate_deploys`: drop `DEFAULT 't1'` (`ALTER COLUMN tenant_id DROP DEFAULT`, `ALTER COLUMN repo_slug DROP DEFAULT`), drop `estate_deploys_read` (`USING (true)`), and create `estate_deploys_tenant_read FOR SELECT` (`NULLIF` fail-closed form) while keeping `operator_scope FOR ALL` for writes (§3.3.2 step 4).
   - In the same Lane 2b commit: remove the time-boxed exemption for `release_notes` and `estate_deploys` from `store/rls_test.go`, `store/rls_failclosed_test.go`, and `store/crosstenant_test.go`, and add both tables to `rlsTables` (`store/rls_test.go:68`), `tenantReadOnlyTables` (`store/crosstenant_test.go:770`, checked at `store/rls_failclosed_test.go:228-232`), and the `seedTenantAll` seed (`store/crosstenant_test.go:779`).

#### 3.3.1 `release_notes` schema & policies (`<head+2>` expand + `<head+3>` contract)

1. In `<head+2>` (expand), add `tenant_id text NOT NULL DEFAULT 't1' REFERENCES tenants (tenant_id) ON DELETE CASCADE` and `repo_slug text NOT NULL DEFAULT 'csitea/csi-spl'`. In `<head+3>` (contract), drop both defaults (`ALTER TABLE release_notes ALTER COLUMN tenant_id DROP DEFAULT, ALTER COLUMN repo_slug DROP DEFAULT`) so a write that omits `tenant_id` fails rather than landing in `t1` silently.
2. Backfill existing `csi-spl` rows to `tenant_id = 't1'`, `repo_slug = 'csitea/csi-spl'`, and `issue_tenant = 't1'`.
3. In `<head+2>` (expand), add `CREATE UNIQUE INDEX release_notes_tenant_sha ON release_notes (tenant_id, sha)`. In `<head+3>` (contract, after Lane 2 is deployed), swap the primary key from `(sha)` to `PRIMARY KEY (tenant_id, sha)` (so two workspaces that share a commit or fork history never collide, and every query is index-prefixed by `tenant_id`).
4. Relax `release_notes_version_check` (`0114_release_note_cycle.sql:16-18`) in the DB and `releaseVersionRe` / `CheckReleaseNote` (`store/release_note.go:31, 116-117`) in Go to the same pattern (`version IS NULL OR (length(version) BETWEEN 1 AND 64 AND version ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$')`) because non-`csi-spl` repositories may use `v1.0.0`, `v0.4.2-beta.1`, or date tags (`2026.11.05`) rather than `csi-spl`'s `-c2` cycle suffix, and commits on repositories that do not tag every push have `version IS NULL`.
   - **Guarding `release_notes_release_key` (`0114_release_note_cycle.sql:23-27`), `releaseKeySQL` (`store/release_note_postgres.go:23-26`), and paging/ordering in `ListReleaseNotes`, `ReleaseNotesOfVersion`, and `checkBefore`**:
     Today, `release_notes_release_key` and `releaseKeySQL` evaluate `string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]` unconditionally, and `ListReleaseNotes` (`store/release_note_postgres.go:178-188`), `ReleaseNotesOfVersion` (`store/release_note_postgres.go:195-196`), and `checkBefore` (`store/release_note.go:206-210`) reject any tag not matching `releaseVersionKey` or filter by `vk >= (SELECT min(k) FROM page)` (which drops rows where `vk IS NULL`). Therefore, Lane 1 (`<head+2>`) rebuilds `release_notes_release_key` with a guarded `CASE WHEN` expression:
     ```sql
     DROP INDEX IF EXISTS release_notes_release_key;
     CREATE INDEX release_notes_release_key ON release_notes (
         tenant_id,
         (CASE
             WHEN version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$'
             THEN array_prepend(
                 coalesce(substring(version from '-c([0-9]+)$')::int, 1),
                 string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]
             )
         END) DESC NULLS LAST,
         coalesce(released_at, committed_at) DESC,
         committed_at DESC,
         sha
     ) WHERE version IS NOT NULL;
     CREATE INDEX release_notes_tenant_released_idx ON release_notes (
         tenant_id,
         coalesce(released_at, committed_at) DESC,
         committed_at DESC
     ) WHERE version IS NOT NULL;
     ```
     And Lane 2 updates:
     - `releaseVersionRe` / `CheckReleaseNote` (`store/release_note.go:31, 116-117`) to accept `^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`.
     - `releaseKeySQL` (`store/release_note_postgres.go:23-26`), `ListReleaseNotes` (`store/release_note_postgres.go:173-191`), `ReleaseNotesOfVersion` (`store/release_note_postgres.go:194-202`), `releaseNumberedSQL` (`store/release_note_postgres.go:30-34`), `sortReleaseNotes` (`store/release_note.go:222-226`), and `checkBefore` (`store/release_note.go:206-210`) to order and page by `(release key DESC NULLS LAST, coalesce(released_at, committed_at) DESC, sha)` and accept any stored version string (so a tenant with only `v0.4.2-beta.1` and `2026.11.05` tags lists both in the Release Notes modal and opens `/releases/<tag>`).
5. In `<head+3>` (contract), enable and force Row-Level Security on `release_notes` with **fail-closed read-only tenant access (`FOR SELECT` using `NULLIF` per `0021_rls_fail_closed.sql:4-10`) and operator-only writes (`FOR ALL`)** so a tenant-scoped transaction can never `INSERT`, `UPDATE`, or `DELETE` `release_notes` rows (with `release_notes` added to `tenantReadOnlyTables` in `store/crosstenant_test.go:770`, checked at `store/rls_failclosed_test.go:228-232`):
   ```sql
   ALTER TABLE release_notes ALTER COLUMN tenant_id DROP DEFAULT;
   ALTER TABLE release_notes ALTER COLUMN repo_slug DROP DEFAULT;
   ALTER TABLE release_notes ENABLE ROW LEVEL SECURITY;
   ALTER TABLE release_notes FORCE ROW LEVEL SECURITY;

   CREATE POLICY release_notes_tenant_read ON release_notes
       FOR SELECT
       USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

   CREATE POLICY operator_scope ON release_notes
       FOR ALL
       USING (current_setting('app.rls_scope', true) = 'operator')
       WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
   ```
   - **Automatic effect on Flow (`store/flow_fold.go:352-357`, `store/flow_postgres.go:264-266`) and Reporting → SQL (`store/reporting_sql.go:68-75`)**:
     - Because Flow reads run inside `s.queryTenant(ctx, q.Tenant, ...)` (`store/flow_fold.go:392`), `release_notes_tenant_read` + `WHERE r.tenant_id = ...` ensures a non-`t1` workspace's Flow shows only `<WORKSPACE>`'s own releases (and `0` `t1` release lines / `0` unread badge count when `<WORKSPACE>` has none).
     - Because `release_notes` now has `tenant_id`, `ENABLE ROW LEVEL SECURITY`, `FORCE ROW LEVEL SECURITY`, and no secret or per-member policy, `pgReportingSQLRelations` (`store/reporting_sql.go:68-75`) automatically admits `release_notes` in **Reporting → SQL (`/reporting/sql`)** strictly scoped to `app.tenant_id = '<WORKSPACE>'` (never `t1`'s rows).

#### 3.3.2 `estate_deploys` schema & policies (`<head+2>` expand + `<head+3>` contract)

1. In `<head+2>` (expand), add `tenant_id text NOT NULL DEFAULT 't1' REFERENCES tenants (tenant_id) ON DELETE CASCADE` and `repo_slug text NOT NULL DEFAULT 'csitea/csi-spl'`. In `<head+3>` (contract), drop both defaults (`ALTER TABLE estate_deploys ALTER COLUMN tenant_id DROP DEFAULT, ALTER COLUMN repo_slug DROP DEFAULT`).
2. Widen `component` check (`0202_estate_deploys.sql:23` and `CheckEstateDeploy` in `store/estate_deploys.go:77-78`) from `('hub', 'wui', 'inf')` to allow workspace-defined deploy targets (`^[a-z0-9][a-z0-9_-]{0,31}$`, such as `'web'`, `'site'`, `'api'`, `'app'`, `'hub'`, `'wui'`, `'inf'`), and add `tenant_id = $n` to `estateDeployPut` (`store/estate_deploys.go:99-109`), `estateDeployFill`'s subselect (`store/estate_deploys.go:114-115`), and `LatestEstateDeploy` (`store/estate_deploys.go:144-149`) so a workspace deploy of component `hub` or `wui` is never read as `t1`'s by the reconcile check.
3. Relax `estate_deploys_version_check` (`0202_estate_deploys.sql:24`, `^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$`) and `estateDeployVersionRe` / `CheckEstateDeploy` (`store/estate_deploys.go:79-80`) the same way as `release_notes.version` (§3.3.1 step 4) and allow `version = ''` (or NULL-able `version`) for untagged trunk deploys keyed on `commit_sha`, so `POST /v1/operator/deploys?tenant=<WORKSPACE>` accepts workspace deploys whose tags do not use `csi-spl`'s `vX.Y.Z-cN` format.
4. In `<head+3>` (contract, after Lane 2 is deployed), replace `CREATE POLICY estate_deploys_read ON estate_deploys FOR SELECT TO PUBLIC USING (true)` (`0202_estate_deploys.sql:42-43`) with fail-closed tenant-scoped `FOR SELECT` (`0021_rls_fail_closed.sql:4-10`, with `estate_deploys` added to `tenantReadOnlyTables` in `store/crosstenant_test.go:770`) while preserving the existing `operator_scope` (`0202_estate_deploys.sql:45-47`) for operator-only writes:
   ```sql
   ALTER TABLE estate_deploys ALTER COLUMN tenant_id DROP DEFAULT;
   ALTER TABLE estate_deploys ALTER COLUMN repo_slug DROP DEFAULT;
   DROP POLICY IF EXISTS estate_deploys_read ON estate_deploys;
   CREATE POLICY estate_deploys_tenant_read ON estate_deploys
       FOR SELECT
       USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
   -- Existing operator_scope policy (0202_estate_deploys.sql:45-47) remains FOR ALL
   -- USING (current_setting('app.rls_scope', true) = 'operator')
   -- WITH CHECK (current_setting('app.rls_scope', true) = 'operator').
   ```

#### 3.3.3 `commit_token_burn` (`SPL-3893`, Spec 143 §8.7) — Owner Decision Q5 (`msg 331b339b`, poll `a98c41db`)

- `commit_token_burn` is not yet on `origin/master` (defined in `csi-spl-doc/specs/143-reporting-section/spec.md:985-1017`). Spec 143's migration creates `commit_token_burn` from the start with:
  - `tenant_id text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE` (no `DEFAULT 't1'`, or `ALTER COLUMN tenant_id DROP DEFAULT` in Lane 2b if created earlier, so a write that omits `tenant_id` fails fast)
  - `FOREIGN KEY (tenant_id, sha) REFERENCES release_notes (tenant_id, sha) ON DELETE CASCADE`
  - `PRIMARY KEY (tenant_id, sha, vendor, day_bucket, part)` (replacing Spec 143 §8.7's `(sha, vendor, day_bucket, part)` at `spec.md:1003`).
- The slicer attributes a lane's token and currency burn to `( lane.workspace_tenant_id, commit.sha )`, so work run on `<WORKSPACE>`'s repo lands under `<WORKSPACE>`.
- **Visibility & RLS (Decided in Q5, `HUM-10` msg `331b339b`, 2026-11-04T21:53:42Z, poll `a98c41db` — *"C — Every signed-in member of the workspace"*):**
  - Instead of Spec 143 §8.7's `operator_select` (`spec.md:1012-1013`), `commit_token_burn` uses a fail-closed tenant-scoped `FOR SELECT` policy (`0021_rls_fail_closed.sql:4-10`, and is listed in `tenantReadOnlyTables` at `store/crosstenant_test.go:770`) so every signed-in member of `<WORKSPACE>` can read `<WORKSPACE>`'s per-commit token and EUR cost, while keeping `operator_scope FOR ALL` (replacing `operator_write FOR ALL` at `spec.md:1014-1016`) so only the operator scope can write burn rows:
    ```sql
    ALTER TABLE commit_token_burn ENABLE ROW LEVEL SECURITY;
    ALTER TABLE commit_token_burn FORCE ROW LEVEL SECURITY;

    CREATE POLICY commit_token_burn_tenant_read ON commit_token_burn
        FOR SELECT
        USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

    CREATE POLICY operator_scope ON commit_token_burn
        FOR ALL
        USING (current_setting('app.rls_scope', true) = 'operator')
        WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
    ```
  - `GET /v1/reporting/releases/daily` and `GET /v1/reporting/releases/commits` return the AI token count and EUR cost per commit and per Kind/Area pill to **every signed-in human member of the workspace** (no operator-only or `costs.read` gate on `/reporting/releases`).

### 3.4 Ingestion & GitHub Authentication / Secret Custody

#### 3.4.1 How the hub ingests a workspace's commits, tags, and releases — Owner Decision Q2 (`msg bbad7ba3`, poll `0636da66`)

Per owner decision Q2 (`HUM-10` msg `bbad7ba3`, 2026-11-04T21:54:13Z, poll `0636da66` — *"A — Recommended: both: the hub polls the repo on GitHub every 5 min (plus webhook and a \"Sync now\" button), and a box can push them too"*), we support **both complementary paths writing to the same idempotent store `PutReleaseNotes(ctx, tenantID, repoSlug, notes, now)`**:

1. **Hub-native GitHub sync (primary — zero CI setup required in the target repo)**:
   - The hub already has a pure-Go GitHub REST client in `csi-spl-api/src/go/spool-hub-api/internal/github/{client.go,jwt.go,repo.go,commits.go}` configured via `SPOOL_HUB_DOCS_EDIT_GITHUB_APP_ID`, `SPOOL_HUB_DOCS_EDIT_INSTALLATION_ID`, and `SPOOL_GITHUB_APP_KEY` (`internal/config/config.go:328-329`, `all.env.yaml:892-894`).
   - Today `internal/github.Client` is bound to a single `Owner`/`Repo`/`InstallationID` at construction (`internal/github/client.go:72-78`), and `internal/github/commits.go:23` already implements `Commits(ctx, n)`. We add a per-repo client/handle scoped to each `workspace_repos` row (`owner`, `repo`, `trunk_branch`, and per-row `github_installation_id` or KMS PAT) and extend `Commits(ctx, n)` with `sinceSHA` / commit timestamps + changed-file top directory, plus `Tags(ctx)` (`GET /repos/{owner}/{repo}/tags`) and `Releases(ctx)` (`GET /repos/{owner}/{repo}/releases`).
   - **Trigger**:
     - **Background reconciler loop** in `spool-hub-api` (every 5 minutes, plus an immediate "Sync now" button/API for workspace admins) walks all active `workspace_repos` rows (`auth_mode IN ('github_app', 'pat_kms', 'public')`), refuses any sync whose `repo_slug` is registered as primary for another tenant (§3.2), fetches new commits on `trunk_branch` since `last_synced_sha` (or the initial backfill window, up to 2,000 commits), maps tag/release SHAs to `version` and `released_at`, parses conventional-commit `kind(area): subject`, optional `Lay-*`/`Tech-*` trailers, and `<PREFIX>-<n>` issue keys, and upserts into `release_notes` with `tenant_id = workspace.tenant_id`.
     - **Optional GitHub App webhook (`POST /v1/webhooks/github`)**: verifies `X-Hub-Signature-256` against the webhook secret in GCP Secret Manager and triggers an immediate delta sync for the matching `workspace_repos.repo_slug` on `push` and `release` events. The webhook secret is a GCP Secret Manager slot provisioned by Terraform; its secret version is populated out of band (like `07-github-app-key.tf` for `spool-hub-github-app-key` in `all.env.yaml:892`), never in Terraform state or git.
2. **Box / CI push (`POST /v1/operator/release-notes` with `tenant` + `repo_slug` in the ingest body)**:
   - `csi-spl-orc/src/bash/run/release-note-ingest.func.sh` already reads `RELEASE_ISSUE_TENANT` (`release-note-ingest.func.sh:32, 96-103`, defaulting to `env.hub.commit_issue_tenant`). We add `RELEASE_NOTE_TENANT` and `RELEASE_NOTE_REPO_PATH` (default `$APP_PATH`, or the `<clone>` column from `$SPOOL_ROOT/workspace-repos.tsv`): `RELEASE_ISSUE_TENANT` defaults to `RELEASE_NOTE_TENANT`, which defaults to cnf `env.hub.commit_issue_tenant` (`release-note-ingest.func.sh:96-103`). When `RELEASE_NOTE_REPO_PATH` is not `$APP_PATH`, `RELEASE_NOTE_TENANT` is required and the action fails fast without it (so a workspace clone ingested without the variable never silently lands in `t1`).
   - Desk cron (`do_spl_issue_close_landed` in `csi-spl-orc/src/bash/run/spl-issue-close-landed.func.sh:86-95`, which calls `spl_icl_fetch` at `:164-167` using `$SPOOL_ROOT/workspace-repos.tsv` from `workspace-repo.inc.sh`) already fetches `"$ICL_REPO"` on the desk box for every workspace in `$SPOOL_ROOT/workspace-repos.tsv`; chaining `RELEASE_NOTE_TENANT=<WORKSPACE> RELEASE_NOTE_REPO_PATH=<clone> ./run -a do_release_note_ingest` ingests the full git log directly from the local clone as an immediate fallback even before any GitHub API change.

#### 3.4.2 How GitHub credentials are held (Secret Manager & KMS envelope per Spec 127 / Spec 159 — never in git) — Owner Decision Q3 (`msg d5b1366a`, poll `c21fd9b7`)

Per owner decision Q3 (`HUM-10` msg `d5b1366a`, 2026-11-04T21:54:03Z, poll `c21fd9b7` — *"A — Recommended: the existing fleet GitHub App for csitea repos (no new secret), plus an optional read-only token per workspace, encrypted with Cloud KMS, for repos in other GitHub orgs"*):

- **Case 1 — Repository in the `csitea` GitHub organization (e.g. `csitea/<REPO>`)**:
  - The hub's existing GitHub App (`SPOOL_HUB_DOCS_EDIT_GITHUB_APP_ID`, `SPOOL_HUB_DOCS_EDIT_INSTALLATION_ID` in `internal/config/config.go:328-329`, private key `SPOOL_GITHUB_APP_KEY` held in GCP Secret Manager `spool-hub-github-app-key` at `all.env.yaml:892`, mounted via `csi-spl-iac/src/terraform/030-cloud-run-hub/07-github-app-key.tf`) already belongs to the `csitea` org.
  - Granting that GitHub App installation read access (`Contents: Read-only`, `Metadata: Read-only`) to `csitea/<REPO>` requires **zero new secrets** — `workspace_repos.auth_mode = 'github_app'` works out of the box, and because `repo_slug`, `auth_mode`, and `github_installation_id` are operator-set only (`PUT /v1/operator/workspaces/{id}/repos`, §3.2), only an operator can bind a workspace to a `csitea/*` repository.
- **Case 2 — External customer GitHub organization or repository**:
  - **Option 2A (GitHub App installation)**: The external org installs the Spool GitHub App on `<ORG>/<REPO>` and an operator records `github_installation_id` on `workspace_repos` (`PUT /v1/operator/workspaces/{id}/repos`). The hub mints installation tokens using its existing `spool-hub-github-app-key` in GCP Secret Manager.
  - **Option 2B (Per-workspace fine-grained GitHub PAT with KMS envelope encryption)**: If a workspace prefers a fine-grained read-only PAT (`Contents: Read`), it is stored following the `workspace_vendor_keys` KMS envelope pattern (`0174_workspace_vendor_keys.sql:50`, sealed with GCP Cloud KMS `057-gcp-kms-vendor-keys`, Spec 127 / Spec 159 `internal/vendorkey/vendorkey.go`) with AAD `<tenant_id>|github|<repo_slug>`, **never** in git, `csi-spl-cnf`, or plaintext Postgres.

### 3.5 Hub API & WUI Reader Changes

1. **`GET /v1/reporting/releases/daily` and `GET /v1/reporting/releases/commits` (`hub/reporting_releases.go`)**:
   - `releaseReportReader` captures `t, hum, ok := s.humanTenant(w, r)` and passes `t.ID` into `rr.ReleaseDaily(r.Context(), t.ID, f)` and `rr.ReleaseCommits(r.Context(), t.ID, f)`.
   - `store/reporting_releases.go` runs inside `s.inTenant` / `s.queryTenant` (`store/rls.go:44, 270`) and filters `WHERE tenant_id = $1`.
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
   - When `repo.configured == false` (no `workspace_repos` row for `t.ID`), the endpoint returns `200 OK` with `repo.configured: false`, `days: []`, `totals: { releases_count: 0, commits_count: 0, ... }`, and the WUI renders an explicit empty-state card (*"No git repository is connected to `<WORKSPACE>` yet"*).
2. **`GET /v1/release-notes` and `GET /v1/release-notes/{ref}` (`hub/release_notes.go`) & Flow (`store/flow_fold.go`, `store/flow_postgres.go`)**:
   - `releaseReader` returns `(rs, tenantID, ok)` from `s.webCalendarTenant(r)` or `s.humanTenant(w, r)` and passes `tenantID` to `ListReleaseNotes(ctx, tenantID, before, versions)`, `ReleaseNotesOfVersion(ctx, tenantID, version)`, and `ReleaseNote(ctx, tenantID, ref)`, which execute inside `s.queryTenant` (`store/rls.go:270`) and order/page by `(release key NULLS LAST, coalesce(released_at, committed_at) DESC, sha)` while accepting any stored version string (§3.3.1 step 4).
   - `flowReleasesSQL` (`store/flow_fold.go:352-357`) and the Flow unread badge count (`store/flow_postgres.go:264-266`) add `r.tenant_id = $3` (and `r.tenant_id = ` + tenant) in addition to `release_notes_tenant_read` RLS.
3. **WUI Reporting → Releases & Release Notes (`csi-spl-wui`)**:
   - `ReleasesFilterBar.vue` and `reporting-releases.ts`: replace the hardcoded `RELEASE_AREAS = ['orc', 'api', 'wui', 'iac', 'cnf', 'doc', 'rdb']` (`reporting-releases.ts:48`) with the dynamic `available_areas` returned by `/v1/reporting/releases/daily` (falling back to the distinct `area` values present in `days[].by_area`).
   - `ReleasesDailyList.vue` and `ReleaseNotesDialog.vue`: build commit links from the workspace's `repo.repo_web_url + repo.repo_commit_path` rather than static `/config.json`.
   - `commit-links.client.ts`: restructure the plugin so `setCommitLinkProvider` re-binds `commitLinker(repoWebUrl, repoCommitPath)` whenever the active workspace's repository metadata (`GET /v1/tenant/settings`) resolves. For `t1`, that is `https://github.com/csitea/csi-spl` + `/commit/`; for `<WORKSPACE>`, that is `https://github.com/<ORG>/<REPO>` + `/commit/`; for an unconfigured workspace, `linker.value` stays `null` (no false links to `csi-spl`).

---

## 4. "The Analysis For It" — Commit & Release Analysis Per Workspace

In the `spool-hub` workspace (`t1`), commit history powers seven distinct analysis layers. Here is how each works in `t1` today and how it carries over to every workspace `<WORKSPACE>` against `<ORG>/<REPO>`:

| # | Analysis capability in `t1` (`spool-hub`) today | Code & Spec today | How it works for `<WORKSPACE>`'s own repo (`<ORG>/<REPO>`) |
|---|---|---|---|
| **1** | **Velocity KPIs & Daily Activity Timeline** (`Releases`, `Commits`, `Commits / day`, `Deploys dev / prd`, per-day commit stream, version grouping) | Spec 143 §2.2, `store/reporting_releases.go:211-271`, `ReportingReleasesSummary.vue`, `ReleasesDailyList.vue` | Computed strictly over `release_notes WHERE tenant_id = '<WORKSPACE>'` and `estate_deploys WHERE tenant_id = '<WORKSPACE>'`. Commits without a version tag group under `unreleased` / their date bucket; when the repo uses git tags or GitHub Releases, `version` and `released_at` populate automatically. |
| **2** | **Conventional-commit `Kind` & `Area` Label Clouds** (`feat`, `fix`, `docs`, `chore`, `perf`, `refactor`, `ci`, `test` + scope pills with counts and multi-select filtering) | Spec 143 §2.2.1 (`SPL-3796`), `ReleasesFilterBar.vue:46, 64, 81`, `store/reporting_releases.go:64-93` | **Decided (Q4, `msg ab74f79d`, poll `9d1a183a`) — carries over per workspace with dynamic Area discovery**: the parser extracts `kind(area): subject` from each commit subject; if a commit has no `(area)` in its subject, the ingester derives `area` from the top-level directory of changed files (e.g. `web`, `src`, `docs`) and strips `workspace_repos.area_strip_prefix` (only `'csi-spl-'` in `t1`). The WUI renders the workspace's own top areas instead of hardcoded `orc/api/wui/...`. |
| **3** | **Lay / Tech Structured Release Notes** (`Lay-What/How/Why`, `Tech-What/How/Why` trailers, completeness `state` badge: `ok`, `missing`, `skip`, `revert`, `backfill`) | Spec 065, `0108_release_note.sql:37`, `release-note-ingest.func.sh` | **Decided (Q4, `msg ab74f79d`, poll `9d1a183a`) — carries over cleanly**: commits created by fleet agents in `<WORKSPACE>` (per `lane-issue-and-docs.md` §5) can include `Lay-*` / `Tech-*` trailers; commits without those trailers show their commit subject and body summary cleanly without error. |
| **4** | **Bidirectional Commit ↔ Issue ↔ Discussion Links** (`SPL-4789`: commit row shows linked `<PREFIX>-<n>` issue chip + discussion thread link; issue drawer and discussion header list every commit that cites `<PREFIX>-<n>`) | `SPL-4789` (landed on `origin/master` in `8f1834b21..b4e38052a`, `0261_release_note_issue_keys.sql`), `csi-spl-wui/tests/e2e/release-commit-links.test.mjs` | **Carries over per workspace**: when ingesting commits for `<WORKSPACE>`, the ingester looks up `<WORKSPACE>`'s `issue_counters.prefix` (`store/issues_postgres.go:761-762`, set via `issue_prefix` on `PATCH /v1/tenant/settings`), sets `release_notes.tenant_id = '<WORKSPACE>'` and `release_notes.issue_tenant = '<WORKSPACE>'`, and populates `issue_keys`. Clicking an issue chip on `/reporting/releases` in `<WORKSPACE>` opens `<WORKSPACE>`'s own issue `<PREFIX>-<n>` and its linked `#development` discussion thread. |
| **5** | **Automated Issue Closure on Commit Landing & Spec 170 To-Do Deadlines** (`do_spl_issue_close_landed` scans trunk commits for `<PREFIX>-<n>` and transitions open `wip` issues to `done`, clearing them from active To-Do reminders) | `workspace-repo.inc.sh:1-28`, `spl-issue-close-landed.func.sh:86-95, 164-167`, [Spec 170](../170-day-tasks-reminder/spec.md) | **Already works on box clones via `workspace-repos.tsv` (`SPL-3528`/`SPL-3794`) and now unifies with the hub**: when the hub syncs new trunk commits for `<WORKSPACE>`, it can both insert `release_notes` rows (linking the closing commit SHA to `<PREFIX>-<n>`) and transition `<PREFIX>-<n>` to `done` with the landing commit SHA recorded on the issue closure event. |
| **6** | **Per-Commit & Per-Label Token and Currency Cost Attribution** (`SPL-3893`, Spec 143 §8: `commit_token_burn` attributes agent lane token burn and EUR cost across commits and displays `tokens · €cost` on each Kind/Area pill and commit row) | Spec 143 §8 (`spec.md:835-1017`), `SPL-3893` | **Decided (Q5, `msg 331b339b`, poll `a98c41db`) — carries over per workspace and visible to every signed-in member of `<WORKSPACE>`**: when an agent lane runs with `Workspace: <WORKSPACE>` (targeting `<ORG>/<REPO>` and issue `<PREFIX>-<n>`), `do_commit_token_burn_slice` joins `usage_events` for that lane's `agent_id` and time window to the commits landed in `release_notes WHERE tenant_id = '<WORKSPACE>'` citing `<PREFIX>-<n>`, and every signed-in workspace member sees the AI token and EUR cost per commit and per Kind/Area pill on `/reporting/releases`. |
| **7** | **Live Deploy Tracking & Drift Reconciliation** (`estate_deploys`: dev/prd deploy counts and live version probe) | Spec 143 §2.2, `0202_estate_deploys.sql`, `hub/operator_deploys.go`, `store/estate_deploys.go:114-115, 144-149` | **Carries over per workspace**: `<WORKSPACE>` records deploys via `POST /v1/operator/deploys?tenant=<WORKSPACE>` (with `LatestEstateDeploy` at `store/estate_deploys.go:144-149` and `estateDeployFill`'s subselect at `:114-115` scoped by `tenant_id = $n`, and `estate_deploys.version` relaxed per §3.3.2 step 3). An optional live probe of `workspace_repos.live_url` is `https` only, a public host only (no private or metadata IPs), operator-set (`PUT /v1/operator/workspaces/{id}/repos`), with a 5 s timeout. If `<WORKSPACE>` does not emit deploy events yet, the Deploys KPI card shows `0` (or `—`) for `<WORKSPACE>`, never `csi-spl`'s `hub`/`wui` deploy counts. |

---

## 5. Owner Decisions & Open Questions (A/B/C Options)

On 2026-11-04 (`HUM-10`, topic `f38888e7-27eb-4aad-b2fe-1736ffbb2f0e`), the owner answered **Q2, Q3, Q4, and Q5**. **Q1** (poll in msg `4b5869d5`) remains open.

### Q1 — Repository cardinality per workspace (`workspace_repos`) — **OPEN (poll in msg `4b5869d5`, awaiting owner answer)**
- **A (Recommended):** Allow multiple repos in the schema (`PRIMARY KEY (tenant_id, repo_slug)` with one `is_primary = true`), UI/Reporting defaults to the primary repo with an optional repo switcher when `count > 1`.
- **B:** Strictly one git repository per workspace (`PRIMARY KEY (tenant_id)` on `workspace_repos`).
- **C (Not recommended — breaks Spec 098 §7 trigger 3 because the sync loop and webhook router query across workspaces by repo slug):** Store a single `repo_url` string inside `tenants.settings` JSONB with no relational table.

### Q2 — How the hub ingests a workspace's git commits and tags — **DECIDED: A (`HUM-10` msg `bbad7ba3`, 2026-11-04T21:54:13Z, poll `0636da66`)**
- **Decision verbatim:** *"A — Recommended: both: the hub polls the repo on GitHub every 5 min (plus webhook and a \"Sync now\" button), and a box can push them too"*
- **A (Selected):** Both: the hub's GitHub App client (`internal/github`) polls `<ORG>/<REPO>` every 5 min (plus optional GitHub webhook + manual "Sync now"), AND box-side `RELEASE_NOTE_TENANT=<WORKSPACE> ./run -a do_release_note_ingest` can push from the local clone in `workspace-repos.tsv`.
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

Q2..Q5 are decided (`bbad7ba3`, `d5b1366a`, `ab74f79d`, `331b339b`); only Q1 (`4b5869d5`, repos per workspace cardinality on `workspace_repos`) remains open. Once Q1 is answered, the work executes in **ordered expand → hub deploy → contract phases** (§3.3.0) so `prd` never experiences an `ON CONFLICT (sha)` or RLS outage during rollout:

| Phase | Order & Dependency | Scope | Files touched | Verification |
|---|---|---|---|---|
| **Lane 1 — RDB expand migrations (`<head+1>`..`<head+2>` at land time)** | **Step 1 (first)** | Create `workspace_repos` (cardinality per Q1, fail-closed `NULLIF` tenant/operator RLS per `0021_rls_fail_closed.sql:4-10`, unique `workspace_repos_primary_slug_idx`) and seed `t1 -> csitea/csi-spl`. Expand `release_notes` and `estate_deploys` with `tenant_id` + `repo_slug`, backfill existing rows to `t1`, add `CREATE UNIQUE INDEX release_notes_tenant_sha ON release_notes (tenant_id, sha)` while keeping PK `(sha)` and no RLS on `release_notes` yet, relax `release_notes.version` and `estate_deploys.version`/`component` checks, rebuild `release_notes_release_key` with the guarded `CASE WHEN` expression (§3.3.1 step 4), and add `release_notes_tenant_released_idx`. Lane 1 adds `workspace_repos` to `rlsTables` (`rls_test.go:68`) and `seedTenantAll` (`crosstenant_test.go:779`), and adds `release_notes` and `estate_deploys` to a time-boxed exemption in `rls_test.go`, `rls_failclosed_test.go`, and `crosstenant_test.go` (each entry carrying a comment naming `SPL-4808` and Lane 2b). (When Spec 143's `commit_token_burn` migration lands, it is created with `tenant_id` without a default, PK `(tenant_id, sha, vendor, day_bucket, part)`, `commit_token_burn_tenant_read FOR SELECT` with `NULLIF`, and `operator_scope FOR ALL` per §3.3.3.) | `csi-spl-rdb/src/sql/postgres/spool-hub/<head+1>_workspace_repos.sql`, `<head+2>_release_notes_deploys_expand.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/{rls_test.go,rls_failclosed_test.go,crosstenant_test.go}` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` + Go store tests verifying that non-`csi-spl` tag strings (including `v1.2.`) insert without error under the guarded `release_notes_release_key` index, `TestRLSCoversEveryTenantTable`/`TestRLSPoliciesFailClosed`/`TestCrossTenantEveryTable` pass with `workspace_repos` seeded and the time-boxed exemption active, and existing hub `ON CONFLICT (sha)` and pool reads remain green. |
| **Lane 2 — Hub Store & API scoping + Workspace Repo API** | **Step 2 (after Lane 1 is on `master`)** | Update `store/release_note_postgres.go` writes to run in `s.asOperator` with `ON CONFLICT (tenant_id, sha)` and reads to run in `s.inTenant` / `s.queryTenant` with `WHERE tenant_id = $1`; relax `releaseVersionRe` / `CheckReleaseNote` (`store/release_note.go:31, 116-117`) and `estateDeployVersionRe` / `CheckEstateDeploy` (`store/estate_deploys.go:77-80`) in Go to match the DB pattern; update `ListReleaseNotes`, `ReleaseNotesOfVersion`, and `checkBefore` to order and page by `(release key NULLS LAST, coalesce(released_at, committed_at) DESC, sha)` and accept any stored version string; update `store/reporting_releases.go`, `store/estate_deploys.go` (`estateDeployPut` `:99-109`, `estateDeployFill`'s subselect `:114-115`, `LatestEstateDeploy` `:144-149` with `tenant_id = $n`), `store/flow_fold.go`, and `store/flow_postgres.go` to scope by `tenant_id`; add the new `asOperator` callers to `operatorCallers` (`TestOperatorScopeCallers` in `store/operator_scope_test.go:138`) with their reason; return `repo` metadata + dynamic `available_areas` (Q4 `ab74f79d`) + per-commit/per-pill AI token & EUR cost to every signed-in workspace member (Q5 `331b339b`); allow workspace admins to edit only `repo_web_url`, `repo_commit_path`, `trunk_branch`, and `live_url` via `PATCH /v1/tenant/settings` (`hub/tenant_settings.go:107`), while `repo_slug`, `auth_mode`, and `github_installation_id` are set only through `PUT /v1/operator/workspaces/{id}/repos` (operator scope, refusing any `repo_slug` already primary for another tenant) + KMS-encrypted PAT storage via `internal/vendorkey/vendorkey.go` (`0174_workspace_vendor_keys.sql`, Q3 `d5b1366a`). | `csi-spl-api/src/go/spool-hub-api/internal/store/{reporting_releases.go,release_note.go,release_note_postgres.go,estate_deploys.go,flow_fold.go,flow_postgres.go,operator_scope_test.go}`, `internal/hub/{reporting_releases.go,release_notes.go,operator_deploys.go,tenant_settings.go}` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` + `go test ./internal/store/... ./internal/hub/...` covering `t1` (`csitea/csi-spl`), a configured workspace (`<ORG>/<REPO>`), an unconfigured workspace (`configured: false`, 0 rows), a tenant with only `v0.4.2-beta.1` and `2026.11.05` tags listing both in the modal and opening `/releases/<tag>`, refusal of cross-tenant primary `repo_slug` and admin edits to `repo_slug`/`auth_mode`/`github_installation_id`, a `t2` member's Flow showing 0 `t1` release lines and badge count 0, and member-visible commit cost figures. |
| **Lane 2b — RDB contract migration (`<head+3>` at land time)** | **Step 3 (only after Lane 2 is deployed and serving on `dev` and `prd`)** | Drop `DEFAULT 't1'` (`ALTER COLUMN tenant_id DROP DEFAULT`, `ALTER COLUMN repo_slug DROP DEFAULT`) on `release_notes`, `estate_deploys`, and `commit_token_burn`; swap `release_notes_pkey` to `PRIMARY KEY USING INDEX release_notes_tenant_sha`; `ENABLE` and `FORCE ROW LEVEL SECURITY` on `release_notes` with fail-closed `release_notes_tenant_read FOR SELECT` (`NULLIF` per `0021_rls_fail_closed.sql:4-10`) and `operator_scope FOR ALL`; replace `estate_deploys_read` (`USING (true)`) with fail-closed `estate_deploys_tenant_read FOR SELECT` (`NULLIF`) while keeping `operator_scope FOR ALL` for writes (§3.3.1 step 5, §3.3.2 step 4). Remove the time-boxed exemption in `rls_test.go`, `rls_failclosed_test.go`, and `crosstenant_test.go` in the same commit, and add `release_notes` and `estate_deploys` (plus `commit_token_burn`) to `rlsTables` (`rls_test.go:68`), `tenantReadOnlyTables` (`crosstenant_test.go:770`, checked at `rls_failclosed_test.go:228-232`), and the `seedTenantAll` seed (`crosstenant_test.go:779`). | `csi-spl-rdb/src/sql/postgres/spool-hub/<head+3>_release_notes_deploys_rls_contract.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/{rls_test.go,rls_failclosed_test.go,crosstenant_test.go}` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` + RLS tests (`TestRLSCoversEveryTenantTable`, `TestRLSPoliciesFailClosed`, `TestCrossTenantEveryTable`, `TestRLSControl`) proving a tenant-scoped transaction in `t2` reads 0 `t1` rows (including via `/reporting/sql` and Flow) and cannot `INSERT`/`UPDATE`/`DELETE` `release_notes`, `estate_deploys`, or `commit_token_burn`. |
| **Lane 3 — Hub GitHub Sync & Box Ingest (`do_release_note_ingest`)** | **Step 4 (after Lane 2)** | Add per-repo client support to `internal/github` (`SPOOL_HUB_DOCS_EDIT_GITHUB_APP_ID`, `SPOOL_HUB_DOCS_EDIT_INSTALLATION_ID`, `SPOOL_GITHUB_APP_KEY` for `csitea/*` + KMS PAT for external orgs per Q3 `d5b1366a`), refusing sync if `repo_slug` is primary for another tenant, extending `Commits(ctx, n)` with `sinceSHA`/top-dir plus `Tags` and `Releases` + 5-min background sync worker + webhook + "Sync now" button AND box-side `RELEASE_NOTE_TENANT=<WORKSPACE> ./run -a do_release_note_ingest` push in `release-note-ingest.func.sh` / `spl-issue-close-landed.func.sh` / `workspace-repo.inc.sh` (per Q2 `bbad7ba3`, where `RELEASE_ISSUE_TENANT` defaults to `RELEASE_NOTE_TENANT` which defaults to `env.hub.commit_issue_tenant`, and `RELEASE_NOTE_TENANT` is required when `RELEASE_NOTE_REPO_PATH != $APP_PATH`); derive `Area` from `kind(area):` else top changed folder, and ingest trailer-free commits cleanly with subject + body (per Q4 `ab74f79d`). | `csi-spl-api/src/go/spool-hub-api/internal/github/...`, `csi-spl-orc/src/bash/run/{release-note-ingest.func.sh,spl-issue-close-landed.func.sh}`, `csi-spl-orc/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh` | Unit + integration test ingesting a non-`t1` workspace repo and verifying `release_notes.tenant_id`, `issue_tenant`, `issue_keys` (via `issue_counters.prefix`), dynamic `area` fallback from top folder, trailer-free subject/body display, and fail-fast when `RELEASE_NOTE_REPO_PATH != $APP_PATH` without `RELEASE_NOTE_TENANT`. |
| **Lane 4 — WUI dynamic areas, workspace commit links, member-visible commit cost, and unconfigured empty state** | **Step 4 (parallel with Lane 3 after Lane 2)** | Replace hardcoded `RELEASE_AREAS` with `available_areas` from the API; render trailer-free commits with subject + body (Q4 `ab74f79d`); show per-commit and per-pill AI token & EUR cost to every signed-in workspace member (Q5 `331b339b`); bind `ReleaseNotesDialog.vue`, `ReleasesDailyList.vue`, and `commit-links.client.ts` (`setCommitLinkProvider` + `commitLinker`) to the active workspace's `repo_web_url`; render the unconfigured-repo empty state. | `csi-spl-wui/src/utils/reporting-releases.ts`, `src/components/reporting/{ReleasesFilterBar.vue,ReleasesDailyList.vue}`, `src/pages/reporting/releases.vue`, `src/components/ReleaseNotesDialog.vue`, `src/plugins/commit-links.client.ts` | Vitest unit tests + Playwright check on a non-`t1` workspace. |
| **Lane 5 — Onboard the first two production workspaces** | **Step 5 (after Lanes 2b, 3, 4 are live on `dev` and `prd`)** | Register the two customer/product workspace repositories via the hub operator API (`PUT /v1/operator/workspaces/{id}/repos`) and box-side `$SPOOL_ROOT/workspace-repos.tsv` (`WORKSPACE_REPO_SLUG=<ORG>/<REPO>`, never in `csi-spl-cnf` or git), run initial commit + tag backfill, and verify `/reporting/releases`, Flow, commit links, and `<PREFIX>-<n>` issue links live on both workspaces. | Ops (`$SPOOL_ROOT/workspace-repos.tsv` + hub operator API; no git files) | Live curl + browser verification on both workspaces showing their own commits, tags, areas, and issue links with zero `csi-spl` rows. |
