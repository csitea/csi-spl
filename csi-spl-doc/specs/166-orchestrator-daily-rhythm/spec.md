# Spec 166: the orchestrators' daily rhythm (day and night window)

Version **v0.3** (2026-10-29), the owner's poll answers folded in (section 7:
Q1 A, Q2 B, Q3 A, Q4 A, Q5 A, Q6 A). v0.3: bugs shift to the night with
refactoring (3.1, B2, B4); the zombie age is 7 days and the cap 500 (3.2); the
reflection is a Qto page (3.3); weekends are the same window (4.5); bypass rows
are placed at any hour (3.1, 6). v0.2: review W1, the zone is `Europe/Berlin`,
not `TZ=CET` (0.2, 4.1, B1).
Placement slug `c002-s166-daily-rhythm-spec`. Epic **SPL-2129**. Issue
**SPL-4217**. Class: feature. Kind: specs_and_docs (agy is the main vendor
for specs; agy is out until 2026-11-03, so claude writes this draft).
Gate spec line: `csi-spl-doc/specs/135-work-process`.
Next free number on `origin/master` checked: `git ls-tree --name-only
origin/master csi-spl-doc/specs/ | tail -2` -> `165-agy-orchestrator-watcher-seats`,
`README.md`; no remote branch names this spec (`git ls-remote origin
'refs/heads/review/*' | grep -iE '166|rhythm'` -> nothing).

This spec changes nothing by itself. It lists what runs on a clock for the
orchestrator and dispatcher roles today, says which of it moves to a nightly
window, defines the new night jobs, and lists the build rows. The owner's
choices were one poll, section 7, now answered in full.

## 0. The owner's order and the baseline

### 0.1 The order (HUM-10, t1, 2026-10-29)

- Topic `5d1c5023-8e41-4af4-898c-ca82af18bba6`, msg `fc06e0dc`: "we need to
  define daily rythm to the orchestrators ..."
- Topic `c0b0d572-c575-4849-8792-4c3ce4d170f2`, msg `421e479a`: "the majority
  of the refactoring , clean up old zombie discussions , internal reflections
  and refactoring jobs shoould be performed each 24h , starting from 20:00 till
  07:00 CET".

### 0.2 The window, in every clock the fleet uses

The rule is stated in Central European time: **night = 20:00 to 07:00
CET/CEST**, day = the rest. CET/CEST is read from the tz database zone `Europe/Berlin` (CET in winter,
CEST in summer); the code reads the hour with `TZ=Europe/Berlin date +%H`,
never a fixed UTC offset and never `TZ=CET`: box 1 has no
`/usr/share/zoneinfo/CET` (`ls` -> No such file or directory), so glibc reads
`TZ=CET` as a POSIX zone name with no offset, which is UTC (`TZ=CET date +%H`
-> `12` at 12:3xZ, 2026-10-29, n=1). Checked on box 1:
`TZ=Europe/Berlin date -d 2026-01-15T19:00Z +%H:%M%Z` -> `20:00CET`, the same
for `2026-07-15T18:00Z` -> `20:00CEST`; `2026-01-15T06:00Z` -> `07:00CET`,
`2026-07-15T05:00Z` -> `07:00CEST`.

| period | CET/CEST (the rule) | UTC | box-local `Europe/Helsinki` (EET/EEST) |
|---|---|---|---|
| winter (CET = UTC+1), e.g. today | night 20:00-07:00 | **19:00Z-06:00Z** | 21:00-08:00 |
| summer (CEST = UTC+2) | night 20:00-07:00 | **18:00Z-05:00Z** | 21:00-08:00 |

