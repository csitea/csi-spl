# sat alone: readiness panel plan (v0.1)

Epic: SPL-2364
Spec: [146 reliability round](../../specs/146-reliability-round/spec.md)
Issue: SPL-2471
Owner topic: t1 `721ad6e4` (msgs `ceca67c2`, `97b1b11d`); task `dispatch-721ad6e4`
Rules: [rounds rulebook](rounds-rulebook.md) (R1-R16), [repo CLAUDE.md](../../../CLAUDE.md)
Prior design: [spec 064, the fleet without the PC](../../specs/064-fleet-without-the-pc/spec.md)

**Status: v0.1, ready for the panel.**
Editor: `c-399@sat` (claude). Reviewer seats: grok
(`sat-alone-panel/seat-grok.md`), mistral (`sat-alone-panel/seat-mistral.md`).

`<pc box>` stands for the owner's PC box tag, as in specs 064 and 068: box
tags other than `sat` are banned literals in this tree (the hygiene sweep in
`10_ci-quality.yml`). `sat` is the GCP satellite of spec 057.

## 0. One sha, and how this was measured

- Code and cnf lines are read on `origin/master` **`7b5ce46a4`**
  (2026-10-18, the lane's start).
- Live state was read on sat between 01:15Z and 01:45Z on 2026-10-18, as the
  box user, read-only: no prd mutation, nothing started or stopped.
- sat cannot open a shell on `<pc box>`: `ssh <pc box>` -> "Could not resolve
  hostname" (NAT), and the reverse tunnel's gate allows only `ping` and
  `lease` (`csi-spl-orc/src/bash/scripts/peer-ssh-gate.sh:20-29`). So every
  "`<pc box>` only" line below is **inferred**: it is in the repo or the
  fleet's state as a `<pc box>` thing AND absent on sat. No line was read on
  `<pc box>` itself. The drill's first run (section 5) reads them from a
  `<pc box>` agent.

## 1. What the owner asked (HUM-10, verbatim)

> ceca67c2: "I am going to travel by plane from Helsinki to Amsterdam today
> from 7 till 10:00, which means that the TAK box will be closed and not part
> of the production."

> 97b1b11d: "Which also means that I would like the production to continue
> with the pure cloud setup on the SAT box. With this discussion, I would like
> to start some kind of drill/checkup on whether this is completely possible,
> including the dev environment. There are some other drills which are
> concerning the security on the dev environment. I would like a mixture of
> experts, a panel of experts, to evaluate what the options are here and just
> to make sure that, whenever I inform 10 minutes beforehand: "Okay, I am going
> to close the TINK box. The production of intelligence will continue solely on
> the SAT box.""

("TAK" / "TINK" = `<pc box>`.) The window today is 07:00-10:00 Helsinki =
**04:00-07:00Z on 2026-10-18**.

## 2. Inventory: what prd and dev need that lives or runs only on `<pc box>`

Verdict per row: **covered** (sat does it today), **can** (sat can, a build
row makes it so), **waits** (stops while `<pc box>` is away and catches up on
its return), **cannot** (must not or cannot move to sat).

### 2.1 Roles, seats, lanes

| # | item | proof (command -> result) | verdict |
|---|---|---|---|
| 1 | orchestrator and dispatch leases | `LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease` -> `orch c-001@sat`, `dispatch c-003@sat`; sat `lease.conf`: `LEASE_PRIORITY_ORCH=sat,<pc box>,box-desk`, `LEASE_PRIORITY_DISPATCH=sat,<pc box>,box-desk` | **covered**: sat holds both and ranks first; nothing moves when `<pc box>` goes |
| 2 | legacy line `LEASE_PRIORITY=<pc box>,box-desk,sat` in sat's `lease.conf` | `grep -i priority /var/spool-hub/dispatch/lease.conf` -> 3 lines; the bare one ranks `<pc box>` first | covered (the per-role lines win); it misleads a reader. Noted, no row |
| 3 | role seats on `<pc box>` standing by (`c-001`..`c-003`, `g-001`..`g-003`) | `lane-map.sh \| grep '@<pc box>'` -> 6 role rows | covered: sat has its own `c-001`..`c-003`, `g-001` (`lane-map.sh \| grep '@sat'`) |
| 4 | lanes running on `<pc box>` | lane map 01:20Z: 16 rows `@<pc box>` (6 role seats, 4 restarted peer seats, 6 task lanes incl. the dedicated channel seat, a test-round row and a costs-tab lane) vs 18 `@sat` | **can**: `do_spl_box_leave` on `<pc box>` drains them (section 3); without it they freeze mid-task |
| 5 | placement keeps choosing `<pc box>` until it is silent 120 s | `./run -a do_spl_box_pick` on sat, 01:2xZ -> `pick=<pc box> reason=every box is at or above its high mark; <pc box> is the least past its band`; the drain marker `box.leave` is read only on the leaving box (`grep -rln box.leave csi-spl-orc/src` -> box-leave, box-join, `spawn-window.sh:151`, the leave test) | **can**, row 01: no cordon exists (`grep -rniE 'cordon\|offline.window' csi-spl-orc/src` -> 0) |
| 6 | DEGRADED rule | cnf `env.box.health` (`csi-spl-cnf/csi-spl/all.env.yaml:1119-1124`): `max_gap_s 120`, `hold_min 30`, `window_min 10`, `min_beat_pct 50`; used at `spl-box-pick.func.sh:107,172` and the pinned-row HOLD `spl-spawn-place.func.sh:276-300` | covered after the cut (~2 min); a returning box can stay degraded up to 30 min (`hold_min`) |
| 7 | queue rows pinned to `<pc box>` (finance lanes) | `spl-spawn-place.func.sh:298-300` -> "hold: ask ... is pinned to ...; it stays queued" | **waits** (by design) |
| 8 | the dedicated channel seat `c-423@<pc box>` | lane map row `c-423@<pc box>` "Dedicated seat: the ... spool channel"; owner order: only that seat talks there | **cannot** without an owner word: that channel is silent while `<pc box>` is away |
| 9 | spawn requests sent to `<pc box>` | `spawn-remote.sh` header: a request waits `SPAWN_REMOTE_WAIT` (300 s) for the receiver's tick | **can**, row 01 (a cordoned box is not picked, so no request) |

### 2.2 Crons

sat's live crontab against the manifest:
`crontab -l | grep -oE '# csi-spl:[a-z0-9:_-]+' | sort -u` -> 40 tags; of the
22 rows of `csi-spl-orc/cnf/box-crons/box-crons.manifest`, 15 are on sat and 7
are not:

| # | cron (manifest line) | what stops without `<pc box>` | proof | verdict |
|---|---|---|---|---|
| 10 | `issue-close-landed` `*/5` (`:28`) | issues of landed commits stay `wip` | `issue-close-landed-cron.sh:7-10`: ONE box acts, the one holding the cursor; sat's cursor dir `.../issue-close-landed/prd-t1` is empty (`ls -la` -> 3 lines) | **waits** (the cursor sweep catches up on return); **can** with row 03 |
| 11 | `reverse-tunnel` `* * * * *` (`:32`) | the `<pc box>` -> sat tunnel (sat's `127.0.0.1:2222` listener) | `setup-reverse-tunnel.func.sh` header; `ss -ltn` on sat -> `127.0.0.1:2222` | covered: it only exists to reach `<pc box>`; nothing on sat needs it while `<pc box>` is off |
| 12 | `fx-rates-fetch` daily 16:37 (`:35`) | the costs' second-currency rates, dev and prd | not in sat's crontab | **waits** (UPSERT on the next run, `fx-rates-fetch-cron.sh:3-6`); **can** with row 06. Which box runs it today: unverified |
| 13 | `issue-key-rate` Mon 06:53 (`:30`) | the weekly issue key rate row | not in sat's crontab | waits (not due on a Sunday); can with row 06 |
| 14 | `box-state-backup` 02:41 (`:21`) | the nightly copy of a box's box-only state | not in sat's crontab | not a `<pc box>` dependency, but **sat's own state gets no nightly copy today**; row 06 |
| 15 | `graft-index-refresh`, `graft-index-final` (`:18-19`) | the graft code index | not in sat's crontab; `command -v graft` on sat -> none | box tooling, not prd/dev; no row |
| 16 | already on sat (spec 064 rows 3-7, closed since) | dev desk reconcile (`*/3`, `ENV=dev`), prd reconcile, weekly full scan, spawn-remote serve, tmp scratch sweep (agent user), unanswered sweep, lane rotate, watchdog start, login check, owner digest, security round queue, cost rollup | the crontab grep above | covered |

### 2.3 Desks, responders, live services

| # | item | proof | verdict |
|---|---|---|---|
| 17 | prd desks and the prd responder on sat | `desk-reconcile/cron-prd.out`: `OK responder sweep (prd, holder): 1/1 tenant(s) handled, 0 failed`; 9 `spool hub-run` sidecars (`ps -eo args= \| grep -c 'spool hub-run'`) | covered |
| 18 | **dev desks on sat** | `desk-reconcile/cron.out`: `FAIL could not seat c-001 on sat` (and c-002, c-003) every tick; `grep -c "FATAL Command 'do_spl_desk_up_tenants'" cron.out` -> 913 | **can**, row 04. Cause not read by this lane. Today a dev topic gets no desk answer from sat |
| 19 | **dev responder on sat** | `grep -c 'responder sweep (dev): no sat-rsp desk seated' cron.out` -> 7152, of 7152 dev sweep lines | can, row 04. Whether `<pc box>` seats the dev desks today: not measured |
| 20 | live hub and WUI, dev and prd | `ENV=dev\|prd ./run -a do_check_deploy_lag` -> hub served `9c4397b6`, wui served `7b5ce46a`, `current` in both envs; `ENV=dev ./run -a do_spl_api_smoke` -> "every check passed" (run from the desk-cron tree at `a629ad83`) | covered: Cloud Run, no box |

### 2.4 CI, infra, browsers

| # | item | proof | verdict |
|---|---|---|---|
| 21 | CI runners | repo variable `SPOOL_CI_RUNNER` = `"ubuntu-latest"` (`gh variable list`); `gh api repos/csitea/csi-spl/actions/runners --jq .total_count` -> 0 (org: 0); last green wf 10 run `39085580284`: every job on a `GitHub Actions <n>` runner, label `ubuntu-latest` | covered: no box runs CI |
| 22 | infra stack (tf-runner, tpl-gen, conf-validator) | `docker ps` on sat -> `con-csi-csi-spl-{tf-runner,conf-validator,tpl-gen}` | covered (applies stay owner-gated) |
| 23 | headless Chrome for e2e and browser lanes | `command -v google-chrome` on sat -> present | covered for headless; a lane that needs a browser on the owner's screen cannot move |

### 2.5 Keys and logins (names and boxes only)

| # | item | proof | verdict |
|---|---|---|---|
| 24 | per-env project SA keys (dev, prd) | key name list on sat: `key-csi-spl-dev`, `key-csi-spl-prd` | covered |
| 25 | the relay and backup SA keys (`-rel`, `all`, `bkp`) | spec 064 row 13 lists them on the PC; sat's name list has none of them | waits; the panel found nothing in the prd/dev path above that needs one. Reviewers: look for one |
| 26 | finance integration keys (NetVisor, bank) | owner order: on `<pc box>` only, not in Secret Manager (fleet record of owner msgs `072a9990`, `c0bcb7b1`) | **cannot**, by owner order |
| 27 | the owner's directive signing key | `csi-spl-orc/src/bash/features/directive/README.md:48-54`: each box the owner types at has its own key; a box without one verifies and cannot issue | waits for a directive typed at `<pc box>`; the owner can type at sat or in the WUI |
| 28 | the agent login on sat | all claude seats on sat share one login; the fleet record has it at 96% of the weekly limit on 10-17 20:33Z, reset 10-21 17Z, the owner tops up | **risk**: every claude lane is on sat while `<pc box>` is away. Not measured now |

## 3. The 10-minute handover runbook

Trigger: the owner posts the notice ("closing `<pc box>` in 10 min") in any
t1 topic. **T = the post's time.** Every step is a named action; its proof is
the command's output, posted by the step's owner on the notice's task.

| step | when | who | named action | proof |
|---|---|---|---|---|
| 3.1 | T+0..1 | dispatch holder (sat) | answer the owner "In progress: handing over"; send step 3.2 to the orch holder | the topic reply |
| 3.2 | T+1 | orch holder (sat) | `BOX=<pc box> CORDON_CMD=on CORDON_MIN=240 DRY_RUN=0 ./run -a do_spl_box_cordon` (**row 01, not built**) | `./run -a do_spl_box_pick` -> the `<pc box>` line says `CORDONED`, `pick=sat` |
| 3.3 | T+1 | orch holder | spool task to `c-001@<pc box>`: run `DRY_RUN=0 DRAIN_MIN=7 ./run -a do_spl_box_leave` there (built, spec 064 L9). Row 02 wraps 3.2-3.4 in one action | its table ends `SAFE TO SWITCH OFF` (exit 0) or `NOT SAFE: <n> agents still running` (exit 3) |
| 3.4 | T+8 | orch holder | every lane in the leave table that did not push: re-enqueue on sat from its hold note (`do_spl_spawn_enqueue`) | one queue row per lane; `lane-map.sh` shows the new `@sat` id |
| 3.5 | T+8 | orch holder | roles: `LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease` | `orch ...@sat`, `dispatch ...@sat` |
| 3.6 | T+9 | orch holder | prd and dev from sat: `ENV=prd ./run -a do_check_deploy_lag`, `ENV=dev ./run -a do_check_deploy_lag`, `ENV=dev ./run -a do_spl_api_smoke`, `ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_desk_probe` (red today, row 04) | `current` x4, "every check passed", the probe's PASS |
| 3.7 | T+10 | dispatch holder | one owner post: **Live** or what is not, naming the measured cases and the `cannot` rows (8, 26) | the topic post |

`do_spl_box_leave` hands any role lease held on `<pc box>` to the next box at
once (its step 3); today there is none (row 1). Finance rows HOLD by
themselves (row 7).

## 4. The way back

| step | who | named action | proof |
|---|---|---|---|
| 4.1 | `c-001@<pc box>`, after the owner says `<pc box>` is up | `DRY_RUN=0 ./run -a do_spl_box_join` on `<pc box>` (built) | its status line; `box.leave` gone |
| 4.2 | orch holder (sat) | `BOX=<pc box> CORDON_CMD=off DRY_RUN=0 ./run -a do_spl_box_cordon` (row 01) | `do_spl_box_pick` lists `<pc box>` without `CORDONED`; expect DEGRADED for up to `hold_min` (30 min) |
| 4.3 | orch holder | roles: `fleet-show` | no `FLEET` move (sat ranks first); any move is a finding |
| 4.4 | dispatch holder | the issue closer catches up on `<pc box>`'s next `*/5` tick (row 10) | the window's landed keys are `done` |
| 4.5 | dispatch holder | the held finance rows place again (row 7) | a `placed` line per held ask in the placer log |

## 5. The drill: sat alone, prd and dev, without the owner

Named action `do_spl_sat_alone_drill` (**row 05, not built**), read-only
except the probes it names. `DRILL_PHASE=pre|during|after`.

Two forms:

- **Soft cut (no owner)**: steps 3.2-3.4 run for real (cordon, then the leave
  on `<pc box>`), then `<pc box>`'s lease loop stops
  (`LEASE_CMD=stop ./run -a do_spl_dispatch_lease` there), for 30 min.
  `<pc box>` stays powered and keeps beating, so DEGRADED never fires: the
  cordon is what keeps lanes off it. Then section 4.
- **Hard cut**: the owner's real absence windows (today 04:00-07:00Z). The
  drill runs `during` from sat and records; nothing to switch.

Checks, each with its pass number:

| # | check | command | pass |
|---|---|---|---|
| D1 | roles on sat | `fleet-show`, every 60 s | 30 of 30 samples `@sat`; 0 `FLEET` lines in sat's `lease.log` |
| D2 | no placement on `<pc box>` | `do_spl_box_pick` every 3 min; the placer log | 10 of 10 picks not `<pc box>`; 0 spawn requests to `<pc box>` |
| D3 | prd answers | a labelled probe post (`ENV=prd do_spl_box_msg_probe`) | 3 of 3 answered by a `@sat` dispatcher within 180 s, 1 answer each |
| D4 | dev answers | `ENV=dev do_spl_desk_probe` | 3 of 3 PASS (today 0 of 3 expected: row 18) |
| D5 | a lane on sat lands | one small sat lane during the window | `git-fetch-fresh.sh --landed` exit 0; its wf 10 green |
| D6 | deploys | `do_check_deploy_lag` dev and prd on D5's sha | 2 of 2 `current` within 60 min |
| D7 | live hub reads | `ENV=dev do_spl_api_smoke`; prd with `API_SMOKE_PRD_GO=1` | every check PASS, both envs |
| D8 | no lost work | the leave table | 0 lanes with unpushed commits and no hold note |
| D9 | no duplicates | the unanswered sweep log; the probe topic | 0 escalations; 1 answer per post |

**Pass = D1..D9 all pass.** A run writes one TSV row per check under
`/var/csi/csi-spl/sat-alone-drill/` and one summary line; a red check names
its inventory row. Cadence: once after rows 01-05 land, then weekly with the
Friday security round, and `during` in every owner absence window.

## 6. Where the dev security drills fit

The owner's message names "other drills which are concerning the security on
the dev environment" without a list. In the repo:

| drill or check | defined | target | numbers | fit |
|---|---|---|---|---|
| dev DB restore drill `do_spl_db_restore_drill` | `csi-spl-orc/src/bash/run/spl-db-restore-drill.func.sh`; spec 029 section 6.9; wf 49 daily 05:47Z | dev only (prd refused in code) | exit codes, a timing line | runs on GitHub, no box: unaffected; its red note is sat's `restore-drill-red-note` cron |
| weekly security round `do_spl_security_round_queue` | `spl-security-round-queue.func.sh`; sat cron Fridays 05:30Z | lanes | per round | already on sat; the drill's weekly run rides on it |
| box hardening round 1 (`do_spl_sshd_harden`, `do_spl_box_ports_loopback`, ...) | `csi-spl-doc/doc/md/box-hardening-round-1.md:8-12` | box | dry run + check, one-off | a re-check on sat is a later round (a root write needs the owner's go per box) |
| local hub hardening `do_spl_local_hub_harden_check` | `spl-local-hub-harden-check.func.sh` | box | PASS/FAIL per check | read-only: a D10 candidate for row 05 |
| secrets round 1 (`do_spl_secret_age_report`, ...) | `csi-spl-doc/doc/md/secrets-round-1.md:8-12` | dev, then prd | results, one-off | `do_spl_secret_age_report` is read-only from sat |
| scanner baselines `do_check_baseline_growth` | `csi-spl-doc/doc/md/security-baselines.md:14-30` | CI | planted reds | CI, unaffected |
| spec 064 drill D1-D6 | `csi-spl-doc/specs/064-fleet-without-the-pc/spec.md:135-160` | fleet | designed, never run | **superseded by section 5** |
| spec 068 peer drill, 101 M3, 134 P5 | spec 068 `:215`, spec 101 `:318`, spec 134 `:331` | dev | n >= 5 | not about losing a box; unchanged |

No pen test, chaos or game-day drill is defined for dev:
`grep -rliE 'pen.?test|chaos|game.?day' csi-spl-doc/specs csi-spl-doc/doc/md`
-> 3 files, each only naming chaos testing as not done.

## 7. What cannot be done on sat alone

Plainly:

1. **Finance work** (NetVisor, bank): its keys stay on `<pc box>` by owner
   order. Those rows wait.
2. **The dedicated channel of `c-423`**: only `c-423@<pc box>` talks there, by owner order.
   It is silent while `<pc box>` is off unless the owner names a sat seat.
3. **Anything on the owner's own screen**: a visible browser, the owner's
   local logins, a signed directive typed at `<pc box>`.
4. **Work in flight on `<pc box>` that nobody drained**: without step 3.3 a
   lane freezes with its unpushed commits on `<pc box>`'s disk until it
   returns.
5. **dev desks and the dev responder from sat**: not today (rows 18, 19);
   row 04 fixes it.
6. **The issue closer and the fx rates**: they wait and catch up (rows 10,
   12); nothing is lost.

Everything else prd needs (roles, prd desks, responder, crons, CI, deploys,
the hub, the infra stack) runs on sat today.

### 7.1 Today's window (04:00-07:00Z), with no row built

Both leases are on sat already, so prd answers continue. Lanes on `<pc box>`
freeze unless step 3.3 runs (it is built). The placer may still send lanes
to `<pc box>` until ~2 min after the cut (row 5). dev desk answers from sat
do not happen (row 18).

## 8. Build rows

R1: disjoint files per batch. Every infra step is a named action plus a test
(repo CLAUDE.md "Nothing ad hoc"). Vendors: claude for code (owner 10-17: no
mistral coding or testing lanes); docs to mistral.

| # | action | sites (file:line) | test / red control | measure after | vendor, kind | batch |
|---|---|---|---|---|---|---|
| 01 | `feat(orc, SPL-2471)`: `do_spl_box_cordon` (on / off / show, `CORDON_MIN` expiry) writes `<spool root>/dispatch/cordon/<box>`; `do_spl_box_pick` and the pinned-row check treat a cordoned box as not pickable | new `csi-spl-orc/src/bash/run/spl-box-cordon.func.sh`; `spl-box-pick.func.sh:107,172,178`; `spl-spawn-place.func.sh:276` | new `spl-box-cordon.tst.sh`; red: a `spl-box-pick.tst.sh` case "cordoned box is picked" fails on master | `do_spl_box_pick` with a cordon -> `CORDONED`, never that box, n=10 | claude, complex_coding | 1 |
| 02 | `feat(orc, SPL-2471)`: `do_spl_box_offline_window BOX= MIN=10`: cordon, spool task to `c-001@<box>` to run `do_spl_box_leave`, wait for its table, print the re-enqueue list | new `csi-spl-orc/src/bash/run/spl-box-offline-window.func.sh` + its `.tst.sh` | fake sender; red = the action does not exist | soft-cut steps 3.2-3.4 done in under 10 min | claude, complex_coding | 2 (needs 01) |
| 03 | `fix(orc, SPL-2471)`: the issue-close cursor and ledger follow the dispatch holder (box state store, `do_spl_box_state_put` / `_get`), so the holder's box sweeps | `csi-spl-orc/src/bash/scripts/issue-close-landed-cron.sh:7-10,35-37`; `spl-issue-close-landed.func.sh` | `spl-issue-close-landed.tst.sh`: red = a holder box without the cursor closes nothing | a commit landed while `<pc box>` is off is `done` within 10 min | claude, complex_coding | 1 |
| 04 | `fix(orc, SPL-2471)`: dev desks seat on sat (`FAIL could not seat c-001`, 913 FATAL ticks) plus a dev `sat-rsp` responder; cause first | the `do_spl_desk_up_tenants` path (the lane names the line once the cause is read) | red = `ENV=dev do_spl_desk_probe` from sat FAILs today | D4 3 of 3 PASS; 0 FATAL lines per hour in `cron.out` | claude, complex_coding | 1 |
| 05 | `feat(orc, SPL-2471)`: `do_spl_sat_alone_drill` D1-D9 (section 5), TSV + summary | new `csi-spl-orc/src/bash/run/spl-sat-alone-drill.func.sh` + its `.tst.sh` | stub outputs: each D goes red on a planted bad sample | one soft-cut run: 9 of 9 PASS | claude, tests | 2 (needs 01, 04) |
| 06 | `feat(orc, SPL-2471)`: `fx-rates-fetch` and `issue-key-rate` run on the dispatch holder's box only (holder gate, like `owner-digest`), then installed on sat with `box-state-backup` | `fx-rates-fetch-cron.sh`, `issue-key-rate-cron.sh`, `box-crons.manifest:21,30,35` | `install-box-crons.tst.sh` + a holder-gate case: red = both boxes run it | sat crontab grep -> 3 new tags; 1 fx row per day, not 2 | claude, simple_coding | 1 |
| 07 | `feat(orc, SPL-2471)`: the lane map marks lanes of a cordoned or degraded box `away`, not `live` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh:10-26` | its test: red = a silent box's lanes read `live` | `lane-map.sh` during the drill: 0 `live` rows `@<pc box>` | claude, simple_coding | 2 (needs 01) |
| 08 | `docs(doc, SPL-2471)`: the runbook of sections 3-4 into `HOWTO-satellite-work.md`; spec 064 section 5 points here | `csi-spl-doc/doc/md/HOWTO-satellite-work.md`; `csi-spl-doc/specs/064-fleet-without-the-pc/spec.md:135` | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` | the runbook has one home | mistral, specs_and_docs | 3 |

Batches: 1 = rows 01, 03, 04, 06 (disjoint files); 2 = rows 02, 05, 07;
3 = row 08. Owner decisions this plan does NOT take: a sat seat for the dedicated channel
(inventory row 8), and any root write on a box.

## 9. Panel

| seat | vendor | id | file | v0.1 verdict | signed v1.0 |
|---|---|---|---|---|---|
| editor | claude | `c-399@sat` | this file | author | - |
| reviewer | grok | placed by the dispatcher | `sat-alone-panel/seat-grok.md` | pending | - |
| reviewer | mistral | placed by the dispatcher | `sat-alone-panel/seat-mistral.md` | pending | - |
