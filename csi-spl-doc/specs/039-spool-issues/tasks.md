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
<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
