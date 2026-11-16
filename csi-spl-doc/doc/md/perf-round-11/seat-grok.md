# Perf round 11 grok seat

Verdict: **REVIEW PASS** on `bd4b42a375e5080530fcb1b2c64e175b2950cdc7` (plan v0.2).

Panel: g-474, grok. Issue SPL-5672. Epic SPL-2402. Spec `csi-spl-doc/specs/027-spool-performance`.

Defects: none. N1 to N5 do not change the row shape, the file split, the red controls, or the direction of the measured gain.

## 1. Slug p11 unused

```
git fetch -q origin master
git rev-parse HEAD
git rev-parse origin/master
git branch --show-current
git status --porcelain | wc -l
git log origin/master --oneline -E --grep='\(p11-' | wc -l
git ls-remote origin 'refs/heads/*p11-*' | wc -l
git rev-parse bd4b42a375e5080530fcb1b2c64e175b2950cdc7
git ls-remote origin refs/heads/review/c002-perf-round-11-planner
git rev-list --count 6fcc711a9..origin/master
git merge-base --is-ancestor 6fcc711a9 origin/master
```

Printed, after the fetch that left `origin/master` at `827c62b796e42beeb428544ffe6aab115454e30e`:

```
HEAD=827c62b796e42beeb428544ffe6aab115454e30e
OM=827c62b796e42beeb428544ffe6aab115454e30e
BRANCH=g-474-c002-perf-round-11-grok-panel-seat
STATUS=0
P11=0
REFS=0
PLAN=bd4b42a375e5080530fcb1b2c64e175b2950cdc7
bd4b42a375e5080530fcb1b2c64e175b2950cdc7	refs/heads/review/c002-perf-round-11-planner
COUNT=8
```

`git merge-base --is-ancestor 6fcc711a9 origin/master` exited 0. The plan tip is the review ref above. `refs/heads/review/c002-perf-round-11-grok-seat` was absent at this read.

## 2. Sites at `6fcc711a9` and on origin/master

`git diff --name-status 6fcc711a9 origin/master` for `spl-standby-bench.tst.sh`, `wd-multi-daemon.tst.sh`, `spl-dispatch-lease.func.sh` and `fleet-lease.tst.sh` printed nothing (`NAMESTATUS_RC=0`).

`check-pre-push.func.sh` has one commit in that range:

```
8800fccb9 fix(iac, SPL-5607): pre-push orc part still runs the always-run list on a full plan
```

`diff` of lines 482-508 between `6fcc711a9` and `origin/master` printed nothing (`HYG-RANGE-IDENTICAL`). `_pp_part_hygiene` still starts at line 492.

`git show 6fcc711a9:<file> | nl -ba` (same lines on `origin/master` for the two test files, and for 482-508 of the hygiene part):

```
spl-standby-bench.tst.sh
177: # --- 8. CONTROL: the liveness check sees a live stub
179: sleep 30 | STUB_LOG=... "$T/stub/claude" --model x >/dev/null 2>&1 &
180: ctl=$!
183: kill "$ctl" 2>/dev/null; wait "$ctl" 2>/dev/null
185: # --- 9. ... vibe on PATH is skipped by its kind, never started

wd-multi-daemon.tst.sh
121: # settle [N]: wait (up to 30 s) until N detached restarts (default 1) have
124: # 37969307772: '4 S9:  /' after the S9 control's two restarts)
125: done_n() { ... }
126: settle() { wait_event 30 done_n "${1:-1}"; }
220: WD_JUDGE_LOCK=0 SIT_SLEEP=1 SEND_SLEEP=2 both 1 2; settle 2
238: settle 2
243: settle 3

check-pre-push.func.sh
482: # hygiene is ~1 s and cannot hang, so it runs directly (no timeout, no subshell).
484: # rides along: under a second, read-only, red when two rule copies disagree.
485: # So does the qto doc map check (SPL-2164): read-only, ~0.1 s, red when an
492: _pp_part_hygiene() {
498: HYGIENE_TREE="$1" HYGIENE_MSG_RANGES="$mr" do_check_dist_hygiene || rc=$?
501: ( source "$drift" && FLEET_RULES_TREE="$1" do_check_fleet_rules_drift ) || rc=1
505: ( source "$qto" && QTO_DRIFT_TREE="$1" QTO_DRIFT_LIVE=0 do_check_qto_doc_drift ) || rc=1
508: }
```

