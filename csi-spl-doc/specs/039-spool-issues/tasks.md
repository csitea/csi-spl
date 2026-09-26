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
- [ ] T004 WUI store/state wiring (CLE-34993): `stores/issues.ts`, client
      calls, the `issue` / `issue_label` frames
- [ ] T005 WUI (GRK-3519): rail tab third after Channels, middle list, right
      detail with the deadline calendar + time, shortcuts, 19 locales
- [x] T006a agents (FR-008): box socket issue frames (issues-v1 §6),
      `hubclient.Issue`, `action.Issue`, `spool issue`; issue topics left out
      of every topic list (§7). The commit adding this line;
      `internal/hub/issues_agent_test.go` (TestAgentIssues, with the CONTROL
      that the store still holds the topic), store TestIssueTopicsHidden on
      both drivers; TestRoundTripsPerRequest unchanged on Postgres
- [ ] T006b MCP tool `spool_issue`, desk actions `do_spl_issue_create` /
      `do_spl_issue_update` / `do_spl_issue_comment`
- [ ] T007 version bump + deploy dev and prd (`/version` + `build.json`)
- [ ] T008 live proof dev + prd: create, edit status / priority / level /
      assignee / deadline, grouping, reload keeps it; screenshots in the topic
