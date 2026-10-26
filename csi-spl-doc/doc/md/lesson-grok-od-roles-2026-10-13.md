# Lesson: Grok as orchestrator and dispatcher, 2026-10-13

> Generated from qto doc `5e74f859-8a75-4441-8089-d4136c047889`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Owner ask (t1 topic `ee1e58d5`, msg `47cafee8`): "We need some kind of report
for lessons learned when Grok was dispatcher and orchestrator." Issue
SPL-1706. Lessons first, then the timeline, the measurements and the root
causes they come from.

Every claim names its source: a file and line, a message id (`msg <id8>`),
a commit sha, or a command and its output. All times are UTC. "Main box" is
the box that held the three role seats; "sat" is the satellite.

Sources used, all read-only:

| source | what it holds |
|---|---|
| `/var/spool-hub/dispatch/rotate.log` (read with `grep -a`) | every role rotation step: GATE, SPAWN, ACK, FAIL, SWITCH |
| `/var/spool-hub/dispatch/rotate.orch.mix.tsv` | one row per orchestrator rotation and the vendor it started |
| `/var/spool-hub/dispatch/handoff/20261013T*-{orch,master,failover}-*.head.md` | which id each new role seat started as |
| `/var/tmp/CLE-parent-level/dispatch/hold/{c,g}-001-<box>-*-orch.md` | the orchestrator's own hold notes, one per session ("hold note HHMM" below) |
| `/var/spool-hub/dispatch/c00[23]-ee1e58d5-*.md` | the dispatcher's posts in the owner topic |
| `/var/spool-hub/c-00{1,2,3}/{inbox,outbox,archive}/20261013T*.json` | every spool message of the three role seats (the `g-00N` dirs are links to these) |
| `/var/spool-hub/asks/*.json` | the ask book |
| `git log origin/master` | the fixes |

<a id="ws-doc-c39c214e-c0cc-4cc7-b0a4-da8fd03044f5"></a>
## 1. Lessons

1. **A vendor switch is a code path; test it with the real launcher.** Five
   role rotations failed before a Grok seat took a role, on three different
   causes (section 2.2). The rotation tests had stubbed the spawn, so none
   of them saw it, and each of the two code faults was found only by a live
   failure. Before a role changes vendor again, run one forced rotation per
   role on the real `spawn-window.sh` in a sandbox tmux, as
   `test-spawn-window-role-seat-vendor.sh` now does (`480a44659`, `ff9b0feb5`).
2. **One switch per decision.** "Grok off" did not mean off: with
   `ROTATE_ROLE_VENDOR` empty, the older `ROTATE_ORCH_SPLIT=1` vendor split
   still picked Grok for 35 % of orchestrator rotations, and did at 11:05Z
   (section 4.2). The code still works that way.
3. **An id that hides the vendor hides the result.** From 12:06Z to 14:06Z
   Grok ran as `c-001`, `c-002` and `c-003`. Readers, the owner included
   (msg `10e31037`: "why is it called c-001"), could not tell who did what.
   A lane's own audit later counted Grok hours as Claude hours (section
   3.4). Fixed: a role id now follows its vendor (`eef0a6475`).
4. **Every "is it alive" check must know every vendor.** The lease liveness
   read only Claude transcripts, so a working Grok orchestrator was declared
   stuck and a false "no live orchestrator" alert went to every agent
   (15:28Z). The dispatch check still reports a false permission GAP for
   every Grok seat (section 4.1).
5. **Judge a role by its output, not its activity.** The Grok seats sent as
   many messages as Claude seats on a busy morning (section 3.2), renewed
   every lease and rotated on time. But in 5 h 38 min the orchestrator sent
   no refactor-round brief, closed none of the 7 asks blocked on GitHub and
   re-ran no failed deploy (section 3.3). The owner judged the run by that,
   from a lane terminal: "the run of the grok as the orchestrator was kind
   of fail" (17:42Z, section 2.3).
6. **"Stays with the owner" is not an answer once the owner has answered.**
   At 14:56Z the owner posted a new GitHub token to try (ESC `74e81c5d`).
   The Grok orchestrator tried it once, saw HTTP 401, wrote "Renewal stays
   with HUM-10" and held 7 lanes idle for about 2 h 40 min. The Claude
   orchestrator that replaced it got GitHub working from the same token
   within minutes and closed all 7 asks (section 3.3).
