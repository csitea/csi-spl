# Perf round 10 grok seat

Verdict: **REVIEW PASS** on `1fae9045a4c5710debfcb0a93a6c2046ac19c117` (plan v0.1).

Panel: g-223, grok. Issue SPL-5619. Epic SPL-2402. Spec `csi-spl-doc/specs/027-spool-performance`.

No defects. N1 to N4 do not change the row shape, the file split, the red controls, or the direction of the measured gain. N1 is a wrong line cite. The file-level hold in the same paragraph is the rule that keeps the rows apart, and the real lines still do not meet.

## 1. Slug p10 unused

```
git fetch -q origin master
git log origin/master --oneline -E --grep='\(p10-' | wc -l
git ls-remote origin 'refs/heads/*p10-*' | wc -l
git rev-parse origin/master
```

Printed, after the fetch that set `origin/master` to `5f46a4eac06b0aa0bdcf6054e1d9bf3b0f9cacba`:

```
0
0
5f46a4eac06b0aa0bdcf6054e1d9bf3b0f9cacba
```

`git ls-remote origin refs/heads/review/c002-perf-round-10-grok-seat` printed nothing. The planner ref printed `1fae9045a4c5710debfcb0a93a6c2046ac19c117`.

The plan commit's parent is `c27701c45275210ded97d846ee865e36199805a1`. `git merge-base --is-ancestor c27701c45 1fae9045a` exited 0. `git show --stat` of that commit is 2 files, `perf-round-10-plan.md` and `perf-round-10/editor.md`.

`git log origin/master --format=%s -E --grep='\(r58-08-' | wc -l` printed `0`. Landed r58 subjects on that master are r58-01 through r58-07. r58-08 is not on trunk.

## 2. Sites at `0d5d699d6` and on origin/master

