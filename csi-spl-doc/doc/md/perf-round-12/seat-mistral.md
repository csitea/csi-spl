# Perf round 12: seat mistral (m-676)

- Seat: m-676 (this box), mistral, panel seat of rulebook 3.2 (doc review
  only; no code review, owner 10-30 cf7a7ee5). Lane issue SPL-5701, epic
  SPL-2402, spec csi-spl-doc/specs/027-spool-performance, topic
  32d81359-7971-4033-92e7-450b1e153424 (context only, not posted in).
- Plan under review: branch `review/c002-perf-round-12-planner`, plan sha
  **`325e0a8edc83674390e68fb81bd3c1b0d505066c`** (the sha this seat signs).
  - `git fetch origin review/c002-perf-round-12-planner && git rev-parse
    FETCH_HEAD` -> `325e0a8edc83674390e68fb81bd3c1b0d505066c`;
    `git ls-remote origin refs/heads/review/c002-perf-round-12-planner` ->
    the same sha.
  - `git show 325e0a8ed --stat` -> exactly 2 files:
    `csi-spl-doc/doc/md/perf-round-12-plan.md` (299 lines) and
    `csi-spl-doc/doc/md/perf-round-12/editor.md` (165 lines).
  - `git log --oneline a9b11eda5..325e0a8ed` -> 4 commits (editor-state and
    the v0.2 panel-ruling commits). `git diff a9b11eda5 325e0a8ed --
    csi-spl-doc/doc/md/perf-round-12-plan.md | grep '^@@'` -> hunks only at
    `@@ -230,13 +230,21 @@`, `@@ -277,6 +285,9 @@`, `@@ -284,5 +295,5 @@`:
    sections 5, 8 and 9. The rows (section 3, plan lines 109-131) are
    unchanged since a9b11eda5, so the lane's earlier re-measure applies to
    this sha; every check below was re-run this session regardless.
  - Rules read: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 4
    (4.1 measured first; 3.2 the panel signs the plan sha).

## Verdict

**PASS on `325e0a8edc83674390e68fb81bd3c1b0d505066c`.**

## Check 1: slug p12 unused

- `git log origin/master --oneline -E --grep='\(p12-' | wc -l` -> `0`
- `git ls-remote origin 'refs/heads/*p12-*' | wc -l` -> `0`
- `git ls-tree -r --name-only origin/master | grep -c perf-round-12` -> `0`

## Check 2: each row's sites exist at a8a54cf44 and on origin/master

`cpp` = `csi-spl-iac/src/bash/run/check-pre-push.func.sh`. Each site read with
`git show a8a54cf44:<file> | sed -n <range>p`:

- `cpp:1067-1078` (row 01, `_pp_run` base re-check block): 1068 `# Pre-existing
  on trunk? Re-run the SAME part against the base ref.` — matches.
- `cpp:713-731` (row 01, `_pp_part_orc`): 713 `_pp_part_orc() {  # <tree>` —
  matches.
- `cpp:671-676` (row 02, `_pp_part_iac`): 671 `_pp_part_iac() {` — matches.
- `cpp:1246` (`_pp_sig`): `line ~ /^FAILED: / { ... emit("suite", s) ... }` —
  matches.
- `cpp:1265-1286` (`_pp_compare`): 1265 `_pp_compare() { ...` — matches.
- `cpp:1021-1025` (comment above `_pp_run`; 1021 is the blank line, the comment
  is 1022-1025), `cpp:686-688` (comment above `_pp_part_orc`; 688 ends `the
  trunk re-check runs the same files.`), `cpp:1083-1084` (TIMED OUT refusal) —
  match.
- `csi-spl-iac/src/bash/tests/run-all-tests.sh:28,58-64` (row 02,
  `IAC_TEST_ONLY`): 28 the doc comment, 60 `[[ -f "$dir/$o" ]] || { ... exit 2;
  }` — matches.
- orc runner filter: `git grep -n 'ORC_TEST_FILES' a8a54cf44 -- csi-spl-orc` ->
  `csi-spl-orc/src/bash/tests/changed-tests.sh:39` (doc) and `:58-59`;
  `ORC_TEST_ALWAYS` at `:34,45`.
- Drift: `git diff --stat a8a54cf44 origin/master --
  csi-spl-iac/src/bash/run/check-pre-push.func.sh
  csi-spl-orc/src/bash/tests/run-all-tests.sh
  csi-spl-orc/src/bash/tests/changed-tests.sh
  csi-spl-iac/src/bash/tests/run-all-tests.sh` -> empty (rc 0). No site
  drifted between the measured sha and current origin/master
  (`8d209da6b62a4eee14ac87c377d9269ab17e1c48`).

