# 174 Issues of kind `activity`: what each role seat is there to do

Version: v0.2 rc (2026-11-09, folds R7 review W1-W10 and N1-N7 of c-573), spec
only: nothing below is built and no issue is filed. Epic SPL-2398 · Issue SPL-5170 · Class feature · Kind specs_and_docs ·
Topic ab86c60e · Task `dispatch-ab86c60e` · Author c-562.

Builds on [spec 060](../060-role-rotation/spec.md) (rotation),
[spec 153](../153-monitoring-lanes-tab/spec.md) section 3.11 (the role seat
mark) and [fleet roles](../../doc/md/SPEC-spool-fleet-roles.md). When built it
amends 153 section 3.11 (C51), 060 FR-040 (the seed gains a list) and fleet
roles section 1 (row C4).

## 0. The owner's words (HUM-10, t1 ab86c60e, 2026-11-09)

- 93a458e9: "we should have issues of kind "activity" with the pre-defined
  activities which each one of those is supposed to be doing anyways :",
  followed by a paste of the lanes list, where a role seat reads
  `c-002@<box> <box> — claude Live role c-002 (rotation 20261109T1145Z-master) unknown Role seat`.
- 324a3a6b: "based on the requirements of the spool-hub and whenever a new
  orchestrator or dispather is instantiating it should refer to those
  activities in the lanes view"
- ab666ad6: "so those should be defined properly based on the REAL task which
  each one of the dispather or garbage collector or orehsestrator is running"

## 1. What is there today

Tree for the file citations: `819870ce6` (origin/master when first read); the
R7 review re-printed 21 of them at `53befd522`, and the one that had moved is
corrected below.

| fact | check |
|---|---|
| The kinds are `epic`, `feature`, `issue`; no later migration changes them | `csi-spl-rdb/src/sql/postgres/spool-hub/0053_issue_kinds.sql:17`; a grep for `issues_kind` and `kind_check` over the migrations finds no other issue kind constraint |
| The statuses are `eval, todo, wip, diss, blocked, onhold, qas, done` plus legacy ones | `0061_issue_blocked_onhold.sql:14-16`, the last migration that adds `issues_status_check` |
| `Role seat` in the lanes view is a fixed label | `csi-spl-wui/src/pages/monitoring/lanes/index.vue:162,166`; `csi-spl-wui/i18n/locales/en.json:3485` |
| `unknown` is the topic cell of a seat: rdb 0264 stored the word, and the template tests `l.topicId` before `l.roleSeat`, so the word wins | `store/fleet_lane.go:42`, `index.vue:161-162` |
| A seat is recognised by its number or its scope | `hub/lanes_registration.go:29`; `store/fleet_lane.go:52`; the rotation writes the scope at `spl-rotate-lib.func.sh:1130` |
| The hub already knows who holds each fleet lease | `store/fleet_lease.go` (`FleetLeases`), `0094_fleet_leases.sql:16` |
| The GC has no agent id, so it has no lanes row | `csi-spl-doc/doc/md/gc-agent.md` section 1.3 |

## 2. Inventory: the real recurring work

### 2.1 How it was measured

Window: the 7 days up to 2026-11-09 about 12:30Z.

| source | n | limit |
|---|---|---|
| Outbox of the seats on one standby box (`<spool root>/<id>/outbox`) | c-001 5,477; c-002 496; c-003 611 | This box held neither lease when read. The holders' outboxes were not read: the box has no ssh alias for the holder's box. The c-001 and c-003 directories also hold messages sent as `g-001` / `g-003` |
| Hub `messages`, read-only (`do_spl_db_query`, prd), `from_id` a seat, by `from_box` | holder's box: c-001 1,586; c-002 3,360; c-003 439. Standby box: c-001 3,121; c-002 550; c-003 278 | Counts of a 26-character normalised opener; what a message means is my reading of the opener, not a classification by anyone who sent it. Openers under 12 messages are not listed |
| Seat transcripts, `./run -a do_*` in Bash calls, standby box, each call filtered by its own time (2026-11-02 12:30Z to 11-09 12:30Z) | c-002: 139 sessions, 1,682 Bash calls; c-003: 192 sessions, 2,412 Bash calls | One count per command per action. Claude sessions on the standby box only, so a `D` row's transcript count shows what a seat did there, including while it was not the holder. The orchestrator's transcripts were not counted: its working directory is not per-seat |
| GC | `<spool root>/dispatch/gc/` state and logs; c-001 outbox openers | One box |

