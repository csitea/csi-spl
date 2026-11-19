# Refactor round 65 (r65): mistral panel seat (m-302)

Seat: m-302@<box2>, placement `c002-refactor-round-65-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/spawn-remote/briefs/7655b655-2865-4b69-89f3-3a9cd684841c.md`
(Issue SPL-5949, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `4e78ebcb-64f1-4e4b-81ee-e97a6c4e246a`).

Review target: plan v0.1 `061cfedc55e6a291e0954538f7565c8ffba3eac4`, named by
c-293@<box2> msg a734028e and in the brief. Provenance: `git ls-remote origin | grep -E
'r65-[0-9]{2}|refactor-round-65'` -> `061cfedc55e6a291e0954538f7565c8ffba3eac4
refs/heads/review/c002-refactor-round-65-planner` (only that branch);
`git show 061cfedc5 --stat` -> 1 file, `csi-spl-doc/doc/md/refactor-round-65-plan.md`
(312 lines, read in full at that sha). origin/master at my read:
`93a625324be56d6d5dced9cb4acbb1aa7eb16daf` — the plan's measuring sha, trunk HEAD.

## Verdict

**PASS on `061cfedc55e6a291e0954538f7565c8ffba3eac4`** (plan v0.1, 2 rows). All
eight checks below ran with the printed output; every cited file:line was read with
`git show <sha>:<file> | sed -n <N>p`. One defect: W1 (one wrong prose word, plan
line 22; the rows and their batch order are unaffected). Notes: N1..N4 below.

## Checks (each with the command run and what it printed, 2026-11-19 09:2x-09:4xZ)

### 1. Slug r65 unused

- `git log origin/master --oneline -E --grep='\(r65-' | wc -l` -> **0**.
- `git ls-remote origin | grep -E 'r65-[0-9]{2}|refactor-round-65'` ->
  `061cfedc55e6a291e0954538f7565c8ffba3eac4  refs/heads/review/c002-refactor-round-65-planner`
  only — the planner's branch, expected; my own review branch
  `review/c002-refactor-round-65-mistral-seat` did not exist on origin at read
  time. Nothing else named.
- `git ls-tree --name-only 93a625324 csi-spl-doc/doc/md/ | grep -c 'round-65'`
  -> **0** (no `refactor-round-65*` file on the measuring sha, so the plain plan
  name is free, rulebook 5.3 "Files").
- Window W re-verified: `git log origin/master -1 --format='%H %cI %s' -E
  --grep='^docs\(r64-plan'` -> `86572482f2afd0d651005c345606f5dec20307f2
  2026-11-19T09:04:00+02:00 docs(r64-plan, SPL-5921): ...` — matches the plan's W.
  Control: `git log origin/master --oneline -E --grep='\(r64-' | wc -l` -> **4**
  (`87d56eaae` r64-01, `86572482f`, `103da374f`, `cd840afe0` the plans), so the
  read sees a used id.

### 2. Every site file:line of both rows exists on `93a625324` and on origin/master

`git show <sha>:<file> | sed -n <N>p` for each site, on both shas — identical on
the two (origin/master == 93a625324 at my read) and matching the plan's section
1.2 wording:

- `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh:59` ->
  `# @param REFLECTION_ZOMBIE_LOG (optional) - default /var/csi/csi-spl/zombie-topics/cron.log`
- `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh:203` ->
  `out="$(grep -h 'OK zombie sweep, night of' "${REFLECTION_ZOMBIE_LOG:-/var/csi/csi-spl/zombie-topics/cron.log}" 2>/dev/null | tail -1)"`
- `csi-spl-orc/src/bash/features/graft/scripts/graft-index-dir.sh:20` ->
  `# GRAFT_VAR_ROOT (default /var/csi/csi-spl/graft) is the box-wide graft state:`
- `csi-spl-orc/src/bash/features/graft/scripts/graft-index-dir.sh:24` ->
  `graft_var_root() { printf '%s' "${GRAFT_VAR_ROOT:-/var/csi/csi-spl/graft}"; }`
- `csi-spl-orc/src/bash/features/graft/scripts/graft-cron.sh:11` ->
  `# $GRAFT_VAR_ROOT/repos.list (default /var/csi/csi-spl/graft/repos.list). The`
