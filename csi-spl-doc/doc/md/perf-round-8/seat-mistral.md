# Perf round 8: seat mistral (m-176)

- Seat: m-176 (this box), mistral, panel seat of rulebook 3.2 (doc review only; no code
  review, owner 10-30 cf7a7ee5). Lane issue SPL-5468, round issue SPL-5456,
  epic SPL-2402, spec csi-spl-doc/specs/027-spool-performance, topic
  720c27be-44e6-4a3f-98f7-61f0bad0bf0c (context only, not posted in).
- Plan under review: `review/c001-perf-round-8-planner`.
  - `git fetch origin review/c001-perf-round-8-planner && git rev-parse FETCH_HEAD`
    printed `29030f9058b1ac927b50404dd9580747aef4b79f` (the editor moved the
    branch past the brief's `df5c90a74`; c-101's note on `dispatch-perf-r8`,
    msg fd6a39b2, names 29030f905 as the sha to sign).
  - `git diff df5c90a74 29030f905 --stat` -> `csi-spl-doc/doc/md/perf-round-8-plan.md | 4 ++--`,
    1 file changed, 2 insertions(+), 2 deletions(-): only section 6 items 4/5
    wording (the r34-brief claim and its check on this box). All measurements and all
    row sites are identical between the two shas, so every check below was run
    against the df5c90a74 plan text and applies unchanged to 29030f905.

## Verdict: PASS on 29030f9058b1ac927b50404dd9580747aef4b79f

(base df5c90a743e41d274b1fb100bb5d2a43d7af480f reviewed line by line; the
29030f905 delta verified to touch only section 6 items 4/5.)

## Checks (each with the command run and what it printed)

### 1. Slug p8 unused

- `git log origin/master --oneline -E --grep='\((p8-' | wc -l` -> `0`
- `git ls-remote origin 'refs/heads/*p8-*' | wc -l` -> `0` (no output lines)

### 2. Row sites exist at f67ead04e and on origin/master; drift

All 38 cited file:line refs of rows 01-04 (5 files of row 01:
`csi-spl-orc/src/bash/run/spl-watchdog.func.sh:80,94,1105`,
`spl-gc.func.sh:75,85`, `spl-agent-login2-sync.func.sh:36,39`,
`spl-box-leave.func.sh:39,44,208`, `spl-rotate-lib.func.sh:50,60,609,613`,
test `run-eager-files.tst.sh:61,69`; row 02:
`csi-spl-orc/lib/bash/funcs/spl-box-workspace.func.sh:27,36`, test
`box-workspace-isolation.tst.sh:1`; row 03: `.github/workflows/10_ci-quality.yml:1708,1717,1735,1737,1743,1769,1787`,
test `csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh:1`; row 04:
`csi-spl-orc/src/bash/run/spl-lane-map.func.sh:308,317,322,344,677,686,690,701,704,711`,
test `lane-map.tst.sh:1`) were each read with
`git show <sha>:<file> | sed -n <N>p` at both `f67ead04e` and `origin/master`:
36 lines non-empty and matching the plan's description (e.g.
`spl-lane-map.func.sh:308` -> `spl_lane_repo_tops() {`, `:322` ->
`spl_lane_local_rows() {`, `:677` -> `spl_lane_wt_dir() {  # ID REPO`,
`:690` -> `spl_lane_wt_changes() {  # WT`, `:704` -> `spl_lane_wt_scan() {  # ROWS`,
wf10 `:1717` -> the `grep -rnIoP "${excl[@]}"` line, `:1737/:1743/:1769/:1787`
-> `sweep ...` calls, `spl-box-workspace.func.sh:27` -> `spl_box_ws_cnf() {`);
the two range-end lines `:686` and `:701` are the blank lines after the closing
`}` at `:685`/`:700` at both shas. Result: `f67ead04e: ok=36 missing=0 (+2
blank range-end lines present)`, `origin/master: ok=36 missing=0`.
Drift: `git diff --stat f67ead04e origin/master -- <the 12 site files>` prints
nothing -> no site file drifted between the measured sha and current
origin/master.
Section 6 spot-checks on origin/master: `git show
origin/master:csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go
| grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'"` -> 3 hits
`:84`, `:119`, `:152`; `wc -l` -> 227;
`git show origin/master:csi-spl-api/src/bash/tests/go-coverage-floor.txt |
sed -n 134p` -> `internal/payments 84.3`;
`git show origin/master:csi-spl-api/src/bash/hub-live-stack.sh | sed -n 53,54p`
-> the `pg_ctl ... -o "-k ..."` lines. The 29030f905 claim
`grep -c fallback_postgres /var/spool-hub/dispatch/briefs/c002-refactor-round-34-planner.md`
-> `0` (rc=1), as the plan states.

