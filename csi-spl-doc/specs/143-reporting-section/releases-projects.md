# Releases: software projects of a workspace, the project drop box (SPL-4963)

Status: **Draft v0.2.3**. Rows B-1 (the schema, SPL-4983), B-2 (store and hub scoped, SPL-5108) and B-3 (the contract, SPL-5475) are built; the rest is not. The owner answered every question (section 9), nothing stays open. Epic SPL-2389.
Amends: [spec.md](spec.md) sections 2 and 6.1, and [spec 171](../171-workspace-own-repo/spec.md) where section 3 says so.
Topic: `93b73456-c662-4785-85ea-00986338a550` (HUM-10, prd t1).

`<WORKSPACE>`, `<BASE_DOMAIN>`, `<ORG>` and `<head+n>` are placeholders. The examples use the made-up project `web-shop`. As in spec.md, "workspace" is the term here; "tenant" appears only in code identifiers.

Why a sibling file and not a long section 2.5: spec.md is already over 1,100 lines and this folder already keeps later additions beside it (`incomes.md`, `expenses-cost-entries.md`, `costs-redesign.md`). Section 2.5 of spec.md points here.

## 1. The owner's words

| msg | text |
|---|---|
| `ae60a8d9` | "the releases tab should be able to track the releases also the development of pre-configured software projects from a drop box switch `https://<WORKSPACE>.<BASE_DOMAIN>/reporting/releases`" (host replaced by placeholders, the rest verbatim) |
| `8262d099` | "the ER model is as follows - each workspace might have 1 or many software projects and each software project might have one or many repos" |
| `cd72fcbd` | "the releases reporting view should be able to show the comits per software project ( which is configured for the workspace where the release is running and not only a single repo" |

## 2. Where this starts from

### 2.1 What runs today

Read on the tree at `7f5c87f35`:

- `release_notes` is estate-wide: no workspace, project or repo column, primary key `sha` alone (`0108_release_note.sql:14`, `:25`). `estate_deploys` is the same, read by everyone (`0202_estate_deploys.sql:42`).
- The hub reads both and drops the caller's workspace (`hub/reporting_releases.go:47`). The filter has no project or repo field (`store/reporting_releases.go:35`).
- The WUI has fixed area pills (`utils/reporting-releases.ts:48`) and no project control (`components/reporting/ReleasesFilterBar.vue:12`).
- Rows reach the table from the deploy-time ingest of this one repo (`csi-spl-orc/src/bash/run/release-note-ingest.func.sh`, `POST /v1/operator/release-notes`, `hub/release_notes.go:67`).

### 2.2 Spec 171 already designs most of the way

[Spec 171](../171-workspace-own-repo/spec.md) (SPL-4808) gives each workspace its own repo and scopes these tables. Its owner decisions bind this file and are not reopened: Q2 ingest (hub polls every 5 min, webhook, "Sync now", and a box may push), Q3 credentials (fleet GitHub App, optional KMS-sealed read-only token per workspace), Q4 (area from the commit scope, else the top folder; commits without trailers show subject and body), Q5 (per-commit cost visible to every member).

Spec 171 is **not built**: `git grep -c workspace_repos origin/master -- csi-spl-rdb csi-spl-api csi-spl-wui csi-spl-orc` prints nothing on 2026-11-07, and `git log origin/master --grep=SPL-4808` shows only `docs(` commits. So this amendment changes its design on paper, with no migration to undo.

Spec 171 stops at workspace -> repo. The owner's ER model puts a project between them. Its Q1 (repos per workspace, poll `4b5869d5`) closed with the owner's answer in msg `24e35756`: many repos, grouped by project, one primary (section 9, Q1).

## 3. What changes in spec 171

Spec 171 stays the authority except for these points. Its Q1 records the answer and points here; the rest of its text is not edited.

