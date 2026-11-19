# Refactor round 64 (r64): mistral panel seat (m-828)

Seat: m-828@sat, placement `c002-refactor-round-64-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-64-mistral-panel-seat.md`
(Issue SPL-5921, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `f054a589-3f8f-4b00-9b59-8db43a114d0e`).

Review target: plan v0.1 `b8090a414331c125f457e46753af3675efdf327d`, named by
c-816@sat msg 9f8b7c9e and in the brief. Provenance: `git ls-remote origin | grep -E
'r64-[0-9]{2}|refactor-round-64'` -> `b8090a414331c125f457e46753af3675efdf327d
refs/heads/review/c002-refactor-round-64-planner` (only that branch);
`git show b8090a414 --stat` -> 1 file,
`csi-spl-doc/doc/md/refactor-round-64-plan.md` (287 lines, read in full at that
sha). origin/master at my read: `32a261c24f7c3b3067869c6559f7b1b0ccccec46` —
the plan's measuring sha, so no drift between them.

## Verdict

**PASS on `b8090a414331c125f457e46753af3675efdf327d`** (plan v0.1, 2 rows). All
eight checks of the brief re-run by me, commands and outputs below. Defects:
W1 (one wrong prose line cite, row sites unaffected). Notes: N1..N4 below.

## Checks (each with the command run and what it printed, 2026-11-19 06:3x-06:5xZ)

### 1. Slug r64 unused

- `git log origin/master --oneline -E --grep='\(r64-' | wc -l` -> **0**.
- `git ls-remote origin | grep -E 'r64-[0-9]{2}|refactor-round-64'` ->
  `b8090a414331c125f457e46753af3675efdf327d  refs/heads/review/c002-refactor-round-64-planner`
  only — the planner's branch, expected; my own review branch
  `review/c002-refactor-round-64-mistral-seat` did not exist on origin at read
  time. Nothing else named. `git ls-remote origin 'refs/heads/review/r64-01'
  'refs/heads/review/r64-02'` -> nothing (no row review branches yet).
- `git ls-tree --name-only 32a261c24 csi-spl-doc/doc/md/ | grep -c 'round-64'`
  -> **0** (no `refactor-round-64*` file on the measuring sha, so the plain plan
  name is free, rulebook 5.3 "Files").

### 2. Source: r63-01/r63-02 on master, the 4 cron scripts unchanged since 32a261c24

- `git log origin/master --oneline -E --grep='\(r63-0[12]'` ->
  `9dcb5589d refactor(r63-01-orc-feature-state-dirs, SPL-5920): ...` and
  `4d4c5ecde refactor(r63-02-orc-key-path-examples, SPL-5924): ...` — both on
  origin/master.
- `git log 32a261c24..origin/master --oneline -- csi-spl-orc/src/bash/scripts/issue-key-rate-cron.sh
  csi-spl-orc/src/bash/scripts/push-orphan-check-cron.sh
  csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh
  csi-spl-orc/src/bash/scripts/token-burn-collect-cron.sh` -> **empty** (rc 0):
  unchanged since the measuring sha.
- `git rev-parse origin/master` -> `32a261c24f7c3b3067869c6559f7b1b0ccccec46`
  (the measuring sha is trunk HEAD at my read).
- The r63-01 R7 W1 substance, re-read on the tree: `git show
  origin/master:csi-spl-orc/src/bash/run/setup-reverse-tunnel.func.sh | sed -n 49p`
  -> `spl_run_paths && dir="${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/reverse-tunnel}"`
  (the action derives its dir), while `reverse-tunnel-cron.sh:23` (check 3)
  defaults to the literal — the cron's gate looks in a dir the action never
  writes on another prefix. The finding holds.

### 3. Every site file:line of both rows on `32a261c24` and on origin/master

`git show <sha>:<file> | sed -n <N>p` for each site, on both shas — identical
on the two, and matching the plan's section 1.2 wording:

- `csi-spl-orc/src/bash/scripts/issue-key-rate-cron.sh:23` ->
  `hist="${KEY_RATE_HISTORY:-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/issue-key-rate/history.tsv}"`
