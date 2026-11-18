# Refactor round 62 - mistral panel seat verdict

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Issue: SPL-5885  
Round: r62 (refactor round 62), topic 7f658d58-4b41-4b39-be56-a1a691ee4351  
Reviewer: m-514@sat (mistral panel seat; docs and review only, no code)  
Plan reviewed: `csi-spl-doc/doc/md/refactor-round-62-plan.md` v0.2 at sha
**94bde66730dfb7015d698f275119e373b335f64f** - the head of
`review/c002-refactor-round-62-planner` (`git ls-remote origin` -> one line,
`94bde6673... refs/heads/review/c002-refactor-round-62-planner`); v0.1
`aa8f25ec4` is its ancestor (`git merge-base --is-ancestor aa8f25ec4
94bde6673` rc 0), plan file 254 lines at v0.2, 244 at v0.1. Editor: c-815.  
Task: `dispatch-refactor-r62`.

All reads 2026-11-18 ~14:00-14:08Z, n=1 per command unless stated, in the lane
worktree after `git fetch origin`, git run as `sudo -u <DEV_USER> git ...`.
`origin/master` = 04ca1d8970f6fe8899a24d42b814a777697387e6 (the plan's
measurement sha 04ca1d897, still the head). Every file:line cited below was
read with `git show <sha>:<file> | sed -n <N>p` on `origin/master` first.

## Verdict

**PASS** on 94bde66730dfb7015d698f275119e373b335f64f. Defects: none. Notes:
N1, N2.

## Checks (command -> output)

### 1. Slug r62 unused

- `git log origin/master --oneline -E --grep='\((r62-' | wc -l` -> **0**
- windowed, plan 1.1's W re-read first:
  `git log origin/master -1 --format=%cI -E --grep='^docs\(refactor-round-35-plan'`
  -> `2026-11-18T10:17:09+02:00` (matches plan 1.1);
  `git log origin/master --since="2026-11-18T10:17:09+02:00" --oneline -E --grep='\((r62-' | wc -l`
  -> **0**
- control, same read for r61 -> **3** lines: `954b10ad5`, `dfe7fd9a1`,
  `61bdcbd1c`, so the read sees a used id
