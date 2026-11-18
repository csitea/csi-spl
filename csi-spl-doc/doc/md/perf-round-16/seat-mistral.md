# Perf round 16 (p16): mistral panel seat (m-638)

Seat: m-638, placement `mistral:c002-perf-round-16-mistral-panel-seat`.
Brief: `/var/spool-hub/spawn-remote/briefs/997f8b0e-627b-41c5-9cd3-8d9cbeb10d13.md` (Issue SPL-5861, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, class refactor, kind specs_and_docs).
Review target: branch `review/c002-perf-round-16-planner`. Per the brief this seat signs ONLY a sha the editor c-337 names as a plan version: v0.1 `90e21bfad7a9831e185eb00e330ffae6015c1152` (named in the brief) and v0.2 `8b3fa986c1738080b810ac8f112a4d74dcd0ec5d` (named by c-337, msg 365731e6, 2026-11-18T07:01:12Z, and by the dispatch holder c-002 on task `dispatch-perf-r16`, msg 0aa2c244: "Review THIS sha instead of v0.1"). Read in full at each sha: `csi-spl-doc/doc/md/perf-round-16-plan.md` and `csi-spl-doc/doc/md/perf-round-16/editor.md`.

## Verdict

**PASS on `90e21bfad7a9831e185eb00e330ffae6015c1152`** (plan v0.1, 1 row: `p16-01-orc-map-shared-doc-name`).

Verified at 2026-11-18T06:4x-06:5xZ:

- `git fetch origin review/c002-perf-round-16-planner && git rev-parse FETCH_HEAD` -> `90e21bfad7a9831e185eb00e330ffae6015c1152`; `git ls-remote origin | grep perf-round-16` -> only `refs/heads/review/c002-perf-round-16-planner` at that sha.
- `git show --stat 90e21bfa` -> +2 files vs master: `csi-spl-doc/doc/md/perf-round-16-plan.md` +218, `csi-spl-doc/doc/md/perf-round-16/editor.md` +204.
- Baseline sha named by the plan: `2fe3729e3` (`git merge-base --is-ancestor 2fe3729e3 origin/master` exits 0).

## Checks (each with the command run and what it printed, 2026-11-18 06:4x-06:5xZ)

1. Slug p16 unused:
   - `git log origin/master --oneline -E --grep='\\(p16-' | wc -l` -> `0`
   - `git ls-remote origin | grep -E 'p16-[0-9]{2}'` -> no output, grep exit 1