Three results shape the design:

1. **The outbox is not the seat's work.** At least 3,598 of c-001's 5,477
   outbox messages on the standby box (65.7%) are sent by scripts under the
   seat's id: `rotation at` 1,969 (`spl-lane-rotate.func.sh`), `spawn-reply`
   492 (`spawn-remote.sh`), `FLEET LEASE` 436 (`spl-dispatch-lease.func.sh`),
   GC bodies 455 (`spl-gc.func.sh`), `WATCHDOG RESTART` 131
   (`spl-agent-restart.func.sh`), login check 67, done-claim check 48. The
   number counts only the openers whose sender a grep found, and only the 22
   most common openers, so it is a floor.
2. **A seat's work depends on the lease, not only on its number.** The seats
   exist on every box. The most run action on the standby seats is the lease
   check (2.5), and most of their outbox is rotation acks and forwards to the
   holder.
3. **A large item is missing from the role table.** The holder's
   acceptance of lane results and its GO on reviews (2.3 D4) is frequent and
   is not a row of [fleet roles](../../doc/md/SPEC-spool-fleet-roles.md)
   section 1.

### 2.2 Orchestrator, while it holds the orch lease

| key | activity | source | evidence, 7 days |
|---|---|---|---|
| O1 | Answer the asks raised to it and close them | `runbook-orchestrator.md` section 2.2; `spl-wd-orch-outcome.func.sh` counts `asks_closed` | not counted separately |
| O2 | Spawn, re-seat, restart and close agents | `runbook-orchestrator.md` sections 1, 2.3, 5 | not counted: the `spaw` openers on the holder's box (552) are likely the `spawn-remote.sh` reply, so script traffic (2.1 result 1) |
| O3 | Keep the hanging-agent roster, at least every 5 minutes | `runbook-orchestrator.md` section 2.4 | not counted |
| O4 | Run the prd operations the other seats' harnesses refuse | `runbook-orchestrator.md` section 6 | not counted |
| O5 | Verify "live" claims before they reach a human | `runbook-orchestrator.md` section 1 | not counted |
| O6 | Backstop: take a post unanswered after 2 minutes, and a post that names it | `runbook-orchestrator.md` section 1; `brief-dispatcher.tpl.md` section "The owner's rule" | hub take-line notes from c-001: 1 |
| O7 | Decide what is not the owner's: placement, priority, close or keep | `runbook-orchestrator.md` section 1 | `Your` 202, `revi` 67 (openers; meaning not checked) |

### 2.3 Dispatcher, while it holds the dispatch lease (master or failover)

Master and failover do the same work; only the lease differs
(`SPEC-spool-fleet-roles.md` section 1). Every `transcripts` count in this table
comes from the standby box (2.1), so it shows less of this work than a holder
does.

