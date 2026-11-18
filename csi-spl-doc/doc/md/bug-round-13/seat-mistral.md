# Bug round 13 - mistral panel seat verdict

Reviewer: m-235@sat (mistral; docs and reviews only, no code written)
Plan reviewed: `csi-spl-doc/doc/md/bug-round-13-plan.md` at commit
`5eec0ec492d1ff2f57021f61c395ca2d9eb2e397` (v0.2) on branch
`review/c002-bug-round-13-planner`. Line numbers below are lines of that file
at that sha.

Sha provenance: `git fetch origin review/c002-bug-round-13-planner && git
rev-parse FETCH_HEAD` -> `5eec0ec492d1ff2f57021f61c395ca2d9eb2e397`;
`git ls-remote origin review/c002-bug-round-13-planner` -> the same sha.
Named as v0.2 by c-466@<box2> (brief, panel request 6656d2cc v0.2 f51287a7);
v0.1 `1aa3a249f` is superseded (`git diff --stat 1aa3a249f 5eec0ec49` ->
`1 file changed, 10 insertions(+), 8 deletions(-)`, the plan file only).
`SPOOL_ROOT=/var/spool-hub spool tail --task dispatch-2f60e49b` -> last entry
2026-11-18T00:34:25Z `placed: m-235@sat`; no later v0.3/v1.0 sha is named on
the task, and the branch head is still `5eec0ec49`.

## Verdict: PASS (no defects; notes N1..N6 below)

Signed sha: `5eec0ec492d1ff2f57021f61c395ca2d9eb2e397`

## Checks (each with the command run and what it printed)

### 1. Slug b13 unused

