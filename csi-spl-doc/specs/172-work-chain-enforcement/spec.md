# 172 The work chain: discussion -> issue -> lane -> agent, no bare issue, lane or agent

Version: v0.3 (2026-11-05), evaluation only: nothing below is built. Issue
SPL-4867 · Epic SPL-2403 · Class feature · Kind specs_and_docs · Task
`dispatch-b0f50875` · Placement slug `c002-spec-enforce-discussion-chain-claude`
· Author c-192.

Number: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`
-> `171-workspace-own-repo`, `README.md`; the same listing over every
`origin/review/*` branch shows no `172-*`, so this is 172.

Tree: every claim about code was read on origin/master `45c7424d9`. Every
prd number is ONE read-only read (n = 1) on 2026-11-05 between 14:10Z and
14:40Z with `cd csi-spl-orc && ENV=prd SQL="<the statement shown>" ./run -a
do_spl_db_query`; the statements are given in short form.

Paths: `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`, `orc/` =
`csi-spl-orc/src/bash/`, `sa/` = `orc/features/spawn-agents/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`.

## 1. The rule

The owner's words, verbatim (HUM-10, csitea `b0f50875`, msg `4ef793d6`,
2026-11-04 11:2xZ): "like evaluate the total change of the enforcing of the
links between the discussions /topics the issues and the lanes aka bare
discussions CAN exist , but bare agents instantiated without lanes no - even if
the lanes are some common activities - fo r example orchestration or
dispatching , bare lanes cannot exist , they must have issues , bare issues
cannot eixst , they must be derived from discussions".

Earlier rules it extends:

- t1 `f94e07bf`, msg `33f8eecb` (2026-10-27): "each lane must have at least 1
  link to an issue WHAT It is doing and at least 1 link to a discusion from
  where did it originated".
- t1 `fcf09921`, msgs `3e75e13e` and `62f96f94`: "Issues must be linked to one
  or more discussions", "that link in the database should be enforced"
  (rdb 0194, SPL-1593).
- t1 `0c2d08a2`, msg `937e89a4`: "for the already nulls , do not use resources
  to search what they were related to -, use the unknown string".
- t1 `ef94396b`, msgs `61bf7791` and `dd164168`: a commit's issue links "at
  least 1 discussion where this issue originated from", and "after this
  feature has completed the usage of the unknown hsould be forbidden" (gate
  SPL-4789, `do_spl_commit_links_check`: the workspace default is not such a
  discussion). So a new issue that links only the default is a bare issue:
  decided, not an owner choice.

As one chain:

| link | rule | today |
|---|---|---|
| discussion | may stand alone | yes |
| issue -> discussion | every issue is born of a discussion; the workspace's catch-all default is not a discussion it was born of | the DB demands >= 1 link, but the default counts (section 2.1) |
| lane -> issue, discussion | every lane row names its issue and its discussion | the placer refuses since SPL-4797; other writers write blanks (2.4) |
| agent -> lane | every running agent runs one lane row, role seats included | role seats run bare rows by design (2.2) |

## 2. Measured today

### 2.1 Issues with no origin discussion

The link table is `issue_discussions` (rdb 0194): a pair of DEFERRED
constraint triggers refuses an issue with no link at COMMIT
(`grep -c 'CREATE CONSTRAINT TRIGGER' rdb/0194_issue_discussions.sql` -> 2).
So "no link" cannot happen: the 0-link count is 0 in every workspace. A bare
issue today is one whose only link is the workspace's default discussion
(`store.IssueDiscussionDefault`: t1 `fcf09921`, any other workspace its "Issue
backlog" topic, `spool_issue_backlog_id`).

`select tenant_id, count(*), count(*) filter (where only_default) ... from
issues left join issue_discussions ... group by 1`:

| workspace | issues | 0 links | only the default | only the default, open | only the default, created last 7 d | created last 7 d |
|---|---|---|---|---|---|---|
| t1 | 4867 | 0 | 3012 | 257 | 279 | 618 |
| w2 | 522 | 0 | 522 | 176 | 0 | 0 |
| w3 | 104 | 0 | 103 | 70 | 0 | 0 |
| csitea | 67 | 0 | 42 | 15 | 0 | 12 |
| e2e | 50 | 0 | 50 | 43 | 0 | 0 |
| w4 | 20 | 0 | 0 | 0 | 0 | 0 |
| csi-rel | 19 | 0 | 14 | 0 | 0 | 5 |
| w5 | 18 | 0 | 15 | 2 | 0 | 0 |
| w6 | 15 | 0 | 0 | 0 | 0 | 4 |
| w7 | 2 | 0 | 2 | 0 | 0 | 0 |
| demo | 1 | 0 | 1 | 1 | 0 | 0 |

Workspaces other than t1, csitea, csi-rel, e2e and demo read w2..w7 (the
repo is public). "Open" = not deleted, status not `done` / `diss`. No
workspace but t1 had a
bare issue born in the last 7 days.

Who files t1's new bare issues (last 7 days, by `created_by`):

| filer | issues | only the default | of those, the description's first `/t/` names another topic | no `/t/` at all |
|---|---|---|---|---|
| g-002 (dispatch seat) | 268 | 162 | 32 | 0 |
| c-002 (dispatch seat) | 238 | 84 | 6 | 2 |
| c-003 (failover seat) | 42 | 19 | 16 | 2 |
| c-001 (orch seat) | 64 | 14 | 8 | 0 |
| a lane | 4 | 0 | 0 | 0 |
| g-001 | 1 | 0 | 0 | 0 |

The rows add up to 617 of the 618: one issue is not classed.

So every bare issue of the week was filed by a role seat, for a lane it
placed. 213 of 279 name `/t/fcf09921` first (4 name no `/t/` at all): the brief named no
discussion the reader takes, and `spl_lane_issue_place`
(`orc/run/spl-lane-issue.func.sh`, lines 286-288) took the default with only
a `WARN brief ... names no topic: the issue links the default discussion`.
This lane's own issue is one: SPL-4867 links only `fcf09921` (`select number,
task_id from issue_discussions where tenant_id='t1' and number=4867`), although
its brief says `Owner topic: csitea b0f50875-...`, a topic of another
workspace. Why that line was not taken I did not check. The commit-links
gate (2.4, last row) then refused this spec's own commit on its first pre-push:
`FATAL commit ... SPL-4867 links no discussion of its own (only the t1 backlog
topic)`. So today a lane is placed on a bare issue and finds out only when it
pushes; G1 moves that refusal to the birth. The dispatch holder (c-002, msg `be197317`) then
tried to link the brief's topic: the t1 hub refused `b0f50875` with
`unknown_discussion` (its messages are only in csitea), so a t1 issue cannot
link another workspace's discussion today; it linked the t1 topic `0c2d08a2`
on the same rule instead (`select number, task_id from issue_discussions where
tenant_id='t1' and number=4867` -> `0c2d08a2`, `fcf09921`). That refusal is
what Q1 decides. The 62 that name
another topic and still link only the default are not classed here.

### 2.2 Lanes with no issue or no discussion

`fleet_lanes` holds no NULL: `topic` and `issue_key` are `NOT NULL DEFAULT ''`
(`\d fleet_lanes`), so "none" is the empty string.

`select ... from fleet_lanes where state='live' group by <age of updated_at>`:

| last write | live rows | no topic | no issue | BOX-0 rows | scope `role <id> (rotation ...)` | scope `seat <id> (restart ...)` |
|---|---|---|---|---|---|---|
| < 1 day | 31 | 7 | 8 | 2 | 5 | 1 |
| 1-7 days | 17 | 9 | 5 | 0 | 5 | 3 |
| > 7 days | 132 | 125 | 130 | 0 | 4 | 3 |

65 of the live rows carry a legacy id (`CLE-`, `AGY-`, `QWN-`). Of the 31 rows
written in the last day, every gap is a role seat (c-001 on both boxes,
c-002 on box A, c-003 on both boxes), a BOX-0 heartbeat row (both boxes), or
g-002 on box B, a seat restart with a topic and no issue. Every lane launched that
day by the placer has both. The 132 rows older than 7 days are lanes long gone
whose row was never set `done`; the hub prunes only `done` rows
(`rdb/0096_fleet_lanes.sql` header).

### 2.3 Agents with no lane row

Running agents on box A (this lane's box): `tmux list-windows -a` -> 12 ids (c-001, c-002, c-003,
c-100, c-164, c-172, c-187, c-188, c-189, c-191, c-192, c-613), each with a
live row. On box B, from its BOX-0 heartbeat (`live=` in its row's scope,
written 14:15Z; its tmux not read from box A): 16 ids, each with a live row.
So n agents with no lane row = 0 today. The gaps are that the role seats' rows
are bare (5, both boxes), and that two start paths write no row at all (2.4:
identity restore, and a put that fails in the background).

### 2.4 How each kind is born today

| kind | birth path | file | link handling |
|---|---|---|---|
| issue | REST `POST /v1/issues`, WUI form, agent spool frame `create` | `api/hub/issues.go` `handleCreateIssue` -> `createIssue`; `api/hub/issues_agent.go` `agentCreateIssue`; `csi-spl-wui/src/composables/useIssueDetailForm.ts` | refuses none (`discussion_required` in `api/hub/issue_discussions.go` `discussionsFor`; `legacyCreateDefault = false`); the WUI blocks it too; the default topic passes as a discussion |
| issue | lane issue at spawn | `orc/run/spl-lane-issue.func.sh` `spl_lane_issue_place` (from `sa/scripts/spawn-window.sh` `sw_issue`) | **default**: no topic in the brief -> the workspace default, WARN only |
| issue | desk and scripts | `orc/run/spl-issue-create.func.sh` `do_spl_issue_create` (callers: alert tick, vendor terms check, epic backfill, spec import) | `ISSUE_DISCUSSIONS` or a `/t/` in the text required; the default passes |
| issue | hub: unanswered blocker sweep, "Make an issue" | `api/hub/blocker_issue.go` `blockerIssueOn`, `blocker_issue_make.go` | derived: the blocker's topic |
| issue | hub: blocker epic, cascade bug | `api/hub/blocker_issue_epic.go`, `api/hub/issue_epic_close.go` | derived; the cascade may fall back to the default |
| lane | the placer | `orc/run/spl-spawn-place.func.sh` `spl_spawn_place_no_links` | **refuses** no discussion / no issue (SPL-4797) |
| lane | hand spawn | `sa/scripts/spawn-window.sh` `sw_issue` -> `sa/scripts/spawn-core.inc.sh` `_spawn_lane_put` | refuses no issue (exit 12); **no discussion check**; the put runs in the background, best effort, and writes blanks |
| lane | enqueue | `orc/run/spl-spawn-enqueue.func.sh` | refuses no `Epic:`/`Spec:` pair, and since SPL-5325 no discussion too (`spl_spawn_q_enqueue_links` runs the placer's `spl_spawn_place_no_links`: a brief with no `Topic:` on a `dispatch-<word>` ask is refused at once, no queue row); `ASK_DISCUSSION` optional: 908 of the last 8 days' 1322 task asks have `discussion` NULL (`select date_trunc('day',created_at), count(*), count(*) filter (where discussion is null) from fleet_asks where kind='task' ...`) |
| lane | role rotation, failover | `orc/run/spl-rotate-lib.func.sh` (`SPAWN_REUSE_ID=1`, scope `role <id> (rotation <rid>)`) | `sw_issue` skipped; topic and issue from `lifetime/*`, empty for a seat |
| lane | seat restart | `orc/run/spl-peer-restart.func.sh` (scope `seat <id> (restart <rid>)`) | as rotation |
| lane | BOX-0 heartbeat | `orc/run/spl-lane-map.func.sh` (scope `mem_kb=... live=...`) | sends no topic, no issue: it is a box, not a lane |
| lane | the hub's put | `api/hub/box_lane.go` lane_op `put`, `api/store/fleet_lane.go` `CheckFleetLane` | both fields may be empty |
| lane end | exit-clean, retire, reap | `sa/scripts/lane-map.sh done`, `sa/scripts/agent-id-retire.sh`, `sa/lib/reap-lane-close.inc.sh` | a role seat's row is never set done (`lane_is_role_seat`) |
| agent | spawn-window (placer, hand, rotation, restart) | `sa/scripts/spawn-core.inc.sh` `spawn_main` | the lane put is started before the window, in the background |
| agent | identity restore (`--resume`) | `orc/run/spl-agent-identity-restore.func.sh` | **writes no lane row** |
| agent | desk seat | `orc/run/spl-desk-up.func.sh` | seats an agent already running; writes no row |
| commit | the pre-push part `commit-links` | `orc/run/spl-commit-links-check.func.sh` `do_spl_commit_links_check` (SPL-4789) | **refuses** a commit whose issue links only the workspace default: the chain's last link is already enforced, after the fact |

(File and function names above were read on `45c7424d9`; line numbers are
given only where I read them.)

## 3. The gates

Each path gets one of three gates: **refuse** (nothing is born), **derive**
(the link comes from something the path already holds, never from a search),
or **default** (a fixed standing value, only for the role seats of section 4
and the box row).

| # | path | gate | what exactly |
|---|---|---|---|
| G1 | `spl_lane_issue_place` | refuse | no discussion in the brief (`li_discussion_from_brief`) and no `LANE_ISSUE_TOPIC` -> FATAL, no default; the spawn exits 12 as for a missing issue |
| G2 | `do_spl_issue_create` | refuse | a new issue whose only discussion is the workspace default is refused (decided: owner `4ef793d6`, `61bf7791`); old issues keep the default as their `unknown` (`937e89a4`) |
| G3 | hub `discussionsFor` | refuse | the same for every create path: a create whose only discussion is `IssueDiscussionDefault` is `discussion_required` (decided, as G2); the hub's derived paths pass their real topic; the cascade's default fallback goes |
| G4 | a brief's `Owner topic: <ws> <uuid>` line | derive | `li_discussion_from_brief` reads it (the form every dispatcher brief uses); a t1 issue then links another workspace's topic if Q1 = A, else the issue is filed in that workspace |
| G5 | `do_spl_spawn_enqueue` | refuse | refuses a brief with no discussion, as it refuses one with no `Epic:`/`Spec:`, and writes `fleet_asks.discussion` from it (derive), so the placer's refusal (SPL-4797) is the second net |
| G6 | `spawn-window.sh`, hand spawn | refuse | the placer's link check runs here too: a hand spawn launches nothing without both |
| G7 | `_spawn_lane_put` | refuse | the put runs in the foreground before `tmux new-window`; a refused put (after 3 tries) stops the launch: no window without its row |
| G8 | rotation, failover, seat restart | derive | `SPAWN_REUSE_ID=1` carries the previous row's topic and issue (`lifetime/*`, else the hub row); a role seat takes its standing values (section 4) |
| G9 | identity restore | derive | before the resume, put the row from `lifetime/brief.md` and `lifetime/issue`; if they name no topic and no issue, do not resume and report it to the dispatch holder (decided: owner `4ef793d6`, "bare agents instantiated without lanes no") |
| G10 | desk seat | none | it starts no agent; the agent it seats has its row |
| G11 | BOX-0 heartbeat | default | it is no lane: a `kind` column, `kind = box` exempt (decided: a schema choice); every lane rule leaves it out |
| G12 | hub lane put (`CheckFleetLane`) | refuse | empty topic or issue refused (lane (c), SPL-4799, `ErrLaneUnlinked`); role seats send their standing values, not `unknown` |
| G13 | 15-min check `do_spl_lane_links_check` | report | live (SPL-4797); after section 4 it stops leaving role seats out: a seat with no standing value is a gap |
| G14 | dead live rows | derive | a live row whose agent has no pane on its box and whose last write is older than 24 h is set `done` (decided: truth-first, a live row with no pane is false data; the reaper already closes reaped ids through `lane-map.sh done`, `sa/lib/reap-lane-close.inc.sh`) |

## 4. Role seats: standing discussion, standing issues, standing lanes

The owner: "even if the lanes are some common activities - fo r example
orchestration or dispatching , bare lanes cannot exist". Today seats are bare
by design (spec 153 sections 3.11 and 3.20: the `role_seat` mark, no topic, no
issue), and lane (c) writes `unknown` for them.

Design:

- **One standing discussion** per workspace that runs seats (Q2), made once by
  a new idempotent action `do_spl_standing_chain_ensure`, titled "Fleet
  operations: the standing seats", in that workspace's operations channel. Its
  uuid is cnf (`env.fleet.standing.discussion`), never a literal in code.
- **One standing issue per role**, born of that discussion, label `standing`,
  status `wip`, never closed by the closer (`issue-close-landed.py` skips
  `standing`): orchestration (001), master dispatch (002), failover dispatch
  (003), GC / reaper, the R7 standing reviewer, the CI seat, and one per
  workspace seat brief. Keys are cnf (`env.fleet.standing.issues.<role>`).
- **The standing lane** is the seat's row: topic = the standing discussion,
  issue_key = its role's standing issue. Every writer of a seat row (rotation,
  failover, restart, restore) takes the two from the cnf; `role_seat` stays
  a display hint only.
- **Work a seat does for a discussion** (an answer, an evaluation) still files
  that discussion's own issue (spec 135 Q1); the standing issue holds only the
  seat's own upkeep (rotations, handoffs).

## 5. Database constraints

| table | today | change | coordination |
|---|---|---|---|
| `fleet_lanes.topic`, `.issue_key` | `NOT NULL DEFAULT ''` | no default, CHECK `<> ''`, old `''` -> `unknown` | lane (c) SPL-4799, rdb 0263: commit `8c8d98323` in its worktree; `git log origin/master --grep SPL-4799` -> none. This spec adds nothing to 0263 |
| `fleet_lanes.topic` | free text | CHECK the form: a uuid, `dispatch-[0-9a-f]{8}` or `unknown` | a migration after 0263; no FK: the topic may be another workspace's |
| `fleet_lanes.issue_key` | key or `''` | a key or `unknown` (0263); no FK: a key may carry another workspace's prefix | the page resolves it (spec 153 3.19) |
| `fleet_lanes.kind` | none | `lane` / `seat` / `box` (G11) | a new migration; a `box` row is exempt from both CHECKs |
| `issues` / `issue_discussions` | >= 1 link at COMMIT (0194) | an issue created after the migration whose only link is the default is refused at COMMIT | a new migration; old issues keep their link |
| `fleet_asks.discussion` | uuid, NULL allowed | NOT NULL for `task` asks created after the migration | after G5 lands |

## 6. Today's bare rows

Owner `937e89a4`: no search, the literal `unknown`.

- **Lanes.** The 132 rows older than 7 days are dead lanes: G14 sets them
  `done` and the hub prunes them a week later; what stays live and empty gets
  `unknown` (lane (c)). Role seats get their standing values, not `unknown`.
- **Issues.** The 3012 (t1) + 749 (other workspaces) issues linked only to the
  default stay so: the default topic is their `unknown`. Nothing is relinked
  by search. Only issues born after G3 need a real discussion.
- **Asks.** A queued ask with no discussion is handed back to the holder by the
  placer (SPL-4797); closed asks stay as they are.

## 7. The total change

| # | component | file / action | change | effort | covered by |
|---|---|---|---|---|---|
| T1 | orc | `spl-lane-issue.func.sh` `spl_lane_issue_place` | G1: no default discussion, FATAL | S | none |
| T2 | orc | `spl-issue-create.func.sh`, `csi-spl-orc/lib/bash/funcs/spl-desk-issue.func.sh` | G2: refuse the default for a new issue | S | none |
| T3 | api | `hub/issue_discussions.go` `discussionsFor`, `hub/issue_epic_close.go` | G3: the default is no discussion for a new issue; the cascade takes the epic's | M | none |
| T4 | orc | `sa/lib/lane-issue.inc.sh` `li_discussion_from_brief` | G4: read `Owner topic: <ws> <uuid>` | S | none |
| T5 | orc | `spl-spawn-enqueue.func.sh` | G5: refuse no discussion, write `ASK_DISCUSSION` | built (the refusal) | **SPL-5325**: the enqueue runs the placer's check (one function, both callers), test `spl-spawn-queue.tst.sh` 1b; the idle filler and the security round now write a `Topic:` line. Writing `ASK_DISCUSSION` from the brief: not built |
| T6 | orc | `sa/scripts/spawn-window.sh` | G6: the link check on a hand spawn | S | none |
| T7 | orc | `sa/scripts/spawn-core.inc.sh` `_spawn_lane_put`, `spawn_main` | G7: the put in the foreground, no window on a refused put | M | none |
| T8 | orc | `spl-rotate-lib.func.sh`, `spl-peer-restart.func.sh` | G8: carry the row's links; seats take the standing values | M | none |
| T9 | orc | `spl-agent-identity-restore.func.sh` | G9: put the row again after a resume | S | none |
| T10 | orc + rdb + api | `spl-lane-map.func.sh` BOX-0; a migration for `fleet_lanes.kind` | G11: the box row is no lane | M | none |
| T11 | api + rdb | `store/fleet_lane.go` `CheckFleetLane`, rdb 0263 | G12: refuse empty, old `''` -> `unknown` | M | **lane (c) SPL-4799**, on review |
| T12 | orc | `do_spl_lane_links_check` | G13: include role seats once section 4 is live | S | the check itself: **lane (a) SPL-4797** (`1662b5e26`); the seat change: none |
| T13 | orc | a new `do_spl_lane_reap_stale` (or `sa/lib/reap-lane-close.inc.sh`) | G14: dead live rows -> `done` | S | none |
| T14 | orc + cnf | a new `do_spl_standing_chain_ensure`; `csi-spl-cnf` `env.fleet.standing.*` | section 4: the discussion and the standing issues | M | none |
| T15 | orc | `scripts/issue-close-landed.py` | the closer skips `standing` | S | none |
| T16 | rdb | the migrations of section 5 (topic form, kind, default-only refusal, asks NOT NULL) | the DB holds the rule | M | none |
| T17 | wui | Monitoring Lanes / Topics | ids render as links, `unknown` as text | built | **lane (b) SPL-4798** (`ce769cf93`); `unknown` as text: pinned by a test, **lane (a) SPL-4797** (`88ac4f56e`) |
| T18 | api + orc | priority: discussion -> issues -> lanes | not a link rule; it walks this chain | built | **SPL-4813** (`2bb59d807`) |
| T19 | api | `hub/box_lane.go`: a put keeps another workspace's v5 topic | a cross-workspace discussion survives the put | built | **lane (a) SPL-4797** (`f43810f8f`) |
| T20 | doc | spec 153 / 135, `doc/md/lane-issue-and-docs.md`, `doc/md/SPEC-spool-fleet-roles.md` | the rule's one home and its pointers | S | none |

Effort: S = under half a day, M = about a day; nothing is L. Not yet covered:
9 S (T1, T2, T4, T5, T6, T9, T13, T15, T20) and 6 M (T3, T7, T8, T10, T14,
T16), plus the seat half of T12. Covered by the queued lanes: T11, T12 (the
check), T17, T18, T19. The shas are `git log --oneline origin/master | grep
SPL-<n>`.

The 4 queued lanes:

| queued lane | rows | state on `45c7424d9` |
|---|---|---|
| (a) `c002-bug-lanes-no-discussion-link-20261104`, SPL-4797 | T12 (the check), T19, the placer refusal (2.4) | landed |
| (b) `c002-feat-lane-ids-render-as-links`, SPL-4798 | T17 | landed |
| (c) `c002-bug-lanes-not-null-discussion-issue`, SPL-4799 | T11 | not on master |
| `c002-bug-lane-prio-follows-discussion`, SPL-4813 | T18 | landed |

## 8. Open choices for the owner

One line each; A is the recommendation.

The poll in csitea `b0f50875` asked six questions; its Q1, Q3, Q4 and Q5 are
decided above (G2/G3, G11, G9, G14), so its Q2 and Q6 are Q1 and Q2 here.

- **Q1 another workspace's discussion.** A: a t1 issue may link a topic of the
  workspace its lane works for (today the hub refuses it, 2.1: a hub change).
  B: the issue is filed in that workspace.
- **Q2 the standing discussion.** A: one per workspace that runs seats, in its
  operations channel. B: one for the whole fleet, in t1.

## 9. Not built here

Everything: this is the evaluation. T1..T10, T12 (seat half), T13..T16 and
T20 go to lanes after the owner's answers; T11 waits for lane (c); the asks'
NOT NULL of T16 waits for T5.