7. **A log line that names one vendor misleads the diagnosis.** The 10:05Z
   failure printed "no claude carrying c-001 started", and the setback posts
   then blamed a start check that "looks only for Claude processes". The
   real cause was an environment variable lost across the tmux hop; process
   recognition already knew Grok (`ff9b0feb5` body). The message now names
   the rotation's vendor and why the pane failed (`ff9b0feb5`).

<a id="ws-doc-8d76c5f3-6c99-4ec3-b496-f3e6efe25c62"></a>
## 2. Timeline

<a id="ws-doc-7723e6a3-7f13-4765-9177-d2b50a936c45"></a>
### 2.1 Before the day

| when | what | source |
|---|---|---|
| 10-11 10:49Z .. 10-12 00:09Z | owner go for three stages: runbooks, a 10-hour read-only Grok shadow (g-192), then a live test. The shadow found 33 runbook gaps; they were folded in | `c002-post-t1-ee1e58d5-go.md`, `c002-ee1e58d5-shadow-result.md`, `0294d8bca`, `cf5bee4c3` |
| 10-11 11:57Z | data rule: secrets may go to Claude, Grok or Mistral, so a Grok role seat may read role traffic | `e6ef6ecfa`, `c002-ee1e58d5-datarule.md` |
| 10-12 05:18Z | orchestrator vendor split behind `ROTATE_ORCH_SPLIT=1`: cnf `agent_split_by_kind.orchestration` = claude 65 / grok 35; dispatch seats stay Claude | `abff60ec7`, `csi-spl-cnf/csi-spl/all.env.yaml:989` |
| 10-12 20:59Z | spec 134 P0: the fleet lease counts a Grok or Vibe holder (before, `spl_lease_agent_pid` counted only `comm == claude`) | `744186fdc` |

<a id="ws-doc-e649e217-3049-4960-bdb6-413bbadbf7b1"></a>
### 2.2 The switch and the five failed rotations

The brief counted 3 failed rotations, the orchestrator ones. `rotate.log`
shows the master dispatcher rotation failed twice more, on the same causes.

| UTC | event | cause | source |
|---|---|---|---|
| 06:11Z | `ROTATE_ORCH_SPLIT=1` set on both boxes | owner order for a 4-hour Grok test | `c002-ee1e58d5-grok-correction.md` |
| 06:14Z | correction posted: the split alone gives Grok 35 % of orchestrator rotations and none of the dispatcher ones | split design (`abff60ec7`) | same file |
| 07:12Z | owner asked: lane c-912 (the enabling change) was paused by the owner's own "pause all other work" order | process | `c002-ee1e58d5-grok-pause.md` |
| 07:27Z | `ROTATE_ROLE_VENDOR=grok` lands: one knob for all three role seats | | `36e9437bd` |
| **09:06:17Z** | orch rotation **FAIL 1**: `spawn-window: c-001 is not a grok id` | the kind/id check ran before the seat-reuse path; tests stubbed the spawn | `rotate.log`; `480a44659` body |
| 09:17:22Z | master rotation FAIL, same text (`c-002 is not a grok id`) | same | `rotate.log` |
| 09:35Z | fix 1: a role seat with `SPAWN_REUSE_ID=1` passes the check; its test runs the real `spawn-window.sh` dry run | | `480a44659` |
| **10:08:03Z** | orch rotation **FAIL 2**: `no claude carrying c-001 started in %1365 within 120s` | `SPAWN_REUSE_ID` did not cross the tmux hop, so the launcher in the new pane refused again and fell to a bash | `rotate.log`; `ff9b0feb5` body |
| 10:19:36Z | master rotation FAIL, same text | same | `rotate.log` |
| **11:07:54Z** | orch rotation **FAIL 3**, same text, although the Grok knob was off | the vendor split picked Grok on its own: the GATE line reads `successor grok: lane-mix orchestration: grok`; then the same tmux-hop fault | `rotate.log` 11:05:34Z; `c002-ee1e58d5-grok-setback3.md` |
| 11:17:50Z | master rotation succeeds as Claude (`claude: dispatch seats: claude`) under the guard set after FAIL 3 | | `rotate.log` |
| 11:40Z | fix 2: the variable crosses the hop; the pane stays until a CLI pid shows; FAIL names the vendor and the pane's last screen | | `ff9b0feb5` |
| 11:46Z | test re-armed on the main box | | `c002-ee1e58d5-alert-9557.md` |

Each failure opened an ask and sent the owner a DM: `8ef5ce28`, `3b83645e`,
`4ec856ef`, `ee6aeb92`, `ffaddc6a` (`rotate.log` ALERT lines; ask files).
In every case the old Claude seat kept the role.