- `csi-spl-orc/src/bash/scripts/push-orphan-check-cron.sh:24` ->
  `state="${PUSH_ORPHAN_STATE_DIR:-/var/csi/csi-spl/push-orphan-check}"`
- `csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh:23` ->
  `ls "${REVERSE_TUNNEL_STATE_DIR:-/var/csi/csi-spl/reverse-tunnel}"/*.conf >/dev/null 2>&1 || exit 0`
- `csi-spl-orc/src/bash/scripts/token-burn-collect-cron.sh:36` ->
  `dir="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}"`
- `csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh` and
  `csi-spl-orc/src/bash/tests/no-literal-paths.baseline` -> `git cat-file -e`
  OK on both shas.

No drift: origin/master == 32a261c24 at my read.

### 4. Each row: practice, R2 control/test, test list, vendor, kind, batch; R7 reviewer

- Plan section 2 table (lines 134-135): both rows carry practice (row 01 "no
  literal box path", developer guide 2.3.1; row 02 "a gate that sees every shell
  file", 2.3.1/2.12.1), why, sites file:line, n (4 files/4 lines; 1 test + 1
  baseline), test + red control (row 01: the on-box control, derived dir =
  old literal, overrides win, `SPL_RUN_PATHS_TOP=` no-dir answer, crontab lines
  before/after; row 02: red control C2 on the fixture tree, RED before, GREEN
  after), box `either`, **vendor claude**, **kind** `simple_coding` / `tests`,
  batch `1` / `2 (after 01)` with `SPAWN_AFTER=c002-r64-01-orc-cron-script-state-dirs`.
  `grep -oE '\| (claude|mistral|...) \| (simple_coding|tests|...) \| ...'`
  over the plan -> exactly `| claude | simple_coding | 1 |` and
  `| claude | tests | 2 (after 01) |`. No mistral coding or testing row
  (owner 10-17, t1 b61851fb msg 91bf8278).
- Test lists re-run with the plan's own NAMES command on 32a261c24:
  r64-01 NAMES (`issue-key-rate-cron push-orphan-check-cron reverse-tunnel-cron
  token-burn-collect-cron`) -> **4** files: `install-box-crons.tst.sh`,
  `reverse-tunnel.tst.sh`, `spl-issue-key-rate.tst.sh`,
  `spl-token-burn-collect.tst.sh` (all `orc:tests/`); r64-02 NAMES
  (`no-literal-paths`) -> **2** files: `no-literal-paths.tst.sh` and its
  baseline. Matches the plan. The further gates the plan names all exist on
  origin/master (`git ls-files` x8): `spl-push-orphan-check.tst.sh`,
  `spl-run-paths.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`
  plus the 4 above.
- R2 bullet 2, the 30-character strings, `git grep -lF '<string>' origin/master
  -- 'csi-spl-*/**/tests/*' | wc -l` -> **0** each for
  `BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}`, `PUSH_ORPHAN_STATE_DIR:-/var/csi/csi`,
  `REVERSE_TUNNEL_STATE_DIR:-/var/csi`, `TOKEN_BURN_STATE_DIR:-/var/csi/csi-s`.
- R7 (plan section 4, lines 204-219): row reviewers cross-vendor first, else the
  holder's claude-waiver call, explicitly "Not a mistral code R7" (line 217) —
  compliant with rulebook 2.7.2 and 91bf8278. The mistral seat here is the
  doc-only panel seat (line 213), allowed.

### 5. Baseline counts, re-counted on origin/master

- `git show origin/master:csi-spl-orc/src/bash/tests/no-literal-paths.baseline
  | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'` -> **`4 10`**
  (4 files, 10 lines). Per-file: `3 .../run/spl-cmd-guard-mode.func.sh`,
  `2 .../run/spl-file-erase.func.sh`, `2 .../run/spl-reflection-gather.func.sh`,
  `3 csi-spl-utl/src/bash/run/fleet-logrotate-install.func.sh` — the plan's 4/10.
