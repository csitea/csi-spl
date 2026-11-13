# Perf round 8: editor seat (c-101, claude)

The raw commands and outputs behind [perf-round-8-plan.md](../perf-round-8-plan.md).

## 1. Seat

- Editor (planner): c-101 on the second fleet box, claude, issue SPL-5456, discussion `720c27be`.
- Every number was measured on **`f67ead04e`** (`f67ead04e1477b2e207447880f833e51d3627c9f`,
  `origin/master` at 18:21Z), on this box, 2026-11-13 18:2xZ-18:3xZ; the 1-minute
  load is printed beside each run. Each before/after pair ran interleaved or back
  to back under the same load.
- The row sites are unchanged on `origin/master` `c3083e6ca` (19:1xZ):
  `git diff --stat f67ead04e c3083e6ca -- <every site file of rows 01-04, and the
  two files of the dead ask's items 4 and 5>` prints nothing.

## 2. Measurements

### 2.1 Row 01: the next five eager orc files (n=7 per arm, interleaved)

`phase.sh` (the p7 editor's probe, [perf-round-7/editor.md](../perf-round-7/editor.md)
2.3) with one `EPOCHREALTIME` pair per sourced file, orc, n=5, load 17.9:
`awk_ms` 97, 107, 92, 82, 94; `eval_ms` 40, 29, 27, 25, 28; `eager_ms` 240, 185,
219, 197, 305; `eager_n` 93.

The costliest eager files (median ms of n=5, then the samples):

| file | median | samples |
|---|---|---|
| `spl-watchdog.func.sh` | 36 | 43, 34, 33, 36, 56 |
| `spl-gc.func.sh` | 21 | 21, 16, 22, 18, 36 |
| `spl-agent-login2-sync.func.sh` | 12 | 14, 11, 12, 11, 15 |
| `spl-box-leave.func.sh` | 12 | 12, 10, 11, 13, 12 |
| `spl-rotate-lib.func.sh` | 9 | 12, 8, 9, 9, 11 |
| `spl-dispatch-lease.func.sh` | 7 | 15, 6, 7, 5, 19 |

Sum of the 93 medians: 154 ms.

`phase5.sh`: the eager loop alone; arm B skips the five files above
(`SKIP5=1`), n=7 interleaved, load 21.8:

| arm | eager_ms | median |
|---|---|---|
| A (today, 93 files) | 342, 256, 192, 235, 195, 158, 211 | **211** |
| B (88 files) | 208, 154, 160, 172, 117, 139, 143 | **154** |

The whole start, `./run -a do_p8_no_such_action` (loads everything, then refuses),
`time` wall / user / sys in s, n=5, load 19.7: `0.440 0.272 0.097`,
`0.417 0.281 0.091`, `0.421 0.276 0.074`, `0.473 0.269 0.087`,
`0.408 0.261 0.103` -> wall median **0.421 s**.

What runs at their top level (`awk` over lines outside a function body):

- `spl-watchdog`: `:80-92` seven guarded `source` lines (`spool-env.inc.sh`,
  `spl-rotate-lib`, `spl-wd-ensure`, `spl-wd-peers`, `spl-agent-login-check`,
  `spl-wd-self-update`, `spl-wd-orch-outcome`), `:94` `SPL_WD_RUN_DIR="$(cd ... && pwd)"`,
  `:1105` `WD_ORDER=...`
- `spl-gc`: `:75-82` four guarded `source` lines (`spl-rotate-lib`, `proc-owner.inc.sh`,
  `start-check.inc.sh`, `spl-lane-map`), `:84` `SPL_GC_RUN_DIR="$(cd ... && pwd)"`,
  `:85` `SPL_GC_KNOBS=...`
- `spl-agent-login2-sync`: `:36` `source spool-env.inc.sh` (with `readlink -f`),
  `:39` `L2_FILES=(...)`
- `spl-box-leave`: `:39-44` three guarded `source` lines; `:208` `spl_box_handover() (`
  is a function with a subshell body, which this `awk` reads as top-level code
  (whether the run.sh index does too is for the lane to check)
- `spl-rotate-lib`: `:50-60` four guarded `source` lines,
  `:55` `SPL_ROTATE_LIB_DIR="$(cd ... && pwd)"`, `:609` and `:613` two arrays

How often orc `./run` starts on this box: the `STOP ::: running function ::`
lines of `/var/csi/csi-spl/csi-spl-orc/dat/log/bash/csi-spl-orc.20261112.log`
(as the desk user): **16,266** on 2026-11-12; the top three `do_spl_lane_rotate`
2,235, `do_setup_reverse_tunnel` 1,440, `do_spl_box_link_watch` 1,437.

### 2.2 Row 02: `spl_box_ws_cnf` (n=5, interleaved)

`/var/tmp/c101-probe/yq.sh`, in `csi-spl-cnf/csi-spl` (`all.env.yaml` 103,490 B,
`prd.env.yaml` 27,047 B), yq v4.43.1, load 31.8:

```bash
yq eval-all -r '. as $i ireduce ({}; . * $i) | .env.box.workspace_base // ""' all.env.yaml prd.env.yaml
yq -r '.env.box.workspace_base // ""' prd.env.yaml; yq -r '.env.box.workspace_base // ""' all.env.yaml
```

- merge: `0.071, 0.073, 0.082, 0.081, 0.089` s -> median **0.081 s**
- two plain reads: `0.019, 0.017, 0.013, 0.023, 0.016` s -> median **0.017 s**