### 3. Row structure (rulebook 3.1, 4.1, R1, R14, owner 10-17)

Read from the plan table at df5c90a74 (= 29030f905 for rows):
- 4 rows, at most 10 (1.1). Each row names at most 5 site files (row 01: 5
  files; rows 02-04: 1 each) plus its test file.
- Each row has a baseline with command + number + n on f67ead04e: 01 `211 ms
  median n=7` (phase5 eager loop) + `0.421 s` whole start n=5; 02 `0.081 s
  median n=5`; 03 `4,443 ms median n=5` (hyprobe arm A) + hygiene part `13 s
  median n=147`; 04 `1,506 ms median n=5` (wtscan arm A) + whole `--check`
  `8.1..15.1 s n=3`.
- Each row names a counting/timing test with a red control (4.1, C2): 01
  `run-eager-files.tst.sh` (CONTROL at `:61-69`, verified) with `MAX_EAGER`
  93 -> 88; 02 `box-workspace-isolation.tst.sh` with a `yq` PATH shim counting
  `eval-all` calls (0 after, 1 today = RED); 03 `check-dist-hygiene.tst.sh` with
  a `grep` PATH shim counting recursive calls (at most 1 after, 6 today = RED);
  04 `lane-map.tst.sh` with a `git` PATH shim counting `rev-parse
  --git-common-dir` (at most 2 per scan after, 24 today = RED).
- Each row carries vendor / kind / batch: all `claude / simple_coding`, batch 1
  (rows 01-03) or batch 2 (row 04). No mistral coding or testing row (owner
  10-17); R14 satisfied (established vendor).
- Batches disjoint (R1): plan section 3.1 lists the disjoint file sets; row 01's
  `spl-gc.func.sh:82` sources `spl-lane-map.func.sh` but does not edit it; row
  04 (batch 2) is the only row touching `spl-lane-map.func.sh`.