The EU switches CET/CEST and EET/EEST on the same dates, so in Helsinki time
the window is 21:00-08:00 the whole year. That matters because **crontab
fields run in the box's local zone**, not UTC: on box 1 `date` -> `Thu Oct 29
12:22:57 EET 2026` (n=1, 2026-10-29T10:22Z). Box 2's zone was not measured.
A cron line that must follow the window either uses Helsinki hours or (the
safe form, row B1) runs every N minutes and asks `do_spl_rhythm_phase`.

### 0.3 Baseline facts (measured 2026-10-29, tree `e3a00cecb`, n=1 each)

- Class share of the live lanes:
  `SPAWN_SHARE_FORMAT=line ./run -a do_spl_spawn_share` (csi-spl-orc, desk-cron
  checkout at `e3a00cecb`, 10:25Z) -> `share of 21 known live lanes (16
  unknown, left out): refactor 0 0% (band 20-30%: UNDER), bug 1 4% (band
  20-30%: UNDER), feature 20 95% (band 40-%: ok); 647 bypass(es)`.
  Refactoring is at 0% at mid-day: the bands alone do not produce refactor
  work; supply does (section 2.3).
- Idle discussions in prd tenant t1, not archived (`ENV=prd SQL="select
  count(*) filter (where last_at < now() - interval '3 days') as idle3, ...
  from topic_heads where tenant_id='t1' and not card_archived" ./run -a
  do_spl_db_query`, about 10:35Z) -> idle3 **7741**, idle7 **6443**, idle14
  **4158**, open total **9692**. `topic_heads` is rdb
  `0144_topic_heads.sql:62`; a soft archive is `messages.archived_at`
  (`0065_messages_archived.sql:16`). This count includes agent task topics;
  section 3.2 narrows it.
- No zombie-discussion cleanup exists: `git grep -lnE 'spool archive|archive --'
  -- csi-spl-orc/src/bash/scripts csi-spl-orc/cnf` -> no file. Topic archive
  exists only as a manual verb (`spool archive`,
  `csi-spl-api/src/go/spool-hub-api/internal/action/archive.go`, CLE-77869).
- No reflection job exists. The nearest thing is the round retrospective
  (`rounds-rulebook.md` R8, files `refactor-round-<N>-retro.md`, last
  `refactor-round-16-retro.md`), written per round, not per day.

## 1. Goals and non-goals

### 1.1 Goals

1. One shared definition of day and night (`do_spl_rhythm_phase`), read by
   every job that changes behaviour by hour.
2. At night the placer prefers refactor and bug rows (a band shift by hour,
   poll Q2 B), so the majority of refactoring and bug fixing runs 20:00-07:00
   CET while each 24 h share stays in the owner's 20-30% band, and the day
   keeps more room for features.
3. A nightly zombie-discussion sweep with a measurable definition.
4. A nightly reflection job that writes a review of the day and turns it into
   at most a few rows for the next night.
5. Owner-facing work keeps its promise round the clock: answers within 3 min
   (the unanswered sweep) are never moved to a window.

### 1.2 Non-goals

- No change to the role rotation cadence (spec 060, hourly), to the GC slots,
  or to the reliability checks (spec 146).
- No new work class; the classes stay `ci`, `refactor`, `bug`, `feature`.
- No quiet hours for the owner: the owner may post at any hour and is
  answered as by day.

## 2. Inventory: what runs on a clock today

### 2.1 How it was read

- Box 1: `sudo -u <box user> crontab -l` and `sudo -u <agent user> crontab -l`,
  2026-10-29T10:2xZ (box user: 56 `csi-spl:` lines; agent user: 1 line).
- Box 2: the same command, run by the orchestrator there on request, reply msg
  `99c83c38` at 10:22Z (box user: 62 `csi-spl:` lines plus lines of other
  projects, left out here; agent user: 1 line).
- Activity: the jobs' own logs under `/var/csi/csi-spl/` on box 1.
- "Today" says when the job runs against the window of 0.2; "24h" = every
  hour.
- Cost: agents started where the log shows it; tokens were **not measured**
  (the token-burn collector exists, row `token-burn`, but no per-job split of
  it was read for this draft).

### 2.2 The table

Only jobs that belong to, or are driven by, the orchestrator and dispatcher
roles (placing, rotation, sweeps, rounds, owner-facing timers). Pure box
upkeep is in 2.4, one line each.

| # | job (crontab tag) | where defined | schedule | boxes | what it costs | today | spec 166 |
|---|---|---|---|---|---|---|---|
| 1 | orchestrator rotation (`csi-spl:orch-rotate`) | `csi-spl-orc/src/bash/scripts/orch-rotate-cron.sh:4`; install `src/bash/run/spl-peer-crons.func.sh:8`; `specs/060-role-rotation/spec.md:19` (R3) | `5 * * * *` | 1, 2 | at most 1 new orchestrator session an hour; skips a young holder (`GATE SKIP young: pid ... 3158s old (< 3300)`, 10:05Z) | 24h | **stays** |
| 2 | dispatcher rotation (`csi-spl:dispatch-rotate`) | `src/bash/scripts/dispatch-rotate-cron.sh:5`; install `spl-peer-crons.func.sh:8` | `15 * * * *` | 1, 2 | at most 1 new dispatcher session an hour (`GATE SKIP young: the last rotation was 2779s ago`, 10:15Z) | 24h | **stays** |
| 3 | dispatcher heal (`csi-spl:dispatch-heal`) | `dispatch-rotate-cron.sh:6` | `1-59/3 * * * *` | 2 (not in box 1's crontab) | script; an agent only when a seat is dead | 24h | **stays** |
| 4 | lane rotation, every agent under 60 min (`box-cron:lane-rotate`) | `csi-spl-orc/cnf/box-crons/box-crons.manifest:24`; `src/bash/scripts/lane-rotate-cron.sh` | `* * * * *` | 1, 2 | box 1, 2026-10-28: 122 `START` lines (a new session each) in `lane-rotate/cron.log` | 24h | **stays** |
| 5 | GC agent (`box-cron:gc`) | `box-crons.manifest:32`; slots `csi-spl-orc/cnf/gc/gc.conf` (`slot 00 claude`, `slot 30 grok`, `GC_AGENT_CAP=180`) | every minute, acts at :00 and :30 | 1, 2 | 2 GC sessions an hour a box (box 1 `gc/cron.log`: `START ...0830Z... grok`, `0900Z claude`, `0930Z grok`, `1000Z claude` on 10-29), at most 180 s on each agent | 24h | **stays**; the night sweep (B6) is a script, not a GC task |
| 6 | unanswered sweep, owner answer in 3 min (`csi-spl:unanswered-sweep`) | `src/bash/scripts/unanswered-sweep-cron.sh:6`; install `spl-peer-crons.func.sh:9`; `SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5` in box 1's line | `* * * * *` | 1, 2 | script, 1440 runs a day; agents only through the escalation | 24h | **stays** (goal 5) |
| 7 | asks timer, `ASKS STILL OPEN` re-raise | `src/bash/run/spl-asks-tick.func.sh:224`, run by the dispatch lease loop (not cron) | each lease-loop tick | every box with the lease loop | posts to every live DO seat | 24h | **stays** |
| 8 | placer: spawn queue, bands, supply blocker (`csi-spl:spawn-place`) | install `src/bash/run/spl-spawn-place-install-cron.func.sh:34`; bands `SPL_SPAWN_BANDS` `src/bash/run/spl-spawn-share.func.sh:25`; band pick `spl-spawn-place.func.sh:37-46`, `:263`; supply `:226-248`; rule home `csi-spl-doc/doc/md/fleet-rules-index.md:53` | `* * * * *` | 1, 2 | every lane placed is an agent; refactor 20-30%, bug 20-30%, feature rest, the same at every hour | 24h | **moves**: bands by phase (B2), supply lead (B3) |
| 9 | idle filler (`csi-spl:spawn-fill`) | install `src/bash/run/spl-spawn-fill-install-cron.func.sh:36`; classes `spl-spawn-fill.func.sh:145-153`; rule `fleet-rules-index.md:54` | `*/10 * * * *` | 1 | queues bug/feature issues when the queue is empty; latest tick: `the spawn queue is not empty (30 queued, 0 placing): nothing to fill` | 24h | **moves**: the night fill takes bug issues only (B4, poll Q2 B) |
| 10 | refactor / bug rounds (planner, rows, reviewer seats, retro) | `csi-spl-doc/doc/md/rounds-rulebook.md` 1.4 (continuous, no owner go), R8 (retro, then the next planner), R10 (hourly placement check); last plan `refactor-round-17-plan.md` | no clock: started by the dispatcher on the supply blocker or the previous retro | either | round 16: 10 actions, "2 row lanes in parallel" | whenever | **moves**: planner by day, rows at night (B3) |
| 11 | security round queue (`csi-spl:security-round`) | install `src/bash/run/spl-security-round-install-cron.func.sh:36` | `30 * * * *`, acts when `date -u +%u%H` = `505` (Fri 05:30Z) | 1 | one round a week | night in winter; day in summer (05:30Z is after 05:00Z) | **stays weekly**, pinned to the phase (B7) |
| 12 | owner digest (`box-cron:owner-digest`) | `box-crons.manifest:27`; cnf `csi-spl-cnf/csi-spl/prd.env.yaml:477` (`hour: 9`, `timezone: Europe/Helsinki`) | `7 * * * *`, posts once a day at 09 Helsinki (07:00Z winter) | lease holder's box | script, one post | day | **stays**; links the reflection (row 20) |
| 13 | topic status cards (`box-cron:topic-status-card`) | `box-crons.manifest:35` | `*/5 * * * *` | 1 (not in box 2's crontab); acts on the lease holder's box | script | 24h | **stays** |
| 14 | issue closer (`box-cron:issue-close-landed`) | `box-crons.manifest:28` | `*/5 * * * *` | 1, 2 | script | 24h | **stays** |
| 15 | done-claim check (`box-cron:done-claim-check`) | `box-crons.manifest:29` | `*/5 * * * *` | 1, 2 | script | 24h | **stays** |
| 16 | QAS CI accept (`box-cron:qas-ci-accept`) | `box-crons.manifest:26` | `23 * * * *` | 1, 2 | script | 24h | **stays** |
| 17 | CI red note (`box-cron:ci-red-note`) | `box-crons.manifest:22` | `*/10 * * * *` | 1, 2 | script; CI fix rows go to the queue head (`ci`) | 24h | **stays** |
| 18 | issue key rate (`box-cron:issue-key-rate`) | `box-crons.manifest:31` | `53 6 * * 1` (Mon 06:53 local) | in the manifest, in neither crontab read | script | day | **stays** (not installed: reported, section 6) |
| 19 | zombie-discussion cleanup | none (0.3) | none | none | none; 6443 t1 topics idle 7+ days | none | **new**: B5, B6 |
| 20 | reflection job | none (0.3) | none | none | none | none | **new**: B8 |
| 21 | weekly full scan (`csi-spl:weekly-full-scan`) | install role `csi-spl-iac/src/terraform/060-gcp-vm-satellite/roles/10_rotation_cron/tasks/main.yml:69` | `0 17 * * 5` (Fri 17:00 Helsinki = 15:00Z winter) | 1 | the slow scanners, CPU on the runner box | day | **moves** to Fri 21:00 Helsinki (B7) |
| 22 | merged-branch prune (`csi-spl:git-prune-merged`) | install `src/bash/run/git-prune-merged-install-cron.func.sh:25` | `47 * * * *` | 2 | script | 24h | **stays** |
| 23 | round branch prune (`do_git_prune_round_branches`) | `src/bash/run/git-prune-round-branches.func.sh`; run by the retro lane (R8) | no clock | the retro lane's box | script | with the retro | **moves** with the retro to the night |
| 24 | graft index refresh / final (`box-cron:graft-index-*`) | `box-crons.manifest:18-19` | `*/15 8-19 * * *`, `0 20 * * *` (Helsinki) | 2 | script | day, final at 20:00 Helsinki | **stays** (already day-only) |

### 2.3 What the inventory says

- Nothing role-related changes by hour except rows 11, 12, 21, 24 (fixed
  clock times). The placer, the filler and the rounds run the same at 03:00
  as at 14:00.
- The refactor band does not fill itself: the placer only *orders* queued
  rows; when no refactor row is queued it sends one supply blocker an hour
  (`spl-spawn-place.func.sh:226-248`) and the dispatcher must start a round.
  At 10:25Z refactor was 0%. A night band without supply would change
  nothing, so B3 moves the supply ahead of the night.

### 2.4 Box upkeep (not role work, all stay)

Listed so the inventory is complete; both boxes unless noted. The spec 146
reliability rows `rel-*` (`box-crons.manifest`, under its `# reliability
round` comment): systemd-unit, reboot-required (`7 4 * * *`), cert-expiry
(`13 6 * * *`), external-api, tmux-health, orphan-process, docker-prune,
gh-runner, clock-sync, cron-snitch, box-beat. Also: box-restart (`--at '0
04:30 Europe/Helsinki'`, `src/bash/scripts/box-restart-cron.sh:6`, night
already), desk-reconcile (dev `*/3`; prd `1-59/5` box 1, `1-59/3` box 2),
agent-identity-reconcile, spawn-remote, wd-start, box-stats, go-cache-prune,
disk-headroom, box-disk-sweep, disk-growth (`23 3 * * *`), docker-prune (`23 4
* * 0`), cost-rollup (`0 5 * * *`), box-state-backup (`41 2 * * *`, box 2),
msg-unreadable (`17 7 * * *`), box-save-sessions, agent-login-check,
login2-sync, uplink-probe, reverse-tunnel (box 2), token-burn,
push-orphan-check, restore-drill-red-note, agent-id-reap, fx-rates-fetch,
weekly-limit-alert, archived-seats-free, file-streams, poll-ack (box 1),
env-order (box 1), gh-runner-cpu-budget, shadow-feed (box 2), ci-overflow
(box 2), box-update (box 2), vendor-terms-check, and the agent user's
tmp-scratch-sweep (`17 * * * *`).

