# Refactoring round 06 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6566  
Topic: 9cd9090d-7a1a-42f4-9db1-d1f50245ee3f  
Discussion: 9cd9090d-7a1a-42f4-9db1-d1f50245ee3f (t1 #refactoring, "Refactor round 06", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r06**, plan `refactor-round-06-plan.md` (free: 0 `refactor-round-06` files on
  `origin/master`, so no date suffix), rows `r06-<NN>`, scope `docs(r06-plan, SPL-6566)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row** (`LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 05:38Z:
  `pick=claude`, `main=claude`, `backup=agy`).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 05 ([refactor-round-05-plan.md](refactor-round-05-plan.md)
v1.0 `e2676a718`, close record `2ccf23c21`, editor `a-891`) has both rows on
`origin/master` with CI green: `r05-01` (`6b216a319`, SPL-6557, agy R7 `a-922` PASS) and
`r05-02` (`62c5bea32`, SPL-6558, agy R7 `a-920` PASS); nothing of r05 remains to queue.
The perf floor (rulebook 4.4), re-measured on `f9521a941` at 2026-11-26T05:38:25Z (14
days): perf 36, refactor 115, 23.8%, 5 x 36 = 180 >= 151, floor-met, so this is a
refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), continuing directly from
r05-02 (`62c5bea32`): duplicated `orc:` crontab-installer scaffolding delegates to one
shared helper, leaving every log line, exit code, env var, and path byte-identical.
**Row 01:** completes the `_spl_run_cron_apply` wave-2 consolidation across the last three
matching `./run`/flock single-line cron installers named in r05 section 7 #1 —
`orc:src/bash/run/spl-spawn-place-install-cron.func.sh:46-79`,
`orc:src/bash/run/spl-review-go-install-cron.func.sh:46-79`, and
`orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh:44-77`. Adding optional
11th arg `mode="${11:-x}"` (`x` = `-x` default, `r` = `-r` readable script with `"is gone"`
/ `"is missing in $src"`) to `_spl_run_cron_apply` in
`orc:src/bash/run/spl-spawn-fill-install-cron.func.sh:53-89` lets all three drop their
duplicated `spl_*_cron_check` functions and 32-34 line state machines behind a
`declare -F _spl_run_cron_apply` lazy-source guard (completing 7/7 wave-1..2
consolidation without touching `spl-review-go.tst.sh`, which `b50-01` edits).
**Row 02:** 12 cron installer files in `orc:src/bash/run/` inline the exact same 6-line
linked-worktree guard (`git rev-parse --path-format=absolute --git-dir` vs
`--git-common-dir`, warning on `DRY_RUN=1` and logging `FATAL ... is a linked worktree:
install from the main checkout - nothing changed` on `DRY_RUN=0`). Extracting
`cron_refuse_linked_worktree` into `orc:lib/bash/funcs/cron-tagged-line.func.sh` (which
already hosts `cron_drop_tagged_line`, used by 11 of the 12) lets wave 1 —
`orc:src/bash/run/spl-box-update-install-cron.func.sh:47-52`,
`orc:src/bash/run/spl-cost-rollup-install-cron.func.sh:57-62`, and
`orc:src/bash/run/git-prune-merged-install-cron.func.sh:33-38` — replace their duplicated
guards with one call (leaving the remaining 8 cron installers + `install-box-crons` in
section 7 for `r07`+ so row 02 stays within rulebook 3.1's 5-file cap).
The rows share no file: both are batch 1.

**Status: closed.** Both rows landed on `origin/master` with cross-vendor agy R7 PASS
(`r06-01` `8024dc0b5` SPL-6575, `r06-02` `984b6d70d` SPL-6577; section 8). Editor:
**a-942** (agy). Plan v1.0 (`c28e628f2`) was signed by cross-vendor claude panel seat
**c-917** (`badeda0c8175aa02bea32df5f5a92baa9655b5b5`, seat commit `61169615d`, msg
`262c4993` / `647e2e45`; `do_spl_review_line_check` rc 0, 67 commands read, msg `4abb9532`;
dispatch holder `c-003` GO LAND `9549a418`). Zero drift on all 17 row/test/host files from
`f9521a941` to `origin/master` `551b3c601` at plan landing, and zero drift on all 10 edited
files from their landed shas to `origin/master` `ae8fd2278` at close.

**One sha:** every count is measured on **`f9521a941`**
(`f9521a941c810423b14249f6707f6cf8ede00a5f`, `origin/master` at 2026-11-26T05:38:25Z),
n=1 per command unless stated. Reads are on `f9521a941` with `git show` / `git grep`. The
tests of 1.5 ran in detached scratch worktrees of `f9521a941` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control, guard control, and mutation
check (1.5) ran in a detached worktree of its own. All helper definitions, caller
replacements, and test hunks are reproduced verbatim in 1.3 and 1.4 so any panel or R7
seat can reconstruct head1, head2, all 5 red/guard controls, and all 7 mutation checks
byte-for-byte on `f9521a941` and verify every sha256. Queue, lane map, brief and branch
reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-26T05:38:25Z, n=1, after a fresh fetch (`git-fetch-fresh.sh --force`):

- **Window: W=2026-11-26T07:34:07+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r05-plan'`:
  `2ccf23c211eaaea2032ca91c51a3f946ae0b076d`
  (`docs(r05-plan, SPL-6553): refactor round 05 closed: r05-01 6b216a319 and r05-02 62c5bea32 landed, agy R7 PASS each`),
  read once at the start as 5.3 says. Per rulebook 5.3, `W` stays fixed at this recorded
  date (`2026-11-26T07:34:07+02:00`, commit `2ccf23c21`); all later R4, R6, 2.7.5, and
  `PRUNE_SINCE` reads for r06 must use `W=2026-11-26T07:34:07+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk ...` ->
  `perf 36 refactor 115 perf-share 23.8% floor-met` (5 x 36 = 180 >= 151).
- `git log origin/master --since="$W" --oneline -E --grep='\(r06-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r06-*' 'refs/heads/*-r06-*' 'refs/heads/*refactor-round-06*' 'refs/heads/wip/*r06*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r06-[0-9]{2}|refactor-round-06'` (local to
  this planner/holder box only, not on the panel seat's box) -> **2** briefs only: this
  planner's brief (`hand-sat-c002-refactor-round-06-planner.md`) and the panel seat's
  brief (`c002-refactor-round-06-claude-panel-seat.md`); 0 `r06-NN` row briefs.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-06`
  -> **0** (`refactor-round-06-plan.md` is free with no date suffix per rulebook 5.3).

### 1.2 The brief's inputs, re-measured

- **(a) r05 section 7:** re-read on `f9521a941`:
  - Remaining `./run`/flock cron installers matching `_spl_run_cron_apply` (r05 section 7
    #1): `orc:src/bash/run/spl-spawn-place-install-cron.func.sh:46-79` (79 lines),
    `orc:src/bash/run/spl-review-go-install-cron.func.sh:46-79` (79 lines), and
    `orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh:44-77` (77 lines).
    Surfaced by `git grep -n "the crontab does not read back what was written" f9521a941 -- csi-spl-orc/src/bash/run/`.
    All three share the exact state machine in `_spl_run_cron_apply`, with
    `spl-topic-archive-suggest-install-cron` needing only optional 11th arg `mode=r` for
    `-r "$script"` (`"is gone"` / `"is missing in $src"`). `b48-01` has landed; live
    `b50-01` edits only `spl-review-go.func.sh` and `spl-review-go.tst.sh`, leaving
    `spl-review-go-install-cron.func.sh` disjoint (`spl-review-go.tst.sh` runs read-only
    in row 01's test column) -> measured here as **row 01** (1.3).
  - Remaining linked-worktree guard duplicates in `orc:src/bash/run/`: surfaced by
    `git grep -n "is a linked worktree: install from the main checkout" f9521a941 -- csi-spl-orc/src/bash/run/`
    -> **12** files (`box-disk-sweep`, `git-prune-merged`, `install-box-crons`,
    `prune-docker-images`, `spl-agent-id-reap`, `spl-box-update`,
    `spl-cost-labels-translate`, `spl-cost-rollup`, `spl-od-pool-supervise`,
    `spl-private-overlay`, `spl-shadow-feed`, `tmp-scratch-sweep`), 11 of which already
    share `cron_drop_tagged_line` from `orc:lib/bash/funcs/cron-tagged-line.func.sh`.
    Three clean non-secret wave-1 callers (`spl-box-update-install-cron`,
    `spl-cost-rollup-install-cron`, `git-prune-merged-install-cron`) -> measured here as
    **row 02** (1.4); the remaining 8 cron installers + `install-box-crons` (including
    `spl-private-overlay-install-cron`, which names `RESERVE_GH_TOKEN_FILE`) stay in
    section 7 for `r07`+.
  - All other r05 section 7 items (`brc`/`oq` `*_read` and `*_apply`, non-matching cron
    installers `spl-dispatch-rotate` / `spl-agent-boot-restore` / `spl-box-restart` /
    `spl-peer-crons`, secret-class 5 probe actions and `gcp-*alert*`,
    `setup-gh-runner-cpu-budget-cron.tst.sh:83-91` now in `b50-02`, PG-heavy
    `spl-msg-{dedup,wipe}` and `spl-channel-agent-*`) remain accounted for in section 7.
- **(b) R7 notes of r05-01 and r05-02:**
  - `r05-01` (`6b216a319`, SPL-6557, agy R7 `a-922` PASS msg `c222573b` on `e5b6947d7`):
    0 W; N1 eager `$(printf '%02d' "$min")` (matches r05 1.3 N6, zero behaviour change),
    N2 commit-body control ref note. No refactor follow-up.
  - `r05-02` (`62c5bea32`, SPL-6558, agy R7 `a-920` PASS msgs `28ef9f7a` / `a1686f64` on
    `9c546c196`): 0 W; N1 eager `$(id -un)` (matches r05 1.4 N6, zero behaviour change),
    N2 header comment of `spl-spawn-fill.tst.sh:1-40` omits section 11 (cosmetic; stays
    untouched to keep diff narrow). No blocking follow-up.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to this planner/holder
  box only and not on the panel seat's box; 145 lines, read 05:38Z):
  - One new entry since r05: lines 144-145 (`b50` `do_spl_review_go` false hold,
    bug-shaped, already taken by live `b50-01`).
  - Re-verified all 9 refactor-labelled entries on `f9521a941` (6 served, 3 open out of
    scope):
    - line 1 (`spl-watchdog.func.sh`, `spl-lane-rotate.func.sh` `/var/csi` literals) -> 0
      hits (served).
    - line 25 (`reverse-tunnel-cron.sh:27`) -> uses `$SPL_VAR_APP_DIR/reverse-tunnel`
      (served).
    - line 48 (`agent-boot-restore` in `spl-watchdog.func.sh:541` and
      `spl-agent-boot-restore-install-cron.func.sh:60`) -> both call
      `spl_var_app_subdir ... agent-boot-restore` (served).
    - line 76 (`spl-desk-reply.sh:9` usage kinds) -> lists all 12 kinds (served).
    - line 104 (`spl-lane-mix.func.sh` `needs_agy_review` / `agy has the final word`) ->
      0 hits in `csi-spl-orc/` (served).
    - line 133 (`spl-unanswered-sweep.func.sh` `send_to_peers_on`) -> 0 hits (served).
    - line 113 (`_ppe_keys` exact-key matching in
      `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh:121-128`) -> open; gate-design
      input (not a narrow refactor row).
    - line 115 (`csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` still names
      `'Lang-review: a-NNN <msg id>'`) -> open; 1-line JSON doc comment (doc/bug-shaped).
    - line 125 (WUI entry-chunk headroom, `ci_initial_gzip_kb` ceiling 155 KB) -> open;
      perf-shaped (belongs in a perf round).
  - All other entries are bug, perf, doc, test-hardening, or other-repo items, accounted
    for in section 7.
- **(d) spec 011 tasks:**
  `git log 2ccf23c21..f9521a941 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r05 close; remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `_spl_run_cron_apply` `mode=r` and wave-2 delegation for `spl-spawn-place-install-cron`, `spl-review-go-install-cron`, and `spl-topic-archive-suggest-install-cron` (completing 7/7)

`orc:` = `csi-spl-orc/`. On `f9521a941`:

- Three remaining `./run`/flock single-line cron installers duplicate the exact 32-34 line
  `check` (`spl_*_cron_check`) / `DRY_RUN=1` / `remove` / `install` state machine hosted
  in `_spl_run_cron_apply` (`orc:src/bash/run/spl-spawn-fill-install-cron.func.sh:56-89`):
  1. `orc:src/bash/run/spl-spawn-place-install-cron.func.sh:46-79` (34 lines; exact match
     to default `mode=x`).
  2. `orc:src/bash/run/spl-review-go-install-cron.func.sh:46-79` (34 lines; exact match
     to default `mode=x`; `b50-01` edits `spl-review-go.func.sh` and `spl-review-go.tst.sh`,
     not this file).
  3. `orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh:44-77` (34 lines;
     identical state machine except `-r "$script"` instead of `-x "$run"` with `"FAIL
     $script is gone"` and `"FATAL $script is missing in $src"`, and empty `miss_why=""`).
- None of the three per-file check helpers (`spl_spawn_place_cron_check`,
  `spl_review_go_cron_check`, `spl_archive_suggest_cron_check`) has any caller or test
  reference outside its own file (`git grep -nE` -> 2 hits each: definition + single call
  in the same `.func.sh` file, n=1).
- Adding optional 11th arg `mode="${11:-x}"` to `_spl_run_cron_apply` in
  `spl-spawn-fill-install-cron.func.sh` leaves all four wave-1 callers byte-identical
  (`mode` defaults to `x`) and supports `mode=r` for `spl-topic-archive-suggest-install-cron`.
  The three wave-2 siblings lazy-source `spl-spawn-fill-install-cron.func.sh` behind a
  `declare -F _spl_run_cron_apply` guard inside their action function, adding zero
  top-level lines, keeping `run-lazy-loader.tst.sh` and `run-eager-files.tst.sh`
  unchanged, and working when sourced standalone (with `spl-desk-install-service.func.sh`).
  Note: `$(id -un)` in `review-go` and `topic-archive-suggest` is now evaluated before
  `_spl_run_cron_apply` on every action rather than only on `install`; output and exit
  codes are identical (same as r05-02 N6). None of the four `.func.sh` files handles any
  token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_run_cron_apply` 34 -> 36 lines;
  `do_spl_spawn_fill_install_cron` 24 lines; `do_spl_spawn_place_install_cron` 42 -> 26
  lines; `do_spl_review_go_install_cron` 41 -> 25 lines;
  `do_spl_topic_archive_suggest_install_cron` 40 -> 24 lines; all three 10-line
  `spl_*_cron_check` functions deleted. None of the 5 edited files has any entry in
  `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh`: update `_spl_run_cron_apply`
  comment and body (`:53-89`) to accept optional 11th arg `mode="${11:-x}"` (`r` checks
  `-r "$run"` with `"FAIL $run is gone"` / `"FATAL $run is missing in $src"`; default `x`
  unchanged). 89 -> 91 lines (`+7 -5`).
- `orc:src/bash/run/spl-spawn-place-install-cron.func.sh`: drop unused `current` from
  `local` at `:29`; replace `:46-79` (dropping `spl_spawn_place_cron_check`) with
  lazy-source + `_spl_run_cron_apply`. 79 -> 52 lines (`+7 -34`).
- `orc:src/bash/run/spl-review-go-install-cron.func.sh`: drop unused `current` from
  `local` at `:30`; replace `:46-79` (dropping `spl_review_go_cron_check`) with
  lazy-source + `_spl_run_cron_apply`. 79 -> 52 lines (`+7 -34`).
- `orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh`: drop unused `current`
  from `local` at `:29`; replace `:44-77` (dropping `spl_archive_suggest_cron_check`) with
  lazy-source + `_spl_run_cron_apply` passing `""` and `r`. 77 -> 50 lines (`+7 -34`).
- `orc:src/bash/tests/spl-spawn-fill.tst.sh`: insert section `12` immediately before
  `echo` / `(( fails == 0 ))` at `:482` (line `:481` is already blank, so adding section
  `12` followed by one blank line leaves one blank line before and after): 1 direct
  `_spl_run_cron_apply` `mode=r` lifecycle check (install-missing, install-readable-0644,
  check-ok, check-missing, remove), 3 wave-2 one-copy checks, and 6 hermetic (`env -u`)
  standalone lazy-load checks (3 `check`-missing + 3 `DRY_RUN=0` install `ok_msg` checks
  including readable non-exec `topic-archive-suggest-cron.sh`) against `$T/crontab.s12`.
  485 -> 577 lines (`+92 -0`). Total edited files: **5** (within rulebook 3.1's max 5;
  the wave-1 and wave-2 sibling test suites run unmodified in the test column).
- head1's files, sha256 (12 chars): `spl-spawn-fill-install-cron.func.sh` `90f45f67f8f1`,
  `spl-spawn-place-install-cron.func.sh` `d80ebc168d97`,
  `spl-review-go-install-cron.func.sh` `ed420ce5cd50`,
  `spl-topic-archive-suggest-install-cron.func.sh` `c8474cb42cb1`,
  `spl-spawn-fill.tst.sh` `32326c024963`.
- Note for the row and its reviewer: build `gc1a`-`gc1c` and `m1a`-`m1c` in detached git
  worktrees, not single-file temp copies, because the lazy-source guard loads its sibling
  via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper, caller, and test hunks (head1 on `f9521a941`):

`orc:src/bash/run/spl-spawn-fill-install-cron.func.sh` (replaces `:53-89`):
```bash
# _spl_run_cron_apply <act> <tag> <src> <trunk> <run> <logdir> <line> <label>
#   <ok_msg> [miss_why] [mode] -> run check, dry-run, remove, or install for a
#   single-line tagged crontab action (mode: x = -x default, r = -r script).
_spl_run_cron_apply() {
  local act="$1" tag="$2" src="$3" trunk="$4" run="$5" logdir="$6" line="$7"
  local label="$8" ok_msg="$9" miss_why="${10:-}" mode="${11:-x}" current
  current="$(spl_desk_cron_line "$tag")"
  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the $label is NOT installed (no line tagged $tag)$miss_why"
      return 1
    fi
    spl_desk_cron_say "$current"
    if [[ "$mode" == r ]]; then [[ -r "$run" ]] || { do_log "FAIL $run is gone"; return 1; }
    else [[ -x "$run" ]] || { do_log "FAIL $run is gone or not executable"; return 1; }; fi
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the $label is installed"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the $label is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  if [[ "$mode" == r ]]; then [[ -r "$run" ]] || { do_log "FATAL $run is missing in $src"; return 1; }
  else [[ -x "$run" ]] || { do_log "FATAL $run is missing or not executable in $src"; return 1; }; fi
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the $label $ok_msg:"
  spl_desk_cron_say "$line"
}
```

`orc:src/bash/run/spl-spawn-place-install-cron.func.sh` (replaces `:46-79`; also remove
`current` from `local` at `:29`):
```bash
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "spawn placer" \
    "runs every minute as the box user (it acts only while this machine holds the orch role)" \
    ": queued spawn requests wait for a hand placement"
}
```

`orc:src/bash/run/spl-review-go-install-cron.func.sh` (replaces `:46-79`; also remove
`current` from `local` at `:30`):
```bash
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "review GO" \
    "runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease)" \
    ": a review PASS waits for a model to send the GO"
}
```

`orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh` (replaces `:44-77`; also
remove `current` from `local` at `:29`):
```bash
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "archive suggestion" \
    "runs hourly as $(id -un) (dry until lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0)" \
    "" r
}
```

`orc:src/bash/tests/spl-spawn-fill.tst.sh` section `12` (inserted immediately before
`echo` / `(( fails == 0 ))` at `:482`, followed by one blank line; `:481` is already blank):
```bash
# --- 12. _spl_run_cron_apply mode=r and wave-2 delegation (r06-01 one copy) -------
printf '%s\n' '# keep me' >"$T/crontab.s12"
cp "$T/crontab.s12" "$T/crontab.s12.orig"
mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
: >"$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
chmod 644 "$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
out="$(env PROJ_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SRC="$SRC" T="$T" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-fill-install-cron.func.sh"
  scr="$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
  _spl_run_cron_apply install "csi-spl:rjob" "$SRC" master "$T/no-such-script" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc1=$?"
  _spl_run_cron_apply install "csi-spl:rjob" "$SRC" master "$scr" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc2=$?"
  _spl_run_cron_apply check "csi-spl:rjob" "$SRC" master "$scr" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc3=$?"
  _spl_run_cron_apply check "csi-spl:rjob" "$SRC" master "$T/no-such-script" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc4=$?"
  _spl_run_cron_apply remove "csi-spl:rjob" "$SRC" master "$scr" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc5=$?"' 2>&1)"
