# 064: development keeps running while the PC is off

Status: **draft for the owner, Q1..Q10 open** (section 9). Spec only;
nothing is built, and no `lease.conf`, cron, sidecar or runner was touched.
Draft 2026-10-03, c-048.
Related: [057 the satellite](../057-satellite/spec.md), [058 the fleet on many
machines](../058-multi-machine-fleet/spec.md), [060 role
rotation](../060-role-rotation/spec.md),
[SPEC-spool-fleet-roles.md section 4.1](../../doc/md/SPEC-spool-fleet-roles.md)
(the fleet lease), [HOWTO-satellite-work.md](../../doc/md/HOWTO-satellite-work.md).

## 1. What the owner asked (t1 topic `1e48c889`, verbatim)

> "Ensuring uninteruptable and constand development even in the moment of
> shutting of the <pc box>"

> "The <pc box> box iz actually my laptot, albeit a good one, running in my
> Tesla. Aka I would like to be able to just shut it off, so that this would
> not stop the operation and the development of the spoolhub"

> "So specs needed first. How to enable that"

(`<pc box>` stands for the PC's box tag: box tags are banned literals in
this tree, see the distribution-hygiene sweep in `10_ci-quality.yml`.)

**Target.** The PC is OPTIONAL. The orchestrator, both dispatchers, every
cron, the CI runners and the lanes have their home on the satellite (`sat`);
the PC at most joins as an extra machine while it is on. This goes further
than t1 `aad0e6cf` (orch home = sat, dispatchers stay on the PC): that split
still loses the dispatchers, the runners and the PC-only crons when the PC
is off.

## 2. Words

| word | meaning |
|---|---|
| **the PC** | the owner's laptop, box tag `<pc box>`; today it leads the fleet (058's "home box") |
| **sat** | the GCP VM of spec 057, box tag `sat` |
| **role seat** | the orchestrator (`c-001`) and the two dispatchers (`c-002` master, `c-003` failover); ids 001..003 exist on every machine |
| **holder** | the machine whose seat holds a role in the hub's fleet lease (rdb 0094/0095), mirrored to `<spool root>/dispatch/lease` and `lease.orch` |
| **PC-only** | a function that stops when the PC is off, because nothing on sat does it today |
| **box user / agent user** | the OS user that owns the desks and crons / the one the agents run as (`box.env`: `OWNER_USER`, `AGENT_USER`) |

## 3. What was measured

sat side: measured on sat 2026-10-03 03:20..03:30Z as the box user, fleet
loop code at `f93b0382` (`<spool root>/dispatch/fleet.ver`). PC side: this
lane has no shell on the PC; c-001 ran the same read-only commands there at
03:25:42Z (task `1e48c889`, ask `376239b4`, msg `a02f63ab`) and the PC cells
below quote that output. n = one snapshot per machine; a cron or runner that
was added or removed after 03:26Z is not in it.

### 3.1 The fleet lease now

```bash
cat /var/spool-hub/dispatch/lease.conf /var/spool-hub/dispatch/lease /var/spool-hub/dispatch/lease.orch
```

- Both machines' `lease.conf` are identical: `LEASE_PRIORITY=<pc box>,box-desk,sat`,
  no `LEASE_PRIORITY_ORCH`, no `LEASE_PRIORITY_DISPATCH`. c-075's per-role
  ranking (`c3f23d36`) is on trunk, configured on neither machine.
- Holders: `c-002@<pc box>` (dispatch), `c-001@<pc box>` (orch).
- sat's own `c-001`, `c-002`, `c-003` stand by in tmux (22 agent windows on
  sat, 3 of them the role seats).

### 3.2 Take-overs: the failover works, the PC is still the home

```bash
grep -c 'takes over' /var/spool-hub/dispatch/lease.log
```

-> 21 take-overs by sat since the fleet lease went live (2026-10-01 23:24Z).
Tonight's three, each after the PC went silent for 188..219 s (the PC's
uplink / DNS failed: `HUB-UNREACHABLE lookup <hub host>: i/o timeout` in the
PC's lease log):