## Check 3: row shape, R1, vendors, verdict claim, R3

Read from `git show 325e0a8ed:csi-spl-doc/doc/md/perf-round-12-plan.md`
(299 lines; row table at lines 113-114):

- Row 01 `perf(p12-01-orc-recheck-failed-files)` (plan:113): 2 edit ranges
  (`cpp:1067-1078`, `cpp:713-731`), at most 5 sites. Baseline with command +
  number + n: `abpp.sh <clone> A`, base re-check 672, 553, 415 s (n=3), whole
  failed part 1,574, 1,222, 1,023 s (n=3); probe arm B 26, 23, 67 s (n=3).
  Counting test with red control (4.1, C2): new
  `iac/src/bash/tests/check-pre-push-recheck-narrow.tst.sh`, red plant
  described (today's `_pp_run` -> 3 files on the base, FAIL). Vendor claude,
  kind simple_coding (R9 noted), batch 1.
- Row 02 `perf(p12-02-iac-recheck-failed-files)` (plan:114): 1 edit range
  (`cpp:671-676`). Baseline `abiac.sh <clone> A`, base re-check 203, 189 s
  (n=2), whole part 533, 390 s (n=2); arm B 2, 1 s (n=2). Same test, iac case,
  red control described. Vendor claude, kind simple_coding, batch 2.
- R1: both rows edit `cpp` and the same new test, but in different batches
  (plan:121-126: batch 1 = row 01; batch 2 = row 02, spawned within 30 min of
  row 01 landing, R16) — no file in two rows of one batch.
- No mistral coding or testing rows: plan:116 "Rows 01-02 are both claude"
  (rulebook R14 + owner 10-17, quoted in the plan).
- Verdict-stays-same claim vs probe output: the lane's own probe (check 4),
  re-read this session, shows rc 1 in both arms in all 3 runs and the plant
  failing on the base in every arm, so the verdict is the same in both arms;
  the editor's signed runs (editor.md sections 2.2/2.3) name the same failures
  in both arms per run.
- R3 re-read this session (2026-11-16 21:1xZ):
  - `lane-map.sh --check <the five rows' paths> --agent m-676` -> exit 4:
    0 `owned by`, 13 `unknown:` lanes, all on the satellite box, none naming
    the pre-push gate (rotation seats and feature/bug lanes).
  - `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a do_spl_spawn_queue` ->
    `19 queued, 0 placing`. Of the plan's five briefs (plan:141-147), two are
    readable on this box: `grep -c check-pre-push` on
    `/var/spool-hub/spawn-remote/briefs/6f8981cb-1407-4963-a597-12e4f739818b.md`
    (placement slug `c002-spl4835-lane-console-keep-clear`) -> `0`, and on
    `ec6cabfb-adac-4fff-b6c5-81a7bc42c0b4.md` (placement slug
    `c002-spl5704-open-takes-claude-waiver-reviewer`) -> `0`. The other three
    (`c002-bug-hubclient-sendframe-unkeyed-error`, the agy-memory brief, and
    `c002-955ab0bd-event-types-causes`) are not under /var/spool-hub on this
    box — the queue output itself says the agy-memory brief was queued on the
    satellite, so the file is there.
  - Does the plan handle R3? Yes: plan section 3.2 (lines 132-150) records the
    lane-map read (exit 4, unknown lanes listed), the spawn-queue read and the
    unlanded-row read, and states at line 147: "Exit 4 is not free: the R3
    check before each spawn re-reads the map and asks any lane still unknown."

## Check 4: the lane's re-measure of p12-01 (base re-check A vs B, n=3)

Setup mirroring editor 2.2, read-only (no prd write): probe dir
`/var/tmp/m676-probe/` with two `git clone --shared` checkouts of `a8a54cf44`
(`git rev-parse HEAD` in each -> `a8a54cf4443f9f4d4aedb35daff3fb3873d983ca`),
each with one planted red line in
`csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh`. Arm A base = the same
`--changed` plan again; arm B base = `ORC_TEST_FILES=<FAILED files>
ORC_TEST_ALWAYS=`. Run by the previous m-676 session of this lane
(12:47-13:36Z); this session re-read the log
(`tail -20 /var/tmp/m676-probe/pp-runs.log`):

```text
run 1 12:47:16Z A tree 1493 s rc 1 | base 511 s rc 1 | total 2004 s || B tree 1493 s rc 1 | base 30 s rc 1 | total 1523 s
run 2 13:17:24Z A tree (reused) | base 455 s rc 1 || B tree 791 s rc 1 | base 90 s rc 1 | total 881 s
run 3 13:36:52Z A tree 737 s rc 1 | base 431 s rc 1 | total 1168 s || B tree 738 s rc 1 | base 65 s rc 1 | total 802 s
PROBE DONE 13:36:52Z
```

- Base re-check arm A (whole `--changed` plan again): **511, 455, 431 s
  (n=3)**; arm B (only the tree run's `FAILED:` files): **30, 90, 65 s (n=3)**.
  B below its paired A 3 of 3. The editor's signed numbers were A 672, 553,
  415 s and B 26, 23, 67 s (n=3) — same ranges, the numbers agree.
- Verdict: rc 1 in both arms in all 3 runs; the plant fails on the base in
  every arm, so the verdict is the same (pre-existing red) in both arms every
  run — the narrowing does not change the verdict.
- The row text is unchanged between a9b11eda5 and the signed 325e0a8ed (diff
  hunks only in sections 5/8/9) and the probed code sha a8a54cf44 is fixed, so
  this measurement applies to the signed sha.

## Check 5: lane map on the rows' paths

- `lane-map.sh --check csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-orc/src/bash/tests/run-all-tests.sh,csi-spl-orc/src/bash/tests/changed-tests.sh,csi-spl-iac/src/bash/tests/run-all-tests.sh,csi-spl-iac/src/bash/tests/check-pre-push-recheck-narrow.tst.sh --agent m-676`
  -> exit 4 (13 `unknown:` lanes, all on the satellite box, none owning these
  paths; output in check 3).
- The same call plus the plan and this seat file -> exit 3, naming only
  `csi-spl-doc/doc/md/perf-round-12-plan.md owned by c-616
  c-616-c002-perf-round-12-planner` (the editor; the review target, not a row
  path). The rows' code paths are owned by no live lane.

## Check 6: distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> exit 0, all sweeps `ok`
over the tracked tree of this worktree (run after this file was written).

## Other plan claims re-verified

- 4.4 share, the rulebook command verbatim on current origin/master:
  `perf 16 refactor 104 perf-share 13.3% under-20` (the plan quoted
  `perf 16 refactor 108 perf-share 12.9% under-20` on `302ac11ce`; the counts
  moved with lands, the verdict is the same `under-20`).
- p11 rows landed: `git merge-base --is-ancestor <sha> origin/master` exits 0
  for `6def8d373`, `e6fb29099`, `1e5134ac5`.
- `git log origin/master --format=%s -E --grep='\(r6[01]-' | wc -l` -> `0`.

## Defects

None. W1..: none.

## Notes

- N1: the sign target moved twice since the brief (a9b11eda5 -> 08c10cfad ->
  325e0a8ed, per c-616's note 7d179894 and c-001's relay e9fccfce on task
  dispatch-perf-r12). This seat signs 325e0a8ed. The earlier local verdict
  commit on a9b11eda5 (dfb9ba3f9, on the lane branch) is deliberately NOT
  pushed, per c-001's relay.
- N2: the plan cites the comment above `_pp_run` as `cpp:1021-1025`; line 1021
  is blank, the comment is 1022-1025. Cosmetic only.
- N3: the editor's 2.1 log counts (orc 15 / iac 33 WARN-pre-existing in 7 days)
  are not reproducible from the only pre-push log on this box:
  `awk '$3=="PART" && $5=="WARN-pre-existing"' ~/.cache/csi-spl/pre-push.log`
  prints 8 lines total (no `orc` line), dated 2026-10-04..2026-11-16. The row
  baselines rest on the A/B probes (check 4), not on those counts, so this is
  a note, not a defect.
- N4: the brief's commit-subject template says "perf round 11 seat mistral
  verdict"; every other reference names the round under review, so this seat
  commits "perf round 12".
- N5: three of the five R3 briefs are not readable on this box (queued on the
  satellite); the plan's R3 handling (re-read the map before each spawn) covers
  that, and the two readable briefs name `check-pre-push` 0 times.
- N6: not re-run (outside the brief's checks 1-6): the editor's 2.1 24 h part
  table, the 2.4 stamp/CI-shard screenings, and the ask ids 56aade4b /
  b00e6895.

## Sign

`panel: m-676 mistral PASS 325e0a8edc83674390e68fb81bd3c1b0d505066c`