- `git ls-remote origin | grep -E 'r62-[0-9]{2}|refactor-round-62'` -> one
  line, the planner's branch only:
  `94bde66730dfb7015d698f275119e373b335f64f\trefs/heads/review/c002-refactor-round-62-planner`
  (this seat's own review branch did not exist on the remote at read time; it
  is created by this seat's push). Broader `git ls-remote origin '*r62*'` ->
  nothing; `git ls-remote origin '*62*'` -> only unrelated refs (spec155,
  SPL-4626, s162, s155-b10, c002-feat, s169, m-462, m-623) plus the planner
  branch. Nothing else carries r62.
- `git ls-tree 04ca1d897 csi-spl-doc/doc/md/ | grep -i 'round-62'` -> rc 1, no
  file, so the plain plan name is right (rulebook 5.3 "Files").

### 2. R15: the round 35 shas resolved by subject

- `git log origin/master --oneline --grep='refactor round 35 plan v1.0'` ->
  `08efd6484 docs(refactor-round-35-plan, SPL-5831): refactor round 35 plan
  v1.0, panel m-392 mistral PASS on v0.2 a73b73d47` (plan's `e563bf623` ->
  `08efd6484`); `git diff --quiet e563bf623 08efd6484 --
  csi-spl-doc/doc/md/refactor-round-35-plan.md` -> rc 0, no difference
- `--grep='refactor(r61-01-orc-uplink-probe-exit-text'` -> `dfe7fd9a1`,
  `954b10ad5` (plan's `cebfa7004` / `2e55f493d`)
- `--grep='refactor(r61-02-orc-login-check-dir-callers'` -> `61bdcbd1c`
  (plan's `89b331061`)
- `--grep='docs(rounds, SPL-5879)'` -> `dc3f39027` (plan's `b33f2a306`)

All four mappings in plan section 1.2 match today's `origin/master`.

### 3. Every site file:line exists on 04ca1d897 and still on origin/master

`git show <sha>:<file> | sed -n <N>p` printed the same line on both shas for
all nine; each carries the `/var/csi/csi-spl` literal:

| site | line on 04ca1d897 = origin/master |
|---|---|
| `csi-spl-orc/src/bash/run/install-box-crons.func.sh:36` | `# @param BOX_CRONS_STATE_DIR (optional) - the logs' root, default /var/csi/csi-spl` |
| `.../install-box-crons.func.sh:51` | `  local state="${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}" ct="${BOX_CRONS_CRONTAB:-crontab}"` |
| `csi-spl-orc/src/bash/run/spl-box-state-backup.func.sh:11` | `# @description   - the csi-spl state dirs: /var/csi/csi-spl (less graft/, a` |
| `.../spl-box-state-backup.func.sh:163` | `  printf '%s\t\n' "${SPOOL_ROOT:-/var/spool-hub}" "${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}" "$HOME/.local/state/csi-spl"` |
| `.../spl-box-state-backup.func.sh:204` | `  skip="${BOX_STATE_SKIP-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/graft ${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/backups}"` |
| `csi-spl-utl/src/bash/run/external-api-health.func.sh:28` | `# @param   BOX_CRONS_STATE_DIR or /var/csi/csi-spl>/uplink-probe` |
| `.../external-api-health.func.sh:62` | `  dir="${EXTERNAL_API_DIR:-${UPLINK_PROBE_DIR:-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/uplink-probe}}"` |
| `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:213` | `# @param TOKEN_BURN_STATE_DIR (optional) - ... default /var/csi/csi-spl/token-burn` |
| `.../spl-spawn-place.func.sh:684` | `    f="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}/buckets.tsv"` |

No drift. Also read: `spl-spawn-place.func.sh:685` -> `    [[ -r "$f" ]] ||
return 1` (the plan's "unchanged after it"); the helpers:
`spl-uplink-probe.func.sh:77` -> `spl_uplink_probe_dir() {`,
`spl-token-burn-collect.func.sh:37` -> `spl_token_burn_state_dir() {`,
`csi-spl-utl/.../orphan-process-reap.func.sh:58` -> the
`declare -F spl_run_paths >/dev/null || source .../spl-run-paths.func.sh` line.
The literal grep per file on origin/master
(`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' origin/master -- <file>`)
returns exactly the plan's sites: 36,51 / 11,163,204 / 28,62 / 213,684.

### 4. Row shape: practice, R2 control/test, test list, vendor, kind, batch, R7

Both rows of plan section 3 carry practice, why, sites (at most 5), n, a
test/red-control cell, box, vendor, kind, batch. Re-ran the section 2 test
command on origin/master: r62-01 (`NAMES="install-box-crons
spl-box-state-backup external-api-health"`) -> **11** files; r62-02
(`NAMES="spl-spawn-place"`) -> **15** files, including
`csi-spl-orc/src/bash/tests/spl-spawn-after.tst.sh` - both counts match the
plan. The red control exists in code:
`git grep -n 'STALE' origin/master -- csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh`
-> :50-51 print `STALE baseline: ...` and :77 asserts a stale entry FAILs
(`red control: a stale baseline entry FAILs`), so fixed files with the
baseline entries kept fail today and pass after they are dropped. Vendor
**claude**, kind **simple_coding** on both rows - no mistral coding or testing
row. R7 reviewer per plan section 5: an **agy** seat per row (cross-vendor
first, 2.7.2), explicitly "Not a mistral code R7" - satisfies the rule
(cross-vendor seat or the claude waiver seat, never mistral).

### 5. Section 7 baseline counts re-counted

- `git show origin/master:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
  -> **`14 30`** (same output on 04ca1d897)
- row files' entries:
  `2 csi-spl-orc/src/bash/run/install-box-crons.func.sh`,
  `3 csi-spl-orc/src/bash/run/spl-box-state-backup.func.sh`,
  `2 csi-spl-utl/src/bash/run/external-api-health.func.sh`,
  `2 csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`
- arithmetic: 14-3 = 11 files / 30-7 = 23 lines after r62-01; then 11-1 = 10 /
  23-2 = 21 after r62-02. The plan's `14/30 -> 11/23 -> 10/21` is correct.

### 6. R3 lane map, and the 1801656f overlap for r62-02

- `lane-map.sh --check csi-spl-orc/src/bash/run/install-box-crons.func.sh,csi-spl-orc/src/bash/run/spl-box-state-backup.func.sh,csi-spl-utl/src/bash/run/external-api-health.func.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/no-literal-paths.baseline --agent m-514`
  -> **exit 4**: no live lane lists the five paths, but 11 live lanes record
  no files (`unknown:` c-054, c-060, c-390, c-714, c-810, c-813, c-815, c-817,
  c-818, c-924, c-927, all on the other box). The plan's 3.2 recorded exit 0
  at 2026-11-18T13:50:34Z (its own read, n=1) - see N1.
- queued bug ask confirmed: `cd csi-spl-orc && SPAWN_QUEUE_FORMAT=json ./run -a
  do_spl_spawn_queue` -> ask `1801656f-e419-4b99-8e40-940ab725ca32`,
  placement `claude:c002-spl5874-held-row-end-and-alarm`, class `bug`, state
  `queued`.
- `git grep -n 'tail -1' origin/master -- csi-spl-orc/src/bash/run/spl-spawn-after.func.sh`
  -> :37 `after="$(sed -nE 's/^After:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\\1/p' "$1" | tail -1)"`,
  so `spl_spawn_after_of` reads ONE `After:` line: SPAWN_AFTER takes one
  prerequisite, as the plan says.
- Judgment: plan 3.1/3.2 handle the overlap for r62-02. Row 02 waits for row 01
  (`SPAWN_AFTER=c002-r62-01-orc-box-crons-state-root`, the placement slug, not
  the row slug) AND for bug ask 1801656f's issue to land; because one
  SPAWN_AFTER names one prerequisite, the holder queues r62-02 only after one
  of the two has landed. That is coherent with the code read at
  `spl-spawn-after.func.sh:37`.

### 7. R1 across rounds: no live perf/bug row names these files

- `git show origin/master:csi-spl-doc/doc/md/perf-round-17-plan.md | grep -cE 'install-box-crons|spl-box-state-backup|external-api-health|spl-spawn-place|no-literal-paths'`
  -> **4**; the four matching lines (125, 151, 199, 235) name
  `spl-spawn-place.func.sh` only to stay off it - line 235: "not a row in p17
  (R1): refactor round 35 row 04 edits the same file and is not landed; a
  later perf round takes it once r61-04 lands"
- `git show origin/master:csi-spl-doc/doc/md/bug-round-17-plan.md | grep -cE <same>`
  -> **1**; the line names `install-box-crons.tst.sh` in a test column of a
  box-link-watch row, not a site on `install-box-crons.func.sh`
- No live perf or bug round row names these files as sites.

### 8. Gates

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree`, exit 0
- `cd csi-spl-orc && AGENT_ID=m-514 ./run -a do_check_fleet_rules_drift` ->
  `OK repo-refs ... OK constitution ... OK fleet rules: no drift`, exit 0

## Defects

None.

## Notes

- N1: the lane-map re-read at ~14:05Z returns exit 4 (11 `unknown:` lanes on
  the other box, none listing the five paths), while plan 3.2 recorded exit 0
  at 13:50:34Z. Live state moved between the two reads; per the lane rules
  exit 4 means ask those lanes first, never free, so the orchestrator's
  spawn-time R3 check (which re-runs it) is the one that governs. Not a
  defect in the plan: its read carried its time and n=1.
- N2: `perf-round-17-plan.md:235` still says "once r61-04 lands"; r61-04 is
  this round's r62-02. Cosmetic, in the p17 plan, not in this plan.