| UTC | role | PC silent | handed back to the PC after |
|---|---|---|---|
| 02:30:44 | orch | 204 s | 3 min 07 s |
| 02:40:57 | dispatch | 188 s | 3 min 09 s |
| 03:15:33 | dispatch | 219 s | 1 min 04 s |

The PC at 03:25Z: 16 cores / 62 GB, **load 111**, 43 sessions, 370 Chrome
processes. sat at 03:23Z: `e2-standard-16`, 16 vCPU / 62 GB, load 1.8.

So the three seats survive a PC that is OFF today: sat takes each role
within ~3.5 min and keeps it while the PC is gone. The cost is everything
else in section 3.3, and the flapping while the PC is on a weak uplink.

### 3.3 Inventory: what runs on the PC only

| # | function | proof (command -> result) | stops when the PC is off | sat has it | smallest change for sat to take it | risk |
|---|---|---|---|---|---|---|
| 1 | orchestrator seat `c-001` | `cat lease.orch` -> `c-001@<pc box>`; `LEASE_PRIORITY` ranks the PC first on both machines | ~3.5 min of no orchestrator, then sat holds it; each PC return hands it BACK (priority handback) | yes, seat standing by | `LEASE_PRIORITY_ORCH=sat,<pc box>` in BOTH `lease.conf` | the two `lease.conf` disagree for a moment = the lease ping-pongs until they match |
| 2 | dispatcher seats `c-002` / `c-003` | `cat lease` -> `c-002@<pc box>` | same as 1: ~3.5 min of no owner answers, then sat answers | yes, both standing by | `LEASE_PRIORITY_DISPATCH=sat,<pc box>` in both `lease.conf` | as 1 |
| 3 | prd desk reconcile, dispatch tick, unanswered sweep, orch / dispatch rotation, agent-identity reconcile | `crontab -l` (box user) on both: same lines on both machines (prd reconcile every 3 min on the PC, every 5 on sat) | nothing; sat's standby sweep starts sending once sat holds the lease (fleet-roles 4.1) | **yes** | none | none new |
| 4 | **dev** desk reconcile (`ENV=dev`, every 3 min) | PC `crontab -l`: `csi-spl:desk-reconcile` `ENV=dev`; sat `crontab -l`: absent | dev desks are not re-seated; a dev sidecar that dies stays dead | **no** | add the dev line to sat's box-user crontab via the satellite ansible role `10_rotation_cron` (or `11_boot_restore`'s sibling) | the PC sets `DESK_MUTE=CLE-00`, sat does not: decide the mute once for both |
| 5 | weekly full scan (`weekly-full-scan-cron.sh`, Fri 17:00, `DRY_RUN=0`) | PC `crontab -l`: `csi-spl:weekly-full-scan`; sat: absent | the weekly scanner run (pre-push-gate.md) | **no** | the same line on sat | runs twice if both machines carry it: holder-gate it, or keep it on one machine |
| 6 | `spawn-remote.sh --serve` (every minute, c-076) | PC `crontab -l`: `csi-spl:spawn-remote`; sat: absent | nothing new: it serves "sat asks the PC to start a lane" | no | none for the target; with the orch on sat it is the PC that would need sat to serve, which the target does not use (lanes start locally on sat) | none |
| 7 | tmp scratch sweep (agent user, :17 hourly) | PC agent-user `crontab -l`: `csi-spl:tmp-scratch-sweep`; sat: `no crontab for` the agent user | `/tmp` scratch grows on sat (it already does today) | **no** | the same line in sat's agent-user crontab | a full `/` on sat stops every lane (30 GB root, 23 GB free now) |
| 8 | the non-AI responder (`box-rsp` desks, SPL-1265 "Seen: routed to the team") | sat `cron-prd.out`: `no box-rsp desk seated on this box yet` in 300 of 300 ticks; PC: 16 `spool` processes vs sat's 6 `spool hub-run` sidecars | an owner post gets no instant "Seen" ack; only the dispatcher answers, once sat holds the lease | **no** | seat the `box-rsp` desks for sat on t1 prd (`do_spl_desk_up_boxes` already reconciles other desk boxes once seated) | two responders = two "Seen" replies per post: holder-gate it like the unanswered sweep |
| 9 | GitHub self-hosted runners | PC `systemctl list-units 'actions.runner*'` -> 4 active: `spool-ci-01`, `-02`, `-03`, `<pc box>-spl-04`; sat -> 0. `grep -c 'runs-on: \[self-hosted, spool-ci\]'` -> 10 jobs in `10_ci-quality.yml`, 1 in `99_runner-smoke.yml`; 20/30 deploys and 15/70/85 run on `ubuntu-latest` | **workflow 10 (the full quality gate) queues until the PC returns**; deploys still run | **no** | register runners on sat with label `spool-ci` through a named action (`do_oss_runners_move` moves runners between repos; a "register on this box" action is new) | runner labels per runner were not read (`gh api .../actions/runners` rate-limited 3x from sat); the persistent-HOME caches (`10_ci-quality.yml` lines 102, 546) start cold on sat; runners and prd keys on one cloud VM |
| 10 | lanes running on the PC | lane map 03:23Z: 25 live lanes `@<pc box>`, 27 `@sat` | each PC lane freezes mid-task; unpushed commits wait on a laptop disk | yes, sat runs lanes | the orch on sat spawns on sat by default | sat's 40-window ceiling; all lanes on one 16-vCPU VM may be too few for the owner's pace (Q5) |
| 11 | Chrome for WUI e2e and browser lanes | PC: 370 Chrome processes (lane browsers + CI e2e); sat: `command -v google-chrome` -> present, 0 running | browser lanes and the e2e shards that run on the PC's runners | binary yes; a green headless e2e on sat: **not measured** | one run: `BASE_URL=<bundle> pnpm run test:e2e` on sat, recorded | a lane that needs a VISIBLE browser on the owner's screen cannot move |
| 12 | infra stack (tf-runner, tpl-gen, conf-validator) and the local dev stack (`csi-spl-lde-main-*`, prd sql proxy) | PC `docker ps`: `con-csi-csi-spl-{tf-runner,conf-validator,tpl-gen}`, `csi-spl-lde-main-{hub,wui,pg,gcs}-1`, `csi-spl-prd-sql-proxy-*`; sat `docker ps -a` -> only `c041-pg` | terraform plan / apply (owner-gated anyway); lde-based checks | **no** | `make do-setup-app-inf` (and the lde) in sat's main checkout, plan-only first | one infra stack per box, main checkout only (CLAUDE.md) |
| 13 | git-rel relay keys and the other csi-spl keys | PC `ls ~/.gcp/.csi/` -> `key-csi-spl-{dev,prd,dev-rel,prd-rel,all,bkp}.json`; sat -> `key-csi-spl-{dev,prd}.json` only | git-rel relay use, anything run with the `all` or `bkp` SA (backups) | dev + prd yes; `-rel`, `all`, `bkp` **no** | copy the keys a sat function needs, out of band (doc section 6.3), never via git, a log or the spool | each copy is one more place to rotate; a cloud VM disk is a different exposure from a laptop's |
| 14 | spool root + `registry.tsv` | sat `/var/spool-hub`: 68 registry rows; each machine has its own root (fleet-roles 4.2) | the PC's inboxes; a message to a PC lane is queued at the hub until the PC returns | yes (own root) | none | a lane on a PC that is OFF still reads `live` on the lane map until it ages out |
| 15 | hub relay (desk sidecars) | sat `ps`: 6 `spool hub-run` | nothing for sat | yes | none | the hub (Cloud Run prd) is the one dependency both machines share; it is not on the PC |
| 16 | MCP servers | sat: the agent user's `~/.claude.json` `mcpServers` -> empty; the repo has no `.mcp.json` | **not measured on the PC** | n/a | none found that a csi-spl brief requires | none measured |
| 17 | Claude session save (every minute) + boot restore, graft index refresh | PC `crontab -l` (box user): `claude-save-sessions.sh`, `claude-sessions-boot.sh`, `graft-cron.sh` x2; sat: `agent-boot-restore` only | resuming PC sessions after a PC reboot; the graft code index on the PC | partly (sat has its own boot restore) | none for the target; graft on sat is the owner's call | out of csi-spl's tree (box tooling) |
| 18 | other projects' crons: creds backup (10:00, 19:00), bnc completion-cache warm, csi-rel price refresh, monitoring watchdog (5 min), uptime alert drill | PC `crontab -l` lines 1-7 | each of those stops | no | **out of scope, owner to decide** (Q10) | the csi-rel monitoring watchdog and creds backup stop silently with the PC |

