# Bug round 14 - mistral panel seat verdict

Reviewer: m-538@<box2> (mistral; docs and reviews only, no code written)
Plan reviewed: `csi-spl-doc/doc/md/bug-round-14-plan.md` at commit
`8a9dc6392b8793087cad186cd73e9721e9284ef8` (v0.2) on branch
`review/c002-bug-round-14-planner`. Line numbers below are lines of that file
at that sha.

Sha provenance: `git fetch origin review/c002-bug-round-14-planner && git
rev-parse FETCH_HEAD` -> `8a9dc6392b8793087cad186cd73e9721e9284ef8`;
`git ls-remote origin review/c002-bug-round-14-planner` -> the same sha.
Named as the review target by the editor c-279@sat (msg 485a0504 on my task
`b53d91de-7d04-52f2-af9b-d90b35f2f2c3`, citing 963ab47b: "please review plan
**v0.2** `8a9dc6392...`, not v0.1 `e0862a1c8`") and by the dispatch holder
c-002@sat (msg b874a294). v0.1 `e0862a1c8` is superseded:
`git diff --stat e0862a1c8 8a9dc6392` -> `1 file changed, 9 insertions(+), 8
deletions(-)`, the plan file only. `git diff --stat origin/master...8a9dc6392`
-> the plan file only, 152 insertions(+).

## Verdict: PASS (no defects; notes N1..N6 below)

Signed sha: `8a9dc6392b8793087cad186cd73e9721e9284ef8`

## Checks (each with the command run and what it printed)

### 1. Slug b14 unused

- `git log origin/master --oneline -E --grep='\(b14-' | wc -l` -> `0`
- `git log origin/master --oneline -E --grep='\bb14-[0-9]{2}-' | wc -l` -> `0`
- `git ls-remote origin | grep -E 'b14-[0-9]{2}|bug-round-14'` -> one line:
  `8a9dc6392...  refs/heads/review/c002-bug-round-14-planner` (the planner
  branch itself, not a row slug `b14-NN-`)
- `git grep -nE '(^|[^0-9a-f])b14-[0-9]{2}-' origin/master` -> no hits
- `grep -rlE '(^|[^0-9a-f])b14-[0-9]{2}-' /var/spool-hub/dispatch/briefs
  /var/spool-hub/asks /var/spool-hub/spawn-remote/briefs | wc -l` -> `0`
  (3267 / 8785 / 2958 files on this box)
- Spec 154's form: `git ls-remote origin | grep -E 's154-b[0-9]{2}'` ->
  `review/c003-feat-s154-b13-contacts-import-data` (662c96e3d) and
  `wip/g-950-s154-b11` (399d1f8bb); `git grep -n 's154-b14' origin/master` ->
  no hits. **I agree with the plan: it does not collide** — spec 154's row id
  is `s154-bNN`, not this round's `b14-NN-` slug form, and no `s154-b14` exists.

### 2. Row sites exist at `087f33ea0` and on origin/master

`git merge-base --is-ancestor 087f33ea0 origin/master` -> exit 0;
`git log -1 --format='%H %cI %s' 087f33ea0` ->
`087f33ea0de0e6266ab4f4151a7d847d5da7afb6 2026-11-18T03:59:04+02:00 fix(b13-02-...)`.
origin/master is now `288fc6bd89`.

Every cited site checked with `git show <sha>:<file> | sed -n <N>p` at BOTH
`087f33ea0` and `origin/master`; all SAME, 0 DRIFT, and
`git diff --stat 087f33ea0 origin/master -- <the 6 row files>` -> empty.
Line counts identical (087f vs master): spl-reflection-gather.func.sh 471/471,
spl-lane-rotate.func.sh 1043/1043, spl-rotate-lib.func.sh 2007/2007,
spl-reflection-gather.tst.sh 529/529, lane-rotate.tst.sh 868/868, spec 166
spec.md 386/386.

- row 01: `spl-reflection-gather.func.sh:250-252` = `spl_reflection_subjects()`
  with `git ... log ... --format='%cI%x09%s'` at `:251` (subjects only);
  `:228` = `... else spl_reflection_stalled_judge "$w" ...` (the judge's call,
  its rc ignored); `:270` = `for line in open(f"{w}/subjects.tsv"...)`,
  `:276` = `def rx(key):`, `:287` = `last = next(((e, at) for e, at, s in subj
  if r.search(s)), None)` (the judge matches keys in subjects.tsv);
  `:340-341` = the `(fetch failed: ...)` line. Test
  `spl-reflection-gather.tst.sh:362` = `# --- 16. section 7: the stalled wip
  issues (SPL-5825) ---`. Doc `csi-spl-doc/specs/166-orchestrator-daily-rhythm/spec.md:305`
  = the `**B8** Implemented (SPL-4894)` row. (The plan's evidence quotes
  `func.sh:217` / `:194` from the reviewer's msg on the older `32da3b6ea`;
  at `087f33ea0` the site list's 228/250-252/270-276/287 is the matching one.)
- row 02: `spl-lane-rotate.func.sh:607` =
  `cl="$(tr '\0\n\r' '   ' < "$root/$d/cmdline" 2>/dev/null || true)"` inside
  `spl_lane_rotate_child_match` (`:590-615`); `:602`, `:112`, `:174` exist as
  cited. `spl-rotate-lib.func.sh:823` =
  `{ IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "$1/cmdline" 2>/dev/null || true`
  inside `spl_rotate_cli` (`:813-827`). Test `lane-rotate.tst.sh`: last case
  marker `grep -nE '^# --- [0-9]+\.' | tail` -> `# --- 33.` at `:844` (file 868
  lines), so "a new case after 33" is at the end.

### 3. Row hygiene (read from the table at the signed sha)

- Both rows carry a red control with command and expected output on
  `087f33ea0` (plan section 3.2) and a counting test: row 01
  `spl-reflection-gather.tst.sh` (case 16 at `:362`); row 02
  `lane-rotate.tst.sh` (a new case after 33).
- vendor `claude`, kind `simple_coding`, batch `1` on both rows (section 7:
  rows 2, vendor claude 2, box sat 2, batches 1).
- File sets of batch 1 (section 3.1) are disjoint: row 01
  {`spl-reflection-gather.func.sh`, `spl-reflection-gather.tst.sh`,
  `specs/166-orchestrator-daily-rhythm/spec.md`}; row 02
  {`spl-lane-rotate.func.sh`, `spl-rotate-lib.func.sh`, `lane-rotate.tst.sh`}.
  `comm -12` of the two sorted lists -> 0 lines. No file in two rows of one
  batch.
- No mistral coding or testing rows: both rows vendor claude; the only mistral
  seat is this panel seat (docs only). R7 column: "a cross-vendor seat if one
  places (agy or grok); else the claude waiver seat" — never mistral.
  `git log -1 --format=%B 087f33ea0 | grep waiver` -> `same-vendor under
  waiver 1a7c70da` (b13-02's line, as the plan cites).
- Last commits on the row files at origin/master match the plan's section 3.1:
  `git log -1 --format='%h %s' origin/master -- <file>` ->
  spl-reflection-gather.func.sh `9d358eee6 fix(orc, SPL-5829): ...`,
  spl-lane-rotate.func.sh `5ebf6314b fix(b13-01-...)`, spl-rotate-lib.func.sh
  `221418819 fix(orc, SPL-5737): ...`; all three shas are ancestors of
  origin/master (`git merge-base --is-ancestor` exit 0 each).

### 4. Red controls re-run (both rows, read-only sandbox, no prd write, no terraform)

I used the editor's scripts verbatim as forwarded by the dispatch holder
c-002@sat (msg 77354b31: `/var/spool-hub/c-279/lifetime/b14-red-controls/` is
on sat and unreadable from <box2>), saved each to a scratch file and read it
before running; I did not rebuild them. Repo: `git clone
/opt/csi/csi-spl-wt/m-538 /tmp/b14-clone-087f && git -C /tmp/b14-clone-087f
checkout 087f33ea0de0e6266ab4f4151a7d847d5da7afb6` (verified HEAD). Both
scripts work in a mktemp dir only.

- `bash rc01.sh /tmp/b14-clone-087f` ->
  `A: - SPL-7: named in a body only (last commit none) rc=0` and `B: rc=0`
  (no line, no `(not read` marker). **Reproduces** the plan's section 3.2 row
  01 exactly: case A prints the false `(last commit none)`, case B prints
  nothing. The defect is real on `087f33ea0`.
- `bash rc02.sh /tmp/b14-clone-087f` ->
  `A rc=0 B rc=1 stderr cmdline lines: 2`, stderr:
  `.../spl-lane-rotate.func.sh: line 607: $T/proc/4242/cmdline: No such file or directory`
  and `.../spl-rotate-lib.func.sh: line 813: $T/proc/4242/cmdline: No such file or directory`.
  **Reproduces** the plan's section 3.2 row 02 (`A rc=0 B rc=1 stderr cmdline
  lines: 2`). The defect is real on `087f33ea0`.

### 5. Section 2 sources re-run (sources 3 and 2, read-only)

- Source 3:
  `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" 087f33ea0 -- "$d" | wc -l; done`
  -> `csi-spl-api: 197  csi-spl-wui: 17  csi-spl-orc: 10  csi-spl-iac: 21
  csi-spl-utl: 0` — **agrees** with the plan. `git show
  087f33ea0:csi-spl-wui/tests/e2e/ci-skip.txt | wc -l` -> `8`;
  `grep -vcE '^\s*(#|$)'` -> `4` entries — agrees ("4 entries").
- Source 2: `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a
  do_report_ci_gate` -> 5 failed runs in the last 100 (window
  2026-11-17T08:40:25Z..2026-11-18T02:56:08Z); first red per JOB: `wui: browser
  e2e (mock, generated) 2/8` x2 and `hub: Postgres gate, pg coverage floor` x2
  = 4 first-red sightings over 2 jobs; failed runs are 68cd3332
  (TestDemoPostQuotaPerDay), 013cb71b x2 (wui e2e), fd9e5a27, 41d35321
  (TestAgentRunPresenceFrames); last green for every failed job:
  `44219928387 087f33ea 2026-11-18T01:59:35Z`; highest timeout p90 `56 %` —
  **agrees** with the plan's source-2 row (see N3 for the totals).
- Row 01 evidence re-measure:
  `git log origin/master --since='72 hours ago' --format=%s | grep -oE 'SPL-[0-9]+' | sort -u`
  vs the same with `--format=%b`, `comm -13` -> `68` keys in a body only;
  `git log origin/master --since='72 hours ago' --format=%b | grep -cE '^(Closes|Refs): SPL-'`
  -> `230` — **agrees** with the plan's 68 / 230.

### 6. R3 lane-map

```text
bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh,csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh,csi-spl-doc/specs/166-orchestrator-daily-rhythm/spec.md,csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh,csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh,csi-spl-orc/src/bash/tests/lane-rotate.tst.sh,csi-spl-doc/doc/md/bug-round-14/seat-mistral.md --agent m-538
```

-> **exit 4**: no live lane lists any of the 7 paths (no exit 3); 7 live lanes
record no files and are unknown scope, ask first: c-176, c-197, c-250, c-261,
c-266, c-279, c-762 (all @sat; c-279 is the planner). This matches the plan's
own recorded check (section 3.1: exit 4 at 02:45:24Z, no live lane lists the
row files). The local briefs that name the row files are landed lanes
(`c003-bug-rotate-child-scan-mawk-vanish` SPL-5737, the s166 waiver reviewers,
etc.). My seat file path is free.

### 7. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-538`, exit 0.

## Defects

None. (No W1..: every check above reproduced or agreed with the plan at the
signed sha.)

## Notes

- **N1**: rc02's stderr attributes the `spl-rotate-lib.func.sh` failure to
  "line 813" (the function's opening line) while the plan's site is `:823`
  (the statement); the plan's section 3.2 output for row 02 claims no line for
  the lib, so there is no contradiction — bash reports the compound command's
  line. The `spl-lane-rotate.func.sh` error is reported at line 607, matching
  the site.
- **N2**: the cron-log counts (730 lines, 80 at line 602 / 4 at line 607, one
  in dispatch-rotate) are sat's logs, not re-measurable from <box2>; <box2>'s own
  `/var/csi/csi-spl/lane-rotate/cron.log` shows the same error shape
  (`grep -c 'cmdline: No such file'` -> 539 here). The mechanism is proven by
  rc02 on `087f33ea0` (check 4).
- **N3**: source-2 totals now read 65 success / 27 cancelled / 5 failure /
  3 running vs the plan's 66 / 29 / 5, because the 100-run window moved; the 5
  failed runs, their jobs and the last-green run 44219928387 on `087f33ea`
  match exactly.
- **N4**: the plan header's "both ACCEPTED" for the b13 rows: shas 5ebf6314b
  and 087f33ea0 verified on origin/master; the ACCEPTED messages live on sat's
  task, not re-verified from <box2>.
- **N5**: v0.2 vs v0.1 is the plan file only (+9/-8), in sections 2, 3.1, 5,
  8, 9 as c-279 said; no row, site or red control changed — verified with
  `git diff e0862a1c8 8a9dc6392`.
- **N6**: the plan's section-2 commands print `\|` (markdown table escaping,
  as its own note under the table says); run with a plain `|` the counts
  reproduce (check 5).
