# 071: box runtime - one start/stop action, one deploy action

Status: **draft v0.2** (v0.2: the 4.4 gap is closed by the lease pause). Lane A (c-142) writes this spec and builds
`do_spl_pool_ctl` (section 4). Lane B builds `do_spl_box_deploy` (section 5)
on this contract. Draft 2026-10-03, c-142, on tree `origin/master` @
`e69fbb44`.
Related: [070 three-second response](../070-three-second-response/spec.md)
section 5.2 (`spool pool serve`, `do_spl_pool_serve`),
[068 peer seats](../068-peer-seats/spec.md) (the peer crons and poll loops),
[069](../069-ysg-box-out/spec.md) (the box crons manifest),
[SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md) (the lease).

`<cloud box>` and `<pc box>` stand for the two box tags, and `<box user>` for
the OS user that owns the crontab. Box tags and user names are banned
literals in this tree.

## 1. What the owner asked (HUM-10, prd t1 #spool-hub-devel, topic `55c97c00`, 2026-10-03, verbatim)

~19:21Z (msg `26ad0364`):

> "create a new discussion for the actual implementation of having a start and stop script for the whole pool software. The whole thing on the server side should be possible to start with one shell action: start something, run something, start/stop something. This will take care of all the starting and stopping of the runtimes."

~19:23Z (msg `7ec7f5f3`):

> "And then we would need to have some kind of a deployment shell action which, on any Linux box, would deploy, set up the cron, and do the needed installations, which will enable the running of the full server-side software successfully."

The first ask is `do_spl_pool_ctl` (section 4, lane A). The second is
`do_spl_box_deploy` (section 5, lane B).

## 2. The rule both actions follow

They **orchestrate the actions that exist**. Neither one re-implements a
start, a stop or a cron line. Every row below already has an action that owns
it. `do_spl_pool_ctl` calls that action. `do_spl_box_deploy` calls the
installers. A fix to one of those actions is its own narrow commit, never a
copy of its logic.

## 3. Inventory: what runs on a box today

Measured on `<cloud box>`, 2026-10-03 ~19:30Z, n=1 box, with `crontab -l`
(as `<box user>`) and `ps -eo user,pid,etimes,args`. The `<pc box>` figures
are c-001's, from ~19:25Z: its desk binary is built by `spl_host_spool` into
`$SPL_STATE_DIR/bin/spool` with a `.src` stamp. prd runs 1.1.3 with 14 hub-run
sidecars, dev runs 1 sidecar. So the native path holds on both boxes.

### 3.1 Long-lived processes (what `do_spl_pool_ctl` starts and stops)

| row | process | scope | starts with | stops with | checked by | measured on `<cloud box>` |
|---|---|---|---|---|---|---|
| `desk:<tenant>/<box>` | `spool hub-run`, one per (env, tenant, desk box), from `$SPL_STATE_DIR/bin/spool` | env | `do_spl_desk_up` through `do_spl_desk_up_all`, `_tenants` and `_boxes` (the desk-reconcile cron, every tick) | `ENV=<env> TENANT_ID=<t> DESK_BOX=<box> DESK_ALL=1 DRY_RUN=0 ./run -a do_spl_desk_down` | pid file `$SPL_STATE_DIR/desk/<t>/<box>/spool/.hub/hub-run.pid`, live, cmdline carries `hub-run` (`spl_desk_alive`); deeper: `do_spl_desk_check` | prd: 6 (t1 + 5 tenants), dev: 0 |
| `lease` | the dispatch lease loop: `renew` + `watch`, or `fleet` (with `LEASE_FLEET`); `do_spl_asks_tick` runs as its child | box (env = `LEASE_ENV` in `lease.conf`) | `LEASE_CMD=ensure ./run -a do_spl_dispatch_lease` (the desk-reconcile cron, every tick, unless `peer/crons.applied`) | `LEASE_CMD=stop ./run -a do_spl_dispatch_lease` | `flock` held on `<spool root>/dispatch/<verb>.run` (`spl_lease_running`); `LEASE_CMD=show` | `fleet` loop up 40624 s; `LEASE_ENV=prd` |
| `peer` | `do_spl_peer_poll`, one loop per OD seat (spec 068) | box | `./run -a do_spl_peer_ensure` (the `csi-spl:peer-ensure` cron once spec 068 L10 applies it) | `spl_peer_stop <seat>` (the same function `do_spl_peer_ensure` uses) | `flock` held on `<spool root>/peer/<seat>/poll.run` | none: no `<spool root>/peer/seats` |
| `pool-serve` | `spool pool serve` (spec 070 L3, Go) | env | `ENV=<env> ./run -a do_spl_pool_serve` (spec 070 5.2) | its pid file `<spool root>/pool/serve.pid` | the pid file, live, cmdline carries `pool serve` | not built: `spool pool serve -h` prints `unknown command "pool"` |