**Rows that block the target** (the PC off for a working day): 8 (no "Seen"
ack), 9 (workflow 10 never runs), 4 (dev desks unreconciled), 5 (no weekly
scan), 11 (no proven browser lane on sat), 13 (no rel keys on sat). Rows 1-2
survive today but hand back and flap; row 10 freezes in-flight work.

## 4. The target design

1. **sat is rank 0 for every role**: both machines' `lease.conf` carry
   `LEASE_PRIORITY_ORCH=sat,<pc box>` and `LEASE_PRIORITY_DISPATCH=sat,<pc box>`
   (or `LEASE_PRIORITY=sat,<pc box>`). The PC is the failover. A PC that
   switches off then held no role, and nothing moves.
2. **Every csi-spl cron of section 3.3 runs on sat**; the ones that post or
   scan (responder, weekly scan) are holder-gated or live on sat only, so a PC
   that is on does not double them.
3. **CI runners on sat** carry `spool-ci`; the PC's four may stay as extra
   capacity while it is on (Q4).
4. **Lanes start on sat** by default; the PC takes lanes only when the
   owner says (Q9).
5. **Before the PC switches off**, nothing to do: no role is there, and
   every lane on it pushes every 20 min anyway (an optional drain action is
   lane L9).

## 5. The drill (designed, NOT run)

