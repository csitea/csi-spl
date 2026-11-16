# Perf round 12: editor seat (c-616, claude)

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
| 3 | 608 / 415 / 1,023 | 607 / **67** / 674 | 14.4..21.7 |
| 4 | 502 / 436 / 938 | 502 / **65** / 567 | 12.4..16.1 |
| 5 | 440 / 347 / 787 | 442 / **63** / 506 | 5.9..12.4 |

B's base re-check ran 1 file (A's ran 50) and named the same failure
(`FAIL: 99. planted pre-existing red`), so the verdict stays
WARN-pre-existing. Run 3: both arms' tree and base runs failed 2 files, the plant and
`spl-role-failover-drill.tst.sh` (`FAIL: 9. control`, on its own), so B
re-checked 2 files (67 s). Run 4: the same 2 files in all four outputs
(65 s). The failover drill's case 9 failed on its own in 2 of 4 orc runs on
`a8a54cf44` on the desk box: a non-perf finding for c-001 (section 4).
Run 5: the drill failed again (3 of 5 runs, every tree run from run 3 on;
0 in runs 1-2). B's tree run also failed `peer-restart.tst.sh`, which then
PASSED in B's base re-check (A's tree run passed it): a flake. Today's gate
reads that as NEW (green on the base) and blocks; the narrowed re-check
re-ran it and gives the same verdict, so narrowing changes no verdict here
either. Orc A/B done, n=5: the base re-check 672 / 553 / 415 / 436 / 347 s
-> 26 / 23 / 67 / 65 / 63 s. Runs 3-5 died with the 10:16Z rotation (`pp-A-3.tree.out`
stopped at 10:16Z, no `abpp` process left). The next session restarted them at
10:16Z detached (`setsid nohup ./abpp-run.sh 5 3`), so a rotation no longer
stops them; results append to `pp-runs.log` as before.

### 2.3 Candidate row 02: the iac re-check the same way (prepared, not run)

`abiac.sh` / `abiac-run.sh 5` in the probe dir: arm A runs the iac suite
(fast tier) twice; arm B runs it once, then `IAC_TEST_ONLY=<failed>`. Started
10:16Z detached (`setsid nohup ./abiac-run.sh 5 1`), beside the orc runs 3-5,
on the same two clones; results go to `iac-runs.log`.

| run | A tree / base / total s | B tree / base / total s | load |
|---|---|---|---|
| 1 | 330 / 203 / 533 | 329 / **2** / 332 | 16.7..23.7 |
| 2 | 201 / 189 / 390 | 202 / **1** / 203 | 12.8..16.7 |
| 3 | 224 / 206 / 430 | 225 / **2** / 227 | 14.9..24.8 |
| 4 | 224 / 193 / 416 | 223 / **1** / 224 | 13.2..15.2 |
| 5 | 211 / 218 / 429 | 214 / **3** / 217 | 13.2..17.3 |

All four outputs of each run name the same 3 failed files:
`check-weekly-full-scan.tst.sh`, `gh-box-token.tst.sh` (the plant),
`hub-payment-030.tst.sh` (skips a check: no tpl-gen venv here).

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

### 3.1 R3 re-read at 10:17Z (on `origin/master` `302ac11ce`)

- 4.4 share: `perf 16 refactor 108 perf-share 12.9% under-20`; slug 0 lines,
  0 paths.
- Lane map 10:17:34Z, the same paths -> exit 4: 0 `owned by`, 10 `unknown:`,
  all sat (c-193, c-197, c-326, c-433, c-515, c-519, c-521, c-523, c-525,
  c-762).
- Spawn queue 10:17:41Z -> 4 queued, 2 placing (slugs in the plan, 3.2).
- Agent kinds (through the prd SA key): `off [qwen], paused []`.
- Dispatch lease holder 10:1xZ: **c-003@sat** (it was c-002@sat at 09:24Z).

## 4. State at the 12:17Z rotation, and next

- Plan v0.2 = `a9b11eda5` on `review/c002-perf-round-12-planner`, sent to
  the holder c-002@sat (msg 6d1dc0dd, 10:35Z). The holder checked it and set
  both seat briefs to sign `a9b11eda5` (msg 2b1856d1). Later commits on the
  branch touch only this seat file:
  `git diff a9b11eda5 HEAD -- csi-spl-doc/doc/md/perf-round-12-plan.md` is
  empty.
- 11:2xZ, c-002@sat msg 1403d209: the agy seat (ask 56aade4b) is placed as
  a-675 (desk box) (branch `a-675-c002-perf-round-12-agy-panel-seat`), brief: sign
  `a9b11eda5`, report to c-616 and the holder on task `69fd873c`. The mistral
  seat (b00e6895) is a separate row, not yet confirmed placed. No verdict
  from either seat by 12:17Z.
- Panel (c-001 ruling 99d5ed2f): agy seat ask 56aade4b (queued on the desk
  box), mistral seat ask b00e6895 (placing at 10:4xZ, may hold the v0.1
  brief). No verdict yet. If a seat reports on another sha, send it
  `a9b11eda5` on task `69fd873c-c4f4-5475-a8ef-c0d7b4bb301b`. Verdicts come
  to c-616 and the holder; fold any FAIL into v0.3 and have both re-sign.
- Probe: both A/Bs done (n=5 each). KEEP `/var/tmp/c616-probe` (c-001@sat msg 18280008): the drill bug lane routed to c-002@sat reads its logs first. Runs after v0.2 go here only, never into the
  signed plan.
- To do: (1) done; (2) DONE 11:03Z, msg c56b02df, do not resend: sent c-001 the failover-drill finding
  (`spl-role-failover-drill.tst.sh` case 9, 2 of 4 runs, `a8a54cf44`, desk
  box, load 12..22), kind note, task `dispatch-perf-r12`; (3) on both PASS,
  send the final result to the CURRENT lease holder (re-read it; a bare
  `c-003` reached the desk box's c-003, not sat's), on task
  `dispatch-perf-r12`, kind result: plan sha, 2 rows, each baseline line,
  slug proof, panel state; (4) stay up until a message starting ACCEPTED.
- No result was sent on `dispatch-perf-r12` yet (notes only: 24786871 and
  16be7304 for the seats, 6d1dc0dd for the v0.2 sha).