| key | activity | source | evidence, 7 days |
|---|---|---|---|
| D1 | Take every new post within 3 minutes (`do_spl_take`) | `brief-dispatcher.tpl.md` section "The owner's rule"; `runbook-dispatcher.md` section 1 | hub take-line notes: c-002 75, c-003 29; transcripts (standby box) `do_spl_take` 2 + 3 |
| D2 | Answer in the topics it owns (`do_spl_desk_reply`) | `runbook-dispatcher.md` section 1 | transcripts (standby box): c-002 20, c-003 58 |
| D3 | Spawn a new lane for real lane work (`do_spl_spawn_enqueue`) | `brief-dispatcher.tpl.md` section "What to do with each message" | `Lane <id> placed on SPL-` c-002 161; transcripts (standby box) `do_spl_spawn_queue` 12 + 0, `do_spl_spawn_enqueue` 0 |
| D4 | Accept lane results and give the GO on reviews (`do_spl_review_line_check`) | `runbook-dispatcher.md:139` defines `ACCEPTED`; not in the role table (2.1 result 3) | holder's box openers: `ACCE` c-002 423, c-003 62; `GO` c-002 139; transcripts (standby box) `do_spl_review_line_check` 4 + 0 |
| D5 | Route a follow-up to the lane that owns it | `brief-dispatcher.tpl.md` section "What to do with each message" | openers starting with a lane id: c-002 1,727, c-003 192 (my reading of the opener) |
| D6 | Check every "done / live" claim before posting it (`do_check_deploy_lag`) | `brief-dispatcher.tpl.md` section "Verify"; `runbook-dispatcher.md` section 4 | transcripts (standby box): c-002 1, c-003 1 |
| D7 | Keep the owner's topics current: status card, planned, in progress | `runbook-dispatcher.md` section 2.2 | `Status card` 67, `Planned` 79, `In progress` 39 |
| D8 | Escalate decisions and refused prd operations to the orchestrator | `brief-dispatcher.tpl.md`; `runbook-dispatcher.md` section 8 | not counted |
| D9 | Act on the unanswered sweep (`do_spl_unanswered_sweep`; the cron runs every minute) | `SPEC-spool-fleet-roles.md` section 3.2; crontab tag `csi-spl:unanswered-sweep`, `* * * * *` | transcripts (standby box): c-002 5, c-003 1 |
| D10 | Work the open asks (`do_spl_asks_open`, `do_spl_ask_close`) | `SPEC-spool-fleet-roles.md` section 4.3 | transcripts (standby box) `do_spl_asks_open` 2 + 8, `do_spl_ask_close` 0 + 6 |

### 2.4 Garbage collector, per box, one pass per slot

| key | activity | source | evidence, 7 days |
|---|---|---|---|
| G1 | Scan every agent of the box (`GC_CMD=scan`) | `gc-prompt.md` section 1; slots in `csi-spl-orc/cnf/gc/gc.conf` (`:00` claude, `:30` grok) | one box: `GC <box>` summaries 269 |
| G2 | Help a stuck agent, at most 3 minutes each (`begin`, `poke`) | `gc-prompt.md` section 2 | `GC (<box>…): y` openers 108, task `gc-<id>` 111 |
| G3 | Restart an agent an earlier poke did not move (`restart`) | `gc-prompt.md` section 2 | not counted |
| G4 | Ask to close a done and idle agent (`close-ask`) | `gc-prompt.md` section 2 | `GC (<box>…): c` openers 78 |
| G5 | Report the pass and the work share, then close (`done`, `do_spl_spawn_share`) | `gc-prompt.md` section 3 | the `DONE` line of `dispatch/gc` log, one per pass |

### 2.5 A seat on standby: the box does not hold the lease

| key | activity | source | evidence, 7 days |
|---|---|---|---|
| S1 | Check the lease; stay ready; do not route | `brief-dispatcher.tpl.md` section "Master / failover"; `runbook-orchestrator.md` section 4 | transcripts `do_spl_dispatch_lease`: c-002 259, c-003 321 (the top action of both) |
| S2 | Forward to the holder what reached only this seat | `SPEC-spool-fleet-roles.md` section 4.2 | c-002 outbox with a `(standby)` opener: at least 100 |

### 2.6 Every seat

| key | activity | source | evidence, 7 days |
|---|---|---|---|
| R1 | Take the rotation: read the handoff, ack, retire the old session, keep breadcrumbs (`do_spl_agent_handoff_note`) | spec 060; `SPEC-spool-fleet-roles.md` section 4.4 | `ACK rotation`: c-002 137, c-003 187 |

### 2.7 Looked at and left out

- **Cron jobs** (`csi-spl-orc/cnf/box-crons/box-crons.manifest`, the `csi-spl:*`
  crontab tags) are the box's work, not a seat's, even when they send under a
  seat's id (2.1). A seat's activity may name the cron it reads, as D9 does.
- **The night's reflection** is a lane with its own brief and issue
  (`brief-reflection.tpl.md`), not a seat.
- **The watcher seat** (`spl-watcher-feed.func.sh`, spec 165 row B5): the feed
  exists; no window named `watch*` runs on the standby box, the other box was
  not read. Question 7.3.