Owner window, 15 min. Run it twice: once BEFORE L1 (measures today's
failover) and once after L1..L6 (measures the target).

1. **Cut**: block the PC's egress for 15 min (an `nft` drop of everything
   but the owner's ssh), or suspend the laptop. Note the UTC start.
2. **Must still happen in the window**, each with its proof:

   | # | expectation | proof |
   |---|---|---|
   | D1 | orch and dispatch held by sat within 4 min of the cut (no move at all once sat is rank 0) | sat `lease.log`: `FLEET <role>: ... -> c-00N@sat`, or no `FLEET` line |
   | D2 | an owner post in a t1 topic is answered by sat's dispatcher, plus one "Seen" ack once row 8 is done | the topic: `from` `c-002@sat` |
   | D3 | a lane started on sat by sat's orch lands a commit on trunk | `git merge-base --is-ancestor <sha> origin/master` -> exit 0 |
   | D4 | workflow 10 on that sha goes green on a sat runner | `gh run view <id> --json jobs` -> every `runnerName` on sat |
   | D5 | deploys 20 and 30 on that sha reach dev and prd | `./run -a do_check_deploy_lag` with the sha -> current |
   | D6 | no duplicates | one "Seen" and one answer per post; one scan run |

3. **Restore**: unblock. Expect: the PC rejoins as STANDBY, no role moves
   back (target config), its frozen lanes resume and their queued messages
   land. Any `FLEET` line after the restore is a finding.
4. **Pass** = D1..D6 proven. Then the same with the PC off for a whole
   working day before the owner relies on it.

## 6. Lanes that close the gaps (ordered, one task each, disjoint files)

