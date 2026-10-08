# 112 Goals, strategy and roadmap: tasks

Authority for what is built. `spec.md` holds the behaviour; this file follows its sections.
Each task names its layer, its dependency, the files it owns, a Done line
(what runs, what it prints, and a control that must fail), a vendor hint
(spec 110 D5: doc and low-level = mistral, hardest coding and secrets =
claude, multilingual text = agy review last) and a box hint (new lanes are
placed by the orchestrator; Postgres tests need the box's docker Postgres,
browser e2e needs Chrome or runs in CI on the mock bundle).
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

Version **v1.0**.

Order: ORC-1 first (everything reads it); RDB-1 lands and is applied to dev
and prd BEFORE STORE-1/HUB-1 ship; WUI-1 after ORC-1; WUI-2 after HUB-1.

## 1. Documentation

- [x] **DOC-1**: Goal and strategy templates.
  - Depends: none.
  - Owns: `csi-spl-doc/goals/template-strategy.md`, `csi-spl-doc/goals/template-goal.yaml`, `csi-spl-doc/goals/README.md`, `csi-spl-doc/goals/milestones.yaml` (the hand-listed first-of-its-kind milestones, 8.1, starting with `2026-09-17 spool-hub started`).
  - Done: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` prints no finding for `csi-spl-doc/goals/`; the templates have the spec 2/3 fields and carry the owner as a role id, never a name (D2). Control: a planted personal name in a copy of the template turns the gate red.
  - Vendor: mistral drafts, agy reviews the language last. Box: any.

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

- [ ] **HUB-1**: Sync route, read-only synced events, approval check (spec 4.1, 4.2, D2).
  - Depends: STORE-1.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/calendar_sync.go`, `calendar_sync_test.go`, the 409 guard in `internal/hub/calendar.go`, the `source_key` prefix filter on the event list; cnf keys `env.roadmap.tenant_id` and `env.roadmap.approver_role` in `csi-spl-cnf/csi-spl/all.env.yaml` (no default).
  - Done: `PUT /v1/calendar/sync` upserts as `creator_type = 'system'`, `creator_id = 'roadmap-sync'` for the deploy identity and answers 403 for a human or agent seat; a goal whose `approval.msg_id` is missing, or not authored by a holder of `approver_role` in the roadmap workspace, is returned as `unapproved` and writes no event; PATCH or DELETE on an event with `source_key` set answers 409; `?source_key=goal:G01:` lists only that goal's events. Controls: an agent token gets 403; an approval message from a non-admin member writes nothing; a missing `approver_role` cnf key fails the sync fast.
  - Vendor: claude (auth). Box: one with docker Postgres.

## 4. WUI

- [ ] **WUI-1**: Roadmap and goal pages (spec 5, 5.3, 6, 9).
  - Depends: ORC-1 (and HUB-1 for the calendar links; without it the links are hidden).
  - Owns: `csi-spl-wui/src/node/roadmap/sync-roadmap.mjs` (runs before `nuxt generate`, calls `do_spl_spec_progress --json`, adds goals from `goal.yaml`, writes `public/roadmap.json`), `csi-spl-wui/src/pages/roadmap.vue`, `csi-spl-wui/src/pages/goals/[id].vue`, `csi-spl-wui/src/components/Roadmap*.vue`, the existing e2e file it extends, and a 25 KB gzip roadmap route budget in `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`.
  - Done: one row per spec dir (no-tasks rows included); `/roadmap?when=week|month&goal=G01` filters as 5.3; the goal page shows countdown, approval state, done-lines, share-done and mean pct; `pnpm run typecheck` green; `perf-budget.py bundle` shows the initial chunk unchanged in bytes and the roadmap route chunk <= 25 KB. Test: e2e on the mock bundle with a fixture `roadmap.json`, at desktop and <= 820 px, in both themes. Controls: the filter toggle changes the visible row count in the fixture; `import`ing `roadmap.json` instead of fetching it turns the initial-chunk check red.
  - Vendor: claude. Box: one with Chrome for local e2e, else CI.