How often: the actions whose files call `do_spl_desk_cnf` (`git grep -l
'do_spl_desk_cnf\b' -- src/bash/run lib/bash/funcs`, tests left out: 60 actions),
counted in the same 2026-11-12 orc log: **3,138** runs (`do_spl_uplink_probe`
1,324, `do_spl_issue_close_landed` 864, `do_spl_dispatch_lease` 586,
`do_spl_desk_doctree` 124, `do_spl_zombie_topics` 96, `do_spl_lane_map` 83, four
others 61). Each reaches `spl_box_ws_guard` -> `spl_box_ws_claim` ->
`spl_box_ws_base` -> `spl_box_ws_cnf workspace_base` at least once (on an operator
box the claim is empty and the guard returns there).

### 2.3 Row 03: the hygiene sweep (n=5, interleaved)

Pre-push part times, `~/.cache/csi-spl/pre-push.log` of the desk user, PART
lines since 2026-11-12T18:00 (24 h): `hygiene` n=147, median **13 s**, p10 5,
p90 41, sum 2,752 s; `commit-links` n=147, median 9 s; `lint-trufflehog` n=134,
median 10 s; `iac-cross` n=113, median 6 s.

`./run -a do_check_dist_hygiene` (csi-spl-iac), `time`, n=3, load 24.2:
`5.826 5.140 0.622`, `6.629 5.350 1.021`, `6.891 5.644 0.983`. Trace
(`PS4` with `EPOCHREALTIME`): 6.78 s of 7.74 s in `sweep`, 6.17 s of it on the
`grep -rnIoP ... | cut | sort -u` line (`10_ci-quality.yml:1717`).

`/var/tmp/c101-probe/hyprobe.sh`: a tracked-file export of the tree (9,559 files);
arm A = the six fixed-pattern sweeps, each its own whole-tree `grep -rnIoP` (today);
arm B = one `grep -rlIP` with the six patterns joined as `(?:p1)|(?:p2)|...`,
then each sweep's `grep -nIoHP` over those files only; load 54.5:

| run | A ms | B ms | files kept | hits | same |
|---|---|---|---|---|---|
| 1 | 4986 | 3866 | 7 | 28 | yes |
| 2 | 4683 | 3283 | 7 | 28 | yes |
| 3 | 3654 | 3464 | 7 | 28 | yes |
| 4 | 4443 | 3978 | 7 | 28 | yes |
| 5 | 4119 | 3345 | 7 | 28 | yes |

Median A **4,443 ms**, B **3,464 ms** (-22%). The ranges overlap (A 3,654..4,986,
B 3,283..3,978): a small gain on a loaded box, so the row carries a drop rule.
The hidden-workspace sweep (`:1769`, its patterns come from a private overlay
under its own `LC_ALL`) was not in the probe.

### 2.4 Row 04: lane-map worktree scan (n=5, interleaved)

`lane-map.sh --check csi-spl-doc/doc/md/perf-round-8-plan.md --agent c-101`
(`/opt/csi/csi-spl-desk-cron`, at `f67ead04e`), `time`, n=3, load 20.3:
`15.138 7.839 6.187`, `8.100 3.712 3.325`, `9.649 3.686 3.263`.

Trace of `do_spl_lane_map --quiet` as the desk user (`PS4` with `FUNCNAME[0..2]`),
9.33 s traced: `spl_lane_local_row` 3.29 s (p7-02's site), `spl_lane_wt_changes`
2.53 s, `spl_lane_hub_read` 0.78 s, `spl_lane_repo_tops` (from `spl_lane_wt_dir`)
0.75 s, `spl_lane_clis_here` 0.34 s, `spl_lane_wt_scan` 0.23 s, `spl_lane_wt_dir`
0.23 s. `spl_lane_wt_changes` ran for 26 worktrees; `spl_lane_repo_tops` ran 52
times (twice per worktree, from `spl_lane_wt_dir`'s loop).

`/var/tmp/c101-probe/wtscan.sh` over those 26 worktrees, as the desk user, load 17.5:
arm A = per worktree, `repo_tops` twice then the three `git` reads in turn
(today's shape); arm B = `repo_tops` once, then the per-worktree reads 8 at a time
(`xargs -P 8`); outputs sorted and compared:

| run | A ms | B ms | same |
|---|---|---|---|
| 1 | 1595 | 259 | yes |
| 2 | 1506 | 244 | yes |
| 3 | 1417 | 240 | yes |
| 4 | 1447 | 253 | yes |
| 5 | 1539 | 296 | yes |

Median A **1,506 ms**, B **253 ms** (-83%).

### 2.5 Not a row: test Postgres `fsync=off` (n=1, arm A only)

The store suite (`go test -count=1 -timeout 40m ./internal/store/`) on
`hub-live-stack.sh`'s Postgres, arm A (`fsync` on) 18:22Z-18:32Z: `rc=1`,
`wall_s=600.8`, load 50.4; one FAIL, `TestHiddenUnreadBufferBudget` (6,577 shared
buffers, budget 6,000: load-sensitive, not the arm). Arm B never ran: the seat's
session ended at 18:41Z. No pair, no number.

### 2.6 The dead ask 94ae299e, items 4 and 5

- Item 4: `grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'"
  csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go` -> 3 lines,
  `:84`, `:119`, `:152`; `wc -l` -> 227.
- Item 5: `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover
  ./internal/payments/` -> `coverage: 84.3% of statements`;
  `grep -n payments csi-spl-api/src/bash/tests/go-coverage-floor.txt` -> `:134
  internal/payments 84.3`: 0.0 points of headroom (the floor rose from 72.4 since
  the p5 retro).

## 3. Readings for R3

See the plan, section 3.2.
