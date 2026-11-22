# 071: box runtime - one start/stop action, one deploy action

Status: **draft v0.3** (v0.2: the 4.4 gap is closed by the lease pause; v0.3: section 7, refresh now, SPL-6239, in review). Lane A (c-142) writes this spec and builds
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

Go build caches are pruned by `do_prune_go_build_cache` on its own `*/5` crontab line (`# csi-spl:go-cache-prune`, installed like the box-stats cron by `do_setup_go_cache_prune_cron`): every hour, and on any tick where the filesystem that holds the cache is at or over 85% full. A cache whose user runs a Go build (a `go`, `compile`, `link`, `vet` or lint process of that user) is a `KEEP busy` line and loses only entries untouched for over `GO_CACHE_BUSY_MIN_AGE_MIN` (default 180 min), by the age step and then the 8G cap, oldest first; an executable entry counts by its directory's mtime and each age is checked again right before its delete (SPL-3110: Go refreshes a used entry's mtime once it is an hour old, so an entry a running build uses is never that old; SPL-2986: 2026-10-23 two pre-push api runs failed with go-build "no such file" when fresh entries were trimmed under them; skipping the whole busy cache let it reach 15G on sat the same day). A build that starts between an idle plan and its delete stops that run. On a critical disk the busy size cap goes deeper (SPL-3912): when the cache is over its cap and its filesystem is at or over the disk headroom guard's critical mark (`spl_box_disk_marks`, `DISK_HEADROOM_CRIT_PCT`, default 92), the cap step takes entries idle over 61 min instead of `GO_CACHE_BUSY_MIN_AGE_MIN`, with a `CRIT` line and `idle_min=` / `crit_pct=` on the cap `PLAN` line; the age step and a cache on a roomier disk keep the 180-min cut-off (sat 2026-10-27: an always-busy user kept 13G against the 8G cap and /mnt/data reached 93%). Each run starts with one timestamped `START` line in `cron.out`.

The prune cannot keep up with a write rate, so the writers stay small. The api test scripts (`run-all-tests.sh`, `hub-pg.tst.sh`, `hub-gcs.tst.sh`, `store-pg-groups.tst.sh`, `hub-pg-groups.tst.sh` in `csi-spl-api/src/bash/tests/`) export `GOFLAGS="-mod=mod -trimpath"` (SPL-3171): without `-trimpath` a compile action id holds the package directory, so every lane worktree wrote its own copy of each package it tested. On sat, 2026-10-24, 5.72 GB of the box owner user's cache was born in one hour, ~90% of it compiled in four lane worktrees (the two caught in `ps` were running `hub-pg.tst.sh`); one hub-pg compile in a second worktree of the same sha added 262 MB, 0.45 MB with `-trimpath` (n=1). The flag makes `runtime.Caller` file names module-relative, so a test finds a repo file from its package directory (the `go test` working directory) instead. `go-test-trimpath.tst.sh` holds both. `build.sh` keeps building without `-trimpath`: it would drop `main.commit` from the build info (`build-stripped.tst.sh`).

The write side (SPL-3119): no test or script points go at a throwaway `GOMODCACHE` with the shared build cache. Without `-trimpath` every compile action id holds the package directory, so a build from a fresh module cache writes new third-party entries that no later run reuses: `build-warm-mod-cache.tst.sh` added 575089594 bytes to its caller's cache per run (n=2, go1.26.10, 2026-10-23) and now builds into its own `$T/build`; `go-cache-throwaway.tst.sh` refuses a script that sets one without the other. `build.sh` still builds without `-trimpath` (`build-stripped.tst.sh`: the flag hides `main.commit`), so this rule stays next to the test scripts' flag (SPL-3171).

On both boxes the box Go is go1.26.10 since 2026-10-21 (GO-2026-6809, the stdlib
crypto/x509 fix that reddened wf 15; owner HUM-10, t1 1e709e5c, poll 09f9bcfa and
msg ff5d4b5f; before it go1.26.9 since 2026-10-20, SPL-2717): `/usr/local/go` is a
symlink to `/usr/local/go1.26.10` (the official tarball, sha256 checked against
go.dev), `/etc/profile.d/go.sh` appends `/usr/local/go/bin` to every login PATH,
and the old trees stay as `/usr/local/go1.26.9` (and `/usr/local/go1.25.1` on the
main box). Measure it:
`readlink -f /usr/local/go` and `sudo -u "$SPOOL_AGENT_USER" bash -lc 'go version'`.
The next switch on any box runs through `cd csi-spl-iac && GO_VERSION=<X.Y.Z> GO_SWITCH_REASON=<why> AGENT_ID=<id> ./run -a do_box_go_switch` (SPL-2739, test `box-go-switch.tst.sh`): a dry run unless `DRY_RUN=0`, which needs the owner's go per box.

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

