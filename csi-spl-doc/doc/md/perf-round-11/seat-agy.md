# Perf round 11: agy panel seat (a-483)

Verdict: **PASS** on `1f61f039db0d5ff83482c42cff2ccf51de036256` (plan v0.3),
section 9 (`W1`–`W3` and `N1`–`N3` all verified fixed, zero open defects, one
non-blocking implementation note `N4`). Sections 0 to 8 are the v0.2 review:

Verdict: **FAIL** on `bd4b42a375e5080530fcb1b2c64e175b2950cdc7` (plan v0.2), three
defects (`W1` on row 01's `wait "$ctl"` mechanism and non-failing C2 red control,
`W2` on row 02's racy `$T/takeovers` count option and `settle ... || fail` site-cap
conflict, `W3` on row 03's in-process signal trap interaction and missing probe
output-identity check), all fixable in the plan text before v1.0.

Panel: `a-483` (agy on the desk box, cross-vendor to editor `c-430` claude; the
panel's other seat is grok on `review/c002-perf-round-11-grok-seat`). Issue:
SPL-5672. Epic: SPL-2402. Spec: `csi-spl-doc/specs/027-spool-performance`. Read on
2026-11-16, `origin/master` `6fa92dbbb9d1a53014b90f4f36e1242567274f44`.

## 0. The sha read

```text
git fetch origin review/c002-perf-round-11-planner && git rev-parse FETCH_HEAD
git rev-parse origin/master
git log --oneline --stat 6fcc711a9..bd4b42a375e5080530fcb1b2c64e175b2950cdc7
```

Printed:

```text
bd4b42a375e5080530fcb1b2c64e175b2950cdc7
6fa92dbbb9d1a53014b90f4f36e1242567274f44
bd4b42a37 docs(p11-plan, SPL-5672): perf round 11 plan v0.2, the measurement window is 02:44Z-02:51Z
 csi-spl-doc/doc/md/perf-round-11-plan.md   | 9 ++++++---
 csi-spl-doc/doc/md/perf-round-11/editor.md | 2 +-
 2 files changed, 7 insertions(+), 4 deletions(-)
58259bf73 docs(p11-plan, SPL-5672): perf round 11 plan v0.1, 3 rows measured on 6fcc711a9
 csi-spl-doc/doc/md/perf-round-11-plan.md   | 293 +++++++++++++++++++++++++++++
 csi-spl-doc/doc/md/perf-round-11/editor.md | 262 ++++++++++++++++++++++++++
 2 files changed, 555 insertions(+)
```

Ancestors, screening diffs, and retro status cited in the plan header
(`perf-round-11-plan.md:33-60`):

```text
for s in 6fcc711a9 76f65baee fed9fb69d 97f4df672 70743821c 4e933d2c5 fd3b0c647 f24802938 8a960d204 0d5d699d6; do
  git merge-base --is-ancestor "$s" origin/master && echo "$s ancestor=yes"
done
git diff --stat fed9fb69d 6fcc711a9
git diff --stat 76f65baee 6fcc711a9 -- \
  csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh \
  csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh \
  csi-spl-iac/src/bash/run/check-pre-push.func.sh
git ls-tree -r --name-only origin/master | /usr/bin/grep -cE 'perf-round-(9|10)-retro' || true
```

Printed `ancestor=yes` for all ten shas, `internal/hub/live_ack_test.go | 37 +++++--`
only for `fed9fb69d..6fcc711a9`, empty diff on the three row files for
`76f65baee..6fcc711a9`, and `0` for `perf-round-(9|10)-retro`.

## 1. Slug p11 unused

```text
git log origin/master --oneline -E --grep='\(p11-' | wc -l
git ls-remote origin 'refs/heads/*p11-*' | wc -l
git ls-tree -r --name-only origin/master | /usr/bin/grep -c perf-round-11 || true
```

Printed:

```text
0
0
0
```

## 2. Row sites at `6fcc711a9` and on `origin/master` (`6fa92dbbb`)

Diff of the row files and `wait-event.inc.sh` from `6fcc711a9` to `origin/master`
(`6fa92dbbb`, 10 commits ahead of `6fcc711a9`):

```text
git diff --stat 6fcc711a9 origin/master -- \
  csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh \
  csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh \
  csi-spl-iac/src/bash/run/check-pre-push.func.sh \
  csi-spl-iac/src/bash/tests/check-pre-push.tst.sh \
  csi-spl-orc/src/bash/tests/wait-event.inc.sh
git diff -U0 6fcc711a9 origin/master -- csi-spl-iac/src/bash/run/check-pre-push.func.sh | /usr/bin/grep '^@@'
```

Printed:

```text
 csi-spl-iac/src/bash/run/check-pre-push.func.sh  | 33 +++++++++++++++++++++---
 csi-spl-iac/src/bash/tests/check-pre-push.tst.sh | 25 ++++++++++++++++++
 2 files changed, 54 insertions(+), 4 deletions(-)
@@ -638,2 +638,27 @@ _pp_part_iac() {
@@ -655,2 +680,2 @@ _pp_part_orc() {  # <tree>
```

`spl-standby-bench.tst.sh` and `wd-multi-daemon.tst.sh` are unchanged (`0` lines);
`check-pre-push.func.sh` changed only at `:638+` (`8800fccb9`, `_pp_orc_always` /
`_pp_part_orc`), below `:482-508`. **Zero row sites drifted** between `6fcc711a9`
and `6fa92dbbb`.

Every `file:line` cited in `perf-round-11-plan.md` and `perf-round-11/editor.md`
checked with `git show <rev>:<file> | sed -n '<N>p'` at both `6fcc711a9` and
`origin/master` (`6fa92dbbb`):

```text
for rev in 6fcc711a9 origin/master; do
  git show "$rev:csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh" | sed -n '177,183p'
  git show "$rev:csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh" | sed -n '121,126p;218,222p'
  git show "$rev:csi-spl-iac/src/bash/run/check-pre-push.func.sh" | sed -n '482,486p;492,508p'
  git show "$rev:csi-spl-orc/src/bash/tests/dispatch-rotate.tst.sh" | sed -n '477,479p'
  git show "$rev:csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh" | sed -n '104,108p'
done
```

Printed (identical at `6fcc711a9` and `6fa92dbbb`):

| cite | what `git show <rev>:<file> \| sed -n` printed | match? |
|---|---|---|
| `spl-standby-bench.tst.sh:177-183` | `# --- 8. CONTROL: the liveness check sees a live stub ---` .. `kill "$ctl" 2>/dev/null; wait "$ctl" 2>/dev/null` | yes |
| `wd-multi-daemon.tst.sh:121-124` | `# settle [N]: wait (up to 30 s) ... (gate 10 run 37969307772: '4 S9:  /' after the S9 control's two restarts)` | yes |
| `wd-multi-daemon.tst.sh:125-126` | `done_n() { ... }` and `settle() { wait_event 30 done_n "${1:-1}"; }` | yes |
| `wd-multi-daemon.tst.sh:218-222` | `reset_box; agent c-952 %1 4052` .. `WD_JUDGE_LOCK=0 SIT_SLEEP=1 SEND_SLEEP=2 both 1 2; settle 2` (`:220`) .. `fail "4 S9 control..."` | yes |
| `check-pre-push.func.sh:482-486` | `# hygiene is ~1 s and cannot hang ... under a second ... ~0.1 s ...` | yes |
| `check-pre-push.func.sh:492-508` | `_pp_part_hygiene() {` .. `return "$rc"` / `}`, with the two drift blocks at `:499-506` | yes |
| `dispatch-rotate.tst.sh:477-479` | `# in flight once the ctx holds both ... 15 s: the rotation's real ack wait outlasts the two acks below under load.` | yes |
| `spl-rotate-lib.func.sh:104-108` | whole-number validation loop including `ROTATE_POLL` + `(( ROTATE_POLL > 0 ))` | yes |

## 3. Row shape, R1, vendor rule, probe backing, and R3 overlap handling

| row | sites (cap 5) | baseline cmd + number + n | counting test + red control (4.1, C2) | vendor / kind / batch |
|---|---|---|---|---|
| 01 `p11-01` | 1 file, 1 range (`spl-standby-bench.tst.sh:177-183`) | `abpair.sh spl-standby-bench.tst.sh` arm A (`editor.md:149-164`), **54.2 s** median (`52.4..57.5`), `n=5` | `spl-standby-bench.tst.sh` end-of-case-8 `sleep` check — **broken on today's code (`W1`)** | `claude` / `simple_coding` / `1, after R3` |
| 02 `p11-02` | 1 file, `<= 2` ranges (`wd-multi-daemon.tst.sh:220`, `:121-126`) | `abpair.sh wd-multi-daemon.tst.sh` arm A (`editor.md:175-192`), **26.2 s** median, **35.9 s** mean (`22.7..55.2`), `n=5` (`8/12` runs timeout across `2.2, 2.4, 2.6`) | `settle` timeout `fail` (`0` timeouts over `n=5` vs deterministic `settle 3` plant) — **call-site edit conflicts with 2-range cap (`W2.2`), and `:198` `$T/takeovers` option races (`W2.1`)** | `claude` / `simple_coding` / `1, after R3` |
| 03 `p11-03` | 1 edited file, 1 contiguous block (`check-pre-push.func.sh:482-508`) + 1 new test file | `hygab.sh <worktree> 7` arm A (`editor.md:212-229`), **3,766 ms** median (`3,088..5,558`), `n=7` | new `check-pre-push-hygiene-concurrent.tst.sh` (`3` in flight, `0` timeouts vs `1` in flight on serial; drift-red order + `rc=1`; `TERM` cleanup) — **in-process trap hazard (`W3.1`)** | `claude` / `simple_coding` (R9) / `1, after R3` |

- **Sites cap (`<= 5`):** met as written (`1`, `2`, `2`), subject to `W2.2` on Row 02.
- **Disjoint files (R1):** met (`spl-standby-bench.tst.sh`; `wd-multi-daemon.tst.sh`; `check-pre-push.func.sh` + `check-pre-push-hygiene-concurrent.tst.sh` — `0` shared paths).
- **No mistral coding or testing rows:** met (`claude / simple_coding` for all 3 rows; `grok` primary reviewer, `agy` or second `grok` backup, mistral code reviews kept paused: `perf-round-11-plan.md:24-25,116-118,230-245`).
- **"Output stays the same" probe backing:**
  - **Row 01:** backed by `editor.md:152-164` (`41` `PASS` lines and `rc 0` in 5 of 5 runs of both arms).
  - **Row 02:** backed by `editor.md:177-186` (`31` `PASS` lines and `rc 0` in 5 of 5 runs of both arms).
  - **Row 03:** **not backed by a stdout comparison in `editor.md:212-232` (`W3.2`)** — `hygab.sh` ran three `./run` invocations and checked only `rc 0` (`editor.md:230`: *"All pieces rc 0 in both arms. The probe times the whole pieces through `./run`. The part sources the two drift files in subshells instead."*). Independently verified in section 4 below (`25/25` lines byte-identical `7/7` on clean runs and `6/6` on clean/failure/unknown-base cases).
- **R3 re-check (`64ca-t7`, `64ca-t9`, `c-396`, and open round rows) and whether the plan handles them:**
  ```text
  git grep -l 'spl_fleet_bench_tick' origin/master
  git show --stat --oneline -s 9499333c1
  git log origin/master --oneline -E --grep='\((r57|r58|r59|r60|p10|p11)-[0-9]{2}-' | head -n 5
  ```
  Printed:
  ```text
  origin/master:csi-spl-doc/doc/md/alerts-fix-round-plan.md
  origin/master:csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh
  origin/master:csi-spl-orc/src/bash/tests/fleet-lease.tst.sh
  9499333c1 fix(iac, SPL-5669): an unreadable feature test makes the pre-push plan run every orc feature
   csi-spl-doc/doc/md/pre-push-gate.md                   |  5 ++++-
   .../src/bash/run/check-pre-push-features.func.sh      | 19 +++++++++++++------
   .../src/bash/tests/check-pre-push-features.tst.sh     | 16 ++++++++++++++++
   3 files changed, 33 insertions(+), 7 deletions(-)
  c1a54b63f test(r58-08-drop-gate-lines-of-r58, SPL-5674): both clean code gates drop the five stale entries rows 01-04 left
  76f65baee test(r57-06-drop-wide-lines-of-r57, SPL-5647): both clean code gates drop the seven wide entries rows 01-05 left
  4e933d2c5 perf(p10-02-iac-cleancode-walk-one-awk, SPL-5636): bash clean-code gate measures every file with one awk
  76990f6cc refactor(r57-05-wui-pin-card-move-object, SPL-5622): pin the drop and start steps; useCardMove takes one object
  70743821c perf(p10-01-ci-hygiene-sweeps-concurrent, SPL-5631): run the seven hygiene sweeps of wf10's Sweep step at once
  ```
  1. **`64ca-t7` (ask `2f9a191e`):** now live on `sat` as `c-433@sat` (`c-433-c002-64ca-t7-bench-back-one-post`, section 7 below). Its brief (`c-002@sat` read at `03:00:06Z`) targets `spl-dispatch-lease.func.sh` (`spl_fleet_bench_tick`) and its test; `git grep -l spl_fleet_bench_tick origin/master` confirms the only test naming `spl_fleet_bench_tick` is `fleet-lease.tst.sh`, disjoint from Row 01's `spl-standby-bench.tst.sh`.
  2. **`64ca-t9` (ask `64c788e8`):** adds a read-only `csi-spl-utl/src/bash/run/` action, its test, and `cnf` only (`c-002@sat` read at `03:00:06Z`), disjoint from all three rows.
  3. **`c-396` (`SPL-5669`, reviewed at `d2087b210`):** now **landed on `origin/master` as `9499333c1`**, touching only `pre-push-gate.md`, `check-pre-push-features.func.sh`, and `check-pre-push-features.tst.sh` (not `check-pre-push.func.sh`), and no longer in `lane-map.sh`. `r58-08` has also landed (`c1a54b63f`).
  4. **Does the plan handle them?** **Yes:** all three rows carry `1, after R3` in their batch cell (`:112-114`), and section 3.2 (`:145-168`) requires re-reading `lane-map.sh --check`, asking any still-`unknown:` lane, and verifying `64ca-t7` / `64ca-t9` on `sat` before spawning. Note `N2` below updates section 3.2 and `:112,114` for `9499333c1`, `c1a54b63f`, and `c-433@sat`.

## 4. Re-measurement of Row 03 (`p11-03`, read-only, `n=7` and `n=5`)

First verified zero diff between `6fcc711a9` and `<this worktree>` (`827c62b79`) on
all files read by `_pp_part_hygiene`:

```text
git diff --stat 6fcc711a9 HEAD -- \
  .github/workflows/10_ci-quality.yml \
  csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh \
  csi-spl-iac/src/bash/run/check-commit-msg-hygiene.func.sh \
  csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh \
  csi-spl-orc/src/bash/run/check-qto-doc-drift.func.sh \
  csi-spl-orc/src/bash/run/check-qto-doc-drift.py \
  csi-spl-orc/src/bash/run/qto-private-index.py
```

Printed nothing (`0` lines changed).

Read-only measurement (`bash <scratch>/probe_p11_03.sh`, no prd access), interleaving
`AB` on odd runs and `BA` on even runs in two modes: (1) the real in-process
`_pp_part_hygiene` (`check-pre-push.func.sh:492-508`) vs `_pp_part_hygiene_b` (both
drift subshells started first into `$d/1.out`+`$d/1.rc` and `$d/2.out`+`$d/2.rc`
under `mktemp -d`, `do_check_dist_hygiene` in foreground, `wait`, `cat` in order),
`n=7`; and (2) the three `./run` actions matching `editor.md:212-230` (`hygab.sh`)
with `RUN_LOG_EPOCH=1800000000` and ordered output replay, `n=5`:

```text
=== 1. In-process _pp_part_hygiene A vs B, n=7 interleaved ===
run 1 load=16.09 A=3091ms(rc=0,lines=25,sha=f217040e) B=1771ms(rc=0,lines=25,sha=f217040e) eq=yes
run 2 load=15.92 A=2753ms(rc=0,lines=25,sha=f217040e) B=1865ms(rc=0,lines=25,sha=f217040e) eq=yes
run 3 load=15.92 A=2796ms(rc=0,lines=25,sha=f217040e) B=1863ms(rc=0,lines=25,sha=f217040e) eq=yes
run 4 load=15.60 A=2926ms(rc=0,lines=25,sha=f217040e) B=1905ms(rc=0,lines=25,sha=f217040e) eq=yes
run 5 load=16.68 A=3654ms(rc=0,lines=25,sha=f217040e) B=3110ms(rc=0,lines=25,sha=f217040e) eq=yes
run 6 load=22.43 A=4214ms(rc=0,lines=25,sha=f217040e) B=2729ms(rc=0,lines=25,sha=f217040e) eq=yes
run 7 load=24.15 A=2948ms(rc=0,lines=25,sha=f217040e) B=1899ms(rc=0,lines=25,sha=f217040e) eq=yes
=== 2. ./run three-piece probe (matching editor hygab.sh + ordered output), n=5 interleaved ===
run 1 load=23.34 A=3630ms(rc=0) B=2014ms(rc=0) norm_eq=yes
run 2 load=22.59 A=3609ms(rc=0) B=2041ms(rc=0) norm_eq=yes
run 3 load=21.66 A=4989ms(rc=0) B=2305ms(rc=0) norm_eq=yes
run 4 load=25.54 A=3564ms(rc=0) B=1943ms(rc=0) norm_eq=yes
run 5 load=24.37 A=3337ms(rc=0) B=1786ms(rc=0) norm_eq=yes
```

Failure-order, exit-code, and unknown-base parity across 6 fixture cases
(`bash <scratch>/probe_p11_03_fail.sh`):

```text
case=clean rcA=0 rcB=0 out_eq=yes lines=DIST_LINE tree=<tmp>/repo mr=origin/master..HEAD fail=0|DRIFT_LINE tree=<tmp>/repo fail=0|QTO_LINE tree=<tmp>/repo live=0 fail=0
case=drift_fail rcA=1 rcB=1 out_eq=yes lines=DIST_LINE tree=<tmp>/repo mr=origin/master..HEAD fail=0|DRIFT_LINE tree=<tmp>/repo fail=1|QTO_LINE tree=<tmp>/repo live=0 fail=0
case=qto_fail rcA=1 rcB=1 out_eq=yes lines=DIST_LINE tree=<tmp>/repo mr=origin/master..HEAD fail=0|DRIFT_LINE tree=<tmp>/repo fail=0|QTO_LINE tree=<tmp>/repo live=0 fail=1
case=dist2_only rcA=2 rcB=2 out_eq=yes lines=DIST_LINE tree=<tmp>/repo mr=origin/master..HEAD fail=1|DRIFT_LINE tree=<tmp>/repo fail=0|QTO_LINE tree=<tmp>/repo live=0 fail=0
case=dist2_and_drift rcA=1 rcB=1 out_eq=yes lines=DIST_LINE tree=<tmp>/repo mr=origin/master..HEAD fail=1|DRIFT_LINE tree=<tmp>/repo fail=1|QTO_LINE tree=<tmp>/repo live=0 fail=0
case=nobase rcA=0 rcB=0 out_eq=yes lines=hygiene: WARN unknown base 'no-such-ref' -- no outgoing commit messages swept|DIST_LINE tree=<tmp>/repo mr= fail=0|DRIFT_LINE tree=<tmp>/repo fail=0|QTO_LINE tree=<tmp>/repo live=0 fail=0
```

- **Agreement with plan numbers:** **Yes.** Through `./run` (`n=5`), Arm A median is
  **3,609 ms** (`3,337..4,989`) vs Arm B **2,014 ms** (`1,786..2,305`), **-44.2%**
  (5 of 5 faster, non-overlapping ranges), closely matching the plan's
  `3,766 ms -> 2,002 ms (-47%)`. In-process inside `_pp_part_hygiene` (`n=7`, no
  extra `./run` startup on the two drift subshells), Arm A median is **2,948 ms**
  (`2,753..4,214`) vs Arm B **1,899 ms** (`1,771..3,110`), **-35.6%** (`~1.05 s`
  saved per run, 7 of 7 faster).
- **Output identity:** **Yes — identical.** `25` lines byte-for-byte identical
  (`sha256` `f217040e`) in 7 of 7 in-process runs, `5/5` normalized-identical through
  `./run`, and `6/6` byte-identical across clean, drift-fail, qto-fail, dist-fail,
  combined-fail, and unknown-base cases.

## 5. Defects

- **W1, row 01 (`perf-round-11-plan.md:112`, `:181-189`; `perf-round-11/editor.md:143-146`):
  `wait "$ctl"` on `:183` already waits out `sleep 30` inside case 8, so the specified
  end-of-case-8 C2 assertion sees `0` `sleep` children on today's code (never turns
  RED), and case 9's `$(bench ...)` waits on nothing from case 8 (C5 hazard).**
  In `csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh:179-183`:
  `sleep 30 | ... "$T/stub/claude" --model x >/dev/null 2>&1 &` (`ctl=$!`) prints
  `PASS: CONTROL: a live stub is seen` on `:182` and then runs
  `kill "$ctl" 2>/dev/null; wait "$ctl" 2>/dev/null` on `:183`. In GNU bash
  (`5.2.37`), `kill "$ctl"` kills only the last pipeline process (`$T/stub/claude`),
  and `wait "$ctl"` then blocks on the **whole background pipeline job** until
  `sleep 30` exits — right on `:183`, *between* `:182`'s `PASS` line and case 9's
  `PASS` line (`:188`), which is why `stamp.sh` showed the 30 s gap before case 9.
  Verified with a scaled 3 s reproduction (`bash <scratch>/probe_r01.sh`):
  ```text
  bash <scratch>/probe_r01.sh
  ```
  Printed:
  ```text
  GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  t_before_kill_wait=0.10
  sleep_between_kill_and_wait=1
  t_after_wait=3.00
  sleep_after_wait=0
  ```
  Consequently: (1) an assertion *"at the end of case 8"* (after `:183`'s `wait`)
  checking `pgrep -P $$ -x sleep` or `env_idle` (`:112`) reads `0` on today's code
  (`sleep_after_wait=0`) and passes after 30 s instead of failing RED; and (2)
  instructing the lane (`:188-189`) to *"find what case 9's `$(bench ...)` waits on
  and name it in the comment above case 8"* asks for a comment describing behaviour
  the code does not perform (R7 C5).
  **Fix in the plan:** state in `:112` and `:181-189` (and `editor.md:143-146`) that
  `:183`'s `wait "$ctl"` blocks 30 s on the pipeline's unkilled `sleep 30` after
  `:182`'s `pass`, and place the C2 process check **between case 8's stop step and
  `wait`** (e.g. `wait_event 2 eval '[[ -z "$(pgrep -P $$ -x sleep)" ]]'` right after
  `kill`, cleaning up on failure -> `0` left / `PASS` when both pids are stopped or a
  fifo fd holds stdin with no `sleep`, vs `1` `sleep` alive / `FAIL` in 2 s on
  today's `kill "$ctl"` alone).

- **W2, row 02 (`perf-round-11-plan.md:113`, `:196-204`): `:198`'s second fix option
  (`settle` on the case's `takeover` line count) races the detached child and breaks
  the `:121-124` guard, and `:113`'s per-call `settle ... || fail` exceeds `:113`'s
  `at most 2 edit ranges` cap.**
  1. **Racy `$T/takeovers` count (`:198`):** in `wd-multi-daemon.tst.sh:59-67`,
     `echo "takeover $ID $REASON" >> "$T/takeovers"` (`:61`) runs inside the
     **detached `setsid $WD_TAKEOVER_CMD` child** (`spl-watchdog.func.sh:1711`), not
     synchronously before `both 1 2` returns at `:220`. Under load, when `both 1 2`
     returns, 0 (or 1 of 2) detached children may have reached `:61`: `settle` on
     `$T/takeovers`'s count then sees `0` (`done_n 0` passes at once) or `1` while a
     second detached `takeover` is still running across `reset_box` (`:223`),
     re-opening gate 10 failure `37969307772` (`:121-124`). By contrast,
     `spl_wd_log "TAKEOVER $id $code ..."` (`spl-watchdog.func.sh:1709`, in
     `$D/wd.log`) is written synchronously *before* `setsid` forks (`:1711`), and
     `env_idle "SPOOL_ROOT=$S"` (`wait-event.inc.sh:35`, `wd_env` at `:104`) waits
     until every process carrying `$S` in `/proc/[0-9]*/environ` has exited.
  2. **Edit-range count (`:113`):** `wd-multi-daemon.tst.sh` calls `settle` at five
     sites across three non-adjacent sections (`:197`, `:220`, `:225`, `:238`,
     `:243`) plus its definition at `:126`. Rewriting each call site as
     `settle ... || fail "<case>: settle timed out"` (`:113`) touches 4–6 edit
     ranges, violating `:113`'s `at most 2 edit ranges` under R7 C1. Putting
     `|| fail "settle ${1:-1} timed out"` inside `settle()` at `:126` covers every
     `settle` call in the file within the 2 ranges (`:121-126` and `:220`).
  **Fix in the plan:** in `:196-198`, drop `$T/takeovers` as the count source in
  favour of `wait_event 30 env_idle "SPOOL_ROOT=$S"` (or `settle "$launched"` from
  `$D/wd.log`'s synchronous `TAKEOVER c-952 S9` lines with `(( launched >= 1 ))`, or
  both); in `:113`, specify that `settle()` at `:126` (and any `env_idle` wait at
  `:220`) calls `fail` on timeout so only `:121-126` and `:220` (`2` ranges) change.

- **W3, row 03 (`perf-round-11-plan.md:114`, `:218-219`; `perf-round-11/editor.md:212-232`):
  copying `p10-01`'s `Sweep` signal/exit traps into `_pp_part_hygiene` breaks
  in-process caller traps or leaves drift child processes alive, and `editor.md`
  lacks a stdout-identity check on `_pp_part_hygiene`.**
  1. **In-process function vs standalone script (`:218-219`, `:114`):** `p10-01`
     (`70743821c`) runs inside `bash "$tmp/sweep.sh"` (its own process) and sets
     `trap sweep_exit EXIT` plus `trap 'sweep_stop ...' HUP INT TERM`. By contrast,
     `_pp_part_hygiene` is called **in-process** by `_pp_capture`
     (`check-pre-push.func.sh:1083`) inside `_pp_run_parts` (`:1307-1329`). Probed
     both naive translations in GNU bash `5.2.37` (`bash <scratch>/probe_r03_term.sh`
     and `probe_r03_term2.sh`):
     ```text
     bash <scratch>/probe_r03_term.sh
     bash <scratch>/probe_r03_term2.sh
     ```
     Printed:
     ```text
     naive: rc=143 elapsed=0.15s dir_exists=yes drift_children_alive=2
     caller_trap_after_bad=''
     fg_sleep_kill_parent_only: rc=143 elapsed=1.51s dir_exists=no drift_grandchildren_alive=2
     ```
     - Wrapping `_pp_part_hygiene` in `( ... )` causes `_pp_part_hygiene "$tree" & p=$!; kill -TERM "$p"` (`:114`) to kill only the outer subshell `$p`, stranding `$d` and both drift jobs (`dir_exists=yes drift_children_alive=2`).
     - Setting `trap ... EXIT` in-process clobbers the caller's `EXIT` trap (`check-pre-push-errexit.tst.sh:56`, `check-pre-push-override.tst.sh:33`, `check-commit-msg-hygiene.tst.sh:36`), and `trap - HUP INT TERM` on return wipes `_pp_run_parts`'s `INT`/`TERM`/`HUP` cleanup traps (`:1309-1313`, `caller_trap_after_bad=''`).
     - `kill "$j1" "$j2"` on the two `( source ... ) &` subshells leaves their child processes (`python3` in `check-qto-doc-drift.func.sh:78,89` or a barrier stub's `sleep`) running (`drift_grandchildren_alive=2`), and bash defers `TERM` while waiting on a foreground external process (`elapsed=1.51s`) unless the process tree is signalled (as `do_stop_pre_push` does via `_pp_proc_tree`, `stop-pre-push.func.sh:25,59`).
  2. **Probe output-identity backing (`editor.md:212-232`):** `hygab.sh` timed
     `./run` calls and recorded `rc 0` only, without comparing stdout or running
     `_pp_part_hygiene`.
  **Fix in the plan:** in `:218-219` and `:114`, specify that `_pp_part_hygiene`
  stays in-process (no outer subshell, no `EXIT` trap), saves and restores
  `$(trap -p HUP INT TERM)`, tracks explicit pids `j1`/`j2` (never `jobs -p`), kills
  each drift job's descendant tree (`_pp_proc_tree` or child walk) and removes `$d`
  before restoring/chaining the caller's signal handler, and that
  `check-pre-push-hygiene-concurrent.tst.sh`'s `TERM` case signals `_pp_proc_tree`
  (or uses an interruptible foreground stub `sleep 30 & wait $!`); record an
  `_pp_part_hygiene` stdout-equality check in `editor.md`.

## 6. Notes

- **N1 (row 03 R2 test column & helper naming, `:114`):** under rulebook R2 (`2.2`),
  `check-pre-push-budget-table.tst.sh` (`:39`, `:98`), `check-pre-push-verdict-forks.tst.sh`
  (`:73`), `check-pre-push-pnpm-noninteractive.tst.sh` (`:95`), and `bash-cleancode.tst.sh`
  (`MAX_LINES=75`) also inspect `check-pre-push.func.sh` (alongside
  `**check-pre-push-errexit.tst.sh**` `:88` and `**check-pre-push-orphan-pipe.tst.sh**`
  `:41`, bold per R2), and `check-pre-push-tree-pass.tst.sh` (`:41`) +
  `stop-pre-push.tst.sh` exercise gate hashing and `TERM` tree-stop. Note in
  particular that `check-pre-push-budget-table.tst.sh:39` enumerates every function
  matching `^_pp_part_`, so any helper added for Row 03 must be named `_pp_hygiene_*`,
  never `_pp_part_hygiene_*`.
- **N2 (section 3.2 & `:112,114` R3 state on `6fa92dbbb`):** `c-396` (`SPL-5669`) has
  landed as `9499333c1` (disjoint from `check-pre-push.func.sh`) and left `lane-map.sh`;
  `r58-08` (`SPL-5674`) has landed as `c1a54b63f`; and `64ca-t7` (ask `2f9a191e`) is
  now live on `sat` as `c-433@sat` (`spl-dispatch-lease.func.sh` + `fleet-lease.tst.sh`
  per `c-002@sat`'s `03:00:06Z` read). Refreshing `:112`, `:114`, and section 3.2 in
  v1.0 avoids sending Row 03's lane to ask a retired `c-396`.
- **N3 (consensus table & in-process vs `./run` baseline):** `perf-round-11-plan.md:294`
  still lists `v0.1` on the `c-430 (editor)` row while `:27` and `:285` are `v0.2`.
  Also note in Row 03 (`:224-225`) that `hygab.sh` (`3,766 -> 2,002 ms`) includes
  `./run` startup on the two drift pieces, whereas in-process `_pp_part_hygiene`
  measures `2,948 -> 1,899 ms` (`-35.6%`, section 4 above).

## 7. R3 lane-map check

```text
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh \
  --check csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh,csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh,csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-iac/src/bash/tests/check-pre-push-hygiene-concurrent.tst.sh,csi-spl-doc/doc/md/perf-round-11/seat-agy.md \
  --agent a-483
```

Printed (04:50:57Z): `EXIT=4`, `0` lines `owned by` (no owning lanes on the row paths
or `seat-agy.md`), and `15` `unknown:` lanes on `sat` (`c-193`, `c-197`, `c-326`,
`c-426`, `c-428`, `c-430`, `c-432`, `c-433` `64ca-t7-bench-back-one-post`, `c-664`,
`c-762`, `g-293`, `g-412`, `g-414`, `g-416`, `g-425`), ending:
`WARN no live lane lists <the five paths>, but 15 live lane(s) record no files: their scope is unknown, not free`.
(Including `csi-spl-doc/doc/md/perf-round-11-plan.md` exits `3`, naming `c-430` on
the desk box as expected for the planner's worktree.)

## 8. Distribution hygiene

On an archive export of `bd4b42a375e5080530fcb1b2c64e175b2950cdc7` and on
`<this worktree>` with `csi-spl-doc/doc/md/perf-round-11/seat-agy.md` staged:

```text
git archive bd4b42a375e5080530fcb1b2c64e175b2950cdc7 | tar -xf - -C "$td"
git -C "$td" init -q && git -C "$td" add .
(cd csi-spl-iac && HYGIENE_TREE="$td" ./run -a do_check_dist_hygiene)
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `EXIT=0` on both, all 7 sweeps `ok` + `ok - no tracked .vibe/ dir`, ending
`INFO distribution-hygiene: clean over the tracked tree of <tree>`.

## 9. v0.3 delta review (`1f61f039db0d5ff83482c42cff2ccf51de036256`)

```text
git fetch origin master review/c002-perf-round-11-planner
git rev-parse FETCH_HEAD origin/master
git log --oneline --stat bd4b42a375e5080530fcb1b2c64e175b2950cdc7..1f61f039db0d5ff83482c42cff2ccf51de036256
git ls-remote origin refs/heads/review/c002-perf-round-11-agy-seat refs/heads/review/c002-perf-round-11-grok-seat refs/heads/review/c002-perf-round-11-planner
```

Printed:

```text
1f61f039db0d5ff83482c42cff2ccf51de036256
938143111401126e6413676bf76d243abee72cff
1f61f039d docs(p11-plan, SPL-5672): perf round 11 plan v0.3, fixes the agy seat's W1-W3 and takes in N1-N3
 csi-spl-doc/doc/md/perf-round-11-plan.md   | 118 +++++++++++++++++++++++------
 csi-spl-doc/doc/md/perf-round-11/editor.md |  30 +++++++-
 2 files changed, 123 insertions(+), 25 deletions(-)
e30c18dfc0ae56edc9b6e3deb3181ed56905bb77	refs/heads/review/c002-perf-round-11-agy-seat
12f8f85c962338a96c019bfe82f3a155c2a90689	refs/heads/review/c002-perf-round-11-grok-seat
1f61f039db0d5ff83482c42cff2ccf51de036256	refs/heads/review/c002-perf-round-11-planner
```

New ancestors, slug status, and row/cited-file drift on `origin/master`
(`938143111401126e6413676bf76d243abee72cff`):

```text
for s in 0a6e9d22e c1a54b63f 9499333c1; do
  git merge-base --is-ancestor "$s" origin/master && echo "$s ancestor=yes"
done
git log origin/master --oneline -E --grep='\(p11-' | wc -l
git ls-remote origin 'refs/heads/*p11-*' | wc -l
git log origin/master --format=%s | /usr/bin/grep -cE '\((r59-06|r60-[0-9]{2}|p11-[0-9]{2})' || true
git diff --stat 6fcc711a9 origin/master -- \
  csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh \
  csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh \
  csi-spl-iac/src/bash/run/check-pre-push.func.sh \
  csi-spl-iac/src/bash/tests/check-pre-push.tst.sh \
  csi-spl-orc/src/bash/tests/wait-event.inc.sh \
  csi-spl-orc/src/bash/run/spl-watchdog.func.sh \
  csi-spl-iac/src/bash/run/stop-pre-push.func.sh \
  csi-spl-orc/src/bash/run/check-qto-doc-drift.func.sh \
  csi-spl-iac/src/bash/tests/check-pre-push-budget-table.tst.sh \
  csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh
```

Printed `ancestor=yes` for `0a6e9d22e`, `c1a54b63f`, and `9499333c1`; `0`, `0`, and
`0` for the three slug/round counts; and on the ten paths only `8800fccb9`
(`check-pre-push.func.sh` `:638+` and `check-pre-push.tst.sh`) plus `c1a54b63f`
(`bash-cleancode.tst.sh` `-3` lines, `r58-08`, noted in `:129-130,192`). **Zero row
sites drifted.**

All newly added `file:line` citations in `1f61f039d` checked on `origin/master`
(`938143111`) with `git show origin/master:<file> | sed -n '<N>p'`:

| cite | what `git show origin/master:<file> \| sed -n` printed | match? |
|---|---|---|
| `check-pre-push.func.sh:1083` | `"$fn" "$@" > >(tee "$f") 2>&1 \|\| rc=$?` (inside `_pp_capture`, `:1081-1087`) | yes |
| `check-pre-push.func.sh:1307-1328` | `local _pp_old_traps; _pp_old_traps="$(trap -p INT TERM HUP)"` .. `trap - INT TERM HUP` (`:1329` restores `$_pp_old_traps`) | yes |
| `wd-multi-daemon.tst.sh:197,220,225,238,243` | the five `settle` call sites (`settle`, `settle 2`, `settle`, `settle 2`, `settle 3`), plus `SPOOL_ROOT="$S"` at `:104` and `$D` at `:101-102` | yes |
| `wait-event.inc.sh:35` | `env_idle() { ! grep -qlzxF -- "$1" /proc/[0-9]*/environ 2>/dev/null; }` | yes |
| `spl-watchdog.func.sh:1709,1711` | `spl_wd_log "TAKEOVER $id $code ..."` (`:1709`) and `( ID="$id" ... setsid ${WD_TAKEOVER_CMD:-...} ... & )` (`:1711`) | yes |
| `stop-pre-push.func.sh:25` | `_pp_proc_tree() {  # <pid>` | yes |
| `check-qto-doc-drift.func.sh:78,89` | `out="$(python3 "$py" "$1" "$2" "$3" "$4")" \|\| rc=$?` and `out="$(python3 "$py" check "$1" "$idx" "$2")" \|\| rc=$?` | yes |
| `check-pre-push-budget-table.tst.sh:39` | `mapfile -t PARTS < <(declare -F \| awk '$3 ~ /^_pp_part_/ { print $3 }' \| sort)` | yes |
| `bash-cleancode.tst.sh:20` | `MAX_LINES=75` | yes |

Hygiene, drift, and lane-map checks on `1f61f039db0d5ff83482c42cff2ccf51de036256`:

```text
git archive 1f61f039db0d5ff83482c42cff2ccf51de036256 | tar -xf - -C "$td"
git -C "$td" init -q && git -C "$td" add .
(cd csi-spl-iac && HYGIENE_TREE="$td" ./run -a do_check_dist_hygiene)
(cd csi-spl-orc && FLEET_RULES_TREE="$td" ./run -a do_check_fleet_rules_drift)
(cd csi-spl-orc && QTO_DRIFT_TREE="$td" QTO_DRIFT_LIVE=0 ./run -a do_check_qto_doc_drift)
(cd csi-spl-iac && HYGIENE_TREE=. HYGIENE_MSG_RANGES="6fcc711a9..1f61f039db0d5ff83482c42cff2ccf51de036256" ./run -a do_check_commit_msg_hygiene)
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh \
  --check csi-spl-orc/src/bash/tests/spl-standby-bench.tst.sh,csi-spl-orc/src/bash/tests/wd-multi-daemon.tst.sh,csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-iac/src/bash/tests/check-pre-push-hygiene-concurrent.tst.sh,csi-spl-doc/doc/md/perf-round-11/seat-agy.md \
  --agent a-483
```

Printed `EXIT=0` on all four hygiene/drift actions (`distribution-hygiene: clean`,
`fleet rules: no drift over 9 pinned facts`, `qto doc map: 297 rows, 297 exported md files`,
`commit-message hygiene: clean over 3 commit message(s)`), and `LANEMAP_EXIT=4`
(`0` owning lanes, `12` `unknown:` lanes on `sat`).

### v0.2 findings verified fixed in `1f61f039d`

- **W1 fixed (`perf-round-11-plan.md:112,206-215,347-349`; `editor.md:144-161`):**
  states that `:183`'s `wait "$ctl"` blocks inside case 8 on the pipeline's unkilled
  `sleep 30` (re-confirmed by the editor's 3 s `n=1` check in `editor.md:148-161`),
  places the C2 assertion (`wait_event 2`, cleaning up on failure) **between case 8's
  stop step and its `wait`**, and removes the erroneous case 9 wait lookup.
- **W2 fixed (`perf-round-11-plan.md:113,221-235,350-352`):** specifies
  `wait_event 30 env_idle "SPOOL_ROOT=$S"` (`wait-event.inc.sh:35`) and optionally
  counting synchronous `TAKEOVER c-952 S9` lines in `$D/wd.log`
  (`spl-watchdog.func.sh:1709`, `>= 1`), explicitly forbids counting `$T/takeovers`
  (`spl-watchdog.func.sh:1711`), and places `|| fail` inside `settle()` at `:126`
  (plus any new wait at `:220`) so only 2 edit ranges (`:121-126` and `:220`) change.
- **W3 fixed (`perf-round-11-plan.md:114,254-267,278-282,353-356`; `editor.md:247-255`):**
  keeps `_pp_part_hygiene` in-process (no outer subshell, no `EXIT` trap), saves and
  restores `$(trap -p HUP INT TERM)`, tracks `j1`/`j2`, stops each drift job's whole
  process tree before handing off to the caller's handler, specifies tree signalling
  (or `sleep 30 & wait $!`) in `check-pre-push-hygiene-concurrent.tst.sh`, records the
  seats' stdout-identity measurements in `editor.md:247-255`, and requires Row 03's
  lane to compare in-process stdout (`n>=5`).
- **N1–N3 folded (`perf-round-11-plan.md:114,129-135,160-175,192-193,268-271,278-282,298,364-370`):**
  Row 03's test column lists the remaining R2 tests bolded where they inspect source
  and constrains helpers to `_pp_hygiene_*`; section 3.2 updates R3 for `0a6e9d22e`
  (`9499333c1`, `c1a54b63f`, `c-433@sat`, and `c-426`/`c-428`/`c-432`); section 9 and
  Row 03's in-process numbers are updated.

### Defects remaining in `1f61f039d`

None.

### Note on `1f61f039d`

- **N4 (row 03 standalone sourcing, non-blocking, `:263-264`):** tests that `source`
  `check-pre-push.func.sh` directly without `./run` (`check-commit-msg-hygiene.tst.sh`,
  `check-pre-push-hygiene-concurrent.tst.sh`) do not automatically load
  `stop-pre-push.func.sh`; if Row 03's lane uses `_pp_proc_tree` rather than an inline
  child walk, guard-sourcing `stop-pre-push.func.sh` when
  `! declare -F _pp_proc_tree >/dev/null` (mirroring `:1324`'s
  `check-release-note.func.sh` load) keeps standalone callers self-contained. (Also
  for provenance: `check-pre-push.func.sh:1083` and `:1307-1328` are the `origin/master`
  `0a6e9d22e`..`938143111` line numbers after `8800fccb9`; at `6fcc711a9` they were
  `:1058` and `:1282-1303`.)
