# Every frequent box cron line runs at most once at a time (SPL-4495)

On 2026-10-31 the satellite box came back after 2082 s of silence with load
467 / 605 / 583 on 16 cores. The cause was stacked copies of every-minute
cron jobs: 111 runs of `do_apply_gh_runner_cpu_budget`, 75 of
`do_spl_workspace_seat_alarm`, 25 of `do_post_box_stats` and 13 of
`do_spl_lane_rotate` (n=1, c-001@sat msg b00eda40). A job slower than its
period piles up, and each new copy makes the box slower still.

## 1. The rule

Every every-minute and every-few-minute line the installers write runs its
job through `csi-spl-orc/src/bash/scripts/cron-no-stack.sh`, on a lock file of
its own:

```
* * * * * <self-update prefix>VAR=v <orc>/src/bash/scripts/cron-no-stack.sh <logdir>/cron.lock <job> >> <logdir>/cron.out 2>&1 # <tag>
```

- The wrapper takes `flock -n` on the lock and writes the holder into it
  (`pid=<p> start=<epoch> job=<job>`). While an earlier run of the same line
  still holds it, the new start exits 0 at once and writes one line to the
  line's own log: `SKIP an earlier run of <holder job> (pid <p>) still holds
  <lock>`.
- A holder older than `CRON_NO_STACK_MAX_S` (default 1800 s) is stuck: each
  start writes `STUCK <job> held <n> s by pid <p> on <box> (max <m> s)` and
  exits 3, and the first such start sends one spool note to
  `CRON_NO_STACK_ALERT_TO` (default `orchestrator`, task `cron-no-stack`).
  The `<lock>.stuck` mark keeps it to one note per stuck holder; the next run
  that gets the lock clears it. Why: a SKIP line keeps the log fresh, so the
  cron heartbeat snitch (log age) would read a hung job as healthy. The
  wrapper kills nothing: the box owner decides about the stuck pid.
- The job runs with the lock's fd closed, so a daemon it leaves behind never
  holds the lock; the lock goes when the job returns.
- The installer writes the wrapper, so a re-install keeps it. Never add it by
  hand: run the installer.
- `spl_desk_cron_script` and `spl_peer_cron_script_of` skip the wrapper and
  its lock, so `check` actions and the spec 068 8.1 check still name the job.

The shared piece is `spl_cron_no_stack_pre` in
`csi-spl-orc/lib/bash/funcs/spl-desk-cron-lock.func.sh`.

## 2. The lines and their locks

| line (tag `# csi-spl:`) | schedule | installer | lock |
|---|---|---|---|
| `gh-runner-cpu-budget` | every minute | `do_setup_gh_runner_cpu_budget_cron` | `<logdir>/cron.lock` |
| `box-cron:<name>`, every scheduled row of `cnf/box-crons/box-crons.manifest` (lane-rotate, gc, token-burn, rel-*, ...) | per row | `do_install_box_crons` | `<state>/<log dir>/<name>.cron.lock` |
| `unanswered-sweep[-<env>]` (runs the seat alarm) | every `SWEEP_CRON_EVERY` min | `do_spl_unanswered_sweep_install_cron` | `<logdir>/cron[-<env>].lock` |
| `box-stats` | every 5 min | `do_setup_box_stats_cron` | `<logdir>/cron.lock` |
| `go-cache-prune` | every 5 min | `do_setup_go_cache_prune_cron` | `<logdir>/cron.lock` |
| `ci-overflow` | every 5 min | `do_setup_ci_overflow_cron` | `<logdir>/cron.lock` |
| `disk-headroom` | every 15 min | `do_check_disk_headroom_install_cron`, and the same line from `do_box_disk_guard_install` (csi-spl-utl) | `<logdir>/cron.lock` |
| `box-restart` | every 5 min | `do_spl_box_restart_install_cron` | `<logdir>/box-restart.lock` |
| `dispatch-heal` | every 2..30 min | `do_spl_dispatch_rotate_install_cron` | `<logdir>/heal.lock` |
| `spawn-remote` | every minute | `do_spl_spawn_remote_install_cron` | `<logdir>/cron.lock` |
| `delivery-probe-<env>` | every 10 min | `do_spl_workspace_delivery_probe_install_cron` | `<logdir>/cron-<env>.lock` |
| `peer-ensure`, `peer-restart`, `peer-distill` | 1 / 15 / 15 min | `do_spl_peer_crons` and the three `_install_cron` actions | `<logdir>/<name>.lock` |
| `wd-start`, `wd-ensure` | every minute | `do_spl_wd_ensure_install_cron` | `<logdir>/starter.lock`, `ensure.lock` |
| `agent-identity-reconcile` | every minute | `do_spl_agent_identity_install` | `<spool root>/agents/reconcile.cron.lock` |

Left as they were, because they already lock the whole line or cannot stack:

- `flock -n` in the line already: `spawn-place`, `accepted-close`,
  `desk-poll-ack`, `review-go`, `spawn-fill`, `security-round`, `box-update`,
  `cost-rollup`, `shadow-feed`.
- `desk-reconcile[-<env>]`: the tick takes its own non-blocking holder lock
  (`desk-reconcile-cron.sh`), and its checkout move waits on the checkout lock
  (`flock -w 300`) on purpose.
- `box-disk-sweep`: the sweep takes `BOX_SWEEP_LOCK` itself.
- Hourly and daily lines (`orch-rotate`, `dispatch-rotate`, `check-env-order`,
  `git-prune-merged`, `agent-id-reap`, `@reboot` lines).

## 3. Test

`csi-spl-orc/src/bash/tests/cron-no-stack.tst.sh`: a line
`do_install_box_crons` writes, run twice by `/bin/sh` over a fake 3 s job: the
second start exits at once with rc 0 and one SKIP line, the first finishes,
one job ran. The red control cuts the wrapper out of the same line and sees
two jobs at once. It also checks the exit code passes through, a daemon left
behind holds no lock, and a re-install keeps the lock.