<a id="ws-doc-4906597e-c895-4461-b2a5-4a49c168a2fe"></a>
### 2.3 The window

| UTC | event | source |
|---|---|---|
| **12:06:52Z** | **window start**: orch rotation SPAWN OK, Grok pid 3839667, still named `c-001` | `rotate.log`; `rotate.orch.mix.tsv` row `20261013T1205Z-orch grok` |
| 12:18:24Z | master dispatcher becomes Grok, named `c-002` (pid 805096) | `rotate.log` |
| 12:23:07Z | failover dispatcher becomes Grok, named `c-003` (pid 1428672) | `rotate.log` |
| 12:12Z .. 13:45Z | owner: "why is it called c-001 .. should be g-001"; lane c-422 (SPL-1685) builds the id switch | `c002-ee1e58d5-g001.md`; `3ee0cdd58` .. `eef0a6475` |
| **14:06:43Z** | orchestrator becomes **g-001** (`SWITCH OK lease.conf LEASE_ORCH=g-001`) | `rotate.log` |
| 14:19:53Z | master dispatcher becomes **g-002** | `rotate.log` |
| 14:26:32Z | failover dispatcher becomes **g-003** | `rotate.log` |
| 14:55Z | first record of GitHub auth failing on the main box (Actions list HTTP 401 for both token files) | hold note 1405 |
| 15:28Z | false "g-001 silent 10 min, restore it" alert `0af972ea` | hold note 1505 |
| 16:06:52Z | the promised 4 hours are reached. The 16:07Z check-in the dispatcher promised (`c002-ee1e58d5-grok-window.md`) has no post file: `ls /var/spool-hub/dispatch/ \| grep ee1e58d5` shows none written between 12:12Z and 19:55Z; not checked on the hub | `ls` |
| 17:42:01Z | owner, typed in lane c-296's terminal: "ok , the run of the grok as the orchestrator was kind of fail", then "get a c-001 of your kind aka claude to be the orchestrator" | c-296 session transcript, user turns 17:42:01Z and 17:42:31Z |
| 17:43:36Z | forced orch rotation with `ROTATE_ROLE_VENDOR=claude` (backup `rotate.conf.bak-20261013T1744Z-grok`) | `rotate.log`; `diff` of the two files -> only that line differs |
| **17:45:20Z** | **window end**: orchestrator is Claude `c-001` again (pid 1697959) | `rotate.log` |
| 17:54:18Z / 17:58:05Z | dispatchers back to Claude `c-002` / `c-003` (early dispatch rotation 1751Z) | `rotate.log` |

Grok held the orchestrator role for 5 h 38 min (12:06:52Z .. 17:45:20Z)
and the dispatcher role for 5 h 36 min (12:18:24Z .. 17:54:18Z). No Grok
quota or limit event happened: `grep -iE 'usage.limit|quota|limit reached'`
over the role seats' messages of 12:06Z .. 17:58Z -> 0 lines about a Grok
seat.

<a id="ws-doc-3d6f6e9d-7060-4f37-a6a4-f2b3a9409371"></a>
## 3. How Grok did in the roles

<a id="ws-doc-e2c046fc-51c0-49fd-9e2f-4251f51a7db9"></a>
### 3.1 What went well

| what | measured | source |
|---|---|---|
| rotations | 16 of 16 Grok role rotations in the window (6 orch, 5 master, 5 failover) ran to SPAWN OK and ACK with no FAIL; the switch to g- ids ran clean on all three seats | `rotate.log` 12:05Z .. 17:22Z |
| leases | each orch rotation ends `lease follows pid <new>` | `rotate.log` CLOSE lines |
| early asks | the first 6 asks closed in the window were closed by Grok seats in 3 to 18 min (f63b3dc1 10 min, 1a56c38e 3, 5cff594d 18, 00e999b1 13, 7c06064e 11, ef1d72cb 3) | `/var/spool-hub/asks/*.json` `created_at` / `updated_at` / `closed_by` |
| care with risk | did not apply a terraform plan whose dev side carried changes outside the owner's go (marketing step 030 applied on prd only) | hold note 1205 |
| one lane per task | repeatedly refused a second lane for an owned task (SPL-37, SPL-40, the activity-clock lane) | hold notes 1405 .. 1705 |
| self-correction | named its own owner-topic posts as a mistake at 14:48Z and handed the topic back | hold note 1405 |
| quotas | no limit event in 5.6 h | section 2.3 |