- `git log origin/master --oneline -E --grep='\(b13-' | wc -l` -> `0`
- `git log origin/master --oneline -E --grep='\bb13-[0-9]{2}-' | wc -l` -> `0`
- `git ls-remote origin | grep -E 'b13-[0-9]{2}|bug-round-13'` -> exactly one
  line: `5eec0ec492d1ff2f57021f61c395ca2d9eb2e397 refs/heads/review/c002-bug-round-13-planner`
  (the planner's own branch).
- `git ls-remote origin | grep b13` also matches
  `review/c003-feat-s154-b13-contacts-import-data` (`662c96e3d`, spec 154's
  feat branch; its `b13-co` does not match `b13-[0-9]{2}`) plus version tags
  whose shas contain `b13` by chance. **I agree with c-466: it does not
  collide** — spec 154's row id is `s154-b13`, not this round's `b13-NN-`
  slug form.
- `grep -rlE '(^|[^0-9a-f])b13-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`
  (5873 files), `/var/spool-hub/asks` (8774), `/var/spool-hub/spawn-remote/briefs`
  (199) -> `0` hits each. c-002@sat read 5909/9016/199 at 00:2xZ -> 0 hits; the
  file counts churn, the hits are 0 in both reads.

### 2. Row sites exist at `344be1c04` and on origin/master

`git log -1 --format='%H %cI' 344be1c04` ->
`344be1c040e8f67f4350a5e5c9301e6d0c4d5b30 2026-11-18T00:56:10+01:00`
(= 2026-11-17T23:56:10Z, as the plan says). origin/master is now
`50caeeefd` (b12-04 landed after the plan); `git merge-base --is-ancestor
344be1c04 origin/master` -> exit 0.

Every cited site checked with `git show <sha>:<file> | sed -n <N>p` at BOTH
`344be1c04` and `origin/master`: 27 lines checked, all SAME, 0 DRIFT.

- row 01: `spl-lane-rotate.func.sh:149-153` = the one-row-per-id awk and the
  `while read -r id kind pid age pane n` loop; `:174` =
  `(( age >= ROTATE_LANE_WARN_AGE )) || return 0`; `:333-336` = the scan loop,
  `:335` printing
  `echo "${idof[$pid]} ${kind[$pid]} $pid $(spl_rotate_age "$pid") $(spl_rotate_pane_of_pid "$pid" | grep . || echo -)"`;
  evidence site `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:868-869` =
  the awk start-time read and `[[ "$start" =~ ^[0-9]+$ ]] || return 0` (prints
  nothing when the pid is gone, as the plan says);
  `lane-rotate.tst.sh`: last case marker `grep -oE '^# --- [0-9]+' | sort -n |
  tail -1` -> `# --- 32` (the plan's "a new case after 32"), and the
  red-control head line `# --- 1. two healthy ticks` is at `:289`.
- row 02: `spl-archived-followup.func.sh:248` = `spl_afu_inherit_failed() {`,
  `:256` = `}`, `:261` = `spl_afu_pending() {`, `:279` = the
  `elif spl_afu_final_refusal "$tries"; then spl_afu_pending_final ...; continue`
  line, `:286` = `}`, `:291` = `spl_afu_pending_final() {`, `:296` = `}`,
  `:455` = `spl_afu_move_final() {`, `:460` = `}`, `:476` = `spl_afu_blocker() {`,
  `:487` = `do_log "WARN the blocker to the orchestrator was not sent; the next run tries again"`,
  `:489` = `}`; `spl-archived-followup.tst.sh:405` = case 14g, `:472` = case
  14o; `csi-spl-doc/specs/041-spool-topic-archive-delete/archive-releases-work.md:156`
  still reads "...every later run tries it again until it takes..." (the
  stale sentence the plan's row 02 fixes).

Stronger than the plan's own drift claim: `git diff --stat 344be1c04
origin/master -- <the 6 row files>` -> empty. Last commits touching them at
`344be1c04`: `git log -1 --format='%h %s' 344be1c04 --
csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh` -> `3a11e8c03 fix(orc,
SPL-5728): ...`; same for `spl-archived-followup.func.sh` -> `68cd33322
fix(b12-03-...)` — as the plan's section 3.1 says.
`git log --oneline 68cd33322..344be1c04 --
csi-spl-doc/specs/041-spool-topic-archive-delete/ | wc -l` -> `0`.

### 3. Row hygiene (read from the table at the signed sha)

- Both rows carry a red control with command and expected output on
  `344be1c04` (plan section 3.2, lines 71-72) and a counting test: row 01 a
  new `lane-rotate.tst.sh` case after 32; row 02 cases 14j-14o at `:405-472`.
- vendor `claude`, kind `simple_coding`, batch `1` on both rows (section 7
  counts: rows 2, vendor claude 2, box sat 2, batches 1).
- File sets of batch 1 (section 3.1, lines 55-57) are disjoint: row 01
  {`spl-lane-rotate.func.sh`, `lane-rotate.tst.sh`}; row 02
  {`spl-archived-followup.func.sh`, `spl-archived-followup.tst.sh`,
  `archive-releases-work.md`}. No file in two rows of one batch.
- No mistral coding or testing rows: both rows vendor claude; the R7 column
  is "an agy seat (agy reviews claude, cross-vendor); else the claude waiver
  seat ... The holder decides at placement" — never mistral.
- Round size 2 <= 10 (rulebook 1.1); consensus "no owner go, no question to
  the owner" (rulebook 1.4) — plan lines 8 and 12.

### 4. One red control re-run (row 01, read-only sandbox, DRY=1, no prd write, no terraform)

`git archive 344be1c04 csi-spl-orc` extracted to a temp dir; the head of
`lane-rotate.tst.sh` at `344be1c04` (lines 1-288, up to `# --- 1. two healthy
ticks` at `:289`) run as the sandbox, then:

```text
reset; lane c-911 10; lane c-913 70; rm -f "$T/proc/2913/stat"; DRY=1 tick
```

printed in `$T/tick.out`:

```text
.../spl-lane-rotate.func.sh: line 174: ((: %913: syntax error: operand expected (error token is "%913")
lane-rotate@box-desk: agents=2 in-flight=0 started=0 deferred=0 (DRY_RUN)
```

`grep -c 'operand expected' "$T/tick.out"` -> `1`; `grep -c ERRTRAP` -> `0`.
**Reproduces** the plan's section 3.2 line 71 exactly (`operand-expected=1`,
`agents=2 ... (DRY_RUN)`). The defect is real on `344be1c04`.

### 5. Section 2 source re-run (source 3, read-only)

```text
for s in e9748a03d 344be1c04; do for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$s $d: "; git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" $s -- "$d" | wc -l; done; done
```

-> `api 197, wui 17, orc 10, iac 21, utl 0` on BOTH shas — **agrees** with the
plan's source-3 row. `git show 344be1c04:csi-spl-wui/tests/e2e/ci-skip.txt |
wc -l` -> `8`; `grep -vc '^#'` -> `4` entries — agrees ("4 entries").

### 6. R3 lane-map

```text
bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh,csi-spl-orc/src/bash/tests/lane-rotate.tst.sh,csi-spl-orc/src/bash/run/spl-archived-followup.func.sh,csi-spl-orc/src/bash/tests/spl-archived-followup.tst.sh,csi-spl-doc/specs/041-spool-topic-archive-delete/archive-releases-work.md,csi-spl-doc/doc/md/bug-round-13/seat-mistral.md,csi-spl-doc/doc/md/bug-round-13-plan.md --agent m-235
```

-> **exit 4**: no live lane lists any of the 7 paths (no exit 3); 15 live
lanes record no files and are unknown scope, ask first: c-054, c-060, c-366,
c-390, c-454, c-457, c-466, c-469, c-528, c-545, c-570, c-669, c-714, c-924,
c-927 (all @<box2>; c-466 is the planner). My seat file path is free.

### 7. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-235`, exit 0.

## Defects

None. (No W1..: every check above reproduced or agreed with the plan at the
signed sha.)

## Notes

- **N1**: origin/master moved to `50caeeefd` (b12-04, SPL-5843, landed) since
  the plan's 00:1xZ read; `git diff --stat 344be1c04 origin/master` over the 6
  row files is empty, so every site and both red controls still hold on
  current master.
- **N2**: the plan cites the row-01 evidence site by basename
  `spl-rotate-lib.func.sh:868-869`; the full path is
  `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` (lines 868-869 verified
  there).
- **N3**: lane-map exit 4 lists 15 no-file lanes now (the plan recorded 6 on
  sat at 00:13:13Z); none owns a row file, and the planner c-466@<box2> is among
  them.
- **N4**: not re-run by me (outside checks 1-7): section-2 sources 1, 2, 4, 5
  (prd SQL, the CI gate report, the <box2> cron-log scan) and the section-8
  box-pick state (grok `pick=hold`, agy/mistral weekly usage). They are the
  planner's measurements, marked as such in the plan. Row 02's red control
  was not re-run (the brief asks for one row; I re-ran row 01).
- **N5**: the plan's source-3 command is printed with `\|` (markdown table
  escaping, as its own note under the section-2 table says); run with a plain
  `|` the counts reproduce exactly (check 5). The measurement is right; only
  the printed form is escaped.
- **N6**: spool file counts churned since c-002's read (briefs 5873 vs 5909,
  asks 8774 vs 9016); the `b13-[0-9]{2}-` grep hits are 0 in both reads.

## v1.0 delta sign-off (second signature)

Signed sha: `d5bf6534ce2ec136f37ffed2625ca6aa18d5830c` (v1.0, landed as
`origin/master` HEAD). Named as v1.0 on task `dispatch-2f60e49b` by the
dispatch holder c-002@sat (ACCEPTED msg `fdc6830d`, 2026-11-18T00:55:35Z:
"v1.0 d5bf6534c landed with your N1 + N2 folded in, no row changed").

Delta checked, only `5eec0ec49..d5bf6534c`:

- `git ls-remote origin master HEAD` ->
  `d5bf6534ce2ec136f37ffed2625ca6aa18d5830c` for both;
  `git log -1 --format='%H %s' d5bf6534c` ->
  `d5bf6534ce2ec136f37ffed2625ca6aa18d5830c docs(b13-plan, SPL-5844): bug round 13 plan v1.0, panel PASS folds N1 N2`.
- `git fetch origin review/c002-bug-round-13-planner && git rev-parse FETCH_HEAD`
  -> `d9051b8ebf4e9307fd4da3b18a7ea984d2340017` (same v1.0 subject);
  `git diff d5bf6534c d9051b8e -- csi-spl-doc/doc/md/bug-round-13-plan.md | wc -l`
  -> `0` (the review branch's v1.0 and master's v1.0 carry the same plan file).
- `git show --stat d5bf6534c` -> `1 file changed, 7 insertions(+), 5 deletions(-)`:
  only `csi-spl-doc/doc/md/bug-round-13-plan.md`.
- `git diff 5eec0ec49 d5bf6534c -- csi-spl-doc/doc/md/bug-round-13-plan.md` ->
  4 hunks: the status line v0.2 -> v1.0; the "One sha" paragraph gains the N1
  note (`origin/master` moved to `7c327ff46`, `git diff --stat 344be1c04
  7c327ff46` over the row files empty); row 01's evidence cell folds N2
  (`spl-rotate-lib.func.sh:868-869` ->
  `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:868-869`); the
  review-history and consensus-table entries (editor v1.0, panel PASS on
  `5eec0ec49`, seat file `32fbf80e8`). No hunk touches any row's defect,
  sites, red control (section 3.2) or the row 02 cell.
- Row files still hold on the signed sha:
  `git diff --stat 344be1c04 d5bf6534c -- <the 6 row files>` -> empty.

Verdict on `d5bf6534ce2ec136f37ffed2625ca6aa18d5830c`: **PASS**.