- Row 03's drop rule is stated: re-measure arms A/B n=10 interleaved, under 15%
  median gain the row is dropped with that measurement (4.1's drop rule).

### 4. Re-measure of p8-02 (cheapest row), n=7, read-only

Probe (yq v4.43.1, in `csi-spl-cnf/csi-spl` of this worktree at cb23af0cc;
`all.env.yaml` 103,490 B, `prd.env.yaml` 27,318 B; load 32.8 beside every run):
arm A `yq eval-all -r '. as $i ireduce ({}; . * $i) | .env.box.workspace_base //
""' all.env.yaml prd.env.yaml`; arm B two plain `yq -r` reads (prd then all).
Interleaved n=7, timed with `EPOCHREALTIME`:

- merge samples `0.062 0.054 0.056 0.053 0.069 0.077 0.061` -> median **0.061 s**
- two reads samples `0.011 0.022 0.013 0.011 0.013 0.012 0.010` -> median
  **0.012 s** (-80%)
- values: merge -> `/var/spool-ws`; prd read -> `""`; all read ->
  `/var/spool-ws` (prd.env.yaml does not set the key, so the fallback is the
  merge's value: the row's premise holds)

Editor's numbers on f67ead04e (load 31.8, n=5): merge **0.081 s**
(0.071..0.089), two reads **0.017 s** (0.013..0.023), -79%. **My number agrees**
(same direction, same magnitude, -80% vs -79%).

### 5. R3 lane-map check on the rows' paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check <the 12 row site files, comma-separated> --agent m-176` ->
**exit 4**, stdout:

```text
unknown: c-567@sat c-567-c002-spl5259-issue-follows-discussion has no files recorded; ask it or read its brief
unknown: c-664@sat c-664-rotate has no files recorded; ask it or read its brief
unknown: c-687@sat c-687-c002-feat-calendar-owner-fi-nl-first-end-jan has no files recorded; ask it or read its brief
unknown: c-688@sat c-688-c002-feat-codex-in-every-ai-client-setting-9130912f has no files recorded; ask it or read its brief
```

No `owned by` line: no live lane owns a row path. Exit 4 = the 4 unknown lanes
must be asked first, never treated as free; the plan's section 3.2 states
exactly that and names c-664 (`rotate`) as the one to ask first for row 01's
`spl-rotate-lib.func.sh`. (The plan's 19:10Z reading listed 5 unknown lanes;
c-661 has since finished, 4 remain.)
Row 04's Batch 2 wait: stated in the row's batch cell and section 3.1 (spawn
within 30 min, R16, of the commit landing `perf(p7-02-orc-lane-map-local-rows-one-jq)`,
which owns `spl-lane-map.func.sh:322-344`; p7-02 itself waits on r58-07).
Verified now: `git log origin/master --oneline -E --grep='\((p7-02'` -> 0 lines
and `--grep='\((r58-07'` -> no output, so both are still unlanded and the wait
is still required; the R16 SLA is stated. Enough.

### 6. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> exit 0, ends
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-176` (all sweeps `ok`, the 3 `allowed` lines are the
owner-approved cnf keys).

## Defects

None. W1..: none.

## Notes

- N1: the review branch moved between the brief and this review: FETCH_HEAD is
  29030f905, not df5c90a74. The delta is only section 6 items 4/5 wording
  (`git diff df5c90a74 29030f905 --stat` -> 1 file, 2 +-, shown above); the
  verdict covers 29030f905, the sha c-101 named.
- N2: `prd.env.yaml` is 27,318 B on current origin/master vs 27,047 B at the
  editor's f67ead04e measurement; the key read (`env.box.workspace_base`) is
  unset in both, and my re-measure (check 4) still agrees with the plan's
  numbers.
- N3: rulebook 3.1 says "file:line sites (at most 5)"; row 01 names 5 files
  carrying 11 file:line refs. Read as site files (the p7-04 precedent, "five
  eager files"), the limit holds; read as individual lines it would not. The
  plan's own table lists files, so I count files.
- N4: the plan's "why now" quoted `perf 3 refactor 139 perf-share 2.1% under-20`
  on f67ead04e at 18:21Z; re-running the 4.4 command now prints `perf 3 refactor
  137 perf-share 2.1% under-20` on both f67ead04e and origin/master, because
  the 14-day window is relative to now. Same verdict (`under-20`), the count
  moved with the window, not with a land.
- N5: spot-check of the editor's frequency claims: `grep -c 'running function'
  /var/csi/csi-spl/csi-spl-orc/dat/log/bash/csi-spl-orc.20261112.log` -> 16266,
  matching the plan's 16,266 orc runs on 2026-11-12. The 3,138 desk-cnf action
  count was not re-counted (same log, different pattern; not one of the brief's
  checks).
- N6: not re-run (outside the brief's checks 1-6): the row 01/03/04 probe numbers
  (phase5, hyprobe, wtscan arms), the `do_spl_hub_agent_kinds` reading in plan
  section 5, and the spawn-queue reading in section 3.2.

## Sign

`panel: m-176 mistral PASS 29030f9058b1ac927b50404dd9580747aef4b79f`
