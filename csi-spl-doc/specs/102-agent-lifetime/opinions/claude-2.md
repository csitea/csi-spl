# 102 opinion: claude-2

Panelist claude-2 (lane c-459), independent: no other opinion was read.
Input: `spec.md` v0.1 at `8f32ffd8`. Every claim about code below carries
the command that shows it, run on that tree (2026-10-07). The dispatcher's
`spec102-owner-answers.md` is not on this box
(`ls /var/spool-hub/dispatch | grep -c spec102` -> 0), so the owner answers
were read from spec section 0.2 only.

**Verdict in one line:** the shape is right (one restart path, one handoff,
stuck = what is absent), but v0.1 is not yet failover-proof. Four things
are missing. First, a per-id lock that EVERY restarting actor takes. Second,
an identity for an agent that runs away from its home box (ids are unique
only as `<id>@<box>`). Third, a fence for a box that is partitioned but
alive. Fourth, a restart throughput that can actually reborn a full box
every hour.

## 1. Checks of the spec's claims about today's code

| # | spec claim | command -> result | holds? |
|---|---|---|---|
| C1 | 063 wall-clock restart off by default | `grep -n lane_restart_wall_min .../store/agent_lifecycle.go` -> `Default: 0, Min: 10, Max: 240, ZeroOff: true` | yes |
| C2 | S7 is a list; modal=2 is that one dialog | `sed -n 1,9p .../situations/s7.sh` -> modal=2 "Make auto mode your default", modal=1 a known list, modal=0 `LEASE_BLOCK_RE` | yes |
| C3 | `spool_claude_perm_flags` has 0 definitions, 1 caller with a fallback | `grep -rn 'spool_claude_perm_flags()' csi-spl-orc/src/bash` -> 0; `spl-lane-restart.func.sh:222` falls back to `--dangerously-skip-permissions` | yes |
| C4 | `spl_rotate_quiesce`, `spl_rotate_handoff` exist | `grep -n '^spl_rotate_quiesce\|^spl_rotate_handoff' .../spl-rotate-lib.func.sh` -> 249, 272 | yes |
| C5 | `WD_TAKEOVER_MAX` default 2 | `spl-watchdog.func.sh:70` `: "${WD_TAKEOVER_MAX:=2}"` | yes |
| C6 | "third takeover -> owner DM" (13) | two counters on one file: `spl_wd_takeover` (`spl-watchdog.func.sh:676`, `n >= MAX`) sends an **orchestrator blocker**; `spl_wdt_limit` (`spl-wd-takeover.func.sh:162`, `n - self >= MAX`) sends the ask + **owner DM** via `spl_rotate_alert` | partly: two paths, two recipients |
| C7 | held out past the limit (6.1 builds on it) | `spl-watchdog.func.sh:474`: `(( now - h < 3600 ))`, so the hold **expires after an hour** by itself | the spec does not say R4 removes the expiry (hole H7) |
| C8 | `WD_HUMAN_IDLE` 120 s | `spl-watchdog.func.sh:472` `${WD_HUMAN_IDLE:-120}` | yes |
| C9 | situations s1..s8 + `lib.inc.sh` | `ls .../watchdog/situations/` -> `lib.inc.sh s1.sh .. s8.sh` | yes |
| C10 | the fixture `modal-default-mode.pane` (8.3) | `ls csi-spl-orc/src/bash/tests/fixtures/wd-situations/` -> present, with `idle.pane`, `working.pane` | yes |
| C11 | `box_beats` absent | `ls csi-spl-rdb/src/sql/postgres/spool-hub \| grep -c box_beats` -> 0 | yes |
| C12 | `ASKS_OWNER` 4 in `spl-wd-ensure.func.sh` | `grep -c` -> 4 | yes |
| C13 | 11 lifecycle keys | `grep -c 'Key: "' .../agent_lifecycle.go` -> 11 | yes |
| C14 | `00-fleet.json` has no autoupdate key | `cat .../settings/00-fleet.json`: `defaultMode`, `disableAutoMode`, `skipDangerousModePermissionPrompt`, no updater key | yes |
| C15 | `seal_kms.go`, `operator_workspaces.go`, `internal/mail` exist | `ls` -> all three present | yes |
| C16 | crons orch-rotate, dispatch-rotate, **dispatch-heal**, **peer-restart** are the seat triggers (4.4) | box user's `crontab -l \| grep -cE 'csi-spl:(orch\|dispatch)-rotate'` -> 2 (n = 1 box, this one); `crontab -l \| grep -oE 'csi-spl:[a-z-]+' \| sort -u` -> 15 tags, **neither `dispatch-heal` nor `peer-restart`**, but `agent-id-reap` and `agent-identity-reconcile` are there | partly: the list differs per box; the reaper is a restart-adjacent actor the spec does not name (H6) |
| C17 | 4.1: "every step below already exists" in the takeover | `spl_wdt_steps` (`spl-wd-takeover.func.sh:217..258`): `spl_peer_restart_spawn` **then** `spl_wdt_kill`, for every agent. It is start-first for lanes too, and its failure path `spl_rotate_restore` assumes the old session still lives | **no**: lane stop-first (4.2) is new code with no rollback today (H1) |
| C18 | boot restore is a fresh restart | `restore-claude-plain.sh`: `restore_args() { ... "--resume $1 ..." }`; the boot path is `do_spl_agent_identity_restore` = **resume** | the spec's "session = /proc start" breaks on resume (H5) |
| C19 | 10.2 "the fleet lane row" holds one agent | `0102_agent_at_box_key.sql:22`: `PRIMARY KEY (tenant_id, fleet, agent_id, agent_box)`; spec 061: ids unique only as `<id>@<box>` | **no**: an agent moved to box B collides with B's own same-numbered id (H2) |