## 3. The rhythm

### 3.1 Day and night

| | day: 07:00-20:00 CET/CEST (06:00Z-19:00Z winter) | night: 20:00-07:00 CET/CEST (19:00Z-06:00Z winter) |
|---|---|---|
| owner answers | within 3 min (unanswered sweep, row 6) | the same, within 3 min |
| placer bands (B2) | refactor **10-20%**, bug **15-20%**, feature the rest (60-75%) | refactor **40-60%**, bug **30-40%**, feature the rest (0-30%) |
| idle filler (B4) | bug and feature issues, as today | bug issues only (poll Q2 B) |
| owner-approved bypass rows | placed as today | placed as today (poll Q6 A) |
| refactor rounds (B3) | the planner and its panel | the round's row lanes, reviewer seats, the retro |
| new jobs | none | zombie sweep (B5, B6), reflection (B8) |
| rotation, GC, CI fixes | as today | as today |

**The 24 h shares stay in the owner's bands** (refactor 20-30%, bug 20-30%,
feature the rest; `fleet-rules-index.md:53`). The owner chose poll Q2 B: bugs
shift to the night with refactoring, and the day keeps more room for
features. With 13 day hours and 11 night hours and the same lane count, the
time-weighted 24 h shares are:

| class | day band | night band | 24 h, low ends | 24 h, high ends |
|---|---|---|---|---|
| refactor | 10-20% | 40-60% | `(13 x 10 + 11 x 40) / 24 = 23.75%` | `(13 x 20 + 11 x 60) / 24 = 38.3%` |
| bug | 15-20% | 30-40% | `(13 x 15 + 11 x 30) / 24 = 21.9%` | `(13 x 20 + 11 x 40) / 24 = 29.2%` |