| # | Spec 171 says | This file says | Why |
|---|---|---|---|
| A1 | `workspace_repos` hangs directly off the workspace (§3.2) | Each repo row also names its project (section 4) | The owner's ER model |
| A2 | `release_notes` key `(tenant_id, sha)`, and `commit_token_burn` refers to it (§3.3.1 step 3, §3.3.3) | `(tenant_id, repo_slug, sha)`, in both | With several repos, a fork or a split repo shares shas inside one workspace. The narrower key leaves one row for both repos, so one of them loses that commit |
| A3 | Only a primary repo's slug is unique across workspaces (`workspace_repos_primary_slug_idx`) | Every repo slug is unique across workspaces (section 4.3) | Non-primary repos are now normal, and the guard must cover them too |
| A4 | The anonymous release-note read stays, now scoped to the workspace (§3.5 item 2) | Anonymous readers get only repos flagged `notes_public` (section 6.3) | **A private repo would leak.** Those reads are public because the rows come "from the public trunk" (`hub/release_notes.go:35`, SPL-4530). A customer's private repo breaks that premise: its commit subjects would be readable with no session on the workspace's host |
| A5 | One `repo` object on the daily answer (§3.5 item 1) | `project` and `repos[]`, and each commit names its `repo_slug` (section 6.2) | One project shows several repos |
| A6 | Trailer-free commits show "subject and body" (Q4) | `release_notes` gains a `body` column (section 4.3) | The decision stands, but the table has no column to hold a body: `grep -nw body` on the `release_notes` migrations (0108, 0114, 0177, 0261) -> one line, `0261_release_note_issue_keys.sql:14`, a comment |
| A7 | The hub sync writes to `PutReleaseNotes` (§3.4.1) | It writes through `buildRows` (`hub/release_notes.go:160`) | The ban filter and the row checks live there (`:168`); a direct write would skip them |

## 4. ER model and tables

### 4.1 The model

```
workspace 1 --- n software project 1 --- n repo 1 --- n commit (release_notes)
                                              1 --- n deploy (estate_deploys)
```

A repo belongs to exactly one project. Commits attach to the repo, never to the project directly, so moving a repo to another project moves its history with it and rewrites no commit row.

### 4.2 New table `software_projects`