- [ ] **WUI-2**: Synced events read-only in the calendar (spec 4.1, 4.4).
  - Depends: HUB-1.
  - Owns: the synced-event branch in `csi-spl-wui/src/components/CalendarMainView.vue` and its event dialog; links to `/roadmap?goal=…#spec-…` from `props.roadmap_url`.
  - Done: an event with `source_key` shows no edit button and no drag, and a "change it in the repo" link; the roadmap row opens `/calendar?d=<iso>&event=<id>`. Test: e2e on the mock. Control: a synced event in the fixture with the edit button visible turns the test red.
  - Vendor: claude. Box: one with Chrome for local e2e, else CI.

- [ ] **I18N-1**: `roadmap.*` and `goal.*` strings in all 19 locales (spec 9).
  - Depends: WUI-1 strings frozen.
  - Owns: the new keys in `csi-spl-wui/i18n/locales/*`.
  - Done: every locale has every new key (the i18n parity test green); agy signs off last. Control: a key missing in one locale turns the parity test red.
  - Vendor: agy (final word on languages). Box: any.

## 5. Sync and backfill actions

- [ ] **ORC-2**: Deploy-time goal sync and git backfill (spec 4.2, 8.1).
  - Depends: HUB-1, DOC-1.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-sync.func.sh` (`do_spl_goals_sync`), `csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh` (`do_spl_goals_backfill_git`), their `.tst.sh`, and the wf 20 step that calls the sync after the hub deploy.
  - Done: both build a batch (goal deadlines and milestones; `x.y.0` tags, release notes, specs turned done, `milestones.yaml`, starting at 2026-09-17) and PUT it to the sync route with audience `public`; the first event is `2026-09-17 spool-hub started`; a second run adds 0 events. Test on a fixture repo: tags `v1.2.0`, `v1.2.1`, `v1.3.0` give exactly 2 release events. Control: a patch tag counted as major turns the test red.
  - Vendor: mistral. Box: any.

- [~] **ORC-3**: DB backfill candidates, tenant-scoped (spec 8.2).
  - Depends: none for the read; HUB-1 for writing the kept ones.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-backfill-db.func.sh` (`do_spl_goals_backfill_db`), `csi-spl-orc/src/bash/tests/goals-backfill-db.tst.sh`.
  - Done: fails fast without `WORKSPACE`; runs `BEGIN TRANSACTION READ ONLY` with `SET LOCAL app.tenant_id` and no rls_scope; writes candidates `topic_id, msg_id, ts, kind, quote` (quote <= 140 chars, owner messages only) to a 0600 file under `$HOME`; kept ones are sent as `db:<topic_id>`, audience `internal`. Test on Postgres: two workspaces seeded, run in A, the output holds none of B's topic ids. Control: B's rows exist, counted as the operator.
  - Vendor: claude (DB content and personal data). Box: one with docker Postgres.
  - Status: the READ half is built (c-605): `do_spl_goals_backfill_db` writes the candidates; "owner" = a member holding `APPROVER_ROLE` / cnf `env.roadmap.approver_role` (D2); a login that bypasses RLS is refused. Test green on Postgres, with the operator-count control. **The write half (send the kept ones as `db:<topic_id>`, audience `internal`) waits for HUB-1.**

## 6. Retrospective

- [ ] **ORC-4**: Retrospective trigger (spec 7).
  - Depends: ORC-2.
  - Owns: `csi-spl-orc/src/bash/run/spl-goals-retrospective.func.sh` (`do_spl_goals_retrospective`), its `.tst.sh`.
  - Done: for a goal whose deadline passed and that has no `retrospective.md`, it sends one spool task to a mistral lane with `do_spl_spec_progress --sha <deadline sha>` attached, and an agy review task after it; the public part passes `do_check_dist_hygiene`; owner quotes go only to the spool post. Test: a fixture goal with yesterday's deadline gives exactly one task; a goal with a retrospective gives none. Control: a goal with tomorrow's deadline must give no task; one given turns the test red.
  - Vendor: mistral (the action is plain bash). Box: any.
