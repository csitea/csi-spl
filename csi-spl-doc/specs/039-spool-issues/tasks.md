# Tasks: 039 Issues

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 rdb 0047 (`issue_counters`, `issue_labels`, `issues`, RLS 0021 form
      + operator policy) and `store.Issues` on memory + Postgres. `37582373`;
      `internal/store/issues_test.go` (TestIssues, TestIssueNumbersConcurrent,
      TestParseIssueRef) on both drivers; cross-tenant seed covers the tables
- [x] T002 rdb 0047 applied: dev and prd, `do_spl_db_bootstrap`
      (`applied 0047_issues.sql`), 2026-09-26 ~06:37Z, before any hub reads it
- [x] T003 hub REST + live frames (issues-v1 §1..§5). this commit;
      `internal/hub/issues_test.go` (TestIssuesCreateReadPatchLive - red with
      the fan-out tenant filter removed, TestIssuesPreflight); api run-all-tests green
- [x] T004 WUI state wiring (CLE-34993): spool-client issue calls + mock,
      `utils/issues.mjs` (grouping, sort / filters mirroring the hub, frames,
      deadline bridge), shims. `10387c41`; `tests/unit/issues.test.mjs`.
      No pinia store: agreed with GRK-3519, the page owns its state and the
      frame handlers in live-ws.mjs / useLive.ts
- [x] T005 WUI (GRK-3519): rail tab third after Channels, middle list,
      right detail with the calendar + time deadline, shortcuts, 19 locales.
      `33891193`; comment send over the tab socket + `?issue=<key>` deep
      link `a3d71ab7` / `618d437d` (reviewed by CLE-34993; the comment
      defect was found by the T008b proof)
- [x] T006a agents (FR-008): box socket issue frames (issues-v1 §6),
      `hubclient.Issue`, `action.Issue`, `spool issue`; issue topics left out
      of every topic list (§7). The commit adding this line;
      `internal/hub/issues_agent_test.go` (TestAgentIssues, with the CONTROL
      that the store still holds the topic), store TestIssueTopicsHidden on
      both drivers; TestRoundTripsPerRequest unchanged on Postgres
- [x] T006b MCP tool `spool_issue` (seated: acts as its seat only), desk
      actions `do_spl_issue_create` / `do_spl_issue_update` /
      `do_spl_issue_comment` / `do_spl_issue_list` (shared leg
      `lib/bash/funcs/spl-desk-issue.func.sh`). The commit adding this line;
      mcp TestToolNamesAreCanonical (six names) + TestSeatedIssueTool,
      spool-smoke, `csi-spl-orc/src/bash/tests/desk-actions.tst.sh` section 9;
      012 cli-mcp-map amended (five + spool_issue)
- [x] T007 hub bump 0.6.9 -> 0.7.0 `a90f16b8`; run 36225417807 deployed dev
      and prd, smoke green; `/version` on dev.api and api both read commit
      `a90f16b8` / 0.7.0 (2026-09-26 07:06Z). WUI build.json: with T005
- [x] T008a live proof, agent path, prd t1, n=1, hub 0.7.0: CLE-34993
      `do_spl_issue_create` -> SPL-1 (in_progress, priority 2, level 4,
      deadline 18:00Z), `do_spl_issue_comment` -> msg 6ef5db9d, list -> counts
      in_progress 1; DB: issues row + comment is_parent 0, channel tasks,
      from CLE-34993
- [x] T008b live proof in the WUI, signed in, `tests/e2e/issues-live.proof.mjs`,
      WUI `618d437d` + hub 0.7.0 `a90f16b8`, n=1 per env, 2026-09-26 ~08:00Z:
      dev tenant t1 12/12 PASS; prd test tenant e2e 12/12 PASS (steps 1-8:
      third tab, create, list without description, status / priority /
      level / assignee / calendar+time deadline, second tab live, comment,
      reload, `?issue=` link). The first prd run failed step 5 once, before the
      proof waited for the second tab's socket (not measured whether it was
      open then). Screenshots (8) posted in topic 9c19bfe9, msg 35b89cc3

