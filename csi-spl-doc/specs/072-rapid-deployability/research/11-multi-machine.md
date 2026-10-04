# 072 research 11: more than one machine (the fleet on many boxes)

Section of [072](../spec.md), research lane c-163, 2026-10-04. Tree:
`origin/master` @ `e3b1627e`; every command below ran on it, n = 1 each.
Sources: [057 satellite](../../057-satellite/spec.md),
[058 multi-machine fleet](../../058-multi-machine-fleet/spec.md),
[064 fleet without the PC](../../064-fleet-without-the-pc/spec.md),
[071 box runtime](../../071-box-runtime/spec.md),
[HOWTO-satellite-work.md](../../../doc/md/HOWTO-satellite-work.md).
Placeholders: `<cloud box>`, `<pc box>`, `<new box>` (box tags),
`<box user>` / `<agent user>` (OS users), `<hub url>`, `<tenant>`.

**Question.** A third party already runs a hub (072 P1 compose or P2 GCP)
and one box of agents (P3). What does it take to add a SECOND machine of
agents that works "exactly the same way" (058 section 1), and what in the
tree is bound to our boxes, tmux, users or GCP project?

## 1. Today

### 1.1 What already works for anyone (the hub side is machine-neutral)

| what | state | check |
|---|---|---|
| routing one-to-many | each machine its own box id; one delivery per box, takeover loses nothing | 058 2.1 H1-H11; `internal/hub/multimachine_test.go` (058 T1) |
| agent ids | every machine numbers `004-999` on its own; unique as `<ID>@<box>` | `grep -n SPOOL_AGENT_ID_RANGE csi-spl-orc/src/bash/features/spawn-agents/scripts/next-agent-id.sh` -> lines 11, 102-103 ("ignored") |
| cross-machine sends, `--to orchestrator` | relayed through the desk + hub | 058 N1; `spool-fleet-relay.sh:64` accepts `dev\|prd\|self` |
| fleet lease (orch / dispatch roles) | on the hub, CAS on `gen`; accepts a self-hosted hub | `spl-dispatch-lease.func.sh:625` `^(dev\|prd\|self)$` |
| fleet-wide lane map | on the hub (058 N2) | `do_spl_lane_map`, `do_spl_lane_put` |
| drain / rejoin a machine | one line each | `do_spl_box_leave`, `do_spl_box_join` (064 L9) headers |
| per-role ranking | one action per machine | `do_spl_lease_rank` header: "run this on each of them, or the role ping-pongs" |
| spawn on another machine | through the spool, no ssh | `spawn-remote.sh` header lines 1-20 |
| tmux socket | derived from the box user's uid, overridable | `spool-env.inc.sh:271-272` `/tmp/tmux-$(id -u "$SPOOL_BOX_USER")/default` |
| spool root | `/var/spool-hub` is a default, `SPOOL_ROOT` overrides it | `git grep -l /var/spool-hub -- csi-spl-orc csi-spl-iac csi-spl-api \| wc -l` -> 77 files, all defaults |
| per-machine settings | one file, 12 keys, the env wins | `spool-env.inc.sh:209` `SPOOL_BOX_ENV_KEYS=` (12 names); `box-config.sh` |

So the **concurrency model is done** (058). What an outsider lacks is the
**provisioning and the wiring**: the steps below are all ours-only or by hand.

### 1.2 The walk: add `<new box>` to a running fleet, every step in order

Counted from the tree, for one new Linux machine and one env.

