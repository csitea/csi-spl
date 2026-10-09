# 112 Goals, strategy and roadmap: tasks

Authority for what is built. `spec.md` holds the behaviour; this file follows its sections.
Each task names its layer, its dependency, the files it owns, a Done line
(what runs, what it prints, and a control that must fail), a vendor hint
(spec 110 D5: doc and low-level = mistral, hardest coding and secrets =
claude, multilingual text = agy review last) and a box hint (new lanes are
placed by the orchestrator; Postgres tests need the box's docker Postgres,
browser e2e needs Chrome or runs in CI on the mock bundle).
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

Version **v1.1**: v1.0 plus the build tasks for spec section 12 (per-workspace
roadmaps, spec v1.2 with OQ1-OQ3 answered): RDB-2, DOC-2, HUB-2, HUB-3,
WUI-3, ORC-5, ORC-6 are new; WUI-1 and ORC-2 are re-split; WUI-2, I18N-1 and
ORC-4 keep their scope. The lane split is section 7.

Order: ORC-1 first (everything reads it); RDB-1 lands and is applied to dev
and prd BEFORE STORE-1/HUB-1 ship; WUI-1 after ORC-1; WUI-2 after HUB-1.
Section 12: RDB-2 is applied to dev and prd BEFORE HUB-2 ships; ORC-2,
ORC-5, ORC-6, WUI-3 and HUB-3 come after HUB-2.

**Audience glossary** (calendar `audience`, in the words of c-723's rename;
before it, `workspace` was spelled `public` and `public` was spelled `web`):
`private` = the creator and the mentions; `internal` = the workspace's
members, guests dropped; `workspace` = everyone in the workspace, guests
included; `public` = `workspace` plus signed-out visitors. Spec 12.5's
"internal by default, override to public" is `internal` / `public` here.
The v1.0 "`public`" of spec 4.3 and 8.1 (goal, milestone, release and spec
events) meant `workspace`; 12.5 supersedes it.

## 1. Documentation