[[ "$out" == *"FATAL $T/no-such-script is missing in $SRC"* && "$out" != *"not executable"* && "$out" == *"rc1=1"* \
  && "$out" == *"OK the rjob runs hourly:"* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the rjob is installed"* && "$out" == *"rc3=0"* \
  && "$out" == *"FAIL $T/no-such-script is gone"* && "$out" == *"rc4=1"* \
  && "$out" == *"OK the rjob is out of the crontab"* && "$out" == *"rc5=0"* ]] &&
  cmp -s "$T/crontab.s12" "$T/crontab.s12.orig" &&
  pass "12. _spl_run_cron_apply mode=r accepts a readable non-exec script and emits exact missing/gone wording" || fail "12. mode=r lifecycle: $out"

sp_f="$PROJ_ROOT/src/bash/run/spl-spawn-place-install-cron.func.sh"
rg_f="$PROJ_ROOT/src/bash/run/spl-review-go-install-cron.func.sh"
as_f="$PROJ_ROOT/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh"
for sib in "$sp_f" "$rg_f" "$as_f"; do
  own="$(grep -nE "spl_(spawn_place|review_go|archive_suggest)_cron_check|the crontab does not read back what was written|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_run_cron_apply " "$sib" &&
    pass "12. one copy: $(basename "$sib") delegates apply to _spl_run_cron_apply" || fail "12. one copy $(basename "$sib"): own=[$own]"
done

out="$(env -u SPAWN_PLACE_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SPAWN_PLACE_CRON_LOG_DIR="$T/log-sp" SPAWN_PLACE_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-place-install-cron.func.sh"
  do_spl_spawn_place_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the spawn placer is NOT installed (no line tagged csi-spl:spawn-place): queued spawn requests wait for a hand placement"* && "$out" != *"command not found"* ]] &&
  pass "12. lazy load: spl-spawn-place-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "12. lazy sp (rc=$rc): $out"

out="$(env -u SPAWN_PLACE_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SPAWN_PLACE_CRON_LOG_DIR="$T/log-sp" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-place-install-cron.func.sh"
  do_spl_spawn_place_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the spawn placer runs every minute as the box user (it acts only while this machine holds the orch role):"* ]] &&
  pass "12. spawn-place install keeps exact ok_msg" || fail "12. sp ok (rc=$rc): $out"

out="$(env -u REVIEW_GO_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" REVIEW_GO_CRON_LOG_DIR="$T/log-rg" REVIEW_GO_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-review-go-install-cron.func.sh"
  do_spl_review_go_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the review GO is NOT installed (no line tagged csi-spl:review-go): a review PASS waits for a model to send the GO"* && "$out" != *"command not found"* ]] &&
  pass "12. lazy load: spl-review-go-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "12. lazy rg (rc=$rc): $out"

out="$(env -u REVIEW_GO_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" REVIEW_GO_CRON_LOG_DIR="$T/log-rg" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-review-go-install-cron.func.sh"
  do_spl_review_go_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the review GO runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"* ]] &&
  pass "12. review-go install keeps exact ok_msg" || fail "12. rg ok (rc=$rc): $out"

out="$(env -u ARCHIVE_SUGGEST_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ARCHIVE_SUGGEST_CRON_LOG_DIR="$T/log-as" ARCHIVE_SUGGEST_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh"
  do_spl_topic_archive_suggest_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the archive suggestion is NOT installed (no line tagged csi-spl:topic-archive-suggest)" && "$out" != *"command not found"* ]] &&
  pass "12. lazy load: spl-topic-archive-suggest-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "12. lazy as (rc=$rc): $out"

out="$(env -u ARCHIVE_SUGGEST_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ARCHIVE_SUGGEST_CRON_LOG_DIR="$T/log-as" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh"
  do_spl_topic_archive_suggest_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the archive suggestion runs hourly as $(id -un) (dry until lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0):"* ]] &&
  pass "12. topic-archive-suggest install keeps exact ok_msg on readable non-exec script" || fail "12. as ok (rc=$rc): $out"
```

**Behaviour:** zero behaviour change. All three wave-2 installers emit their exact
check-missing, check-ok, dry-run, remove, and install log lines and exit codes (all 6
standalone lazy-load and install `ok_msg` checks pass on unmodified `base` too), and all
four wave-1 installers keep their default `mode=x` behaviour unchanged.

### 1.4 Row 02's site: `cron_refuse_linked_worktree` in `cron-tagged-line.func.sh` and wave-1 delegation for `spl-box-update-install-cron`, `spl-cost-rollup-install-cron`, and `git-prune-merged-install-cron`

`orc:` = `csi-spl-orc/`. On `f9521a941`:

- Twelve `orc:src/bash/run/` files inline the exact same 6-line linked-worktree guard
  (`git rev-parse --path-format=absolute --git-dir` vs `--git-common-dir`; when `dry == 0`,
  `do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing
  changed"; return 1`; when `dry == 1`, `echo "WARN $PROJ_PATH is a linked worktree: the
  path below would vanish with it; install from the main checkout"`). Eleven of them
  already call `cron_drop_tagged_line` from `orc:lib/bash/funcs/cron-tagged-line.func.sh`
  (loaded automatically by `./run` and `in_orc`).
- `cron_refuse_linked_worktree` has **0 collisions** anywhere in the repo
  (`git grep -nE 'cron_refuse_linked_worktree' f9521a941` -> 0).
- Adding `cron_refuse_linked_worktree <dry> [allow]` (12 lines) to
  `orc:lib/bash/funcs/cron-tagged-line.func.sh` adds zero new files to `lib/bash/funcs/`,
  keeps `run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged, and lets three
  clean non-secret wave-1 callers drop their duplicated guard and unused `gd cd` locals:
  1. `orc:src/bash/run/spl-box-update-install-cron.func.sh:28,47-52` (already tested
     against a fixture linked worktree in `spl-box-update-install-cron.tst.sh:66-75`,
     which explicitly sources `lib/bash/funcs/cron-tagged-line.func.sh`).
  2. `orc:src/bash/run/spl-cost-rollup-install-cron.func.sh:36,57-62`.
  3. `orc:src/bash/run/git-prune-merged-install-cron.func.sh:23,33-38`.
  None of the four `.func.sh` files handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `cron_drop_tagged_line` 20 lines;
  `cron_refuse_linked_worktree` 12 lines; `do_spl_box_update_install_cron` 34 -> 29 lines;
  `do_spl_cost_rollup_install_cron` 39 -> 34 lines;
  `do_git_prune_merged_install_cron` 23 -> 18 lines. None of the 5 edited files has any
  entry in `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:lib/bash/funcs/cron-tagged-line.func.sh`: append `cron_refuse_linked_worktree`
  (12-line helper + 3-line comment + 1 blank line). 40 -> 56 lines (`+16 -0`).
- `orc:src/bash/run/spl-box-update-install-cron.func.sh`: drop unused `gd cd` from `local`
  at `:28`; replace `:47-52` with `cron_refuse_linked_worktree "$dry"
  "${BOX_UPDATE_ALLOW_WORKTREE:-0}" || return 1`. 64 -> 59 lines (`+2 -7`).
- `orc:src/bash/run/spl-cost-rollup-install-cron.func.sh`: drop unused `gd cd` from `local`
  at `:36`; replace `:57-62` with `cron_refuse_linked_worktree "$dry"
  "${COST_ROLLUP_ALLOW_WORKTREE:-0}" || return 1`. 82 -> 77 lines (`+2 -7`).
- `orc:src/bash/run/git-prune-merged-install-cron.func.sh`: drop unused `gd cd` from
  `local` at `:23`; replace `:33-38` with `[[ "$act" == install ]] && {
  cron_refuse_linked_worktree "$dry" "${GIT_PRUNE_ALLOW_WORKTREE:-0}" || return 1; }`.
  43 -> 38 lines (`+2 -7`).
- `orc:src/bash/tests/cron-tagged-line.tst.sh`: insert section `7` immediately before the
  final summary line at `:70` (line `:69` is already blank): 5 direct
  `cron_refuse_linked_worktree` checks (main checkout, non-git dir, linked worktree
  `dry=0`, linked worktree `dry=1`, linked worktree `allow=1`), 4 one-copy checks (host +
  3 wave-1 installers), and 3 standalone installer linked-worktree checks (`git-prune-merged`
  `DRY_RUN=0`/`DRY_RUN=1` and `cost-rollup` `DRY_RUN=0`). 70 -> 123 lines (`+53 -0`).
  Total edited files: **5** (within rulebook 3.1's max 5; the sibling test suites run
  unmodified in the test column).
- head2's files, sha256 (12 chars): `cron-tagged-line.func.sh` `393ecc8a586d`,
  `spl-box-update-install-cron.func.sh` `072806852e51`,
  `spl-cost-rollup-install-cron.func.sh` `569b0052759c`,
  `git-prune-merged-install-cron.func.sh` `726a96dfe9ab`,
  `cron-tagged-line.tst.sh` `57bffcc274b4`.

Verbatim helper, caller, and test hunks (head2 on `f9521a941`):

`orc:lib/bash/funcs/cron-tagged-line.func.sh` (appended after `:40`, preceded by one blank
line):
```bash
# cron_refuse_linked_worktree <dry> [allow]: refuse an install from a linked
# git worktree ($PROJ_PATH vanishes with it); dry=1 warns and returns 0,
# dry=0 logs FATAL and returns 1. allow=1 skips the check (for tests).
cron_refuse_linked_worktree() {
  local dry="$1" allow="${2:-0}" gd cd
  [[ "$allow" == 1 ]] && return 0
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$gd" && "$gd" != "$cd" ]] || return 0
  if [[ "$dry" == 0 ]]; then
    do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"
    return 1
  fi
  echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
}
```

`orc:src/bash/run/spl-box-update-install-cron.func.sh` (replaces `:47-52`; also remove
`gd cd` from `local` at `:28`):
```bash
    cron_refuse_linked_worktree "$dry" "${BOX_UPDATE_ALLOW_WORKTREE:-0}" || return 1
```

`orc:src/bash/run/spl-cost-rollup-install-cron.func.sh` (replaces `:57-62`; also remove
`gd cd` from `local` at `:36`):
```bash
    cron_refuse_linked_worktree "$dry" "${COST_ROLLUP_ALLOW_WORKTREE:-0}" || return 1
```

`orc:src/bash/run/git-prune-merged-install-cron.func.sh` (replaces `:33-38`; also remove
`gd cd` from `local` at `:23`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${GIT_PRUNE_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/tests/cron-tagged-line.tst.sh` section `7` (inserted immediately before
`[ "$fails" -eq 0 ]` at `:70`, followed by one blank line; `:69` is already blank):
```bash
# 7. cron_refuse_linked_worktree and wave-1 delegation (r06-02 one copy)
git init -q -b master "$T/wt-main" && git -C "$T/wt-main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T/wt-main" worktree add -q --detach "$T/wt-linked"
mkdir -p "$T/wt-main/csi-spl-orc" "$T/wt-linked/csi-spl-orc" "$T/wt-nogit/csi-spl-orc"
wt_check() {
  local pp="$1"; shift
  env PROJ_PATH="$pp" LIB="$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$LIB"; cron_refuse_linked_worktree "$@"' _ "$@" 2>&1
}
out="$(wt_check "$T/wt-main/csi-spl-orc" 0 0)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "7. cron_refuse_linked_worktree allows a main checkout (dry=0)" || fail "7. main ($rc: $out)"
out="$(wt_check "$T/wt-nogit/csi-spl-orc" 0 0)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "7. cron_refuse_linked_worktree allows a non-git dir (dry=0)" || fail "7. nogit ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 0)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" ] \
  && pass "7. cron_refuse_linked_worktree refuses a linked worktree when dry=0" || fail "7. linked dry=0 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 1 0)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" ] \
  && pass "7. cron_refuse_linked_worktree warns and returns 0 when dry=1" || fail "7. linked dry=1 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "7. cron_refuse_linked_worktree skips when allow=1" || fail "7. linked allow=1 ($rc: $out)"

ctl_f="$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh"
[ "$(grep -c 'is a linked worktree: install from the main checkout' "$ctl_f")" -eq 1 ] && grep -q '^cron_refuse_linked_worktree()' "$ctl_f" \
  && pass "7. one copy: cron-tagged-line.func.sh hosts cron_refuse_linked_worktree" || fail "7. host one copy"
for sib in \
  "$PROJ_ROOT/src/bash/run/spl-box-update-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-cost-rollup-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/git-prune-merged-install-cron.func.sh"; do
  own="$(grep -nE 'is a linked worktree: install from the main checkout|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "7. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "7. one copy $(basename "$sib"): own=[$own]"
done

# standalone installer linked-worktree checks (dry=1 warns, dry=0 refuses)
out="$(env -u GIT_PRUNE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" GIT_PRUNE_CRONTAB="$T/fake-crontab" GIT_PRUNE_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_git_prune_merged_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/git-prune-merged-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "7. git-prune-merged refuses a linked worktree when DRY_RUN=0" || fail "7. git-prune dry=0 ($rc: $out)"
out="$(env -u GIT_PRUNE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" GIT_PRUNE_CRONTAB="$T/fake-crontab" GIT_PRUNE_CRON_LOG_DIR="$T/log" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_git_prune_merged_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/git-prune-merged-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "7. git-prune-merged warns on a linked worktree when DRY_RUN=1" || fail "7. git-prune dry=1 ($rc: $out)"
out="$(env -u COST_ROLLUP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" ENV=dev COST_ROLLUP_CRON_SCHEDULE="0 2 * * *" COST_ROLLUP_CRONTAB="$T/fake-crontab" COST_ROLLUP_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; source "$3"; do_spl_cost_rollup_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-cost-rollup-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "7. cost-rollup refuses a linked worktree when DRY_RUN=0" || fail "7. cost-rollup dry=0 ($rc: $out)"
```

**Behaviour:** zero behaviour change. All three wave-1 installers emit their exact
linked-worktree `FATAL` (when `DRY_RUN=0`) and `WARN` (when `DRY_RUN=1`) messages and
exit codes (all 3 standalone installer linked-worktree checks pass on unmodified `base`
too), and when `*_ALLOW_WORKTREE=1` or on a main/non-git checkout return 0 without
side effects.

### 1.5 Before and on the rows' heads

2026-11-26T05:48Z-06:56Z, n=1, as the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and
`SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines `grep -ciE '^ *(ok|pass)'`,
fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to base: same rc, pass and
fail counts; "-" means that row's head does not touch the suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-spawn-fill.tst.sh` | 01 | 0 / 55\* / 0 | 0 / 65\* / 0 (+10 new checks) | - |
| `orc:src/bash/tests/spl-security-round-queue.tst.sh` | 01 | 0 / 33\* / 0 | = | - |
| `orc:src/bash/tests/spl-desk-poll-ack.tst.sh` | 01 | 0 / 37 / 0 | = | - |
| `orc:src/bash/tests/spl-accepted-close.tst.sh` | 01 | 0 / 32 / 0 | = | - |
| `orc:src/bash/tests/spl-spawn-queue.tst.sh` | 01 | 0 / 327\* / 0 | = | - |
| `orc:src/bash/tests/spl-review-go.tst.sh` | 01 | 0 / 210 / 0 | = | - |
| `orc:src/bash/tests/spl-topic-archive-suggest.tst.sh` | 01 | 0 / 51 / 0 | = | - |
| `orc:src/bash/tests/cron-tagged-line.tst.sh` | 02 | 0 / 9 / 0 | - | 0 / 21 / 0 (+12 new checks) |
| `orc:src/bash/tests/spl-box-update-install-cron.tst.sh` | 02 | 0 / 12 / 0 | - | = |
| `orc:src/bash/tests/spl-cost-rollup-install-cron.tst.sh` | 02 | 0 / 16 / 0 | - | = |
| `orc:src/bash/tests/git-prune-merged-cron.tst.sh` | 02 | 0 / 15 / 0 | - | = |
| `orc:src/bash/tests/od-pool-replace.tst.sh` | 02 | 0 / 9 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note (\*): `spl-spawn-fill.tst.sh`, `spl-security-round-queue.tst.sh`, and
`spl-spawn-queue.tst.sh` print a trailing `PASS: all` line on success (counted by
`grep -ciE '^ *(ok|pass)'`: `spl-spawn-fill` base = 54 `PASS:` + 1 `PASS: all`, head1 =
64 `PASS:` + 1 `PASS: all`; `spl-spawn-queue` base and head1 = 326 `PASS:` + 1 `PASS: all`) and a trailing
`FAIL: <N>` line on failure (counted by `grep -ciE '^ *(not ok|fail)'`). Multi-line
`$out` dumped inside a `fail` message on `rc1`, `m2a`, `m2b`, `m2c`, and `m2d` also
includes raw `OK ...` or `FAIL ...` log lines on their own lines, which the line counter
counts alongside real `PASS:`/`FAIL:` checks (broken down per control below). Run every
suite and control in a git worktree (not a plain `git archive` export): outside a git
tree, `no-literal-paths.tst.sh` reads `STALE` on base and heads alike (`0/15/0` in a git
worktree).

`shellcheck 0.10.0 -S warning -x` on all 10 edited files (head1: 5 files, head2: 5 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's 5 touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `f9521a941`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `spl-spawn-fill.tst.sh` on base): rc 1, 61 `ok|pass`
  lines (54 base + all 6 standalone lazy-load/install checks passing on base, proving
  equivalence, + 1 dumped `OK` line), 7 fail lines (4 real `FAIL:` checks: `12. mode=r
  lifecycle` + 3 `12. one copy` checks naming `:48`, `:48`, `:46` + 2 dumped `FAIL the
  rjob is NOT installed` lines + trailing `FAIL: 4`); head1: rc 0, 65 pass (64 `PASS:` +
  `PASS: all`), 0 fail.
- Row 01 guard control a (`gc1a`, head1 with `declare -F _spl_run_cron_apply` deleted in
  `spl-spawn-place-install-cron.func.sh`): rc 1, 62 pass, 3 fail lines (2 `FAIL:` checks
  `12. lazy sp` and `12. sp ok`, both rc=127 `line 47: _spl_run_cron_apply: command not
  found`, + trailing `FAIL: 2`).
- Row 01 guard control b (`gc1b`, head1 with `declare -F _spl_run_cron_apply` deleted in
  `spl-review-go-install-cron.func.sh`): rc 1, 62 pass, 3 fail lines (2 `FAIL:` checks
  `12. lazy rg` and `12. rg ok`, both rc=127 `line 47: _spl_run_cron_apply: command not
  found`, + trailing `FAIL: 2`).
- Row 01 guard control c (`gc1c`, head1 with `declare -F _spl_run_cron_apply` deleted in
  `spl-topic-archive-suggest-install-cron.func.sh`): rc 1, 62 pass, 3 fail lines (2
  `FAIL:` checks `12. lazy as` and `12. as ok`, both rc=127 `line 45: _spl_run_cron_apply:
  command not found`, + trailing `FAIL: 2`).
- Row 02 red control (`rc2`, head2's `cron-tagged-line.tst.sh` on base): rc 1, 12 pass (9
  base + all 3 standalone installer linked-worktree checks passing on base, proving
  equivalence), 9 fail (5 direct `cron_refuse_linked_worktree` checks rc=127 `command not
  found` + `7. host one copy` + 3 `7. one copy` checks naming `:48`, `:58`, `:34`);
  head2: rc 0, 21 pass, 0 fail.

**Mutation checks** (n=1 each, detached worktrees of `f9521a941` with head1/head2
applied, then one defect injected):
- `m1a` (`spl-spawn-place-install-cron.func.sh` replaces arg 10 `miss_why` with `""`):
  `spl-spawn-fill.tst.sh` rc 1, 63 pass, 2 fail lines (`FAIL: 12. lazy sp` + trailing
  `FAIL: 1`).
- `m1b` (`spl-review-go-install-cron.func.sh` replaces arg 10 `miss_why` with `""`):
  `spl-spawn-fill.tst.sh` rc 1, 63 pass, 2 fail lines (`FAIL: 12. lazy rg` + trailing
  `FAIL: 1`).
- `m1c` (`spl-topic-archive-suggest-install-cron.func.sh` omits 11th arg `r`, falling back
  to default `mode=x`): `spl-spawn-fill.tst.sh` rc 1, 63 pass, 2 fail lines (`FAIL: 12. as
  ok (rc=1): FATAL .../topic-archive-suggest-cron.sh is missing or not executable` +
  trailing `FAIL: 1`).
- `m2a` (`cron_refuse_linked_worktree` in `cron-tagged-line.func.sh` returns 0 instead of
  1 on `dry=0`): `cron-tagged-line.tst.sh` rc 1, 20 `ok|pass` lines (18 real `PASS:` + 2
  dumped `OK` lines), 3 fail (`FAIL: 7. linked dry=0`, `FAIL: 7. git-prune dry=0`,
  `FAIL: 7. cost-rollup dry=0`).
- `m2b` (`spl-box-update-install-cron.func.sh` passes `1` instead of
  `"${BOX_UPDATE_ALLOW_WORKTREE:-0}"`): `spl-box-update-install-cron.tst.sh` rc 1, 12
  `ok|pass` lines (11 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 6. worktree`).
- `m2c` (`spl-cost-rollup-install-cron.func.sh` passes `1` instead of
  `"${COST_ROLLUP_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 21 `ok|pass`
  lines (20 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 7. cost-rollup dry=0`).
- `m2d` (`git-prune-merged-install-cron.func.sh` passes `1` instead of
  `"${GIT_PRUNE_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 20 `ok|pass` lines
  (19 real `PASS:` + 1 dumped `OK` line), 2 fail (`FAIL: 7. git-prune dry=0`, `FAIL: 7.
  git-prune dry=1`).

The tests that name the sites (R2): `git grep -lE` over `*tst.sh`, `features/*/tests/*`,
`csi-spl-api/`, and `csi-spl-iac/` for row 01
(`spl-(spawn-fill|spawn-place|review-go|topic-archive-suggest)-install-cron|do_spl_(spawn_fill|spawn_place|review_go|topic_archive_suggest)_install_cron`)
-> `orc:src/bash/tests/spl-spawn-fill.tst.sh`, `orc:src/bash/tests/spl-spawn-queue.tst.sh`,
`orc:src/bash/tests/spl-review-go.tst.sh`,
`orc:src/bash/tests/spl-topic-archive-suggest.tst.sh` (0 hits in `csi-spl-api/` or
`csi-spl-iac/`); plus the three wave-1 regression suites (`spl-security-round-queue.tst.sh`,
`spl-desk-poll-ack.tst.sh`, `spl-accepted-close.tst.sh`) because row 01 touches
`_spl_run_cron_apply` in `spl-spawn-fill-install-cron.func.sh`. For row 02
(`cron-tagged-line|cron_drop_tagged_line|spl-(box-update|cost-rollup)-install-cron|do_spl_(box_update|cost_rollup)_install_cron|git-prune-merged-install-cron|do_git_prune_merged_install_cron`)
-> `orc:src/bash/tests/cron-tagged-line.tst.sh`,
`orc:src/bash/tests/spl-box-update-install-cron.tst.sh`,
`orc:src/bash/tests/spl-cost-rollup-install-cron.tst.sh`,
`orc:src/bash/tests/git-prune-merged-cron.tst.sh`,
`orc:src/bash/tests/od-pool-replace.tst.sh` (`:122` explicitly sources
`cron-tagged-line.func.sh`; `spl-box-deploy.tst.sh:65` defines a stub function only
without sourcing `spl-box-update-install-cron.func.sh` and stays out of the test column;
0 hits in `csi-spl-api/` or `csi-spl-iac/`). 30-char non-header comment grep across all 8
`.func.sh` files -> 12 comments >= 30 chars, hits only on the untouched `# shellcheck
disable=SC2016 # $HOME...` directives matching tests' own shellcheck directives, never
grepping source text. No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r06-01-orc-run-cron-apply-wave2)` | one fact, one copy (developer guide 2.2.4) | `spl-spawn-place-install-cron.func.sh:46-79`, `spl-review-go-install-cron.func.sh:46-79`, and `spl-topic-archive-suggest-install-cron.func.sh:44-77` duplicate the 32-34 line crontab `check` (`spl_*_cron_check`) / `DRY_RUN=1` / `remove` / `install` state machine hosted in `_spl_run_cron_apply` (`spl-spawn-fill-install-cron.func.sh:56-89`, landed in `r05-02` `62c5bea32`); adding optional 11th arg `mode="${11:-x}"` (`r` for `-r` script) completes 7/7 wave-1..2 consolidation (1.3, r05 section 7 #1) | `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh:53-89`<br>`orc:src/bash/run/spl-spawn-place-install-cron.func.sh:29,46-79`<br>`orc:src/bash/run/spl-review-go-install-cron.func.sh:30,46-79`<br>`orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh:29,44-77`<br>`orc:src/bash/tests/spl-spawn-fill.tst.sh:482` | copies of the `./run`/flock cron check/dry-run/remove/install state machine and `spl_*_cron_check` across these 3 wave-2 installers + host 4 -> 1 (7/7 wave-1..2 sharing `_spl_run_cron_apply`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head's `spl-spawn-fill.tst.sh` on parent FAILs 4 checks (`rc1`, rc 1, 61 `ok\|pass` lines, 7 fail lines = 4 `FAIL:` + 2 dumped `FAIL` + `FAIL: 4`: `mode=r lifecycle` + 3 one-copy checks naming `:48`, `:48`, `:46`; all 6 standalone checks pass on base), then GREEN (`0/65*/0`); guard controls (`gc1a`, `gc1b`, `gc1c`, `declare -F _spl_run_cron_apply` deleted in each wave-2 installer, built in worktrees: rc 1, `62/3` = 2 `FAIL:` + `FAIL: 2` each with `_spl_run_cron_apply: command not found`); mutations `m1a`/`m1b` (arg 10 `""`, rc 1 `63/2` each) and `m1c` (omit arg 11 `r`, rc 1 `63/2` `is missing or not executable`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 10 new checks in `spl-spawn-fill.tst.sh`. Tests: **`orc:.../spl-spawn-fill.tst.sh`**, `orc:.../spl-security-round-queue.tst.sh`, `orc:.../spl-desk-poll-ack.tst.sh`, `orc:.../spl-accepted-close.tst.sh`, `orc:.../spl-spawn-queue.tst.sh`, `orc:.../spl-review-go.tst.sh`, `orc:.../spl-topic-archive-suggest.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r06-02-orc-cron-worktree-guard-wave1)` | one fact, one copy (developer guide 2.2.4) | `spl-box-update-install-cron.func.sh:47-52`, `spl-cost-rollup-install-cron.func.sh:57-62`, and `git-prune-merged-install-cron.func.sh:33-38` (3 of 12 files in `orc:src/bash/run/`) duplicate the exact 6-line linked-worktree refusal/warning guard while already sharing `cron_drop_tagged_line` from `orc:lib/bash/funcs/cron-tagged-line.func.sh` (1.4) | `orc:lib/bash/funcs/cron-tagged-line.func.sh:40`<br>`orc:src/bash/run/spl-box-update-install-cron.func.sh:28,47-52`<br>`orc:src/bash/run/spl-cost-rollup-install-cron.func.sh:36,57-62`<br>`orc:src/bash/run/git-prune-merged-install-cron.func.sh:23,33-38`<br>`orc:src/bash/tests/cron-tagged-line.tst.sh:70` | copies of the linked-worktree cron guard across these 3 wave-1 installers 3 -> 1 (`cron_refuse_linked_worktree` in `cron-tagged-line.func.sh`; total copies across `orc:src/bash/run/` + `lib/` 12 -> 10) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head's `cron-tagged-line.tst.sh` on parent FAILs 9 checks (`rc2`, rc 1, 12 pass, 9 fail: 5 direct helper checks rc=127 `command not found` + host + 3 one-copy checks naming `:48`, `:58`, `:34`; all 3 standalone installer checks pass on base), then GREEN (`0/21/0`); mutations `m2a` (`cron_refuse_linked_worktree` returns 0 on `dry=0`, rc 1 `20*/3`), `m2b` (`box-update` passes `allow=1`, `spl-box-update-install-cron.tst.sh` rc 1 `12*/1`), `m2c` (`cost-rollup` passes `allow=1`, `cron-tagged-line.tst.sh` rc 1 `21*/1`), and `m2d` (`git-prune-merged` passes `allow=1`, `cron-tagged-line.tst.sh` rc 1 `20*/2`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 12 new checks in `cron-tagged-line.tst.sh`. Tests: **`orc:.../cron-tagged-line.tst.sh`**, `orc:.../spl-box-update-install-cron.tst.sh`, `orc:.../spl-cost-rollup-install-cron.tst.sh`, `orc:.../git-prune-merged-cron.tst.sh`, `orc:.../od-pool-replace.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r06-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r06-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows extract or extend internal crontab-installer helpers with zero change
to any output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper extension and delegation; no behaviour changes)` (row 01) and
`Docs: none (internal helper extraction and delegation; no behaviour changes)` (row 02).
The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-spawn-fill-install-cron.func.sh`, `spl-spawn-place-install-cron.func.sh`,
  `spl-review-go-install-cron.func.sh`, `spl-topic-archive-suggest-install-cron.func.sh`,
  `spl-spawn-fill.tst.sh`; row 02: `csi-spl-orc` `cron-tagged-line.func.sh`,
  `spl-box-update-install-cron.func.sh`, `spl-cost-rollup-install-cron.func.sh`,
  `git-prune-merged-install-cron.func.sh`, `cron-tagged-line.tst.sh`).
- No row edits `orc:src/bash/run/spl-review-go.func.sh`,
  `orc:src/bash/tests/spl-review-go.tst.sh` (live in `b50-01`),
  `orc:src/bash/tests/spl-spawn-queue.tst.sh`,
  `orc:src/bash/tests/spl-topic-archive-suggest.tst.sh`,
  `orc:src/bash/run/box-disk-sweep-install-cron.func.sh`,
  `orc:src/bash/run/prune-docker-images-install-cron.func.sh`,
  `orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh`,
  `orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh`,
  `orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh`,
  `orc:src/bash/run/spl-private-overlay-install-cron.func.sh`,
  `orc:src/bash/run/spl-shadow-feed-install-cron.func.sh`,
  `orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh`,
  `orc:src/bash/run/install-box-crons.func.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, `csi-spl-utl/`, or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (10 edited + 6 sibling regression-run test files = 16 checked; `spl-review-go.tst.sh`
is intentionally NOT edited because live `b50-01` edits it, and runs read-only in row 01's
test column):
`orc:src/bash/run/spl-spawn-fill-install-cron.func.sh`,
`orc:src/bash/run/spl-spawn-place-install-cron.func.sh`,
`orc:src/bash/run/spl-review-go-install-cron.func.sh`,
`orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh`,
`orc:src/bash/tests/spl-spawn-fill.tst.sh`,
`orc:src/bash/tests/spl-spawn-queue.tst.sh`,
`orc:src/bash/tests/spl-topic-archive-suggest.tst.sh`;
`orc:lib/bash/funcs/cron-tagged-line.func.sh`,
`orc:src/bash/run/spl-box-update-install-cron.func.sh`,
`orc:src/bash/run/spl-cost-rollup-install-cron.func.sh`,
`orc:src/bash/run/git-prune-merged-install-cron.func.sh`,
`orc:src/bash/tests/cron-tagged-line.tst.sh`,
`orc:src/bash/tests/spl-box-update-install-cron.tst.sh`,
`orc:src/bash/tests/spl-cost-rollup-install-cron.tst.sh`,
`orc:src/bash/tests/git-prune-merged-cron.tst.sh`,
`orc:src/bash/tests/od-pool-replace.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 16 paths> --agent a-942`, n=1, at
  2026-11-26T05:47:41Z: **exit 4** ("no live lane lists <the 16 paths>, but 18 live lane(s)
  record no files", 0 owned). All 18 `unknown:` live lanes are on the other box (13
  channel/workspace/other-repo seats `c-029`, `c-041`, `c-086`, `c-146`, `c-187`, `c-398`,
  `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-936`, plus `c-902` b50 panel
  seat, `c-904` s187 S1 rdb+store, `c-907` s196 T1 topic tags store, and `c-957`/`c-965`
  spec 125 doc/R7 seats). Verified via `do_spl_lane_map` at 05:38:34Z — live lanes on this
  box (`a-942`, `c-940` SPL-6561 R7, `c-938` / `a-934` s182 channel loops planner/panel,
  `c-936` s186 M2 hub send checks, `a-826` SPL-6517 latency action 7, `a-932` spec 150
  v2.0, `c-893` / `a-891` r05 closing, `a-927` b50 planner) touch none of the 16 paths.
  No live lane owns any of the 16 paths; the holder re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-26T05:38:38Z):
  6 queued, 0 placing (`e919eb62` this round's claude panel seat — since placed as `c-917`,
  `5b1b7d82` s186 M9 Qto sync, `d908fbc6` s186 M11 WUI multicast action, `cd76e33f` s187
  S2, `a8001b67` s187 S12a, `5a432cc3` Qto doc export PDF). None touches any of the 16
  paths.
- **Unlanded rows from r05:** **0** (`r05-01` landed `6b216a319`, `r05-02` landed
  `62c5bea32`, close record `2ccf23c21`).
- **Briefs on this box** modified in the last 24 h matching any of the 8 `.func.sh` paths
  (at 05:47Z): only the already-landed `c002-r05-02-orc-run-cron-apply-wave1.md` and
  `hand-sat-c002-r05-02-orc-run-cron-apply-agy-reviewer.md`; **0 live briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 05:47Z):
  `git diff --name-only $(git merge-base f9521a941 <b>) <b> -- <the 16 paths>` -> only
  three already-landed branches (`review/r05-02` landed `62c5bea32`, `review/b47-03` landed
  `a5cb972b7`, `review/c-652-c002-bug-placer-review-seat-overflow-pass` landed
  `ffaf6876d`); **0 unlanded branches**.
- **Commits in the last 24 h** on the 16 paths (`git log f9521a941 --since='24 hours ago'`,
  at 05:48Z) -> 3 landed commits (`62c5bea32` r05-02, `a5cb972b7` b47-03, `ffaf6876d`
  SPL-6521); 0 unlanded churn.

## 3. Per row: what the lane does

- **r06-01:** `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh` extends
  `_spl_run_cron_apply` (`:53-89`) with optional 11th arg `mode="${11:-x}"` (`r` checks
  `-r "$run"` with `"FAIL $run is gone"` and `"FATAL $run is missing in $src"`; default `x`
  unchanged). `orc:src/bash/run/spl-spawn-place-install-cron.func.sh`,
  `orc:src/bash/run/spl-review-go-install-cron.func.sh`, and
  `orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh` each drop unused
  `current` from `local`, drop their `spl_*_cron_check` function, lazy-source
  `spl-spawn-fill-install-cron.func.sh` behind `declare -F _spl_run_cron_apply` inside
  their action function, and delegate their apply tail to `_spl_run_cron_apply` (with `"" r`
  for `spl-topic-archive-suggest-install-cron`). `orc:src/bash/tests/spl-spawn-fill.tst.sh`
  inserts section `12` before `:482` (1 direct `mode=r` lifecycle check, 3 wave-2 one-copy
  checks, and 6 hermetic standalone lazy-load `check`-missing and `DRY_RUN=0` install
  `ok_msg` checks).
- **r06-02:** `orc:lib/bash/funcs/cron-tagged-line.func.sh` adds
  `cron_refuse_linked_worktree <dry> [allow]` after `:40`.
  `orc:src/bash/run/spl-box-update-install-cron.func.sh`,
  `orc:src/bash/run/spl-cost-rollup-install-cron.func.sh`, and
  `orc:src/bash/run/git-prune-merged-install-cron.func.sh` each drop unused `gd cd` from
  `local` and replace their inline 6-line linked-worktree guard with
  `cron_refuse_linked_worktree "$dry" "${<ALLOW_VAR>:-0}" || return 1`.
  `orc:src/bash/tests/cron-tagged-line.tst.sh` inserts section `7` before `:70` (5 direct
  helper checks, 4 one-copy checks, and 3 standalone installer linked-worktree checks).

## 4. Panel and reviewers (R7)

- Editor: **a-942** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-917** (live on
  the other box, placed for ask `e919eb62`). Returned **PASS** on v0.1
  (`9c39b5d2f76b8d19b60024754bcc59908c90b5e4`, seat commit `bdddcc409`, msg `9319e614` /
  `f8f607aa`; W1 and N1-N3 folded in v1.0; pending full review-line check and final v1.0
  signature). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-26T05:39:26Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 05:39:15Z (`pick=agy`, `main=agy`, `backup=claude`; mistral sits on no review), R7
    review of a claude coding row goes to an **agy seat** per row (claude waiver backup
    only while agy is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 05:39:34Z picked an available box
    (this box, 134% < 180% overflow, `agy weekly unknown`, placed anyway); the holder
    re-checks agy capacity at row placement and uses the claude waiver backup only if agy
    is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r06-01 | `c002-r06-01-orc-run-cron-apply-wave2` | `refactor(r06-01-orc-run-cron-apply-wave2, SPL-<row issue>): ...` | `review/r06-01` | 1 |
| r06-02 | `c002-r06-02-orc-cron-worktree-guard-wave1` | `refactor(r06-02-orc-cron-worktree-guard-wave1, SPL-<row issue>): ...` | `review/r06-02` | 1 |

**r06-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-spawn-fill-install-cron.func.sh` (extend
`_spl_run_cron_apply` at `:53-89` with optional 11th arg `mode="${11:-x}"` for `-r`),
`csi-spl-orc/src/bash/run/spl-spawn-place-install-cron.func.sh` (drop unused `current` at
`:29`, drop `spl_spawn_place_cron_check`, lazy-source `spl-spawn-fill-install-cron.func.sh`
and delegate `:46-79` to `_spl_run_cron_apply`),
`csi-spl-orc/src/bash/run/spl-review-go-install-cron.func.sh` (drop unused `current` at
`:30`, drop `spl_review_go_cron_check`, lazy-source `spl-spawn-fill-install-cron.func.sh`
and delegate `:46-79` to `_spl_run_cron_apply`),
`csi-spl-orc/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh` (drop unused
`current` at `:29`, drop `spl_archive_suggest_cron_check`, lazy-source
`spl-spawn-fill-install-cron.func.sh` and delegate `:44-77` to `_spl_run_cron_apply` with
`"" r`), and `csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh` (insert section `12`
before `:482`: 1 direct `mode=r` lifecycle check, 3 wave-2 one-copy checks, and 6 hermetic
standalone lazy-load `check`-missing and `DRY_RUN=0` install `ok_msg` checks). NOT
`spl-review-go.func.sh`, NOT `spl-review-go.tst.sh`, NOT `spl-spawn-queue.tst.sh`, NOT
`spl-topic-archive-suggest.tst.sh`, NOT `spl-desk-install-service.func.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 01 verbatim,
1.3's shape (verbatim blocks in 1.3); red control (`rc1`, head's `spl-spawn-fill.tst.sh`
on parent) RED then GREEN in the body; guard controls (`gc1a`, `gc1b`, `gc1c`, `declare -F
_spl_run_cron_apply` deleted in each wave-2 installer, built in worktrees); mutations
`m1a`/`m1b`/`m1c` caught by section `12`. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 5 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper extension and delegation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief
if the claude backup is used; never mistral; re-checked at placement).

**r06-02 brief, Files: ONLY**
`csi-spl-orc/lib/bash/funcs/cron-tagged-line.func.sh` (append
`cron_refuse_linked_worktree` after `:40`),
`csi-spl-orc/src/bash/run/spl-box-update-install-cron.func.sh` (drop unused `gd cd` at
`:28`, replace `:47-52` with `cron_refuse_linked_worktree "$dry"
"${BOX_UPDATE_ALLOW_WORKTREE:-0}" || return 1`),
`csi-spl-orc/src/bash/run/spl-cost-rollup-install-cron.func.sh` (drop unused `gd cd` at
`:36`, replace `:57-62` with `cron_refuse_linked_worktree "$dry"
"${COST_ROLLUP_ALLOW_WORKTREE:-0}" || return 1`),
`csi-spl-orc/src/bash/run/git-prune-merged-install-cron.func.sh` (drop unused `gd cd` at
`:23`, replace `:33-38` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${GIT_PRUNE_ALLOW_WORKTREE:-0}" || return 1; }`), and
`csi-spl-orc/src/bash/tests/cron-tagged-line.tst.sh` (insert section `7` before `:70`: 5
direct helper checks, 4 one-copy checks, and 3 standalone installer linked-worktree
checks). NOT `box-disk-sweep-install-cron.func.sh`, NOT
`prune-docker-images-install-cron.func.sh`, NOT `spl-agent-id-reap-install-cron.func.sh`,
NOT `spl-cost-labels-translate-install-cron.func.sh`, NOT
`spl-od-pool-supervise-install-cron.func.sh`, NOT
`spl-private-overlay-install-cron.func.sh`, NOT `spl-shadow-feed-install-cron.func.sh`,
NOT `tmp-scratch-sweep-install-cron.func.sh`, NOT `install-box-crons.func.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02 verbatim,
1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head's `cron-tagged-line.tst.sh`
on parent) RED then GREEN in the body; mutations `m2a`/`m2b`/`m2c`/`m2d` caught. Gates:
the row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x`
on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper extraction and delegation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief
if the claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the `./run`/flock cron check/dry-run/remove/install state machine and `spl_*_cron_check` across row 01's 3 wave-2 installers + host (1.3) | 4 on `f9521a941` (`spl-spawn-fill` host + `spl-spawn-place`, `spl-review-go`, `spl-topic-archive-suggest`) -> 1 (`_spl_run_cron_apply`, 7/7 wave-1..2 consolidated) after row 01 |
| copies of the linked-worktree cron guard across row 02's 3 wave-1 installers (1.4) | 3 on `f9521a941` (`spl-box-update`, `spl-cost-rollup`, `git-prune-merged`) -> 1 (`cron_refuse_linked_worktree` in `cron-tagged-line.func.sh`; fleet total 12 -> 10) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-spawn-fill-install-cron.func.sh` +7 -5, `spl-spawn-place-install-cron.func.sh` +7 -34, `spl-review-go-install-cron.func.sh` +7 -34, `spl-topic-archive-suggest-install-cron.func.sh` +7 -34, `spl-spawn-fill.tst.sh` +92 -0; row 02: `cron-tagged-line.func.sh` +16 -0, `spl-box-update-install-cron.func.sh` +2 -7, `spl-cost-rollup-install-cron.func.sh` +2 -7, `git-prune-merged-install-cron.func.sh` +2 -7, `cron-tagged-line.tst.sh` +53 -0 |
| measured on | `f9521a941`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Remaining linked-worktree cron guard callers matching `cron_refuse_linked_worktree` (waves 2-3 for `r07`+ once `r06-02` lands): `orc:src/bash/run/box-disk-sweep-install-cron.func.sh:41-46` (54 lines), `prune-docker-images-install-cron.func.sh:42-47` (52 lines), `spl-agent-id-reap-install-cron.func.sh:33-38` (43 lines), `spl-cost-labels-translate-install-cron.func.sh:76-81` (109 lines), `spl-od-pool-supervise-install-cron.func.sh:33-38` (50 lines), `spl-shadow-feed-install-cron.func.sh:33-38` (43 lines), `tmp-scratch-sweep-install-cron.func.sh:41-46` (55 lines), plus `spl-private-overlay-install-cron.func.sh:65-72` (89 lines; names `RESERVE_GH_TOKEN_FILE` — keep out if treated as credential-adjacent) and `install-box-crons.func.sh:65-70` (278 lines; does not call `cron_drop_tagged_line`) | direct `cron_refuse_linked_worktree` wave-2..3 candidates for `r07`+ once `r06-02` lands; deferred here because row 02 hits rulebook 3.1's 5-file cap | `git grep -n "is a linked worktree: install from the main checkout" f9521a941 -- csi-spl-orc/src/bash/run/` (12 hits) and `wc -l` on `f9521a941` (n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` (`brc:91-96` vs `oq:62-68`) and `*_apply` (`brc:136-161` vs `oq:111-137`) scaffolding (r04/r05 section 7) | 15 differing lines in `*_apply` (`chmod 600`, stderr handling, status predicate, log/undo headers); left out while cleaner zero-behaviour-change cron duplicates exist | r05 section 7 |
| Remaining non-matching cron installers: `orc:src/bash/run/spl-dispatch-rotate-install-cron.func.sh` (134 lines, 2-line rotate+heal), `spl-agent-boot-restore-install-cron.func.sh` (177 lines, retire/removed markers and custom install wording), `spl-box-restart-install-cron.func.sh` (117 lines, `SPL_DESK_CRON_CREATE` + slot check), `spl-peer-crons.func.sh` (273 lines, `SPL_DESK_CRON_CREATE` + no `"the "` prefix) | none matches `_spl_simple_cron_apply` or `_spl_run_cron_apply` verbatim; each needs separate inspection or a distinct helper | file reads on `f9521a941` (n=1) |
| `orc:src/bash/run/spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` (5 live probe sidecar setup/pin/detach/kill blocks) | touches 5+ files and passes `ROOT_KEY` / `MEMBER_PW_FILE` (secret-handling path; brief: secret-class sites stay out) | r05 section 7 |
| `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 vacuous red control | test-bug fix, already taken by live `b50-02` | `bug-round-50-plan.md` row 02 |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line preflight) | heavy PG R2 gate (`postgres:16-alpine` containers) | r05 section 7 |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop) | passes `-K "${cfg}/auth.curl"` (secret-class); kept out per brief | r05 section 7 |
| Candidates-file open refactor-labelled items: `_ppe_keys` exact-key in `iac:src/bash/run/check-pre-push-e2e.func.sh:121-128` (line 113), `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` saying `Lang-review: a-NNN` (line 115), and WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125) | `_ppe_keys` is gate-design input; `i18n-lang-review-exempt.json:2` is a 1-line JSON doc comment (doc/bug-shaped); WUI entry-chunk headroom is perf-shaped. Lines 1, 25, 48, 76, 104, and 133 are verified served on `f9521a941`; lines 144-145 are bug-shaped (`b50-01`) | `git show` / `git grep` on `f9521a941` (1.2 (c), n=1) |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh`, `spl-{accepted-close,desk-poll-ack,review-go}.func.sh` action bodies, `spl-hub-box-band.func.sh`, `spl-wui-perf-report.func.sh`, `csi-spl-utl/**`, `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, spec 011 deferred/owner-decision tasks, and remaining non-refactor candidates-file items | each pulls PostgreSQL or 30+ tests into R2, is secret-class, or stays out for its r05/r04 section 7 reason | 1.2 (a), (c), (d); r05 section 7 |

## 8. Changes

- v0.1 (a-942): the rows and every read on `f9521a941`; both heads built in detached
  scratch worktrees; the 21-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; all 5 red and guard
  controls (`rc1`, `gc1a`, `gc1b`, `gc1c`, `rc2`) and all 7 mutation checks (`m1a`, `m1b`,
  `m1c`, `m2a`, `m2b`, `m2c`, `m2d`) run on detached worktrees and verified RED; all
  helper, caller, and test hunks included verbatim in 1.3 and 1.4. Pushed to
  `review/c002-refactor-round-06-planner` (`9c39b5d2f`).
- v1.0 (a-942): folded cross-vendor claude panel (`c-917`, PASS on v0.1 `9c39b5d2f`,
  seat commit `bdddcc409`, msg `9319e614` / `f8f607aa`; dispatch holder `c-002` msg
  `f010f49e`) W1 and recorded N1-N3 (no row change; all 10 fenced `bash` blocks
  **byte-identical** to v0.1 `9c39b5d2f`; zero drift across all 17 row/test/host files
  from `f9521a941` to `origin/master` `551b3c601`):
  - **W1:** fixed row 02's `cron-tagged-line.tst.sh` line count in section 1.4 and
    section 6 from `70 -> 106` (`+36 -0`) to `70 -> 123` (`+53 -0`: 52 hunk lines + 1
    trailing blank line; rebuilt sha256 `57bffcc274b4` unchanged).
  - **N1:** recorded that neither row edits its test file's header comment
    (`spl-spawn-fill.tst.sh` already lacks section 11; `cron-tagged-line.tst.sh:3-11`
    lists 1-6); no row change.
  - **N2:** recorded that the panel seat did not re-run `spl-spawn-queue.tst.sh`,
    `gcloud-account-pinned.tst.sh`, `do_sec_shellcheck`, `do_check_pre_push`, or
    `gc1a`/`gc1b`/`m1a`/`m1b`/`m2b`/`m2c` (all run by the planner in 1.5 and by the
    row lanes at landing).
  - **N3:** recorded that `spl-spawn-fill.tst.sh` takes > 2 min under load; row lanes
    should not run the column in a 120 s foreground call.
  Pushed fast-forward to `review/c002-refactor-round-06-planner` (`badeda0c8`), signed by
  `c-917` (seat commit `61169615d`, msg `262c4993` / `647e2e45`, `do_spl_review_line_check`
  rc 0, 67 commands read, msg `4abb9532`, holder `c-003` GO LAND `9549a418`), and landed on
  `origin/master` at `c28e628f2`.
- closed (a-942): both rows landed on `origin/master`, cross-vendor agy R7 PASS, CI green
  (measured on `origin/master` `ae8fd2278` at `2026-11-26T13:04Z`, n=1):
  - r06-01 `8024dc0b5` (`8024dc0b596dd44970444673a3eaf3cd49a304b4`, SPL-6575, author
    `c-014` claude, committed `2026-11-26T14:06:41+02:00`): R7 `a-041` agy **PASS** on
    `fea2e748c` (`fea2e748c40196bfe8ec3ca20191418ab55921c8`; `do_spl_review_line_check`
    rc 0, `OK 16 of 16`, 18 commands read); `git patch-id --stable`
    `41d4c3a73f47164919b4f8a31e76af55c0cf00a3` equal on both, `git diff fea2e748c
    8024dc0b5 -- <5 files>` empty (C7), zero drift to `ae8fd2278`. CI on `8024dc0b5`: push
    workflows 10 (`45816723303`), 15 (`45816723516`), 25 (`45816723106`), 26
    (`45816723204`), 64 (`45816723265`), 67 (`45816723403`) **success** (plus schedule 00
    `45819324881`, 21 `45818685814` / `45820854393`, 40 `45818707981` / `45820720811`
    **success**; 9 skipped workflow 12 runs). Direct gate 10 (`45816723303`) **success**
    (R11). Diff (`git show --numstat`, exact 5 files):
    `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh` `+7 -5` (sha256 `90f45f67f8f1`),
    `orc:src/bash/run/spl-spawn-place-install-cron.func.sh` `+7 -34` (sha256
    `d80ebc168d97`), `orc:src/bash/run/spl-review-go-install-cron.func.sh` `+7 -34` (sha256
    `ed420ce5cd50`), `orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh`
    `+7 -34` (sha256 `c8474cb42cb1`), `orc:src/bash/tests/spl-spawn-fill.tst.sh` `+92 -0`
    (sha256 `32326c024963`), matching plan 1.3 head1 / section 6 verbatim.
  - r06-02 `984b6d70d` (`984b6d70d6c7f885966c2e85c3ce7a2b8eaab096`, SPL-6577, author
    `c-019` claude, committed `2026-11-26T12:59:20+02:00`): R7 `a-029` agy **PASS** on
    `4047a14a0` (`4047a14a03456cda540feeba1fac74d931af6470`; `do_spl_review_line_check`
    rc 0, `OK 14 of 14`, 14 commands read); `git patch-id --stable`
    `bfc35dfbb4a80f96d5b076d4fc35c5ef5a51e89f` equal on both, `git diff 4047a14a0
    984b6d70d -- <5 files>` empty (C7), zero drift to `ae8fd2278`. CI on `984b6d70d`: push
    workflows 10 (`45807032885`), 15 (`45807032921`), 25 (`45807032949`), 26
    (`45807032892`), 64 (`45807032758`), 67 (`45807032918`) **success** (plus schedule 00
    `45809331122`, 21 `45808594867`, 40 `45808594901` **success**; 6 skipped workflow 12
    runs). Direct gate 10 (`45807032885`) **success** (R11). Diff (`git show --numstat`,
    exact 5 files): `orc:lib/bash/funcs/cron-tagged-line.func.sh` `+16 -0` (sha256
    `393ecc8a586d`), `orc:src/bash/run/spl-box-update-install-cron.func.sh` `+2 -7` (sha256
    `072806852e51`), `orc:src/bash/run/spl-cost-rollup-install-cron.func.sh` `+2 -7`
    (sha256 `569b0052759c`), `orc:src/bash/run/git-prune-merged-install-cron.func.sh`
    `+2 -7` (sha256 `726a96dfe9ab`), `orc:src/bash/tests/cron-tagged-line.tst.sh` `+53 -0`
    (sha256 `57bffcc274b4`), matching plan 1.4 head2 / section 6 verbatim.
  - **R5, R6, 2.7.5, and post-land verification on `ae8fd2278`:** `git merge-base
    --is-ancestor <row> origin/master` rc 0 and box checkout (`ae8fd2278`) ancestry rc 0
    for both (both `csi-spl-orc` Bash only, no hub or WUI deploy required). R6 (`git log
    origin/master --since="2026-11-26T07:34:07+02:00" --format='%H %cI %s' -E
    --grep='\(r06-'`) returns both rows (`8024dc0b5`, `984b6d70d`) and the 2 plan commits
    (`c28e628f2`, `9efdca138`). Review count (2.7.5): 2 of 2 row reviews
    (`review: a-041 agy PASS`, `review: a-029 agy PASS`), both cross-vendor to their claude
    authors (`c-014`, `c-019`); no claude waiver seat was needed. Post-land `git grep` on
    `ae8fd2278`: in `csi-spl-orc/src/bash/run/`, 0
    `spl_(spawn_place|review_go|archive_suggest)_cron_check` copies remain,
    `_spl_run_cron_apply` exists once at `spl-spawn-fill-install-cron.func.sh:56` (called
    at `:47`), and all 6 wave-1..2 siblings delegate to it (`spl-security-round:53`,
    `spl-desk-poll-ack:50`, `spl-accepted-close:50`, `spl-spawn-place:48`,
    `spl-review-go:48`, `spl-topic-archive-suggest:46`), completing 7/7 consolidation;
    `cron_refuse_linked_worktree` exists once at
    `csi-spl-orc/lib/bash/funcs/cron-tagged-line.func.sh:45` (sole helper copy of the
    linked-worktree `FATAL` line at `:52`), called by wave-1 installers
    `spl-box-update-install-cron.func.sh:47`, `spl-cost-rollup-install-cron.func.sh:57`,
    and `git-prune-merged-install-cron.func.sh:33`, leaving 9 deferred callers in
    `csi-spl-orc/src/bash/run/` (10 copies total across `run/` + `lib/`, down from 12).
  - **Round close & teardown:** orchestrator GC (`c-001`, msg `3ce590c8`) confirmed both
    rows landed on `origin/master` and requested the close record with `Closes: SPL-6566`.
    `do_spl_lane_map --all` at `13:03Z` shows only editor `a-942` still live for r06
    (`c-917`, `c-014`, `c-019`, `a-041`, `a-029` already gone). Remote branches remaining
    on `origin` for R8 prune (`PRUNE_SINCE=2026-11-26T07:34:07+02:00`):
    `review/c002-refactor-round-06-claude-seat` (`61169615d`); `review/r06-01`,
    `review/r06-02`, and `review/c002-refactor-round-06-planner` are already pruned.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-942 (agy): v0.1 (`9c39b5d2f`), v1.0 (`badeda0c8`, landed `c28e628f2`),
  close record.
- Panel reviewer seat: c-917 (claude, seat `61169615d6cde9bc20cc83d57ff211f6e6ae8eab` on
  `review/c002-refactor-round-06-claude-seat`):
  - v0.1 `9c39b5d2f76b8d19b60024754bcc59908c90b5e4`: **PASS** (seat commit `bdddcc409`,
    msg `9319e614` / `f8f607aa`; W1 and N1-N3 folded in v1.0).
  - v1.0 `badeda0c8175aa02bea32df5f5a92baa9655b5b5`: **PASS** (seat commit
    `61169615d6cde9bc20cc83d57ff211f6e6ae8eab`, msg `262c4993` / `647e2e45`;
    `do_spl_review_line_check` rc 0, 67 commands read, msg `4abb9532`; holder `c-003` GO
    LAND `9549a418`; 10/10 fenced `bash` blocks byte-identical, zero open W).
- Row R7 seats: section 4; both agy: a-041 (r06-01), a-029 (r06-02) (section 8, round
  closed).