### 4.5 A dirty desk checkout is recovered, never cleaned (SPL-2490)

The crontab line moves the desk checkout with `git checkout --detach
origin/master`. Tracked edits left in that checkout make the checkout fail,
and every tick then runs stale code. From 2026-10-02 the `desk-reconcile`
topic carried 16 such blockers, 11 of them `dirty:` (bug round 1 plan, row
03). When `desk-reconcile-cron.sh` finds HEAD behind trunk and tracked files
dirty, it now:

1. takes `<state dir>/recover.lock` with `flock -n`. When another tick holds
   it, or a git `index.lock` exists, it does nothing and the tick stays
   stale;
2. snapshots the staged and unstaged tracked changes with `git stash create`,
   checks that the snapshot still matches the tree, and stores it as
   `refs/rescue/desk-cron/<YYYYMMDDTHHMMSSZ>` (`-2`, `-3` ... when that
   second is taken);
3. resets the tracked files to HEAD and checks out trunk. It never runs
   `git clean` and never touches an untracked file. When trunk would
   overwrite an untracked file, git refuses the checkout and the tick stays
   stale. The work stays in the ref;
4. tells the orchestrator in a `desk-reconcile` blocker that names the ref.
   `git -C <checkout> stash apply <ref>` restores the work.

It recovers only a HEAD that is an ancestor of trunk. `DESK_DIRTY_RECOVER=0`
turns it off. Gate: `desk-cron-trunk.tst.sh` check 11.

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
   A stopped desk row the box does not run is named on one line and does
   not fail it (`box_deploy_drop_retired`): a desk `do_spl_desk_rebox`
   moved away (`rebox-seated.txt`, `rebox-retired/`); a stub whose pinned
   desk lives under another user (`spl_desk_moved_to`, spec 069 8.4: the
   box-update cron runs as the box user, the desks as `SPOOL_DESK_USER`,
   SPL-5847); an unpinned stub with no live sidecar, which nothing starts.

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

## 7. Refresh now: a box sample within 10 s of a click (SPL-6239)

Status of this section: **draft v0.3, for a cross-vendor spec review**. Docs
only: nothing below is built. Written 2026-11-22 by c-176 on tree
`origin/master` @ `8d7782cc3`; every `file:line` below is on that tree.

### 7.1 The ask

The owner (HUM-10, t1 topic `78f0138c`, msg `cfc8ec2b`, 2026-11-22 08:32Z),
verbatim:

> "As the Admin I want to have the means to see the RAM and disk utilization rates on the boxes within 10s of a click on a refresh button"

The dispatcher's plan in that topic (msg `fb111060`): the hub asks each
connected box for a sample over its open connection; the box answers with the
same sample as its 5-minute one; the page shows each box's sample age and
marks a box that did not answer within 10 s as old; only admins may click;
clicks are rate-limited. This section follows that plan. Where it differs or
says more, 7.11 lists it.

### 7.2 What exists (measured on `8d7782cc3`)