- [x] **DOC-1**: Goal and strategy templates.
  - Depends: none.
  - Owns: `csi-spl-doc/goals/template-strategy.md`, `csi-spl-doc/goals/template-goal.yaml`, `csi-spl-doc/goals/README.md`, `csi-spl-doc/goals/milestones.yaml` (the hand-listed first-of-its-kind milestones, 8.1, starting with `2026-09-17 spool-hub started`).
  - Done: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` prints no finding for `csi-spl-doc/goals/`; the templates have the spec 2/3 fields and carry the owner as a role id, never a name (D2). Control: a planted personal name in a copy of the template turns the gate red.
  - Vendor: mistral drafts, agy reviews the language last. Box: any.

- [ ] **DOC-2**: A goal names its workspace (spec 12.2, 12.3, 12.4).
  - Depends: DOC-1.
  - Owns: `csi-spl-doc/goals/template-goal.yaml`, `csi-spl-doc/goals/README.md`.
  - Done: the template has `workspace: "<workspace slug>"` (required, no default); `owner_role` reads `biz_owner or admin`; the README says a goal's events land in its `workspace` only and that a `biz_owner` or `admin` of that workspace approves it (12.3); the comment on `public:` says it is D1's repo-doc flag, never the calendar audience (the audience is the workspace switch, RDB-2). `do_check_dist_hygiene` prints nothing for `csi-spl-doc/goals/`. Control: `grep -c '^workspace:' csi-spl-doc/goals/template-goal.yaml` -> 1 (0 on today's file).
  - Vendor: mistral. Box: any.

## 2. Roadmap counts (one rule)

- [x] **ORC-1**: `do_spl_spec_progress` (spec 5.1).
  - Depends: none.
  - Owns: `csi-spl-orc/src/bash/run/spl-spec-progress.func.sh`, `csi-spl-orc/src/bash/tests/spl-spec-progress.tst.sh`, its fixture tree under `csi-spl-orc/src/bash/tests/fixtures/spec-progress/`.
  - Done: `./run -a do_spl_spec_progress` prints TSV `spec state x p o pct`, one row per spec dir, and a total line naming the sha; on `fecc09693` with 112 left out it reads 16 done / 59 in-progress / 14 no-boxes / 0 planned / 22 no-tasks (5.2). `--sha <ref>` reads `git archive`; `--json` writes the `roadmap.json` shape. Test: a fixture with one spec per state plus a spec whose only open box is `[~]`, which must read `in-progress` with pct = floor(100 x / (x+p+o)). Control: counting `[~]` as done turns that case red.
  - Vendor: mistral (low-level bash). Box: any.

## 3. Data model and hub

- [x] **RDB-1**: Migration `<next>_calendar_source_key.sql` (spec 4.2).
  - Depends: none. Apply to dev and prd before STORE-1/HUB-1 deploy.
  - Owns: `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_calendar_source_key.sql` (claim the number at build time; `ls … | tail -1` -> `0155_mistral_kind.sql` today).
  - Done: `calendar_events.source_key text NULL`, partial unique index `(tenant_id, source_key) WHERE source_key IS NOT NULL`, `kind` CHECK widened with `goal` and `milestone`; forward-only and additive; the migration catalogue gate is green. Control: inserting two rows with the same `(tenant_id, source_key)` fails; two NULL keys succeed.
  - Vendor: claude. Box: one with docker Postgres.
  - Landed: `0156_calendar_source_key.sql` in `961dbaaaf` (v4.0.1), test `TestCalendarSourceKey0156` (n=8 inserts; control: a non-unique index turns it red). `/version` schema_head `0156_calendar_source_key.sql` on dev and prd.

- [x] **STORE-1**: Store support for synced events (spec 4.2, 4.3).
  - Depends: RDB-1.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/store/calendar_sync.go`, `calendar_sync_test.go` (memory + Postgres parity), the `calendarKinds` line in `internal/store/calendar.go`, and the allow-list assertion in `TestPublicExportGrantsEqualAllowList`.
  - Done: `UpsertCalendarBySourceKey` upserts by key and soft-deletes a `goal:`/`spec:` key missing from the batch; the same test runs green on memory and Postgres (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`). Controls: a `db:%` key with audience `public` is refused; `calendar_events` added to the 091 allow-list turns the allow-list test red; a re-run of the same batch leaves the row count unchanged.
  - Vendor: claude. Box: one with docker Postgres.
  - Landed: `0198be10c` (v4.0.4), `internal/store/calendar_sync.go`; `TestCalendarSyncBySourceKey` green on memory and Postgres (n=2 drivers x 8 syncs). Controls, each red with its guard removed: db: key audience public refused; same batch re-run = 4 unchanged, row count kept; `calendar_events` on the allow-list fails `TestPublicExportGrantsEqualAllowList`. Hub on dev and prd serves `0198be10`.

- [x] **HUB-1**: Sync route, read-only synced events, approval check (spec 4.1, 4.2, D2).
  - Depends: STORE-1.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/calendar_sync.go`, `calendar_sync_test.go`, the 409 guard in `internal/hub/calendar.go`, the `source_key` prefix filter on the event list; cnf keys `env.roadmap.tenant_id` and `env.roadmap.approver_role` in `csi-spl-cnf/csi-spl/all.env.yaml` (no default).
  - Done: `PUT /v1/calendar/sync` upserts as `creator_type = 'system'`, `creator_id = 'roadmap-sync'` for the deploy identity and answers 403 for a human or agent seat; a goal whose `approval.msg_id` is missing, or not authored by a holder of `approver_role` in the roadmap workspace, is returned as `unapproved` and writes no event; PATCH or DELETE on an event with `source_key` set answers 409; `?source_key=goal:G01:` lists only that goal's events. Controls: an agent token gets 403; an approval message from a non-admin member writes nothing; a missing `approver_role` cnf key fails the sync fast.
  - Vendor: claude (auth). Box: one with docker Postgres.
  - Landed: `f6aa81630` (route, `internal/hub/calendar_sync.go`) + `f2fb2eeeb` (cnf `env.roadmap.*` = `~`, 030 passes them as `SPOOL_HUB_ROADMAP_*`), v4.0.6 on dev and prd. Deploy identity = the operator ID token; a seat is 403 `deploy_identity_only`. Finding 1: the route prunes only the key families the request carries (a family it leaves out, goal: or spec:, is carried unchanged; one it carries is carried whole). Finding 2: `source_key` on the read path + `CalendarBySourceKey` (`internal/store/calendar_source.go`). `calendar_sync_test.go` 5 tests green on memory and Postgres; controls, each red with its guard removed: agent token 403; a non-admin approval writes nothing; missing `approver_role` 503 `roadmap_not_configured`; a release:-only batch deletes 0 and carries the goals. Both cnf values wait on the owner (the sync answers 503 until set).
  - Amended by spec 12.2-12.4: HUB-2 replaces the one cnf workspace and the one cnf role; the 503 `roadmap_not_configured` goes with them.

- [ ] **RDB-2**: Migration `<next>_tenant_roadmap_public.sql`, the roadmap visibility switch (spec 12.5, OQ3).
  - Depends: none. Apply to dev and prd before HUB-2 deploys.
  - Owns: `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_tenant_roadmap_public.sql` (claim the number at build time; `ls … | tail -1` -> `0158_calendar_web_audience.sql` today, c-723's rename may claim the next one).
  - Done: `tenants.roadmap_public boolean NOT NULL DEFAULT false`, the 0129 `marketing_enabled` pattern (catalog-only ADD COLUMN, RLS unchanged); forward-only and additive; the migration catalogue gate is green. Control: a fresh tenant row reads `roadmap_public = false` (a `DEFAULT true` turns the test red).
  - Vendor: claude. Box: one with docker Postgres.

- [ ] **HUB-2**: Sync over several workspaces, per-workspace approval and audience (spec 12.2, 12.3, 12.4, 12.5).
  - Depends: HUB-1, RDB-2.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/calendar_sync.go`, `calendar_sync_test.go`; the `roadmap_public` read and its switch route (`PATCH /v1/workspaces/<slug>/roadmap` `{public: bool}`, `biz_owner` or `admin` of that workspace only) with its store method and test; removal of cnf `env.roadmap.tenant_id` and `env.roadmap.approver_role` from `csi-spl-cnf/csi-spl/all.env.yaml` and of their `SPOOL_HUB_ROADMAP_*` passthrough in wf 030.
  - Done: each event and each goal in the `PUT /v1/calendar/sync` body names its `workspace`; the route upserts per workspace by `(tenant_id, source_key)` and prunes per workspace; an approval counts when its message is in the goal's own workspace and its author holds `biz_owner` or `admin` there (`rbac.RoleIDs`, no cnf); a `goal:`, `release:` or `spec:` event (deadlines and milestones included) carries no audience in the request (400 if it does) and is written `internal`, or `public` when that workspace's `roadmap_public` is true; flipping the switch re-audiences that workspace's synced non-`db:` events in the same transaction; `db:` stays `internal` (4.3). Unchanged: deploy identity only, idempotent, 409 on a synced event. Test on memory and Postgres. Controls, each red with its guard removed: the same `goal:G01:deadline` in two workspaces gives two rows, never one; a `biz_owner` approval and an `admin` approval each write the goal, a `member` approval writes nothing; an `admin` of workspace A approving a goal of workspace B writes nothing; a sync event with `audience: workspace` is refused; a `member` gets 403 on the switch route.
  - Vendor: claude (auth). Box: one with docker Postgres.

- [ ] **HUB-3**: In-app goals for a workspace with no repo (spec 12.2 OQ1, 12.8).
  - Depends: HUB-2; spec 113 workspace docs (0157) live.
  - Owns: a goal-doc reader in `csi-spl-api/src/go/spool-hub-api/internal/hub/roadmap_goal_docs.go` and its test: a spec 113 workspace doc marked as a goal carries the `template-goal.yaml` fields (DOC-2); saving one runs the same approval check and upsert as HUB-2 for that workspace, with `creator_id = 'roadmap-sync'`.
  - Done: a workspace with no repo gets the same `goal:<id>:deadline` and `goal:<id>:m:<key>` events from its in-app goal doc as a repo workspace gets from `goal.yaml`; the spool's own roadmap is just another workspace (OQ2, no special case). First step: a five-line shape note in this task (which doc field marks a goal) agreed with the spec 113 lane before code. Control: an unapproved in-app goal writes no event; a goal doc in workspace B never writes into A.
  - Vendor: claude. Box: one with docker Postgres.

## 4. WUI

- [ ] **WUI-1**: Roadmap page, spec rows (spec 5, 5.1, 5.3 (b), 9). Re-split by spec 12: the goal parts moved to WUI-3.
  - Depends: ORC-1.
  - Owns: `csi-spl-wui/src/node/roadmap/sync-roadmap.mjs` (runs before `nuxt generate`, calls `do_spl_spec_progress --json`, writes `public/roadmap.json` with spec rows ONLY, never a goal: a goal's audience is a runtime per-workspace switch, 12.5, that a build-time file cannot honour), `csi-spl-wui/src/pages/roadmap.vue`, `csi-spl-wui/src/components/Roadmap*.vue` (the spec-row table), the existing e2e file it extends, and a 25 KB gzip roadmap route budget in `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`.
  - Done: one row per spec dir (no-tasks rows included); `/roadmap?when=week|month` filters by the `tasks.md` change date (5.3 (b)); `pnpm run typecheck` green; `perf-budget.py bundle` shows the initial chunk unchanged in bytes and the roadmap route chunk <= 25 KB. Test: e2e on the mock bundle with a fixture `roadmap.json`, at desktop and <= 820 px, in both themes. Controls: the filter toggle changes the visible row count in the fixture; `import`ing `roadmap.json` instead of fetching it turns the initial-chunk check red; a fixture `goal.yaml` next to the specs leaves `grep -c '"goals"' public/roadmap.json` at 0.
  - Vendor: claude. Box: one with Chrome for local e2e, else CI.

- [ ] **WUI-3**: Workspace filter, goal rows and the goal page from the hub (spec 5.3 (a), 6, 12.6).
  - Depends: WUI-1, HUB-2 (and ORC-2 for real data; the mock serves fixture events).
  - Owns: `csi-spl-wui/src/pages/goals/[id].vue`, the workspace filter and goal rows in `csi-spl-wui/src/components/Roadmap*.vue` that WUI-1 does not own (name the files at build time, disjoint from WUI-1's), the mock's synced-event fixtures, the e2e file it adds.
  - Done: `/roadmap?ws=<slug>&when=week|month&goal=G01` (the filter in the URL, 12.6); the workspace list holds only the workspaces the viewer is a member of, plus the host workspace's roadmap when it is `public` (read signed-out via the public calendar read); goal rows and the goal page (countdown, approval state, done-lines, share-done, mean pct, 6) read the `goal:<id>:` events of that workspace (`?source_key=goal:G01:`, HUB-1) joined with the spec rows of `roadmap.json`. Test: e2e on the mock, signed in as a member of A only and signed out, at desktop and <= 820 px. Controls: a fixture workspace B the viewer is not in never appears in the filter; signed out, an `internal` roadmap shows no goal row.
  - Vendor: claude. Box: one with Chrome for local e2e, else CI.

- [ ] **WUI-2**: Synced events read-only in the calendar (spec 4.1, 4.4).
  - Depends: HUB-1.
  - Owns: the synced-event branch in `csi-spl-wui/src/components/CalendarMainView.vue` and its event dialog; links to `/roadmap?goal=…#spec-…` from `props.roadmap_url`.
  - Done: an event with `source_key` shows no edit button and no drag, and a "change it in the repo" link; the roadmap row opens `/calendar?d=<iso>&event=<id>`. Test: e2e on the mock. Control: a synced event in the fixture with the edit button visible turns the test red.
  - Vendor: claude. Box: one with Chrome for local e2e, else CI.
  - Spec 12: scope unchanged. The roadmap link is `props.roadmap_url` as ORC-2 writes it (now with `ws=<slug>`); WUI-2 follows it, never builds it.

- [ ] **I18N-1**: `roadmap.*` and `goal.*` strings in all 19 locales (spec 9).
  - Depends: WUI-1 and WUI-3 strings frozen.
  - Owns: the new keys in `csi-spl-wui/i18n/locales/*`.
  - Done: every locale has every new key (the i18n parity test green); agy signs off last. Control: a key missing in one locale turns the parity test red.
  - Vendor: agy (final word on languages). Box: any.

## 5. Sync and backfill actions

- [ ] **ORC-2**: Deploy-time goal sync, per workspace (spec 4.2, 12.2, 12.4). Re-split by spec 12: the git backfill moved to ORC-5.
  - Depends: HUB-2, DOC-2.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-sync.func.sh` (`do_spl_goals_sync`), its `.tst.sh`, and the wf 20 step that calls it after the hub deploy.
  - Done: reads every `goal.yaml`, takes each goal's `workspace`, and PUTs one batch whose events and goals each name their workspace; it sends NO audience (HUB-2 sets `internal` or `public` from the workspace switch); `props.roadmap_url` = `/roadmap?ws=<slug>&goal=G01#spec-089` and the deadline event's props carry the goal's `specs` and `done_lines` (WUI-3 reads them); a second run adds 0 events. Test against a stub route on a fixture with goals in two workspaces. Controls: a goal without `workspace` fails the run before any call; a batch that carries an `audience` on a `goal:` key turns the test red.
  - Vendor: mistral. Box: any.

- [ ] **ORC-5**: Git backfill, per workspace (spec 8.1, 12.7). Split out of ORC-2.
  - Depends: HUB-2, DOC-1.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh` (`do_spl_goals_backfill_git`), its `.tst.sh`.
  - Done: `: "${WORKSPACE:?WORKSPACE must be set (no default)}"` first; builds the batch (`x.y.0` tags, release notes, specs turned done, `milestones.yaml`, starting at 2026-09-17) for that one workspace with no audience (HUB-2 sets it) and PUTs it to the sync route; the first event is `2026-09-17 spool-hub started`; a second run adds 0 events. Test on a fixture repo: tags `v1.2.0`, `v1.2.1`, `v1.3.0` give exactly 2 release events. Controls: a patch tag counted as major turns the test red; an unset `WORKSPACE` exits non-zero before any call.
  - Vendor: mistral. Box: any.

- [x] **ORC-3**: DB backfill candidates, tenant-scoped (spec 8.2).
  - Depends: none for the read; HUB-1 for writing the kept ones.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-backfill-db.func.sh` (`do_spl_goals_backfill_db`), `csi-spl-orc/src/bash/tests/goals-backfill-db.tst.sh`.
  - Done: fails fast without `WORKSPACE`; runs `BEGIN TRANSACTION READ ONLY` with `SET LOCAL app.tenant_id` and no rls_scope; writes candidates `topic_id, msg_id, ts, kind, quote` (quote <= 140 chars, owner messages only) to a 0600 file under `$HOME`; kept ones are sent as `db:<topic_id>`, audience `internal`. Test on Postgres: two workspaces seeded, run in A, the output holds none of B's topic ids. Control: B's rows exist, counted as the operator.
  - Vendor: claude (DB content and personal data). Box: one with docker Postgres.
  - Status: the READ half is built (c-605): `do_spl_goals_backfill_db` writes the candidates; "owner" = a member holding `APPROVER_ROLE` / cnf `env.roadmap.approver_role` (D2); a login that bypasses RLS is refused. Test green on Postgres, with the operator-count control. The WRITE half is built (c-616): `KEPT_FILE=<the pruned 0600 candidates file>` PUTs the kept rows to `/v1/calendar/sync` as one `db:<topic_id>` event per topic, audience `internal`, as the env SA's id token; the batch carries only the `db:` family (no `goals[]`, a `goal:`/`spec:`/`release:` key is refused before the call), so the route prunes nothing; `WORKSPACE` must be cnf `env.roadmap.tenant_id`. Test A5 against a stub route, with the `goal:` control. The live call waits for the owner's `env.roadmap.*` (503 `roadmap_not_configured` until then).

- [ ] **ORC-6**: DB backfill without the one cnf workspace (spec 12.2, 12.3, 12.7).
  - Depends: HUB-2 (it removes `env.roadmap.*`).
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-backfill-db.func.sh`, `csi-spl-orc/src/bash/tests/goals-backfill-db.tst.sh`.
  - Done: the write half drops the `WORKSPACE == cnf env.roadmap.tenant_id` check (today line 83-85) and names `WORKSPACE` in each `db:` event of the batch; the read half counts messages of members holding `biz_owner` or `admin` in `WORKSPACE` (12.3) instead of `APPROVER_ROLE` / cnf `env.roadmap.approver_role` (today line 41); `WORKSPACE` stays required with no default; isolation unchanged (read-only, tenant-scoped, candidates under `$HOME`, `db:` = `internal`). Test on Postgres. Controls: an unset `WORKSPACE` fails fast; a `member`'s message is never a candidate; B's topic ids never appear in a run in A (ORC-3's control kept).
  - Vendor: claude (DB content and personal data). Box: one with docker Postgres.

## 6. Retrospective

- [ ] **ORC-4**: Retrospective trigger (spec 7).
  - Depends: ORC-2.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-retrospective.func.sh` (`do_spl_goals_retrospective`), its `.tst.sh`.
  - Done: for a goal whose deadline passed and that has no `retrospective.md`, it sends one spool task to a mistral lane with `do_spl_spec_progress --sha <deadline sha>` attached, and an agy review task after it; the public part passes `do_check_dist_hygiene`; owner quotes go only to the spool post. Test: a fixture goal with yesterday's deadline gives exactly one task; a goal with a retrospective gives none. Control: a goal with tomorrow's deadline must give no task; one given turns the test red.
  - Vendor: mistral (the action is plain bash). Box: any.
  - Spec 12: scope unchanged; it reads every `goal.yaml` whatever its `workspace`, and the retrospective task names that workspace.

## 7. Lane split (v1.1)

One lane per row; a lane starts when its "starts after" tasks are landed. The
lanes own disjoint files; WUI-1 and WUI-3 share `Roadmap*.vue` and so run one
after the other, never side by side.

| lane | tasks | vendor | starts after |
|---|---|---|---|
| L1 | WUI-1 | claude | now (ORC-1 is landed) |
| L2 | WUI-2 | claude | now (HUB-1 is landed) |
| L3 | the 12.x hub task: RDB-2 then HUB-2 (one lane, the migration is applied to dev and prd before the hub ships) | claude | now |
| L4 | ORC-2 (with DOC-2 first, a mistral doc commit in the same lane) | mistral | L3 |
| L5 | ORC-4 | mistral | L4 |
| L6 | ORC-5 | mistral | L3 |
| L7 | ORC-6 | claude | L3 |
| L8 | WUI-3 | claude | L1 and L3 |
| L9 | HUB-3 | claude | L3 and the spec 113 shape note |
| L10 | I18N-1 | agy | the WUI lanes L1, L2, L8 (strings frozen) |
