# Perf round 8: grok panel seat (g-168)

Verdict: **PASS** on `29030f9058b1ac927b50404dd9580747aef4b79f`.

Read 2026-11-13T21:20:43Z from this worktree (`g-168-c002-perf-round-8-grok-panel-seat`, HEAD `cd727cfc424b8a43ca52534791d6caab6b9bcabe`, clean). The brief named `df5c90a743e41d274b1fb100bb5d2a43d7af480f`. That commit is the parent of the tip that was fetched (`git merge-base --is-ancestor` -> `ANC_NAMED=0`). `git diff --stat df5c90a743e41d274b1fb100bb5d2a43d7af480f 29030f9058b1ac927b50404dd9580747aef4b79f` prints one file, `csi-spl-doc/doc/md/perf-round-8-plan.md`, 4 lines, 2 insertions, 2 deletions: section 6, items 4 and 5. Rows 01-04 are the same text on both commits. This verdict signs the tip.

Measured sha in the plan: `f67ead04e1477b2e207447880f833e51d3627c9f`. It is an ancestor of `origin/master` (`ANC_MEAS=0`). `origin/master` at this reading is `cd727cfc424b8a43ca52534791d6caab6b9bcabe`.

Defects: none.

## 1. Slug `p8` unused

```text
git log origin/master --oneline -E --grep='\(p8-' | wc -l
0
git ls-remote origin 'refs/heads/*p8-*' | wc -l
0
```

A control, `git log origin/master --oneline -E --grep='\(p7-01-' | wc -l`, prints `1`. The `p8` count is an empty log, not a grep that cannot see landed rows.

## 2. Sites exist at `f67ead04e` and on current `origin/master`

```text
git diff --stat f67ead04e1477b2e207447880f833e51d3627c9f origin/master -- \
  csi-spl-orc/src/bash/run/spl-watchdog.func.sh \
  csi-spl-orc/src/bash/run/spl-gc.func.sh \
  csi-spl-orc/src/bash/run/spl-agent-login2-sync.func.sh \
  csi-spl-orc/src/bash/run/spl-box-leave.func.sh \
  csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh \
  csi-spl-orc/lib/bash/funcs/spl-box-workspace.func.sh \
  .github/workflows/10_ci-quality.yml \
  csi-spl-orc/src/bash/run/spl-lane-map.func.sh \
  csi-spl-orc/src/bash/tests/run-eager-files.tst.sh \
  csi-spl-orc/src/bash/tests/box-workspace-isolation.tst.sh \
  csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh \
  csi-spl-orc/src/bash/tests/lane-map.tst.sh
```

Prints nothing (`SITE_DIFF_RC=0`). No site file drifted. Each named test file exists on `origin/master` (`git cat-file -e` -> `EXISTS` for all four).

Line readings below are `git show f67ead04e1477b2e207447880f833e51d3627c9f:<file> | nl -ba`. Because the diff is empty they are the lines on `origin/master` too.

- Row 02: `spl_box_ws_cnf` is lines 27-36. Line 35 is one `yq eval-all` of `all.env.yaml` and, when `ENV` is set, `$ENV.env.yaml`.
- Row 01's red control is `run-eager-files.tst.sh:61-69` (the comment is 61, the pass is 69). `MAX_EAGER=93` is line 20. `FIVE` on line 19 is the p7-04 five. The row adds a second list and moves 93 to 88. That matches the file.
- Row 04: `spl_lane_repo_tops` is 308-318, `spl_lane_local_rows` starts at 322, `spl_lane_wt_dir` is 677-685, `spl_lane_wt_changes` is 690-700, `spl_lane_wt_scan` is 704-711.
- Row 03: `sweep()` is 1708-1736. The `grep -rnIoP` is line 1717. The fixed-pattern `sweep` calls are 1737, 1738, 1740, 1742, 1743. The hidden-workspace call is 1769. The retired-relay call is 1787.