| part | where | what it does today |
|---|---|---|
| the 5-minute sample | `csi-spl-orc/src/bash/run/post-box-stats.func.sh:23-42` (`do_post_box_stats`), run by the `*/5` `# csi-spl:box-stats` cron (`box-stats-cron.sh`, `do_setup_box_stats_cron`) | reads `/proc/loadavg`, `nproc`, `/proc/meminfo`, the live panes and `df`, then `spool box-stats put` on a one-shot `role=cli` session |
| the sample's fields | `csi-spl-orc/src/bash/run/spl-lane-map.func.sh:745-764` (`spl_lane_box_sample`), `:769` (`spl_lane_box_disks`: `timeout 10 df -kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs`, at most 16 mounts) | `{box, load1, load5, load15, cpus, mem_total_kb, mem_avail_kb, swap_used_kb, agents_live, disks[]}` |
| the box CLI | `csi-spl-api/src/go/spool-hub-api/cmd/spool/box_stats.go:38-74` | `box-stats put` sends lane_op `box_stats_put` |
| the hub, box side | `internal/hub/box_stats.go:144-184` | `box_stats_put`: `At` = the hub's clock, `WriterBox` = the session's box, `AppendBoxStat` |
| the hub, browser side | `internal/hub/box_stats.go:37-40`, `:104-137` | `GET /v1/tenant/box-stats?box=&since=` under `audit.read`, minus the boxes the box-owner lock hides (`lockViewFor`, `box_lock_view.go:133`) |
| the table | rdb `0117_box_stats.sql`, `0121_box_stats_disks.sql`; `internal/store/box_stats.go:22` (`BoxStatsRetention` 30 days), `:25` (`BoxStatsMax` 20000 rows per list) | append-only, pruned by the hub's retention sweep (`box_stats.go:43`) |
| the box's open socket | `internal/hub/ws.go:402-421` (`register`: one `role=box` session per (tenant, box), last hello wins), `:455-459` (`boxSession`); client `internal/hubclient/hubclient.go:593-640` (`readLoop`, a `switch f.Type`) | the desk sidecar `spool hub-run` (`cmd/spool/hub.go:1298`) keeps it; the hub closes it at `SPOOL_HUB_WS_MAX_LIFE` (5 min) and the box redials (`ws_maxlife.go:30`, `rotateGrace` 15 s) |
| hello features | `internal/wire/wire.go:121-141` (`backfill`, `fallback`, `commit`, `live_ack`) | how the hub knows what a box client understands |
| two hub instances | cnf `env.hub.cloud_run.max_instances` = 2 | a box's socket may sit on the other instance; cross-instance fan-out is Postgres LISTEN/NOTIFY (`internal/store/wake.go:19`, `internal/hub/wake.go:27`) |
| the agent-run report | `internal/hubclient/agent_run.go:41` (`AgentRunReport`), wired at `cmd/spool/hub.go:1234` | which roster agents run, from the dispatch lease's liveness file |
| the pages | `csi-spl-wui/src/pages/monitoring/boxes/index.vue:189-193` (box stats since 1 h, under `audit.read`), `[id].vue:87-92` (NOW: the latest sample and its age), `[id].vue:242-262` (`loadStats`, which already has a quiet re-read) | no refresh button: `grep -niE 'refresh\|reload'` on both pages -> 3 lines, all in `[id].vue`: the `loadStats` comment (`:245`) and the roster refresh (`:322`, `:324`). `[id].vue:328` re-reads quietly every 5 min while the tab is visible |

Two facts differ from the lane brief: the 5-minute sample comes from the
box-stats cron, not the lane-map tick (`post-box-stats.func.sh:11-12`; the
lane-map's `LANE_BOX_ROW_S` only rate-limits the BOX-0 row it refreshes on
the same run); and the disks column is rdb `0121`, while `0118` is
`0118_fleet_load_target.sql`.

### 7.3 The flow and its 10-second budget

1. The admin clicks **Refresh** on Monitoring > Boxes (the list or one box).
2. The browser sends `POST /v1/tenant/box-stats/refresh` (body `{}` for every
   box, or `{"box": "<id>"}`).
3. The hub checks the permission and the limits (7.5), picks the boxes to
   ask (7.6.2), mints one request id per box and announces each on the
   NOTIFY channel `spool_box_sample` (payload `<tenant>|<box>|<req>|<deadline unix ms>`).
4. Every hub instance listens. The one that holds that box's `role=box`
   socket, with the hello feature `box_sample`, writes it a `box_sample`
   frame (`msg_id` = the request id). An instance that holds no such socket
   keeps the request until its deadline: a box that says hello in that time
   gets the frame then (the 5-minute socket roll).
5. The box's `spool hub-run` collects the sample (7.6.3) and writes one
   `box_sample_put` frame on the same socket. No new dial and no new hello.