- `do_spl_rhythm_phase` (spec 166) ran twice in c-002's transcripts. Too thin
  to call an activity from this data; whoever reviews this may say otherwise.

**This inventory cannot prove it is complete.** It lists what the sources show.
Activities with "not counted" rest on the runbook alone.

## 3. The specification

### 3.1 The kind

`activity` is a fourth value of `issues.kind`.

| | epic / feature | issue | activity |
|---|---|---|---|
| means | a body of work | one thing to do | standing work a role always does |
| level | 1 | 2 or 3 | 1, no parent, no children |
| ends | when its issues end | when a commit lands or it is ended | does not end; retired only when the role stops doing it |
| statuses | all | all | `wip` (in force), `diss` (retired); every other value is refused |
| closer `do_spl_issue_close_landed` | refuses by kind | closes on a landing commit | never closes it; a commit citing it links only |
| assignee | any | any | none: it belongs to a role |
| issues board and "my issues" | shown | shown | hidden unless `kind=activity` is asked for |

An activity is a definition, not a work item: there is no run of it to close,
and no count of its passes on the row. Work that comes out of an activity (a
bug the GC finds) is an ordinary issue.

### 3.2 The one home of the set

`csi-spl-orc/cnf/role-activities/activities.tsv`, beside `cnf/gc/gc.conf` and
`cnf/box-crons/`, one row per activity:

| column | example |
|---|---|
| `slug` | `dispatcher-accept-results`: `[a-z0-9-]`, at most 31 characters, stable, never reused |
| `role` | `orchestrator`, `dispatcher`, `gc`, `standby`, `seat` |
| `title` | shown in the lanes view |
| `body` | one paragraph, becomes the issue description |
| `source` | the file or action that defines it |
| `signal` | zero or more `do_*` actions that show it happening (3.5) |
| `status` | `active` or `retired` |

The issue rows are its projection. `do_spl_activity_sync` (dry run unless
`DRY_RUN=0`) creates, updates and retires them, matching on the label
`activity-<slug>`, so no new column is needed and a key never changes. The
role goes on the label `role-<role>`. Labels are `^[a-z0-9][a-z0-9-]{0,39}$`
(`store/issues.go:120`) and must exist in the workspace's label catalogue
(`store/issues.go:689`), so the sync creates them first. An activity is exempt
from the rule "no issue without an epic and a git spec" and from the `Source:`
card: the catalog row's `source` is its reference. A row edited by hand is put back on the
next sync, which logs that it did (question 7.2).

### 3.3 How a seat binds

A seat stores no binding. The view derives its activities from the seat number
and the hub's lease, so a rotation, a vendor switch (`c-002` -> `g-002`) or a
lease flip cannot leave the view stale. A stale lease (older than 180 s,
`runbook-orchestrator.md` section 4) reads as `standby`:

| seat | lease on this seat | role | activities |
|---|---|---|---|
| 001 | holds orch | `orchestrator` | O1-O7, R1 |
| 002, 003 | holds dispatch | `dispatcher` | D1-D10, R1 |
| 001-003 | does not hold | `standby` | S1, S2, R1 |
| `GC-0@<box>` | none | `gc` | G1-G5 |

Every start reads the same set, so a new session is told what it is for.
`do_spl_activity_brief ROLE=<orchestrator|dispatcher|gc>` prints keys and
titles. For a seat it prints the role's list and the standby list, and says
which applies follows the lease, because a seed is written once and a lease
flips later. Each of these includes it: the orchestrator seed (`spl_orch_rotate_seed`,
`spl-orch-rotate.func.sh:642`), the dispatcher brief
(`brief-dispatcher.tpl.md`), the standby refresh, the restore path and the GC's
first prompt. If the hub cannot be read it prints the catalog without keys and
the start goes on: a rotation never fails over this list.

### 3.4 The lanes view

For a role seat's row:

| cell | today | new |
|---|---|---|
| Scope | `role c-002 (rotation …)` | unchanged, `LaneRoleScope` depends on it |
| Topic | `unknown` | the role: `Dispatcher`, `Orchestrator` or `Standby`, from the hub's lease state; never the word `unknown` |
| Issues | `Role seat` | the activity keys as links, with the title on hover; the list folds to a count when long |

The hub adds `role` and `activities: [{key, title, status, last_seen}]` to the
row and returns an empty topic for a seat. `Role seat` stays only as the
fallback when the set cannot be read. The new label strings are translation
keys in every locale, and agy has the final word on them.

The GC needs a row it does not have today. `do_spl_gc` writes `GC-0@<box>` on
`GC_CMD=start` and clears it on `done`. The id passes the column check (rdb
0238, `[A-Z]{2,4}-[0-9]{1,9}`), but today nothing would show it:
`hub/fleet_lanes_view.go:207` keeps only `laneIDRe` ids and `LaneIsNotLane`
(`store/fleet_lane.go:60`) knows only `BOX-`. Row C2 changes both. The GC still
has no agent id: `GC-0` is a row name, like `BOX-0`. See question 7.4.

### 3.5 What a seat is doing right now

**It cannot be known in general, and the view must not claim it.** A model
session interleaves its inbox; `heartbeat.json` gives only `progress_ts`,
`turn_since`, `tool`, `tool_since` and hashed calls.

What can be known, without a model:

- **Last seen, per activity.** The steps log (spec 160 section 3.9) names the
  tools a session ran. Matching those `do_*` actions against the `signal`
  column gives one time per activity, shown as `last seen 4 min ago`, never
  `doing`. An activity with no `signal` shows a dash, and a dash does not mean
  the work did not happen. **This has no data source today:** the log is off
  (`env.box.agent_steps_log.agents` is `[]`, `all.env.yaml:1272`), it matches
  only `-wt*-<id>` claude directories, so the orchestrator and non-claude seats
  get none, and nothing carries it to the hub. Row C3 builds the path for
  claude dispatchers; every other seat shows a dash until its source exists.
- **The GC** is exactly known: its `BEGIN <id>` / `END <id>` log lines.
- **A rotation in progress** is exactly known from `dispatch/rotate.log`.

A signal is evidence of a command, not of the job done well. Judging output
stays with the outcome checks (`spl-wd-orch-outcome.func.sh`).

### 3.6 When a role changes

1. A commit changes the role's definition and its catalog rows together, as
   one change (`Spec:` or the role runbook cited). A row is never deleted: a
   retired one stays with `status=retired` in the file, and the sync sets
   `diss`.
2. A box cron row `role-activity-sync` runs the sync on the dispatch holder's
   box every 15 minutes, as the other holder-box rows do, and does nothing while
   the catalog hash is unchanged. The next start of each seat picks up the new
   list. The lanes view changes at the sync.
3. A test checks every `source` path and `signal` action still exists, and
   every role has at least one row. It cannot see an activity nobody wrote
   down, so completeness stays a review item when a runbook changes.

## 4. Build rows

Each is one small lane. A1 lands first; B and C need A1 deployed.