| # | step | kind | check |
|---|---|---|---|
| 1 | get a machine. The only coded path is terraform 059 + 060 in OUR GCP project (`tf_key_project: csi-spl-all`), cnf in `prd.env.yaml`, rendered from prd only | ours-only | `grep -n tf_key_project csi-spl-cnf/csi-spl/prd.env.yaml` -> lines 270, 285 |
| 2 | set up the OS: the 10-role playbook runs only from the tf-runner, on the inventory 060's `07-ansible.tf` writes, over the IAP tunnel | ours-only | `satellite-playbook.func.sh` header: "No script yet = no 060 apply" |
| 3 | the playbook's facts are literals of our box: `box_tag`, `agent_id_range`, `fleet_env`, `fleet_tenant`, `box_timezone`, `owner_uid`/`agent_uid` 2000/2001, `repo_url`, `agent_clis` | code edit | `box-playbook.yaml` lines 27, 29, 32-34, 39-40, 43, 45 |
| 4 | the two OS user names are cnf literals of our estate | cnf edit | `prd.env.yaml` lines 323-324 (`box_owner_user`, `box_agent_user`) |
| 5 | without GCP: clone, `install.sh --box <new box> --tenant <tenant> --env self`, by hand | command | `install.sh` lines 92-101 (flags) |
| 6 | write box.env: `SPOOL_DESK_BOX`, `SPOOL_FLEET_ENV`, `SPOOL_FLEET_TENANT`, `SPOOL_DIR_LAYOUT=qualified`, `SPOOL_BOX_TAG` | 5 keys by hand | `box-config.sh KEY=VALUE`; nothing writes them for a non-GCP box (`grep -c satellite install.sh` -> 0) |
| 7 | first pin of the desk key: the tenant root key on the new box, OR `do_spl_desk_pin` admin mode (`BOX_PUBKEY`) run on the machine that holds it | 2 machines | `spl-desk-pin.func.sh` `@param` lines 26-28; 072 F8 |
| 8 | `lease.conf` with the SAME ranking on every machine | per machine, or ssh | `do_spl_lease_rank` header; `do_spl_fleet_config` reaches a box only by a local dir or ssh (its header) |
| 9 | the server side (desks, lease loop, crons) | command | `ENV=<env> BOX_DEPLOY_CMD=install DRY_RUN=0 ./run -a do_spl_box_deploy` |
| 10 | CI runners on the new box (optional) | command | `do_gh_runner_add`: needs `gh` with `admin:org` and an org runner group (header) |
| 11 | the GCP / GitHub credentials the lanes need | out of band | 057 `do_satellite_creds_push`, playbook role `06_secrets` (SA keys + token) |
| 12 | each AI CLI logged in on the new box (paste-the-code) | human | 057 T023 (still open for our own box) |

**Total today for a non-GCP machine: ~12 steps on 2 machines, 5 box.env
keys and a root-key handling step, no single command, and no page that
lists them**: `grep -ciE 'satellite|second machine|multi.?machine|fleet' README.md` -> 0.
For a GCP machine in the outsider's own project: steps 1-4 are ~10 cnf and
code edits first (they are our project, our users, our box tag).

Time: **not measured** for an outsider. Ours took a working day of a lane
plus the owner's go per apply (057 7, 2026-10-01 ~09:00-14:05Z), with the
code already being written for exactly that box.

### 1.3 Cost (numbers, list price; ranks below usability, 072 section 2)

| item | per month | source |
|---|---|---|
| our second machine, `e2-standard-16` (16 vCPU / 64 GB), europe-north1, always on | **~$430 VM + ~$18 disks and NAT = ~$450** | estimate from the e2 list rate; 057 T013 (catalogue check) still OPEN |
| the 057 approval it replaced, `e2-highmem-4` | ~$163 | 057 4.2 |
| the budget alert still set in cnf | 170 (billing currency) | `prd.env.yaml:278` `budget_amount_month: 170` vs `:295` `machine_type: e2-standard-16`: on the estimate the alert fires every month |
| an outsider's extra box on any provider, 8-16 vCPU | ~$40-150 | estimate, not measured |
| the hub side of a second machine | $0: no new hub resource | 058 3.2 (one more box id, pin, roster) |

## 2. Blockers

1. **The only machine provisioning is GCP in our project.** 059/060 are
   rendered from `prd.env.yaml` with `tf_key_project: csi-spl-all`
   (`prd.env.yaml:270, 285`) and the playbook runs only on 060's generated
   inventory through IAP (`satellite-playbook.func.sh` header). A box on any
   other cloud, on-prem or a laptop has no coded path at all. This also
   breaks 072 3.1's seam rule: the "box" contract is GCP-shaped.