`git diff --stat 0d5d699d6 origin/master` for wf10, `check-dist-hygiene.tst.sh`, `bash-cleancode.tst.sh`, and the four readers printed nothing. The same stat for `0d5d699d6 c27701c45` on the three row files printed nothing. `origin/master` at this read is `5f46a4eac` (the plan's `c27701c45` is an ancestor). No name drift. The commits after `e62583e01` do not touch those paths.

`bash-cleancode.tst.sh` at `0d5d699d6` (`git show <sha>:<file> | awk`), same lines on `origin/master`:

```
8:          the vendored spec-kit scaffold, upstream code.
9:          A function longer than MAX_LINES (75; 80 until r29-01) fails
10:          unless LONG lists it. LONG is
25:LONG="
26:  csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh do_provision_firebase_dns 169
27:  csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh _spawn_worktree 79
28:  csi-spl-orc/src/bash/run/spl-agent-identity-restore.func.sh do_spl_agent_identity_restore 80
29:  csi-spl-orc/src/bash/run/spl-desk-reply.func.sh spl_desk_pick 80
30:"
36:# measure <file>...
42:measure() {
51:}
89:all=$(measure "${files[@]}")
103:got=$(APP_ROOT="$T" measure "$T/x.sh" | sed -n 1p)
104:[[ "$got" == "4 $T/x.sh a" || "$got" == "4 x.sh a" ]]
125:grown() {
```

`measure()` is `:42-51`. Its comment is `:36-41`. The 4-line CONTROL accepts both name forms. Callers the plan names are present.

wf10 at `0d5d699d6`, and the same line numbers on `origin/master`. Pattern text is omitted here; each `awk 'NR==N'` printed a line:

```
1708: sweep() {
1717: hits="$(grep -rnIoP ...
1744: # CONTROL: csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh
1745: LC_ALL=C sweep ...
1746: LC_ALL=C sweep ...
1748: LC_ALL=C sweep ...
1750: LC_ALL=C sweep ...
1751: LC_ALL=C sweep ...
1777: LC_ALL="$gate_loc" sweep ...
1795: sweep ...
1804: vibe="$(find . -path ./.git -prune ...
```

The four readers, same line on both shas:

```
repodocs/sync-hygiene.sh:30
  done < <(sed -nE "s/^[[:space:]]*(LC_ALL=C[[:space:]]+)?sweep[[:space:]]+\" ...
repodocs/drift_test.go:17
  var sweepLineRe = regexp.MustCompile(`(?m)^[ \t]*(?:LC_ALL=C[ \t]+)?sweep[ \t]+" ...
spl-release-note-bans-seed.func.sh:75
  pats="$(sed -nE "s/^[[:space:]]*(LC_ALL=C[[:space:]]+)?sweep[[:space:]]+\" ...
blog-check.tst.sh:46
  sed -nE "s/^(LC_ALL=C[[:space:]]+)?sweep \"personal name\" ...
```

Full paths: `csi-spl-api/src/go/spool-hub-api/internal/repodocs/sync-hygiene.sh`, `csi-spl-api/src/go/spool-hub-api/internal/repodocs/drift_test.go`, `csi-spl-orc/src/bash/run/spl-release-note-bans-seed.func.sh`, `csi-spl-orc/src/bash/tests/blog-check.tst.sh`.

## 3. Row shape

Two rows, both batch 1, both `claude / simple_coding`. No mistral coding or testing row. No path is in both rows: row 01 is wf10 plus `csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh`; row 02 is `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`.

Edit sites are under 5. Row 02 names two ranges (`:42-51`, `:36-41`). Row 01's edit is the `sweep()` body (`:1708-1744`) and one new join before `:1804`. The seven call lines in that cell are marked unchanged. See N2.

Each baseline names a command, a number, and n, on `0d5d699d6`. Each row names a counting test whose red control fails on today's code (row 01: 1 grep in flight; row 02: 3 awk calls) and passes on the fast code.

The opening line calls this the fourth round under rulebook section 4. Section 4.5 says the first round under that section is p7. p7, p8 and p9 subjects are on `origin/master`, so p10 is the fourth.

### Medians in the saved probe logs

`/var/tmp/c209-probe/parab-clean.txt` (7 lines) matches editor 2.3. Sorted A `3083 3252 3322 3397 3536 4640 4804`, median 3397. Sorted B `1149 1277 1305 1361 1438 1462 1789`, median 1361. Drop 59.9%, the plan's -60%. Every run has the same sha on both arms (`265131b1`) and rc 0.

`/var/tmp/c209-probe/parab-plant.txt` is one line: `run=1 load=15.87 A=4856 rc=1 sha=c52bfd09 B=1581 rc=1 sha=c52bfd09`. That is the tabulated plant run. See N3.

`/var/tmp/c209-probe/bcc-ab15.txt` matches editor 2.4 (15 runs, `files=1200`, 7013/7013, `same=yes` on every run). Sorted A median 1577 (1331..2236). Sorted B median 37 (33..53).

`diff -u /var/tmp/c209-probe/bcc-A.out /var/tmp/c209-probe/bcc-B.out` differs only in the last line (`bcc-A.tst.sh` vs `bcc-B.tst.sh`). Both files have 13 `PASS:` lines and the same three `NOTE LONG` lines. That is the identical-but-for-the-file-name claim.

### Collisions

Row 02 and r58-08 share `bash-cleancode.tst.sh`. The plan places row 02 only while r58-08 is neither live nor queued, and waits if r58-08 is placed first. r58-08 is not on `origin/master` (section 1). `refactor-round-32-plan.md` row 08 cites `:27-29` for the three stale `LONG` entries. Those entries are still lines 27-29. `measure()` is 42-51 and its comment is 36-41. The hunks do not meet. The plan's own cite `:8-13` is wrong (N1). The hold it states is on the whole file, so the wrong numbers do not let both rows edit the file at once.

Row 01 and lane c-244: the plan says that lane's slug names the pre-push commit-body hygiene, so it is asked before row 01 spawns, and exit 4 is not free. The live map still shows that lane. See section 5.

## 4. Re-measure of p10-02

Read-only. Tracked-file export of `0d5d699d6` (`git archive 0d5d699d6 | tar -x`), then `bash /var/tmp/c209-probe/bcc.sh <export> 7`. `nproc` printed 16. Load during the runs was 9.21..9.66.

```
files=1200
run=1 load=9.66 A=1245 B=29 lines A=7013 B=7013 same=yes
run=2 load=9.66 A=1066 B=28 lines A=7013 B=7013 same=yes
run=3 load=9.66 A=989 B=23 lines A=7013 B=7013 same=yes
run=4 load=9.66 A=955 B=22 lines A=7013 B=7013 same=yes
run=5 load=9.66 A=1002 B=25 lines A=7013 B=7013 same=yes
run=6 load=9.21 A=1083 B=25 lines A=7013 B=7013 same=yes
run=7 load=9.21 A=1060 B=27 lines A=7013 B=7013 same=yes
```

Sorted A `955 989 1002 1060 1066 1083 1245`, median 1060 ms. Sorted B `22 23 25 25 27 28 29`, median 25 ms. Drop 97.6%. Output identical 7 of 7. File count 1200 and line count 7013 match the editor. Absolute milliseconds are lower than 1577 / 37 because this load is lower than the editor's 24.85..30.49. The ratio and the identical lines agree. `REMEASURE_EXIT:0`.

## 5. R3 lane-map

```
timeout 90 bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check \
  .github/workflows/10_ci-quality.yml,csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh,csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \
  --agent g-223
```

Started 2026-11-15T18:41:03Z. `LANE_MAP_EXIT:4`. No line `owned by`. Nine `unknown:` lines, all on sat: c-170, c-193, c-197, c-203, c-239, c-241, c-244 (`c-244-c001-bug-prepush-commit-body-hygiene`), c-664, c-762. Then `WARN no live lane lists <the three paths>, but 9 live lane(s) record no files` and `FATAL ... status 4`.

The plan's 18:20Z map had 11 unknown lines. c-236 and g-266 are not in this one. c-244 is still unknown. Exit 4 is not an owner of the row files. The plan already says the check before each spawn re-reads the map and asks a lane that is still unknown, and it names c-244 before row 01. That handles both collision notes.

## 6. Dist hygiene

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-223` and `HYGIENE_EXIT:0`. That run was before this file was tracked. A later run that is not 0 blocks the review-branch push.

## Notes

- N1. Plan lines 102-104 say r58-08 deletes stale `LONG` lines at `:8-13` today. On `0d5d699d6` and on `origin/master` `5f46a4eac`, lines 8-13 are the header comment. `LONG="` is lines 25-30. r58-08's own plan cites `:27-29`, and those three entries are still 27-29. They do not meet `:36-51`. Correct the cite in v1.0. The file-level wait stands.
- N2. Row 01's sites cell lists the sweep range, the join, and seven unchanged call lines. The edit is two sites. The seven lines are a do-not-edit constraint, which is why the count stays inside the 5-site cap. Moving them out of the sites cell in v1.0 would make the cap obvious.
- N3. The plant "3 of 3" adds two runs that are prose in editor 2.3 (A 4089 and 4056 ms, B 1399 and 1555 ms). The only plant file is `parab-plant.txt`, n=1, shas equal, rc 1/1. The clean series is file-backed 7/7. One backed plant run is enough for the identical-output claim; the other two are not in a file.
- N4. This remeasure is n=7 at load 9.21..9.66, not the editor's n=15 at load 24.85..30.49. Medians 1060 ms and 25 ms versus 1577 ms and 37 ms. Same files, same 7013 lines, same direction.