The refactor high end is over 30%, so the share report (B2) also prints the
**last 24 h weighted share** per class, and the placer stops preferring a
class at night once its 24 h share reaches 30% (refactor or bug alike). The
night then carries the bigger part of the refactoring and the bug fixing,
which is what the owner asked ("the majority"); features get 60-75% of the
lanes by day and 0-30% at night. CI fix rows keep the queue head at every
hour, and owner-approved feature bypass rows are placed at any hour as today
(poll Q6 A), outside the bands.

### 3.2 A zombie discussion, measurably

A **zombie discussion** is a topic whose topic head (rdb `topic_heads`)
satisfies **all** of:

1. `not card_archived`;
2. `last_at < now() - 7 days` (poll Q1 A; cnf `env.rhythm.zombie_idle_days: 7`);
3. no hub ask on it in state open, acked, queued or placing
   (`do_spl_asks_open`);
4. no live lane on it (`do_spl_lane_map`: no lane whose task or brief names
   the topic uuid);
5. no issue in `eval`, `todo`, `wip` or `blocked` whose description starts
   with `Source: /t/<uuid>` of this topic (spec 135 Q4);
6. not a DM thread (`dm_last_at IS NULL`) and not in `topic_priorities`.

The sweep **archives** a zombie (the soft card archive of rdb 0065, which
`unarchive` reverses) and never deletes one; a new post brings it back as
today. Each night it archives at most `ZOMBIE_MAX` = **500** topics (poll Q3
A; cnf `env.rhythm.zombie_max: 500`), oldest first, one log line per topic. The first night runs as a dry-run report only,
sent to the dispatch holder.

