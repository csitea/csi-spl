# Test round 1: claude seat verdict

Seat: **c-245@sat** (claude). Issue: SPL-2064 (seat lane), round issue SPL-2052.
Plan reviewed: `test-round-1-plan.md` v0.1 (9e3d04dd9).

**One sha:** every number below was measured in this session on
**`7a041f105`** (`origin/master`, 2026-10-16), unless a line names a CI run.
CI per-file wall times come from the `--- every file (wall s)` and
`--- slowest 10 test files (wall s, cpu s)` blocks that
`csi-spl-orc/src/bash/tests/run-all-tests.sh` prints in the two
`orc: hermetic action tests` jobs of three green master runs:
38819626552 (c1bb3d004), 38819244084 (e95587ea2), 38816173780. n=3, the
median is quoted.

Tally: **0 agree / 6 agree with changes / 6 disagree / 3 proposals.**

## 1. The finding that changes most rows: `orc-shard-weights.txt` is not a wall-time measurement of today

Rows 01, 02, 05, 06 and 09 quote their "number now" from
`csi-spl-orc/src/bash/tests/orc-shard-weights.txt`. That file is a packing
weight, last refreshed on 2026-10-12 from runs of 2026-10-11/12:

- `git log -1 --format='%h %ci' -- csi-spl-orc/src/bash/tests/orc-shard-weights.txt`
  -> `94cd17be3 2026-10-12 10:29:04 +0300`

Today's CI wall per file, median of n=3 runs (command: fetch each hermetic
job log with `gh api repos/csitea/csi-spl/actions/jobs/<job>/logs`, keep the
lines after `--- every file (wall s)`, median per file):

| file | weights.txt | CI wall, 3 runs | median | cpu s (2 runs) | idle share |
|---|---|---|---|---|---|
| `orch-rotate.tst.sh` | 222 | 361 428 426 | **426** | 41 55 | **~88 %** |
| `dispatch-rotate.tst.sh` | 263 | 245 278 249 | **249** | 46 65 | **~78 %** |
| `fleet-lease.tst.sh` | 580 | 161 236 244 | 236 | 90 134 | ~44 % |
| `desk-actions.tst.sh` | 366 | 119 225 236 | 225 | 84 141 | ~33 % |
| `parse-metadata-nofork.tst.sh` | 453 | 111 191 205 | 191 | 76 112 | ~36 % |
| `box-purge.tst.sh` | - | 113 197 190 | 190 | - | - |
| `wd-self-update.tst.sh` | - | 169 220 175 | 175 | 57 80 | ~65 % |
| `tmux-close-window.tst.sh` | 264 | 169 172 168 | 169 | 8 12 | **~94 %** |
| `cloud-actions.tst.sh` | 140 | 110 160 160 | 160 | 6 9 | **~94 %** |
| `peer-poll.tst.sh` | 518 | 126 214 138 | 138 | 107 167 | ~18 % |
| `spl-lane-mix.tst.sh` | 545 | 111 185 119 | 119 | 114 189 | **~0 %** |

Idle share = 1 - cpu/wall (both from the `slowest 10` block of runs
38819626552 and 38819244084). A test that is idle most of its wall time is
waiting on real-second timeouts and is cut by a clock seam; a test with
cpu ~= wall is CPU work and is NOT cut by "mock sleep".

Sum of the per-file medians over all 431 files: **8,070 s**; the five slowest
files sum to **1,327 s = 16 %**, not "2,462 s, >67 %" (section 1 of the plan).

## 2. The 12 rows

