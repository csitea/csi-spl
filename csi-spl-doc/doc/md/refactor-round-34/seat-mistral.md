# Refactor round 34: mistral panel seat (m-206, mistral)

Issue SPL-5800, epic SPL-2402, spec `csi-spl-doc/specs/011-spool-project-refactor`,
task `dispatch-refactor-r34`. Doc review only: this seat reviews the plan, never a
row, and touches no file but this one.

## Verdict

**PASS** on plan sha **`8be605b72d4b69beeb4ed5ffb7761585a30dba97`** (v0.2), file
`csi-spl-doc/doc/md/refactor-round-34-plan.md` (279 lines at that sha), branch
`review/c002-refactor-round-34-planner-v3`.

Sha provenance: the brief named v0.1 `b5f104df6`; the dispatch holder c-002@sat
(msg `5e0dabf3`, task `e18cfbfc-8c20-59fc-b97b-91eb7187559b`, 2026-11-17T14:45:47Z)
named v0.2 `8be605b7...` (c-041 msg `be18fdd4`) and told me to review and sign that.
My `git ls-remote origin 'refs/heads/review/c002-refactor-round-34-planner-v3'` ->
`8be605b72d4b69beeb4ed5ffb7761585a30dba97`, matching FETCH_HEAD after
`git fetch origin review/c002-refactor-round-34-planner-v3`. v0.2 vs v0.1:
`git show --stat 8be605b7` -> only the plan file, 15 insertions, 5 deletions
(header, section 1, status line, section 8); rows unchanged, as the holder said.

Measured baseline sha of the plan: `fd9e5a27a382451896ba01560e25eefcecc040d8`
(ancestor of origin/master, verified with `git merge-base --is-ancestor` -> yes).

## Checks (each with the command and what it printed)

### 1. Slug r60 unused

- `git log origin/master --oneline -E --grep='\(r60-' | wc -l` -> **0**
- `git ls-remote origin 'refs/heads/*r60*' | wc -l` -> **0**

(origin/master at check time: `e9748a03d296322b6fc101c50a8c2e493bef24c3`.)

### 2. Row sites exist at fd9e5a27a and on origin/master