| row | scope | test |
|---|---|---|
| A1 store | Next free migration (head today `0270`): add `activity` to the kind check. Store validation at `store/issues.go:504`; refuse any status but `wip`/`diss`; a `treeLevel` case (`store/issues.go:258`) gives level 1 without touching `IsEpic`, so an activity cannot be a parent | Store tests on Postgres and memory: accepted, level 1, bad status refused, parent refused, used as a parent refused, kind change refused. `PRE_PUSH_TIER=full` |
| A2 hub issues | `hub/issues.go:222` (input), `:657` (filter), `treeKind`; excluded from the default list | Hub tests: `kind=activity` lists it, the default does not, `done` refused 4xx |
| A3 closer | `issue-close-landed.py:163-164` and the epic cascade skip activities | Closer test with a citing `feat(x, SPL-n)` commit: stays `wip`; red control without the skip |
| A4 orc readers | Skip activities in `issue-epic-backfill.py:119,240` (level 1 reads as an epic), `issue-discard-select.py:66` (no kind test) and every open-status reader in `csi-spl-orc/src/bash` | Each reader's test with an activity row; red control without the skip |
| B1 catalog | `activities.tsv` from section 2, and its validity test | Each `source` and `signal` exists, every role has a row, a slug fits the label rule; red control with a bad path |
| B2 sync | `do_spl_activity_sync`, dry run by default; creates the catalogue labels first; the box cron row `role-activity-sync` (3.6) | Run twice = one set of rows; a hand edit is restored and logged; a retired row goes `diss`; a too-long slug is refused; the cron does nothing on an unchanged hash and off the holder's box |
| B3 hub lanes | `role`, `activities`, empty topic for a seat in `fleet_lanes_view.go`; role from `FleetLeases` | Hub tests: holder, standby, a stale lease reads standby, a lease flip changes the set with no write, vendor letter `g-002` |
| B4 WUI issues | `ISSUE_KINDS`, `isTopKind` and normalisers in `csi-spl-wui/src/utils/issues.mjs:13-14,32,251,339`; hidden from board and count | Unit tests, `pnpm run typecheck`, e2e |
| B5 WUI lanes | Topic and Issues cells at `index.vue:158-172`, locale keys; agy reviews the text last; amends spec 153 C51 | `monitoring-lanes.test.mjs:52` (C51) rewritten to the new cells; unit tests; e2e in Chrome against the generated bundle: no `unknown` on a seat row |
| C1 seat start | `do_spl_activity_brief` and its includes (3.3) | `orch-rotate.tst.sh`, `dispatch-rotate.tst.sh`: the seed carries the role's and the standby keys; hub down still rotates |
| C2 GC row | `GC-0@<box>` on `start`, cleared on `done`; a read path past `laneIDRe`; `LaneIsNotLane` extended (3.4) | `gc-agent.tst.sh`: a row during the pass, none after, a dead pass ages out; hub test that the row is returned and is no lane |
| C3 last seen | Turn the steps log on for claude dispatcher seats; a new `fleet_lanes` field carries each activity's time with the seat's lane row write (the build confirms that write can take it); other seats stay a dash (3.5) | One action maps to one activity; no signal gives a dash; `c-001` and `g-002` give a dash; red control with an unmapped action |
| C4 docs | Fleet roles and both runbooks point to the catalog, and D4 enters the role table | `do_check_fleet_rules_drift` |

## 5. Not in scope

Scheduling or triggering work from an activity; counting passes; SLA reports
per activity; activities for lane agents (a lane has its one issue).

## 6. Risks

- **The list drifts from what seats do.** The catalog says what a seat is for;
  section 3.6's test catches only broken references.
- **A signal reads as proof of work.** 3.5 fixes the wording to `last seen`.
- **Kind switches are scattered.** Section 4 lists the ones found by grep over
  `epic`, `level` and `IssueKind*`; A1, A2, A3, A4 and B4 must re-grep at build
  time.

## 7. Open questions for the owner

| # | question | recommendation |
|---|---|---|
| 7.1 | Show a standby seat with its own short list (S1, S2, R1), or the same list as the holder, greyed? | **Own short list.** It is what the standby seats actually do (2.5), and a greyed D1-D10 would say it might route |
| 7.2 | May someone edit an activity in the web UI, or only through git? | **Git only**: it follows from the one-home rule, the sync restores a hand edit, and comments stay open. No owner answer needed unless this is wrong |
| 7.3 | Is the watcher a standing seat that needs activities? | **Not yet**: no such window on the standby box (other box unread). A fact to check at build, not a decision; add it to the catalog if it runs as a seat |
| 7.4 | The GC exists only during its pass. Show a `GC-0` row only while it runs, or always, with the last pass? | **Only while it runs**, with the last pass's time in the box row; a row that says live when nothing runs is the same lie as `unknown` |
| 7.5 | Which workspace holds the activity issues? Seats serve the whole fleet | **One: the workspace of the fleet's own work** (`t1`, prefix `SPL`). Other workspaces see the role and titles with no link |
| 7.6 | Should D4 (accept results, give GO) be written into the dispatcher's role table? The runbook already defines `ACCEPTED`; the table does not name it | **Yes**, through row C4: it aligns the table with the runbook |