| # | row | command I ran (on 7a041f105 unless CI) | output | verdict |
|---|---|---|---|---|
| 01 | fleet-lease speed | CI wall, table in section 1 | 161 / 236 / 244 s, median 236 s; cpu 90 / 134 s | **agree with changes**: number now is 236 s, not 580 s; ~44 % idle, so the clock seam helps but < 60 s is only reachable by also cutting CPU; target < 120 s. Drop `orc-shard-weights.txt` from its sites (R1, section 4 below). |
| 02 | spl-lane-mix speed | CI wall, table in section 1 | median 119 s; wall 111 / 185 s vs cpu 114 / 189 s | **disagree**: 11th slowest, not 2nd, and CPU-bound (cpu = wall), so "mock loops / sleeps" has nothing to remove. Replace with **P1** (orch-rotate). |
| 03 | search-sig behavioural | `grep -nE 'grep\|\.func\.sh' csi-spl-orc/src/bash/tests/spl-search-sig-check.tst.sh` | 14 asserts on stub call logs and the SQL sent (lines 50-93, 103); ONE source read, line 95, checks the recorded `SPL_SEARCH_SIG_PASSED_ON_RECORDED=` constant format | **disagree**: the test already executes the action with stubbed psql/proxy; line 95 guards a recorded value, not behaviour. Not among the 12 most urgent. Slot freed for the round. |
| 04 | coverage floor logging | `go test -count=1 -cover ./internal/logging/` (go1.26.9) and `grep -E ' (0\.0\|3\.5)$' csi-spl-api/src/bash/tests/go-coverage-floor.txt` | logging 100.0 %, floor 0.0 | **agree with changes**: merge rows 04 and 08 into ONE row that raises every drifted floor in the one file: logging 0.0 -> 100.0 (measured), testkit 0.0 -> 78.6, testkit/fakehub 0.0 -> 82.1, auth/cmd/auth-demo 0.0 -> 71.8, github/githubtest 0.0 -> 21.1 (each measured with `go test -count=1 -cover`, n=1). One file, five lines, one push. |
| 05 | peer-poll speed | CI wall, table in section 1; `grep -cE '\bsleep [0-9]' csi-spl-orc/src/bash/tests/peer-poll.tst.sh` | median 138 s; cpu 107 / 167 s (~18 % idle); 2 sleep lines | **disagree**: the plan's "multi-second fixed polling sleeps" are 2 lines and ~18 % of wall; the rest is CPU. Replace with **P2** (dispatch-rotate, 249 s, ~78 % idle). |
| 06 | parse-metadata-nofork speed | CI wall, table in section 1 | median 191 s, cpu 76 / 112 s | **agree with changes**: number now 191 s, not 453 s; target < 90 s. Drop `orc-shard-weights.txt`. |
| 07 | unanswered-sweep behavioural | `sed -n 1,45p csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh`; `git grep -n disabled_at origin/master -- 'csi-spl-api/**/migrations/*' 'csi-spl-api/**/*.sql'` | the test already runs the sweep SQL against a real throwaway Postgres with the real rdb migrations (header, cases 1-9); the grep at line 36 runs BEFORE the docker SKIP on purpose; no migration has `disabled_at` (0 lines) | **disagree**: the row's premise is inverted. `disabled_at` is the column that does NOT exist (the prd failure of 2026-10-01 the header names); the line 36 grep is a negative guard that still bites on a box with no docker. Its red control ("removing `WHERE disabled_at IS NULL`") names a clause the SQL does not have. Removing the grep loses coverage. |
| 08 | coverage floor testkit | `go test -count=1 -cover ./internal/testkit/ ./internal/testkit/fakehub/` | 78.6 % and 82.1 %, floors 0.0 | **agree with changes**: fold into row 04 (above). |
| 09 | desk-actions speed | CI wall, table in section 1 | median 225 s (119 / 225 / 236), cpu 84 / 141 s | **agree with changes**: number now 225 s, not 366 s; target < 90 s. Drop `orc-shard-weights.txt`. |
| 10 | ask-owner untested action | `ls csi-spl-orc/src/bash/run/ \| grep -i ask` | `spl-ask-ack spl-ask-close spl-ask-put spl-asks-open spl-asks-sync spl-asks-tick ...`; `spl-ask-owner.func.sh`: No such file or directory | **disagree**: the action does not exist. The "224 untested" behind it is a measuring artefact (section 3 below): the real count is 30. Replace with **P3**. |
| 11 | open-in-place flake | `gh run view 38729860085` and `gh run view 38727011636 --json conclusion,headSha,createdAt,event` | 38727011636 success, push, 11:23:40Z; 38729860085 failure, **schedule**, 11:47:34Z, same sha 62177c06b; failed job `wui: browser e2e (mock, generated) 1/5` | **agree with changes**: a real flake (same sha, two verdicts, n=1), but the order is the reverse of the plan: green first, then the scheduled run went red. It is outside the last-100 window (that window starts 12:57Z); keep it, its target "0 in 20 local runs" is fine. |
| 12 | edge package test suite | `go list -f '{{.ImportPath}} T={{len .TestGoFiles}} X={{len .XTestGoFiles}}' ./internal/edge`; `go test -count=1 -cover ./internal/edge/` | `T=0 X=2` (`edge_test.go`, `guard_test.go`, both `package edge_test`); coverage **98.9 %**; floor already `internal/edge 98.9` (line 30) | **disagree**: the package is tested. The plan's `go list ... .TestGoFiles` misses external `_test` packages. With `(not .TestGoFiles) and (not .XTestGoFiles)` the untested Go package count is **0**. |