Row 01's edit is 177-183. Row 02's edit is line 220, and 121-126 if `settle` is rebuilt. Lines 238 and 243 are other `settle` calls in the same file. See N4.

## 3. Row shape

Three rows, all batch 1, all `claude / simple_coding`. No mistral coding or testing row. No path is in two rows:

- 01: `csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh`
- 02: `csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh`
- 03: `csi-spl-iac/src/bash/run/check-pre-push.func.sh` and the new `check-pre-push-hygiene-concurrent.tst.sh`

Each row names at most two edit ranges. Each baseline names a command, a number and n on `6fcc711a9`. Each row names a counting test whose red control fails on today's code (01: 1 `sleep` left; 02: `settle 2` on the runs with one restart, and a planted `settle 3` every run; 03: 1 check in flight) and passes on the fast code.

### Saved probe logs

`/var/tmp/c430-probe/ab-r01-*.res` walls, rc 0. Arm A: 55.2, 57.5, 52.4, 54.2, 54.0 (median 54.2, range 52.4..57.5). Arm B: 25.2, 29.0, 22.4, 27.1, 24.6 (median 25.2, range 22.4..29.0). Each `ab-r01-*.out` has `PASS=41` and `^FAIL:` count 0. The one line containing the word FAIL is `PASS: hung agent: FAIL, the agent is stopped`.

`/var/tmp/c430-probe/ab-r02-*.res` walls, rc 0. Arm A: 55.2, 26.2, 23.5, 51.9, 22.7 (median 26.2, mean 35.9). Arm B: 23.9, 26.2, 23.5, 21.9, 22.2 (median 23.5, mean 23.5). Each `ab-r02-*.out` has `PASS=31` and `^FAIL:` count 0.

`/var/tmp/c430-probe/wetimeouts.log` is 3 lines, all `wd-multi-daemon.tst.sh line=126 budget=30 cmd=done_n 2`.

`/var/tmp/c430-probe/hygab-7.txt` (7 lines): A 3813, 3766, 3359, 3391, 3088, 5558, 5129 (median 3766, range 3088..5558). B 2444, 2512, 1663, 2002, 1717, 1877, 2440 (median 2002, range 1663..2512). B below its paired A on all 7. Loads on those lines: 16.60..21.75.

## 4. Re-measure of p11-03

Read-only. `QTO_DRIFT_LIVE` left unset. n=5, odd runs sequential then parallel, even runs parallel then sequential. Tree `827c62b796e42beeb428544ffe6aab115454e30e`. `nproc` 16. Load 43.86..47.29.

```
HEAD 827c62b796e42beeb428544ffe6aab115454e30e
START 2026-11-16T04:37:16Z load 47.29 nproc 16
run 1 load 47.29 A 7843 B 2813 rcA 0 0 0 rcB 0 0 0
run 2 load 46.24 A 6482 B 3058 rcA 0 0 0 rcB 0 0 0
run 3 load 44.85 A 6553 B 3421 rcA 0 0 0 rcB 0 0 0
run 4 load 45.10 A 6368 B 3500 rcA 0 0 0 rcB 0 0 0
run 5 load 43.86 A 6125 B 4341 rcA 0 0 0 rcB 0 0 0
```

Sorted A `6125 6368 6482 6553 7843`, median 6482. Sorted B `2813 3058 3421 3500 4341`, median 3421. Drop 47.2%. B faster on 5 of 5. The ranges do not overlap.

Piece stdout, sequential vs parallel, same index: dist, fleet and qto each printed `SAME` on all 5 runs (692, 607 and 424 bytes). Every piece rc is 0.

