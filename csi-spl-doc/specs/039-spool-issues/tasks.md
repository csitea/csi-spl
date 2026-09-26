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

<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