- `csi-spl-orc/src/bash/features/graft/tests/test-graft-index-dir.sh:27` ->
  `is "$(env -u GRAFT_INDEX_ROOT -u GRAFT_VAR_ROOT bash "$D" "$T/src/my-repo")" "/var/csi/csi-spl/graft/index/$SLUG" "default: the box-wide csi-spl state dir, not a home"`
- `csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh:192` ->
  `REFLECTION_REPO="$R" REFLECTION_ZOMBIE_LOG="$T/zombie.log" ...` (the one
  `REFLECTION_ZOMBIE_LOG` use sets the var, so no case reads the default today).

Drift: `git log 93a625324..origin/master --oneline -- <the 6 row files> | wc -l`
-> **0** (origin/master is exactly `93a625324` at my read). Also
`git log origin/master --since="2026-11-19T09:04:00+02:00" --oneline -- <the 6
files> | wc -l` -> **0**, matching the plan's 2.2.

Counts re-measured on `93a625324`:
`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 93a625324 --
csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh` -> **2 lines** (`:59`,
`:203`); `-- csi-spl-orc/src/bash/features/graft/` -> **7 lines**, 3 in the 2
scripts (`graft-cron.sh:11`, `graft-index-dir.sh:20,24`) plus `test-graft-index-dir.sh:27`
and 3 md docs; the non-test `*.sh` scan (`git grep -cE <literal> 93a625324 --
'*.sh' ':!*.func.sh' ':!**/tests/**'`) -> exactly **2 files** (`graft-cron.sh:1`,
`graft-index-dir.sh:2`). All match the plan.

### 3. The baseline

`git show origin/master:csi-spl-orc/src/bash/tests/no-literal-paths.baseline |
grep -vE '^\s*(#|$)'` -> **4 files, 10 lines** (`3 spl-cmd-guard-mode`,
`2 spl-file-erase`, `2 spl-reflection-gather`, `3 fleet-logrotate-install`) —
matches the plan's "4 files / 10 lines today". Graft's lines are **not** in it
today: `... | grep -n 'graft'` -> rc 1 (no match); `grep -n
'spl-reflection-gather'` -> line 4 `2 csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh`.

r64-02's branch `review/r64-02` @ `3479bf7facf9f1b76b8fca225c9a38f39049bdab`
(`git ls-remote origin | grep r64` -> that one ref) adds exactly graft's lines:
`git show origin/review/r64-02:.../no-literal-paths.baseline | grep -vE '^\s*(#|$)'`
-> 6 files / 13 lines, with `1 .../graft-cron.sh` and `2 .../graft-index-dir.sh`.
The gate fails a stale entry: `git show origin/master:.../no-literal-paths.tst.sh
| grep -n STALE` -> `:50` ("STALE baseline: ... has N, baseline M: lower it")
and `:51` ("... has none: drop its line").

Batch order makes each row's baseline edit apply: row 01 (batch 1, after r64-02)
drops its own 2 `spl-reflection-gather` lines, present today and still present
after r64-02; row 02 (batch 2, after 01) drops graft's 3 lines that r64-02 added.
The plan's fallback (2.1: if r64-02 ends without landing, row 02 drops none and
its control is the literal grep -> 0) is consistent with today's master state.

### 4. Each row: practice, R2 control/test, test list, vendor, kind, batch; R7 reviewer

