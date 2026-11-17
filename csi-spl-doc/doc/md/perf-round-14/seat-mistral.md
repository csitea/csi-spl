# Perf round 14 (p14): mistral panel seat (m-031@sat)

Seat: m-031@sat, ask 8aaab744, placement `mistral:c002-perf-round-14-mistral-panel-seat`.
Brief: `briefs/c002-perf-round-14-mistral-panel-seat.md` (Issue SPL-5795, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, kind specs_and_docs).
Review target: branch `review/c001-perf-round-14-planner`. Per the brief this seat signs ONLY a sha that c-025@sat names on task `dispatch-perf-r14`; it does not review a moving head.

## Verdict

**PASS on `ad762145514300b5042a895c9f1bcd6cd5893d57`** (plan v0.2, 2 rows: `p14-01-wui-unit-pool`, `p14-02-api-pg-groups-pool`).

Named by c-025@sat on task `dispatch-perf-r14`, msg `57ec4e23` (2026-11-17T14:49:59Z): "sha to sign: **ad7621455**". Verified at 2026-11-17T14:50Z:

- `git ls-remote origin refs/heads/review/c001-perf-round-14-planner` -> `ad762145514300b5042a895c9f1bcd6cd5893d57`
- `git fetch origin review/c001-perf-round-14-planner && git rev-parse FETCH_HEAD` -> `ad762145514300b5042a895c9f1bcd6cd5893d57`

Read at 2026-11-17T15:0xZ: `git show ad7621455:csi-spl-doc/doc/md/perf-round-14-plan.md` (270 lines) and `git show ad7621455:csi-spl-doc/doc/md/perf-round-14/editor.md` (175 lines). The branch head later moved to `af1daf18156149ced3263ce618a185a2756e8ba7` (c-025 msg at 15:28:39Z): `git diff ad7621455 af1daf181 --stat` -> `perf-round-14/editor.md | 12 ++` only, and `git diff ad7621455 af1daf181 -- csi-spl-doc/doc/md/perf-round-14-plan.md | wc -l` -> `0`. This verdict names the sha actually read: `ad762145514300b5042a895c9f1bcd6cd5893d57`.

## Checks run (each with the command and what it printed)

1. Slug p14 unused (2026-11-17 ~14:56Z, on origin/master):
   - `git log origin/master --oneline -E --grep='\(p14-' | wc -l` -> `0`
   - `git ls-remote origin 'refs/heads/*p14-*' | wc -l` -> `0`
   - `git ls-tree -r --name-only origin/master | grep -c perf-round-14` -> `0`
   - Plan's "why now" re-verified: `git merge-base --is-ancestor 05791365d origin/master` and `... e3388fce3 ...` both exit 0 (p13-01, p13-02 on master); the rulebook 4.4 command on current origin/master printed `perf 20 refactor 100 perf-share 16.7% under-20` (same as the plan's 13:31:41Z read on `f9661ccf0`).
2. Each row's sites exist at the plan sha and on origin/master, no drift:
   - `git diff ad7621455 origin/master -- csi-spl-wui/src/node/test/run-unit-tests.mjs | wc -l` -> `0`
   - `git diff ad7621455 origin/master -- csi-spl-api/src/bash/tests/hub-pg.tst.sh | wc -l` -> `0`
   - Row 01 sites read with `git show <sha>:csi-spl-wui/src/node/test/run-unit-tests.mjs | sed -n '1,21p;29p;68,94p'` at both shas: `:1-21` the header/contract, `:29` `const UNIT_DIR = join(WUI, 'tests/unit')`, `:68-84` the `spawnSync` loop, `:86-94` the failure summary — identical at both shas.
   - Row 02 sites read with `git show <sha>:csi-spl-api/src/bash/tests/hub-pg.tst.sh | sed -n '210,275p'` at both shas: `:215` the `db_lock` flock, `:227-238` `store_groups`, `:239-250` `hub_groups`, `:251-268` the launch-and-wait (the two chains backgrounded, so today at most 2 groups at once), `:270` the "sequential groups" wording — identical at both shas.
   - Editor citations: `git show <sha>:csi-spl-iac/src/bash/run/check-pre-push.func.sh | sed -n '786p'` -> `"$2" run test:unit || exit 1`; `git show <sha>:.github/workflows/10_ci-quality.yml | sed -n '605p'` -> `run: pnpm run test:unit` (both shas).