- [x] T009 SPL-18 epics: rdb 0049 (orphans -> "random" epic), the epic rule
      in store (both drivers; an update meets it only when it changes the
      parent or labels), `kind` / `epic` in issues-v1 + `epic=` / `kind=`
      filters + the `epics` summary (§8), `spool issue --epic/--kind`,
      ISSUE_EPIC / ISSUE_KIND, MCP fields. The commit adding this line;
      store TestIssueEpicRule (memory + pg), TestMigration0049EpicBackfill
      (pg, incl. a second pass), hub TestIssueEpics, desk-actions.tst.sh §9;
      api run-all-tests ALL PASSED
- [x] T010 SPL-18 WUI: left-most panel lists the epics (done / open count +
      progress bar, All issues), a click filters the list (`?epic=`), the list
      shows issues only, the create form requires an epic (defaults to the
      selected one) or makes an epic, an epic picker in the detail. The
      commit adding this line; tests/unit/issues.test.mjs (SPL-18 block),
      tests/e2e/issues.test.mjs 9/9 on the mock, typecheck, unit 105/105.
      Sends `parent` / the `epic` label, so it works on hub 0.7.x before the
      roll (an older hub refuses unknown body fields)
- [x] T010b owner 09:08 (topic 070843ba) - hub: rdb 0053 `kind` (epic |
      feature | issue), the three-level rule on both drivers, `kind` subtask +
      `epic` = level-1 ancestor in the JSON, `kind` / `epic` / `parent`
      filters, features in the summary, `spool issue --kind feature --parent`,
      ISSUE_KIND feature. The commit adding this line; store TestIssueEpicRule
      (three levels, memory + pg), hub TestIssueThreeLevels