For every file:line the rows cite (69 lines across 18 files: row 01
`store/fallback_postgres.go:84-87,119-129,152-161`; row 02 `payments/handler.go:460,635`
and `go-coverage-floor.txt:130-134`; row 03 the three orc action files
`:19-23 / :11-12,18-19 / :15-18` and `param-required-baseline.txt:4-10`; rows 04-06
the ten orc action files' cited lines and `no-literal-paths.baseline`), I ran
`git show <sha>:<file> | sed -n <N>p` per line at `fd9e5a27a` and at `origin/master`:
**0 MISSING**, and `diff` of the two 69-line sections -> empty, **no drift** at
either `013cb71bf` or `e9748a03d`. Spot content: `fallback_postgres.go:84` ->
`AND m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%' AND m.env_sig <> ''`;
`go-coverage-floor.txt:134` -> `internal/payments 84.3` (the floor the plan cites).

### 3. Row structure, R1, R3, p14 overlap

- Sites per row (entries in the sites column): 01: 3 ranges in 1 file; 02: 2;
  03: 4; 04: 4; 05: 5; 06: 4 — all at most 5 (rulebook 3.1).
- Baseline with command + number + n: section 2's table carries command, n and row
  per input (e.g. the signed-human predicate: `grep -n "m.from_box = 'box-wui' AND
  m.from_id LIKE 'HUM-%'" go:store/fallback_postgres.go` -> 3 lines `:84 :119 :152`).
- Counting test with red control per row: each row's test column names a Control
  (row 01 C2 behaviour-kept with a dropped-conjunct red case; row 02 floor-without-
  file red; row 03 gate before/after; rows 04-06 derived-dir-equals-literal plus the
  ratchet red). Vendor, kind, batch columns present on every row.
- R1, batch 1 (rows 01-04) file sets: `fallback_postgres.go` / new
  `capture_status_test.go` + `go-coverage-floor.txt` / 3 orc action files +
  `param-required-baseline.txt` / 3 token-burn files + `no-literal-paths.baseline`
  — pairwise disjoint. `no-literal-paths.baseline` is shared by rows 04-06 only
  across batches 1/2/3, serialised per R1 and R16 (plan section 3.1).
- No mistral coding or testing rows: vendor column is `claude` on all 6 rows
  (owner 10-17, t1 b61851fb msg 91bf8278).
- R3 live/queued lanes: plan section 3.2 does **not** claim the lane map free; it
  records its own `lane-map.sh --check` exit 4 at 2026-11-17T14:29:25Z and says the
  holder re-runs the check before each row's spawn. My own run (check 5 below)
  reproduces exit 4 — the plan's handling is honest and matches R3.
- Perf round 14 overlap, file by file: `git ls-remote origin
  'refs/heads/review/c001-perf-round-14-planner'` -> `5929030f0c3683bf324c81a1703e58038d7a27a9`
  = the plan's named v0.1. `git diff --stat origin/master...5929030f0` -> 2 files,
  both docs (the plan and its editor seat). Its table has 1 row
  (`grep -cE '^\| [0-9]{2} \|'` on the table -> 1), `p14-01-wui-unit-pool`, sites
  `csi-spl-wui/src/node/test/run-unit-tests.mjs` + new
  `csi-spl-wui/tests/unit/unit-runner-pool.test.mjs`, running
  `unit-runner-coverage.test.mjs` and `cleancode.test.mjs` — all under
  `csi-spl-wui/`. This round's 17 written paths are under `csi-spl-api/`,
  `csi-spl-orc/`, `csi-spl-iac/` only; intersection with p14's files -> **empty**.

### 4. Re-measure one row, n=3 (read-only)

Row 01's input, on `fd9e5a27a`, three runs of
`git show fd9e5a27a:csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go | grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'"`:
run 1 -> `84 119 152` (3 lines), run 2 -> `84 119 152` (3), run 3 -> `84 119 152`
(3). Same on `origin/master` (`e9748a03d`): `84 119 152`, file 227 lines (plan says
227-line file). My number (3 copies) and the row's verdict (3 -> 1) **agree**.
Also re-measured the two baselines at `fd9e5a27a`:
`git show fd9e5a27a:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
-> `27 52` (plan: 27 files / 52 lines), and the rows 04-06 subset greps to exactly
the 10 baseline lines (token-burn 3+2+1, agent-login 2+2+2+2, probes 2+1+1);
`git show fd9e5a27a:csi-spl-iac/src/bash/tests/param-required-baseline.txt | grep -vE '^\s*(#|$)' | wc -l`
-> `7` (plan: 7 lines in 3 files). Rulebook 4.4's command on fresh origin/master
-> `perf 20 refactor 100 perf-share 16.7% under-20`, exactly the plan's reading.

### 5. R3 lane map on the rows' paths

`bash .../spawn-agents/scripts/lane-map.sh --check <18 paths: the 17 written paths
plus payments/handler.go, comma-separated> --agent m-206` -> **exit 4**: 0 paths
owned; 8 `unknown:` lanes with no files recorded, all on sat: `c-004@sat`,
`c-025@sat` (p14 planner), `c-041@sat` (r34 planner), `c-044@sat`, `c-197@sat`,
`c-521@sat`, `c-762@sat`, `m-031@sat` (p14 mistral seat). Exit 4 is not free; the
plan does not treat it as free (section 3.2) and the holder re-runs per row.

### 6. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-206`,
**exit 0**.

## Defects

None. (W1..: no defect found; every check above printed what the plan claims.)

## Notes

- N1: the lane-map exit 4 (check 5) includes the two planner lanes (c-041, c-025)
  and the p14 mistral seat (m-031), which record no files because they write only
  review-branch docs. Per the seed, exit 4 means ask first, never free — the plan
  leaves the per-row re-check to the holder, which is what R3 requires.
- N2: p14's branch head is still `5929030f0` (ls-remote matches the plan's named
  v0.1). If p14 advances with new rows, the plan's own section 3.2 has the holder
  re-check the overlap before this round's first row spawns.
- N3: live queue moved since the plan's 14:29:34Z reading: `do_spl_spawn_queue` now
  (14:5xZ) -> `2 queued, 0 placing`, live refactor share `4 14% (band 10-20%: ok)`,
  last 24 h refactor `7% (band 20-30%: UNDER)`; no refactor-class row queued in
  either reading, so the "why now" holds.
- N4: STEP 0 done: developer guide read, acked as m-206 (blob `8b1916cd`).

Signed: m-206 (mistral), 2026-11-17T14:53Z, on
`8be605b72d4b69beeb4ed5ffb7761585a30dba97`.

## v1.0 signing

The editor landed v1.0 on `origin/master` as
**`c7ee2effde172674aaac49e2a663d2c20fb9128d`** (2026-11-17T16:58:07+02:00, subject
`docs(r34-plan, SPL-5800): round 34 plan v1.0, panel m-206 mistral PASS on v0.2
8be605b72`). Verified before signing:

- `git diff 8be605b7..c7ee2effd -- csi-spl-doc/doc/md/refactor-round-34-plan.md` ->
  the status line, the editor line, section 8 and section 9 only; the rows table is
  untouched: `git show c7ee2effd:csi-spl-doc/doc/md/refactor-round-34-plan.md |
  grep -cE '^\| 0[1-6] `'` -> 6 rows, vendor column `claude` on all 6.
- `git log origin/master --oneline -E --grep='\(r60-' | wc -l` -> 0.

Verdict on v1.0: **PASS** on `c7ee2effde172674aaac49e2a663d2c20fb9128d`.

Signed: m-206 (mistral), 2026-11-17T15:01Z, on
`c7ee2effde172674aaac49e2a663d2c20fb9128d`.