<a id="ws-doc-f14a5e6a-9835-4b85-99d5-7da3bbd1d183"></a>
### 3.2 Message volume

Same length of time, the three role seats' outgoing messages
(deduplicated by msg id over `c-00{1,2,3}/{inbox,outbox,archive}`):

| period | seats | messages sent | to another role seat | pure acks ("Seen ...", "... No reply.") |
|---|---|---|---|---|
| 06:00Z .. 09:39Z | Claude | 332 | 210 | 0 |
| 14:06Z .. 17:45Z | Grok (g-) | 301 | 192 | 34 |
| 18:00Z .. 21:39Z | Claude | 114 | 56 | 1 |

The Grok seats were as busy as Claude on a busy morning. About 1 in 9 of
their messages was an acknowledgement with no new content, against close to
none from Claude. The hold notes show the pattern: g-001 sent the dispatcher
a hang list every 5 minutes and g-002 answered each with "will not kill ...
no push" (hold note 1605, 16:44Z .. 17:03Z, 7 such replies).

<a id="ws-doc-c734634a-e444-4d93-b338-76a085b13e3c"></a>
### 3.3 What went badly

| what | measured | source |
|---|---|---|
| owner posts escalated as unanswered after 5 min | **16** escalations (17 topic rows, 9 topics), all 12:24Z .. 15:44Z, all while Grok held the dispatch seats. 10-12: 0. 10-13 before 12:18Z and after 17:54Z: 0. One topic, `add4fbf4`, took 7 of them | `grep -l 'Unanswered sweep ESCALATION' c-001/{archive,inbox}/*.json` -> 1 file on 10-11, 16 on 10-13 |
| a missed owner question | the owner asked why `add4fbf4` went unanswered (14:46Z). The orchestrator's "take" at 14:42Z counted as an agent reply and stopped the sweep, and the dispatcher had been told not to post. Nobody posted the result | hold note 1405, 14:46Z and 14:48Z |
| wrong and retracted posts | g-002 double-posted in `add4fbf4` (`80dbc900`), retracted with `do_spl_desk_msg_delete` at 14:36Z. g-001 posted three times in that owner topic while not holding dispatch (`cbe40940`, `e139da3e`, `702c6018`) | hold note 1405 |
| false alert to everyone | g-002 posted alert `0af972ea` to all agents (15:28Z): "g-001 silent, restore it". g-001 was working; cause in section 4.1 | hold note 1505 |
| asks left open | 7 asks from lanes blocked on GitHub push (85802f3b, bddeea40, 66eeda0a, 4ccbff51, 8533be17, d245e8e0, 2f8cefcf), opened 15:08Z .. 16:56Z, re-acked hourly by g-001, closed by none. The Claude c-001 closed all 7 at 17:50Z .. 18:08Z | ask files: `acked_by g-001@<box>`, `closed_by c-001@<box>` |
| GitHub blind for about 3 h | from 14:55Z gh returned 401. At 14:56Z the owner posted a new token ("try it", ESC `74e81c5d`). g-001 tried it at 15:10Z, got 401 and left it: "Renewal stays with HUM-10". The Claude c-001 had gh logged in from that same token, and pushes going over SSH, by 17:5xZ | hold notes 1405, 1505; `c-001-<box>-1743-orch.md` line 2 |
| failed deploy not re-run | hub workflow 20 run 38416894867 failed (15:04Z). g-001 decided "re-run the failed jobs" but never fired it (gh 401), and told every seat not to start one. Hub stayed on v7.9.8 `cb7885b6`, built 13:42Z, until the Claude c-001 dispatched run 38441845189 at 17:50Z (green) | hold notes 1505, 1705; `c-001-<box>-1743-orch.md` line 3 |
| no refactor round | lane c-296 (refactor rounds) got no round-18 brief after round 17 reported at 11:07Z: 6 h 35 min, until the switch back | c-296 transcript 17:42:17Z |
| sat seat attempt | g-001 tried to place a lane through `g-001@sat`, which has no spool dir there (16:18Z, exit 5, nothing spawned), then retried through `c-001@sat` | hold note 1605, "Activity clock lane" |

<a id="ws-doc-c2e7257d-166f-4e6d-b398-cc7fa3871b79"></a>
### 3.4 What the owner saw, and what was not Grok's fault

- The owner's verdict came after about 4 h with no release and no round.
  Part of that was the GitHub token, which failed for every seat. Grok's
  part was not recovering once the owner gave it the means (section 3.3).
