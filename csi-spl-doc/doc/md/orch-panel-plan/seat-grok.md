# Orchestration panel: grok seat review

Status: **review of plan v0.1**. This file does not sign v1.0.
Epic SPL-1308, issue SPL-3934. Specs
[101](../../../specs/101-four-orchestrator-dispatchers/spec.md) and
[134](../../../specs/134-od-pool/spec.md).
Panel task `dispatch-orch-grok-again`.
Reviews [orch-panel-plan.md](../orch-panel-plan.md) version 0.1, commit
`9862b850b` (ancestor of this tree).
Tree `48fb1855fff844de130a6a43f5736333eea968c6`. The orc tree and
`fleet_ask_od.go` / `fleet_ask_od_postgres.go` are unchanged from
`3bc99fb34a324d91373676bee3c3354add30bbce` through this tree
(`git diff --stat` of those paths is empty).
Live readings below are one sample each, on the PC, at
2026-10-28T02:23:40Z. Sat was not read.

## 1. Verdict

Agree the shape. Build no third lock. Finish spec 134, add the chain
lock, time slots for new rows, the too-slow handover, and visibility,
and fix the box defects in B1..B5. Twelve rows cover RC1..RC6. Each row
has a red control and a measure-after. The vendor column has no mistral
coding row. Section 6 names the owner gates. Spec 101 stays superseded
(section 5.2). Batch order in section 5.1 holds, including the hot file
`fleet_ask_od.go` as O3 then O5 then O7.

Changes, one per row that needs one: B1 cite, B2 call order, B3 file
list, B4 follow-up for an unnamed cause, O1 cadence content, O2 drill
cap, O4 seat count and the claude-out fixture, O5 the sentence in
section 4.2, O7 how a slow grok turn is stopped. No row is a reject.
No thirteenth row.

## 2. Re-measured on this tree

