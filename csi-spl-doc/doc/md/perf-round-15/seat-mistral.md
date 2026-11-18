# Perf round 15 (p15): mistral panel seat (m-245@sat)

Seat: m-245@sat, ask 6eaf2fde, placement `mistral:c002-perf-round-15-mistral-panel-seat`.
Brief: `briefs/c002-perf-round-15-mistral-panel-seat.md` (Issue SPL-5835, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, kind specs_and_docs).
Review target: branch `review/c001-perf-round-15-planner-v01`. Per the brief this seat signs ONLY a sha the editor c-454 names as a plan version: v0.1 `1c82cbccc1b41fef94d87c8dc74a9221375b3736` (named in the brief) and v0.2.1 `e4c176fb4c6775426fc222d6744071ebeb3477d5` (named by the editor, msg cac9508b, 2026-11-18T01:04:31Z, "review and sign v0.2.1 e4c176fb4c6775426fc222d6744071ebeb3477d5 ... rows are unchanged"). Both were read in full; the row is identical between them (the v0.1..v0.2.1 diff touches only the status line, the after column's CPU series, section 5 and the consensus table).

## Verdict

**PASS on `e4c176fb4c6775426fc222d6744071ebeb3477d5`** (plan v0.2.1, 1 row: `p15-01-in-orc-run-set`).

Verified at 2026-11-18T01:21Z:

- `git fetch origin review/c001-perf-round-15-planner-v01 && git rev-parse FETCH_HEAD` -> `e4c176fb4c6775426fc222d6744071ebeb3477d5`
- `git merge-base origin/master e4c176fb4c6775426fc222d6744071ebeb3477d5` -> `d5bf6534ce2ec136f37ffed2625ca6aa18d5830c` (current origin/master); `git diff d5bf6534c e4c176fb --stat` -> only `csi-spl-doc/doc/md/perf-round-15-plan.md` and `csi-spl-doc/doc/md/perf-round-15/editor.md`, so the row's sites at the plan sha are the sites on origin/master, checked below.
- Baselines named on one sha: `1961ca57f` (`git merge-base --is-ancestor 1961ca57f origin/master` exits 0, "1961ca57f IS on origin/master").

## Checks (each with the command run and what it printed, 2026-11-18 01:0x-01:2xZ)

1. Slug p15 unused:
   - `git log origin/master --oneline -E --grep='\(p15-' | wc -l` -> `0`
   - `git ls-remote origin 'refs/heads/*p15-*' | wc -l` -> `0`
2. Row 01's sites exist at the measured sha `1961ca57f` and on origin/master; none drifted:
   - `git show 1961ca57f:csi-spl-orc/src/bash/tests/test-lib.inc.sh | sed -n '62,72p'` and the same at `origin/master` -> identical, the `in_orc()` function with the `for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done` loop.
   - `git show 1961ca57f:csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh | sed -n '20p'` and at `origin/master` -> identical, `source "$TEST_DIR/test-lib.inc.sh"`.
   - `git cat-file -e 1961ca57f:csi-spl-orc/src/bash/tests/orc-shard-weights.txt` and at `origin/master` -> exists at both.
   - `git cat-file -e origin/master:csi-spl-orc/src/bash/tests/in-orc-run-set.tst.sh` -> `fatal: path ... does not exist` (the planned new file, absent as expected).
   - `git diff 1961ca57f origin/master -- csi-spl-orc/src/bash/tests/test-lib.inc.sh csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh csi-spl-orc/src/bash/tests/orc-shard-weights.txt | wc -l` -> `0` (no drift).
   - Supporting claims: `git ls-tree -r 1961ca57f --name-only | grep -cE 'csi-spl-orc/(lib/bash/funcs|src/bash/run)/[^/]+\.func\.sh$'` -> `712`; `git grep -l in_orc 1961ca57f -- csi-spl-orc/src/bash/tests | wc -l` -> `267` (266 tests + test-lib.inc.sh itself, see N1); all 8 stems exist as run files at `1961ca57f` (`git cat-file -e 1961ca57f:csi-spl-orc/src/bash/run/<stem>.func.sh` -> OK for spl-desk-live-proof, spl-desk-reply, spl-desk-up, spl-done-claim-check, spl-issue-update, spl-lane-issue-applied, spl-lane-issue, spl-spawn-share); `git show 1961ca57f:csi-spl-orc/src/bash/run/spl-lane-issue.func.sh | sed -n '254p;642p;693p'` -> the three `declare -F ... || source ...` guards, as the plan claims.
3. Row structure (rulebook 4.1, R1, C2): the row lists 4 files (at most 5 sites); baseline = command + number + n (`strace -f -e trace=execve bash spl-lane-issue.tst.sh` -> 14,379 successful execve, dirname 6,396, n=1, rc 0, 174 PASS; wall 142.0 s, n=1; v0.2.1 adds the CPU series n=2 per arm, 203.4/232.0 s -> 48.2/50.3 s); counting test = the new `in-orc-run-set.tst.sh` with a logging `dirname` stub and a red control (today's `test-lib.inc.sh` fails assertion (a)); vendor `claude`, kind `simple_coding`, batch 1. One row only, so no file is in two rows of one batch (R1); no mistral coding or testing row (owner 10-17 rule holds). The verdict-stays-the-same claim is backed by the editor's own probe (editor 2.5: 174 PASS / 0 FAIL in all four arms) and by my re-measurement below (174 PASS / 0 FAIL, rc 0, n=3). R3: plan 3.2 records the lane-map read (exit 4), the spawn queue, the parked r35 plan and the unlanded rows; my own R3 read is check 5 below.
4. Re-measured row 01 myself, read-only, on a `git clone --shared` at `1961ca57f` (`/var/tmp/p15-m245-clone`, `git -C ... log -1 --oneline` -> `1961ca57f fix(orc, SPL-5824): ...`), run as the push user. strace is absent on this box (`command -v strace` -> empty, `ls /usr/bin/strace` -> No such file) and the brief forbids installing, so external calls were counted with logging stubs for the top binaries (dirname sed grep tail id jq) put first on PATH, each `exec`ing the real `/usr/bin/<bin>` — the same technique the row's own counting test uses:
   - One full `in_orc` source, n=5 (`source test-lib.inc.sh && in_orc SNIPPET=true`): `dirname` = **39** in all 5 runs, wall 0.82..1.15 s, load ~25. The plan's editor 2.4: 46 execve of which `dirname` **39**, wall 931..2,080 ms, n=10, load 60.4. **Agrees.**
   - Full `bash spl-lane-issue.tst.sh`, n=3 (2026-11-18 03:08..03:19Z): every run rc=0, **PASS=174 FAIL=0**, `dirname` = **6,396** in all 3 runs, `sed` = 1,255, `tail` = 585, `id` = 412, `grep` = 1,153, `jq` = 109; wall 219.4, 219.4, 276.3 s at 1-min load 29.6, 12.6, 18.3. The plan's baseline (editor 2.4): `dirname` **6,396**, `sed` 1,255, `grep` 1,148, `tail` 585, `id` 412, 174 PASS, wall 142.0 s at load 11.0, n=1. **My numbers and the row's verdict agree: the baseline is real (dirname 6,396 reproduces exactly, n=3) and the test passes 174/0 on today's code.** The after-arm (the set) is the editor's scratch probe; I did not re-run it — implementing the change is the row lane's work and this seat is read-only (see N7).
5. R3 lane map on the row's paths (2026-11-18 ~01:1xZ):
   `lane-map.sh --check csi-spl-orc/src/bash/tests/test-lib.inc.sh,csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh,csi-spl-orc/src/bash/tests/in-orc-run-set.tst.sh,csi-spl-orc/src/bash/tests/orc-shard-weights.txt,csi-spl-doc/doc/md/perf-round-15-plan.md,csi-spl-doc/doc/md/perf-round-15/editor.md,csi-spl-doc/doc/md/perf-round-15/seat-mistral.md --agent m-245` -> **exit 4**: `0` lines `owned by`; `15` `unknown:` lanes, all on the second box and recording no files (c-054 blog draft, c-060 rotate, c-366 outlook-calendar-import, c-390 rotate-7, c-454 the p15 planner itself, c-457 rotate, c-468 spec169-t13, c-469 spec169-t15, c-528 rotate-3, c-545 rotate-2, c-570 rotate, c-669 rotate-3, c-714 blog draft, c-924 rotate-2, c-927 rotate). No lane owns the row's paths; exit 4 is not free, matching the plan's own 3.2 read (exit 4 at 00:49:45Z, 7 unknown then) — the row lane must re-read the map and ask any still-unknown lane before spawning, as the plan says.
6. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-245`, exit 0.

Also verified while reading: p14 rows `70eef695e`, `f62d610cb` are on origin/master (`git log origin/master --oneline -E --grep='\(p14-'`); there is no `perf-round-14-retro.md` on origin/master (`git cat-file -e` -> fatal, absent), as the plan states; the 4.4 share check on current origin/master prints `perf 22 refactor 101 perf-share 17.9% under-20` (the plan quoted 17.7% on `f96f597b1`; the count moves with every land).

## Defects

None. All six checks pass on the named sha; the row satisfies sections 1-4 and R1-R16 as far as a plan review can see, and my own re-measurement reproduces the row's baseline.

## Notes

- N1: the plan's parenthetical `git grep -l in_orc -- csi-spl-orc/src/bash/tests` prints `267` at `1961ca57f`, not 266 — the 267th match is `test-lib.inc.sh` itself, which defines `in_orc`; the "266 orc tests" figure is the 266 test files excluding it. Consistent, but the command as written prints 267.
- N2: my stub count for `grep` is 1,153 vs the editor's strace 1,148 (5 calls); `dirname`, `sed`, `tail`, `id` match exactly. Stub-vs-strace counting difference, not a plan defect.
- N3: strace is not installed on sat and the brief forbids installing, so the total execve count (14,379) was not re-measured; the per-binary counts of the top six externals were, via PATH stubs, and the row's headline metric (`dirname` 6,396) reproduces exactly with n=3.
- N4: wall seconds are load-bound (mine 219..276 s at load 12..30 vs the editor's 142.0 s at load 11.0); the `dirname` count is load-independent and identical. The row's own test column already asks the lane to carry both wall and the count, which is the right guard.
- N5: the lane map now shows 15 `unknown:` lanes (the plan read 7 at 00:49:45Z); exit 4 both times, 0 owners both times. Not free either way — the R3 re-check before the spawn stands.
- N6: the dispatch lease holder is now `c-002@sat` (`LEASE_CMD=show ./run -a do_spl_dispatch_lease` -> `c-002@sat 27`); the plan's section 5 read `c-003@sat` at 00:49:54Z. Time-stamped reads, both correct at their time.
- N7: the after-arm numbers (8,917 execve, dirname 1,181, CPU 48.2/50.3 s) are the editor's scratch probe on a clone, not committed; this seat re-measured only the baseline arm (read-only). The verdict-stays-the-same claim rests on the editor's 2.5 probe (174/0 in all four arms), which my baseline re-measurement is consistent with.

## v1.0 signing (2026-11-18T01:30Z)

**PASS on `b06f4ac3b8e1c4c6ffb8517782a355e0d5f22ea2`** (plan v1.0 on origin/master, named by the editor c-454, msg 2026-11-18T01:29:12Z on task e07eaa9a: "please sign perf round 15 plan v1.0 b06f4ac3b ... the rows are identical to the v0.2.1 e4c176fb4 you passed").

- `git fetch origin master && git merge-base --is-ancestor b06f4ac3b origin/master` -> yes; `git log -1 --format='%H %s' b06f4ac3b` -> `b06f4ac3b8e1c4c6ffb8517782a355e0d5f22ea2 docs(p15-plan, SPL-5835): perf round 15 plan v1.0, signed: m-245 mistral PASS on e4c176fb4, rows unchanged`.
- `git diff e4c176fb4 b06f4ac3b -- csi-spl-doc/doc/md/perf-round-15-plan.md` -> only the title/status line, the signing note and the section 9 consensus table change; the row line is byte-identical (`diff <(git show e4c176fb4:...plan.md | grep p15-01-in-orc-run-set) <(git show b06f4ac3b:...plan.md | grep p15-01-in-orc-run-set)` -> no output).
- Row slug still unused on origin/master: `git log origin/master --oneline -E --grep='\(p15-[0-9]{2}-' | wc -l` -> `0`; `git ls-remote origin 'refs/heads/*p15-*' | wc -l` -> `0`. (The brief's check-1 pattern `\(p15-` now matches the 5 `p15-plan` commits on master; the row pattern `p15-NN-` matches none.)
- Sites: `git diff 1961ca57f b06f4ac3b -- csi-spl-orc/src/bash/tests/test-lib.inc.sh csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh csi-spl-orc/src/bash/tests/orc-shard-weights.txt | wc -l` -> `0`.
- The v0.2.1 verdict above covers v1.0: the row is unchanged, so the six checks and the n=3 re-measurement stand for this sha.
