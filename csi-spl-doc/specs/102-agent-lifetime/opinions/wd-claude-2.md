# 102 v1.1 (watchdogs, 10.4) - panelist claude-2

Input: `spec.md` / `tasks.md` at `8ee516f26` (v1.1.0-draft), owner answers WD1..WD5,
today's code at `origin/master` `982ebab00`. Independent opinion: no other
panelist file was read.

**Verdict: agree with the goal and with WD2/WD4/WD5 as framed; do not build
10.4.1, 10.4.2 and 10.4.4 as written.** The draft adds 3 instances on top of a
loop whose per-agent state is box-wide and unlocked, so 3 instances corrupt
each other's ticks and double-count debounces and takeovers. The id lock it
relies on cannot be held by the watchdog without blocking the takeover it
starts. The "bad commit can never take down all 3" claim does not hold, because
every other restart path starts the new checkout. And a box with 0 watchdogs
stops beating, so 10.2 reads it as down and moves its lanes while the old
copies keep running. Each hole has a small fix below. Q12 keep (a), Q13 flip to
(b), Q14 keep (a) with a sharper definition.

## 1. Claims checked against the code

Commands run in this worktree (`csi-spl-orc/src/bash/run`) and on the live
box, read-only.

| # | draft claim | check | holds? |
|---|---|---|---|
| C1 | tick is 60 s; "3 missed checks" = 180 s (10.4.2) | `grep -n 'WD_TICK:=30' spl-watchdog.func.sh` -> `:73`; live `wd.log` stamps 30 s apart, n=8 consecutive ticks | **no**: the tick is 30 s, so 3 missed checks = 90 s |
| C2 | "a HUNG loop is not caught" (0.3 facts, 13) | `grep -n '^spl_wd_ensure_hung' spl-wd-ensure.func.sh` -> `:125`; `WD_ENSURE_HUNG:=180` at `:41` | **half**: the keeper DETECTS a hung loop after 180 s and sends a blocker + owner DM. It does not restart it |
| C3 | one loop per box, pid in `dispatch/wd/run.pid`, lock `run.lock` | `spl-watchdog.func.sh:51-56`; `ps` shows one `do_spl_watchdog` tree | yes |
| C4 | "periodic crons pull origin master into the checkout" (10.4.4) | `crontab -l \| grep -c 'git checkout -q --detach'` (box user) -> 9 | yes, and it is 9 crons on one worktree, some every minute or every 3 min, so code arrives within about 3 min, not 5 |
| C5 | the loop "runs old code until killed" | `spl-watchdog.func.sh:72` (`WD_SITUATIONS` = the checkout) and `:796` (`$ROTATE_RUN -a do_spl_wd_takeover`, a new `./run`) | **partial**: only the loop body is old. `s1..s9.sh`, `lib.inc.sh` and the takeover are read fresh from the moving checkout on every tick, so today's loop runs MIXED versions (new `s9.sh` with old `spl_wd_gather`) |
| C6 | the watchdog takes the id lock before it acts (10.4.1) | `grep -rn spl_agent_id_lock spl-watchdog.func.sh` -> 0; only `spl-wd-takeover.func.sh:86` takes it | today no. Ring, Escape, C-c re-poke and the S7 answer (`:752-763`) are typed with no lock at all |
| C7 | 13: situations are `lib.inc.sh`, s1..s8 | `ls features/watchdog/situations` -> s1..**s9** | stale (T004 landed) |
| C8 | 13: `WD_TAKEOVER_MAX` at `:70`, `:474`, `:676` | grep -> `:74`, `:534`, `:786` | line drift only |
| C9 | 13: `grep -c ASKS_OWNER spl-wd-ensure.func.sh` -> 4; `box_beats` -> 0 | as stated | yes |
| C10 | rollback "restarted on the prior working revision / backup binary" (10.4.4) | the loop is bash run from ONE detached worktree that the crons move; nothing on disk keeps the old tree | **no**: no prior revision exists to roll back to |
| C11 | a tick is short | live: `tick/agents` 15 ids, every `tick/out.*` written within 2 s of `last.tick` (n=1 tick) | yes today. A tick that answers a dialog (S7 key sequence with `WD_KEY_WAIT`) or sends is longer |

## 2. Per subsection