| fact | command | reading |
|---|---|---|
| seat links | `readlink /var/spool-hub/{a,g,m,q}-001` and `c-00{1,2,3}` | `a-001`, `g-001`, `m-001`, `q-001` -> `c-001`; `c-002` -> `g-002`; `c-001` and `c-003` are not links |
| restore skip | `grep -n` of `_ai_restore_recheck` and `a live window already carries it` in `spl-agent-identity-restore.func.sh` | function at line 171; skip text at line 180; call at line 114 |
| bare-shell fallback | `grep -n 'exec env HISTSIZE' spawn-core.inc.sh` | line 94 (inside `_sp_live`) and line 732 |
| heartbeat path | `spool-agent-hook.sh` | line 111 `os.path.join(root, aid)` with no realpath of `d`; line 591 `os.path.join(d, "heartbeat.json")` |
| failover order | `spl-role-failover.func.sh` | `spl_rotate_spawn` at 265; `spl_role_failover_end_old` at 269 only when `new == seat`; the other old pid is ended at 295-306 after the new seat has acked. `spl_role_failover_end_old` is defined at 214 |
| watchdog copy | `spl-watchdog.func.sh:876` | `cp "$SPOOL_ROOT/$id/heartbeat.json"` |
| early limit | `spl_wd_s2_limit` | starts at 1214, ends at 1236; caller at 1188; one wake via `spl_wd_limit_wake` after reset plus grace |
| place gate | `sed -n 143p spl-spawn-place.func.sh` | `[[ "${holder##*@}" == "$ASKS_BOX" ]] \|\| { do_log "INFO the orch role is held on ${holder##*@} ($holder): its machine places"; return 0; }` |
| place helpers | `grep -n` in the same file | `spl_spawn_place_away_hold` at 725; `spl_spawn_place_brief` at 741; the "no brief file" hand at 461 |
| chain lock | `fleet_ask_od.go`, `fleet_ask_od_postgres.go` | `odLockable` at line 229; interface `LockNextOdJob` at 106-109; `func (s *Memory) LockNextOdJob` at 332; `func (s *Postgres) LockNextOdJob` at 88 |
| queue glob | `git ls-files` `fleet_ask*.go` | seven files, including `fleet_ask_od.go`, `fleet_ask_od_postgres.go`, and `fleet_ask_od_test.go` |
| relay | `spool-fleet-relay.sh`, `spool-send.sh` | `say()` at line 40 writes stderr; capture at 169 is `2>&1`; failure at 176 is `say "send via $BOX failed (rc=$rc): $out"`. `spool-send.sh` 456 captures the relay's stdout; 459 prints `hub relay failed (rc=...)` and exits `10 + rc` with no hub body |
| pool ingest | `git grep -c OD_POOL_INGEST -- csi-spl-orc csi-spl-api` then `wc -l` | 0 |
| peer mutex | `sed -n 18p spl-peer-gate.func.sh` | the comment `The mutex is never released` |
| 101 names | `git ls-files \| grep -E 'm05-numbers\|u4-seat-cost\|m3-drill\|spl-peer-setup\|spl-fleet-od-cutover'` | `NONE` |
| supervisor defaults | `spl-od-pool-supervise.func.sh` lines 24, 48, 68 | `OD_BACK_CLAUDE_N` default 2, `OD_BACK_GROK_N` default 2 |
| runbook commands | lines in `runbook-orchestrator.md` that contain `./run -a` or a `cd ` command | 22 |
| runbook hang | same file | line 382: the transcript reader looks only under `~/.claude/projects`; line 395: a grok session lives under `~/.grok/sessions` |
| dispatch grade | [grok-dispatch-grade-2026-10-25.md](../grok-dispatch-grade-2026-10-25.md) lines 101-103 and 196-197 | dispatch, lane c-271, issue SPL-3481. grok-held all n=161, 31 (19.3%) within 3 min, median 481 s, p90 1251, 14 (8.7%) with no reply in 30 min. claude-held matched n=417, 331 (79.4%), median 40 s, p90 541. claude-held same cell n=35, 16 (45.7%), median 232 s |
| HIT S3 "runs only" | `grep -ah 'HIT S3'` of `/var/spool-hub/dispatch/wd.log` and `wd.log.1`, then `grep 'runs only'`, first 10 characters counted | 18, all `2026-10-27` |
| g-001 heartbeat window | `wc -l` and `grep -c` of `2026-10-27T13:` and `2026-10-27T14:` on `/var/spool-hub/g-001/heartbeat.log` | size 200; both counts 0 |
| pool cron | `crontab -l` of the box user, pattern `od_pool\|do_spl_od\|spl-od\|OD_POOL` | no line |
| lease | `LEASE_CMD=show ./run -a do_spl_dispatch_lease`; `dispatch/lease.orch` | dispatch `c-002@sat` age 8; orch `c-001@sat` |

The plan's landed-sha table in section 2 was not re-walked, apart from
the ingest count, the peer-gate line, the five absent names, and the
supervisor defaults above. The queue depth of 57 and the sat load were
not re-run. `writer_box` line numbers were not re-grepped.

## 3. Root causes

| RC | rows |
|---|---|
| RC1 one vendor login | B5 does not open a second login. O4 is the pool across two logins |
| RC2 bare pane, restore skip, early limit | B1 and B5 |
| RC3 failover shares one inbox and one heartbeat | B2 |
| RC4 grok not proven as orchestrator | O1, O2, O7 |
| RC5 queue follows the role-holder box, briefs stay behind | B3 |
| RC6 spec 101's live half, and the relay that does not name its cause | B4, O3, O7, and section 5.2 |

## 4. Rows

**B1 — change the cite, agree the fix.** On this tree the fallback
`exec env HISTSIZE=-1 HISTFILESIZE=-1 BASHOPTS=histappend bash --norc`
is line 732, and the same exec is line 94. The plan cites line 729.
The restore skip text is still line 180. The red control (a pane whose
pid is `sh -c env ... spawn-claude.sh`, no harness child, must `START`
in the same pane) matches that code.