- [x] T010c WUI: features next to epics in the left-most panel ("Epics and
      features", a kind dot), the create form cycles issue / epic / feature,
      a level-2 issue lists its subtasks in the right pane and adds one, a
      subtask links to its parent. Fixed on the way: spool-client's private
      issueQuery copy never sent kind / epic / parent (the list only looked
      right because the page re-filters) - a unit test now pins the copy to
      issues.mjs. The commit adding this line; unit 107/107, e2e 13/13 (mock)
- [ ] T010d the done git-specs imported into the tree: SPL-76, GRK-3523 (not
      this lane)
- [x] T011 SPL-18 live: rdb 0049 + 0053 on dev and prd (do_spl_db_bootstrap,
      applied before each roll); hub 0.7.3 `bfe7a790` then 0.7.4 `3fc78449`
      served on dev.api and api (/version); WUI `5166575f` on dev and apex
      (build.json); after the roll 0 epic-labelled rows left kind issue and
      0 issues without a valid parent on dev t1, prd t1, prd e2e. Signed-in
      proof `tests/e2e/issues-live.proof.mjs`, n=1 per env: dev t1 16/16,
      prd test tenant e2e 16/16 (steps 9-12: the level-1 panel, a feature made
      in the UI, an issue under it, a subtask in the right pane, the panel's
      count). Earlier prd runs failed step 9 (the check took an empty list as
      an answer) and step 4 once (the check read the hub before the deadline
      PATCH landed; step 7 saw it stored) - both proof-side, both fixed
- [x] T012 owner topics 32a56460, d81cbf47, f2c32da2 (2026-09-26): deadline
      a date + 24-hour time 07:00-22:00 (`53c42204`); prio 1..5 and the six
      statuses 01-eval..09-done with hover names: rdb 0054 + 0055 on dev and
      prd, backend `48096860`, hub 0.7.8 served on dev.api and api; WUI
      `4e389e3c` on dev and apex (build.json); the title filter is gone
      (`f901ebd5`). Proof n=1 per env: dev t1 18/18, prd e2e 18/18. Unmeasured:
      whether Chrome paints the native option title
- [x] T013 SPL-949 (owner topic e5759793): level is the tree's, 1 epic /
      feature, 2 issue, 3 subtask. rdb 0056 backfill + CHECK (level IN
      (1,2,3)) applied on dev and prd after hub 0.7.9 (`a9b45ebc`) was served;
      the store derives level on every write; WUI `b8f37e5c` shows it
      read-only. Group-by tenant/kind/level with an off-tree count, n=1 per
      env, after the migration: dev t1 epic 1 x1, feature 1 x3, issue 2 x17,
      issue 3 x3; prd csi-rel 1 x1 / 2 x2, e2e 1 x5 / 2 x14 / 3 x4, t1 1 x42 /
      2 x907; off_tree 0 on every row (before: levels 0..4, 965 of 975 prd rows
      off the tree). Signed-in proof issues-live.proof.mjs, n=1 per env: dev
      t1 19/19, prd e2e 19/19 (level read-only 2, feature 1, subtask 3)
- [x] T014 SPL-966 (owner 2026-09-26): statuses 05-blocked (blocked) and
      06-onhold (onhold) in every tenant, between 03-diss and 07-qas. rdb 0061
      (one CHECK, rows unchanged) applied on dev and prd at 16:24Z / 16:29Z
      after hub 0.8.8 (`e162bb78`, served inside 0.8.9 `73dc5691`); WUI
      `80aeb7dc` (red no-entry / grey pause glyphs, hover texts in 19 locales).
      Probe after the WUI deploy, 16:32:33-16:36:01Z, 72 requests: / and /login
      on spool-hub.ai and dev.spool-hub.ai 200 every time. Proof n=1, prd e2e
      at https://e2e.spool-hub.ai: 23/23 (8b: the row shows 05-blocked then
      06-onhold, the hub holds each). Incident: two earlier runs from the apex
      wrote SPL-967..970 into prd t1 (tenant hosts: the apex is t1's host);
      the proof now refuses to write unless claim t and the page host are
      TENANT (`6c080b57`)
- [x] T015 SPL-1027 (owner 2026-09-28, prd t1 topic 89485c7a): the right
      pane is gone; above 820 px an issue opens in a modal (FR-011); the sheet
      is fully CRUD inline (FR-010); delete is a soft delete (FR-009, rdb
      0071, DELETE /v1/issues/{ref}); phones unchanged (SPL-992)
  - [x] T015a spec + contract + rdb 0071 (`c9fc985f`), applied on dev and prd
        (`do_spl_db_bootstrap` printed `applied 0071_issue_soft_delete.sql`;
        information_schema lists deleted_at / deleted_by in both)
  - [x] T015b hub DELETE route, store soft delete, `op: delete` frame
        (`025a7ddd`, hub 1.3.6 on dev.api and api); TestIssueSoftDelete
        memory + postgres, TestIssuesDelete
  - [x] T015c WUI modal + inline CRUD sheet + cell cursor (`4390d22b`,
        `76530c3e`: keyboard pickers anchor to their control). Mock e2e on
        the generated bundle: issues-crud-modal 40/40 (1440 + 1024),
        issues 32/32, issues-mobile 48/48, issue-dock-comment 21/21
  - [x] T015d live, WUI 76530c3e (1.4.4) on dev and apex, hub 025a7ddd:
        `issues-crud-modal-live.proof.mjs` n=1 per env - dev t1 19/19, prd
        e2e (https://e2e.spool-hub.ai) 19/19; every row it made was deleted
        and reads 404 at the hub
- [x] T016 SPL-1028 (owner 2026-09-28, topic 89485c7a): views List | By
      status (FR-012), remembered per person
  - [x] T016a rdb 0072 humans.issues_view (`673200dd`), applied on dev and prd
        (`applied 0072_human_issues_view.sql` both)
  - [x] T016b hub: issues_view in auth.ViewPrefs, the session claim, PUT
        preferences (`200b4901`, hub 1.4.7 on dev.api and api);
        TestPreferencesIssuesView, store both drivers
  - [x] T016c WUI switch, status groups (count, fold, +, drag) (`6ad50d87`,
        `d73829ec`: the header row was a narrow flex box from a stale rule);
        mock e2e issues-views 11/11
  - [x] T016d live, WUI d73829ec (1.4.9) on dev and apex:
        `issues-views-live.proof.mjs` n=1 per env - dev t1 9/9, prd e2e 9/9
        (the view stored at the hub, a reload keeps it, a group's +, a drag
        = a status at the hub, its row deleted, the person's view restored)
<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
