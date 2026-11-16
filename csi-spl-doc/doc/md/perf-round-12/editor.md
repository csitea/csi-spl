# Perf round 12: editor seat (c-616, claude) - WORK IN PROGRESS

State written at the 10:20Z rotation on 2026-11-16. This is not the plan yet:
`perf-round-12-plan.md` is not drafted. Issue SPL-5701, epic SPL-2402, spec
`csi-spl-doc/specs/027-spool-performance`, round topic `32d81359`; report to
the dispatch lease holder (c-002@sat at 09:24Z) on task `dispatch-perf-r12`.

## 1. Done

- STEP 0: developer guide acked (blob `8b1916cd`), fetched.
- One sha for every baseline: **`a8a54cf44`** (`origin/master` at 09:22Z).
- Rulebook 4.4 on `a8a54cf44`, the command verbatim:
  `perf 16 refactor 108 perf-share 12.9% under-20`.
- Slug: `git log origin/master --oneline -E --grep='\(p12-'` -> 0 lines;
  `git ls-tree -r --name-only origin/master | grep -c perf-round-12` -> 0.
- Retro: `git ls-tree -r --name-only origin/master | grep -cE 'perf-round-(9|10|11)-retro'`
  -> 0. There is no `perf-round-11-retro.md`; the plan says so and guesses
  nothing.

## 2. Measurements so far

### 2.1 The desk box pre-push log (`~/.cache/csi-spl/pre-push.log` of the desk user)

24 h, 2026-11-15T09:20Z..2026-11-16T09:20Z, PART lines without SKIP / cached:

| part | n | sum s | median s |
|---|---|---|---|
| `orc` | 67 | 35,090 | 394 |
| `api` | 29 | 19,090 | 225 |
| `iac` | 28 | 13,015 | 395 |
| `orc-features` | 40 | 9,895 | 235 |
| `lint-gosec` | 18 | 9,470 | 454 |
| `wui` | 31 | 8,018 | 259 |
| `wui-e2e` | 14 | 7,111 | 419 |

By verdict, same 24 h: `orc` PASS n=51, mean 258 s; **`orc` WARN-pre-existing
n=15, mean 1,405 s (928..2,318 s, all one lane, SPL-5640)**. Over 7 days
(from 2026-11-09T09:20Z), WARN-pre-existing: `orc` 15 (21,081 s), `iac` 33
(24,742 s), `wui` 27 (22,930 s), `orc-features` 11 (7,020 s).

Cause, read in `csi-spl-iac/src/bash/run/check-pre-push.func.sh`: a failed
part is re-run WHOLE on the base ref (`_pp_run`, `:1068-1076`) to tell a
pre-existing red from a new one. For `orc` the base re-check runs the same
`--changed` plan again (`_pp_part_orc`, `:713-731`).

### 2.2 Candidate row 01: the orc re-check runs only the files that failed (A/B, running)

Probe dir `/var/tmp/c616-probe/` on the desk box: two `git clone --shared`
checkouts `T` and `T2` of `a8a54cf44`, each with one planted red line in
`unanswered-sweep.tst.sh` (the pre-existing red of SPL-5640) and one in iac
`gh-box-token.tst.sh` (for 2.3).

- `abpp.sh` uses c-324's change set (`spl-dispatch-lease.func.sh`,
  `fleet-lease-nolocal-hold.tst.sh`), which selects 50 orc tests.
- Arm A runs the plan on the tree, then the whole plan again (today's
  re-check).
- Arm B runs the plan, then only the `FAILED:` files
  (`ORC_TEST_FILES=<failed> ORC_TEST_ALWAYS=`).
- `abpp-run.sh 5` starts A and B together each run; results go to
  `pp-runs.log`.

| run | A tree / base / total s | B tree / base / total s | load |
|---|---|---|---|
| 1 | 902 / 672 / 1,574 | 901 / **26** / 927 | 12.7..39.5 |
| 2 | 670 / 553 / 1,222 | 670 / **23** / 693 | 27.2..39.3 |

B's base re-check ran 1 file (A's ran 50) and named the same failure
(`FAIL: 99. planted pre-existing red`), so the verdict stays
WARN-pre-existing. Runs 3-5 were still running at the rotation.

### 2.3 Candidate row 02: the iac re-check the same way (prepared, not run)

`abiac.sh` / `abiac-run.sh 5` in the probe dir: arm A runs the iac suite
(fast tier) twice; arm B runs it once, then `IAC_TEST_ONLY=<failed>`.

### 2.4 Screened, no row (n=1, on `a8a54cf44`, `stamp.sh`)

- The five files p11 handed on (`lane-rotate`, `wd-fence`, `desk-move`,
  `orch-rotate`, `wd-self-update`): the largest single gap is 4.0..13.4 s,
  amid many 5..10 s case waits of the code under test; no wait stands out
  (`st-*.txt`).
- CI workflow 10, 11 green runs on master: wui e2e shards took 692..1,166 s
  and orc shards 581..1,054 s. The slowest shard differs from run to run, so
  a rebalance has no measured gain. Counted, not probed.

## 3. R3 reads

- Lane map, 09:24:37Z, `--check` on `check-pre-push.func.sh`, orc
  `run-all-tests.sh`, `changed-tests.sh`, the plan and this file,
  `--agent c-616` -> exit 4: 0 `owned by`, 8 `unknown:` (sat: c-193, c-197,
  c-326, c-433, c-513, c-664, c-762, g-293).
- Spawn queue, 09:24:50Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue` -> 8 queued, 0 placing. None of the 4 briefs readable
  here names a candidate file; the other 4 are on sat.
- Round rows, 09:26Z: r57-r59 and p7-p11 have all landed; there are no r60
  rows.
- Agent kinds, 09:24Z: `off [qwen], paused []`. `command -v agy grok vibe` on
  the desk box finds all three.

## 4. Next

1. Finish 2.2 (n=5) and run 2.3 (n=5) on `a8a54cf44`.
2. Draft `perf-round-12-plan.md`. Rows 01 (orc) and 02 (iac) both edit
   `check-pre-push.func.sh`, so they go in batch 1 and batch 2. Push it to
   `review/c002-perf-round-12-planner`.
3. Ask the holder for a grok seat and an agy seat on the desk box.