6. The instance that holds the socket checks the request id, stores the
   sample in `box_stats` exactly as a tick sample (`At` = the hub's clock),
   and drops the request.
7. The requesting instance reads `box_stats` for the asked boxes every 250 ms
   and answers as soon as every asked box has a row newer than the click, or
   at its wait cap, whichever comes first.
8. The page renders each box's row, its age, and the stale mark (7.4).

| step | share of the 10 s | basis |
|---|---|---|
| 1-2 browser to hub | 0.5 s | not measured |
| 3 checks, box list, NOTIFY | 0.2 s | not measured |
| 4 NOTIFY to the socket's instance, frame written | 0.3 s | not measured (the message wake-up rides the same mechanism) |
| 5 box collects | 3.0 s cap | `df` under a 3 s timeout; the rest is `/proc` reads. Measured: the `spl_lane_box_disks` `df` command took 4, 6, 4, 6, 5 ms on one box, n=5, 2026-11-22 |
| 5-6 frame back, `AppendBoxStat` | 0.3 s | not measured |
| 7 the requester sees the row | 0.25 s | the poll interval |
| hub wait cap (steps 3-7) | **7.0 s** | `SPOOL_HUB_BOX_REFRESH_WAIT`, cnf `hub.env` |
| 8 answer to render | 1.0 s | not measured |
| slack | 1.5 s | |
| **total** | **10 s** | 0.5 + 7.0 + 1.0 + 1.5 |

The hub never holds the request past the cap: a box that did not answer by
then is stale (7.4). Build row T8 measures the real click-to-render time on
dev before the issue closes.

### 7.4 What the page shows per box

- **Every box keeps a row.** The answer carries each asked box's newest
  sample, fresh or not. A box is never blanked by a refresh, and nothing
  shows a value it did not measure.
- **Its age**: "12 s ago" from the row's `at` (the hub's clock), with the
  exact time as the title, as `[id].vue:92` does today.
- **Its state**, one of:

| state | when | shown as |
|---|---|---|
| `fresh` | the box answered within the wait, row `at` >= the click | the age only |
| `recent` | not asked: its newest sample is younger than the per-box limit (7.5) | the age only; no box is sampled twice inside the limit |
| `stale` | asked, no answer by the cap (socket down, an old binary, a hung box) | its last sample, its real age and a "no answer within 10 s" mark |
| `never` | asked, and no sample at all in the retention | "no sample yet", as the page says today for an empty history |

- The Refresh button is disabled while a refresh runs, and shows the time
  the last one ended.

### 7.5 Who may click, and the limits

**Who: `tenant.settings`**, so `biz_owner` and `admin` (`internal/rbac/rbac.go:271-281`).
Seeing box stats stays `audit.read` (adds `product_owner`). Why: a refresh
makes every box do work, so it is an operator action, not a read; the owner
asked it "as the Admin"; and an existing permission needs no rbac migration.
The other choice was a new `boxes.refresh` permission, granted to the same
two roles: cleaner names, at the cost of an rbac change. The reviewer may
pick it; this spec proposes `tenant.settings`. Without the permission the
button is not drawn and the route answers 403.

**Limits** (cnf `hub.env`, the defaults named here):

| limit | default | what happens |
|---|---|---|
| per box, hub side: `SPOOL_HUB_BOX_REFRESH_MIN_S` | 60 s | a box whose newest sample (tick or refresh) is younger is not asked; it answers `recent` |
| per tenant, in flight | 1 | a click while one runs joins it and gets the same answer |
| per tenant, per rolling hour: `SPOOL_HUB_BOX_REFRESH_PER_H` | 12 | the 13th answers 429 with `Retry-After` |
| per box, box side: `SPOOL_BOX_SAMPLE_MIN_S` | 30 s | `spool hub-run` answers at most one `box_sample` per 30 s, whatever the hub sends; a frame inside it is logged and dropped |
| unsolicited answers | refused | the hub stores a `box_sample_put` only for a request id it issued for that (tenant, box) and whose deadline has not passed, so a box cannot write extra samples this way |

So a box samples on demand at most once a minute through the hub, and at
most twice a minute even with a faulty hub.

### 7.6 The build

#### 7.6.1 Wire

`internal/wire/wire.go`, three constants:

- `TBoxSample = "box_sample"`: hub to box, `msg_id` = the request id. No body.
- `TBoxSamplePut = "box_sample_put"`: box to hub, `msg_id` = the request id,
  `lane` = one sample object, the same JSON as `box_stats_put` (no new field).
  Fire and forget: the hub sends no reply; a refused sample is logged on the
  hub with the reason (the `store.CheckBoxStat` text).
- `FeatureBoxSample = "box_sample"`: the hello feature of a box client that
  answers `box_sample`. The hub asks no socket without it, so an old binary
  gets no frame it would mis-route, and its box reads `stale`.

The hub writes `Box` and `WriterBox` from the session (`x.box`), never from
the frame, as `box_stats_put` does (`box_stats.go:176`).

#### 7.6.2 Hub

New file `internal/hub/box_refresh.go`:

- the route `POST /v1/tenant/box-stats/refresh` (+ `OPTIONS`), beside
  `routeBoxStats`;
- the boxes it asks: every box with a sample in the last 24 h for the tenant,
  minus the ones `lockViewFor` hides from this actor, minus the `recent`
  ones; or the one box named, under the same rules;