### 3.2 Cron lines (what `do_spl_box_deploy` installs)

| tag (`# csi-spl:<tag>`) | schedule | runs | installed by | on `<cloud box>` |
|---|---|---|---|---|
| `desk-reconcile` | `*/3` | `desk-reconcile-cron.sh`, dev | `do_spl_desk_install_service` (`ENV=dev`) | yes |
| `desk-reconcile-prd` | `1-59/5` | `desk-reconcile-cron.sh`, prd | `do_spl_desk_install_service` (`ENV=prd`) | yes |
| `unanswered-sweep` | `2-59/10` | `unanswered-sweep-cron.sh` | `do_spl_unanswered_sweep_install_cron` | yes |
| `agent-id-reap` | `*/15` | `agent-id-reap.sh` (`DRY_RUN=1`) | `do_spl_agent_id_reap_install_cron` | yes |
| `orch-rotate` | `5 * * * *` | `orch-rotate-cron.sh` | `do_spl_orch_rotate_install_cron` | yes |
| `dispatch-rotate` | `15 * * * *` | `dispatch-rotate-cron.sh` | `do_spl_dispatch_rotate_install_cron` | yes |
| `agent-identity-reconcile` | `* * * * *` | `agent-identity-reconcile.sh --apply` | `do_spl_agent_identity_install` | yes |
| `agent-boot-restore` | `@reboot` | `agent-boot-restore-cron.sh` | `do_spl_agent_boot_restore_install_cron` | yes |
| `weekly-full-scan` | `0 17 * * 5` | `weekly-full-scan-cron.sh` (iac) | `do_install_weekly_full_scan_cron` (iac) | yes |
| `box-cron:*` (4 rows) | per `cnf/box-crons/box-crons.manifest` | box sessions, graft | `do_install_box_crons` (spec 069) | no |
| `peer-restart`, `peer-distill`, `peer-ensure` | spec 068 6.2 | the peer crons; they replace the two rotations and the sweep | `do_spl_peer_crons` (`APPLY=1`, owner's go) | no |
| `pool-serve` | `* * * * *` | `do_spl_pool_serve` | `do_spl_pool_serve_install_cron` (spec 070 L3) | not built |

Measure it again: `crontab -l | grep -o '# csi-spl:[a-z0-9:-]*$'`.

### 3.3 Not runtimes: never started or stopped by these actions

- **Agent windows and everything in them.** That covers the `claude` and
  other agent processes, their `spawn-*.sh` launchers and the
  `spool-notice-pane.sh` strips in the agent windows. They are interactive.
  The fleet tools own them.
- **The hub.** Cloud Run (`20`), not a box process.
- **Another box.** Each box runs its own `do_spl_pool_ctl` from its own
  checkout, state dir and spool root.

## 4. `do_spl_pool_ctl` (lane A)

`csi-spl-orc/src/bash/run/spl-pool-ctl.func.sh`.

```
ENV=<dev|prd> POOL_CMD=<start|stop|status|restart|ensure> [DRY_RUN=1] ./run -a do_spl_pool_ctl
```

| param | meaning |
|---|---|
| `ENV` | required: `dev` or `prd` |
| `POOL_CMD` | `status` (default), `start`, `stop`, `restart`, `ensure` |
| `DRY_RUN` | `1` (default) prints what each verb would call and calls nothing. `status` is always read-only |
| `POOL_TENANT` | the tenant `start` seats live agents in. Default: `LEASE_TENANT` in `lease.conf`, else `t1` |
| `SPOOL_ROOT` | default `/var/spool-hub` |

### 4.1 Which rows a run acts on

- **env rows** (`desk:*`, `pool-serve`) belong to `ENV`.
- **box rows** (`lease`, `peer`) belong to the box env: `LEASE_ENV` in
  `<spool root>/dispatch/lease.conf`, default `prd`. A `start`, `stop` or
  `restart` acts on the box rows only when `ENV` is the box env. So
  `ENV=dev` never touches the prd lease. On `<cloud box>` today, `ENV=dev`
  acts on the dev desks and the dev `pool-serve` only.
- `status` prints every row, plus one `cron:<tag>` row for each tagged cron
  line (`running` = installed).

### 4.2 The verbs

| verb | does, in order |
|---|---|
| `start` | Removes the env's reconcile pause marker and, with the box rows, the lease pause. Then the desk rows: `do_spl_desk_up_all` (`TENANT_ID=$POOL_TENANT`), `do_spl_desk_up_tenants` (the other tenants), `do_spl_desk_up_boxes`, the same three steps a reconcile tick runs. Then `LEASE_CMD=ensure`, `do_spl_peer_ensure`, and `do_spl_pool_serve` when it is built. Every step is idempotent, so a second `start` is a no-op |
| `ensure` | The same as `start`, but it keeps a pause marker. While the env is paused (marker no older than `DESK_PAUSE_MAX_SECS`), it touches no row at all. While only the lease pause is fresh, it starts every row except the lease. This is the verb a cron may call |
| `stop` | Writes the pause marker `<spool root>/.desk-reconcile.<env>.pause` (body: `pool-ctl stop <utc> <user>`), so the reconcile does not re-seat what was just stopped. With the box rows, it also writes `<spool root>/dispatch/lease.pause`, so no reconcile tick (dev or prd) re-takes the lease (4.4). Then, in reverse order: stops `pool-serve` by its pid file, `spl_peer_stop` for each seat, `LEASE_CMD=stop`, and `do_spl_desk_down DESK_ALL=1` for each desk whose sidecar is live. A row that is already stopped or missing is skipped, so `stop` twice is a no-op |
| `restart` | `stop`, then `start` |
| `status` | One line per row: `<row> <running|stopped|missing> <detail>`. `missing` means the box has no such runtime: no `lease.conf`, no peer seat, or `pool serve` not built (detail: `not built yet (spec 070 L3)`). Exit 0 |

### 4.3 Safety

- **It kills only by a pid file or a lock that its own action wrote**: the
  desk sidecar's `hub-run.pid` (cmdline checked by `do_spl_desk_down`), the
  lease and peer `.run` locks, and `pool/serve.pid`. It never matches a
  command-line pattern and never runs `tmux kill-*`. Before it kills
  `pool-serve`, it checks that the pid is not a tmux pane's process and that
  its cmdline is `spool pool serve`. A pid file that points anywhere else is
  refused and left alone.
- **It touches this box only**: the local state dir and the local spool root.
- **prd**: `status` is read-only. A prd `start`, `stop` or `restart` needs
  the owner's go. Agents send the exact command to the orchestrator.

### 4.4 The lease pause (closed in v0.2)

`desk-reconcile-cron.sh` used to run `LEASE_CMD=ensure` on every tick, both
dev and prd, *before* it read the pause marker and regardless of it. So
the next tick re-took a lease that a `stop` had just released. The per-env
desk pause cannot hold the lease, because a rebox (spec 058 6.5) pauses the
desks and must keep dispatching.

The fix (c-001's go, 2026-10-03) adds a separate, box-level marker,
`<spool root>/dispatch/lease.pause`. The reconcile skips the lease ensure
while that marker is no older than `DESK_PAUSE_MAX_SECS` (1800 s). A stale
marker is ignored with a WARN, the same rule as the desk pause.
`do_spl_pool_ctl stop` writes it when it stops the box rows, and `start`
removes it. Gates: `desk-cron-trunk.tst.sh` check 10 and
`spl-pool-ctl.tst.sh` checks 3, 8 and 9.

A `stop` still holds for at most `DESK_PAUSE_MAX_SECS`, by design: a box
that was forgotten in the stopped state comes back by itself. A longer stop
removes the crons (`BOX_DEPLOY_CMD=remove`, section 5).

## 5. `do_spl_box_deploy` (lane B)

`csi-spl-orc/src/bash/run/spl-box-deploy.func.sh`. It brings any Linux box
from a fresh checkout to a running server side, and back.

```
ENV=<dev|prd> BOX_DEPLOY_CMD=<install|check|remove> [DRY_RUN=1] ./run -a do_spl_box_deploy
```

`check` is read-only: it prints the plan and each prerequisite's verdict.
`install` and `remove` are dry runs unless `DRY_RUN=0`. Every step is
idempotent. It names no literal host, user, domain or box tag:

- the box tag comes from `spl_desk_box_default`;
- the user is `$USER`;
- the paths come from `$HOME`, `$APP_PATH` and `$SPOOL_ROOT`;
- the hub URL comes from the cnf (`env.dns.api_fqdn`, through `do_spl_desk_cnf`).

### 5.1 Prerequisites (checked first; `install` refuses and names every one that is missing)

| prerequisite | check |
|---|---|
| tools | `python3 yq flock curl setsid tmux git go crontab` resolve on the cron PATH (`desk-reconcile-cron.sh --check-tools`). With `BOX_DEPLOY_PKGS=1` and `DRY_RUN=0`, the missing ones are installed through the box's package manager with `sudo`, listed first. Go comes through `csi-spl-api/src/bash/use-go-toolchain.sh` |
| checkout | `$APP_PATH` is a main checkout on trunk (not a linked worktree: every installer refuses one) |
| self-updating cron checkout | `<shared checkout>-desk-cron` exists. `do_spl_desk_install_service` creates it when it is missing |
| spool root | `$SPOOL_ROOT` exists with the right owner and mode (`do_provision_spool_root`) |
| cnf | `$SPL_STATE_DIR/<env>.env.yaml` resolves (`do_spl_cloud_cnf`) |
| keys | the per-env key `~/.gcp/.csi/key-csi-spl-<env>.json` and, on a desk's first seat, the tenant root key (`ROOT_KEY_JSON`). Both are checked for presence only, never printed and never in git |

### 5.2 Steps of `install`

1. Prerequisites (5.1).
2. **Build the binary** through `spl_host_spool`
   (`csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh`). It writes
   `$SPL_STATE_DIR/bin/spool` plus its `.src` stamp, keeps a current build
   and refuses a downgrade. This is the only build step: `pool serve` is a
   subcommand of the same binary.
3. **Install the crons**: each installer of 3.2, called with `DRY_RUN=0`,
   for this env. That is `do_spl_desk_install_service` (`ENV=<env>`), the
   sweep, reap, identity, boot-restore and box-crons installers, the iac
   weekly scan, and either the two rotations or, once spec 068 L10 has
   applied, `do_spl_peer_crons`. `do_spl_pool_serve_install_cron` joins the
   list once spec 070 L3 lands. A failing installer stops the run and names
   the installer.
4. `ENV=<env> POOL_CMD=start DRY_RUN=0 ./run -a do_spl_pool_ctl`.
5. `POOL_CMD=status`. The run exits non-zero when a row the box should run
   (3.1, minus the `missing` rows) is not `running`.

`remove` runs `POOL_CMD=stop`, then each installer's remove action
(`DESK_SERVICE_ACTION=remove`, `*_CRON_ACTION=remove`,
`BOX_CRONS_ACTION=remove`, ...). It keeps the state dir, the keys and the
spool root, which hold the inboxes.

### 5.3 Acceptance (lane B)

Lane B's test uses stub installers and a stub crontab. It shows that:

- `install` twice gives one line per tag;
- a missing tool is refused and named;
- `remove` leaves no `csi-spl:` line;
- a worktree `APP_PATH` is refused.

A run on `<pc box>` with `ENV=dev` then shows `POOL_CMD=status` all
`running`.

## 6. Lanes

| lane | owns | done when |
|---|---|---|
| A (c-142) | this spec, `spl-pool-ctl.func.sh`, `tests/spl-pool-ctl.tst.sh` | stub test: start then status = all running, stop then status = all stopped, stop twice = no-op, `pool serve` absent = "not built yet", an interactive pane is never killed. Each check has a failing control |
| B | `spl-box-deploy.func.sh` and its test | 5.3 |

<!-- version: 0.2.0 · updated: 2026-10-03 -->