- Graft scripts' literal counts, `git grep -cE '/(opt|var)/csi($|[^A-Za-z0-9_-])'
  origin/master -- <file>` -> `graft-cron.sh`: **1**, `graft-index-dir.sh`:
  **2** — so row 02's +2 graft entries give 6 files / 13 lines, the plan's
  6/13.
- The whole-repo scan re-run: `git grep -cE '/(opt|var)/csi($|[^A-Za-z0-9_-])'
  origin/master -- '*.sh' ':!*.func.sh'` -> **23 files, 86 lines**; excluding
  `*/tests/*` -> exactly the 6 files: the 4 row-01 scripts plus
  `graft-cron.sh` and `graft-index-dir.sh`. Matches the plan's 1.2.

### 6. R3: lane-map over the 6 written paths

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
  --check csi-spl-orc/src/bash/scripts/issue-key-rate-cron.sh,csi-spl-orc/src/bash/scripts/push-orphan-check-cron.sh,csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh,csi-spl-orc/src/bash/scripts/token-burn-collect-cron.sh,csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh,csi-spl-orc/src/bash/tests/no-literal-paths.baseline
  --agent m-828` -> **`free`**, **exit 0**.

### 7. R1 across rounds: no live perf/bug round row names these files

- Plans read on origin/master (= 32a261c24): all `perf-round-*-plan.md`
  (newest `perf-round-18-plan.md`) and all `bug-round-*-plan.md` (newest
  `bug-round-18-plan.md`).
- `grep -cE 'issue-key-rate-cron|push-orphan-check-cron|reverse-tunnel-cron|token-burn-collect-cron|no-literal-paths'
  <plan>` over every one -> **0** everywhere except `bug-round-16-plan.md`: 1,
  `bug-round-18-plan.md`: 1, `perf-round-15-plan.md`: 1. Those three hits are
  off-limits / context mentions of `no-literal-paths.baseline` (bug-round-16
  line 55 r35's row files; bug-round-18 line 49 r62's off-limits list;
  perf-round-15 line 137 a baseline read), not rows. Newest of each kind:
  perf-round-18 -> 0, bug-round-18 -> 1 (the off-limits mention). No live
  perf or bug round row names any of the 6 paths.

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-828`,
  exit 0.

## Defects

- **W1** — plan line 81 (section 1.2): "Each script already computes `ORC`
  from its own path (`:17`, `:17`, `:17`, `:22`)". Re-read on origin/master:
  `issue-key-rate-cron.sh:17`, `push-orphan-check-cron.sh:17` and
  `token-burn-collect-cron.sh:22` do compute `ORC`, but `reverse-tunnel-cron.sh:17`
  is blank — its `ORC=` line is **:18**
  (`git show origin/master:csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh | sed -n '17,18p'`).
  Prose cite off by one for one of the four; the row's site line `:23` is
  correct and the substance (all four scripts derive `ORC` from their own path)
  holds, so the row is unaffected. Fix the cite to `:18` in v1.0.

## Notes

- N1: the plan cites "r63-01 R7 W1" as the source of both rows; the R7 review
  text lives on the row's review branch, not on master, so I verified the
  finding's substance directly on the tree instead (check 2): the action
  derives `${SPL_VAR_APP_DIR}/reverse-tunnel` (`setup-reverse-tunnel.func.sh:49`)
  while the cron gate defaults to the literal (`reverse-tunnel-cron.sh:23`).
- N2: origin/master was exactly the measuring sha `32a261c24` at my read, so
  every count in the plan is also the trunk count; no drift to re-measure.
- N3: my lane-map read returned exit 0 `free` (check 6), same as the plan's
  06:16Z read; the holder's R3 re-check before each row's spawn still governs.
- N4: the plan's window W claim re-verified: `git log origin/master -1
  --format='%H %cI' -E --grep='^docs\(r63-plan'` ->
  `2aad3eb936144b68214a9b8842db5b812071b7a1 2026-11-18T19:28:43+01:00`.
  The scripts+tests log since W -> 5 commits (`dcf0fe9b2`, `a9792796b`,
  `17fd13fd0`, `4d4c5ecde`, `9dcb5589d`), none on a row file — matches the
  plan's 2.2.

## Signature

m-828@sat (mistral), 2026-11-19T06:57Z: **PASS on
`b8090a414331c125f457e46753af3675efdf327d`**, W1 (plan line 81, prose cite),
N1-N4. To be re-signed on the editor's v1.0 sha when named on task
`dispatch-refactor-r64`.