2. **The playbook carries our box's facts as literals**
   (`box-playbook.yaml:27-45`: box tag, a dead id band, fleet env and tenant,
   timezone, uids, our repo URL). An outsider edits code to run it.
3. **OS user names live in the estate cnf** (`prd.env.yaml:323-324`) and the
   playbook assumes uids 2000/2001 (`box-playbook.yaml:39-40`). Not a
   blocker in code (the tmux socket follows the uid,
   `spool-env.inc.sh:272`), but a stranger copying the cnf inherits our users.
4. **`do_spl_box_deploy` needs a GCP project key even to run desks**:
   `spl-box-deploy.func.sh:147-149` marks `PREREQ key missing` when
   `~/.gcp/.<org>/key-<org>-<app>-<env>.json` is absent, and a `DRY_RUN=0`
   install refuses; `ENV` is `dev or prd` (its `@param`). A box on a P1
   compose hub can never pass it (072 F9 / A17 cover the env, not the key).
5. **The first pin needs the tenant root key** on the new box or a second
   machine (`spl-desk-pin.func.sh:26-28`). Same root cause as 072 F8; with
   many machines it is paid once per machine per tenant.
6. **Fleet config is copied per machine, and the copy path needs ssh.**
   `lease.conf` must be identical everywhere (`do_spl_lease_rank` header;
   `do_spl_fleet_config` header, 068 F5: "one rank line applied on one
   machine flapped the orchestrator for 3 h").
   `do_spl_fleet_config` reaches a box only by a local dir or ssh, and a
   NAT'd machine is not reachable by ssh (`spawn-remote.sh:6`
   "Could not resolve hostname"). The hub already holds the lease itself.
7. **A forgotten `SPOOL_DESK_BOX` reuses the first machine's box id.**
   The default is `box-desk` (`spool-fleet-relay.sh:63`,
   `spl-desk-pin.func.sh:25`). Two machines on one box id evict each other
   in a loop (058 H1, close 4409). Today this fails by symptom, not by name
   (072 measure 3, clarity of errors).
8. **A legacy id is baked into a default path**:
   `git grep -n CLE-parent-level -- csi-spl-orc` -> 4 lines
   (`spl-box-leave.func.sh:109`, `spl-lane-restart`, `spl-orch-rotate`), the
   hold-note root `/var/tmp/CLE-parent-level/dispatch/hold`.
9. **One GitHub login shared by every machine**: the 5000/h API quota is
   shared and was hit twice in 2 min (HOWTO-satellite-work section 4, gap 15).
   With N machines it gets N times worse.
10. **No outsider doc.** README: 0 hits (1.2). The how-to that exists,
    HOWTO-satellite-work.md, is written for our two boxes (ssh to our
    satellite, our users).

## 3. Actions

New ids M1-M9, in the 072 section 6 shape. Effort: XS < 0.5 day, S <= 1
day, M 2-5 days. Ranked by 072 section 2 (time, then steps, then errors).

