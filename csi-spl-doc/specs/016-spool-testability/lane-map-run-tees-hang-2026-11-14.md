# lane-map `--check` hung under `./run` (SPL-5519, 2026-11-14)

Regression from 75a38b791 (SPL-5500, perf p8-04). Fixed in the worktree scan;
`lane-map.sh --check` got an overall time limit as well.

## 1. Cause

`spl_lane_wt_scan` (`csi-spl-orc/src/bash/run/spl-lane-map.func.sh`) started
the worktree reads as background jobs, then called `wait -n` (to keep
`LANE_WT_JOBS` running) and a bare `wait`. Under `./run`, run.sh keeps two
`>(do_run_log_tee ...)` process substitutions open until the action exits.
In the main shell a bare `wait` also waits on those, so it never returned,
even with no job started. Inside `$(...)` (the map's `spl_lane_clean_here`)
the subshell does not wait on them, which is why a plain map still ended.
`spl_lane_check` calls the scan in the main shell, so every `--check` under
`./run` hung.

Measured on this tree (bash 5.2.37, n=1 each): the real
`LANE_CHECK=a/b ./run -a do_spl_lane_map --quiet` in local mode was killed by
`timeout 20` (exit 124) before the fix and answered `free` in 0.6 s after it.

The SPL-5500 tests passed because `lane-map.tst.sh` sources the functions
with no `./run`, so no tees were open; its review's re-measure ran the map,
the subshell path.

## 2. Fix

- The scan waits on its own workers' pids only: `wait -n -p <pid>` on the
  running pids to keep `LANE_WT_JOBS` going (bash 5.1+), then
  `wait <all pids>`. Chosen over a subshell around the loop because it states
  what is waited on, instead of depending on which children a subshell
  inherits.
- `lane-map.sh --check` runs the action under `timeout -k 5 LANE_CHECK_TIMEOUT`
  (default 60 s, whole seconds, else exit 64). When the limit is hit it prints
  `LOCAL-ONLY: lane-map --check did not finish in <n> s (LANE_CHECK_TIMEOUT);
  no lane was read: not free, ask c-001` and exits **5**. It has the same
  meaning as the hub-silent exit 5: not free, ask c-001. A plain map and
  `put` / `done` have no limit.

## 3. Test

`csi-spl-orc/src/bash/tests/lane-map-run-tees.tst.sh` runs the real `./run`
with its tees under `timeout 30`. It checks three local lanes read one at a
time (`LANE_WT_JOBS=1`): a changed path is exit 3, a free path is `free`.
It also gives `lane-map.sh` a stub action that sleeps (exit 5 within the
limit), one that answers (its own verdict), and a bad limit (exit 64).
RED on the old scan: both `./run --check` cases exit 124. RED on the old
`lane-map.sh`: the stalled check runs the stub's full 30 s.

## 4. The same pattern elsewhere in csi-spl-orc

A `wait` or `wait -n` with no pid outside the tests:
`features/run-ci-tests.sh:140,144` (CI calls it with plain `bash`, not under
`./run`) and `scripts/docker-init-{tf-runner,tpl-gen,conf-validator}.sh`
(container entrypoints that wait on `sleep infinity`). None runs inside a
`./run` action, so none hangs this way.