The ratio agrees with the plan's hygab-7 drop (about 47%, B faster on every pair). The absolute medians are higher at this load (43.86..47.29 against the plan's 16.60..21.75). See N1.

The dist piece on run 1 exited 0. Its verdict lines were the eleven `ok` lines (org, personal name, OS user, home directory, mail address, hidden workspace, retired relay estate, no tracked `.vibe/` dir) and `INFO distribution-hygiene: clean`. The qto piece exited 0 and printed `WARN no private index: hand-copy check NOT RUN`. That is the non-live path (`QTO_DRIFT_LIVE` unset, and the part itself passes `QTO_DRIFT_LIVE=0`).

## 5. R3 lane map

After the remeasure:

```
lane-map.sh --check \
  csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh,\
  csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh,\
  csi-spl-iac/src/bash/run/check-pre-push.func.sh,\
  csi-spl-iac/src/bash/tests/check-pre-push-hygiene-concurrent.tst.sh \
  --agent g-474
```

Exit 4. Zero lines `owned by`. Fifteen `unknown:` lines, each "has no files recorded":

- c-193, c-197, c-664, c-762, g-293, g-412, g-414, g-416, g-425 (rotation)
- c-326 (`64ca-t10-fewer-rollouts-one-login`)
- c-426 (`64ca-t6-lease-real-outage`)
- c-428 (`64ca-t3-rotate-streak-per-role`)
- c-430 (`64ca-t4-lanemap-box-offline`)
- c-432 (`64ca-t5-review-seat-past-overflow`)
- c-433 (`64ca-t7-bench-back-one-post`)

Then `WARN no live lane lists <the four paths>, but 15 live lane(s) record no files` and `FATAL ... status 4`. Exit 4 is not free. The plan already requires a fresh map read before each spawn. See N3.

## 6. Hygiene

Section 4 records `do_check_dist_hygiene` on this tree before this file existed (rc 0, clean). After this file was staged, the same action in `csi-spl-iac` exited 0. The allowed-line counts stayed 9, 4 and 6, and the closing line was `INFO distribution-hygiene: clean`.

## Notes

N1. This seat's p11-03 remeasure (section 4) is n=5 at load 43.86..47.29. Plan hygab-7 is n=7 at load 16.60..21.75 (A median 3766 ms, B median 2002 ms). Both show about a 47% drop and B faster on every pair, with rc 0. The absolute milliseconds differ with the load. The row's direction holds.

N2. `8800fccb9` edits `check-pre-push.func.sh` below `_pp_part_hygiene`. Lines 482-508 are unchanged and unmoved (section 2). The lane still edits 492-508 and the comment at 482-486. The comment's "~1 s", "under a second" and "~0.1 s" are what the plan tells the lane to correct. hygab-7 piece times and this seat's run both sit above those three phrases.

N3. The plan's 02:45Z map listed 13 unknown lanes, including c-361, c-396 and rotation seats g-367, g-374, g-376, g-386, g-393. This read lists 15 (section 5). c-396 is absent. c-433 is live with slug `c002-64ca-t7-bench-back-one-post` and no files recorded, so row 01 waits on that lane until a fresh map says otherwise. The plan's own rule is that the holder re-reads the map and asks any lane that is still unknown.

N4. Row 02's probe arm B is `settle 1` on line 220. The plan states that arm is the measurement, and that the landed wait must keep the guard at 121-124. The n=5 median moves from 26.2 s to 23.5 s. The stated gain is the timeout tail: `wetimeouts.log` records three `done_n 2` budgets at line 126, which is the body of `settle`. Lines 238 (`settle 2`) and 243 (`settle 3`) are outside the row's edit and are not in that log.

N5. `hygab.sh` discards the combined stdout. This seat compared each piece's own stdout, sequential against overlapped, and all 15 compares were `SAME`. The part's print order (dist, then fleet-rules, then qto) and the folded rc are what `check-pre-push-hygiene-concurrent.tst.sh` is specified to prove. The three calls today are still sequential at 498-506, each with its own rc folded into `rc`.