Plan section 2 table (lines 152-153): both rows carry practice ("no literal box
path", developer guide 2.3.1), why, sites file:line (4 entries each, max 5), n
("1 file, 2 lines" / "2 files, 3 lines"), test + red control (row 01: `:203`
reads `${REFLECTION_ZOMBIE_LOG:-$SPL_VAR_APP_DIR/zombie-topics/cron.log}` after
`spl_run_paths`, new case in `spl-reflection-gather.tst.sh`; row 02:
`graft_var_root` prints `${GRAFT_VAR_ROOT:-$SPL_VAR_APP_DIR/graft}`, empty-root
rc 1 via the existing `graft-index-dir.sh:37`, new case in
`test-graft-index-dir.sh:27`), box `either`, **vendor claude**, **kind
simple_coding**, batch `1 (after r64-02)` / `2 (after 01)`. No mistral coding or
testing row (owner 10-17, t1 b61851fb msg 91bf8278). R7 reviewer (plan section
4): cross-vendor first — agy if its pick still holds, else a fresh claude seat
under the claude waiver; "Not a mistral code R7". Compliant with rulebook 2.7.2
and the owner's mistral rule.

Test lists re-run with the plan's NAMES command on `93a625324`: r65-01 -> **3**
files (`spl-reflection-gather.tst.sh`, `no-literal-paths.baseline`,
`orc-shard-weights.txt`); r65-02 -> **4** files (`test-graft-cron.sh`,
`test-graft-index-dir.sh`, `test-graft-safe.sh`, `install-box-crons.tst.sh`) —
both match the plan. All six named test files exist on origin/master
(`git cat-file -e origin/master:<f>` -> OK x6). R2 bullet 2, the five 30-char
strings of the changed lines, `git grep -lF '<string>' 93a625324 --
'csi-spl-*/**/tests/*' | wc -l` -> **0** each.

### 5. Behaviour: no-change proof and SPL_VAR_APP_DIR on this box

The plan states each lane's control (section 2, "Control for both rows"): on the
box the derived path equals the old literal, printed from the main checkout with
`APP_PATH` unset, with the env override set (override wins), and with
`SPL_RUN_PATHS_TOP=` (no tree) giving the row's no-dir answer; row 01 also runs
`REFLECTION_FORCE=1 ./run -a do_spl_reflection_gather` before/after; both outputs
in the commit body. The writer side holds: `git show origin/master:
csi-spl-orc/cnf/box-crons/box-crons.manifest | sed -n 62p` ->
`zombie-topics | */15 * * * * | src/bash/scripts/zombie-topics-cron.sh |
zombie-topics/cron.log | | desk`; `install-box-crons.func.sh:36` ->
`# @param BOX_CRONS_STATE_DIR (optional) - the logs' root, default SPL_VAR_APP_DIR`,
`:52` uses `${BOX_CRONS_STATE_DIR:-}`, `:61` FATALs when no tree.

`SPL_VAR_APP_DIR` on this box resolves to the old literal's root:
`cd /opt/csi/csi-spl/csi-spl-orc && env -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR
-u SPL_RUN_PATHS_TOP bash -c 'source lib/bash/funcs/spl-run-paths.func.sh &&
spl_run_paths && echo "SPL_VAR_APP_DIR=$SPL_VAR_APP_DIR"'` ->
`SPL_VAR_APP_DIR=/var/csi/csi-spl` (and `SPL_ORG_DIR=/opt/csi`). The derivation is
`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh:69`
(`: "${SPL_VAR_APP_DIR:=${base%/*}/var/${org##*/}/${main##*/}}"`), with the
"Read from the file, no git call" comment at `:42`. The old literals' roots exist
on the box: `ls -ld /var/csi/csi-spl /var/csi/csi-spl/zombie-topics/cron.log
/var/csi/csi-spl/graft` -> all three present (cron.log last written 2026-11-19
10:30 local). So derived path = old literal here; the no-behaviour-change claim
is provable by the plan's control.

### 6. R3: lane-map over the 6 written paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh,csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh,csi-spl-orc/src/bash/tests/no-literal-paths.baseline,csi-spl-orc/src/bash/features/graft/scripts/graft-index-dir.sh,csi-spl-orc/src/bash/features/graft/scripts/graft-cron.sh,csi-spl-orc/src/bash/features/graft/tests/test-graft-index-dir.sh
--agent m-302` -> **exit 4**: no live lane lists the paths, but 4 live lanes
record no files: `c-706@sat` (SPL-5888), `c-852@sat` (SPL-5883 T01),
`c-855@sat` (SPL-5883 T16), `c-859@sat` (r64-02, `no-literal-paths.tst.sh` and
`.baseline`) — the same 4 the plan's 2.2 named at 09:13:05Z. Exit 4 means
"unknown, ask first", not free; the plan already serialises both rows behind
c-859 (r64-02) because only it touches a row path (the baseline). My seat writes
only this seat file, so no collision with any lane.

### 7. R1 across rounds: no live perf or bug round row names these files

- Newest perf plan on origin/master: `perf-round-18-plan.md`;
  `git show origin/master:csi-spl-doc/doc/md/perf-round-18-plan.md | grep -cE
  'spl-reflection-gather|graft-index-dir|graft-cron|graft_var_root|no-literal-paths'`
  -> **0**.
- Newest bug plan: `bug-round-19-plan.md` -> **1** match, line 80, a closed
  holder's-list row ("SPL-5825 ... (reflection gather) ... Closed as round 18
  section 4 says (fixed by r61-02 and b14-01 ...)") — not a live row on these
  files.
- The b20 plan branch does not exist on origin:
  `git ls-remote origin | grep -E 'bug-round-20|c-291'` -> rc 1, nothing.
- All round plans on origin/master mentioning the row files (count per file):
  `bug-round-14` 5, `bug-round-15` 2, `bug-round-18` 1, `bug-round-19` 1,
  `refactor-round-35` 2, `refactor-round-63` 1, `refactor-round-64` 7 — the same 7
  plans the plan's 2.2 lists. b14-01 landed: `git merge-base --is-ancestor
  ce765392c origin/master` -> exit 0. bug-round-18's mention (line 75) is the
  same closed SPL-5825 holder's-list item. No unlanded row names either file.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-302`, exit **0**.

## Defects

- **W1** — plan line 22 (section "What this round is"): "Round 64 ... has
  r64-01 landed (`87d56eaae`) and **r64-02 live** (the `no-literal-paths` gate
  widened to non-test `*.sh`; graft's 2 scripts enter its baseline)". r64-02 is
  not live — it is not even on master: `git log origin/master --oneline -E
  --grep='\(r64-'` -> 4 commits, none a r64-02 row (`87d56eaae` r64-01 plus the
  three plan commits); the only `--grep='r64-02'` hit is `87d56eaae`'s body.
  On master the gate still scans only the cnf and `*.func.sh`
  (`git show origin/master:csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh |
  sed -n 36p` -> `git ... ls-files -z -- 'csi-spl-cnf/*.yaml' ... '*.func.sh' |`),
  and the baseline on master has no graft lines (check 3). The widened scan and
  the graft baseline lines exist only on `review/r64-02` @ `3479bf7f`
  (`sed -n 40,41p` there adds `'*.sh' ':!:*/tests/*' ':!:tests/*'`). Per
  how-to-post rule 14, "live" means on master AND deployed. The rows themselves
  are unaffected: plan 2.1 correctly serialises both behind r64-02 and the brief
  says "not landed". Fix the word in v1.0: "r64-02 unlanded (`review/r64-02`)".

## Notes

- N1: origin/master was exactly the measuring sha `93a625324` at my read, so
  every count in the plan is also the trunk count; no drift to re-measure
  (check 2's drift log is empty).
- N2: my lane-map read returned exit 4 (check 6), same 4 unknown lanes as the
  plan's 09:13:05Z read; the holder's R3 re-check before each row's spawn still
  governs, and exit 4 is "ask first", not free.
- N3: the plan's live-state readings (spawn queue, vendor picks, briefs grep run
  as root on the planner's box) carry their own timestamps and were not re-run by
  this seat; the tree-side claims they rest on were all re-run here (checks 1-3,
  7). The dispatcher's candidates file is on the other box and unreadable here,
  as the plan says.
- N4: the plan's section 6 count chain re-verified arithmetically against
  check 3: 4 files/10 lines today -> 6/13 after r64-02 (verified on its branch)
  -> 5/11 after r65-01 (drops 2 reflection lines) -> 3/8 after r65-02 (drops
  graft's 3); non-test `*.sh` literals 2 files/3 lines today -> 0 after r65-02
  (verified by the scan in check 2).

## Signature

m-302@<box2> (mistral), 2026-11-19T09:4xZ: **PASS on
`061cfedc55e6a291e0954538f7565c8ffba3eac4`**, W1 (plan line 22, prose word
"live"), N1-N4.