| # | lane | files (only these) | closes | needs |
|---|---|---|---|---|
| L1 | a named action that sets the per-role ranking in THIS machine's `lease.conf` (dry run default) + test; then run it on both machines | `csi-spl-orc/src/bash/run/spl-lease-rank.func.sh` (new) + `csi-spl-orc/src/bash/tests/spl-lease-rank.tst.sh` (new) | rows 1, 2 | Q1 |
| L2 | seat `box-rsp` for sat on t1 prd, and holder-gate `do_spl_responder_sweep` (standby sends nothing) | `csi-spl-orc/src/bash/run/spl-responder-sweep.func.sh` + `csi-spl-orc/src/bash/tests/responder-reboot-test.tst.sh` | row 8 | Q2 |
| L3 | a named action that registers self-hosted runners on THIS box with label `spool-ci` (idempotent, dry run default) + test; run on sat | `csi-spl-orc/src/bash/run/gh-runner-add.func.sh` (new) + its `.tst.sh` | row 9 | Q3, Q4 |
| L4 | the PC-only csi-spl crons on sat: dev desk reconcile, weekly full scan (holder-gated or sat-only), tmp scratch sweep | `csi-spl-iac/src/terraform/060-gcp-vm-satellite/roles/10_rotation_cron/**` + `csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh` | rows 4, 5, 7 | none |
| L5 | prove a headless browser e2e on sat; record the result (no code unless it fails) | `csi-spl-doc/doc/md/HOWTO-satellite-work.md` (one table row) | row 11 | none |
| L6 | the csi-spl keys sat needs (`-rel`, `bkp`), out of band, plus a check action that reports present / absent without printing a key | `csi-spl-iac/src/bash/run/check-spl-keys.func.sh` (new) + its test | row 13 | Q6 |
| L7 | infra stack + lde on sat's main checkout, then `make do-tf-plan` dev from sat (plan only) | none in git; a result row in `HOWTO-satellite-work.md` (after L5 lands, same file) | row 12 | owner go |
| L8 | the drill of section 5 in the owner's window; results appended here as section 10 | `csi-spl-doc/specs/064-fleet-without-the-pc/spec.md` | proves all | L1..L6, Q7 |
| L9 | (optional) `do_spl_box_leave`: before the PC switches off, every PC lane pushes or hands over, then the PC drops out of the lease | `csi-spl-orc/src/bash/run/spl-box-leave.func.sh` (new) + its test | row 10 | Q8 |

No lane touches `csi-spl-api/**`, `csi-spl-wui/**`, the hub, or the fleet
lease loop (c-075's knobs suffice).

## 7. Risks

- **One VM becomes the whole fleet.** sat down (GCP maintenance, a full
  disk, a bad upgrade) = the fleet down, the mirror of today. The PC as
  automatic failover covers it only while the PC is on.
- **Capacity.** The PC runs 25 lanes at load 111; sat runs 27 at load 1.8 on
  the same 16 cores (sat's lanes are lighter: no Chrome, no runners, no
  lde). Moving runners + Chrome lanes to sat is where its load will go.
- **Runner exposure.** Self-hosted runners next to the prd SA keys on a cloud
  VM; spec 044 FR-OS-005 keeps every public-repo PR job off self-hosted
  runners, and that rule holds unchanged on sat.

## 8. Out of scope

The hub itself (Cloud Run); token cost per lane (063, c-077); the lease
loop's timing (180 s); other projects' crons (row 18, Q10).

## 9. Owner questions

- **Q1.** Make sat rank 0 for ALL three roles (orchestrator AND both
  dispatchers), the PC the failover? (yes / no)
- **Q2.** Seat the non-AI responder (`box-rsp`) on sat, holder-gated so only
  one machine answers? (yes / no)
- **Q3.** Register self-hosted runners on sat: how many? (a number; the PC
  has 4)
- **Q4.** Keep the PC's 4 runners registered as extra capacity while it is
  on? (yes / no)
- **Q5.** sat VM: stay `e2-standard-16`, or grow to how many vCPUs? (a number)
- **Q6.** Copy the git-rel relay keys and the `bkp` key to sat? (yes / no)
- **Q7.** Run the 15-minute drill of section 5 (PC egress blocked) in a
  window you pick? (yes / no, and a UTC time)
- **Q8.** Build the drain action `do_spl_box_leave` (L9), or is "every lane
  pushes every 20 min" enough before you switch the PC off? (yes / no)
- **Q9.** While the PC is on, should it still take lanes? (yes / no)
- **Q10.** The other projects' crons on the PC (creds backup, csi-rel
  watchdog / price refresh / uptime drill, bnc cache warm): move them to sat
  too? (yes / no)

<!-- last-edit: 2026-10-03T03:35:00Z — c-048 -->
