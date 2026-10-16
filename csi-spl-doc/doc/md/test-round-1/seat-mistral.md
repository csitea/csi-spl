# Test round 1: mistral seat verdict (claude takeover of the mistral seat)

Seat: **c-249@sat**, claude takeover of the mistral seat (m-246@sat had its
2 tries). Issue: SPL-2068 (seat lane), round issue SPL-2052.
Plan reviewed: `test-round-1-plan.md` v0.1 (9e3d04dd9). Every number below
was measured in this session; none is copied from the plan or another seat.

**Tree:** every file count was run on **`754b1d4bb`** (`origin/master`,
2026-10-16). CI numbers name their window:

- **W100**: `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
  -> last 100 runs of `10_ci-quality.yml` on master, 2026-10-15T13:21Z..23:45Z:
  49 cancelled, 44 success, 5 failure, 2 running.
- **F100**: the last 100 *failed* master runs,
  `gh run list --workflow 10_ci-quality.yml --branch master --limit 100 --status failure`
  -> run 38332275444 (2026-10-13T01:28Z) .. 38795036653 (2026-10-15T19:34Z).
  Their failed jobs: `gh api repos/csitea/csi-spl/actions/runs/<id>/jobs` -> 264
  failed jobs; each job log (`gh api .../actions/jobs/<id>/logs`) grepped for
  `FAILED: <file>.tst.sh`, `] FAIL tests/e2e/<file>`, `FAIL ci_<budget>`,
  `--- FAIL: Test<name>`, `gate fail-fast: stopped`. 242 of 264 logs gave a
  line; 22 gave none (fetch timeout twice, or a cancel). Counts are
  **distinct runs**, so they are lower bounds.
- **H3**: per-file CI wall and cpu of the 2 `orc: hermetic action tests`
  jobs (the `--- every file (wall s)` and `--- slowest 10 test files (wall s,
  cpu s)` blocks of `run-all-tests.sh`) in 3 green master runs:
  38823881139 (c853b7e5c), 38813463720 (d0950b1e3), 38812274856 (9b162dc9f).
  n=3, the median is quoted.

Tally over the 12 rows: **0 agree / 7 agree with changes / 5 disagree / 3 proposals.**

## 1. Section 1 (too much / too little)

| claim in the plan | command | output on 754b1d4bb / window | verdict |
|---|---|---|---|
| WUI 379 unit, 255 e2e, 143 proof | `ls csi-spl-wui/tests/unit/*.test.mjs \| wc -l`; `ls csi-spl-wui/tests/e2e/*.test.mjs \| wc -l`; `find csi-spl-wui -name '*.proof.mjs' -not -path '*/node_modules/*' \| wc -l` | 381; 257; 141 | agree with changes: numbers drifted |
| "143 proof files completely omitted from CI" | `grep -n proof .github/workflows/50_oss-standalone.yml` | line 104 runs `tests/e2e/standalone-live.proof.mjs`; `pnpm test:live:proofs` (`run-live-proofs.mjs`) picks the rest on demand against dev/prd | agree with changes: 140 of 141 never run in a gate, by design (live sites); 1 runs in workflow 50 |
| ORC 430 hermetic, 116 feature tests | `ls csi-spl-orc/src/bash/tests/*.tst.sh \| wc -l`; `find csi-spl-orc/src/bash/features -path '*/tests/*' -name '*.sh' \| wc -l` | 431; 118 | agree with changes |
| ORC "5 tests take 2,462 s (>67 % of hermetic runtime)" | H3 | top 5 medians: orch-rotate 426.6, dispatch-rotate 280.0, fleet-lease 239.4, desk-actions 229.7, wd-self-update 229.2 = 1404.9 s; per-run sum over both shards 8812, 9531, 9189 s | **disagree**: the top 5 are ~15 % of hermetic wall, not 67 %. The 2,462 s comes from `orc-shard-weights.txt` (a packing weight, sum 15437 s per the `--- shard 1/2 weight: 7713 of 15437 s` log line, last changed `94cd17be3 2026-10-12`), not from a CI run |
| ORC "224 of 612 bash actions have 0 tests" | the plan's 3.6 loop | 224 of 612 | **disagree**: the loop greps the kebab basename only. Re-run also accepting the `do_<snake>` symbol: 194 of the 224 are named by a test, **30 of 612** are named by none (list: `untested30` below) |
| CI job-minute share WUI 61 % / ORC 22 % / API 12 % / IAC 2 % | the jobs of the 49 finished W100 runs (47 fetched), `((completed_at-started_at))` summed per area | 3756.4 job-min: wui 2151.2 (57.3 %), orc 1052.0 (28.0 %), hub 420.4 (11.2 %), iac 77.6 (2.1 %) | agree with changes: WUI is still the largest, ORC is larger than stated |
| API 752 `*_test.go`, 2,194 Go tests | `find csi-spl-api -name '*_test.go' \| wc -l`; `git grep -hE '^func Test[A-Z_]' -- 'csi-spl-api/*_test.go' \| wc -l` | 752; 2194 | agree |
| API "several utility packages at 0.0 floor despite tests" | `grep -E ' (0\.0\|3\.5)$' csi-spl-api/src/bash/tests/go-coverage-floor.txt`; `go test -count=1 -cover ./internal/logging/ ./internal/testkit/... ./internal/auth/fakeidp/ ./internal/auth/cmd/auth-demo/ ./internal/github/githubtest/` | floors 0.0 for auth-demo, githubtest, logging, testkit, fakehub, 3.5 fakeidp; coverage 71.8, 21.1, 100.0, 78.6, 82.1, 3.5 | agree |
| IAC 149 tests, "133 rely on source text" | `ls csi-spl-iac/src/bash/tests/*.tst.sh \| wc -l`; plan 3.4 | 149; the 133 is over iac **and** orc (`Bash text tests: 133 of 580`) | agree with changes: 133 is the two trees together, not iac alone |

Area verdicts: WUI agree with changes (heavy e2e is the cost; source-text unit
tests 285 of 381, plan 3.4 command), ORC **disagree** with "5 bloated tests"
(the wall is spread; the real waste is idle wait, see P1) and with "224
untested", API agree, IAC agree with changes.

## 2. Section 2 (top 15 failing), checked against F100 and W100

| plan rank | plan says | measured | verdict |
|---|---|---|---|
| 1 perf budget, 31 runs | `FAIL ci_initial_gzip_kb 155.1 > 155` | F100: 17 runs, all `FAIL ci_initial_gzip_kb 155.1 > 155`, runs 38452084961 (10-13 19:05Z) .. 38560414845 (10-14 11:58Z); 0 in W100 | agree with changes: the top real fault by count, 17 runs not 31, gone since 10-14 12:00Z |
| 2 `tests/e2e/card-menu.test.mjs`, 4 runs | | `ls csi-spl-wui/tests/e2e/ \| grep card-menu` -> only `phone-card-menu.test.mjs`. The 4 W100 e2e 5/5 reds print `FAIL tests/e2e/move-by-drag.test.mjs (exit 1, then exit 1 on retry)`; fixed by `af08b91e0` (test fix) | **disagree**: wrong file; it is `move-by-drag.test.mjs`, 4 runs (F100), already fixed |
| 3 duplicate action name, 3 runs | | F100: `run-loader-convention.tst.sh` 2 runs, `func-name-unique.tst.sh` 1 | agree with changes |
| 4 `gate10-fail-fast.tst.sh` flake | fixed `f3c92877a` | `git log -1 f3c92877a` -> 2026-10-12, "order the hold check by events"; 0 in F100 | agree, but it is history, drop from a "now" list |
| 5 `open-in-place.test.mjs` flake | passed on rerun | run 38729860085 (62177c06b) prints `FAIL tests/e2e/open-in-place.test.mjs (exit 1, then exit 1 on retry)`; the green run on that sha, 38727011636, is 24 min **earlier** (11:23Z vs 11:47Z); 1 run in F100; the plan's 3.1 command today prints nothing | agree with changes: it failed its in-run retry too; 1 run total |
| 6 `calendar-phone.test.mjs` | 2+ runs | F100: 0 runs name it | **disagree**: not in the window |
| 7-9 lane-mix / fleet-lease / peer-poll "load flake" | "multiple" | F100: 0 `FAILED:` lines name any of the three | **disagree**: slow, not failing |
| 10 `spool-posts-dir.tst.sh` | 1 run | `git ls-files \| grep spool-posts-dir` -> nothing; the posts-dir check lives in `dispatch-setup-check.tst.sh` | agree with changes: wrong file name |
| 11 `mobile-back-stuck.test.mjs` | multiple | F100: 0 runs | **disagree** |
| 12 `phone-composer-target.test.mjs` | multiple | F100: 0 runs | **disagree** |
| 13 `tfvars-parity.tst.sh` / `step-contracts.tst.sh`, 5 runs | | `git ls-files \| grep -E 'tfvars-parity\|step-contract'` -> nothing; F100: 8 iac job failures | agree with changes: names are job labels, not files |
| 14 hub store Postgres, 4 runs | | F100: hub job failed in 36 runs; 29 of the 100 failed runs carry a `gate fail-fast: stopped` line (another job's red stopping the rest); Go `--- FAIL:` top: `TestHygienePatternsInSync` 2, `TestBoxTokenRetiredRevisionStillStrands` 2 | agree with changes |
| 15 `LiveTopicPane.vue` unit, 3 runs | | F100: 0 unit-job failures | **disagree** |

**What F100 says is failing most** (distinct runs), the list the plan should carry:

| # | test | runs (F100) |
|---|---|---|
| 1 | perf budget `ci_initial_gzip_kb 155.1 > 155` (nuxt generate) | 17 |
| 2 | `tests/e2e/open-parent-section.test.mjs` | 6 |
| 3 | `tests/e2e/issues-crud-modal.test.mjs` | 5 |
| 4 | `tests/e2e/move-by-drag.test.mjs` | 4 |
| 5 | `tests/e2e/blog-share.test.mjs` | 4 |
| 6 | `check-pre-push-features.tst.sh` | 3 |
| 7 | `poll-answer-no-scroll`, `message-order`, `login-centred`, `docs` (e2e) | 3 each |
| 8 | `workspace-doc-node`, `topic-head-pg`, `tenant-host`, `spl-spawn-queue`, `run-loader-convention`, `public-dataset-load`, `msg-wipe` (orc) | 2 each |

Failures are **spread**: past the budget, no test fails in more than 6 of
100 failed runs. A per-job count over-reads the jobs that a fail-fast stop
marks red (the hub job reads 36 failures, Go `--- FAIL:` lines name 2 tests
twice).

## 3. Section 3 baselines, re-run

| item | plan output (4251b33cf) | my output (754b1d4bb) | verdict |
|---|---|---|---|
| 3.1 flaky (same sha red+green) | 1 pair | plan's command on today's last 100 runs: prints nothing | agree with changes: window moved; the one pair was red after green (see rank 5) |
| 3.2 never in CI | `ci-skip: 4, proof.mjs: 143, orc-proof: 1` | `ci-skip: 4, proof.mjs: 141, orc-proof: 2` | agree with changes |
| 3.3 no red control | 25 (head -25) | `head -25 \| wc -l` -> 25; without `head`: 80 `assert.match(src(` lines | agree with changes: the `head` caps the count at 25 by construction |
| 3.4 source-text tests | `284 of 379; 133 of 579` | `WUI text tests: 285 of 381; Bash text tests: 133 of 580` | agree |
| 3.5 slowest | weights file | weights file unchanged (`94cd17be3`); CI (H3) differs: see section 1 | **disagree**: a weight is not a wall time |
| 3.6 untested | `224 of 612; Go 1` | `224 of 612`; Go: `go list -f '{{if not .TestGoFiles}}…'` -> `internal/edge xtest=2` | **disagree** on both: 30 of 612 (section 1); edge has 2 external test files |
| 3.7 floors | 6 lines | same 6 lines | agree |

## 4. The 12 rows

| # | row | command | output (754b1d4bb / H3) | verdict and change |
|---|---|---|---|---|
| 01 | fleet-lease speed | H3 | wall 205.8 239.4 239.6 (median 239.4), cpu 108.2 135.0 135.5 | **agree with changes**: number now 239 s, not 580. cpu 135 s, so "< 60 s" needs the CPU work cut too; target < 120 s. Drop `orc-shard-weights.txt` from its sites (R1, section 6) |
| 02 | spl-lane-mix speed | H3 | wall 156.9 175.9 179.9, cpu 165.0 180.7 183.9 | **disagree**: cpu >= wall, nothing sleeps; it is the 10th slowest by H3 median (176 s). Replace with **P1** |
| 03 | search-sig behavioural | `grep -c 'do_spl_search_sig_check' csi-spl-orc/src/bash/tests/spl-search-sig-check.tst.sh`; `git grep -c "grep -qE" <same>` | 3; 1 | **disagree**: the test already runs the action 3 times against a psql stub; the one `grep -qE` pins the format of a recorded constant (`SPL_SEARCH_SIG_PASSED_ON_RECORDED`). Replace with **P2** |
| 04 | logging floor | `go test -count=1 -cover ./internal/logging/`; `grep -n 'internal/logging' …/go-coverage-floor.txt` | 100.0 %; `43:internal/logging 0.0` | **agree with changes**: floor 99.0, not 85.0, and **merge row 08 into it**: one commit raising all drifted plain floors in that one file: logging 0.0->99.0, testkit 0.0->77.6, testkit/fakehub 0.0->81.1, auth/cmd/auth-demo 0.0->70.8, github/githubtest 0.0->20.1 (measured coverage minus the 1.0 tolerance the file header allows) |
| 05 | peer-poll speed | H3 | wall 178.7 207.5 208.0, cpu 145.2 162.3 163.6 | **agree with changes**: 207 s now, 78 % of it cpu; target < 120 s |
| 06 | parse-metadata speed | H3 | wall 133.2 192.7 199.9, cpu 86.9 112.8 112.3 | **agree with changes**: 193 s now; target < 100 s |
| 07 | unanswered-sweep behavioural | `sed -n 36,37p csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh`; `grep -c 'docker run' <same>` | `grep -q 'disabled_at' … && fail "the sweep SQL names disabled_at, which no tenants migration has"`; 1 | **disagree**: the grep asserts the column is **absent** (it never existed, 2026-10-01 incident in the file's own header); the test already runs the SQL on a docker Postgres. The planned red control ("removing `WHERE disabled_at IS NULL` fails") is backwards. Drop |
| 08 | testkit floor | `go test -count=1 -cover ./internal/testkit/...` | testkit 78.6 %, fakehub 82.1 % | **agree with changes**: fold into row 04 (one file, one commit); frees a slot |
| 09 | desk-actions speed | H3 | wall 181.9 229.7 233.0, cpu 115.0 142.8 142.4 | **agree with changes**: 230 s now; target < 150 s |
| 10 | ask-owner test | `ls csi-spl-orc/src/bash/run/spl-ask-owner.func.sh`; `git grep -n 'do_spl_ask_owner\b'` | `No such file or directory`; only plan + seat files | **disagree**: the action does not exist. Replace with **P3** |
| 11 | open-in-place flake | run 38729860085 log | `FAIL tests/e2e/open-in-place.test.mjs (exit 1, then exit 1 on retry)`; 1 run in F100 | **agree with changes**: 1 run in 100 failed runs; `open-parent-section.test.mjs` (6) and `issues-crud-modal.test.mjs` (5) fail more. Retarget to open-parent-section; the "20 consecutive `node --test`" target needs the generated bundle (`BASE_URL=<bundle> pnpm run test:e2e`) |
| 12 | edge test suite | `ls csi-spl-api/src/go/spool-hub-api/internal/edge/`; `go test -count=1 -cover ./internal/edge/`; `grep -n internal/edge …/go-coverage-floor.txt` | `edge.go edge_test.go guard_test.go`; 98.9 %; `30:internal/edge 98.9` | **disagree**: already tested and floored. `TestGoFiles` is empty because both files are package `edge_test` (`XTestGoFiles` = 2). Drop |

Rows 07 and 12 drop with no replacement from this seat; row 08 folds into
04. That leaves slots for the other seats' proposals (or the F100 e2e
leaders `issues-crud-modal`, `blog-share`).

## 5. Three proposals the plan missed

| P | action | command | number | replaces |
|---|---|---|---|---|
| P1 | **cut idle wait in `orch-rotate.tst.sh` and `dispatch-rotate.tst.sh`** (fake clock or event wait; the time goes to sleeping, not work) | H3 | orch-rotate wall 399.1 426.6 427.7 / cpu 43.1 56.3 55.6 (**~87 % idle**, 371 s); dispatch-rotate wall 263.5 280.0 282.2 / cpu 55.8 64.2 65.8 (~77 % idle, 216 s). Also idle: `tmux-close-window.tst.sh` 173.5 / 11.5, `cloud-actions.tst.sh` 156.7 / 9.3. Target: each < 2x its cpu. Red control: a stalled rotation still fails inside the cap | row 02 (batch 1, lane 2) |
| P2 | **refresh `orc-shard-weights.txt` from CI**, once, after the speed rows | `grep -h 'weight:' <hermetic job log>`; H3 sums | weights total 15437 s; measured per-run hermetic sum 8812 / 9531 / 9189 s (n=3), i.e. weights ~1.7x reality and ranked differently (fleet-lease weight 580 vs 239 s). Every speed row in this plan was ranked from the stale file. The test that reads the file: `git grep -ln orc-shard-weights -- '*.tst.sh'` -> `run-all-tests-parallel.tst.sh`; the row names its red control there | row 03 (move to batch 3, alone on that file) |
| P3 | **hermetic test for `gcp-compute-lb-cleanup.func.sh`** with stubbed gcloud: every call carries `--account`, deletes run in dependency order, nothing runs on a missing `ENV` | `grep -rlw 'do_gcp_compute_lb_cleanup\|gcp-compute-lb-cleanup' csi-spl-orc/src/bash/tests csi-spl-iac/src/bash/tests csi-spl-orc/src/bash/features/*/tests \| wc -l`; `grep -c 'delete' csi-spl-iac/src/bash/run/gcp-compute-lb-cleanup.func.sh`; `grep -c 'DRY_RUN' <same>` | 0 tests; 10 `delete` lines (`gcloud compute … delete --quiet`); 0 `DRY_RUN`. It is one of the destructive `gcp-*` actions the repo CLAUDE.md names, and one of the 30 actions no test names | row 10 |

`untested30` (actions no test names by basename or `do_` symbol), command:
the plan's 3.6 loop, then for each hit `grep -rqw "do_${b//-/_}"` over the
same test dirs -> 30 files; the 5 largest: `gcp-tail-logs` (152 lines),
`spl-wire-probe` (144), `spl-wd-orch-outcome` (142),
`spl-standby-bench-helpers` (104), `gcp-compute-lb-cleanup` (87).

## 6. R1 and the 3 x 4 batches

- R1 (`rounds-rulebook.md` 2.1: no path in two rows of one batch):
  `grep -n 'orc-shard-weights.txt' csi-spl-doc/doc/md/test-round-1-plan.md`
  -> section 4 lines 156, 157, 160, 161, 164: rows 01 + 02 (batch 1) and
  05 + 06 (batch 2) each list it. Section 5.1 drops it from rows 02/05/06,
  so the two sections disagree. **R1 fails on section 4 as written.** Fix:
  no speed row edits the weights file; P2 refreshes it once, alone, in batch 3.
- `go-coverage-floor.txt` sits in rows 04, 08, 12, one per batch: R1 holds,
  and with 08 folded into 04 and 12 dropped it is one row.
- Batches are 4 + 4 + 4 with lane chains 01->05->09, 02->06->10,
  03->07->11, 04->08->12: the shape holds. With my changes:
  batch 1 = 01, P1, 04(+08), 11-retargeted; batch 2 = 05, 06, and two slots
  for other seats; batch 3 = 09, P3, P2, one slot. P1's files
  (`orch-rotate.tst.sh`, `dispatch-rotate.tst.sh`) are in no other row.

## 7. Signature

Pending v1.0.