**B2 — change the cite, agree the end-before-start rule.** The hook
joins `root` and `aid` and then opens `heartbeat.json` inside that
path, so a symlink shares one file. The watchdog copies that file at
line 876. The failover does not end the old session before the new
spawn. `spl_rotate_spawn` runs at 265. `spl_role_failover_end_old` runs
at 269 only when the new id is the seat id. When the ids differ, the
old pid is ended at 295-306, after the new seat has acked the probe.
The plan cites the definition at 214 and the late kill. Move the end
to before line 265 so the old pid is gone before the new spawn's first
tick. The red control (old pid gone before that tick; a hook run as
`AGENT_ID=c-001` through a `c-001 -> g-001` link does not rewrite the
other heartbeat) is the right fixture.

**B3 — narrow the file list, agree the behaviour.** The gate at line
143 returns without placing when the orch role is held on another
machine. The away-hold is `spl_spawn_place_away_hold` at 725. The brief
lookup is `spl_spawn_place_brief` at 741. The missing-brief hand is
line 461. The plan's 728 and 742 fall inside those two functions on
this tree. The glob `fleet_ask*.go` is seven files and includes
`fleet_ask_od.go` and `fleet_ask_od_postgres.go`, which section 5.1
reserves for O3, O5, and O7. Name the queue files (`fleet_ask.go`,
`fleet_ask_postgres.go`, the queue tests, the new migration) and keep
the od lock files out of batch 2. Within a batch the other pairs are
disjoint. Briefs on the row, any box places, and the spawn mutex stay.

**B4 — log and check now; fix the named cause in a follow-up.** The
relay's `say` writes stderr. The hub's stderr is inside the relay's
`$out` because of `2>&1`, then `say` prints it. `spool-send.sh` keeps
the relay's stdout and, on failure, prints the rc without that body.
Nothing appends `dispatch/relay.log`. Agree the log line and
`do_spl_relay_check`. This seat sent no cross-box relay (read-only).
Open point 1 stays open. Drop "then the cause it names is fixed in the
same row" until one failure has been reproduced and named.

**B5 — agree.** `spl_wd_s2_limit` waits until reset plus grace, then one
wake, and it does not open a second login. A frozen grok turn that
stops emitting hooks is the runbook trap at line 382, which this row
does not claim to catch. The red control (a peer's good-turn heartbeat
wakes the parked seats at the next tick) is the change this function
has to grow.

**O1 — put the grok cadence in this row.** Agree a cadence table in the
orchestrator runbook, edited in Qto and re-exported, checked by
`do_spl_orch_drill --list`. The table also needs the six items in
section 5. Leave the orchestrator median out until O2. The dispatch
grade is the only grok timing this seat re-read, and it is dispatch.

**O2 — keep the drill, drop the 600 s cap from the pass line.** Agree
the same dev hour, claude and grok, n >= 5 per task, at least 90%
right, median within 2x claude, against the cadence's expected times.
`no task over 600 s` copies `OD_SLOW_S` for `route_post`. A grok task
whose tool cost exceeds 600 s fails that line even when it is within
2x claude. 600 s stays the lock rule (O7). The drill is where an
orchestrator median replaces the dispatch grade. agy runs the same
line after 2026-10-30.

**O3 — agree.** `odLockable` is line 229. The memory `LockNextOdJob` is
line 332. The Postgres twin is line 88. No third lock. The red control
(one actor per chain, 409 for the other seat, n >= 50) matches section
4.1. The `(ask_id, gen)` on an outward act covers the chain. It does
not cover the dispatch lease; that re-read is an O1 cadence step.

**O4 — three seats, and the claude-out fixture stays off one login.**
Agree the pool target `claude_n = 2`, `grok_n = 1`, `min_boxes = 2`.
The supervisor defaults on this tree are 2 and 2 (lines 24, 48, 68).
The owner's "3 of those" is the target, so the plan's 2 + 1 stands and
spec 134's 2 + 2 does not. When agy joins after its drill, it replaces
a seat: the live count stays 3. The red control "claude out -> 3 grok
seats within one tick" puts all three seats on one login, which the
same row refuses unless `OD_ACCEPT_ONE_LOGIN=1`. With the flag unset,
claude out leaves the pool at `grok_n` (1). With the flag set, 3 grok
is allowed. Filling from the other vendor applies when one seat of a
vendor dies and that vendor is not wholly out. A pool under 3 is the
result when the alternative is three seats on one login.