## 2. Races (sections 4, 5, 8): file and function for each

| # | race | where today | what goes wrong |
|---|---|---|---|
| R-a | **063 lane restart vs watchdog takeover on one lane** | `do_spl_lane_restart` does `respawn-pane -k` and takes **no** `peer/restart.lock` (`grep -n 'restart\.lock' spl-lane-restart.func.sh` -> 0). It logs to `lane-restart.log` (`spl-lane-restart.func.sh:51`), while the watchdog's `spl_wd_rotating` reads only `rotate.log` (`spl-watchdog.func.sh:386`) | during the respawn gap the pane is a shell, S3 hits, and the takeover spawns a second session in the same worktree. The two lane actors cannot see each other |
| R-b | **seat rotation vs takeover** | `spl_orch_rotate_auto` holds `rotate.orch.lock`, `spl_disp_rotate_auto` holds `rotate.dispatch.lock`, the takeover holds `peer/restart.lock`: three different locks. `rotate.hold` is ONE line for ONE id (`spl-dispatch-rotate.func.sh:295`), and the orch rotation never writes it (`grep -n rotate.hold spl-orch-rotate.func.sh` -> 0 writes) | the watchdog sees an orch rotation only through `rotate.log` within 900 s (`spl_wd_rotating`). 4.4 moves the trigger but keeps three locks |
| R-c | **box-wide single restart lock = throughput** | `spl-wd-takeover.func.sh:78`: `flock -n 6` on `peer/restart.lock`, refuse when busy; `spl-watchdog.func.sh:105` marks the whole box busy meanwhile | one lane restart is about `WD_START_WAIT` 120 s + `ROTATE_TERM_WAIT` 30 s; one seat restart can wait for `ROTATE_ACK_TIMEOUT` (900 s, `spl-rotate-lib.func.sh:58`). 30 agents x ~150 s = 75 min, more than the 60 min rebirth period, before a single seat or crash takes its turn. **Hourly rebirth cannot keep up on a full box** |
| R-d | **kill during a handoff write** | `spl_wdt_steps`: `{ spl_rotate_handoff ...; spl_wdt_section ...; } > "$hand"`, a truncating write in place | v0.1 makes this file continuous (H3: "even a kill leaves a usable one"). A TERM in mid-write leaves a truncated file, which defeats H3. `handoff.prev.md` is named, but no atomic write is |
| R-e | **agent note vs script refresh** | 5.2: the agent writes through `do_spl_agent_handoff_note`, which still writes the same file the script rewrites | "never by editing the file" moves the race; it does not remove it. Two writers, one file, no lock named |
| R-f | **wip snapshot of a live or mid-rebase tree** | 4.1 runs WIP "before RETIRE"; 5.4 pushes at 1 h and 1 h 50 while the agent works | at the hard end the agent may be inside `git rebase` (the closing steps rebase before every push). A temporary-index commit of that tree captures conflict markers. A push from the PostToolUse hook would also block the agent for the push's length |
| R-g | **S9 on an idle agent with an un-poked message** | `spool-agent-hook.sh` header: "unread" = inbox files newer than `.hook-seen`; injection happens only on SessionStart / UserPromptSubmit / PostToolUse | a plain `spool send` or a hub relay with no tmux poke leaves an unread file; the idle agent gets no UserPromptSubmit, and condition 5 holds. After `stuck_min` S9 restarts a healthy idle agent |
| R-h | **reaper vs held-out agent** | `spl-agent-id-reap.func.sh`: retires every id dead for `SPOOL_ID_REAP_H` (6 h), role ids excepted; cron `*/15` (today `DRY_RUN=1`) | 6.1, 6.2, 7 and 10.2 all leave an id stopped and waiting for the admin. Once the reaper goes live it retires the id and its hold, and the handoff loses its owner |
| R-i | **partitioned box, not down** | 10.2: "a box that cannot reach the hub restarts only its own agents..." | that rule stops *restarts* only. Box A, cut from the hub, keeps its live sessions running; box B CASes them after `box_down_min` (2 min) and starts copies. **Two copies of one lane push to one branch** |
| R-j | **seat start-first vs the 2 h sharp end** | 4.2 start-first + 060 ack (`ROTATE_ACK_TIMEOUT` up to 900 s) | a seat restart that starts AT 2 h keeps the old session alive past 2 h for up to 17 min, which contradicts R2 |

