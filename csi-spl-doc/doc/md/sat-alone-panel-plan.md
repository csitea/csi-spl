# sat alone: readiness panel plan (v1.0)

Epic: SPL-2364
Spec: [146 reliability round](../../specs/146-reliability-round/spec.md)
Issue: SPL-2471
Owner topic: t1 `721ad6e4` (msgs `ceca67c2`, `97b1b11d`); task `dispatch-721ad6e4`
Rules: [rounds rulebook](rounds-rulebook.md) (R1-R16), [repo CLAUDE.md](../../../CLAUDE.md)
Prior design: [spec 064, the fleet without the PC](../../specs/064-fleet-without-the-pc/spec.md)

**Status: v1.0, both reviews folded (section 9); signatures in each seat's
own file.** v0.1 was `327fd8559`.
Editor: `c-399@sat` (claude). Reviewer seats: grok `g-400@sat`
(`sat-alone-panel/seat-grok.md`, verdict change, 28 agree / 20 change / 0
reject), mistral `m-404@sat` (`sat-alone-panel/seat-mistral.md`, verdict
GOOD after two evidence send-backs).

`<pc box>` stands for the owner's PC box tag, as in specs 064 and 068: box
tags other than `sat` are banned literals in this tree (the hygiene sweep in
`10_ci-quality.yml`). `sat` is the GCP satellite of spec 057.

## 0. One sha, and how this was measured