3. Row shape (read of the plan table at ad7621455, rulebook sections 1-4):
   - Row 01: 4 edit ranges in 1 file (`:1-21`, `:29`, `:68-84`, `:86-94`) — at most 5 sites. Baseline with command + number + n: editor 2.2 probe `node src/node/test/run-unit-tests.mjs` -> 565.6 and 546.7 s, n=2, 524 green; pre-push log `wui` fast n=14 mean 650 s, full n=7 mean 640 s; CI wf 10 n=5, 124..168 s. Counting test with red control (4.1, C2): new `wui/tests/unit/unit-runner-pool.test.mjs`, asserts peak 4 with `WUI_UNIT_JOBS=4` and 1 with `=1`; red: today's runner -> peak 1 with `=4`. Vendor/kind/batch: claude / simple_coding / 1.
   - Row 02: 4 edit ranges in 1 file (`:227-238`, `:239-250`, `:251-268`, `:270`). Baseline: editor 2.3 `SPL_API_TEST_TIER=full bash csi-spl-api/src/bash/tests/run-all-tests.sh` -> 2,754 s whole run n=1, hub Postgres gate 1,830 s, package suites ~1,632 s; pre-push log `api` full n=9 mean 3,270 s. After: editor 2.4 uncapped scratch arm -> suites 967 s, gate 1,189 s, n=1, RC 0, `grep -cE 'not ok|FAIL'` -> 0. Counting test with red control: new `csi-spl-api/src/bash/tests/hub-pg-pool.tst.sh`, asserts peak = cap (3 with `HUB_PG_GROUP_JOBS=3`) and 1 with `=1`; red: today's script -> peak 2 with `=3`. Vendor/kind/batch: claude / simple_coding / 1.
   - R1: the two batch-1 file lists share no file (row 01: `run-unit-tests.mjs` + new test files; row 02: `hub-pg.tst.sh` + new files + `run-all-tests.sh` only to list the new test).
   - No mistral coding or testing rows: both rows claude (owner 10-17 rule, plan section "Owner orders").
   - Verdict-stays-same claims backed by probe output: row 01 "524 green in each arm" (editor 2.2 table); row 02 RC 0 with 0 FAIL lines (editor 2.4).
   - R3: plan section 3.2 reads the lane map twice (13:40:11Z, 14:27:57Z), the spawn queue twice, and the unlanded round rows; re-read by this seat in check 5 below.
   - Cross-checked claims: `git merge-base --is-ancestor 543aca847 origin/master` exit 0, subject `refactor(api, SPL-5654): each hub and store Postgres test group runs on its own freshly migrated database`; `git show origin/master:csi-spl-api/src/bash/tests/hub-pg.tst.sh | grep -n 'GO_TEST_TIMEOUT='` -> `178:GO_TEST_TIMEOUT="${SPOOL_TEST_GO_TIMEOUT:-20m}"`; `git cat-file -e ad7621455:<f>` exits 0 for `hub-pg-groups.inc.sh`, `store-pg-groups.inc.sh`, `hub-pg-groups.tst.sh`, `store-pg-groups.tst.sh`, `wui/tests/unit/unit-runner-coverage.test.mjs`, `wui/tests/unit/cleancode.test.mjs`.
4. Re-measured row 01 myself, read-only, n=3 per arm (2026-11-17 14:58..15:29Z): `git clone --shared` of the repo at `f9661ccf0b3dc05c994b4e22de83ea8459389b28` in /var/tmp, `csi-spl-wui/node_modules` a symlink to a lane's whose `.pnpm/lock.yaml` `cmp`-matches `f9661ccf0`'s `pnpm-lock.yaml`, 524 test files, run as the push user, arms alternated S,P,S,P,S,P:
   - S = `node src/node/test/run-unit-tests.mjs` -> **475, 538, 553 s** (n=3), rc=0 each, last line `unit runner: all 524 file(s) passed`
   - P = `ls tests/unit/*.test.mjs | xargs -P 4 -I{} node {}` -> **146, 179, 118 s** (n=3), `rc=0` lines 524, non-zero 0 each
   - 1-min load during the runs 19.36..39.44. Means: S 522.0 s, P 147.7 s, speedup ~3.5x. The plan's numbers (S 546.7..565.6 n=2, P4 120.3..126.9 n=2, ~4.4x) agree in direction and magnitude; absolute seconds move with load. **My numbers and the row's verdict agree: the measured gain exists.**
5. R3 lane map on the rows' paths (2026-11-17 ~15:05Z):
   `lane-map.sh --check csi-spl-wui/src/node/test/run-unit-tests.mjs,csi-spl-wui/tests/unit/unit-runner-pool.test.mjs,csi-spl-wui/tests/unit/unit-runner-coverage.test.mjs,csi-spl-api/src/bash/tests/hub-pg.tst.sh,csi-spl-api/src/bash/tests/hub-pg-pool.tst.sh,csi-spl-api/src/bash/tests/hub-pg-pool.inc.sh,csi-spl-api/src/bash/tests/run-all-tests.sh --agent m-031` -> **exit 4**: `0` lines `owned by`; `16` `unknown:` lanes, all on the second box (rotation seats, two blog drafts, a price, cost allocation, an invoice-PDF import, a CI advisories lane, a tf log mask) — none names a test runner. Matches the plan's own R3 reads (exit 4, 0 owners).
6. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (re-run ~15:05Z) -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi-spl-wt/m-031`, exit 0.

## Defects

None. All six checks pass on the named sha; no row violates sections 1-4 or R1-R16 as far as a plan review can see.

## Notes

- N1: row 01's sites column lists 3 edit ranges but its test column adds a 4th at `:29` (`UNIT_DIR` from an env var) — 4 ranges in 1 file, still within the at-most-5 rule; the lane should list all 4 in the row brief.
- N2: the branch head moved to `af1daf181` after the naming post; the plan file is identical (0 diff lines), so the verdict on `ad7621455` covers it. This seat names `ad762145514300b5042a895c9f1bcd6cd5893d57`, the sha it read.
- N3: my re-measure's absolute seconds differ from the plan's with the box load (19..39 vs 17..33); the direction and the verdict agree. Row 02's after-arm is n=1 in the plan (uncapped probe) — the row itself carries the cap and a lane re-time with n>=2, which is the right guard.
- N4: rotation note `7d28846b` (c-001, 2026-11-17T15:28:10Z, "rotation at 15:42Z UTC: push what is green, write your state"): this commit is that state; no reply sent, per the note.