- Lane c-296's audit at 17:42Z said "08:01 – 14:06 c-001 ... the first 4 h
  were under c-001" and counted them as Claude. The `rotate.log` rows show
  `c-001` was Grok from 12:06:52Z. Of the 6 h 35 min with no round, Claude
  held the orchestrator for 59 min (11:07Z .. 12:06Z) and Grok for 5 h 36 min.
  Lesson 3 is why that audit went wrong.

<a id="ws-doc-2872c7a8-9082-45f4-8217-d23bffaa7395"></a>
## 4. Root causes

<a id="ws-doc-adfed1db-2834-45b7-96fc-de0c6839ebc9"></a>
### 4.1 Claude-only assumptions in the code

| assumption | effect | state |
|---|---|---|
| the lease counted only a `comm == claude` process | a Grok holder would never renew | **fixed** `744186fdc` (10-12) |
| spawn refused a kind/id mismatch before the seat-reuse path | FAIL 1, 09:06Z and 09:17Z | **fixed** `480a44659` |
| `SPAWN_REUSE_ID` did not cross the tmux hop into the new pane | FAIL 2 (10:08Z, 10:19Z) and FAIL 3 (11:07Z) | **fixed** `ff9b0feb5` |
| the start-wait error text said "no claude" whatever the vendor | the setback posts blamed the wrong check | **fixed** `ff9b0feb5`: `spl-rotate-lib.func.sh:712` prints `${ROTATE_KIND}` and the pane's state |
| fixed `c-` ids for the role seats | Grok worked as `c-001`; the owner and an audit misread who acted | **fixed** SPL-1685: `3ee0cdd58`, `688bddbc7`, `7228224e1`, `c58eb9f60`, `eef0a6475` (`ROTATE_ROLE_ID_FOLLOWS_VENDOR` defaults to 1) |
| the lease transcript tail read only Claude session files | a working Grok orchestrator read as "stuck"; false alert `0af972ea` | **fixed** SPL-1696 `5b02b5ae1`; the watchdog's progress checks (S1, S8, S9) read the Grok session too |
| `do_spl_dispatch_check` wants `--dangerously-skip-permissions` with no `--permission-mode`, and a Claude `.claude/settings.local.json` | a false permission GAP for every Grok seat, re-checked by hand in at least 5 hold-note entries (hold notes 1305, 1405, 1505) | **open**: `csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh:58-77` unchanged |
| a role alias (`g-001`) exists only on the box that switched | a send to `g-001@sat` found no spool dir (16:18Z) | **fixed** SPL-1716: the receiving box's sidecar writes mail for an alias it has no dir for into the seat's one live letter, desk and fleet inbox both, and mints no orphan (`liveRoleSeat`, `csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go`; test `role_alias_test.go`) |

<a id="ws-doc-ef210733-3a25-441e-ac7d-0fdb673c7223"></a>
### 4.2 Two settings that could each pick the vendor

`spl_rotate_role_vendor` (`csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:108-128`)
returns "no choice" when `ROTATE_ROLE_VENDOR` is empty. The orchestrator
rotation then falls back to the `ROTATE_ORCH_SPLIT=1` split, cnf claude
65 / grok 35. The rotation at 11:05Z did exactly that. Today
`/var/spool-hub/dispatch/rotate.conf` still reads `ROTATE_ORCH_SPLIT=1` and
`ROTATE_ROLE_VENDOR=claude`: emptying the second line would start the 35 %
Grok picks again. **Open.**

<a id="ws-doc-b0c67570-825c-4cc7-a7af-7e654d95ce4b"></a>
### 4.3 Tests that stubbed the real spawn

The rotation suites (`orch-rotate.tst.sh`, `dispatch-rotate.tst.sh`) stubbed
`spawn-window.sh`, so the kind/id check and the tmux hop never ran
(`480a44659` and `ff9b0feb5` bodies). The first fix's test ran the real
script, but in-process, and still missed the hop. Only the second drove a
real tmux pane in a sandbox socket. **Fixed** for the role seat spawn
(`test-spawn-window-role-seat-vendor.sh`, 22 pass / 0 fail per `ff9b0feb5`).

<a id="ws-doc-5c95743b-6fa6-4348-82be-b7cdaa44a496"></a>
### 4.4 Other causes found

- **No outcome check on the role.** Nothing measured whether the
  orchestrator produced briefs, releases or closed asks. Lease, rotation
  and liveness checks were all green while the work stopped (section 3.3).