- Code and cnf lines are read on `origin/master` **`7b5ce46a4`**
  (2026-10-18, the lane's start; the code is unchanged at `327fd855`).
  Later commits (`e3655cac9`) move some cites a few lines down; where a
  reviewer measured on a newer tree the row says so.
- **Every live number below is a snapshot** with its UTC time. The holder
  ids, lane counts and the pick move by the minute (the grok seat re-read
  them 40 min later and several differed). The runbook re-reads each one at
  T+0; never act on the frozen value.
- Live state was read on sat between 01:15Z and 01:45Z on 2026-10-18 (v0.1) and 02:15Z-02:20Z (v1.0 additions), as the
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
| 1 | orchestrator and dispatch leases | `LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease` at 01:2xZ -> `orch c-001@sat`, `dispatch c-003@sat`; at 02:03Z (grok seat) `dispatch g-002@sat`; between them both roles sat on `<pc box>` (row 29); sat `lease.conf`: `LEASE_PRIORITY_ORCH=sat,<pc box>,box-desk`, `LEASE_PRIORITY_DISPATCH=sat,<pc box>,box-desk` | **covered while sat's role seats are alive**: sat ranks first and held both at both reads; row 29 is the exception |
| 2 | legacy line `LEASE_PRIORITY=<pc box>,box-desk,sat` in sat's `lease.conf` | `grep -i priority /var/spool-hub/dispatch/lease.conf` -> 3 lines; the bare one ranks `<pc box>` first | covered (the per-role lines win); it misleads a reader. Noted, no row |
| 3 | role seats on `<pc box>` standing by (`c-001`..`c-003`, `g-001`..`g-003`) | `lane-map.sh \| grep '@<pc box>'` -> 6 role rows | covered: sat has its own `c-001`..`c-003`, `g-001` (`lane-map.sh \| grep '@sat'`) |
| 4 | lanes running on `<pc box>` | lane map 01:20Z: 16 rows `@<pc box>` (02:07Z, grok seat: 13 `@<pc box>`, 21 `@sat`) (6 role seats, 4 restarted peer seats, 6 task lanes incl. the dedicated channel seat, a test-round row and a costs-tab lane) vs 18 `@sat` | **can**: `do_spl_box_leave` on `<pc box>` drains them (section 3); without it they freeze mid-task |
| 5 | placement keeps choosing `<pc box>` until it is silent 120 s | `./run -a do_spl_box_pick` on sat, 01:2xZ -> `pick=<pc box> reason=every box is at or above its high mark; <pc box> is the least past its band`; at 01:58Z, 02:08Z and 02:19Z -> `pick=sat`, `<pc box>` DEGRADED (02:19Z: "last beat 151s ago (max 120s)"). So the pick follows the beats, either way, minute by minute; the drain marker `box.leave` is read only on the leaving box (`grep -rln box.leave csi-spl-orc/src` -> box-leave, box-join, `spawn-window.sh:151`, the leave test) | **can**, row 01: no cordon action exists (`grep -rniE 'cordon\|offline.window' csi-spl-orc/src` -> 1 line, a comment in `spl-box-presence-watch.func.sh:8`; no `do_spl_box_cordon`) |
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
| 11 | `reverse-tunnel` `* * * * *` (`:32`) | the `<pc box>` -> sat tunnel (sat's `127.0.0.1:2222` listener) | `setup-reverse-tunnel.func.sh` header; `ss -ltn` on sat -> `127.0.0.1:2222` | covered: it only exists to reach `<pc box>`; nothing on sat needs it while `<pc box>` is off. The listener was up at 01:2xZ and absent at 01:55Z-02:06Z (grok seat): one `ss` line is not proof it is up |
| 12 | `fx-rates-fetch` daily 16:37 (`:35`) | the costs' second-currency rates, dev and prd | not in sat's crontab | **waits** (UPSERT on the next run, `fx-rates-fetch-cron.sh:3-6`); **can** with row 06. Which box runs it today: unverified |
| 13 | `issue-key-rate` Mon 06:53 (`:30`) | the weekly issue key rate row | not in sat's crontab | waits (not due on a Sunday); can with row 06 |
| 14 | `box-state-backup` 02:41 (`:21`) | the nightly copy of a box's box-only state | not in sat's crontab | not a `<pc box>` dependency, but **sat's own state gets no nightly copy today**; row 06 |
| 15 | `graft-index-refresh`, `graft-index-final` (`:18-19`) | the graft code index | not in sat's crontab; `command -v graft` on sat -> none | box tooling, not prd/dev; no row |
| 16 | already on sat (spec 064 rows 3-7, closed since) | dev desk reconcile (`*/3`, `ENV=dev`), prd reconcile, weekly full scan, spawn-remote serve, tmp scratch sweep (agent user), unanswered sweep, lane rotate, watchdog start, login check, owner digest, security round queue, cost rollup | the crontab grep above | covered |

### 2.3 Desks, responders, live services

| # | item | proof | verdict |
|---|---|---|---|
| 17 | prd desks and the prd responder on sat | `desk-reconcile/cron-prd.out`: `OK responder sweep (prd, holder): 1/1 tenant(s) handled, 0 failed`; 9 `spool hub-run` sidecars (`ps -eo args= \| grep -c 'spool hub-run'`). The responder is holder-gated (`spl-responder-sweep.func.sh:104-109`): at 01:47:44Z, with the lease on `c-002@<pc box>`, sat logged "this machine's responder sends nothing" (grok seat, 8 standby lines) | **covered only while sat holds the dispatch lease**; a fresh lease on `<pc box>` silences sat's responder until it moves or goes stale (`LEASE_STALE` 180 s) |
| 18 | **dev desks on sat** | `desk-reconcile/cron.out`: `FAIL could not seat c-001 on sat` (and c-002, c-003) every tick; `grep -c "FATAL Command 'do_spl_desk_up_tenants'" /var/csi/csi-spl/desk-reconcile/cron.out` -> 913 at 01:3xZ, 925 at 01:57Z (mistral seat), 928 at 02:06Z (grok seat); the log line is `spl-desk-up-all.func.sh:133`, after `do_spl_desk_up` returns non-zero | **can**, row 04. Cause not read by any seat. Today a dev topic gets no desk answer from sat |
| 19 | **dev responder on sat** | `grep -c 'responder sweep (dev): no sat-rsp desk seated' cron.out` -> 7152, of 7152 dev sweep lines | can, row 04. Whether `<pc box>` seats the dev desks today: not measured |
| 20 | live hub and WUI, dev and prd | `ENV=dev\|prd ./run -a do_check_deploy_lag` -> hub served `9c4397b6`, wui served `7b5ce46a` (02:08Z: `e3655cac`), `current` in both envs; `ENV=dev ./run -a do_spl_api_smoke` -> "every check passed" (run from the desk-cron tree at `a629ad83`) | covered: Cloud Run, no box |

### 2.4 CI, infra, browsers

| # | item | proof | verdict |
|---|---|---|---|
| 21 | CI runners | repo variable `SPOOL_CI_RUNNER` = `"ubuntu-latest"` (`gh variable list`); `gh api repos/csitea/csi-spl/actions/runners --jq .total_count` -> 0 (org: 0); last green wf 10 run `39085580284`: every job on a `GitHub Actions <n>` runner, label `ubuntu-latest` | **covered while the variable holds**: no box runs CI. If `SPOOL_CI_RUNNER` is cleared, the gate falls back to `[self-hosted, spool-ci]` (`10_ci-quality.yml` runs-on expression) and sat has no runner; cnf `ci_overflow.enabled` true can point the variable at local runners on a long hosted queue |
| 22 | infra stack (tf-runner, tpl-gen, conf-validator) | `docker ps` on sat -> `con-csi-csi-spl-{tf-runner,conf-validator,tpl-gen}` | covered (applies stay owner-gated) |
| 23 | headless Chrome for e2e and browser lanes | `command -v google-chrome` on sat -> present | covered for headless; a lane that needs a browser on the owner's screen cannot move |

### 2.5 Keys and logins (names and boxes only)

| # | item | proof | verdict |
|---|---|---|---|
| 24 | per-env project SA keys (dev, prd) | key name list on sat: `key-csi-spl-dev`, `key-csi-spl-prd` | covered |
| 25 | the relay and backup SA keys (`-rel`, `all`, `bkp`) | spec 064 row 13 lists them on the PC; sat's name list has none of them | waits; the panel found nothing in the prd/dev path above that needs one. Reviewers: look for one |
| 26 | finance integration keys (NetVisor, bank) | owner order: on `<pc box>` only, not in Secret Manager (fleet record of owner msgs `072a9990`, `c0bcb7b1`) | **cannot**, by owner order |
| 27 | the owner's directive signing key | `csi-spl-orc/src/bash/features/directive/README.md:48-54`: each box the owner types at has its own key; a box without one verifies and cannot issue | waits for a directive typed at `<pc box>`. Whether sat holds a signer is **unverified** (the key check stops the agent holding the keyring, so no seat ran it) |
| 28 | the agent login on sat | all claude seats on sat share one login. `BOX_PICK_KIND=claude ./run -a do_spl_box_pick` at 02:19Z -> `claude weekly unknown` ("no banner read, or its BOX-0 row is an hour old: placed anyway"); cnf `env.box.quota.weekly_max_pct` 90: at or over it the pick does not place that vendor (`spl-box-quota.func.sh:18`). The fleet record says 96% on 10-17 20:33Z, not shown in any log here | **risk, number unknown**: every claude lane is on sat while `<pc box>` is away. Step 3.0 reads it before the window |
| 29 | **sat's own weekly reboot** | `box-restart-cron.sh --at '0 04:30 Europe/Helsinki'` in sat's crontab; sat rebooted 01:35:41Z. Boot restore (`agent-boot-restore/cron.out`): `REFUSE g-002: its session is unknown; not guessing one` (and g-003), rule at `agent-identity.py:925`. `lease.log`: 01:35:46Z `NO-LOCAL-AGENT dispatch` (`spl-dispatch-lease.func.sh:1572`), 01:38:14Z orch `c-001@sat -> c-001@<pc box>`, 01:39:18Z dispatch `g-002@sat -> c-002@<pc box>`, back at 01:44:37Z and 01:48:03Z | **can**, build rows 09 and 10. With `<pc box>` off the roles have nowhere to fall: no orch for ~3 min and no dispatch until a grok seat is restarted by hand |

## 3. The 10-minute handover runbook

Trigger: the owner posts the notice ("closing `<pc box>` in 10 min") in any
t1 topic. **T = the post's time.** Every step is a named action; its proof is
the command's output, posted by the step's owner on the notice's task.

Steps 3.1 and 3.7 are topic posts, not `./run` actions: their proof is the
post itself.

| step | when | who | named action | proof |
|---|---|---|---|---|
| 3.0 | T+0 | dispatch holder | re-read every live value of section 2 that the steps use: `fleet-show`, `do_spl_box_pick`, `BOX_PICK_KIND=claude ./run -a do_spl_box_pick` (the claude weekly %; at 90% or more, or unknown, say so in 3.7) | the three outputs on the task |
| 3.1 | T+0..1 | dispatch holder (sat) | answer the owner "In progress: handing over"; send step 3.2 to the orch holder | the topic reply |
| 3.2 | T+1 | orch holder (sat) | `BOX=<pc box> CORDON_CMD=on CORDON_MIN=240 DRY_RUN=0 ./run -a do_spl_box_cordon` (**row 01, not built: this step cannot run today**) | `./run -a do_spl_box_pick` -> the `<pc box>` line says `CORDONED`, `pick=sat` |
| 3.3 | T+1 | orch holder | spool task to `c-001@<pc box>`: run `DRY_RUN=0 DRAIN_MIN=7 ./run -a do_spl_box_leave` there (built, spec 064 L9). Row 02 wraps 3.2-3.4 in one action | its table ends `SAFE TO SWITCH OFF` (exit 0) or `NOT SAFE: <n> agents still running` (exit 3) |
| 3.4 | T+8 | orch holder | every lane in the leave table that did not push: re-enqueue on sat from its hold note (`do_spl_spawn_enqueue`) | one queue row per lane; `lane-map.sh` shows the new `@sat` id |
| 3.5 | T+8 | orch holder | roles: `LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease` | `orch ...@sat`, `dispatch ...@sat` |
| 3.6 | T+9 | orch holder | prd and dev from sat: `ENV=prd ./run -a do_check_deploy_lag`, `ENV=dev ./run -a do_check_deploy_lag`, `ENV=dev ./run -a do_spl_api_smoke`, `ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_desk_probe` (red today, row 04) | deploy lag `current` x4 and the api smoke "every check passed" are green today (02:08Z); the dev desk probe is the expected red until row 04 |
| 3.7 | T+10 | dispatch holder | one owner post: **Live** or what is not, naming the measured cases and the `cannot` rows (8, 26) | the topic post |

`do_spl_box_leave` hands any role lease held on `<pc box>` to the next box at
once (its step 3); today there is none (row 1). Finance rows HOLD by
themselves (row 7).

## 4. The way back

| step | who | named action | proof |
|---|---|---|---|
| 4.1 | `c-001@<pc box>`, after the owner says `<pc box>` is up | `DRY_RUN=0 ./run -a do_spl_box_join` on `<pc box>` (built) | its status line; `box.leave` gone |
| 4.2 | orch holder (sat) | `BOX=<pc box> CORDON_CMD=off DRY_RUN=0 ./run -a do_spl_box_cordon` (row 01, not built) | `do_spl_box_pick` lists `<pc box>` without `CORDONED`; expect DEGRADED for up to `hold_min` (30 min) |
| 4.3 | orch holder | roles: `fleet-show` | no `FLEET` move (sat ranks first); any move is a finding |
| 4.4 | dispatch holder | today: the issue closer catches up on `<pc box>`'s next `*/5` tick (row 10). After row 03 the holder's box sweeps, so there is nothing to catch up | the window's landed keys are `done` |
| 4.5 | dispatch holder | the held finance rows place again (row 7) | a `placed` line per held ask in the placer log |

## 5. The drill: sat alone, prd and dev, without the owner

Named action `do_spl_sat_alone_drill` (**row 05, not built**).
`DRILL_PHASE=pre|during|after`. Its checks read; the soft cut it drives is
not read-only (the cordon, the leave and the lease stop are real).

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

D1 (30 samples at 60 s) and D2 (10 at 3 min) cover one 30-min run, not a
whole absence window.

**Pass, by form:**
- **Hard cut before rows 01 and 04**: D1, D3, D5, D6, D7, D9 pass. D4 is
  expected 0 of 3 (row 18). D8 does not apply (no leave table). D2 passes
  only while `<pc box>` stays silent past `max_gap_s`; if its beats resume
  the pick can move back to it (row 5).
- **Soft cut after rows 01, 04, 09**: D1..D9 all pass; D2's 10 of 10 needs
  the cordon, since `<pc box>` stays up and beating.
 A run writes one TSV row per check under
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
-> 4 files with this plan (3 before it); `reliability-round-plan.md:79` and
`perf-round-5/m1.md:201` name chaos testing as not done; the other two were
not line-checked by the grok seat.

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
7. **Riding out sat's own weekly reboot** (row 29): with `<pc box>` off,
   orch and dispatch have no seat for minutes and dispatch stays down until
   build rows 09-10 land. The reboot is `0 04:30 Europe/Helsinki` (weekly);
   today's (01:35Z) was before the owner's window.

Everything else prd needs (roles, prd desks, responder, crons, CI, deploys,
the hub, the infra stack) runs on sat today, with the limits rows 17, 21
and 29 state.

### 7.1 Today's window (04:00-07:00Z), with no row built

prd answers continue **while the dispatch lease is on sat** (it was,
`g-002@sat`, at 02:03Z); while a fresh lease sits on `<pc box>`, sat's
responder sends nothing (row 17) until the lease moves or goes stale. Step
3.2 cannot run (row 01 not built). Lanes on `<pc box>` freeze unless step
3.3 runs (it is built). The placer skipped a silent `<pc box>` at 01:58Z and
picked sat at 02:08Z and 02:19Z, but can pick `<pc box>` again if its beats
resume before the lid closes. dev desk answers from sat do not happen
(row 18).

## 8. Build rows

R1: disjoint files per batch. Every infra step is a named action plus a test
(repo CLAUDE.md "Nothing ad hoc"). Vendors: claude for code (owner 10-17: no
mistral coding or testing lanes); docs to mistral.

| # | action | sites (file:line) | test / red control | measure after | vendor, kind | batch |
|---|---|---|---|---|---|---|
| 01 | `feat(orc, SPL-2471)`: `do_spl_box_cordon` (on / off / show, `CORDON_MIN` expiry) writes `<spool root>/dispatch/cordon/<box>`; `do_spl_box_pick` and the pinned-row check treat a cordoned box as not pickable | new `csi-spl-orc/src/bash/run/spl-box-cordon.func.sh`; `spl-box-pick.func.sh:107,172,178`; `spl-spawn-place.func.sh:276` | new `spl-box-cordon.tst.sh`; red: a `spl-box-pick.tst.sh` case "cordoned box is picked" fails on master | `do_spl_box_pick` with a cordon -> `CORDONED`, never that box, n=10 | claude, complex_coding | 1 |
| 02 | `feat(orc, SPL-2471)`: `do_spl_box_offline_window BOX= MIN=10`: cordon, spool task to `c-001@<box>` to run `do_spl_box_leave`, wait for its table, print the re-enqueue list | new `csi-spl-orc/src/bash/run/spl-box-offline-window.func.sh` + its `.tst.sh` | fake sender; red = the action does not exist | soft-cut steps 3.2-3.4 done in under 10 min | claude, complex_coding | 2 (needs 01) |
| 03 | `fix(orc, SPL-2471)`: the issue-close cursor and ledger follow the dispatch holder (box state store, `do_spl_box_state_put` / `_get`), so the holder's box sweeps; installs the `issue-close-landed` row on sat (this row owns every `box-crons.manifest` edit of batch 1) | `csi-spl-orc/src/bash/scripts/issue-close-landed-cron.sh:7-10,35-37`; `spl-issue-close-landed.func.sh`; `box-crons.manifest:28` | `spl-issue-close-landed.tst.sh`: red = a holder box without the cursor closes nothing | a commit landed while `<pc box>` is off is `done` within 10 min | claude, complex_coding | 1 |
| 04 | `fix(orc, SPL-2471)`: dev desks seat on sat (`FAIL could not seat c-001`, 928 FATAL ticks at 02:06Z) plus a dev `sat-rsp` responder; cause first | `csi-spl-orc/src/bash/run/spl-desk-up-all.func.sh:133` (the fail line), `spl-desk-up.func.sh` (its return); the lane runs `lane-map.sh --check` on both before its first edit, since other desk work touches `do_spl_desk_up` | red = `ENV=dev do_spl_desk_probe` from sat FAILs today | D4 3 of 3 PASS; 0 FATAL lines per hour in `cron.out` | claude, complex_coding | 1 |
| 05 | `feat(orc, SPL-2471)`: `do_spl_sat_alone_drill` D1-D9 (section 5), TSV + summary | new `csi-spl-orc/src/bash/run/spl-sat-alone-drill.func.sh` + its `.tst.sh` | stub outputs: each D goes red on a planted bad sample | one soft-cut run: 9 of 9 PASS; one hard-cut run: the six checks of section 5's first form | claude, tests | 2 (needs 01, 04) |
| 06 | `feat(orc, SPL-2471)`: `fx-rates-fetch` and `issue-key-rate` run on the dispatch holder's box only (holder gate, like `owner-digest`), then installed on sat with `box-state-backup` | `fx-rates-fetch-cron.sh`, `issue-key-rate-cron.sh`, `box-crons.manifest:21,30,35` | `install-box-crons.tst.sh` + a holder-gate case: red = both boxes run it | sat crontab grep -> 3 new tags; 1 fx row per day, not 2 | claude, simple_coding | 2 (manifest after row 03) |
| 07 | `feat(orc, SPL-2471)`: the lane map marks lanes of a cordoned or degraded box `away`, not `live` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh:10-26` | its test: red = a silent box's lanes read `live` | `lane-map.sh` during the drill: 0 `live` rows `@<pc box>` | claude, simple_coding | 2 (needs 01) |
| 09 | `fix(orc, SPL-2471)`: a grok (or any vendor) role seat with no recorded session restarts FRESH from its role handoff after a reboot, as the mistral exception does, instead of `REFUSE ... session is unknown` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-identity.py:915-925` | `test-agent-identity-restore.sh` new case: red = a sessionless `g-` role seat is REFUSEd on master | next sat reboot: `pgrep -u <agent user> -af grok` shows the lease's master and failover within 5 min of boot | claude, complex_coding | 1 |
| 10 | `feat(orc, SPL-2471)`: `NO-LOCAL-AGENT` with no other fresh box in rank raises an alert to the orch holder (and the owner digest), not only a lease log line | `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh:1572` | `fleet-lease.tst.sh` case: red = no alert line when the only other box is DEGRADED | a planted dead seat on dev -> one alert within 2 min | claude, simple_coding | 1 |
| 08 | `docs(doc, SPL-2471)`: the runbook of sections 3-4 into `HOWTO-satellite-work.md`; spec 064 section 5 points here | `csi-spl-doc/doc/md/HOWTO-satellite-work.md`; `csi-spl-doc/specs/064-fleet-without-the-pc/spec.md:135` | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` | the runbook has one home | mistral, specs_and_docs | 3 |

Batches: 1 = rows 01, 03, 04, 09, 10 (disjoint files; row 04's file list
is confirmed by its `--check` before its first edit); 2 = rows 02, 05, 06,
07; 3 = row 08. Rows 05 and 06 wait for the batch-1 rows they name. Owner decisions this plan does NOT take: a sat seat for the dedicated channel
(inventory row 8), and any root write on a box.

## 9. Panel

| seat | vendor | id | file | v0.1 verdict | signed v1.0 |
|---|---|---|---|---|---|
| editor | claude | `c-399@sat` | this file | author | this commit |
| reviewer | grok | `g-400@sat` | `sat-alone-panel/seat-grok.md` (`46a91dd08`) | change, 28 / 20 / 0; every change folded above | its own signing commit |
| reviewer | mistral | `m-404@sat` | `sat-alone-panel/seat-mistral.md` (`b42383587`) | GOOD; its one risk note (a quota check before the window) is step 3.0 | its own signing commit |

A seat counts as signed only by its own commit to its own file on this
plan's v1.0 sha; this table does not sign for anyone.

### 9.1 What changed from v0.1

- Live values are snapshots with times; step 3.0 re-reads them (grok rows
  1, 4, 5, 20).
- Rows 11, 17, 21, 27, 28 narrowed to what was measured (grok).
- New row 29 and build rows 09, 10: sat's own reboot left dispatch with no
  seat (editor, lease and boot-restore logs).
- Steps 3.1 and 3.7 are posts; 3.2 and 4.2 cannot run today; 3.6's proofs
  split (grok). Step 3.0 adds the quota read (mistral).
- The drill's pass line is split by form; "read-only" corrected (grok).
- The chaos count is 4 with this plan (grok).
- Section 7.1 says when prd answers continue and when not (grok).
- Batch 1 no longer has two rows on `box-crons.manifest`; row 06 moved to
  batch 2; row 04 names its file (grok).
- The mistral seat's first two verdict commits pasted evidence that had not
  been run (a missing file, a stale holder id); its third, `b42383587`,
  matches re-runs.