```sql
CREATE TABLE software_projects (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    project_slug text        NOT NULL CHECK (project_slug ~ '^[a-z0-9][a-z0-9-]{0,47}$'),
    name         text        NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    is_default   boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, project_slug)
);

CREATE UNIQUE INDEX software_projects_one_default ON software_projects (tenant_id) WHERE is_default;

ALTER TABLE software_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE software_projects FORCE ROW LEVEL SECURITY;
CREATE POLICY software_projects_tenant_read ON software_projects
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON software_projects
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

The same shape as `workspace_repos`: members read, only the operator scope writes. The slug is the URL value and never changes; `name` may.

The gates that must learn the table: `rlsTables` (`store/rls_test.go`), `tenantReadOnlyTables` and `seedTenantAll` (`store/crosstenant_test.go`), and `notChannelTables` (`channelmove/catalogue.go`).

No archive column in v1: a later forward-only migration can add it when a project first retires.

### 4.3 Changes to spec 171's tables, before they are created

- `workspace_repos`:
  - add `project_slug text NOT NULL` with `FOREIGN KEY (tenant_id, project_slug) REFERENCES software_projects (tenant_id, project_slug) ON DELETE CASCADE`. It cascades because both tables also cascade from `tenants`: a workspace delete must succeed whichever path runs first (B-1 tests it);
  - add `notes_public boolean NOT NULL DEFAULT false` (A4);
  - replace `workspace_repos_primary_slug_idx` with `CREATE UNIQUE INDEX workspace_repos_slug_once ON workspace_repos (repo_slug)` (A3), and drop the plain `workspace_repos_slug_idx` it makes redundant.
- `is_primary` keeps spec 171's meaning, one per workspace: the repo that chat commit links, the settings page and an ingest naming no repo all use. A commit hash in chat still links to the primary repo only, so a hash from another repo gets a wrong link. That is a known v1 limit.
- `release_notes`:
  - Step A adds `CREATE UNIQUE INDEX release_notes_tenant_repo_sha ON release_notes (tenant_id, repo_slug, sha)` in place of spec 171's `release_notes_tenant_sha`, and Step C makes it the primary key. It must be an index and not a `UNIQUE` constraint: `ADD PRIMARY KEY USING INDEX` refuses a constraint's index with `index "..." is already associated with a constraint`. Built (B-3, `*_release_notes_deploys_rls_contract.sql`): the key keeps the name `release_notes_pkey`, so the index is renamed to it, and a write that names no workspace now fails (no `t1` default);
  - add `body text NOT NULL DEFAULT '' CHECK (length(body) <= 2000)` (A6);
  - add `CREATE INDEX release_notes_tenant_repo_time ON release_notes (tenant_id, repo_slug, committed_at DESC)` for the report's window.
  - Step A does not rebuild `release_notes_release_key`: B-2's migration does, as amended in spec 171 section 3.3.1 step 4, because the old hub's list needs the old index until then.
- `commit_token_burn`: `repo_slug` joins its primary key and its foreign key (A2).
- No foreign key from `release_notes` or `estate_deploys` to `workspace_repos`, as in spec 171. The ingest refuses a `repo_slug` the workspace has not registered, extending spec 171's `409 repo_not_registered`.
- Reporting's SQL tab admits `software_projects` and `workspace_repos`, a recorded choice: they hold a workspace's own rows and no secret column, so an admin there can read that workspace's `auth_mode`, `github_installation_id`, `live_url` and `sync_error`, which the member-facing projects answer (section 6.1) leaves out. `estate_deploys` stayed refused there until B-3: from B-1 it had a `tenant_id` but its read policy was still `USING (true)`. From B-3 `release_notes` and `estate_deploys` read through `app.tenant_id`, so the tab admits both, scoped to the workspace.

### 4.4 How csi-spl maps in

- Workspace `t1`, as spec 171's core invariant says (`hub.commit_issue_tenant`, `all.env.yaml:722`). One project, slug `csi-spl`, `is_default = true`, with one repo `csitea/csi-spl`, `is_primary = true`, `notes_public = true`.
- Spec 171's seed gains the project row, in the same operator-scope block and with the same no-op on a database with no `t1`.
- Every existing row gets `repo_slug = 'csitea/csi-spl'` by spec 171's backfill. Nothing else moves.
- Every other workspace stops seeing csi-spl rows, as the owner already required (spec 171 msg `0fcabe44`).

### 4.5 How a project is pre-configured

Decided: **the operator registers, workspace admins do not** (section 9, Q2).

- Not cnf: `csi-spl-cnf` is in this public repo, and a customer's repo name must not ship in it (`lane-issue-and-docs.md` section 5).
- Not a workspace admin form in v1: the fleet GitHub App can read every repo it is installed on, so a free-typed slug could point one workspace at another's private repo. Spec 171 made `repo_slug` operator-only for this reason.
- The path: `PUT /v1/operator/workspaces/{id}/projects/{project}` (name, default flag) and spec 171's `PUT /v1/operator/workspaces/{id}/repos`, now with a required `project_slug`. Driven by the box action `do_workspace_repo_register` with `WORKSPACE_PROJECT=<slug>` as a new required input. It fails fast when the input is missing, with no default.
- A workspace's first project becomes its default. A project with no repo yet is not listed by the reads, so "1 or many repos" holds for what a member sees.

## 5. Ingest

Spec 171 §3.4 stands (sync, webhook, box push, credentials). This file only adds what several repos need.

- **Per repo**: `last_synced_sha`, `version_tag_glob`, `trunk_branch` and the credential already sit on each repo row, so the sync treats two repos of a project as two independent walks.
- **Identity**: read-only (Contents and Metadata) through the App installation or the row's sealed token, as Q3 decided. This file names no credential or key path.
- **Trailers are optional** outside csi-spl (Q4). A trailer-free commit stores its body (A6) and state `skip`, not `missing`: per spec 065, `missing` means a commit bypassed the trailer rule, and that rule does not bind another project's repo. The parser (`hub/release_notes_parse.go:110`) takes this from the repo row, never from the repo's name.
- **Tags as versions**: as csi-spl does it, a commit's version is the first tag on trunk that contains it, within that repo only. `released_at` comes from the GitHub Release's publish time when one exists, else the time the sync first saw the tag. An untagged commit has `version` NULL and counts as unreleased.
- **Other git hosts**: `provider` allows them, but the hub syncs only GitHub in v1. Any other host uses the box push (`auth_mode = 'ingest_only'`).
- **No default URLs**: the box action requires `WORKSPACE_REPO_SLUG`, `WORKSPACE_REPO_WEB_URL` and `WORKSPACE_PROJECT`, each `: "${VAR:?...}"`. The hub's API base stays the cnf value (`github_api`, `all.env.yaml:895`).
- **Personal data**: the sync stores no commit author name or email, as `release_notes` holds none today. The body passes the same ban filter as the rest of the row.

## 6. API

### 6.1 The list for the drop box: `GET /v1/reporting/releases/projects`

Mounted beside the two reads (`routeReportingReleases`, `hub/reporting_releases.go:36`), with its `OPTIONS` route and its `openapi.json` entry. The projects of the caller's workspace, default first, then by name:

```json
{
  "configured": true,
  "default": "web-shop",
  "projects": [
    {
      "slug": "web-shop",
      "name": "Web shop",
      "is_default": true,
      "repos": [
        { "slug": "<ORG>/web-shop-api", "web_url": "https://example.com/<ORG>/web-shop-api", "commit_path": "/commit/", "trunk_branch": "main", "sync_status": "ok", "last_synced_at": "2026-11-07T06:00:00Z" }
      ]
    }
  ]
}
```

With no project: `{"configured": false, "default": "", "projects": []}`, and the WUI shows spec 171's empty state. `auth_mode`, `github_installation_id`, `live_url` and `sync_error` stay out of the answer.

### 6.2 The filter on both reads

`GET /v1/reporting/releases/daily` and `/commits` gain:

| param | meaning |
|---|---|
| `project` | a project slug of the caller's workspace. Absent: the workspace's default project. Never "every project" (section 9, Q5) |
| `repo` | optional, a repo slug of that project. Absent: every repo of the project |

- The hub resolves them to a repo list and passes it as a new `Repos []string` on `ReleaseReportFilter`. The store **refuses an empty list** rather than reading everything, so a bug fails closed.
- Bad shape: `400 bad_query`, as today. A project or repo the workspace does not have: `404 unknown_project` / `404 unknown_repo`, the same answer whether it does not exist or belongs to another workspace, so the status reveals nothing.
- No project configured: `200` with `configured: false` and no days.

The daily answer adds, and each day gains `repos`:

```json
{
  "configured": true,
  "project": { "slug": "web-shop", "name": "Web shop" },
  "repos": [ { "slug": "<ORG>/web-shop-api", "web_url": "https://example.com/<ORG>/web-shop-api", "commit_path": "/commit/", "sync_status": "ok", "last_synced_at": "2026-11-07T06:00:00Z" } ],
  "unreleased_commits": 14,
  "days": [ { "date": "2026-11-07", "commits_count": 9, "repos": { "<ORG>/web-shop-api": 6, "<ORG>/web-shop-wui": 3 } } ]
}
```

(`days` is cut down here; its other fields stay as in spec.md 2.4.1, plus spec 171's `available_areas` and `available_kinds`.)

Three existing behaviours change with this:

- `total_versions` counts distinct `(repo_slug, version)`. It counts the version string alone today (`store/reporting_releases.go:185`), which would make two repos' `v1.0.0` one release.
- Deploys on a day are those of the selected repos. Each deploy and each commit names its `repo_slug`, and a commit's link comes from its own repo.
- Without a deploy report a project's days keep the existing neutral "Deploys: not recorded".

### 6.3 Release notes page and Flow

These stay single-repo in v1, which keeps the change small: the modal list, `GET /v1/release-notes` and the Flow release lines read the workspace's **primary repo** only. Otherwise two repos' `v1.0.0` would merge into one version and share one read mark (`f:rel:<version>`, `store/flow_fold.go:164`).

`GET /v1/release-notes/{ref}` takes an optional `repo`, so a commit row from another repo can open its own note. It must belong to the workspace; absent means primary.

**Anonymous readers (A4)**: with no member session (`releaseReader`, `hub/release_notes.go:186`), these reads return rows of repos with `notes_public = true` only. A workspace whose primary repo is not flagged answers an anonymous reader with an empty list, and `/releases/<ref>` with 404. A member session reads every repo of the workspace.

### 6.4 Access (spec.md 6.1)

Access comes through the workspace (owner, msg `cf6a27b3`, section 9, Q4): a member of a workspace reads the releases of every repo of that workspace's software projects. There is no per-repo or per-project access list.

- **Member**: reads the projects and both reports, as the Releases tab admits today (`humanTenant`, `hub/reporting_releases.go:47`), and the release notes of every repo of the workspace (section 6.3).
- **Reader with no login**: sees only repos flagged `notes_public`, and only through the release-note reads of section 6.3. The projects route and both reports refuse them, as the reports do today (`hub/reporting_releases.go:52`). A session of someone who is not a member of this workspace counts as no login.
- **Cost fields** follow spec 171's Q5. **Registration** is operator scope only (section 9, Q2).

B-5 must change one thing for this to hold: today `releaseReader` reads no session when the page names a workspace, and every visitor gets the member's answer (`hub/release_notes.go:181`). It has to read the session on such a page, or it cannot tell a member from a reader with no login.

## 7. WUI

### 7.1 The drop box

- A `<select>` first in the filter bar (`ReleasesFilterBar.vue:12`), hook `data-test="releases-project"`, loaded once from the projects route.
- One project: its name as plain text, no control. No project: spec 171's empty state and no filter bar.
- A project with more than one repo also shows a repo row of pills with counts, the same pattern as kinds and areas, hook `releases-repo-<slug>`. One pill on filters to that repo.
- Commit rows and deploy chips show the repo's short name only when the project has more than one repo, so csi-spl looks as it does now.

### 7.2 The URL

- `?project=<slug>&repo=<org/name>`, read on load and written with `router.push` on a pick, so a link keeps the pick and Back undoes it. Only these two go into the URL; range and pills stay as they are.
- No param: the workspace's default, and the URL stays clean.
- A stale param (404 from the hub): fall back to the default with `router.replace`, no error shown.
- Picking a project clears `repo` and the area picks, since areas differ per project, and keeps kinds, range and search.
- The label cloud's cache key must include project and repo: today it is range and search only (`pages/reporting/releases.vue:74`), so a switch would show the last project's counts.
- `releaseQuery` (`utils/reporting-releases.ts:70`) sends the two params. `mockReleaseReport` (`:318`) gains two projects, one with two repos, because the offline e2e runs only on the mock.

### 7.3 What "development" shows in v1

The owner asked for "the releases also the development". v1 adds no new view, only what the rows already hold:

- commits per day across the project's repos (the existing day list, now per project);
- a new KPI card, `14  -  Unreleased`, commits in the window that no tag carries yet, in the existing one-line card form (spec.md 2.2);
- commits per repo, as counts on the repo pills.

Open work is left out of v1 (section 9, Q6): nothing links an issue to a project, and guessing one from commit citations would miss every issue not yet cited.

## 8. Build rows

One row, one lane, in this order. Rows B-1 to B-3 and B-6 are spec 171's Lanes 1, 2, 2b and 3 **as amended here**, so they replace those lanes rather than run beside them. Spec 171's expand, deploy, contract order is kept: no non-`t1` registration before B-3 is live on dev and prd. Spec 171 Lane 4 (dynamic areas, empty state, workspace commit links) runs with B-7 and goes through the same language review.

| ID | Area | Summary | Test | Red control |
|---|---|---|---|---|
| B-1 | `rdb` | Spec 171 Lane 1 plus `software_projects`, the columns and indexes of 4.3, and the `t1` project seed | `PRE_PUSH_TIER=full ./run -a do_check_pre_push`; the RLS and catalogue gates name the new table; deleting a workspace with a project and a repo succeeds | A second default project in one workspace, and one repo slug registered in two workspaces, each fail on their unique index |
| B-2 | `api` | Spec 171 Lane 2: store and hub scoped by workspace, upserting on `(tenant_id, repo_slug, sha)`; its migration rebuilds `release_notes_release_key` guarded | Spec 171 Lane 2's list, plus the same sha stored in two repos of one workspace keeps two rows | With spec 171's two-column key, the shared-sha test reads one row |
| B-3 | `rdb` | Spec 171 Lane 2b: contract, the three-column primary key | Spec 171 Lane 2b's list; the shared-sha rows survive the swap | A second row with the same workspace, repo and sha fails on the primary key |
| B-4 | `api` | Store: `ReleaseProjects`, `Repos` on the filter, the unreleased count, per-repo day counts, versions counted per repo, in the Postgres and Memory drivers | Store tests: one project's report excludes the other's commits; two repos' `v1.0.0` count as 2 | An empty `Repos` must return an error; a store that reads everything on it fails the test |
| B-5 | `api` | Hub: the projects route, `project` and `repo` params, `repo_slug` on commits, `notes_public` on anonymous reads, `repo` on `{ref}`, primary-only modal and Flow, operator project route, `openapi.json` | Hub tests per section 6, including a member of workspace A asking for B's project gets 404 | An anonymous read of a private repo's note must be empty; returning it fails the test |
| B-6 | `api`, `orc` | Spec 171 Lane 3: sync and box push per repo through `buildRows`, trailer-free state `skip` with `body`, `WORKSPACE_PROJECT` on `do_workspace_repo_register` | Sync test on a two-repo fixture with tags: versions stay per repo; `.tst.sh` for the action | The action run without `WORKSPACE_PROJECT` must exit non-zero; a row synced around `buildRows` keeps a banned word and fails |
| B-7 | `wui` | Drop box, repo pills, URL params, Unreleased card, cloud key, mock; pushed to `review/<slug>` with all 19 locales drafted, **not landed** until B-8 passes | `pnpm run typecheck`, unit tests, `BASE_URL=<bundle> pnpm run test:e2e` at 1440 and 390 px: pick, reload keeps it, Back undoes it, stale param falls back | A cloud key without the project shows the old project's counts after a switch; the e2e must see that fail |
| B-8 | `i18n` | agy language review of B-7's keys as the last step before they ship, per the language rule. Then B-7 lands | `i18n-parity`, `i18n-untranslated` and `i18n-no-raw-text` gates green | A missing key in one locale fails `i18n-parity` |
| B-9 | ops | Register the first real projects through the operator route, then verify live on dev and prd | Live read of both reports on one workspace: only its own commits, zero csi-spl rows | The same read from a second workspace on the first one's project answers 404 |

Keys B-7 adds: `reporting.releases.project_label`, `repo_label`, `kpi_unreleased`. `grep -c reporting csi-spl-wui/src/utils/i18n-first-screen.mjs` -> 0, so they should stay out of the first-screen catalogue. That is unmeasured, so B-7 still runs the WUI budget check before it lands.

If agy is still out of quota when B-7 is ready (the brief for this amendment puts its return at about 2026-11-10), B-7 waits on its review branch and does not land.

## 9. The owner's answers

Form `baeb59f7`, complete in msg `24e35756` (HUM-10, 2026-11-07 06:39:23Z): all six A, the recommended answer of v0.1.0. Nothing stays open. "Section 9, Qn" means this list; a bare Q2..Q5 in sections 2, 3 and 5 is spec 171's.

1. **Does your ER message close spec 171's open Q1 (repos per workspace)?** Yes, msg `24e35756`: "A — Yes: several repos per workspace, grouped by project, one primary repo for chat commit links". Spec 171 section 5 records it.
2. **Who registers a project and its repos?** The operator, msg `24e35756`: "A — Only the operator in v1 (you or an agent); a workspace admin form later, since a typed repo name could reach another workspace's private repo". See section 4.5.
3. **Which workspace holds csi-spl?** `t1`, msg `24e35756`: "A — t1 only, and each repo in exactly one workspace". The workspace of the owner's link gets its own projects. See sections 4.3 and 4.4.
4. **May anyone without a login read a private repo's release notes?** No, msg `24e35756`: "A — No: public only for a repo flagged public, as csi-spl is. This narrows your SPL-4530 \"release notes are public\" for private customer repos". See section 6.3.
   **Which members may read them?** Every member of the workspace, msg `cf6a27b3`: "well if the person does have access to the workspace and the the workspace does have access to the repos of this software project , than the members will have access to the repos of this software project". This is the later word: it replaces the note in msg `01bbead4` (06:38:29Z), which spoke of members "having access to that repo". See section 6.4.
5. **Should the drop box have an "All projects" entry?** No, msg `24e35756`: "A — Not in v1: it mixes unrelated versions and deploys". See sections 6.2 and 7.1.
6. **Should v1 show open work?** No, msg `24e35756`: "A — Not yet: v1 shows commits per day, unreleased commits and commits per repo". See section 7.3.

### 9.1 What the answers change in sections 4.5 and 8

No build row changes, and neither does the path in section 4.5; each answer is the recommendation they were drafted on.

- **Answer 2**: section 4.5 and rows B-5, B-6 and B-9 already register through the operator route only.
- **Answer 3**: the seed of section 4.4 and B-1's red control (one repo slug in two workspaces fails) already hold it.
- **Answer 5**: no row builds an "All projects" entry, and B-4's empty `Repos` refusal stands.
- **Answer 6**: B-7's Unreleased card and repo pills are what the answer lists, and no row builds open work.
- **Answer 4 with msg `cf6a27b3`**: no row builds a per-repo list. B-5's `notes_public` row stands, and section 6.4 names what it must read.

<!-- version: 0.2.3 · updated: 2026-11-14 -->