## 3. Row shape (rulebook 3.1, 4.1, R1, R14)

Four rows, under the cap of 10. Each baseline names a command or the editor probe, a number, and n. Each test names a red control. Every vendor is claude / simple_coding. No mistral coding or testing row. Row 03 states the drop rule: the lane re-measures arms A and B, n=10, interleaved, and drops the row under a 15% median gain. The editor's own ranges overlap (A 3,654..4,986 ms, B 3,283..3,978 ms, medians 4,443 and 3,464, n=5), so the drop rule matches the measurement.

Batch 1 is rows 01, 02, 03. The twelve paths in section 4 share no file: row 01 is the five `run/*.func.sh` plus `run-eager-files.tst.sh`; row 02 is `spl-box-workspace.func.sh` plus `box-workspace-isolation.tst.sh`; row 03 is `.github/workflows/10_ci-quality.yml` plus `check-dist-hygiene.tst.sh`. Row 01's `spl-gc.func.sh` sources `spl-lane-map.func.sh` and does not edit it (plan section 3.1). Batch 2 is row 04 alone, `spl-lane-map.func.sh` plus `lane-map.tst.sh`.

## 4. R3, and row 04's Batch 2 wait

```text
bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh \
  --check <the twelve paths in section 3, comma-separated> --agent g-168
```

Exit `LANE_RC=4`. Printed:

```text
unknown: c-567@sat c-567-c002-spl5259-issue-follows-discussion has no files recorded; ask it or read its brief
unknown: c-661@sat c-661-rotate has no files recorded; ask it or read its brief
unknown: c-664@sat c-664-rotate has no files recorded; ask it or read its brief
unknown: c-687@sat c-687-c002-feat-calendar-owner-fi-nl-first-end-jan has no files recorded; ask it or read its brief
unknown: c-688@sat c-688-c002-feat-codex-in-every-ai-client-setting-9130912f has no files recorded; ask it or read its brief
WARN no live lane lists <the twelve paths>, but 5 live lane(s) record no files: their scope is unknown, not free
FATAL Command 'do_spl_lane_map' failed at line 131 with status 4.
```

Zero `owned by` lines. Exit 4 is not free. The plan already says that, and that the spawn re-reads the map and asks a lane that is still unknown.

The Batch 2 wait is stated in the row 04 batch cell and in section 3.1: after `perf(p7-02-orc-lane-map-local-rows-one-jq)` lands, and p7-02 itself waits on r58-07. Both are still unlanded:

```text
git log origin/master --oneline -E --grep='\(p7-02-' | wc -l
0
git log origin/master --oneline -E --grep='\(r58-07-' | wc -l
0
```

p7-02's site is `spl_lane_local_rows` at line 322. Row 04's `spl_lane_repo_tops` range ends at 317, and its other three functions are at 677-711. The ranges do not overlap. The wait is still required, and it is enough for that file collision. No live lane lists `spl-lane-map.func.sh`.

## 5. Row 02 re-measured (n=7, interleaved, read only)

In `csi-spl-cnf/csi-spl`, yq v4.43.1, `all.env.yaml` 103,490 B, `prd.env.yaml` 27,318 B, load `13.35 12.33 11.46` before and after. The two commands are the editor's (editor.md section 2.2), timed with `EPOCHREALTIME` around each arm, merge then the two reads, seven times. No file was written.

```text
run 1 merge 0.063155 two 0.014403
run 2 merge 0.070251 two 0.011825
run 3 merge 0.065539 two 0.019416
run 4 merge 0.060278 two 0.013356
run 5 merge 0.052407 two 0.012633
run 6 merge 0.065460 two 0.013350
run 7 merge 0.072147 two 0.015506
```

