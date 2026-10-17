# Blocker issues go under one epic per workspace (SPL-2409)

Owner HUM-10, t1 7a98c2d1 (msgs ef77b762 + 5863d0d6): no issue without an
epic and a git spec. The hub's blocker rule (spec 135 section 8, c-350) made
every unanswered blocker an issue with no parent: SPL-2404 on prd t1, found by
c-367 (msg c111a7ce).

## 1. What the hub does

- Every issue the hub makes of a blocker, by the sweep (`SweepBlockerIssues`)
  or by the owner's "Make an issue" (`POST /v1/messages/{msg_id}/issue`), goes
  under the workspace's blocker epic. Both pass through `blockerIssueOn`
  (`csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go`).
- The blocker epic is the oldest open, live epic titled exactly
  `Area: unanswered blockers - issues with no spec` (`hub.BlockerEpicTitle`).
  On prd t1 that is SPL-2394, made by hand on 2026-10-17.
- With none open, the hub makes one (kind epic, linked to the blocker's
  topic), on the topic `hub.BlockerEpicTask(tenant, prev)`: derived from the
  tenant and the number of the hub's epic before it (0 for the first). Two hub
  processes walk the same chain, and issues' UNIQUE (tenant_id, task_id) lets
  one of them make it: never two open at once.
- An epic closes and archives itself with its issues when its last open
  issue closes (SPL-1729, owner poll 954cd02f). The next blocker then makes
  the next epic on the chain. Unarchiving an old epic is how to read its
  resolved blocker issues.
- A hand-made epic is found by its title only: renamed, the hub no longer
  uses it. An epic the hub made is also found by its chain topic, renamed or
  not, while it is open.

Code: `internal/hub/blocker_issue_epic.go`. Tests (memory, and Postgres under
`SPOOL_TEST_PG_DSN`): `internal/hub/blocker_issue_epic_test.go`.

## 2. The owner exception, unchanged

The sweep files no issue for a workspace owner (spec 135 section 9 Q2). The
code reads the `tenant_owner` flag over the member's whole role set
(`rbac.accessOf`): a member is the owner when any role of the set is a
`tenant_owner` role. Spec 025 section 2: "tenant owner = biz-owner", and
"there is no separate owner flag on the membership". So `biz_owner` alone or
with `admin` is the owner; `admin` alone is not
(`TestBlockerOwnerExceptionReadsTheRoleSet`).

Measured on prd t1, 2026-10-17 (`ENV=prd TENANT_ID=t1 ./run -a
do_spl_hub_member_list`, read-only): HUM-10's primary role is `admin`; two
other members hold `biz_owner`. That action prints the primary role only, not
the role set; SPL-2404 was filed for HUM-10, so his set holds no
`tenant_owner` role today. Covering him is a decision, not a code fix; it is
reported to the dispatch holder (task `dispatch-7a98c2d1`).