### 10.4.1 Three daemons and arbitration - REPLACE

Three holes:

1. **Shared, unlocked per-agent state.** Every instance writes the same files:
   `<WD_DIR>/<id>.hits` (the 2-tick debounce of S2/S3/S8), `<id>.ep.<code>.<tag>`
   (once per episode), `<id>.takeovers`, `<id>.heldout`, `<id>.<what>` (since),
   `last.tick`, `resume`. Each tick also starts with `rm -rf "$tick"` (`:106`)
   and `rm -rf "$ctx"` (`:274`). Three instances therefore (a) delete each
   other's tick and ctx dirs mid-tick, (b) count one real tick 3 times, so S3's
   "2 ticks" becomes about 10 s, and (c) race the check-then-write of
   `ep.S3.takeover`. If two instances both launch the takeover, the second
   gets exit 4 from the id lock, but `<id>.takeovers` has already gone up twice.
   With `WD_TAKEOVER_MAX` 2, ONE real restart then holds the agent out for an
   hour.
2. **Keys are not under any lock.** Two instances that both see S6 send
   `C-c` twice. Two `C-c` on an empty Claude input arm and then confirm exit,
   so the "re-poke" kills the session. The same applies to S7's Escape and
   S7's Down+Enter.
3. **"The watchdog must acquire the id lock before acting" deadlocks the
   takeover.** `spl_agent_id_lock` binds the lock to the CALLER's pid through a
   helper (`spl-rotate-lib.func.sh:147`). The watchdog starts the takeover
   detached under `setsid` (`:796`), and that new process asks for the same lock
   (`spl-wd-takeover.func.sh:86`). The watchdog still holds it, so the takeover
   exits 4 and never runs.

Replacement text:

> - **Three daemons**: every box runs instances 1, 2, 3 of `do_spl_watchdog`
>   (`WD_INST`), each detached with `setsid` (today's `spl_lease_detach`) as
>   the box user. Each holds `dispatch/wd/run.<n>.lock` (flock, for its life).
>   Liveness is "the lock is held" (`! flock -n run.<n>.lock true`), never
>   `kill -0` on a pid file (pid reuse). A lock file is NEVER removed: removing
>   a held flock file lets a second process lock a new inode.
> - **One judge per agent per tick**: before it gathers an agent, an instance
>   takes `dispatch/wd/<id>.judge.lock` with `flock -n` and holds it through
>   gather, judge and act. It skips the agent when that lock is held, or when
>   `<id>.judged` (epoch) is younger than `WD_TICK - 5` s. All per-agent state
>   (`hits`, `ep.*`, `since`, `takeovers`, `heldout`, `s9.poked`) is written
>   only under the judge lock. So the 3 instances are one pool, every agent is
>   judged about once per `WD_TICK` whichever instance gets it, debounces count
>   real ticks, and every key, poke, note and snapshot happens once.
>   `s9.reported` and `WD_NOTE_DEBOUNCE` are not needed: the episode flags
>   already do once-per-episode, once they are single-writer.
> - **Per-instance scratch**: `tick.<n>/`, `ctx.<n>/`, `last.tick.<n>`,
>   `resume.<n>`, `heartbeat.<n>`.
> - **The id lock stays where T003 put it**: in the start/stop actors (the
>   takeover, lane restart, rotations, restore, reaper). The watchdog does not
>   take it. It starts the takeover detached, as today, and the takeover's
>   exit 4 is the arbiter against every non-watchdog actor.

### 10.4.2 Heartbeat and peer monitoring - REPLACE (thresholds and who may judge)

- Hung threshold: `WD_HUNG = max(3 x WD_TICK, 180 s)`. That is 180 s at
  today's 30 s tick, the same number the keeper already uses (C1, C2). Write the
  heartbeat at tick START and after every finished agent (`progress_seq`), so a
  long but healthy tick keeps beating. 3 x 30 s alone would make a 90 s
  dialog-answering tick look hung.
- **Only a healthy judge judges.** An instance judges a peer only when (a) it
  wrote its own heartbeat this tick (a full disk or read-only fs means nobody
  kills anybody, and the keeper alerts instead), and (b) its own gap since its
  previous tick is under `3 x WD_TICK` (a box back from suspend sees every peer
  stale: no peer kill on that tick, the rule the keeper already applies).
- Kill = `TERM`, and the instance's TERM trap finishes the CURRENT agent
  (never stopping halfway through a key sequence), then exits; `KILL` after
  `ROTATE_TERM_WAIT`. Kill and restart happen under `run.<n>.start.lock`, and
  the restarter re-checks staleness after it gets that lock, so two judges
  never kill the same instance twice.
- **One start function** `spl_wd_inst_start <n>` (under `run.<n>.start.lock`,
  re-checks `run.<n>.lock`, starts from the GOOD code, see 10.4.4). Peers and
  the keeper both call it. Nothing else starts an instance.

### 10.4.3 Cross-box liveness - REPLACE (the most serious hole)

The draft says a box's beat is written by its watchdog (10.2) and that "a
failure of watchdogs alone does not trigger agent migration". Both cannot hold:
**a box whose 3 watchdogs are dead writes no beat. After `box_down_min` the
other boxes read it as DOWN and CAS its lanes**, and the second witness ("lane
branch not moved for 2 min") is true of almost any working lane. The fence is
self-applied by the dead watchdog, so the old copies keep running: two copies,
the exact thing 10.2 forbids. A `wd_count: 0` row can also never arrive,
because nothing is left to send it.

Replacement text:

> - Each instance beats `box_beats` as its own row `(box, inst, beat_at, pid,
>   code_sha)`, with inst 1..3. The **cron keeper also beats**, as `inst = 0`,
>   every minute.
> - **Box down** (10.2) = no row of ANY inst, keeper included, for
>   `box_down_min`.
> - **Watchdogs down** = the keeper row is fresh but no inst 1..3 row is. The
>   HUB derives `wd_count` from fresh rows; boxes do not self-report it.
>   Nothing migrates. The hub sends ONE admin message (11.2) per episode.
>   Observing boxes send nothing, so N boxes do not mean N-1 duplicate alerts.
> - A box whose keeper is also dead (cron gone) is down by definition. That is
>   10.2's case, and the fence there needs a fencer that is not the watchdog:
>   the keeper applies the fence when its own beat is not acked.

### 10.4.4 Self-update - REPLACE

Four holes:

1. **The stop rule does not stop the bad code (C10).** After the halt,
   instances 2 and 3 are "on old code" only in memory. Any later death (a hung
   kill, OOM, the keeper, a reboot) restarts them from the checkout, which now
   holds the bad commit. Within hours all 3 can be on it.
2. **No rollback target exists (C10).**
3. **Mixed versions (C5).** Situation scripts and the takeover already run new
   code under an old loop.
4. **"Checked once" is too weak.** A broken `s*.sh` that times out on every
   agent produces a tick of all-OK verdicts, so `status: ok` proves the loop
   ran, not that it can see.

Replacement text:

> - **Code snapshots**: an instance never runs from the moving checkout. The
>   update holder exports `git archive <sha> csi-spl-orc` into
>   `dispatch/wd/code/<sha>/`. `dispatch/wd/code/good` is a symlink to the last
>   sha that passed the roll, and `candidate` is the sha being rolled.
>   `spl_wd_inst_start` always starts `good`, so peers, the keeper and a reboot
>   can never spread a bad commit. Keep the last 3 snapshots.
> - **Detect**: at each tick an instance compares the checkout HEAD with
>   `good`. A changed sha whose `orc/` tree is unchanged only moves `good`, with
>   no restart, because most commits do not touch the watchdog.
> - **Roll** (under `update.lock`; the holder is instance 1, or the lowest live
>   instance): (0) the candidate snapshot passes the fast fixture subset of
>   `wd-situations.tst.sh` (S3 hit, S9 hit, controls 1 and 4) run from the
>   snapshot. (1) The holder **self-execs** into the candidate at its tick
>   boundary (`exec`, which keeps its lock fd and its pid, never killed
>   mid-action) and must complete one tick that judged at least 1 agent with
>   0 script timeouts. (2) It hands the baton (`update.next = 2`). Instances
>   sleep in 5 s slices and check the baton, so the next one execs within 5 s,
>   not at its next 30 s tick. (3) The same for 3. (4) `good` = candidate.
>   Time: detect up to 30 s + 3 x (up to 5 s + one tick of about 2 s) = about 60 s,
>   inside WD3's 2 min with margin (C11, n=1 tick, 15 agents).
> - **Stop**: a failure at (0) or (1) means the holder re-execs into `good`,
>   the candidate is marked `bad` (never rolled again; the next commit is a new
>   candidate), and one admin message names the sha and the failing step.
>   Live instances never drop below 2, and bad code never runs on more than 1.
> - The keeper is the exception: cron runs it from the checkout. It stays tiny
>   and only calls `spl_wd_inst_start`, which starts `good`.

### 10.4.5 Admin alerts - AGREE, with three edits

- "Down" = the instance's lock is free or it is hung (10.4.2), and it has stayed
  so for longer than one restart attempt (60 s). Without that, the 2-of-3 rule
  fires during a peer restart of a single kill, or never fires because the
  survivors restart fast.
- **Who sends**: the keeper (it survives all 3 instances) keeps
  `wd/inst.<n>.down_since` and sends both alerts. The hub sends the
  all-3-down / cross-box alert (10.4.3). Note that the keeper's current alerts
  go to the orchestrator plus an `ASKS_OWNER` DM (C9). WD5 moves them to 11.2
  admin messages, so name the keeper's DM as replaced, not kept.
- 10.4.3 says "warning note to the orchestrator" and Q14 says "alert admin": pick
  one. It should be the admin message, from the hub, once.

### 10.4.6 Tests and controls - AGREE with the table, ADD these rows

| case | expected | control |
|---|---|---|
| 3 instances, one agent hits S3 for 2 real ticks | exactly 1 takeover; `<id>.takeovers` = 1; S3 confirmed only after about 2 x `WD_TICK`, not about 10 s | 1 instance -> same counts (the pool equals one loop) |
| 3 instances, S6 re-poke | exactly one `C-c` reaches the pane (stub `spl_wd_key`, count calls) | judge lock removed (seam) -> 2 or 3 calls: the test proves the lock matters |
| bad candidate halted, then kill instance 2 | instance 2 restarts on `good`'s sha | none: this IS the stop rule's proof |
| full disk (heartbeat write fails on all 3) | 0 peer kills; keeper alert | one heartbeat writable -> normal judgement |
| all 3 instances dead, keeper alive | hub: box UP, `wd_count` 0, one admin message; 0 lane CAS | keeper dead too -> box down -> 10.2 CAS |
| suspend 10 min, resume | 0 peer kills on the first tick | - |
| a 120 s tick (stub a slow S7 answer) | no hung verdict (`progress_seq` advances) | progress frozen 180 s -> hung |

## 3. Holes against WD1..WD5

| answer | hole |
|---|---|
| WD1 "3 per box, as daemons" | met by 3 detached `setsid` processes. "Daemon" does not require systemd (Q13). The cross-box check is unobservable as drafted (10.4.3) |
| WD2 "all 3 active" | met only with the judge lock. As drafted, "active" means 3x the state writes and 3x the keys (10.4.1) |
| WD3 "restart them" (one at a time, next only after the previous is back and checked once, within 2 min) | the sequence is right. The checkout is not a rollback point and other restart paths spread the new code (10.4.4). The 2 min holds only with a baton, not with 30 s tick polling |
| WD4 "hung after 3 missed checks" | 3 x 30 s = 90 s is shorter than a legitimate dialog tick. Keep "3 checks" as the owner's words, but a check is a heartbeat slot, and the floor is 180 s |
| WD5 "not back within 5 min, or both down at once" | who measures and sends is unnamed. The instances cannot send when all 3 are dead, so it has to be the keeper and the hub |

Also: 17.5's cut-over (legacy loop + instance 1 side by side) collides on
`tick/` and `ctx/` unless instances use per-instance dirs. Its step 5 (enable
systemd units) is a root step. Simpler: the keeper does the cut-over. The
commit that adds instances also teaches the keeper to start 1..3 from a
snapshot, then TERM the legacy `run.lock` holder once all 3 have ticked. The
legacy loop never sees the judge lock, so overlap must stay under one tick: it
takes no judge lock, and per-agent state races for that one tick.

## 4. Q12, Q13, Q14

- **Q12: keep (a) 2 of 3**, with "down" defined as above (more than 60 s, past
  one restart attempt). In the owner's 2-per-box wording, "both down" meant "no
  coverage left OR redundancy gone". 2 of 3 is the earliest common-cause signal
  (bad update, disk, OOM), and a rolling update never takes 2 down. All 3 down
  is covered too, but only the keeper or the hub can see it.
- **Q13: flip to (b), no systemd.** (1) A system unit in `/etc` is a root
  change on every box. On this fleet that is an owner step, which breaks
  "consensus, then build, no go", and every new box needs it again. (2)
  `Restart=always` is a third starter that fights the peer restart and the
  keeper. A peer-started instance 2 makes systemd's own instance 2 fail
  `flock -n`, exit, and restart every 5 s until `StartLimitBurst` marks the unit
  failed. A peer kill of a unit-owned pid also races systemd's restart. (3) The
  rolling update wants `exec` in place, and `systemctl restart` needs root or
  polkit from the box user. (4) The owner's "daemon" is met by today's
  `setsid nohup` detach. Peers (seconds) plus the keeper (60 s, survives all 3)
  are already two independent restarters, plus the `@reboot` keeper run. If the
  owner wants systemd later, make it the ONLY starter (peers and keeper just
  kill, `ExecStart` starts `good`) and treat that as a separate owner-installed
  step.
- **Q14: keep (a)**, re-defined as "keeper beat fresh, 0 instance beats", sent
  once by the hub as an admin message. Option (b) would fire on every rolling
  update.

## 5. T023..T027

- **Order**: right in spirit (T023 first, T025 and T026 after it, the drill
  last). But T023, T024, T025 and T026 all own `orc/run/spl-watchdog.func.sh`,
  so they cannot run in parallel as the graph allows (T025 and T026 are both
  "after T023"). Either serialise them, or move the new logic into new files
  (`spl-wd-peers.func.sh`, `spl-wd-self-update.func.sh`, `spl-wd-alert.func.sh`)
  so each task owns one file plus a one-line call site.
- **T023** is too big (instances, judge lock, peers, hung, dedup, systemd).
  Split it: **T023a** instances + judge lock + per-instance dirs. Test: the
  S3-twice and S6 rows of 10.4.6. Control: the seam. **T023b** peers + hung +
  `spl_wd_inst_start` + keeper. Drop `spl-wd-install-service.func.sh` (Q13).
- **T024** needs a migration (`box_beats` gets `inst`) and the keeper beat. Its
  control "remote fenced -> 10.2 guest CAS activates" is T018's. Replace it
  with the "keeper alive, 0 instances -> 0 CAS" row. The file is
  `csi-spl-api/src/go/spool-hub-api/...`, not `api/internal/...`.
- **T025** owns `orc/run/spl-watchdog.func.sh` and the new self-update file.
  Add the `code/<sha>` snapshots and `good`. The missing control: after a halt,
  a killed instance restarts on `good`.
- **T026** must name the keeper as the sender and remove the `ASKS_OWNER` DM path
  it replaces. Its test "hold its restart lock for 301 s" holds a lock the
  design must never let anyone hold that long; use a start stub that fails.
- **T027** path: `csi-spl-doc/specs/102-agent-lifetime/drill-wd-redundancy-<date>.md`.
  Add one scenario: all 3 killed with the keeper alive (box stays up, no lane
  moves).

## 6. Scores (1 weak .. 5 strong), v1.1-draft as written

| axis | score | why |
|---|---|---|
| robust | 2 | 3 writers on unlocked per-agent state and unlocked keys turn redundancy into double actions (one restart counts as two, a double `C-c` exits a session) |
| failover-proof | 2 | 0 watchdogs = 0 beats = the box is read as down, so lanes move while the old copies run. A bad commit spreads through every restart path except the update |
| simple | 2 | three starters (systemd, keeper, peers), two dedup schemes, a root install step. The judge lock + one start function + `good` snapshot is less code |
| uninterruptible | 3 | the rolling order is right and never goes below 2 live. But a 90 s hung rule can kill a healthy instance mid-key-sequence, and suspend/full disk can trigger mutual kills |

With the replacements above I would score it 4 / 4 / 4 / 4.

<!-- last-edit: 2026-10-07T10:55:00Z -->