## 3. Per section: agree, or a replacement

| section | verdict |
|---|---|
| 0 owner words, 0.2 answers | **agree** |
| 1 why | **agree** |
| 2 words | **replace the "session age" row**: "now minus `lifetime/session.json:started` (written by the SEED step of 4.1, with a session number). A `--resume` (boot restore, a restore script) keeps the file, so it is the same session and the same 2 h. Only the restart path starts a new session." The `/proc` start time is only a cross-check: on mismatch, the older one wins. Add **guest**: an agent running away from its home box (10). |
| 3 lifetime | **agree**, plus one row for seats (see 4.2 below): a seat's watchdog restart starts at `HARD_END - ROTATE_START_WAIT - ROTATE_ACK_TIMEOUT` at the latest, so the old seat is gone by 2 h (R2). |
| 4.1 the action | **replace the first paragraph and the RETIRE / WIP rows**: "`do_spl_agent_restart` is NEW code built from the takeover's phases. The takeover today is start-first for every agent (`spl_wdt_steps`). Lane stop-first is new, and it has no rollback: a failed lane start leaves nothing running, and the next tick retries." Lane order: **RETIRE, then WIP, then SPAWN**. WIP runs on the quiescent tree. If `.git/rebase-merge`, `rebase-apply` or `MERGE_HEAD` exists, it pushes `ORIG_HEAD` plus the dirty diff as a patch file in the handoff, never the conflicted tree. |
| 4.1 LOCK (new row, the main fix) | Every actor that starts or stops a session takes ONE per-id lock `<spool root>/<id>/lifetime/restart.lock` (flock, non-blocking, refuse = exit 4). The actors are this action, `do_spl_lane_restart`, `spl_orch_rotate_auto`, `spl_disp_rotate_auto`, the boot / identity restore and the reaper. Box-wide, replace the single `peer/restart.lock` with **`RESTART_SLOTS`** (default 4) slot locks for lanes; a seat takes slot 0 exclusively. Every actor also writes `rotate.log` phases, so `spl_wd_rotating` sees all of them. |
| 4.2 order | **agree** (lanes stop-first, seats start-first), plus the 3 row above for the seats' timing. |
| 4.3 done or died | **replace row 3**: "no process, no marker, pane on a shell or gone, **the workdir present and the registry row open** -> crash". Keep S3's `rundir_gone` = finished (`s3.sh`): every lane that finished under today's `/exit-clean` has no `done` marker, and v0.1 would resurrect them all on the first tick of the rollout. Also add: a `done` marker older than the session start is ignored (a stale one from the previous task under a reused id). |
| 4.4 seats | **agree** with R11 (a), plus: the crons named must be measured per box (C16). The trigger moves only once the per-id lock (4.1 LOCK) is live in the rotations, else the old cron and the watchdog both fire at `:05`. |
| 5.1 one file | **agree**, plus: written to `handoff.md.tmp` and renamed, under `<id>/lifetime/handoff.lock`, with the previous copy renamed to `handoff.prev.md` first. |
| 5.2 writers | **replace the "agent" bullet**: the agent's sections live in separate files `<id>/handoff.d/{next,notes,lessons}.md`. `do_spl_agent_handoff_note` writes only those, also tmp + rename. The script composes `handoff.md` from them and never writes them. That leaves one writer per file and no lock between agent and script. |
| 5.3 hub copy | **agree**; move the seal out of `internal/marketing` into a shared package, rather than importing marketing from the lifecycle code. |
| 5.4 wip branch | **replace the ref name and the pusher**: `wip/<lane branch>` (lane branches are already fleet-unique; `wip/<id>` is not, see H2). Pushed only by the watchdog's detached job, never by the hook. The pre-push gate must not run on a `wip/*` ref; that needs a scoped hook exemption, not the global `SPL_PREPUSH_OVERRIDE`. CI is unaffected: of 16 push-triggered workflows, 15 filter on branches and 1 on `stable-*` tags (`grep -A4 '^  push:' .github/workflows/*.yml`). |
| 6.1 restarts per hour | **agree**, plus: the hold **does not expire** (today it does after 3600 s, C7), and ONE counter replaces the two of C6. |
| 6.2 rebirths per task | **agree** |
| 7 quota, login | **agree** |
| 8.1 S9 | **replace condition 5**: "**a keystroke was delivered** (a poke or a 1 h / 1 h 50 notice, logged with its ts by the sender in `<id>/lifetime/input.log`) and no UserPromptSubmit followed it". An unread inbox file with no poke gets ONE poke from the watchdog first, which starts the window. Add per harness: S9's condition 5 is used only where that harness's hook emits UserPromptSubmit. I believe, unchecked, that agy, grok and qwen do not, since the hook header says "non-claude harnesses get the heartbeat only". For those, S9 uses conditions 1-4 with `2 x stuck_min`. |
| 8.2 action | **agree** |
| 8.3 proof | **agree**; add control 5: an idle pane with an unread inbox file, **no** poke, which must give no hit (R-g); and control 6: a status line that changes every tick while a dialog is frozen, which must still hit (condition 4 must hash the pane minus a fixed status-line region, else a ticking clock hides every freeze; I believe, unchecked, that the fleet's status line can carry a clock). |
| 9 CLI updates | **agree**, with the spec's own proof task for `DISABLE_AUTOUPDATER` first. |
| 10.1 reboot | **agree**, plus: the reboot path restarts from the handoff (a new session) and **retires the `--resume` boot restore**, not keeps it as the default fallback. Two restore paths behind a switch is the R-b race again. |
| 10.2 down | **replace** with the identity and the fence of H2 and R-i (section 4 below). |
| 10.3 back | **replace "at its next rebirth"** for the case where the home box finds its OWN copy still running (it was partitioned, not down). That copy is killed **at once** (it lost the CAS), its tree is pushed to `wip/<branch>-fenced-<ts>`, and one line goes to the orchestrator. The guest copy stays until its next rebirth, as R6 says. |
| 11 admin | **agree** |
| 12 shared memory | **agree** |
| 13 changes | **replace the 093 8 row** ("cause widened" understates it: start-first for lanes becomes stop-first, new code, C17), and **add rows**: 063 `do_spl_lane_restart` (gets the per-id lock, logs to `rotate.log`, or is folded into the restart path; R-a); the reaper `spl-agent-id-reap.func.sh` (skips ids with an open `lifetime/` hold or a hub handoff and no `done`; R-h); `fleet_lanes` PK `(…, agent_id, agent_box)` (C19). |
| 14 trace | **agree** |
| 16 open questions | below |
| 17 rollout | **agree**, plus: the per-id lock (4.1 LOCK) and the `rundir_gone`-is-done rule join **P0**, because P1's restarts collide without them. 10.2 stays last and waits for H2. |

## 4. Holes: what an owner answer needs that v0.1 misses

| # | answer | hole | proposed fix |
|---|---|---|---|
| H1 | W2 one restart path | the "one path" is start-first in code, and lane stop-first has no failure handling (C17) | 4.1 replacement above |
| H2 | W7, R6 another box restarts them | ids are unique only as `<id>@<box>` (061; C19). A guest `c-007` from box A on box B collides with B's own `c-007`: the spool dir `/var/spool-hub/c-007`, its `registry.tsv` row, its tmux window name, and `wip/c-007`. Peers address it as `c-007@A`, and the relay sends that to the down box | a guest runs under `<spool root>/guest/<id>@<home>/`, with the window named `<id>@<home>`. The `fleet_lanes` row keyed by the HOME box gains `running_box`. The hub routes `<id>@<home>` to `running_box`. wip ref: `wip/<lane branch>` |
| H3 | W7 "coordinated", R5 2 min | no fence for a box that is alive but partitioned (R-i). 2 min is also shorter than one Cloud Run hub blip | a box whose own beat has not been acknowledged for `box_down_min` **fences itself**: it starts nothing, pokes its lanes "no new push", and on reconnect kills every copy whose `running_box` is no longer itself (10.3). The CAS winner also needs a second witness for a lane: the lane branch on origin has not moved for `box_down_min` |
| H4 | R11 + 4.1 throughput | R-c: one restart at a time per box cannot do 30 rebirths an hour | `RESTART_SLOTS` (4.1 LOCK) |
| H5 | A1 per session | a `--resume` makes a new pid with the old session: by `/proc` the 2 h resets on every resume, so a crash-resume loop never hits the hard end | section 2 replacement |
| H6 | W1 "the watchdog stops it" | other actors also stop or retire agents: the reaper (R-h), the 063 lane restart (R-a) and the restore wrappers. v0.1 names none of them | 13 rows above; every one takes the per-id lock |
| H7 | R4 "it stops and only tells the admin" | today's hold expires after an hour (C7), so the restarts would quietly resume | 6.1 replacement |
| H8 | R2 "2 h sharp" | seats start-first can overrun 2 h by `ROTATE_ACK_TIMEOUT` (R-j) | 3 replacement |
| H9 | H3 "even a kill leaves a usable one" | in-place write (R-d), two writers (R-e) | 5.1, 5.2 replacements |

## 5. The 10 open questions (section 16)

| # | verdict | why |
|---|---|---|
| Q1 | **keep (a)** | R1/R2 put the force at 2 h |
| Q2 | **keep (a)**, with the 3 timing row | start-first is right; it only has to START early enough to finish by 2 h (H8) |
| Q3 | **keep (a)** | a seat's task never ends; 6.1 still guards seats against loops |
| Q4 | **keep (a)** | a known reset time needs no human |
| Q5 | **keep (a)**, but the pusher is the watchdog's job, never the hook (R-f) | bounded pushes; and a hook must not block on the network |
| Q6 | **keep (a)** | W6 forbids a harness switch |
| Q7 | **keep (a)** | |
| Q8 | **keep (a)** | 093 6.4's reason holds |
| Q9 | **keep (a)**, but "one per box per minute" becomes "`RESTART_SLOTS` at a time, oldest session first" | with ~30 over-age agents per box and ~150 s per restart, one per minute queues behind the single lock anyway (R-c) |
| Q10 | **change to (a′)**: `--force-with-lease` allowed to `wip/<lane branch>` only, never `wip/<id>` | `wip/<id>` collides across boxes (H2); the lane branch name is already fleet-unique |

## 6. Scores for v0.1 (1-5)

| quality | score | why |
|---|---|---|
| robust | **3** | S9's "absent, not present" rule and the continuous handoff are strong. But four actors still restart agents under three locks, and two handoff writers share one file |
| failover-proof | **2** | 10.2 has no fence for a partitioned box and no identity for an agent away from home; both lead to two copies of one lane |
| simple | **4** | one path, one file, one message type, four settings. The fixes above add one lock and one guest dir, not new concepts |
| uninterruptible | **3** | a kill mid-handoff truncates it today. The wip snapshot can catch a mid-rebase tree. A partition can run two copies. All three are fixable inside the spec's own shape |