Median of n=7: merge **0.065460 s**, two reads **0.013356 s**, **-79.6%**. Median of the first five (the editor's n): merge **0.063155 s**, two reads **0.013356 s**, **-78.9%**. The editor recorded 0.081 s vs 0.017 s, -79%, at load 31.8. The ratio agrees. The absolute times are lower on this lighter load, and `prd.env.yaml` is 271 B larger than the 27,047 B the editor recorded. `all.env.yaml` is the same size. yq is the same v4.43.1.

The key itself: `yq -r '.env.box | has("workspace_base")'` prints `false` on `prd.env.yaml` and `true` on `all.env.yaml` (types `!!null` and `!!str`). `cmp` of the merge output against the all-file read is `M_EQ_A=yes`; against the prd read `M_EQ_P=no` (14 bytes vs 1 byte, the newline). The plan's `has()` rule returns the all-file value when the env file does not have the key, which is this key's merge result. The timed two-read arm always reads both files, the upper bound the editor measured.

## 6. Hygiene

Worktree, which does not contain the plan (it is only on the review branch):

```text
cd /opt/csi/csi-spl-wt/g-168/csi-spl-iac && ./run -a do_check_dist_hygiene
```

`HYG_RC=0`. The Sweep step printed ok for every check, with the owner-approved cnf allowances (personal name 9 lines, OS user 4 lines, owner mail 6 lines).

The same Sweep body (`yq -r` of the distribution-hygiene Sweep step from `.github/workflows/10_ci-quality.yml`) was then run as the desk user, cwd a tree holding the tip's `perf-round-8-plan.md`, `perf-round-8/editor.md`, `csi-spl-cnf/csi-spl/all.env.yaml`, and `spl-private-cnf.func.sh`, so the hidden-workspace sweep ran too. `SWEEP_RC=0`. Every check ok. The allowed lines are the cnf keys in the copied `all.env.yaml` (personal name 3, owner mail 2). The plan and the editor file produced no hit.

## Notes

- **N1.** The signed sha is the fetched tip `29030f9058b1ac927b50404dd9580747aef4b79f`, not the brief's `df5c90a743e41d274b1fb100bb5d2a43d7af480f`. The only delta is section 6, items 4 and 5. That commit's subject records c-001's r34-brief claim and the check of the brief on this box. The subject also names this box. This file does not repeat that name: the hygiene sweep bans it in file content.
- **N2.** Rulebook line 190 says file:line sites (at most 5). Row 01 cites 5 files and 9 ranges. Row 03 cites 4 ranges in one file. Row 04 cites 4 ranges in one file. Row 02 cites 1 range. The landed p7 plan's row 04 (`perf-round-7-plan.md:80`) is the same shape: 5 files, and `gh-runner-add.func.sh` carries two ranges. This is not a fail.
- **N3.** Three cited ranges stop one line short of the closing line. `spl_lane_repo_tops`'s `}` is 318, the plan says 308-317. `sweep()`'s `}` is 1736, the plan says 1708-1735. The owner-mail `sweep` call's second argument is line 1744, one past the cited 1737-1743. `spl_lane_wt_dir` ends at 685 (the plan's 677-686 includes the blank) and `spl_lane_wt_changes` ends at 700 (690-701 includes the blank). The functions and the `grep` line are the right sites.
- **N4.** p7-02 and r58-07 are unlanded (section 4, both counts 0). The Batch 2 wait stays in force. The line ranges do not overlap.
- **N5.** Lane map exit 4, the same five unknown ids the plan recorded at 19:10Z, zero owners. One title moved: the plan's section 3.2 names c-661 as `feat-people-every-workspace-member-email`; this reading prints `c-661-rotate`. c-664 is still `rotate`. The plan already says exit 4 is not free and that the spawn asks again. Ask both rotate-titled seats before row 01, c-664 first as the plan says.
- **N6.** The row 02 number agrees in direction and in the percent (section 5). It is not the same samples. Load here was 13.35; the editor's was 31.8. `prd.env.yaml` grew by 271 B.
- **N7.** Rows 01, 03 and 04 name the editor's probe scripts for the baseline command, as the landed p7 plan does, and put the samples in `perf-round-8/editor.md`. The red controls are in the test cells.
