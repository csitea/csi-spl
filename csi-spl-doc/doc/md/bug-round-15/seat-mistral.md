# Bug round 15 - mistral panel seat verdict

Reviewer: m-345@<box> (mistral; docs and reviews only, no code written, no file
touched but this one). Issue: SPL-5862. Epic: SPL-2402. Spec:
csi-spl-doc/specs/157-dispatch-automation.

Plan reviewed: `csi-spl-doc/doc/md/bug-round-15-plan.md` **v0.2** at commit
`b65f8581125a6e669ac766a5cae5d12be066b800` on branch
`review/c002-bug-round-15-planner`. Sha provenance:
`git fetch origin review/c002-bug-round-15-planner && git rev-parse FETCH_HEAD`
-> `b65f8581125a6e669ac766a5cae5d12be066b800`;
`git ls-remote origin review/c002-bug-round-15-planner` -> the same sha. Named
as the review target by the brief (the editor c-339@<box>'s plan report
5b0d4d59 names b65f858 as v0.2). v0.1 `8ce0de287` is superseded:
`git diff --stat 8ce0de287 b65f8581125a6e669ac766a5cae5d12be066b800` ->
`1 file changed, 7 insertions(+), 6 deletions(-)`, the plan file only.
`git merge-base --is-ancestor 2fe3729e3 origin/master` -> exit 0 (the plan's
measurement sha is on trunk); `git merge-base --is-ancestor
b65f8581125a6e669ac766a5cae5d12be066b800 origin/master` -> exit 0.

All row sites below were read at BOTH `2fe3729e3` and `origin/master` with
`git show <sha>:<file> | sed -n <N>p`; the outputs were identical
(`git diff --stat 2fe3729e3 origin/master -- <the row files>` -> empty), so
0 drift. Red controls were run by me on a scratch clone
(`sudo -u <DEV_USER> git -C <worktree> archive 2fe3729e3 | tar -x -C /tmp/b15repo`),
the repo untouched.

## Verdict

**PASS on `b65f8581125a6e669ac766a5cae5d12be066b800`.** Defects W1..: none.
Notes N1..N5 below.

## Checks (each with the command run and what it printed)

### 1. Slug b15 unused

- `git log origin/master --oneline -E --grep='\(b15-' | wc -l` -> `2`; both
  hits are the plan's own version commits `b65f85811` and `8ce0de287`
  (subject scope `b15-plan`), not a row slug.
- `git log origin/master --oneline -E --grep='\(b15-[0-9]{2}' | wc -l` -> `0`
  (no row slug `(b15-NN`).
- `git log origin/master -E --grep='\bb15-[0-9]{2}-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b15-[0-9]{2}' | wc -l` -> `0`;
  `git ls-remote origin | grep 'bug-round-15'` -> one line:
  `b65f8581125a6e669ac766a5cae5d12be066b800  refs/heads/review/c002-bug-round-15-planner`
  (the planner's own review branch, pushed 06:05Z, after the plan's 05:48:58Z
  slug check - see N2).
- `git log origin/master --oneline -E --grep='s[0-9]{3}-b15' | wc -l` -> `0`:
  no `sNNN-b15`-style row of another spec exists on trunk. **I agree it would
  not collide anyway**: that form is another spec's row id (`s154-bNN`), not
  this round's `(b15-NN-` slug form.
- `grep -rlE '(^|[^0-9a-f])b15-[0-9]{2}-' /var/spool-hub/dispatch/briefs
  /var/spool-hub/asks /var/spool-hub/spawn-remote/briefs | wc -l` -> `0`.