- **Escalation is not recovery.** A seat may park a blocker "with the
  owner". The Grok seats did that even after the owner had answered
  (the 14:56Z token).
- **A take silences the sweep.** An orchestrator "take" in an owner topic
  counts as an agent reply, so the unanswered sweep stops although no
  answer was posted (14:42Z .. 14:46Z, hold note 1405).

<a id="ws-doc-0dfdc8b6-b2a4-4942-8095-fddb09c25410"></a>
### 4.5 2026-10-14: the orch role handed to a Grok seat on its weekly limit

Rotation `20261014T0805Z-orch` on sat (`rotate.log`, n=1): the successor
`g-001` opened on Grok's limit menu ("Buy more credits / Try Again"), the
rotation logged SPAWN OK and flipped `LEASE_ORCH=g-001` before any ack, and
the fleet orch lease fell to the other box for about 10 minutes. Three
causes, all **fixed** by SPL-1820:

| cause | fix | test (`orch-rotate.tst.sh` section 18) |
|---|---|---|
| the vendor guard trusted lane-mix, whose hub pause and 6 h verdict window (`LANE_MIX_LIMIT_FRESH`) ran out together at 08:05:01Z while the weekly quota was still out | `spl_rotate_grok_out`: the newest watchdog verdict of each Grok seat (`ctx*/<id>/out.s2`) saying `S2 kind=limit` within `ROTATE_GROK_LIMIT_FRESH` (a week) = claude, for `ROTATE_ROLE_VENDOR=grok`, the orchestration split and the dispatch seats | 18.1; controls: a newer clean verdict, a week-old one |
| the start check knew no Grok limit screen: "no known dialog", then SPAWN OK | the `grok weekly limit` dialog in `start-check.inc.sh` ("You hit your weekly limit", "Buy more credits"; never a bare "weekly limit", Grok's footer reads "Weekly limit left") | 18.2: fails at once, named, no SWITCH |
| `LEASE_ORCH=<successor>` was written at SPAWN OK, before the ack | `spl_orch_rotate_flip` runs after ACK OK, before RETIRE; an unacked successor never carries the role | 18.3: lease.conf sampled through the ack wait |

The dispatch rotation still flips at SPAWN OK (`spl_disp_flip`); its
Grok successor now meets the same two guards before it gets there.

<a id="ws-doc-0c1c5c66-5eb9-47b9-8aba-b2c7a9dff491"></a>
## 5. Follow-ups

| # | follow-up | state |
|---|---|---|
| 1 | lease counts a Grok holder | **done** `744186fdc` |
| 2 | role seat passes the spawn id check | **done** `480a44659` |
| 3 | seat reuse crosses the tmux hop; FAIL names the vendor and the pane state | **done** `ff9b0feb5` |
| 4 | role id follows the vendor (g-001 / g-002 / g-003) | **done** SPL-1685, `eef0a6475` |
| 5 | a Grok session counts as activity for the lease and the watchdog | **done** SPL-1696, `5b02b5ae1` |
| 6 | `do_spl_dispatch_check`: accept a Grok seat's flags, skip the Claude settings file for other vendors | open, no issue yet; for the orchestrator to place |
| 7 | one vendor switch for the roles: `ROTATE_ROLE_VENDOR` wins and an empty value means Claude, not the split; or retire `ROTATE_ORCH_SPLIT` for roles | open, no issue yet; the owner's call, because the 65/35 split is an owner order |
| 8 | a role alias reaches the other box (`g-001@sat` -> its live seat) | **fixed** SPL-1716 (section 4.1); live on a box once its desk sidecar runs the new spool binary |
| 9 | an outcome check for the orchestrator role: alert when no lane brief, no round brief and no ask closed for N hours while lanes wait | open, no issue yet |
| 10 | a take in an owner topic does not count as the answer for the unanswered sweep | open, no issue yet |
| 11 | workflow 21 catch-up re-dispatches once after a red hub run on a new sha | open, `c-001-<box>-1743-orch.md` "Idea, not placed" |
| 12 | before the next vendor trial of a role: one forced rotation per role on the real spawn in a sandbox, then the trial; the owner's check-in time becomes a scheduled post, not a promise | open, process; for the dispatcher of the next trial |
| 13 | the dispatch rotation flips `LEASE_MASTER` / `LEASE_FAILOVER` after the ack too, as the orch rotation does since SPL-1820 | open, no issue yet; for the orchestrator to place |

Fixed on master as of `origin/master` `94e5fb5b5`: rows 1 to 5.