- the pending map `(tenant, box) -> {req, deadline}` on every instance, fed
  by the NOTIFY listener (a new channel on the listen connection that
  `RunWake` already holds; `store.BoxSampleWaker`, Memory and Postgres, so
  the tests run two hub servers on one Memory store as two instances, as
  `memWake` does for the message wake-up);
- on a NOTIFY: when this instance holds the box's socket with the feature,
  write `box_sample`; on a `role=box` hello: when a pending request for that
  box is still inside its deadline, write it then;
- `case wire.TBoxSamplePut` in the session's frame switch (`ws.go`, beside
  `case wire.TCommit` at `:193`): check the pending request id, decode with
  `DisallowUnknownFields`, `CheckBoxStat`, `AppendBoxStat`;
- the answer: `{asked_at, wait_ms, boxes: [{box, state, row}]}`, `row` the
  same `store.BoxStat` the GET returns, `state` one of 7.4.

#### 7.6.3 Box

New file `internal/hubclient/box_sample.go`, and `case wire.TBoxSample` in
`readLoop` (`hubclient.go:612`), handled off the read goroutine so a slow
`df` never stalls deliveries:

- `load1/5/15` from `/proc/loadavg`, `cpus` as `nproc` counts it (the
  process's CPU affinity), `mem_total_kb`, `mem_avail_kb`, `swap_used_kb`
  from `/proc/meminfo`: the same sources and the same arithmetic as
  `spl_lane_box_sample`;
- `disks` from the same `df -kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs`
  command under a 3 s timeout (the tick allows 10 s), parsed as
  `spl_lane_box_disks` parses it: the same mounts, at most 16, `used_kb`
  when df prints it; a timeout sends `disks: []`, as the tick does on an
  unreadable df;
- `agents_live`: the number of roster agents the `AgentRunReport` says run.
  This is the one field whose source differs: the tick counts live panes
  (`spl_lane_live_here`), which the desk sidecar's user may not be able to
  read. When the box has no fresh report, the hub copies `agents_live` from
  the box's newest tick sample. The owner asked for RAM and disk, so the
  agent count is not part of the ask; T2's parity test names the difference;
- the 30 s box-side guard (7.5);
- `FeatureBoxSample` added to the hello features of `role=box` sessions.

The desk sidecar binary is rebuilt by `spl_host_spool` on the desk-reconcile
tick (section 3.1), so boxes pick it up without a deploy step. Until a box
runs it, the feature is absent and the box reads `stale`.

#### 7.6.4 WUI

- `utils/spool-client-lazy.mjs` (beside `boxStats`, `:966`): `refreshBoxStats(ctx, { box })`;
  its type in `types/mjs-shims.d.ts` (beside `:151`).
- A `BoxRefreshButton.vue` on `monitoring/boxes/index.vue` (all boxes) and
  `[id].vue` (this box), drawn only with `tenant.settings`.
- `utils/box-resources.mjs`: merge the answer's rows into the page's rows and
  keep each box's `state`; `[id].vue` re-reads its history quietly
  (`loadStats(true)`, `:242`) after the answer.
- Every new string is a translation key in every locale file
  (`developer-guide.md` 3.4), with the fleet's language check before it
  ships.

#### 7.6.5 Migration and cnf

No migration: the refresh sample is a `box_stats` row like the tick's (7.7)
and the permission exists. The new hub settings
(`SPOOL_HUB_BOX_REFRESH_WAIT`, `_MIN_S`, `_PER_H`) are cnf `hub.env` keys,
rendered by tpl-gen in the same commit.

### 7.7 Stored, and the retention effect

**A refresh sample is stored in `box_stats`, like the tick's.** It has to be:
the instance that holds the socket is often not the instance that holds the
browser's request, and the table is how the answer crosses between them. It
also keeps the page consistent: a reload after a refresh shows the same
sample, not the older tick one.

The effect, with the limits of 7.5:

- **rows**: at most 12 refreshes per hour per tenant, so at most 12 extra
  rows per box per hour, beside the 12 tick rows. A box clicked every hour
  for 30 days reaches 17280 rows, under `BoxStatsMax` (20000) for one box;
  the pages read 1 h or 24 h, never the full window.
- **hourly averages**: `BoxStatHours` (`internal/store/box_stats.go:122`) averages every row of an hour, so an
  hour with refreshes weights the minutes someone looked at. Peaks are not
  affected. Telling refresh rows apart would need a column (a migration);
  this spec does not add one. The reviewer may ask for it.
- **retention**: unchanged, 30 days, the same sweep.

### 7.8 Tests

Each test lands with its build row and ships with its red control
(`developer-guide.md` 2.12.1): seen red on the planted defect, then green,
both outputs in the commit body.

| test | where | proves | red control |
|---|---|---|---|
| refresh contract | `internal/hub/box_refresh_test.go` | two hub servers on one Memory store; a fake box client with the feature on instance B; `POST` on instance A answers `fresh` for that box, within the wait cap + 1 s, waited on the answer event, no fixed sleep | the fake box sends its hello without `box_sample`: the answer is `stale`, the test fails |
| silent box is stale | same file | a fake box with the feature that never answers: the answer comes at the cap, `stale`, with its last row and that row's own `at` | plant a hub that labels any box with a row `fresh`: the test fails |
| limits | same file | a second click inside 60 s writes no second frame (frames counted on the fake box); the 13th click in an hour is 429; an unsolicited `box_sample_put` stores nothing; `product_owner` gets 403 | drop each check in turn: its case fails |
| box handler | `internal/hubclient/box_sample_test.go` | fixture `/proc` files and a stub `df`: the sample is the expected object; two frames within 30 s give one answer; a hung `df` gives `disks: []` within 3 s | remove the guard: two answers, the test fails |
| collector parity | `csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh` | the same fixtures through `spl_lane_box_sample` (`LANE_LOADAVG`, `LANE_MEMINFO`, `LANE_NPROC`, `LANE_DF_CMD`) and through the Go collector give the same object, `agents_live` left out and named | change the Go mount filter: the test fails |
| click to render | `csi-spl-wui/tests/e2e/box-refresh.test.mjs` (Playwright, mocked api) | click Refresh: the mocked fresh row's age is shown within 10 s of the click; a mocked `stale` box keeps its old row with the stale mark, never blank; without `tenant.settings` no button | remove the stale branch from the page: the stale case fails |

### 7.9 Build rows

Dependency-ordered, smallest first. Each row lands with its test and its
red control.

| row | builds | test | needs |
|---|---|---|---|
| T1 | the wire constants and the hello feature (7.6.1) | a hello carrying `box_sample` parses; the hub reads the feature | - |
| T2 | the Go collector, no frame yet (7.6.3, minus the handler) | box handler (fixture part) + collector parity | - |
| T3 | the box handler in `readLoop`, the 30 s guard, the feature in the hello | box handler (frames, guard, hung df) | T1, T2 |
| T4 | `store.BoxSampleWaker`: the NOTIFY channel, Memory and Postgres | a NOTIFY reaches a second listener; Postgres under `PRE_PUSH_TIER=full` | - |
| T5 | the hub's pending map, frame send, hello catch-up, `box_sample_put` accept | two-instance frame delivery; unsolicited answer refused | T1, T4 |
| T6 | the route, permission, limits, wait, answer; the cnf keys + tpl-gen | refresh contract, silent box, limits | T5 |
| T7 | the WUI button, age, stale mark, i18n | click to render (e2e) + the i18n gates | T6 |
| T8 | the help text for Monitoring > Boxes; on dev, 10 clicks timed click to render | the measurement in the commit body: n, min, max, the tree sha and binary versions | T3 on the dev boxes, T7 deployed |

T3 can ship before T5: a box that sends the feature to a hub that never asks
changes nothing.

### 7.10 Out of scope

A periodic auto-refresh, a faster tick, CPU % (the sample has load, not CPU
use), alerts on a threshold, and a refresh of the daily host facts sheet
(`hostEvery`, 24 h, `internal/hubclient/host.go`).

### 7.11 Where this differs from the dispatcher's plan (msg `fb111060`)

1. "Only admins can click": `tenant.settings`, held by `admin` and
   `biz_owner` (the tenant owner). 7.5 says why and names the alternative.
2. "The same sample it sends every 5 minutes": the same fields and the same
   reads, collected by `spool hub-run` in Go and sent on the open socket, not
   by running the bash cron action. That action needs a fresh hello and a
   lane read on top of its own work, and runs as the box user, while the
   socket belongs to the desk sidecar's user. Only `agents_live` comes from
   another source (7.6.3).
3. The 10 s is split into a 7 s hub wait and 3 s for the browser and render
   (7.3), not 10 s of waiting for the box.
4. A refresh sample is stored like a tick sample (7.7): the two hub instances
   need the table to pass the answer between them.

<!-- version: 0.3.0 · updated: 2026-11-22 -->
