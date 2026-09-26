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
- [ ] T005 WUI (GRK-3519): rail tab third after Channels, middle list, right
      detail with the deadline calendar + time, shortcuts, 19 locales
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
- [ ] T007 version bump + deploy dev and prd (`/version` + `build.json`)
- [ ] T008 live proof dev + prd: create, edit status / priority / level /
      assignee / deadline, grouping, reload keeps it; screenshots in the topic