| # | action | changes | owner | effort | acceptance check (a test can run it) |
|---|---|---|---|---|---|
| **M1** | `do_spl_box_enrol`: ONE action run on the new machine. Asks/reads `<hub url>`, `<tenant>`, `<new box>`; writes the 5 box.env keys of 1.2 #6 (`SPOOL_DIR_LAYOUT=qualified` from day one); mints the desk key; pins it with a join token once A5 lands, else prints the one exact admin-mode `do_spl_desk_pin BOX_PUBKEY=...` line for the root-key holder; refuses a box id already live on the hub roster | G18, B5, B7 | orc | S-M | stub hub: run twice -> `box-config.sh` shows the 5 keys, the 2nd run changes nothing; with `<new box>` already on the roster -> exit non-zero naming the clash (control: today's flow takes it silently) |
| **M2** | `do_spl_box_deploy` for a box with no GCP: the key prereq becomes `todo` (not `missing`) when the cnf has no GCP backend or `ENV=self`, and the action takes `ENV=self` + `SPOOL_HUB_URL` | A17, B4 | orc | S | `ENV=self SPOOL_HUB_URL=<url> BOX_DEPLOY_CMD=check ./run -a do_spl_box_deploy` prints no `PREREQ key missing`; test in `spl-box-deploy.tst.sh` |
| **M3** | Refuse the default box id on a second machine: when the hub roster already shows `box-desk` live from another host and box.env has no `SPOOL_DESK_BOX`, the desk start refuses with "set SPOOL_DESK_BOX (box-config.sh)" | B7 | orc + api | S | two stub machines, neither sets the key -> the 2nd refuses with that line; never a 4409 loop |
| **M4** | Box bootstrap for ANY ssh host: `HOST=<ssh host> ./run -a do_box_playbook` runs the 060 roles 01-11 on a plain inventory; 060 terraform becomes one way to get a host (the GCP backend of 072 3.1) | B1 | iac | M | `do_box_playbook HOST=localhost SATELLITE_PLAYBOOK_ARGS=--check` against a Debian 13 container exits 0; `grep -ci iap <new action>` -> 0 |
| **M5** | Playbook facts from cnf, not literals: `box_tag`, fleet env/tenant, timezone, uids, `repo_url`, `agent_clis` move to `steps.060-*` (or the M4 inventory vars); drop the dead `agent_id_range` | B2, B3 | iac + cnf | S | `grep -cE '^\s+(box_tag\|agent_id_range\|fleet_tenant\|box_timezone\|owner_uid\|repo_url):' box-playbook.yaml` -> 0; `do_tpl_gen` clean |
| **M6** | Fleet config through the hub: the ranking (`LEASE_PRIORITY*`) is a field of the fleet row the hub already keeps; every machine's lease loop reads it; `lease.conf` keeps only local facts | B6 | api + orc | M | change the ranking on one machine -> the other machine's loop uses it within one tick with no ssh; the 068 F5 flap test (two machines, two rankings) cannot be built any more |
| **M7** | Hold-note root from the spool root: `ROTATE_HOLD_DIR` default -> `$SPOOL_ROOT/dispatch/hold` | B8 | orc | XS | `git grep -c CLE-parent-level -- csi-spl-orc` -> 0; the 3 actions' tests green |
| **M8** | Per-machine GitHub identity: each box gets its own token (a GitHub App installation token per machine), so N machines get N quotas | B9 | orc + owner | M | two machines -> `gh api rate_limit` shows two separate `resources.core` pools |
| **M9** | `DEPLOY.md` "More than one machine": the walk after M1-M2 (enrol, deploy, rank, drain), costs, and the error index for 4409, `pin_conflict`, `ambiguous_to_box`, `unknown_local_agent` | B10, A15 | docs | S | every command on the page has a passing check in this table; linked from README; a timed run of it rides 072 A16 |

**Top 3** (072 section 2): **M1** (12 steps on 2 machines -> 1 command plus
one pin line), **M2** (a box on a compose hub can run the server side at
all), **M4** (a second machine on any provider, and the 3.1 seam for boxes).
M7 is XS and can ride any lane that touches those files.

Order: M7, M2, M5 are independent (wave 1). M1 after M2; M3 with M1. M4
after M5. M6 is its own spec-sized change on the hub. M9 last.

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | Is "an outsider runs agents on more than one machine" in scope for 072 v1, or after P1-P3? | **In scope, after A4/A5**: M2, M5, M7 now (cheap, unblock it); M1, M4 next; M6, M8 when a second outsider fleet exists |
| Q2 | Extra machines: keep GCP terraform as the only path, or a provider-neutral ssh-host bootstrap (M4) with GCP 060 as one backend? | **M4 first**; it is 072 3.1's seam applied to boxes, and the cheaper non-GCP box (1.3) becomes a supported path |
| Q3 | Fleet ranking: kept per machine (today, needs ssh or care) or held by the hub (M6)? | **The hub**: the lease is there already, and one mismatched line cost 3 h of flapping (068 F5) |
| Q4 | Our own second machine: confirm the `e2-standard-16` price (057 T013) and raise the 059 budget from 170 to the confirmed figure + 10%? | **Yes**: on the estimate (~$450/month) the alert at 170 fires every month and so tells nothing |

<!-- last-edit: 2026-10-04 — c-163, research section 11 -->