Size, for the cap: 6443 t1 topics are idle 7+ days today before conditions
3-6 (0.3). At 500 a night that backlog drains in 13 nights.

### 3.3 The reflection job

A **reflection** is a written review of the last 24 h, made once a night,
in the first quarter hour of the window (19:15Z winter):

- **Gathered mechanically** (one action, no tokens): CI reds per job
  (`CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`,
  csi-spl-iac), reverts on master (`git log --since=24.hours
  --grep='^Revert'`), lanes that ended without landing (lane issues ended
  `diss`), the owner's messages in t1 in the window (ids only), the class
  share and the 24 h share (B2), and the zombie count (B6).
- **Written by one lane** (class `refactor`, kind `specs_and_docs`, its main
  vendor, the backup when out): it reads the gathered file, marks which owner
  messages were **corrections** (the owner saying a rule was broken or a
  result was wrong), each with its msg id, and writes: reds, reverts, owner
  corrections, what each correction asks the fleet to change, and at most 3
  proposed rows (refactor or bug) with an `Epic:` and `Spec:` line each.
- **Where it goes** (poll Q4 A): a Qto doc page per day in the system
  workspace, **never git**: the repository is public and the owner's messages
  may carry private matter. Nothing is posted to a channel. The proposed rows go to the spawn queue
  with `SPAWN_CLASS=refactor|bug` through the normal enqueue gates, so they
  run the same night. The next morning's owner digest (row 12) links the
  page.