2. Row 01's sites exist at `2fe3729e3` and on origin/master; none drifted:
   - `git show 2fe3729e3:csi-spl-orc/src/bash/tests/changed-tests.sh | sed -n '8,14p'` -> the header comment; `sed -n '72,87p'` -> `keys()`; the same two ranges at `origin/master` -> identical.
   - `git show 2fe3729e3:csi-spl-doc/doc/md/pre-push-gate.md | sed -n '73,84p'` -> the orc fast-tier paragraph naming the map (`changed-tests.sh`, `ORC_TEST_ALWAYS`); identical at `origin/master`.
   - `git show 2fe3729e3:csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh | wc -l` -> `159`, cases `# 1`..`# 12` present (the row's "case 13" is the new case the row lands, absent today as expected); identical at `origin/master`.
   - `git diff 2fe3729e3 origin/master -- csi-spl-orc/src/bash/tests/changed-tests.sh csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh csi-spl-doc/doc/md/pre-push-gate.md` -> empty (no drift).
   - Supporting claim: `git ls-tree -r --name-only 2fe3729e3 | grep -c '/spec.md$'` -> `186` (plan: "spec.md is the basename of 186 tracked files").
3. Row structure (rulebook 4.1, R1, C2): the row lists 3 files / 4 site references (at most 5 sites); baseline = command + number + n (replay of the 249 `origin/master` commits since 2026-11-11T05:45Z touching `csi-spl-orc/` — `git log origin/master --since='2026-11-11T05:45Z' --format='%H' -- csi-spl-orc/ | wc -l` -> `249` — each commit's files through `ORC_TEST_FILES=<files> ORC_TEST_ALWAYS= bash changed-tests.sh` on `2fe3729e3` -> 5,342 `run` lines, 189,337 weighted CI s, n=1); counting test = `run-all-tests-changed.tst.sh` case 13 with controls (a) a change to `b/spec.md` selects neither `specfix.tst.sh` nor `areader.tst.sh`, (b) CONTROL a change to `a/spec.md` selects `areader.tst.sh`, (c) CONTROL a change to `only-one.md` selects `onefix.tst.sh`; red control = today's `changed-tests.sh` fails (a). Vendor `claude`, kind `simple_coding`, batch 1. One row only, so no file is in two rows of one batch (R1); no mistral coding or testing row (owner 10-17 rule holds). The coverage-side claim (no test that should run is dropped) is backed by probe output — re-verified by me in check 4.
4. Re-measured row 01 myself, read-only, in a local clone at `2fe3729e3` (`git clone --no-hardlinks /opt/csi/csi-spl-wt/m-638 /var/tmp/p16-clone && git -C /var/tmp/p16-clone checkout 2fe3729e3`; `git log -1 --format=%H` -> `2fe3729e3bb242c8451632d5e95db7eb0803ed21`); no prd write. All 249 commits, not a subset: per commit, `git diff-tree --no-commit-id --name-only -r <c>` fed to `ORC_TEST_FILES=<files> ORC_TEST_ALWAYS= bash csi-spl-orc/src/bash/tests/changed-tests.sh`:
   - before arm: `run` lines = **5,342**, `full` = **19**, weighted s (sum of `orc-shard-weights.txt` per selected test, its `*` line as default) = **193,437**; `run` lines with `names .../spec.md` = **1,318**. Matches the editor's 5,342 / 19 / 1,318 exactly.
   - after arm (scratch patch of `keys()` in the clone, never committed: a `.md` whose basename more than one tracked `.md` carries keys by its repo path only; shared names read once per run via `git ls-files -- '*.md' | awk -F/ '{print $NF}' | sort | uniq -d`; `bash -n` OK): `run` lines = **4,024** (-24.7%), `full` = **19**, weighted s = **143,083** (-26.0%). Editor's probe: 4,024 (-24.7%), 139,723 s (-26.2%). **Direction and rough size agree.**
   - single-commit probes: `ORC_TEST_FILES=csi-spl-doc/specs/157-dispatch-automation/spec.md` -> before 16 `run` lines, after `ignore\tcsi-spl-doc/specs/157-dispatch-automation/spec.md\tdoc` (0 tests); `ORC_TEST_FILES=csi-spl-doc/specs/148-local-dev-mode/spec.md` -> after still prints `run\tdev-mode-root-one-liner.tst.sh\tnames csi-spl-doc/specs/148-local-dev-mode/spec.md` (16 -> 1).
   - coverage side: `grep -l 'spec\.md' csi-spl-orc/src/bash/tests/*.tst.sh | wc -l` -> `16`; of those, 15 write or name only fixture paths under their temp dirs (`$T`/`$R`/`$SR`); the one real-path reader is `dev-mode-root-one-liner.tst.sh:25` (`SPEC="$APP_ROOT/csi-spl-doc/specs/148-local-dev-mode/spec.md"`), kept by the after arm. No test gained selections; the two fully dropped tests (`spl-spec-progress.tst.sh`, `wui-deploy-newest.tst.sh`) reference only fixture `tasks.md` / `README.md` paths.
5. R1 across rounds: bug round 15 plan v1.0 `f529b3091` — `git show f529b3091:csi-spl-doc/doc/md/bug-round-15-plan.md | sed -n '57,60p'` -> rows hold `spl-lane-rotate.func.sh`, `lane-rotate.tst.sh`, `spl-spawn-group-put.func.sh`, `spl-spawn-group.tst.sh`, `csi-spl-doc/specs/135-work-process/spec.md`, the four `run.sh` copies, `run-log.tst.sh`, and the off-limits line names p16's candidate files (`changed-tests.sh`, `run-all-tests-changed.tst.sh`, `pre-push-gate.md`, ...). No p16 row names one of them (p16 row 01 names only `changed-tests.sh`, `run-all-tests-changed.tst.sh`, `pre-push-gate.md`).
6. R3 lane map on the row's paths + this seat file (2026-11-18T06:5xZ):
   `lane-map.sh --check csi-spl-orc/src/bash/tests/changed-tests.sh,csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/perf-round-16/seat-mistral.md --agent m-638` -> **exit 4**: `0` lines `owned by`; `7` `unknown:` lanes recording no files (c-176, c-197, c-337, c-352, c-358, c-762, m-345, all on the editor's box). Exit 4 is not free; the plan's own 3.2 read records the same exit-4 state and the holder re-runs R3 before each spawn. This seat writes only its seat file, which no lane owns.
7. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-638`, exit 0.

## Defects

None. All seven checks pass on the named sha; the row satisfies rulebook sections 1-4 (4.1 measured first, 3.2 the panel signs the plan sha) as far as a plan review can see, and my own full replay (all 249 commits, not a subset) reproduces the row's baseline exactly and the probe's direction and size.

## Notes

- N1: run-line counts reproduce exactly (5,342 -> 4,024, `full` 19 in both arms, 1,318 `spec.md`-named); the weighted sums differ from the editor's by ~4,100 s in BOTH arms (mine 193,437 -> 143,083 summing `orc-shard-weights.txt` with its `*` default; editor 189,337 -> 139,723), so the percentage agrees (-26.0% vs -26.2%) — a weight-accounting difference, not a plan defect.
- N2: lane map exit 4 (7 unknown lanes, 0 owners) — not free per the rule; the plan records the same and the R3 re-check before each spawn stands. This seat touched no row file.
- N3: plan section 5 still lists an agy panel seat as planned; per the brief the agy seat (a-635) is dropped until 2026-11-24 (c-001 3d8282c0), so this mistral seat is the only cross-vendor seat, the p12..p15 shape. The consensus table (section 9) holds only the editor row; seats sign in their own files.
- N4: the section 6 candidate (spawn-share / spawn-place fork, probe B) is honestly marked unmeasured — correctly not a row under 4.1.

## v0.2 signing (2026-11-18T07:0x-08:2xZ)

**PASS on `8b3fa986c1738080b810ac8f112a4d74dcd0ec5d`** (plan v0.2 on `review/c002-perf-round-16-planner`, 2 rows: p16-01 unchanged, new p16-02 `orc-spawn-share-briefs-one-pass`). Named by the editor c-337 (msg 365731e6, 2026-11-18T07:01:12Z) and by the dispatch holder c-002 on task `dispatch-perf-r16` (msg 0aa2c244, 2026-11-18T07:01:40Z: "Review THIS sha instead of v0.1").

- `git fetch origin review/c002-perf-round-16-planner && git rev-parse FETCH_HEAD` -> `8b3fa986c1738080b810ac8f112a4d74dcd0ec5d`; `git log --oneline 90e21bfa..FETCH_HEAD` -> one commit, `8b3fa986c docs(perf-round-16-plan, SPL-5861): perf round 16 plan v0.2, 2 rows, row 02 spawn-share briefs in one pass`; `git diff --stat 90e21bfa FETCH_HEAD` -> only the plan and `editor.md`.
- Row 01 is unchanged between v0.1 and v0.2 (its table line is context in the v0.1..v0.2 diff), so the v0.1 verdict and re-measurement above cover it.

Checks re-run on v0.2 (2026-11-18 07:0x-08:2xZ):

1. Slug p16 still unused: `git log origin/master --oneline -E --grep='\\(p16-' | wc -l` -> `0`; `git ls-remote origin | grep -cE 'p16-[0-9]{2}'` -> `0`.
2. Row 02's sites exist at `2fe3729e3` and on origin/master; none drifted:
   - `git show 2fe3729e3:csi-spl-orc/src/bash/run/spl-spawn-share.func.sh | sed -n '189,197p'` -> `spl_spawn_share_briefs()`: the per-lane `grep -m1 -oiE ... | sed -E ... | tr ...` plus a `jq` per lane, exactly the site the row names.
   - `git log --oneline 2fe3729e3..origin/master -- '*spl-spawn-share*'` -> `0`; `git diff 2fe3729e3 origin/master -- csi-spl-orc/src/bash/run/spl-spawn-share.func.sh csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh` -> empty.
   - `git show 2fe3729e3:csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh | wc -l` -> `142`, header cases 1-13; the row's "case 14" is the new case the row lands, absent today as expected.
   - Row 01's sites re-checked: `git diff 2fe3729e3 origin/master -- csi-spl-orc/src/bash/tests/changed-tests.sh csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh csi-spl-doc/doc/md/pre-push-gate.md` -> empty (as at v0.1).
3. Row shape (rulebook 4.1, R1, C2): row 02 lists 2 files (at most 5 sites); baseline = command + number + n (logging `PATH` stubs: 164 execs per call with 41 lanes, n=1, deterministic; 20 calls 9.6/10.9/9.7 s, n=3; whole `spl-spawn-queue.tst.sh` 337.6/375.7/337.4 s wall, user+sys 369.2/369.8/366.3 s, n=3, 272 PASS each); counting test = `spl-spawn-share.tst.sh` case 14 with controls (a) at most 3 stubbed execs per call, (b) CONTROL the map equals the expected JSON, (c) CONTROL no lane -> `{}`; red control = today's function, about 4 execs per lane. Vendor `claude`, kind `simple_coding`, batch 1. Batch 1 = rows 01 and 02 in parallel, file sets disjoint (row 01: `changed-tests.sh`, `run-all-tests-changed.tst.sh`, `pre-push-gate.md`; row 02: `spl-spawn-share.func.sh`, `spl-spawn-share.tst.sh`). No mistral coding or testing row.
4. Re-measured row 02 myself, read-only, on clones of `2fe3729e3` (`/var/tmp/p16-clone` = arm S, `/var/tmp/p16-clone-r` = arm R, the share-half patch only, never committed):
   - Function alone, fixture of 41 lanes on the box (40 briefs incl. edge cases `Class: BUG`+second `Class:` line, `Class: ci.`, `Class:feature x`, `class: Refactor`, `Class: chore`, empty, plus 1 missing brief) and 1 lane on another box, logging `PATH` stubs for `jq grep sed tr`: arm S **162 execs** (41 grep, 39 jq, 41 sed, 41 tr — 39 jq because my fixture has 3 no-key lanes where the editor's had 1; the per-lane structure is identical to the editor's 164 = 41 each); arm R **3 execs** (1 grep, 2 jq) — matches the editor's "3: 1 grep, 2 jq" exactly. `jq -S` of both maps, `cmp` -> identical, edge cases included (`BUG`+second line -> `bug`, `ci.` -> `ci`, `Class:feature x` -> `feature`, `class: Refactor` -> `refactor`; chore / empty / missing -> no key).
   - Timed, n=3 per arm: S 1.06, 1.03, 0.85 s per call; R 0.03, 0.03, 0.03 s (this box at load ~16; the editor's 9.57/10.86/9.68 -> 0.36/0.27/0.22 s at load 24-26 — same direction, the size is load/box-bound).
   - Whole test `spl-spawn-queue.tst.sh`, n=2 per arm on the clones, 272 PASS / 0 FAIL / rc 0 in all four runs: concurrent pair S 250.3 s wall / 254.9 s CPU, R 244.4 s wall / 245.1 s CPU; sequential pair S 296.0 s wall / 284.5 s CPU, R 238.8 s wall / 248.3 s CPU. **Direction agrees** (wall and CPU both drop in every run); the size on this box (-3.8% to -12.7% CPU) is smaller than the editor's desk box (-20.5%) — per-call exec cost is box/load-bound, which is why the row's test column has the lane re-time on its own sha.
5. R1 across rounds: parked refactor round 35 v0.1 `27e21eefc` row 04 edits `orc:run/spl-spawn-place.func.sh:206,672` (`git show 27e21eefc:csi-spl-doc/doc/md/refactor-round-35-plan.md | grep -n 'spl-spawn-place'` -> lines 115, 140), so row 02 correctly leaves `spl-spawn-place.func.sh` out and moves the `| tail -1` site to section 6. Bug round 15 v1.0 `f529b3091` rows touch no p16 file (its plan lines 57-60, re-read at v0.2).
6. R3 lane map on all row paths + this seat file (2026-11-18T07:5xZ):
   `lane-map.sh --check csi-spl-orc/src/bash/tests/changed-tests.sh,csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-orc/src/bash/run/spl-spawn-share.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh,csi-spl-doc/doc/md/perf-round-16/seat-mistral.md --agent m-638` -> **exit 4**: `0` lines `owned by`; `6` `unknown:` lanes recording no files (c-176, c-197, c-337, c-352, c-762, m-345, all on the editor's box). Exit 4 is not free; the holder re-runs R3 before each spawn. This seat writes only its seat file.
7. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-638`, exit 0 (after N5 below).

## Defects (v0.2)

None. Both rows satisfy rulebook sections 1-4 as far as a plan review can see; my re-measurements reproduce row 01's counts exactly and row 02's exec-count structure and map equality exactly, with the whole-test direction agreeing on this box.

## Notes (v0.2)

- N5: this file's header first carried this box's qualifier (`m-638@<box>`); the distribution-hygiene Sweep bans the literal box name in `.github/workflows/10_ci-quality.yml`, so the header now reads `m-638` (spool messages keep `@<box>`; commit messages drop it per rulebook 2.7.4).
- N6: my whole-test gain on this box is smaller than the editor's (-3.8%..-12.7% CPU vs -20.5%) — box/load-bound; the deterministic exec count (162 -> 3 on my fixture, 164 -> 3 on the editor's) and the identical map are the load-independent proofs, and both reproduce.
- N1-N4 above stand for v0.2 unchanged.

## v1.0 signing (2026-11-18T07:3x-08:3xZ)

**PASS on `330bfc390728334e32114f86079da08d48b250d2`** (plan v1.0, landed on `origin/master`; named by the dispatch holder c-002 on task `dispatch-perf-r16`, msg 4b2129ab, 2026-11-18T07:3xZ).

- `git fetch origin master review/c002-perf-round-16-planner` -> `origin/master` = `330bfc390...`; `git merge-base --is-ancestor 330bfc390728334e32114f86079da08d48b250d2 origin/master` -> yes, v1.0 is on master. `git log --oneline 8b3fa986c..330bfc390` -> the editor rebased the plan onto master: `1f28c66b5` (v0.1), `ab7972761` (v0.2), `330bfc390` (v1.0).
- `git show --stat 330bfc390` -> doc only: `perf-round-16-plan.md`, `perf-round-16/editor.md`, `perf-round-16/seat-mistral.md` (this seat file folded in, with "all @sat" reworded to "all on the editor's box" for the public repo — the same rewording applied in this commit).
- Rows unchanged: `diff <(git show 8b3fa986c:csi-spl-doc/doc/md/perf-round-16-plan.md | grep -E '^\| 0[12] ') <(git show 330bfc390:csi-spl-doc/doc/md/perf-round-16-plan.md | grep -E '^\| 0[12] ')` -> empty (ROWS-IDENTICAL). The v0.2..v1.0 plan diff touches only the title/status line and section 9 (the consensus table with this seat's PASS, N1/N6 carried to the row lanes) — no row line.
- Slug: `git log origin/master --oneline -E --grep='\((p16-' | wc -l` -> `1` (the v0.2 plan commit `ab7972761`, whose body names the row id — as p15's seat noted for its plan commits); actual row commits `git log origin/master --format='%h %s' -E --grep='^perf\(p16-[0-9]{2}-' | wc -l` -> `0`; `git ls-remote origin | grep -cE 'p16-[0-9]{2}'` -> `0`. No row has landed.
- Sites: `git diff 2fe3729e3 330bfc390 -- csi-spl-orc/src/bash/tests/changed-tests.sh csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh csi-spl-doc/doc/md/pre-push-gate.md csi-spl-orc/src/bash/run/spl-spawn-share.func.sh csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh | wc -l` -> `0` (no drift; the b15 fixes landed after `f529b3091` touch none of the row files).
- R3: `lane-map.sh --check <the 5 row paths + this seat file> --agent m-638` -> exit 4, `0` owned, `5` unknown (c-176, c-197, c-337, c-762, m-345, all on the editor's box). Not free; the holder re-runs R3 before each spawn.
- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> clean, exit 0.

The v0.2 verdict above covers v1.0: the rows are byte-identical between `8b3fa986c` and `330bfc390`, so the seven checks and both re-measurements stand for this sha.

## Defects (v1.0)

None.

## Notes (v1.0)

N1-N6 above stand unchanged.
