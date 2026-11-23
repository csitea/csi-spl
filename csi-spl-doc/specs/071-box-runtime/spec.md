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
Extended by [section 8](#8-actual-box-values-from-one-snapshot-htop-df-and-du-spl-6318) (SPL-6318: actual `htop`, `df -P` per mount and `du` top-10 directories from one timestamped snapshot, superseding the configured/daily display on Monitoring > Boxes).

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
| the sample's fields | `csi-spl-orc/src/bash/run/spl-lane-map.func.sh:745-760` (`spl_lane_box_sample`), `:769` (`spl_lane_box_disks`: `timeout 10 df -kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs`, at most 16 mounts) | `{box, load1, load5, load15, cpus, mem_total_kb, mem_avail_kb, swap_used_kb, agents_live, disks[]}` |
| the box CLI | `csi-spl-api/src/go/spool-hub-api/cmd/spool/box_stats.go:38-74` | `box-stats put` sends lane_op `box_stats_put` |
| the hub, box side | `internal/hub/box_stats.go:144-184` | `box_stats_put`: `At` = the hub's clock, `WriterBox` = the session's box, `AppendBoxStat` |
| the hub, browser side | `internal/hub/box_stats.go:37-40`, `:104-137` | `GET /v1/tenant/box-stats?box=&since=` under `audit.read`, minus the boxes the box-owner lock hides (`lockViewFor`, `box_lock_view.go:133`) |
| the table | rdb `0117_box_stats.sql`, `0121_box_stats_disks.sql`; `internal/store/box_stats.go:22` (`BoxStatsRetention` 30 days), `:25` (`BoxStatsMax` 20000 rows per list) | append-only, pruned by the hub's retention sweep (`box_stats.go:43`) |
| the box's open socket | `internal/hub/ws.go:403-422` (`register`: one `role=box` session per (tenant, box), last hello wins), `:454-458` (`boxSession`); client `internal/hubclient/hubclient.go:593-640` (`readLoop`, a `switch f.Type`) | the desk sidecar `spool hub-run` (`cmd/spool/hub.go:1298`) keeps it; the hub closes it at `SPOOL_HUB_WS_MAX_LIFE` (5 min) and the box redials (`ws_maxlife.go:30`, `rotateGrace` 15 s) |
| hello features | `internal/wire/wire.go:121-147` (`backfill`, `fallback`, `commit`, `live_ack`, `kinds13`) | how the hub knows what a box client understands |
| two hub instances | cnf `env.hub.cloud_run.max_instances` = 2 | a box's socket may sit on the other instance; cross-instance fan-out is Postgres LISTEN/NOTIFY (`internal/store/wake.go:19`, `internal/hub/wake.go:28`) |
| the agent-run report | `internal/hubclient/agent_run.go:41` (`AgentRunReport`), wired at `cmd/spool/hub.go:1234` | which roster agents run, from the dispatch lease's liveness file |
| the pages | `csi-spl-wui/src/pages/monitoring/boxes/index.vue:189-193` (box stats since 1 h, under `audit.read`), `[id].vue:87-92` (NOW: the latest sample and its age), `[id].vue:242-260` (`loadStats`, which already has a quiet re-read) | no refresh button: `grep -niE 'refresh\|reload'` on both pages -> 3 lines, all in `[id].vue`: the `loadStats` comment (`:245`) and the roster refresh (`:322`, `:324`). `[id].vue:328` re-reads quietly every 5 min while the tab is visible |

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
| 3-7 the hub wait, all inside its 7.0 s cap (the sub-rows below are its parts, not added to it): | | |
| 3 checks, box list, NOTIFY | 0.2 s | not measured |
| 4 NOTIFY to the socket's instance, frame written | 0.3 s | not measured (the message wake-up rides the same mechanism) |
| 5 box collects | 3.0 s cap | `df` under a 3 s timeout; the rest is `/proc` reads. Measured: the `spl_lane_box_disks` `df` command took 4, 6, 4, 6, 5 ms on one box, n=5, 2026-11-22 |
| 5-6 frame back, `AppendBoxStat` | 0.3 s | not measured |
| 7 the requester sees the row | 0.25 s | the poll interval |
| hub wait cap (steps 3-7, the sum of the parts above is 4.05 s worst case) | **7.0 s** | `SPOOL_HUB_BOX_REFRESH_WAIT`, cnf `hub.env` |
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
| `stale` | asked, no answer by the cap (socket down, an old binary, a hung box) | its last sample, its real age and a "no answer within the wait" mark (the hub's 7 s cap, 7.3) |
| `never` | asked, no answer by the cap, and no sample at all in the retention (a pinned box whose cron never wrote and whose socket did not answer) | the page's existing "No current sample yet." (`boxes.now_none`, `csi-spl-wui/i18n/locales/en.json:2554`) |

- The Refresh button is disabled while a refresh runs, and shows the time
  the last one ended.

#### 7.4.1 The summary table at the top (owner follow-up)

The owner (HUM-10, t1 topic `78f0138c`, msg `f87c349b`, 09:18:14Z), verbatim;
the post ends mid-sentence:

> "Also, although UI has to be changed, the most essential info per box should be on the top in a single table, in one row, one box, and then the attributes on the table. Then the rest of the info could be as"

So Monitoring > Boxes (`index.vue`) opens with **one table: one row per box,
one column per key attribute**. Today the page is a list of cards, one per
box, each with its facts under it (`index.vue:38-73`, `MonitoringBoxFacts` at `:70`);
there is no table.

| column | value | source (all exist on `8d7782cc3`) |
|---|---|---|
| Box | the box tag and its online dot, a link to `/monitoring/boxes/<id>` | the roster row, as the card's link today |
| RAM used % | `memUsedKB / (memUsedKB + memAvailKB)`, rounded up as `diskUsedPct` rounds (`box-resources.mjs:95`); a new helper beside it, since `currentOf` returns the two numbers, not the percent | `currentOf` (`utils/box-resources.mjs:178`) |
| RAM free | `memAvailKB`, through `formatKB` (KiB, MiB or GiB as it picks) | `currentOf`, `formatKB` (`box-resources.mjs:286`) |
| Fullest disk | its mount and its used %, df's Use% | `lowestDisk` + `diskUsedPct` (`box-resources.mjs:108`, `:95`) |
| Load / CPUs | `load1` / `cpus` | `currentOf` |
| Agents live | `agents_live`, the existing field (a refresh sample's value comes as 7.6.3 says) | `currentOf` |
| Sample age | "12 s ago", the exact time as the title | the row's `at` |
| State | the 7.4 mark: none for `fresh` / `recent`, "stale" for `stale`, `boxes.now_none` for `never` | the refresh answer; before any refresh, none |

Rules:

- **One row per box of this workspace**, in the order the list uses today
  (online, then offline). The filter above the list filters the table too.
  The groups of other workspaces (`index.vue:74`) stay below it as today:
  this workspace's box stats do not cover them.
- **Every number comes from the box's newest sample**, the same row the card
  shows (`latestBoxStat`, `box-resources.mjs:153`), so the table and the
  details below it never disagree. A box with no sample shows the page's
  existing "No current sample yet." (`boxes.now_none`) across its reading
  cells, never a 0, until a refresh fills it (7.6.2).
- **The Refresh button (7.6.4) sits on the table's header**, and a refresh
  updates the table's rows, ages and marks in place.
- **Without `audit.read`** (today's rule for box stats, `index.vue:191`) the
  reading columns are not drawn: the table shows Box only.
- **Narrow screens**: below 640 px the table keeps Box, RAM used %, Fullest
  disk and Sample age; the other columns move into the row's title text.
  The page never scrolls sideways.
- Every header and mark is a translation key (`developer-guide.md` 3.4).

**Below the table** the per-box details stay as they are today (option A).
This waits on the owner's answer to the poll in the same topic (msg
`c9db41d2`): A as today, one section per box; B folded per box, opened by
its row; C on a separate page per box. A different answer changes only
build row T9 and its e2e test, not the hub or the box.

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

The hub writes both `Box` and `WriterBox` of a refresh sample from the
session (`x.box`); the frame's `box` field is ignored. This is stricter
than `box_stats_put`, which takes `WriterBox` from the session but keeps
`Box` from the frame (`box_stats.go:176`, returned at `:184`; review W1).
The asked unit is a pinned box (7.6.2), the id a `role=box` socket
registers under (`ws.go:403-422`, `x.box`), so the stored row lands under
the id the page matches rows by (`latestBoxStat`).
A box whose 5-minute cron writes another `box` than its desk id
(`LANE_BOX`) already does not match its roster row today; T8 names any
such box on dev.

#### 7.6.2 Hub

New file `internal/hub/box_refresh.go`:

- the route `POST /v1/tenant/box-stats/refresh` (+ `OPTIONS`), beside
  `routeBoxStats`;
- the boxes it asks: **every pinned box the page lists**: `Store.ViewBoxes`
  (`internal/store/store.go:286`; Postgres reads `FROM pins LEFT JOIN roster`,
  `view_postgres.go:53-59`, so a pin whose box announced no agents is still
  a row), the same detail the page builds its rows from (`hub/view.go:348`,
  `index.vue:115`, `box-rows.mjs:76`), minus a revoked pin (`ViewBox.Revoked`),
  minus the browser pseudo-box `box-wui` (`BROWSER_BOX`,
  `csi-spl-wui/src/utils/view-api-core.mjs:180`, which the page skips too),
  minus the ones `lockViewFor` hides from this actor, minus the `recent`
  ones; or the one box named, under the same rules. Not `Store.Roster`
  (`store.go:259`): it holds only boxes that announced agents (Postgres
  `SELECT box_id, agent_id FROM roster`, Memory drops an empty set), so a
  pinned box with a live socket and no agents would be listed and not asked
  (review W1 on `b130fc296`). Whether the box has a sample does not matter:
  a box with a live socket whose 5-minute cron wrote nothing (no sample in
  24 h, or none at all) is asked like any other, and its row fills on the
  answer (review W3 on `3a806f18c`). A pinned box with no socket anywhere
  reads `stale`, or `never` when it has no sample;
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
tick (section 5.2 step 2; the reconcile cron is section 3.2), so boxes pick it up without a deploy step. Until a box
runs it, the feature is absent and the box reads `stale`.

#### 7.6.4 WUI

- `utils/spool-client-lazy.mjs` (beside `boxStats`, `:966`): `refreshBoxStats(ctx, { box })`;
  its type in `csi-spl-wui/src/types/mjs-shims.d.ts` (beside `:151`).
- A `BoxRefreshButton.vue` on `monitoring/boxes/index.vue` (all boxes) and
  `[id].vue` (this box), drawn only with `tenant.settings`.
- The summary table (7.4.1), a `BoxSummaryTable.vue` at the top of
  `monitoring/boxes/index.vue`, built by row T9 before the button.
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
  rows per box per hour, beside the 12 tick rows. At that cap for all 30
  days one box holds (12 + 12) x 24 x 30 = 17280 rows, under `BoxStatsMax`
  (20000, `store/box_stats.go:25`); one click an hour gives 9360. Two boxes
  at the cap over a full 30-day list are 34560, over the cap, as two boxes'
  tick rows alone already fill most of it (8640 each); the pages read 1 h
  (`index.vue:192`) or 24 h (`[id].vue:253`), never the full window.
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
| wire feature (T1) | `internal/wire/wire_test.go` + `internal/hub/box_refresh_test.go` | a hello carrying `box_sample` gives a session whose features hold it; `box_sample` / `box_sample_put` frames round-trip through the strict decoder | drop `FeatureBoxSample` from the hello's features: the session lacks it, the test fails |
| NOTIFY channel (T4) | `internal/store/box_sample_wake_test.go` (Memory) + the Postgres twin under `PRE_PUSH_TIER=full` | a `spool_box_sample` announce from one store handle reaches a second listener with tenant, box, request id and deadline intact; a malformed payload is dropped, never delivered | plant a listener on another channel name: nothing arrives, the test fails |
| two-instance delivery (T5) | `internal/hub/box_refresh_test.go` | an announce on instance A puts one `box_sample` frame on the fake box socket held by instance B; a box that says hello on B inside the deadline gets it then, after it none; an unsolicited `box_sample_put` (unknown request id, or past its deadline) stores nothing | plant a frame write that ignores the feature (asks every socket): the featureless fake box gets a frame, the test fails |
| a never-sampled box (W3) | same file | a pinned box **with no roster row** (it announced no agents) and a live featured socket, and no row in `box_stats` at all, is asked; its answer is stored and the POST answers `fresh` with that row; the same box with no socket answers `never`; a revoked pin and `box-wui` are not asked | two plants, each fails the test: the asked set as "boxes with a sample in 24 h", and the asked set as `Store.Roster` (the box has no roster row, so it is not asked) |
| refresh contract | `internal/hub/box_refresh_test.go` | two hub servers on one Memory store; a fake box client with the feature on instance B; `POST` on instance A answers `fresh` for that box, within the wait cap + 1 s, waited on the answer event, no fixed sleep | the fake box sends its hello without `box_sample`: the answer is `stale`, the test fails |
| silent box is stale | same file | a fake box with the feature that never answers: the answer comes at the cap, `stale`, with its last row and that row's own `at` | plant a hub that labels any box with a row `fresh`: the test fails |
| limits | same file | a second click inside 60 s writes no second frame (frames counted on the fake box); the 13th click in an hour is 429; an unsolicited `box_sample_put` stores nothing; `product_owner` gets 403 | drop each check in turn: its case fails |
| box handler | `internal/hubclient/box_sample_test.go` | fixture `/proc` files and a stub `df`: the sample is the expected object; two frames within 30 s give one answer; a hung `df` gives `disks: []` within 3 s | remove the guard: two answers, the test fails |
| collector parity | `csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh` | the same fixtures through `spl_lane_box_sample` (`LANE_LOADAVG`, `LANE_MEMINFO`, `LANE_NPROC`, `LANE_DF_CMD`) and through the Go collector give the same object, `agents_live` left out and named | change the Go mount filter: the test fails |
| summary table | `csi-spl-wui/tests/e2e/box-summary-table.test.mjs` (Playwright, mocked api) + a unit test of the row builder | one row per box of the workspace, the columns of 7.4.1 in order, the values of the mocked newest sample (RAM used %, the fullest mount's df Use%); a box with no sample reads `boxes.now_none`, never 0; without `audit.read` only the Box column; at 375 px no sideways scroll | build each row from the first sample instead of the newest: the values differ, the test fails |
| click to render | `csi-spl-wui/tests/e2e/box-refresh.test.mjs` (Playwright, mocked api) | click Refresh: the mocked fresh row's age is shown within 10 s of the click; a mocked `stale` box keeps its old row with the stale mark, never blank; without `tenant.settings` no button | remove the stale branch from the page: the stale case fails |

### 7.9 Build rows

Dependency-ordered, smallest first. Each row lands with its test and its
red control, both in 7.8 (the `test` column names the 7.8 rows). T8 is a
measurement on dev, not a gate, so it has no red control: its commit body
carries the numbers.

| row | builds | test | needs |
|---|---|---|---|
| T1 | the wire constants and the hello feature (7.6.1) | wire feature | - |
| T2 | the Go collector, no frame yet (7.6.3, minus the handler) | box handler (fixture part) + collector parity | - |
| T3 | the box handler in `readLoop`, the 30 s guard, the feature in the hello | box handler (frames, guard, hung df) | T1, T2 |
| T4 | `store.BoxSampleWaker`: the NOTIFY channel, Memory and Postgres | NOTIFY channel | - |
| T5 | the hub's pending map, frame send, hello catch-up, `box_sample_put` accept | two-instance delivery | T1, T4 |
| T6 | the route, permission, limits, the asked set (the pinned boxes, `ViewBoxes`), wait, answer; the cnf keys + tpl-gen | refresh contract, silent box, a never-sampled box, limits | T5 |
| T9 | the summary table of 7.4.1 from today's `GET /v1/tenant/box-stats`, the details below as option A; i18n | summary table (e2e + unit) + the i18n gates | - (it reads only what exists; the owner's poll `c9db41d2` decides the part below the table) |
| T7 | the WUI button on the table's header, age, stale mark in its State column, i18n | click to render (e2e) + the i18n gates | T6, T9 |
| T8 | the help text for Monitoring > Boxes; on dev, 10 clicks timed click to render | the measurement in the commit body: n, min, max, the tree sha and binary versions | T3 on the dev boxes, T7 deployed |

T3 can ship before T5: a box that sends the feature to a hub that never asks
changes nothing. T9 needs no other row and can ship first: it is the owner's
"most essential info per box on the top" with the 5-minute samples, and T7
then adds the button and the fresh ones.

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

## 8. Actual box values from one snapshot: `htop`, `df` and `du` (SPL-6318)

Status of this section: **draft v0.6, for cross-vendor spec re-review** (v0.6
folds in owner poll `1a89fe8b` answers D1 = B and D2 = N from msg `cd8860d7`,
on top of v0.5's c-736 review fixes W1–W2 and N1–N6). Docs only: no code, no
migration and no terraform in this change. Written 2026-11-23 by a-729; every
`file:line` citation below is verified on `origin/master` @ `16fbe330e`
(unchanged on `b09bdbeb6`). Builds on section 7 (SPL-6239); section 8.9 lists
every place it extends or changes section 7, and section 8.10 records the
resolved owner decisions (D1 = B, D2 = N).

### 8.1 The ask

The owner (HUM-10, t1 topic `78f0138c`, 2026-11-23 ~16:0xZ), verbatim:

- msg `b27fa22f` (with a screenshot of Monitoring > Boxes):
  > "BUT THOSE are the configured and I want to see the ACTUAL data from the boxes"
- msg `c5acabfa`:
  > "as they would be shown from the htop and du cmds"
- msg `ed55626d`:
  > "at the moment the snaphot of their values where taken"
- Poll `e657ed62`, answer A:
  > "Per mount: used / size / % (as df), plus the 10 biggest directories (as du)"
- Poll `1a89fe8b` (msg `cd8860d7`, 2026-11-23 ~17:5xZ):
  > "Answer 1: B — Measured again when I press Refresh, even if it takes 30-60 s"
  > "Answer 2: N — No, htop header values only: CPU, load, memory, swap, uptime (Recommended: what you asked)"

### 8.2 What exists on `origin/master` (`16fbe330e`)

#### 8.2.1 Section 7 build status (verified via `git log origin/master -E --grep='SPL-6239 row T'`)

- **On `origin/master`**:
  - **T1** (`38da97302`): wire constants `TBoxSample`, `TBoxSamplePut`,
    `FeatureBoxSample` (`internal/wire/wire.go:149-162`).
  - **T2** (`8604ad411`): Go collector `BoxSampler.Collect`
    (`internal/hubclient/box_sample.go:53-236`), plus bash parity test
    (`csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh`).
  - **T4** (`2af5387bf`): `BoxSampleChannel = "spool_box_sample"` and
    `store.BoxSampleWaker` on Memory and Postgres
    (`internal/store/box_sample_wake.go:20-116`).
  - **T9** (`0674db0a5`, test fix `e20037af4`): `BoxSummaryTable.vue:1-90` and
    `utils/box-summary.mjs:1-50`, wired at `pages/monitoring/boxes/index.vue:43`.
- **Not on `origin/master`**: **T3**, **T5**, **T6**, **T7**, **T8**. Section
  8.8 folds them in as explicit prerequisites or extends them.

#### 8.2.2 Configured vs 24-hour daily facts vs 5-minute sampled on Monitoring > Boxes

Inspecting the real WUI code explains why Monitoring > Boxes reads as
configured and stale data instead of live box telemetry:

| page / component | `file:line` (`16fbe330e`) | fields shown | actual source | kind |
|---|---|---|---|---|
| `pages/monitoring/boxes/index.vue` | `:29`, `:193-199`; `MonitoringAllocation.vue:10-49`; `MonitoringAllocRows.vue:15`; `utils/monitoring-allocation.mjs:45-46,59-118` | Fleet band, runner CPU cap, CI overflow, runner CPUs, box order, per-box bands, agent kinds on/off, vendor split — **at the very top of the page**, above every box | `GET /v1/operator/fleet-load`, `GET /v1/tenant/settings`; every row carries `planned: true, measured: null` | **Configured** |
| `components/BoxSummaryTable.vue` | `:13-50`; `utils/box-summary.mjs:23-50`; `index.vue:43,205` | RAM used %, RAM free, fullest disk (`mount pct%` only — no used/size), `load1 / cpus`, live agents, age, State (empty until T7) | `GET /v1/tenant/box-stats?since=1h` (`latestBoxStat`) | **Sampled (5 min)**, incomplete |
| `components/MonitoringBoxFacts.vue` | `:11-13,15-32,40-46,52-68`; `index.vue:76` | OS, CPU model, CPUs, total RAM, hostname, service state, boot uptime, timezone, run-times, network IPs/gateway/DNS | `GET /v1/view/roster` `boxes[]` (`internal/hub/view.go:317-322`), collected at most once per 24 h (`internal/hubclient/host.go:32` `hostEvery`) | **Daily hello facts (24 h)** |
| `components/MonitoringBoxFacts.vue` | `:33-34,47,94,101-107` | **Free memory**, **Swap used**, **Load (1, 5, 15 min)** | **24-hour daily hello facts** (`detail.system.mem_avail_mb`, `swap_free_mb`, `load`), ignoring `props.stat` | **Stale daily facts** (should be live) |
| `components/MonitoringBoxFacts.vue` | `:35,98` | Disk: single fullest mount (`lowestDisk`); other mounts hidden in hover `title` | `props.stat` (`box_stats`, 5 min) | **Sampled (5 min)**, single mount only |
| `components/MonitoringBoxFacts.vue` | `:70-73,99`; `utils/monitoring-allocation.mjs:127-142` | Per-box band, runner CPU cap, box-order place `(planned)` | `GET /v1/operator/fleet-load` | **Configured** |
| `pages/monitoring/boxes/[id].vue` | `:89-110,253`; `utils/box-resources.mjs:178-191` | `Now` block: `load1 on cpus CPUs`, `used, avail` (no total, no %), `swapUsedKB` (no total), single `lowestDisk` line, `agentsLive` | `GET /v1/tenant/box-stats?box=<id>&since=24h` | **Sampled (5 min)**, incomplete |
| `pages/monitoring/boxes/[id].vue` | `:114`; `BoxLoadBand.vue:12-69` | Per-box load band form (`low..high % of cores`), plus one live line (`:24`, `load5` % of cores) | `GET/PATCH /v1/operator/fleet-load` | **Configured** |
| `components/BoxStatsPane.vue` | `:53-59,119-128` | `?r=hardware` opens with 24-hour `sys.memAvailMB` / `swapLine`; `?r=system` shows 24-hour `sys.load` / `bootAt` | `roster.boxes[id].system` (24 h) | **Stale daily facts** |
| `components/BoxStatsPane.vue` | `:99-110` | Per-mount disk table (`Mount`, `Size`, `Used (%)`, `Free`), buried under `?r=hardware`, omits `Used` in GiB/MiB | `latestBoxStat(stats.rows)` | **Sampled (5 min)**, no `Used` size, no `du` |

Not collected anywhere on `16fbe330e`: CPU % (total or per core), `swap_total_kb`
in `box_stats`, `mem_buffers_kb` / `mem_cached_kb`, task/thread counts, live
`uptime_s`, and the 10 biggest directories (`du`).

### 8.3 What one snapshot holds

Every live reading of a box (`htop` header, `df -P` per mount, and `du` top-10
directories) is labelled with explicit snapshot timestamps and never mixed with
24-hour daily facts. The hub stamps the snapshot with `at` when stored (as in
7.2/7.6.1), and the WUI prints both the exact snapshot time (in the reader's
time zone, ISO 8601 UTC on hover) and its relative age (`12 s ago`).

- **On an on-demand Refresh click (owner decision D1 = B, msg `cd8860d7`)**:
  every asked box measures all three parts fresh for that click — `htop` header
  and `df -P` per mount **first** (~0.26 s, so `du` disk I/O never skews `htop`
  CPU or iowait), immediately followed by a fresh time-capped `du` scan
  (`BOX_DU_TIMEOUT_S = 30 s` wall-clock cap, `BOX_DU_BUCKET_TIMEOUT_S = 5 s`
  per depth-2 bucket, under `nice -n 19 ionice -c 3`) — and sends all three
  back together in one `box_sample_put` frame. `top_dirs_at` is the instant
  that fresh `du` scan finished (within `<= 30 s` of the `htop`/`df` readings
  and `at`, taken during the same Refresh click). The hub wait cap is raised to
  **45 s** (click-to-render `<= 47 s`, inside the owner's 30–60 s allowance).
- **On the 300 s background cron tick (between Refresh clicks)**:
  Step A posts live `htop` + `df -P` (~0.26 s) paired with the box's local
  `top-dirs.json` cache (refreshed after Step A at most every
  `BOX_DU_EVERY_S = 900 s` / 15 min, and also refreshed whenever a Refresh
  click runs `du`). Before any Refresh click, `top_dirs_at` can therefore be up
  to ~15–20 min older than `at`, and is always labelled with its own timestamp;
  pressing Refresh measures all three fresh.

#### 8.3.1 Per-mount disk usage (`df -P`)

Each entry in `disks[]` (cap `BoxDisksMax = 16`, `store/box_stats.go:28`,
rdb `0121` CHECK) holds:

| field | type | meaning |
|---|---|---|
| `mount` | `string` | absolute mount point, printable ASCII, `<= 256` bytes, unique per sample |
| `fstype` | `string` (optional) | filesystem type (`ext4`, `xfs`, `vfat`, `tmpfs`, `overlay`, ...), printable `[a-z0-9._-]{1,24}` |
| `total_kb` | `int64` | `df -kP` `1024-blocks` (Size) |
| `used_kb` | `int64` | `df -kP` `Used` |
| `avail_kb` | `int64` | `df -kP` `Available` |

`Use%` is derived on read exactly as POSIX/GNU `df -P` computes `Capacity`:
`ceil(used_kb * 100 / (used_kb + avail_kb))` (`diskUsedPct` at
`box-resources.mjs:95-100`). Never `1 - avail/total`, which includes ext4's
root-reserved blocks and reads higher than `df` (note in `box-resources.mjs:90-91`).

**Which mounts are included (exact rule)**:

1. Run `df -kPT` under the 3 s timeout (`boxSampleDFTimeout`, `box_sample.go:40`),
   ignoring rows whose size/avail are non-numeric (`-`, e.g. unreachable network
   mounts) and deduplicating identical mount paths.
2. Always exclude pseudo/virtual/image filesystems: `devtmpfs`, `squashfs`,
   `efivarfs`, `proc`, `sysfs`, `cgroup`, `cgroup2`, `debugfs`, `tracefs`,
   `fusectl`, `pstore`, `securityfs`, `autofs`, `mqueue`, `hugetlbfs`,
   `rpc_pipefs`, `nsfs`, `ramfs`.
3. Include all real local and network filesystems (`ext4`, `ext3`, `ext2`,
   `xfs`, `btrfs`, `zfs`, `vfat`, `ntfs`, `nfs`, `nfs4`, `cifs`, `virtiofs`,
   `9p`, etc.). GNU `df` already lists each backing block device once (so bind
   mounts backed by a secondary data disk are not duplicated; if two mounts
   still share one `st_dev`, keep the shortest mount path).
4. **`tmpfs` and `overlay` exception rule**: exclude `tmpfs` and `overlay` by
   default, **except** when a box's agents live or write scratch data there:
   resolve `stat(path).st_dev` for `$SPOOL_ROOT`, `$SPL_WT_ROOT`,
   `$SPL_VAR_APP_DIR`, and `/tmp`. If a `tmpfs` or `overlay` mount's `st_dev`
   matches any of those paths — and for `/tmp` only when it is a dedicated mount
   with `total_kb >= 1048576` (1 GiB) — include it with its `fstype`. Every
   other `tmpfs` (`/run`, `/run/user/*`, `/dev/shm`, `/run/credentials/*`) and
   container or worktree `overlay` (e.g. `<data>/containers/overlay2/*/merged`,
   `.../node_modules`) stays excluded.

#### 8.3.2 The 10 biggest directories (`du`)

| rule | value | why |
|---|---|---|
| count | **10** (`BoxTopDirsMax = 10`) | owner poll `e657ed62` answer A |
| roots | every included mount from 8.3.1 with `total_kb >= 262144` (256 MiB) | covers real data/root disks and dedicated `>= 1 GiB` `/tmp`, skips tiny firmware partitions (e.g. `/boot/efi` at 124 MiB) |
| filesystem boundary | stay on one filesystem (`st_dev == mount_dev`, as `du -x`), never follow symlinks (`lstat`), deduplicate hardlinks by `(st_dev, st_ino)` per mount | matches GNU `du -kx`; never double-counts bind mounts or traverses `/proc`/`/sys` |
| size accounting | `st_blocks * 512 / 1024` (allocated 1 KiB blocks, identical to `du -k`) | matches `du`, not apparent `st_size` |
| privilege & unreadable trees | runs unprivileged as `<box user>` (the `# csi-spl:box-stats` crontab user, `setup-box-stats-cron.func.sh:92`), **never as `root`**; unreadable directories (e.g. root-only container storage or `/root`) are skipped and counted in `top_dirs_unreadable` | reported directory sizes can be lower than a `root` `du` would show; the UI notes skipped unreadable dirs whenever `top_dirs_unreadable > 0` |
| depth | **depth 2** below each scanned mount (depth 1 only when a depth-1 dir has no subdirectories); mount root (depth 0) is omitted | gives actionable paths (`/var/log`, `/var/cache`, `<data>/app/worktrees`) without wasting top-10 slots on nested parent/child duplicates; mount totals are already in `df` |
| deterministic scan order & coverage | (1) visit the **known-largest buckets from the previous scan** first (descending by prior `size_kb`), so the likely top-10 are always refreshed first; (2) visit remaining depth-2 buckets **round-robin across mounts** (lexicographical within each mount), resuming from a local cursor file (`du-cursor.json`) across consecutive runs when the previous run hit the total cap | prevents a slow early mount from starving other mounts and guarantees every bucket is covered over consecutive runs |
| time cap | **`BOX_DU_TIMEOUT_S = 30`** s total wall-clock cap, **`BOX_DU_BUCKET_TIMEOUT_S = 5`** s per depth-2 bucket, under `nice -n 19` + `ionice -c 3` | prevents `du` from ever loading a box (measured below) |
| partial / unvisited marking | when a depth-2 bucket hits its 5 s cap, stop descending it, keep the exact KiB summed so far with `partial: true` (rendered `>= X GiB`), and advance to the next bucket; when the 30 s total cap ends the scan before all discovered buckets are visited, count `top_dirs_unvisited > 0` and set **`top_dirs_partial = true`** (never silently claim an incomplete scan is the true top 10, and never mix sizes from different scan runs under one `top_dirs_at`) | makes capped or unvisited buckets explicit rather than misrepresenting an incomplete scan as a complete top 10 |
| timestamp | `top_dirs_at` (RFC 3339 UTC, clamped `<= at` by the hub), `top_dirs_partial` (bool), `top_dirs_unvisited` (int), `top_dirs_unreadable` (int) | makes age, completeness and privilege limits explicit |

**Measured cost on a live 16-core, 64 GiB RAM Linux build box (2026-11-23;
`/` 29 GiB with 661,671 used inodes, secondary data mount `<data>` 196 GiB
with 5,458,578 used inodes, `/tmp` 32 GiB `tmpfs`)**:

| command | measured wall time | notes |
|---|---|---|
| `df -kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs` (n=5) | **4.0..5.7 ms** | negligible |
| `/proc` header single pass (`stat`/`meminfo`/`loadavg`/`uptime` + numeric `/proc` count, Python, n=5) | **1.03..2.20 ms** | Go will be faster |
| Two-pass 250 ms `htop` header read (Python, n=1) | **254.1 ms** | 250 ms window + ~4 ms reads |
| `du -kx --max-depth=2 /boot/efi` | **2.5 ms** | 1 dir |
| `du -kx --max-depth=2 /tmp` | **1.90 s** | 1,885 dirs, rc=1 (unreadable entries) |
| `du -kx --max-depth=2 /var` | **1.93 s** | 156 dirs, rc=1 |
| `du -kx --max-depth=2 /` | **6.07 s** | 131 dirs, rc=1 |
| `du -ksx` on `<data>` top-level dirs (1.8 GiB..44 GiB each) | **0.04 s**, **0.18 s**, **2.44 s**, **2.79 s**, **6.30 s** | 5 dirs completed inside 10 s |
| `du -kx --max-depth=2 <data>` (under `nice -n 19 ionice -c 3`) | **> 60 s (timeout)** | 5.46M inodes; a worktree subtree (`<data>/opt`) alone timed out at > 10 s |

This measurement proves two design facts: (1) fresh `du` on Refresh exceeds
section 7's original 10 s budget, which is why the owner approved extending the
Refresh wait budget to 30–60 s (D1 = B, msg `cd8860d7`: hub wait cap **45 s**
for a **30 s** box `du` cap), and (2) an unbounded monolithic `du` on a large
data disk exceeds 60 s and yields nothing when killed, whereas a prioritised,
per-bucket time-capped Go walker returns completed buckets plus `>=` lower
bounds inside 30 s and explicitly sets `top_dirs_partial = true` when any
bucket is capped or unvisited.

#### 8.3.3 `htop` header values

All collected directly from `/proc` in Go (zero subprocesses, zero
`/proc/<pid>/stat` per-process reads):

- **CPU %**: read `/proc/stat` (`cpu` aggregate and `cpu0..cpuN-1`, up to
  `BoxCPUCoresMax = 256`) twice across a **250 ms** window
  (`boxSampleCPUWindow = 250 * time.Millisecond`). For each line, sum
  `user + nice + system + idle + iowait + irq + softirq + steal`; active delta =
  `totalDelta - (idleDelta + iowaitDelta)`. Output:
  - `cpu_pct`: total CPU % (`0.0..100.0`, 1 decimal) on `BoxStat`;
  - `cpu_user_pct`, `cpu_sys_pct`, `cpu_iowait_pct`: breakdown on `BoxSnapshot`;
  - `cpu_cores_pct[]`: per-core CPU % (`0.0..100.0`, length `cpus`) on `BoxSnapshot`.
- **Load average**: `load1`, `load5`, `load15` from `/proc/loadavg` fields 1–3
  (already in `BoxStat`).
- **Memory**: from `/proc/meminfo` (all in KiB):
  - `mem_total_kb`, `mem_avail_kb` (existing on `BoxStat`);
  - `mem_buffers_kb` (`Buffers`), `mem_cached_kb` (`max(0, Cached + SReclaimable - Shmem)`,
    matching `htop` 3.x's green/blue/yellow memory meter calculation).
  - Headline `Used` = `max(0, mem_total_kb - mem_avail_kb)` (consistent with
    `box_stats` history and `memUsedPct` at `box-resources.mjs:199`); `htop`
    bar detail shows Used, Buffers, Cache and Available against Total.
- **Swap**: `swap_used_kb` (existing) + **`swap_total_kb`** (new on `BoxStat`,
  from `SwapTotal`, `0` when the box has no swap).
- **Tasks**: from `/proc/loadavg` field 4 (`<running>/<threads>`) and counting
  numeric entries in `/proc`:
  - `tasks_total` (total PIDs), `tasks_running` (runnable kernel entities) on `BoxStat`;
  - `tasks_threads` (total threads) on `BoxSnapshot`.
- **Uptime**: `uptime_s` (whole seconds from `/proc/uptime` field 1) on `BoxStat`.

Per-process tables (top CPU / top RSS processes) are explicitly **out of scope**
per owner decision D2 = N (msg `cd8860d7`, section 8.10).

#### 8.3.4 Refresh time budget (replaces section 7.3's 10 s target per D1 = B)

Because D1 = B measures `du` fresh on every Refresh click, section 7.3's 10 s
target is replaced by a **<= 45 s hub wait / <= 47 s click-to-render** budget
(inside the owner's 30–60 s allowance, msg `cd8860d7`):

| step | time | basis |
|---|---|---|
| 1–2 browser to hub | ~0.5 s | existing HTTPS path (no client fetch timeout in `hubFetch`, `spool-client.mjs:406`) |
| 3–4 hub checks, NOTIFY, WS `box_sample` frame | ~0.5 s | same wake path as 7.3 |
| 5a box fast `htop` header (250 ms) + `df -kPT` | ~0.26 s (3.0 s `df` cap) | collected **first**, before `du`, so `du` I/O does not skew `htop` |
| 5b box fresh `du` scan (`nice -n 19 ionice -c 3`) | up to **30.0 s** cap | `BOX_DU_TIMEOUT_S = 30 s`, `BOX_DU_BUCKET_TIMEOUT_S = 5 s`; ~6–12 s on a root-only box, capped at 30 s on multi-million-inode data disks |
| 5c–6 `box_sample_put` back, atomic `box_stats` + `box_snapshots` tx | ~0.5 s | one DB tx |
| 7 hub requester poll interval | 0.25 s | 250 ms poll (7.3) |
| **hub wait cap (`SPOOL_HUB_BOX_REFRESH_WAIT`)** | **45.0 s** | covers 3 s fast + 30 s `du` + socket roll / `du.lock` wait + slack; well below Cloud Run hub `timeout_seconds: 600` (`all.env.yaml:485`), and `http.Server` has no `WriteTimeout` (`cmd/spool/hub.go:738`, only `ReadHeaderTimeout: 10s` at `cmd/spool/timeouts.go:10`) |
| 8 browser render + slack | ~1.5 s | |
| **total click-to-render** | **~8–35 s typical, <= 47 s worst case** | inside the owner's 30–60 s budget (D1 = B) |

### 8.4 How it is collected and stored (retention)

#### 8.4.1 Collection split: fresh `du` on Refresh; fast snapshot first on the 300 s cron

1. **One Go collector** (`BoxSampler.Collect` in `internal/hubclient/box_sample.go`):
   collects the fast snapshot (`htop` header, per-core CPU, `df -kPT` mounts)
   **first** (~0.26 s, so `du` disk I/O never skews `htop`), and reads
   `$SPL_VAR_APP_DIR/box-stats/top-dirs.json` (or empty if absent/corrupt).
2. **On-demand Refresh now (D1 = B; `box_sample` WS frame on `spool hub-run`)**:
   runs off `readLoop` (so message delivery never stalls), with at most **1
   in-flight collection per box** and a `SPOOL_BOX_SAMPLE_MIN_S = 60 s` guard:
   - **Step 1**: runs `BoxSampler.Collect` for fresh `htop` header + `df -kPT`
     (~0.26 s).
   - **Step 2**: runs a fresh time-capped `du` scan as a low-priority child
     process (`nice -n 19 ionice -c 3 spool box-stats du-cache --force --out "$SPL_VAR_APP_DIR/box-stats/top-dirs.json" --cursor "$SPL_VAR_APP_DIR/box-stats/du-cursor.json" --lock "$SPL_VAR_APP_DIR/box-stats/du.lock" --timeout 30s --bucket-timeout 5s`, degrading cleanly if `ionice` is unavailable). Running `du-cache` as a child process isolates `nice 19` + `ionice -c 3` to the disk walk without lowering `spool hub-run`'s own WS/delivery priority, and shares the exact same `du.lock` / `top-dirs.json` / `du-cursor.json` code path with the cron. If `du.lock` is already held by an in-flight cron scan, `--force` waits (bounded by `--timeout`); once unlocked, if `top-dirs.json` was written at or after wait start, it reuses that fresh file immediately instead of scanning twice.
   - **Step 3**: attaches the fresh `top_dirs` + `top_dirs_at` from `top-dirs.json`
     and sends `box_sample_put` on whichever active `role=box` socket is
     connected (surviving a 5-minute socket roll, `rotateGrace = 15 s` at
     `ws_maxlife.go:30`; a duplicate `box_sample` frame for the same `req` from
     hello catch-up is ignored while that `req` is already running).
3. **The 300 s box-stats cron (`do_post_box_stats`, `post-box-stats.func.sh:23-42`)**:
   - **Step A (sample & post FIRST — never delayed or loaded by `du`)**: runs
     `spool box-stats sample` (invoking `BoxSampler.Collect` with the existing
     `top-dirs.json` cache and `agents_live` from live panes) and posts via
     `spool box-stats put`. If an older hub rejects the new v2 fields
     (`DisallowUnknownFields` at `hub/box_stats.go:172`), `do_post_box_stats`
     strips them and retries the legacy v1 payload, matching the `used_kb`
     fallback at `post-box-stats.func.sh:33-39`.
   - **Step B (throttled `du` AFTER the sample is posted)**: runs
     `nice -n 19 ionice -c 3 spool box-stats du-cache --lock-nonblock --lock "$SPL_VAR_APP_DIR/box-stats/du.lock" --out "$SPL_VAR_APP_DIR/box-stats/top-dirs.json" --cursor "$SPL_VAR_APP_DIR/box-stats/du-cursor.json" --max-age 15m --timeout 30s --bucket-timeout 5s`.
     If `top-dirs.json` is younger than `BOX_DU_EVERY_S` (900 s / 15 min — for
     example because a Refresh click just updated it) or `du.lock` is held, it
     returns immediately without scanning disk; otherwise it walks the mounts
     in prioritised order (8.3.2) and atomically replaces `top-dirs.json`
     (mode `0644`, already home-redacted). Running `du` after Step A ensures the
     5-minute `htop` snapshot never measures CPU/IO generated by `du` itself
     and is never delayed by up to 30 s. (On a fresh boot with no cache yet,
     the first `top-dirs.json` is written at the end of tick 1 and ships on
     tick 2 or on any Refresh click.)

#### 8.4.2 Storage and retention: scalar history + 1-row-per-box latest snapshot

"Answered only (no storage)" does not work with two Cloud Run instances
(`max_instances = 2`, section 7.2/7.7) and blanks the page on reload. Storing
`top_dirs` and `cpu_cores_pct` on every 5-minute `box_stats` row would bloat
30-day history and `GET /v1/tenant/box-stats?since=24h` by ~25x.

So the snapshot is split across two tenant-scoped tables written in **one
transaction** under the same `at` and the session's `x.tenant` (`tenant_id`):

1. **`box_stats`** (existing 30-day append-only time series, `BoxStatsRetention = 30d`):
   adds only small nullable scalar columns (`cpu_pct`, `swap_total_kb`,
   `mem_buffers_kb`, `mem_cached_kb`, `tasks_total`, `tasks_running`, `uptime_s`
   — ~40 bytes/row). Existing rows keep `NULL`; retention (30 days) and
   `BoxStatsMax` (20,000) are unchanged.
2. **`box_snapshots`** (new **1 row per `(tenant_id, box)`**, upserted on every
   tick and every refresh): holds `{at, writer_box, snapshot jsonb}` (`cpu_cores_pct`,
   `cpu_user_pct`, `cpu_sys_pct`, `cpu_iowait_pct`, `tasks_threads`, `top_dirs`,
   `top_dirs_at`, `top_dirs_partial`, `top_dirs_unvisited`, `top_dirs_unreadable`;
   hard cap 16 KiB). O(1) rows per box regardless of refresh rate or retention;
   retired boxes older than `BoxStatsRetention` (30 days) are pruned by the same
   `PruneBoxStats` sweep.
3. **Tenant ownership of `box_snapshots` rows**: each write lands under the
   posting session's `x.tenant` (`LEASE_TENANT` for the 5-minute cron, or the
   `role=box` socket's `x.tenant` for a refresh). If `x.tenant` is NOT the
   operator workspace AND `box` is pinned in multiple workspaces (a shared fleet
   box), the hub strips `top_dirs` **before storing** and sets
   `details_redacted: true`, so host directory paths of a shared box are never
   persisted into a non-operator tenant's row (8.7.2).

### 8.5 What Monitoring > Boxes shows

**Actual live box data leads the page; configured values are demoted and
explicitly labelled `(configured / planned)`.**

1. **Top of Monitoring > Boxes (`pages/monitoring/boxes/index.vue`) — Summary
   table (`BoxSummaryTable.vue`) with Refresh button**:
   - Moves **above** `MonitoringAllocation` (the first block under the filter
     and count).
   - Columns (all from the box's newest snapshot, never from 24-hour facts or
     configured targets):
     - `Box` (tag, online dot, link to `/monitoring/boxes/<id>`)
     - `CPU` (`cpu_pct%` from `htop`, `—` on older boxes)
     - `Load / CPUs` (`load1 / cpus`, hover shows `load1 / load5 / load15`)
     - `RAM` (`used / total (pct%)`, e.g. `16.0 / 62.8 GiB (26%)`)
     - `Swap` (`used / total`, e.g. `0 / 0` or `512 MiB / 4.0 GiB`)
     - `Fullest disk` (`mount used / size (pct%)` per `df -P`)
     - `Snapshot` (local time + relative age, ISO UTC on hover)
     - `State` (section 7.4 mark: none for `fresh`/`recent`, stale mark for
       `stale`, `boxes.now_none` for `never`)
   - Narrow screens (`< 640 px`): keep `Box`, `CPU`, `RAM`, `Fullest disk`,
     `Snapshot`; move the rest to the row title, zero horizontal scroll.
2. **Per-box live snapshot (`components/BoxLiveSnapshot.vue`) — on each box card
   in `index.vue` AND as the upgraded `Now` block on `[id].vue`**:
   - Header: **`Live snapshot · taken <local time> (<age> ago)`** (exact ISO UTC
     on hover; Refresh button on `[id].vue` for `tenant.settings`; while a
     refresh runs, the button is disabled and shows an active progress label
     indicating `htop`, `df` and `du` are being measured — up to 45 s).
   - **`htop` header strip**:
     - CPU total % (`user / sys / iowait` breakdown) + compact per-core bars
       (inline up to 16 cores; summary chip with expand toggle above 16);
     - Memory: `Used / Total (pct%)`, `Avail`, `Buffers`, `Cache`;
     - Swap: `Used / Total`;
     - Load average: `1m  5m  15m`;
     - Tasks: `<total> total, <threads> thr, <running> running` · `Live agents: <n>`;
     - Uptime: `<d>d <hh>:<mm>:<ss>` from `uptime_s`.
   - **Per-mount disks (`df -P`) — always visible as a table (never hidden in hover
     text)**:
     - Columns: `Mount | Type | Used | Size | Avail | Use%`.
     - Replaces the single-line `lowestDisk` summary on `MonitoringBoxFacts.vue:35`
       and adds the missing `Used` size column to `BoxStatsPane.vue:103-105`.
   - **Top 10 biggest directories (`du`)**:
     - Sub-heading carries its own honest time:
       **`Top 10 directories (du · taken <time>, <age> ago)`** (matches the
       snapshot within seconds after a Refresh click; shows the background
       cache time before any Refresh), plus a `partial (time-capped)` badge
       when `top_dirs_partial` is true (hover names `top_dirs_unvisited` if > 0)
       and a subtle note when `top_dirs_unreadable > 0` ("unprivileged scan;
       root-only dirs skipped").
     - Columns: `Directory | Mount | Size` (`>= X GiB` on a time-capped bucket).
     - When `details_redacted` is true (8.7.2), shows a muted note ("Directory
       details are shown to the box's operator or owner admin") rather than an
       empty table that looks broken.
3. **Removing stale 24-hour duplicates & demoting configured values**:
   - `MonitoringBoxFacts.vue:33-34,47` and `BoxStatsPane.vue:57-58,125` **stop
     rendering** `sys.memAvailMB`, `swapLine`, and `sys.load` from the 24-hour
     hello sheet. Static daily facts (OS, CPU model, Hostname, Timezone,
     Run-times, Network) remain in a clearly labelled **`Static host facts
     (daily · reported <age> ago)`** block below the live snapshot.
   - `MonitoringAllocation.vue` (`index.vue:29`) moves **below** the box cards,
     wrapped in a collapsed-by-default `<details>` block titled **`Configured
     targets & allocation (planned, not live)`**, keeping its existing
     `(planned)` markers and Settings links. Per-box `mbf-allocation`
     (`MonitoringBoxFacts.vue:70-73`) keeps its explicit **`Configured (planned)`**
     heading, clearly separate from the live snapshot above it.
   - Every new label, column header and badge is an i18n key across every locale
     with the fleet's GCT language check (`developer-guide.md` 3.4).

### 8.6 Wire, store and RDB changes (named only; no migration written here)

#### 8.6.1 Wire (`internal/wire/wire.go`, `internal/store/box_stats.go`)

- Keep `TBoxSample`, `TBoxSamplePut`, `FeatureBoxSample` (`wire.go:149-162`).
  No new WS frame type is needed: a `FeatureBoxLiveV2` box runs fresh `htop` +
  `df` + `du` on `TBoxSample`, while an older v1 `FeatureBoxSample`-only box
  still answers its legacy `BoxStat` inside the wait.
- Add hello feature `FeatureBoxLiveV2 = "box_live_v2"`.
- Additive optional fields on `store.BoxStat` (`omitempty` so v1 boxes stay valid):
  - `CPUPct *float64` (`cpu_pct`), `SwapTotalKB *int64` (`swap_total_kb`),
    `MemBuffersKB *int64` (`mem_buffers_kb`), `MemCachedKB *int64` (`mem_cached_kb`),
    `TasksTotal *int` (`tasks_total`), `TasksRunning *int` (`tasks_running`),
    `UptimeS *int64` (`uptime_s`), `BoxDisk.FSType string` (`fstype,omitempty`),
    and on the inbound wire struct (`box_stats_put` / `box_sample_put` payload)
    `Snapshot *store.BoxSnapshot` (`snapshot,omitempty`).
- New `store.BoxSnapshot` struct (returned in `GET /v1/tenant/box-stats` as
  top-level `snapshots: { "<box>": BoxSnapshot }` and in
  `POST /v1/tenant/box-stats/refresh` as `boxes[].snapshot`):
  - `At time.Time` (`at`, set by hub = `BoxStat.At`)
  - `CPUCoresPct []float64` (`cpu_cores_pct,omitempty`)
  - `CPUUserPct, CPUSysPct, CPUIOWaitPct float64` (`cpu_user_pct`, `cpu_sys_pct`, `cpu_iowait_pct`)
  - `TasksThreads int` (`tasks_threads`)
  - `TopDirs []BoxDir` (`top_dirs,omitempty`),
    where `BoxDir = {Path string, Mount string, SizeKB int64, Partial bool}`
  - `TopDirsAt *time.Time` (`top_dirs_at,omitempty`),
    `TopDirsPartial bool` (`top_dirs_partial,omitempty`),
    `TopDirsUnvisited int` (`top_dirs_unvisited,omitempty`),
    `TopDirsUnreadable int` (`top_dirs_unreadable,omitempty`)
  - `DetailsRedacted bool` (`details_redacted,omitempty`, hub-set when `top_dirs`
    was stripped per 8.7.2)
- **cnf `hub.env` defaults**: `SPOOL_HUB_BOX_REFRESH_WAIT = 45s` (replaces
  section 7's `7s` per D1 = B), `SPOOL_HUB_BOX_REFRESH_MIN_S = 60`,
  `SPOOL_HUB_BOX_REFRESH_PER_H = 12`; box-side `SPOOL_BOX_SAMPLE_MIN_S = 60`
  (replaces section 7's `30`).
- **Deploy order**: hub deploys with the new fields accepted BEFORE boxes start
  sending them (both `hub/box_stats.go:172` and `cmd/spool/box_stats.go:59` use
  `DisallowUnknownFields()`).

#### 8.6.2 RDB (`csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_box_live_snapshot.sql`)

Not written in this spec commit; build row T10 claims the next number with
`do_rdb_migration_next` (head on `16fbe330e` is `0313_cost_splits_vendor.sql`,
so `<NNNN> >= 0314`). Forward-only PostgreSQL 16 DDL:

1. `ALTER TABLE box_stats` adds the 7 nullable scalar columns (`cpu_pct real`,
   `swap_total_kb bigint`, `mem_buffers_kb bigint`, `mem_cached_kb bigint`,
   `tasks_total integer`, `tasks_running integer`, `uptime_s bigint`) with
   range `CHECK` constraints (catalog-only on PG 16, no table rewrite).
2. `CREATE TABLE box_snapshots`:
   - `(tenant_id text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE, box text NOT NULL CHECK (box ~ '^[a-z0-9][a-z0-9-]{0,31}$'), writer_box text NOT NULL, at timestamptz NOT NULL, snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object' AND octet_length(snapshot::text) <= 16384), PRIMARY KEY (tenant_id, box))`
   - `CREATE INDEX box_snapshots_at ON box_snapshots (at);`
   - **RLS** (`developer-guide.md` 2.6.4, identical to `0117_box_stats.sql:45-52`):
     `ENABLE ROW LEVEL SECURITY`, `FORCE ROW LEVEL SECURITY`, `tenant_scope`
     (`tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`) and
     `operator_scope` (`current_setting('app.rls_scope', true) = 'operator'`).

#### 8.6.3 Store (`internal/store/box_stats.go`, `box_stats_postgres.go`)

- Extend `CheckBoxStat` for the new scalar fields and add `CheckBoxSnapshot`
  enforcing every limit in 8.7.1.
- Extend `BoxStats` (or add `BoxSnapshots` beside it): write `box_stats` +
  `INSERT INTO box_snapshots ... ON CONFLICT (tenant_id, box) DO UPDATE` inside
  the **same** `inTenant` transaction when `snapshot != nil`, so `at` never
  drifts; `ListBoxSnapshots(ctx, tenantID, box)` reads `box_snapshots` with
  explicit column names (never `SELECT *`, `developer-guide.md` 2.2.3);
  `PruneBoxStats` prunes `box_snapshots WHERE at < $1` too.

Built by row T10 (SPL-6318) as follows; where section 8 named no value, the
choice is recorded here:

- Migration `0317_box_live_snapshot.sql` (claimed with `do_rdb_migration_next`).
  Range CHECKs: `cpu_pct BETWEEN 0 AND 100`; `tasks_total` and
  `tasks_running BETWEEN 0 AND 4194304` (Linux `PID_MAX_LIMIT`); the other
  five `>= 0`. Same limits in `checkBoxStatHeader`, called by `CheckBoxStat`.
- `BoxSnapshots` is a store interface beside `BoxStats`:
  `AppendBoxStatSnapshot(ctx, tenant, b, snap)` (a nil `snap` writes only the
  `box_stats` row and leaves the box's snapshot row as it was) and
  `ListBoxSnapshots(ctx, tenant, box) map[box]BoxSnapshot`. `AppendBoxStat`
  is unchanged for its callers.
- `BoxDir` JSON keys: `path`, `mount`, `size_kb`, `partial`.
- Both drivers store the percentages of a snapshot rounded to 1 decimal, the
  precision 8.3.3 gives them, so the stored JSON stays far below the
  16 KiB CHECK. Without the rounding, a value such as `1e-300` prints 300
  digits in jsonb.
- `BoxDisk.FSType` (8.6.1) is not in T10: no T10 test needs it. Row T11
  adds it with the collector.

Built by row T11 (SPL-6318), `internal/hubclient/box_header.go` and
`box_df.go` on `BoxSampler.Collect`; where 8.3.1 / 8.3.3 named no value, the
choice is recorded here:

- CPU breakdown: `cpu_user_pct` = user + nice, `cpu_sys_pct` = system + irq
  + softirq, `cpu_iowait_pct` = iowait, each a share of the 8-column delta
  at 1 decimal (htop's non-detailed meter groups them so). The guest columns
  are not added: the kernel already counts them in user and nice.
- `cpu_cores_pct`: one value per `cpuN` line present in both reads, in
  `/proc/stat` order, at most 256. Its length is the kernel's online CPUs,
  which can differ from `cpus` (the process's CPU affinity) on a pinned box.
- `tasks_running` and `tasks_threads` are `/proc/loadavg` field 4;
  `tasks_total` counts the numeric entries of `/proc`; `uptime_s` floors
  `/proc/uptime` field 1.
- A part that cannot be read stays nil (NULL in the row) and the sample is
  still sent; without two `/proc/stat` reads there is no `cpu_pct` and no
  snapshot. A context cancelled during the 250 ms window sends nothing.
- `df -kPT` replaces the tick's argv. A df without the Type column (the
  tick's `df -kP`) is parsed as the tick does, so
  `csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh` still compares the
  tick's fields (the Go half writes those only) until row T12b retires the
  bash collector.
- `st_dev` is read only for `tmpfs` / `overlay` rows and for `/dev/*` rows
  (the bind-mount rule of 8.3.1 step 3), never for a network mount, and
  inside the 3 s df cap: a stat stuck on a hung mount gives `disks: []`, as
  a hung df does.
- The agent roots are the collecting process's `$SPOOL_ROOT`,
  `$SPL_WT_ROOT` and `$SPL_VAR_APP_DIR`; an unset one is no root.
- `BoxDisk.FSType` is `fstype,omitempty`, last in the struct;
  `CheckBoxStat` takes `[a-z0-9._-]{1,24}`.
- `wire.FeatureBoxLiveV2` exists; the hello carries it from row T14. The
  row T3 handler sends `Stat` as before, now with the header scalars and
  `fstype`; the hub reads `box_sample_put` only from row T5, which builds on
  a hub that already takes both, so no deploy order is at stake.

### 8.7 Limits and privacy

#### 8.7.1 Limits

Section 7.5's refresh limits are updated for D1 = B (`SPOOL_HUB_BOX_REFRESH_WAIT`
raised to `45s`; `SPOOL_BOX_SAMPLE_MIN_S` raised to `60s`; `_MIN_S=60` and
`_PER_H=12` stay in force, with v2 `recent` checking both `row.At` and
`snapshot.TopDirsAt` so a recent 5-minute cron tick carrying an older cached
`du` never suppresses an explicit Refresh click):

| limit | value | enforced at |
|---|---|---|
| hub refresh wait cap (`SPOOL_HUB_BOX_REFRESH_WAIT`) | `45 s` (replaces §7 `7 s`; Cloud Run hub timeout is `600 s`, `all.env.yaml:485`) | `hub/box_refresh.go`, cnf `hub.env` |
| per-box hub cooldown (`SPOOL_HUB_BOX_REFRESH_MIN_S`) | `60 s` (v2 `recent` requires BOTH `row.At` AND `snapshot.TopDirsAt` `< 60 s`) | `hub/box_refresh.go`, cnf `hub.env` |
| per-tenant rolling hour (`SPOOL_HUB_BOX_REFRESH_PER_H`) | `12` | `hub/box_refresh.go`, cnf `hub.env` |
| per-box sidecar guard (`SPOOL_BOX_SAMPLE_MIN_S`) | `60 s` + max 1 in-flight collection per box (replaces §7 `30 s`) | `hubclient` `box_sample` handler |
| CPU sampling window | `250 ms` | `BoxSampler.Collect` |
| background cron `du` interval (`BOX_DU_EVERY_S`) | `900 s` (15 min; Refresh bypasses with `--force`) | `spool box-stats du-cache` + `do_post_box_stats` |
| `du` total wall-clock cap (`BOX_DU_TIMEOUT_S`) | `30 s` (under `nice -n 19 ionice -c 3`, serialized by `du.lock`) | `box_du.go` |
| `du` per-bucket cap (`BOX_DU_BUCKET_TIMEOUT_S`) | `5 s` | `box_du.go` |
| `disks[]` cap | `16` mounts (`BoxDisksMax`) | `box_sample.go`, `CheckBoxStat`, rdb `0121` |
| `top_dirs[]` cap | `10` entries (`BoxTopDirsMax`), path printable ASCII `<= 256` bytes, absolute, no `..` | `box_du.go`, `CheckBoxSnapshot` |
| `cpu_cores_pct[]` cap | `256` cores (`BoxCPUCoresMax`), values `0..100` | `box_sample.go`, `CheckBoxSnapshot` |
| `snapshot` JSON size cap | `16384` bytes (`BoxSnapshotMaxBytes`) | `CheckBoxSnapshot`, rdb CHECK (`cmd/spool/box_stats.go:50` stdin cap is 64 KiB) |

#### 8.7.2 Privacy and access control (no user names or cross-tenant paths leak)

A shared fleet box can be seated in multiple workspaces (`index.vue:70-75`),
and host directories may contain OS user home directories or other workspaces'
checkouts. Three layers prevent leaks:

1. **Box-side home-directory redaction (before bytes leave the box)**:
   - Any `du` path matching a user home prefix from `/etc/passwd` (or
     `/home/<seg>` or `<data>/home/<seg>`) has the `<seg>` username replaced
     with `uid-<st_uid>` (rendered as `<data>/home/<uid>/.cache`, where `<uid>`
     is `uid-<st_uid>`). Numeric UID distinguishes heavy accounts for operators
     while never transmitting personal or OS login names.
   - **Scope limit (explicit)**: box-side rewriting covers home-directory
     prefixes only; per-user or workspace-named directories outside homes (for
     example `/tmp/<user>-...` or checkout folders) are not pattern-rewritten
     on the box. Preventing their disclosure to other workspaces relies
     explicitly on the hub's write-time and read-time gates below.
2. **Tenant isolation, write-time stripping, and box-owner lock**:
   - `box_stats` and `box_snapshots` both enforce PostgreSQL RLS (`tenant_scope`).
   - On **write** (`box_stats_put` / `box_sample_put`), if `x.tenant` is NOT the
     operator workspace AND `box` is pinned in more than one workspace, the hub
     strips `top_dirs` before storing in `box_snapshots` and sets
     `details_redacted: true`, so a shared box's host paths are never written
     into a non-operator tenant's row.
   - On **read**, both `GET /v1/tenant/box-stats` and
     `POST /v1/tenant/box-stats/refresh` apply `lockViewFor`
     (`internal/hub/box_lock_view.go:133`) to both `rows` and `snapshots`: a
     box locked to someone else is completely omitted.
3. **Who may see `top_dirs` (`du`) (hub read-time gate)**:
   - **`htop` header + `df` mounts**: readable by any `audit.read` holder in the
     workspace (`biz_owner`, `product_owner`, `admin`), as `box_stats` is today.
   - **`top_dirs`**: returned ONLY when the caller is:
     - (a) an **operator workspace admin** (`operatorActor`,
       `internal/hub/fleet_load.go:124` — sees every non-locked box in the
       operator workspace), **OR**
     - (b) a **`tenant.settings` holder (`admin` or `biz_owner`)** in a
       non-operator workspace AND the box is **dedicated to that workspace**
       (pinned in no other tenant) or **owned by the caller under a box-owner
       lock** (`BoxLock.IsOwner(hum)`).
   - For every other `audit.read` caller (e.g. a customer workspace viewing a
     shared fleet box, or a `product_owner`), the hub strips `top_dirs`,
     `top_dirs_at`, `top_dirs_partial`, `top_dirs_unvisited`,
     `top_dirs_unreadable` from the response and sets `details_redacted: true`.
     Neither host directory layouts nor non-home paths ever cross a workspace
     boundary.

### 8.8 Tests (with red controls) and build rows

Every test lands with its build row and ships with its red control
(`developer-guide.md` 2.12.1: seen RED on the planted defect, then GREEN, both
outputs in the commit body). Store/migration rows run `PRE_PUSH_TIER=full`
(real Postgres + RLS tests, `developer-guide.md` 2.6.4, 2.12.4). Row **T17** is
a live dev verification and measurement row (like section 7's T8), not a code
gate, so it has no red control; its commit body carries the measured numbers.

#### 8.8.1 Tests and red controls

| test | where | proves | red control |
|---|---|---|---|
| store + PG RLS (T10) | `internal/store/box_stats_test.go`, `rls_test.go`, `rls_failclosed_test.go` | new `box_stats` scalar cols + `box_snapshots` upsert/list/prune on Memory and Postgres; `TestRLSCoversEveryTenantTable` covers `box_snapshots`; a statement without a tenant reads 0 rows; `CheckBoxSnapshot` rejects > 10 dirs, `..` paths, > 16 KiB | drop the `box_snapshots` RLS policy or `..` path check: the test fails |
| `htop` header + `df` collector (T11) | `internal/hubclient/box_sample_test.go` | two-pass `/proc/stat` fixture yields exact total + per-core CPU % and user/sys/iowait; `/proc/meminfo` yields buffers/cached/swap_total; `/proc/loadavg` + `/proc/uptime` yield tasks/threads/uptime; `df` rule includes an agent-root `tmpfs` while excluding `/run` `tmpfs` and container `overlay` | drop the agent-root `st_dev` check (so `/tmp` `tmpfs` is dropped) or break `/proc/stat` delta: the test fails |
| Go `du` walker + coverage + redaction + parity (T12a) | `internal/hubclient/box_du_test.go` + `csi-spl-orc/src/bash/tests/box-du-parity.tst.sh` | fixture tree sizes match real GNU `du -kx` (allocated blocks, hardlink dedup, symlinks not followed, `-x` boundary); depth-2 top-10 ordering; prior-largest-first + cursor round-robin order; a bucket hitting its 5 s cap stops with `partial: true`; when total cap ends with buckets unvisited, **`top_dirs_partial: true` and `top_dirs_unvisited > 0`**; unreadable dirs counted in `top_dirs_unreadable` without aborting; `/home/<user>` and `<data>/home/<user>` rewrite to `uid-<n>` before JSON encode; `--force` bypasses `--max-age`, waits on `du.lock` and reuses a file written during the wait | (1) remove hardlink dedup: parity fails; (2) remove `/home/<user>` redaction: privacy assertion fails; (3) drop the unvisited-bucket `top_dirs_partial = true` check: coverage test fails |
| cron order + cache + fallback (T12b) | `csi-spl-orc/src/bash/tests/box-stats-cron.tst.sh` | `do_post_box_stats` posts the sample BEFORE invoking `du-cache`; skips `du` scan while cache is `< BOX_DU_EVERY_S` or `du.lock` is held; strips v2 fields and retries cleanly when a stub legacy hub refuses unknown fields | run `du-cache` before `box-stats put`: ordering assertion fails |
| hub snapshot + v2 `recent` + privacy gate (T13) | `internal/hub/box_stats_test.go`, `box_refresh_test.go` | `box_stats_put` and `box_sample_put` store scalars + upsert `box_snapshots` in one tx (`at` identical, future `top_dirs_at` clamped `<= at`); v2 `recent` asks a box whose `row.At < 60 s` but `top_dirs_at > 60 s`, and skips it only when both are `< 60 s`; write-time strip omits `top_dirs` when storing a shared box under a non-operator tenant; `GET /v1/tenant/box-stats` returns `snapshots`; `POST /refresh` returns `boxes[].snapshot`; `lockViewFor` hides locked boxes' snapshots; non-operator admin on a shared box gets `details_redacted: true` with `top_dirs` stripped, while operator admin and dedicated-box admin see them | (1) bypass the operator/shared-box write or read redaction gate: customer-admin test sees `top_dirs` and fails; (2) check `row.At` alone for v2 `recent`: stale-`du` refresh test fails |
| box handler v2 + fresh `du` on Refresh (T14) | `internal/hubclient/box_sample_test.go` | `spool hub-run` advertises `FeatureBoxLiveV2`; on `box_sample` frame it collects `htop` + `df` FIRST, then runs fresh `du-cache --force` (under `nice`/`ionice` + `du.lock`, bounded by 30 s cap) and sends scalars + fresh `top_dirs` + `top_dirs_at` in `box_sample_put`; reuses freshly written `top-dirs.json` when waiting on an in-flight cron scan; ignores duplicate `box_sample` for same `req` across a socket roll and sends `box_sample_put` on the active socket; enforces 1 in-flight and `SPOOL_BOX_SAMPLE_MIN_S = 60 s` guard; missing/corrupt `top-dirs.json` still sends `htop` + `df` with `top_dirs: []` | serve cached `top-dirs.json` without running `du-cache --force`, or run `du` before `htop`: freshness / ordering assertion fails |
| WUI summary + refresh (T15) | `csi-spl-wui/tests/unit/box-summary.test.mjs`, `tests/e2e/box-summary-table.test.mjs`, `tests/e2e/box-refresh.test.mjs` | summary table shows actual CPU %, Load 1/5/15, RAM `used / total (%)`, Swap `used / total`, fullest mount `used / size (%)`, snapshot time + age, Refresh button (only with `tenant.settings`, disabled with active progress state while waiting up to 45 s); Refresh updates values in place and marks stale boxes; i18n gates + 375 px no sideways scroll | read RAM/load from 24-hour `detail.system` or drop stale branch: test fails |
| WUI `BoxLiveSnapshot` (T16a) | `csi-spl-wui/tests/unit/box-resources.test.mjs`, `tests/e2e/box-live-snapshot.test.mjs` | renders `htop` header + per-core bars, full per-mount `df -P` table (`Mount`, `Type`, `Used`, `Size`, `Avail`, `Use%`), top-10 `du` table with its own `top_dirs_at`, `partial` badge, unreadable note, and redacted notice when `details_redacted`; i18n gates + 375 px no sideways scroll | omit `Used` size column or ignore `details_redacted`: test fails |
| WUI configured demotion & stale removal (T16b) | `csi-spl-wui/tests/e2e/box-live-snapshot.test.mjs`, `tests/unit/monitoring-allocation.test.mjs` | live snapshot and `BoxSummaryTable` appear ABOVE `MonitoringAllocation` on `index.vue`; `MonitoringAllocation` sits below inside collapsed `Configured (planned)` `<details>`; `MonitoringBoxFacts` / `BoxStatsPane` no longer render stale 24-hour `mem_avail_mb`, `swapLine`, or `sys.load`; i18n gates | leave `MonitoringAllocation` at line 29 above `BoxSummaryTable`, or leave `sys.load` in `MonitoringBoxFacts`: DOM order / stale-value check fails |

#### 8.8.2 Build rows (dependency-ordered, smallest first)

Rows **T1** (`38da97302`), **T2** (`8604ad411`), **T4** (`2af5387bf`) and **T9**
(`0674db0a5`) from section 7.9 are already on `origin/master` (`16fbe330e`).
The remaining section-7 rows (**T3, T5, T6**) stay prerequisites below; section
7's **T7** and **T8** are absorbed into **T15** and **T17** so the WUI and live
dev measurement are built once. **T17** is a measurement/verification row with
no red control. Top-process tables (former optional row T18) are dropped per
owner decision D2 = N.

| row | builds | test (8.8.1 / 7.8) | needs |
|---|---|---|---|
| T3 *(§7)* | box `box_sample` handler in `readLoop`, 60 s guard (`SPOOL_BOX_SAMPLE_MIN_S`) + 1 in-flight, `FeatureBoxSample` in hello (`internal/hubclient`) | 7.8 box handler (frames, guard, hung df) | T1, T2 *(done)* |
| T5 *(§7)* | hub pending map, `box_sample` frame send, hello catch-up, `box_sample_put` accept (`internal/hub`) | 7.8 two-instance delivery | T1, T4 *(done)* |
| T6 *(§7, updated for D1 = B)* | `POST /v1/tenant/box-stats/refresh`, `tenant.settings`, limits (`SPOOL_HUB_BOX_REFRESH_WAIT=45s`, `_MIN_S=60`, `_PER_H=12`), `ViewBoxes` asked set, wait, cnf + tpl-gen | 7.8 refresh contract, silent box, never-sampled box, limits | T5 |
| T10 | migration `<NNNN>_box_live_snapshot.sql` (`box_stats` scalar cols + `box_snapshots` with RLS), Go store types, `CheckBoxSnapshot`, Memory + Postgres store | store + PG RLS (`PRE_PUSH_TIER=full`) | — |
| T11 | Go `htop` header + `df` agent-root collector (`BoxSampler` 250 ms `/proc/stat` + `meminfo`/`uptime`/`loadavg` + `df` `st_dev` exception), `FeatureBoxLiveV2` | `htop` header + `df` collector | T2 *(done)*, T10 |
| T12a | Go time-capped `du` walker (`box_du.go`), prior-largest + cursor order, `top_dirs_partial` on capped/unvisited, `uid-<n>` home redaction, `spool box-stats du-cache` (`--max-age`, `--force`, `--lock`, `--lock-nonblock`) / `sample` | Go `du` walker + coverage + redaction + parity | T11 |
| T12b | Bash `do_post_box_stats`: sample/put first, then throttled `du-cache` (`--lock-nonblock --max-age 15m`, `nice -n 19 ionice -c 3`), legacy hub fallback strip | cron order + cache + fallback | T12a |
| T13 | hub `box_stats_put` / `box_sample_put` snapshot upsert + write-time shared-box strip, v2 `recent` check (`row.At` + `top_dirs_at`), `GET /v1/tenant/box-stats` `snapshots`, `POST /refresh` `boxes[].snapshot`, `lockViewFor` + read-time privacy gate | hub snapshot + v2 `recent` + privacy gate | T6, T10 |
| T14 | box `spool hub-run` v2 handler: `FeatureBoxLiveV2`, collects `htop` + `df` first then runs fresh `nice -n 19 ionice -c 3 spool box-stats du-cache --force` (30 s cap, `du.lock` wait/reuse), `SPOOL_BOX_SAMPLE_MIN_S=60`, socket-roll safe | box handler v2 + fresh `du` on Refresh | T3, T11, T12a, T13 *(hub deploys first)* |
| T15 *(absorbs §7 T7)* | WUI client `refreshBoxStats`, snapshot helpers (`box-resources.mjs`, `box-summary.mjs`), `BoxRefreshButton.vue` (with in-progress state up to 45 s), upgraded `BoxSummaryTable.vue` (CPU %, Load, RAM, Swap, Fullest disk, Snapshot time, State), i18n + GCT | WUI summary + refresh + i18n gates | T9 *(done)*, T13 |
| T16a | WUI `BoxLiveSnapshot.vue` (`htop` header + per-core bars, full `df -P` mount table, top-10 `du` with `top_dirs_at`/partial/unreadable/redacted) wired into `index.vue` & `[id].vue`, i18n + GCT | WUI `BoxLiveSnapshot` + i18n gates | T15 |
| T16b | Remove 24-hour volatile duplicates (`mem_avail_mb`, `swap`, `load`) from `MonitoringBoxFacts.vue` & `BoxStatsPane.vue`, label daily facts as static daily facts, demote `MonitoringAllocation.vue` below live boxes as collapsed `Configured (planned)`, i18n + GCT | WUI configured demotion & stale removal + i18n gates | T16a |
| T17 *(absorbs §7 T8)* | Monitoring > Boxes help text; on dev with T14 boxes + T16b WUI live: 10 timed Refresh clicks (proving click-to-render inside 30–60 s / hub wait `<= 45 s` and `top_dirs_at` advancing on every Refresh), live parity check against `df -P`, `htop` and `du`, and shared-box privacy verification | measurement & live proof in commit body (no red control: n, min, max, shas, binary versions) | T14 on dev boxes, T16b deployed |

T10 has no prerequisite and can land in parallel with T3, T5 and T6.

### 8.9 Where this extends or changes section 7

1. **Refresh budget, `du` freshness & guards (7.3, 7.5, 7.6.5)**: per owner
   decision D1 = B (`cd8860d7`), Refresh runs a fresh time-capped `du` scan
   after `htop` + `df -P`; `SPOOL_HUB_BOX_REFRESH_WAIT` rises from `7 s` to
   `45 s` (click-to-render `<= 47 s`, inside the owner's 30–60 s allowance),
   `SPOOL_BOX_SAMPLE_MIN_S` rises from `30 s` to `60 s` (plus 1 in-flight per
   box), and v2 `recent` checks both `row.At` and `snapshot.TopDirsAt` so a
   recent 5-minute cron tick carrying cached `du` does not suppress an explicit
   Refresh click.
2. **Mount filter (7.2, 7.6.3)**: adds the agent-root `st_dev` exception for
   `tmpfs`/`overlay` (including dedicated `>= 1 GiB` `/tmp`) and optional
   `fstype`, while preserving `df -P` `Use%` arithmetic.
3. **Sample payload & collector (7.6.1, 7.6.3)**: extends `BoxSampler.Collect`
   with the 250 ms `/proc` `htop` header; Refresh invokes fresh `du-cache --force`
   (under `nice -n 19 ionice -c 3` + `du.lock`) while the 300 s cron reads the
   cached `top-dirs.json` first and refreshes it at most every 15 min after;
   adds `FeatureBoxLiveV2`; retires the bash `awk` collector on
   `do_post_box_stats` in favour of `spool box-stats sample` (keeping a
   fallback strip for older hubs).
4. **Database & retention (7.6.5, 7.7)**: section 7 needed no migration;
   section 8 adds one forward-only migration (`box_stats` scalar columns +
   1-row-per-box `box_snapshots` with RLS), keeping 30-day history lean.
5. **Page layout (7.4, 7.4.1)**: promotes live actual box data above configured
   `(planned)` allocation, adds per-mount `df -P` and top-10 `du` tables plus
   `htop` header, shows an active progress state during the up-to-45 s Refresh
   scan, and removes 24-hour volatile duplicates from daily facts.
6. **Out of scope (7.10)**: CPU % (total and per core) moves into scope per the
   owner's `htop` ask; per-process tables (top CPU / top RSS) stay **out of
   scope** per owner decision D2 = N (`cd8860d7`), alongside periodic
   auto-refresh, threshold alerts and daily host facts refresh.
7. **Build rows (7.9)**: keeps unbuilt T3, T5, T6 as prerequisites (updating
   T3/T6 defaults for D1 = B) and absorbs T7 and T8 into T15 and T17.

### 8.10 Resolved owner decisions (poll `1a89fe8b`, msg `cd8860d7`)

Both open decisions from v0.5 were answered by the owner (HUM-10, t1 topic
`78f0138c-1877-4538-9d9b-f4b455ca7062`, msg `cd8860d7-147b-4e32-9093-cb30986b762f`)
and folded throughout section 8:

1. **D1 — `du` freshness on Refresh**: **Resolved = B**
   > *"Answer 1: B — Measured again when I press Refresh, even if it takes 30-60 s"*
   - Refresh measures `htop` header + `df -P` first (~0.26 s), then runs a
     fresh time-capped `du` scan (`BOX_DU_TIMEOUT_S = 30 s`,
     `BOX_DU_BUCKET_TIMEOUT_S = 5 s`, under `nice -n 19 ionice -c 3` + `du.lock`)
     and returns all three together. Hub wait cap is `45 s` (click-to-render
     `<= 47 s`, inside 30–60 s), `SPOOL_BOX_SAMPLE_MIN_S = 60 s` + 1 in-flight,
     and v2 `recent` requires both `row.At` and `snapshot.TopDirsAt` `< 60 s`.
     The 300 s background cron continues to post `htop` + `df` + cached
     `top-dirs.json` first and refresh `top-dirs.json` at most every 15 min after.
2. **D2 — Top processes in the `htop` view**: **Resolved = N**
   > *"Answer 2: N — No, htop header values only: CPU, load, memory, swap, uptime (Recommended: what you asked)"*
   - Dropped completely: no process collection, no `top_cpu`/`top_mem` wire or
     store fields, no process tables in WUI, and no row T18.

<!-- version: 0.6.0 · updated: 2026-11-23 -->