## 4. Behaviour in detail

1. `do_spl_rhythm_phase` prints `day` or `night` and exits 0. It reads cnf
   `env.rhythm` (`timezone: Europe/Berlin`, `night_start: 20`, `night_end: 7`;
   the sweep's `zombie_idle_days: 7` and `zombie_max: 500` live there too) and
   honours `RHYTHM_NOW=<ISO-8601>` for tests. Every row below calls it; no
   job does its own hour arithmetic.
2. The placer reads the phase each tick and takes its bands from
   `SPL_SPAWN_BANDS_DAY` / `SPL_SPAWN_BANDS_NIGHT`; the share report prints
   the phase, the bands it used and the last 24 h weighted share.
3. Supply lead: from 2 h before the night the supply check asks for refactor
   rows when fewer than twice the night's refactor lanes are queued, so a
   planner (day) has rows ready at 20:00 CET.
4. A once-a-night job runs from a cron line every 15 min and acts only when
   the phase is `night`, only on the dispatch lease holder's box, and only
   once per night (a stamp file per night date), the guard the owner digest
   uses.
5. Weekend (poll Q5 A): the same window every day, seven days a week; no
   weekend case in `do_spl_rhythm_phase`.

## 5. Build rows

Every row lands with its tests, a red control that fails on today's tree, and
its docs in the same commit (spec 135 lane rules). Files are disjoint per
batch.

| row | slug | files | test and red control |
|---|---|---|---|
| **B1** Implemented `2f46fc829` (SPL-4322) | `s166-b1-rhythm-phase` | `csi-spl-orc/src/bash/run/spl-rhythm-phase.func.sh` (new); `csi-spl-cnf/csi-spl/all.env.yaml` (`env.rhythm`); `csi-spl-cnf/src/python/conf-validator/EnvModels/all.py`; `csi-spl-orc/src/bash/tests/spl-rhythm-phase.tst.sh` (new); `csi-spl-doc/doc/md/fleet-rules-index.md` (new row) | `RHYTHM_NOW=2026-01-15T18:59Z` -> day, `2026-01-15T19:00Z` -> night, `2026-07-15T18:00Z` -> night, `2026-07-15T05:00Z` -> day, `2026-01-15T06:00Z` -> day. **Red:** a variant with a fixed `+1` offset fails both July cases. A variant reading `TZ=CET` fails the 19:00Z winter case on a box with no `zoneinfo/CET` (it reads 19, not 20). conf-validator refuses `night_start` outside 0..23. |
| **B2** | `s166-b2-bands-by-phase` | `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh`; `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh` (band pick only); `csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh`; `csi-spl-orc/src/bash/tests/spl-spawn-place-argmax.tst.sh`; `fleet-rules-index.md` row at line 53 | bands day `refactor 10-20, bug 15-20`, night `refactor 40-60, bug 30-40`. At night with refactor 35% and one refactor and one feature row queued, the placer takes refactor; at night with bug 25% and one bug and one feature row queued, it takes bug; by day both inputs take feature; last 24 h refactor share at 30% -> the night takes feature over refactor (the same for bug); an owner-approved bypass row is placed at night as by day (Q6 A). **Red:** on today's tree both night cases take feature (one band set). |
| **B3** | `s166-b3-supply-lead` | `spl-spawn-place.func.sh` (supply block only, after B2 lands); `csi-spl-orc/src/bash/tests/spl-spawn-place-supply.tst.sh` (new); `csi-spl-doc/doc/md/rounds-rulebook.md` (1.4: planner by day, rows by night) | 2 h before the night with 0 refactor rows queued the holder gets one blocker naming the night; at noon with the same queue only today's hourly one. **Red:** today no blocker is sent ahead of the night. |
| **B4** Implemented `e0c06c9b3` (SPL-4502) | `s166-b4-fill-by-phase` | `csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh`; `csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh`; `fleet-rules-index.md` row at line 54 | at night with one `feature` and one `bug` issue todo only the bug is queued (poll Q2 B); by day both classes as today. **Red:** today the night tick queues the feature. |
| **B5** | `s166-b5-hub-zombie-list` | `csi-spl-api/src/go/spool-hub-api/internal/hub/` (a read-only list of idle topic heads: `idle_days`, `limit`; conditions 1, 2 and 6 of 3.2 in SQL) and its `_test.go` on Postgres | a topic idle 8 days -> listed; idle 8 days but archived, a DM, or prioritised -> not listed; idle 6 days -> not listed with `idle_days=7`. **Red:** the endpoint does not exist (404). **Implemented** (SPL-4323): `GET /v1/operator/zombie-topics?idle_days=<1..3650, 7>&limit=<1..5000, 500>` -> `{as_of, idle_days, limit, idle_before, topics: [{task_id, last_at}]}`, oldest first; the operator workspace's admin or the operator service account (the fleet-load doors); `hub/zombie_topics.go`, the SQL in `store/zombie_topics_postgres.go` (the memory store answers 501); landed `a59be211a` (W1 test `02070428f`), served on dev and prd as v6.8.4 since 2026-10-30. |
| **B6** | `s166-b6-zombie-sweep` | `csi-spl-orc/src/bash/run/spl-zombie-topics.func.sh` (new: conditions 3-5 against asks, lane map and issues; `DRY_RUN=1` default; `ZOMBIE_MAX`); `csi-spl-orc/src/bash/scripts/zombie-topics-cron.sh` (new); `csi-spl-orc/cnf/box-crons/box-crons.manifest` (row `zombie-topics`, `*/15 * * * *`); `csi-spl-orc/src/bash/tests/spl-zombie-topics.tst.sh` (new); `csi-spl-doc/doc/md/gc-agent.md` (pointer) | a fake hub list of 3 candidates, one with an open ask and one held by a live lane: only the third is archived; by day nothing runs; a second tick the same night does nothing; `DRY_RUN=1` archives nothing. **Red:** the archive call for the topic with the open ask. Needs B1, B5. |
| **B7** Implemented `42e062de1` (SPL-4506) | `s166-b7-fixed-clocks` | `csi-spl-iac/src/terraform/060-gcp-vm-satellite/roles/10_rotation_cron/tasks/main.yml` (weekly full scan to Fri 21:00 Helsinki); `csi-spl-orc/src/bash/run/spl-security-round-install-cron.func.sh` (act on Friday in phase `night`, not on `%u%H = 505`); their tests | the security round acts on a Friday 02:00Z in July (night) and not on Friday 05:30Z in July (day). **Red:** today it acts on Friday 05:30Z in July. **Implemented** (SPL-4506): the line acts on a UTC Friday when `./run -a do_spl_rhythm_phase` says night (the queue is idempotent per date, so one round a Friday); the weekly scan line is `0 21 * * 5` in `install-weekly-full-scan-cron.func.sh`, which owns the hour (the role runs that action). A box picks it up when its line is re-installed: `DRY_RUN=0 ./run -a do_spl_security_round_install_cron` (orch holder's call) and the satellite role, each with the owner's go. |
| **B8** | `s166-b8-reflection` | `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh` (new); `csi-spl-orc/src/bash/scripts/reflection-cron.sh` (new); `box-crons.manifest` (row `reflection`, after B6); brief template `csi-spl-orc/src/bash/features/dispatch/brief-reflection.tpl.md` (new); `csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh` (new); `csi-spl-doc/doc/md/runbook-dispatcher.md` (pointer) | on a fixture repo with one revert and a fake CI report with 2 reds the gathered file lists all three and the window's owner msg ids; the enqueued brief carries `Class: refactor`, `Epic:` and `Spec:` lines and passes the enqueue gate; nothing is written to git. **Red:** the same brief without its `Spec:` line is refused by the existing gate, and the test sees the refusal. Needs B1. |

Order: B1 first; then B2, B4, B5, B7 in parallel (disjoint files); then B3
(after B2, same file), B6 (after B5), B8. The rows that touch
`box-crons.manifest` (B6, B8) land one after the other.

## 6. Not fixed here (reported)

- Manifest row `issue-key-rate` (`box-crons.manifest:31`) is in neither box's
  crontab as read on 2026-10-29. Reported to the dispatch holder with this
  spec; not a row of it.
- 647 recorded feature bypasses in the share report (0.3). The night bands
  do not touch bypasses: owner-approved bypass rows are placed at any hour,
  as today (poll Q6 A).

## 7. The owner's choices (one poll)

Posted by the dispatch holder in t1 `5d1c5023` (poll msg `d102c775`).
**Answered** by the owner (msgs `33fdf316` for Q1-Q5, `c6ad2e61` for Q6):

| Q | answer | folded into |
|---|---|---|
| Q1 | A, 7 days | 3.2 condition 2 |
| Q2 | **B**, bugs shift to the night as well (not the recommended A) | 1.1 goal 2, 2.2 row 9, 3.1, B2, B4 |
| Q3 | A, 500 a night | 3.2 |
| Q4 | A, a Qto doc page per day, never git | 3.3 |
| Q5 | A, the same window every day | 4.5 |
| Q6 | A, bypass rows placed at any hour | 3.1, 6 |

The poll as posted, recommended answers first:

```poll
Zombie discussion: idle how many days (and no open ask, no live lane, no open issue) before the nightly sweep archives it? Archive is reversible.
(A) 7 days (recommended)
(B) 3 days
(C) 14 days
(D) 30 days
Do bug rows also shift to the night, or only refactoring?
(A) Only refactoring shifts; bugs keep 20-30% day and night; the night filler takes bug issues, not feature issues (recommended)
(B) Bugs shift to the night as well; the day keeps more room for features
(C) Only the refactor band changes; the night filler still takes feature issues
How many zombie discussions may one night archive?
(A) 500: the backlog of about 6400 drains in about 13 nights (recommended)
(B) 100
(C) No cap
Where does the nightly reflection go?
(A) A Qto doc page per day in the system workspace, linked from the morning owner digest; never git, the repo is public (recommended)
(B) A post in the spool-hub-devel channel
(C) Both
Weekends?
(A) The same window every day (recommended)
(B) Saturday and Sunday are night all day: refactoring and cleanup only; owner answers as always
Owner-approved feature bypass rows at night?
(A) Placed at any hour, as today (recommended)
(B) They wait for the day
```

## 8. Hygiene

Org-neutral: no personal names, user names or host names; the boxes are
"box 1" and "box 2". Every count above carries its command, its time and the
tree it ran on (n=1 each).