## 3. Section 1 (too much / too little) verdicts

| claim in the plan | command | output | verdict |
|---|---|---|---|
| CI job p90: hub 1037 s, orc 974 / 852 s, iac 147 s, e2e ~15 min/shard, unit 145 s | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (window 2026-10-15 12:57Z .. 23:07Z) | hub p90 1053 s (n=31), orc 975 / 876 s (n=37), iac 147 s, feature 242 s, e2e 853..924 s per shard (n=32), unit+typecheck 145 s | **agree** (drift of a few %). |
| ORC: "5 tests take 2,462 s (>67 % of hermetic runtime)" | CI medians, section 1 | top 5 = 1,327 s of 8,070 s = **16 %** | **disagree**: the 2,462 s is the sum of 5 stale packing weights. ORC is not "a handful of bloated tests"; the slowest 12 files are all between 128 and 426 s. |
| ORC: "224 of 612 bash actions have 0 tests" | the plan's 3.6 loop -> `224 of 612`; the same loop that ALSO accepts the `do_<snake>` name: `grep -rlqw "do_${b//-/_}" csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests csi-spl-api/src/bash/tests` | **30 of 612** | **disagree**: the plan greps a test's CONTENT for the file's kebab name, but tests call `./run -a do_spl_box_leave` (e.g. `spl-box-leave.tst.sh` exists and was counted "untested"). Real long tail: 30. |
| WUI: "74 % of unit tests read source via readFileSync" | `grep -lE '(readFileSync\|fs\.read)' csi-spl-wui/tests/unit/*.test.mjs \| wc -l`; files that also import `../src/`; files that read and do NOT import | 285 of 380 read a file; **304 of 380 import and run `src/` code**; **76** read source and import nothing | **agree with changes**: "too little behavioural unit testing" is true for 76 files (20 %), not 74 %. Many of the 285 read a fixture or a locale file next to executing code. |
| WUI: 143 `*.proof.mjs` never run in CI; 4 ci-skip | the plan's 3.2 command | `ci-skip: 4, proof.mjs: 141, orc-proof: 2` | **agree** (141 now). |
| API: "internal/edge has no tests"; floors drifted | `go list` + `go test -cover`, row 12 / row 04 above | edge 98.9 %; 5 packages under their real coverage | **agree with changes**: drift yes, edge no. |
| Failures in last 100: WUI 5 (4 card-menu, 1 open-in-place), ORC 5, API 3, IAC 0 | `do_report_ci_gate`, 100 runs | 5 failed runs in all: 4 `wui e2e 5/5` (card-menu, runs 38744577102 38745970215 38748827138 38749369628), 1 `orc 2/2` (`run-loader-convention.tst.sh`, 38795036653), hub 2 (both fail-fast stops) | **agree with changes**: ORC 1 not 5, API 2 fail-fast not 3, open-in-place outside this window. |

## 4. Section 2 (top 15 failing) verdicts