- The plan's own literal grep `git log origin/master --grep='(b15-'` now ->
  `30`, because the plan's own two commits landed on master after its
  05:48:58Z measurement (see N1); every row-slug form above is still 0.

### 2. Row sites exist at `2fe3729e3` and on origin/master

- row 01 `csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh:329` ->
  `id="$(tr '\0' '\n' < "$d/environ" 2>/dev/null | sed -n 's/^SPOOL_AGENT_ID=//p' | sed -n 1p)"`
  (the `< file` before `2>/dev/null`, the defect shape); `:537` ->
  `echo "$pid" > "$f" 2>/dev/null || true`; `:317` = `spl_lane_rotate_scan() {`,
  `:341` = `done`; `:530` = `spl_lane_rotate_warn() {`, `:541` = `}`.
- row 02 `csi-spl-orc/src/bash/run/spl-spawn-group-put.func.sh:134-140` ->
  the `spl_spawn_group_state` jq with the `$st` reads (`elif $st == "done" ...`,
  `elif $k == null then {state: "waiting"}`); `:167-172` ->
  `spl_spawn_group_issues() { ... spl_epic_stall_list issues ... }`;
  `:175-181` -> `spl_spawn_group_read() { ... }`.
  `csi-spl-doc/specs/135-work-process/spec.md:346-347` ->
  `| done | its issue is done: the lane landed |` /
  `| closed | its issue is diss, or its lane is gone with the issue not done |`.
- row 03 `csi-spl-orc/src/bash/run/run.sh:705-720` -> `_do_log_resolve_file()`
  with the `WARN log $log_file is not writable, logging to $_log_fb` fallback.
  The four copies are byte-identical at `2fe3729e3`:
  `git show 2fe3729e3:<f> | sha256sum` -> `527b6e27ab6c5519af26059dc44f093feb4751e8186651a99a8c1162380f963a`
  for `csi-spl-orc`, `csi-spl-iac`, `csi-spl-utl` and repo-root `src/bash/run/run.sh`.
- Test files exist at `2fe3729e3` (`git cat-file -e`): `lane-rotate.tst.sh`
  (last case marker `# 34. SPL-5857...`, so "a new case after 34" is at the
  end), `spl-spawn-group.tst.sh` (cases numbered to `# 10`), `run-log.tst.sh`,
  `csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh`.

### 3. Row hygiene (read from the row table at the signed sha)

- Every row has a red control that fails on `2fe3729e3` (re-run by me, check
  4), a named test column, vendor `claude` x3, kind `simple_coding` x3,
  batch `1` x3.
- Batch 1 file sets are disjoint: row 01 `spl-lane-rotate.func.sh` +
  `lane-rotate.tst.sh`; row 02 `spl-spawn-group-put.func.sh` +
  `spl-spawn-group.tst.sh` + spec 135 `spec.md`; row 03 the four `run.sh` +
  `run-log.tst.sh`. The batch-1 bullets piped through `sort | uniq -d | wc -l`
  -> `0`.
- No mistral coding or testing rows: all three rows are `claude`.
- R7 column of every row: "a cross-vendor seat if one places (agy or grok);
  else the claude waiver seat (waiver 1a7c70da)" - a cross-vendor seat or the
  claude waiver seat, never mistral, matching rulebook 2.7.2 and this brief.

### 4. Red controls re-run by me on a clone of `2fe3729e3` (repo untouched)

Scripts read first at `/var/spool-hub/dispatch/b15-red-controls/rc01.sh`,
`rc02.sh`, `rc03.sh`; run as `bash <script> /tmp/b15repo` (rc03 with the second
fleet user `<DEV_USER>`, A = `<HARNESS_USER>`):

- rc02: `row SPL-2582 state=waiting why=` / `issue get calls: 0` - RED on
  `2fe3729e3`, exactly the plan's section 3.2 output.
- rc01, n=2 runs: `A rc=0 B rc=0 A environ lines: 40 B warned lines: 2` and
  `A environ lines: 28 B warned lines: 2`; the counted stderr lines name
  `spl-lane-rotate.func.sh: line 329: $T/proc/4300/environ: No such file or
  directory` and `line 537: $T/spool/c-901/lifetime/rotate.lane.warned: No such
  file or directory` - RED, at the cited lines (A's count is race-dependent,
  the plan itself says so; see N4).
- rc03: `day file: <HARNESS_USER>:<HARNESS_USER> 664; A warn: 0; B warn: 1; day
  file lines A 5 -> after B 5` - RED, the plan's shape (see N5).

### 5. One section-2 source re-run (source 3, read-only)

`for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n
"$d: "; git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" 2fe3729e3
-- "$d" | wc -l; done` -> `csi-spl-api: 199`, `csi-spl-wui: 17`,
`csi-spl-orc: 10`, `csi-spl-iac: 21`, `csi-spl-utl: 0` - agrees exactly with the
plan's source-3 row.

### 6. R3 lane-map check on the rows' paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh,csi-spl-orc/src/bash/tests/lane-rotate.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-group-put.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-group.tst.sh,csi-spl-doc/specs/135-work-process/spec.md,csi-spl-orc/src/bash/run/run.sh,csi-spl-iac/src/bash/run/run.sh,csi-spl-utl/src/bash/run/run.sh,src/bash/run/run.sh,csi-spl-orc/src/bash/tests/run-log.tst.sh
--agent m-345` -> exit 4: no live lane lists any row file; 12 live lanes on
the other box record no files (c-054, c-060, c-390, c-468, c-528, c-545,
c-570, c-596, c-669, c-714, c-924, c-927). The two of them with a brief file
on this box (the two blog drafts) grep clean of every row file
(`grep -qE 'spl-lane-rotate\.func|lane-rotate\.tst|spl-spawn-group-put|spawn-group\.tst|135-work-process/spec\.md|/run\.sh|run-log\.tst'`
-> no match); the `-rotate` lanes record no files by nature. Same class as the
plan's own 05:59:39Z exit-4 check; the orchestrator re-runs R3 before each
spawn (see N3).

### 7. R1 across rounds: no b15 row names a perf-round-16 candidate file

The p16 candidate files (`changed-tests.sh`, `run-all-tests-changed.tst.sh`,
`pre-push-gate.md`, `spl-spawn-share.func.sh`, `spl-spawn-place.func.sh`,
`spl-spawn-share.tst.sh`) appear in the plan only in the section 3.1
**Off limits** line; the batch-1 row file bullets contain none of them
(grep count over the batch-1 bullets -> 0), and the row table (section 3)
mentions none (grep count -> 0). Row 02's fix scope stays in
`spl-spawn-group-put.func.sh`, not the placer file.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of <worktree>`, exit 0
(re-run after adding this file, see the commit).

## Defects

None. No W items.

## Notes

- **N1**: the plan's slug check recorded `git log origin/master --grep='(b15-'`
  -> empty at 05:48:58Z; that literal grep now returns 30 because the plan's
  own two commits (`8ce0de287`, `b65f85811`, scope `b15-plan`) landed on master
  after the measurement. True at measurement time; every row-slug form
  (`(b15-NN`, `\bb15-NN-`, ls-remote `b15-NN`, dispatch dirs) is still 0, so
  the slug is unused as a round row id.
- **N2**: `git ls-remote origin | grep 'bug-round-15'` now matches the
  planner's own `review/c002-bug-round-15-planner` branch (pushed 06:05Z, after
  the 05:48:58Z slug check). Expected, not a collision.
- **N3**: lane-map exit 4 with 12 unknown no-file lanes on the other box -
  the same class the plan itself recorded at 05:59:39Z (13 lanes then); the
  findable briefs are clean of the row files. The orchestrator re-runs R3 and
  asks an exit-4 lane first before each spawn.
- **N4**: rc01's A count is race-dependent: the plan measured 34 and 43, I
  measured 40 and 28 on the same `2fe3729e3` clone; B warned lines = 2 in every
  run, at exactly the cited `:329` and `:537`. The red control fails as claimed.
- **N5**: in my rc03 sandbox the B WARN line read the `no log file` variant of
  the same `is not writable` message (the fallback dir under the sandbox TMPDIR
  was not creatable); the counted `is not writable` lines = 1 and the day-file
  lines `A 5 -> after B 5` match the plan's red output shape.

---

## v1.0 signature

**PASS on `f529b3091e126e188c28504d12f081dd18472923`** (plan v1.0), signed
2026-11-18 after the editor c-339@<box> named it (msg df3b7358) and the
dispatch holder c-002@<box> asked for the signature (msg b2f2ce59).

Provenance and re-checks, each with the command run and what it printed:

- `git fetch origin review/c002-bug-round-15-planner master && git rev-parse
  FETCH_HEAD` -> `f529b3091e126e188c28504d12f081dd18472923`;
  `git ls-remote origin review/c002-bug-round-15-planner` -> the same sha.
- `git merge-base --is-ancestor
  f529b3091e126e188c28504d12f081dd18472923 origin/master` -> exit 0 (v1.0 is on
  `origin/master`).
- `git diff --stat b65f8581125a6e669ac766a5cae5d12be066b800
  f529b3091e126e188c28504d12f081dd18472923` -> `1 file changed, 7 insertions(+),
  5 deletions(-)`, `csi-spl-doc/doc/md/bug-round-15-plan.md` only: the status
  line, the N1 fold into section 3.1, the N4 fold into section 3.2 row 01, the
  review history and the consensus table (Panel `m-345@<box>` PASS on
  `b65f85811`). **No row's defect, site or red control changed**, so every v0.2
  check above stands; the plan's "One sha" line still names `2fe3729e3`.
- Slug re-check at v1.0: `git log origin/master --oneline -E --grep='\(b15-[0-9]{2}'
  | wc -l` -> `0`; `git log origin/master --oneline -E --grep='\(b15-' | wc -l`
  -> `3` (the plan's own `8ce0de287`, `b65f85811`, `f529b309`, scope
  `b15-plan`); `git ls-remote origin | grep -cE 'b15-[0-9]{2}'` -> `0`.
- Site spot-checks at `f529b309`: `git show f529b309:...spl-lane-rotate.func.sh
  | sed -n '329p;537p'` -> the same two defect lines as at `2fe3729e3`;
  `git show f529b309:...spl-spawn-group-put.func.sh | sed -n '167p;175p'` ->
  `spl_spawn_group_issues() {  # EPIC` / `spl_spawn_group_read() {  # GROUP
  ASKS FULL(0|1)`; `git show f529b309:csi-spl-orc/src/bash/run/run.sh |
  sha256sum` -> `527b6e27ab6c5519af26059dc44f093feb4751e8186651a99a8c1162380f963a`,
  the same as at `2fe3729e3`.
- Red control re-run at v1.0 (measurement sha unchanged, clone of `2fe3729e3`):
  `bash /var/spool-hub/dispatch/b15-red-controls/rc02.sh /tmp/b15repo` ->
  `row SPL-2582 state=waiting why=` / `issue get calls: 0` - still RED, as the
  plan's section 3.2 says.

Defects on v1.0: none (no new W items). Notes N1..N5 stand.