**O5 — agree 900 s as intake, change the sentence in section 4.2.**
`OD_SLOT_S` = 900 and `OD_SLOT_GRACE` = 60: a row younger than 60 s is
for the intake seat, and an older row is for any able seat. Work a seat
already holds keeps its chain. The clause "the turn length measured
today (minutes) fits inside it" is not a measurement this seat can
stand behind (section 5). 900 s is the intake window for new rows. A
grok turn can run longer than the slot; the next slot takes new rows.
The 24 h share, the floor of one slot in six, and the spec 068 warning
stay.

**O6 — agree.** The issue card, the topic header, and the tmux `@od`
option make the lock visible. New i18n keys go in every locale, as the
plan already says. The vendor cell "UI: never mistral" stays.

**O7 — keep 600 s, and stop the live turn.** Agree `OD_SLOW_S`
(`route_post` 600, `lane_verify` 900, `spawn` 900, `box_op` 1800), the
gen bump, the row back to `open`, and the 2-revoke / 3-revoke back-off.
Agree that P4, P5, and P6 are the live half and that they follow this
plan's numbers. The dispatch median of 481 s (n=161) is a reason to
keep 600 s for the normal dispatch-shaped reply. It is not an
orchestrator median. A grok turn does not yield until its tool chain
ends, so a 409 on the seat loop's next renew lands after that chain
has already acted. The revoke signals the live pane, and the gen fence
refuses a late outward act on the old gen. The measure-after (p95
lock-to-first-act, 0 rows held past `OD_SLOW_S`, 0 double answers, 7
days) stays.

## 5. What a grok orchestrator needs

The failure-day per-task list was not recoverable. For
2026-10-27T13:52-14:33Z, `/var/spool-hub/g-001/heartbeat.log` has 200
lines and 0 lines in `2026-10-27T13:` or `2026-10-27T14:`
(2026-10-28T02:23:40Z). The 27-minute turn and the 26..37 queued
messages stay the dispatcher's post. This seat has no orchestrator
median to put in the plan.

A grok turn runs its tool chain to the end before it yields. On the
failure shape that implies, the slow work is any orchestrator task
whose tools are long (a lease show, sudo, a long `./run`, a cross-box
read), done one after another in the same turn. The plan's cadence and
stop rule need six additions. They belong in O1 and O7.

1. One task per turn. Draining the inbox in one serial tool chain holds
   the chain for the whole chain.
2. Re-read `LEASE_CMD=show` immediately before each outward act. The
   chain gen does not cover the dispatch lease.
3. Ack the set just acted on, and only when a fresh recv is still that
   set, before the next long command.
4. Expected times include that tool cost. The table gets an
   orchestrator median only from the O2 drill.
5. The hang check reads `~/.grok/sessions`. The runbook already says
   the transcript reader looks under `~/.claude/projects` (lines 382
   and 395).
6. The too-slow revoke interrupts the live pane (O7). A 409 that only
   the seat loop observes arrives too late.

## 6. Open points

1. **Relay.** Open. This seat did not reproduce it.
2. **Three seats or four.** Three. agy replaces a seat after the drill,
   so the live count stays 3. The supervisor's 2 / 2 defaults change
   with O4.
3. **600 s.** Keep it. The 481 s figure is the dispatch grade. This
   seat has no orchestrator reading that moves the line.
4. **900 s.** Keep it as the intake window for a new row younger than
   60 s. It is not a turn budget. Section 4.2 loses the "fits inside
   it" clause.

## 7. Signature

Unsigned. The editor folds the changes above and asks this seat before
this file records v1.0.

<!-- version: review · updated: 2026-10-28 · last-edit: 2026-10-28T02:23:40Z -->