Commands: `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
(100 runs, 2026-10-15 12:57Z .. 23:07Z: 44 success, 51 cancelled, **5 failure**) and the same with
`CI_GATE_RUNS=500` (2026-10-13 20:03Z .. 2026-10-15 23:13Z: 155 success, 273 cancelled, **72 failure**;
its "failed runs" list prints the newest 27 of the 72, back to 2026-10-14 19:54Z), plus
`gh run view <id> --json conclusion,headSha,createdAt,jobs` and the job log's `FAIL` lines for each
run id the plan cites.

| rank | plan claim | what I measured | verdict |
|---|---|---|---|
| 1 | perf-budget, 31 runs | 0 in last 100; 500 runs: `wui: nuxt generate` is first red in **12** runs; last green 38819626552 (2026-10-15 22:48Z) | **agree with changes**: a real defect of the older window, green now. 31 not reproduced (my window is 500 runs, the plan's 1,000), and I did not check that each of the 12 is the perf-budget signature (none is among the 27 listed). |
| 2 | card-menu e2e, 4 runs | 4 runs, the same 4 ids, `FAIL 8 a hold on the card body opens the card menu` on 3 shas within 33 min; job green since 38819626552 | **agree** (real fault, now fixed). |
| 3 | duplicate action, 3 runs (38720562396, 38721706455, 38795036653) | 38720562396 and 38721706455: `FAIL: defined in two files ... spl-hub-request-minutes.func.sh` / `FAILED: func-name-unique.tst.sh`; **38795036653** is a different test: `FAIL: ./run cannot resolve` / `FAILED: run-loader-convention.tst.sh` | **agree with changes**: 2 runs, not 3; the third is its own defect (rank it separately, 1 run). |
| 4 | gate10-fail-fast flake, 3 runs | `git log --oneline -1 f3c92877a` -> `fix(iac test, gate10-fail-fast): order the hold check by events, not a 3 s clock`; 0 in the last 500 | **agree** it was a flake; already fixed, so no row (correctly none). |
| 5 | open-in-place flake | see row 11: green 11:23Z push, red 11:47Z schedule, same sha | **agree with changes** (order reversed; n=1). |
| 6 | calendar-phone e2e, 2+ runs | 38021028676: failure on 892f2654, `wui: browser e2e 3/3` (2026-10-10, a 3-shard era); 0 in the 27 failed runs listed of the last 500 | **agree with changes**: historical; not seen since the 5-shard split. |
| 7 | spl-lane-mix "times out (>1200 s)" | 0 timeouts in the 27 listed failed runs (`grep -ciE 'lane-mix\|timed out'` -> 0 FAIL lines); orc shard p90 923 / 838 s of a **1800 s** limit (51 % / 46 %, n=203); file median 119 s | **disagree**: no timeout evidence; the cap is 1800 s, not 1200 s. |
| 8 | fleet-lease load flake | same: 0 FAIL lines; file median 236 s | **disagree** as a failing test; it is a slow test (row 01), not a failing one. |
| 9 | peer-poll load flake | same: 0 FAIL lines; median 138 s | **disagree**, as 8. |
| 10 | spool-posts-dir, 1 run | 38725456882 a2c79894: `FAIL: 1. rc=0 changed=yes PLAN posts-dir mkdir -p + chmod 2777` | **agree**. |
| 11 | mobile-back-stuck, "multiple" | not among the 27 listed failed runs; no run id in the plan | **cannot verify**: no run id; drop or cite one. |
| 12 | phone-composer-target, "multiple" | same | **cannot verify**. |
| 13 | iac tfvars-parity / step-contracts, 5 runs | 500 runs: `iac` first red in **10** runs; 7 consecutive iac reds 2026-10-14 21:11Z .. 22:45Z (38638301087 .. 38649779430, `Process completed with exit code 1`) | **agree with changes**: 10 first-red runs, one 95-minute streak; real fault. |
| 14 | hub internal/store Postgres, 4 runs | the hub reds in the listed 27 are `TestHygienePatternsInSync` (38659511447, 38661401173) or fail-fast stops; no store failure listed | **cannot verify** the store claim; the hub's real reds in the window are the hygiene-pattern sync test. |
| 15 | LiveTopicPane unit, 3 runs | `wui: unit tests` is not among the jobs failing in the 500-run report | **cannot verify** in my window. |

Missing from the plan's top 15 although they are first-red in the 500-run window:
`orc 1/2` OA-12 poke CONTROL (38673192429), `orc 1/2` hidden-workspace add (38659511447), `orc 1/2`
canary key leak (38636179087), `wui e2e 4/5` mouse-drag strip (38697596380), `wui e2e 4/5` print/TOC
gap (38635003388), and one infrastructure red: `Failed to download archive ... actions/setup-go`
(38687357144). Each is n=1 in the list; none repeats, so none earns a row on its own.

**Split:** of the 15, I can confirm 7 with a run id (1, 2, 3, 5, 10, 13, and 4 as fixed); 3 (7, 8, 9)
are slow tests with no failure evidence and should leave a "most failing" list; 4 (11, 12, 14, 15) carry
no run id I could check.

## 5. Three more urgent actions (proposals)

**P1. `orch-rotate.tst.sh`: clock seam for the rotate waits. Replaces row 02.**
- Number now: the slowest orc test, median **426 s** (361 / 428 / 426, n=3), cpu 41 / 55 s: **~88 % idle**.
- Why idle: the test drives the real rotate code with real-second waits:
  `grep -cE '_WAIT=[0-9]|_SEC=[0-9]|_TIMEOUT=[0-9]' csi-spl-orc/src/bash/tests/orch-rotate.tst.sh` -> `10`
  (`ROTATE_ESC_WAIT`, `ROTATE_START_WAIT`, `ROTATE_ACK_TIMEOUT`, `ROTATE_EXIT_WAIT=6/8`, ...).
- Target: < 120 s CI wall; red control: an ack that never arrives still trips the `ROTATE_ACK_TIMEOUT` case.
- Sites: `csi-spl-orc/src/bash/tests/orch-rotate.tst.sh` (+ the wait seam in its action file, if the seam is missing).

**P2. `dispatch-rotate.tst.sh`: same seam. Replaces row 05.**
- Number now: median **249 s** (245 / 278 / 249), cpu 46 / 65 s: **~78 % idle**;
  `grep -cE '_WAIT=[0-9]|_SEC=[0-9]|_TIMEOUT=[0-9]' csi-spl-orc/src/bash/tests/dispatch-rotate.tst.sh` -> `8`.
- Target: < 90 s. Lane 1 can take P1 then P2 (same pattern, disjoint files).

**P3. Hermetic dry-run tests for the two DESTRUCTIVE untested iac actions. Replaces row 10.**
- Of the 30 truly untested actions (section 3), the repo CLAUDE.md names two as destructive, owner-go-only:
  `gcp-delete-service-account.func.sh` (55 lines) and `gcp-compute-lb-cleanup.func.sh` (87 lines). Command:
  the 30-file list, filtered by `grep -qE 'DRY_RUN|gcloud .*(delete|create|add-iam|set-iam|deploy)|(INSERT|UPDATE|DELETE) '` -> 9 files, these two among them.
- Target: one `.tst.sh` each, gcloud stubbed: the default is a dry run that makes NO gcloud call; a missing env refuses. Red control: flip the DRY_RUN default and the test goes red.
- Sites: two new files under `csi-spl-iac/src/bash/tests/`.

Further measured candidates for the slots freed by rows 03, 07, 12 and the 04+08 merge (not counted as proposals):
`tmux-close-window.tst.sh` 169 s at ~94 % idle (it `exec`s `features/spawn-agents/tests/test-tmux-close-window.sh`),
`cloud-actions.tst.sh` 160 s at ~94 % idle, `box-purge.tst.sh` 190 s, `wd-self-update.tst.sh` 175 s at ~65 % idle.

## 6. R1 check (disjoint files per batch) and 3 x 4 lanes

- `grep -n 'orc-shard-weights.txt' csi-spl-doc/doc/md/test-round-1-plan.md` -> the section 4 table lists it in rows **01 and 02 (both batch 1)** and **05 and 06 (both batch 2)**, and 09: **R1 is broken twice** in the row table, while section 5.1 lists it only under row 01. Every speed row that lands changes the weight of its file, so each would want that file.
  Fix: no speed row edits `orc-shard-weights.txt`; ONE refresh after batch 3, from the `--- every file (wall s)` block (the file's own header says so).
- `go-coverage-floor.txt` sits in rows 04, 08 and 12 (batches 1, 2, 3): R1 holds, but with 04+08 merged and 12 dropped it is one row and the question goes away.
- 3 batches x 4 rows = 12, 4 lanes in parallel: holds as drawn (sections 5.1, 5.2). With my changes: batch 1 = 01, P1, 04+08, 06; batch 2 = 09, P2, 11, P3; batch 3 = the freed slots (candidates above), each one file, disjoint.

## 7. Sign-off

signed: c-245 on 7289d2db8

v1.0 takes every correction above: speed rows on CI medians (n=3), P1 orch-rotate (row 01), P2 dispatch-rotate (row 05), P3 destructive iac dry-runs (row 08), rows 04+08 of v0.1 merged, rows 03/07/12 of v0.1 dropped, `orc-shard-weights.txt` out of every row (R1 holds in all 3 batches).

One note for R7.2, not a blocker: the mistral seat is held by a claude takeover (c-249), so a claude-built row reviewed by c-249 is a same-vendor review. Every row is claude, so its reviewer is the agy seat or a non-claude seat.
