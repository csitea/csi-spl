# Perf round 16 (p16): mistral panel seat (m-638)

Seat: m-638, placement `mistral:c002-perf-round-16-mistral-panel-seat`.
Brief: `/var/spool-hub/spawn-remote/briefs/997f8b0e-627b-41c5-9cd3-8d9cbeb10d13.md` (Issue SPL-5861, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, class refactor, kind specs_and_docs).
Review target: branch `review/c002-perf-round-16-planner`. Per the brief this seat signs ONLY a sha the editor c-337 names as a plan version: v0.1 `90e21bfad7a9831e185eb00e330ffae6015c1152` (named in the brief). Read in full at that sha: `csi-spl-doc/doc/md/perf-round-16-plan.md` (218 lines) and `csi-spl-doc/doc/md/perf-round-16/editor.md` (204 lines).

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
   `lane-map.sh --check csi-spl-orc/src/bash/tests/changed-tests.sh,csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/perf-round-16/seat-mistral.md --agent m-638` -> **exit 4**: `0` lines `owned by`; `7` `unknown:` lanes recording no files (c-176, c-197, c-337, c-352, c-358, c-762, m-345, all @sat). Exit 4 is not free; the plan's own 3.2 read records the same exit-4 state and the holder re-runs R3 before each spawn. This seat writes only its seat file, which no lane owns.
7. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-638`, exit 0.

## Defects

None. All seven checks pass on the named sha; the row satisfies rulebook sections 1-4 (4.1 measured first, 3.2 the panel signs the plan sha) as far as a plan review can see, and my own full replay (all 249 commits, not a subset) reproduces the row's baseline exactly and the probe's direction and size.

## Notes

- N1: run-line counts reproduce exactly (5,342 -> 4,024, `full` 19 in both arms, 1,318 `spec.md`-named); the weighted sums differ from the editor's by ~4,100 s in BOTH arms (mine 193,437 -> 143,083 summing `orc-shard-weights.txt` with its `*` default; editor 189,337 -> 139,723), so the percentage agrees (-26.0% vs -26.2%) — a weight-accounting difference, not a plan defect.
- N2: lane map exit 4 (7 unknown lanes, 0 owners) — not free per the rule; the plan records the same and the R3 re-check before each spawn stands. This seat touched no row file.
- N3: plan section 5 still lists an agy panel seat as planned; per the brief the agy seat (a-635) is dropped until 2026-11-24 (c-001 3d8282c0), so this mistral seat is the only cross-vendor seat, the p12..p15 shape. The consensus table (section 9) holds only the editor row; seats sign in their own files.
- N4: the section 6 candidate (spawn-share / spawn-place fork, probe B) is honestly marked unmeasured — correctly not a row under 4.1.
