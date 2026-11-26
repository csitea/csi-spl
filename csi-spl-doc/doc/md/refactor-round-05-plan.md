# Refactoring round 05 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6553  
Topic: b2a0d417-80fa-41b7-8cde-391106ecc2f7  
Discussion: b2a0d417-80fa-41b7-8cde-391106ecc2f7 (t1 #refactoring, "Refactor round 05", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r05**, plan `refactor-round-05-plan.md` (free: only `refactor-round-5-plan.md` exists,
  so no date suffix), rows `r05-<NN>`, scope `docs(r05-plan, SPL-6553)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row** (`LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 03:09Z:
  `pick=claude`, `main=claude`, `backup=agy`).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 04 ([refactor-round-04-plan.md](refactor-round-04-plan.md)
v1.0 `ea644d377`, editor `a-852`) has both rows on `origin/master`: `r04-01`
(`fc50062f3`, SPL-6551, agy R7 `a-882` PASS) and `r04-02` (`b42d34d7b`, SPL-6552, agy R7
`a-886` PASS); nothing of r04 remains to queue (`a-852` writes r04's close record).
The perf floor (rulebook 4.4), measured on `b42d34d7b` at 2026-11-26T03:08:53Z (14 days):
perf 36, refactor 113, 24.2%, 5 x 36 = 180 >= 149, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), continuing directly from
r02-02 (`8ff47fd73`), r03-02 (`0fcaa450b`), and r04-02 (`b42d34d7b`): duplicated
`orc:src/bash/run/` single-line cron installer scaffolding delegates to one shared helper
in a sibling file, leaving every log line, exit code, env var, and path byte-identical.
**Row 01:** the final single-line script cron installer matching `_spl_simple_cron_apply`
— `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh:54-88` (r04 section 7 #2) —
carries the exact 35-line `check` / `DRY_RUN=1` / `remove` / `install` crontab state
machine hosted in `_spl_simple_cron_apply` (`setup-box-stats-cron.func.sh:64-107`, def at
`:68-107`, which already accepts optional 11th arg `noun=""` after `r04-02` `b42d34d7b`). Lazy-sourcing
`setup-box-stats-cron.func.sh` behind a `declare -F _spl_simple_cron_apply` guard inside
`do_spl_orch_rotate_install_cron` and passing `""` as arg 11 completes the
`_spl_simple_cron_apply` wave-1..4 consolidation (all 10 matching script cron installers
sharing 1 copy) without touching `setup-box-stats-cron.func.sh` or `box-stats-cron.tst.sh`.
**Row 02:** four `./run`-based `flock` cron installers in `orc:src/bash/run/` —
`spl-spawn-fill-install-cron.func.sh:47-78`,
`spl-security-round-install-cron.func.sh:51-82`,
`spl-desk-poll-ack-install-cron.func.sh:48-81`, and
`spl-accepted-close-install-cron.func.sh:48-81` — carry the exact same 32-34 line
`check` (`spl_*_cron_check`) / `DRY_RUN=1` / `remove` / `install` crontab state machine
(differing only in job label, install OK message, and check-missing reason). Extracting
`_spl_run_cron_apply` into `spl-spawn-fill-install-cron.func.sh` lets all four installers
drop their duplicated `spl_*_cron_check` functions and state machines, with the three
wave-1 siblings lazy-sourcing `spl-spawn-fill-install-cron.func.sh` behind a
`declare -F _spl_run_cron_apply` guard (leaving `spl-spawn-place-install-cron`,
`spl-review-go-install-cron`, and `spl-topic-archive-suggest-install-cron` in section 7
for `r06`+ so row 02 stays within rulebook 3.1's 5-file cap and off live `b48-01`).
The rows share no file: both are batch 1.

**Status: v1.0 signed (ready for batch-1 row placement).** Editor: **a-891** (agy).
Cross-vendor claude panel seat **c-893** signed v1.0
(`78812b3d75ee018ce4497ad5d82af3ac37d39cd8`, seat commit `81022372b`, msg `45e1ab76` /
`aec30545`; `do_spl_review_line_check` rc 0, `DOCS-ONLY`, dispatch holder GO LAND
`16edd42c`). Zero drift on all 13 row/test/host files from `b42d34d7b` to `origin/master`
`5dbcaec84`.

**One sha:** every count is measured on **`b42d34d7b`** (`b42d34d7b9e57704a26e1fde93ebb65e2813389f`,
`origin/master` at 2026-11-26T03:08:53Z), n=1 per command unless stated. Reads are on
`b42d34d7b` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of `b42d34d7b` (not committed, removed on exit): "base" unmodified, "head1" =
base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape; each red control, guard control, and mutation check (1.5) ran in a detached
worktree of its own. All helper definitions, caller replacements, and test hunks are
reproduced verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2,
all 6 red/guard controls, and all 5 mutation checks byte-for-byte on `b42d34d7b` and
verify every sha256. Queue, lane map, brief and branch reads are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-26T03:08:53Z, n=1, after a fresh fetch (`git-fetch-fresh.sh --force`):

- **Window: W=2026-11-26T04:08:14+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r04-plan'`:
  `ea644d37747fd070b9a244fb0bde46a17f3ef755`
  (`docs(r04-plan, SPL-6547): refactor round 04 plan v1.0, signed by c-804 (claude) PASS on 31060f1b8`),
  read once at the start as 5.3 says (`a-852` had not yet landed round 04's close record
  as of 03:33Z, re-checked on `0d5e0b252`). Per rulebook 5.3, `W` stays fixed at this
  recorded date (`2026-11-26T04:08:14+02:00`, commit `ea644d377`); all later R4, R6,
  2.7.5, and `PRUNE_SINCE` reads for r05 must use `W=2026-11-26T04:08:14+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r05-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r05-*' 'refs/heads/*-r05-*' 'refs/heads/*refactor-round-05*' 'refs/heads/wip/*r05*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r05-[0-9]{2}|refactor-round-05'` (local to
  this planner/holder box only, not on the panel seat's box) -> **2** briefs only: this
  planner's brief (`hand-sat-c002-refactor-round-05-planner.md`) and the panel seat's
  brief (`c002-refactor-round-05-claude-panel-seat.md`); 0 `r05-NN` row briefs.
- `git ls-tree --name-only b42d34d7b csi-spl-doc/doc/md/ | grep -c refactor-round-05`
  -> **0** (only `refactor-round-5-plan.md` exists, so `refactor-round-05-plan.md` is free
  with no date suffix per rulebook 5.3).

### 1.2 The brief's inputs, re-measured

- **(a) r04 section 7:** re-read on `b42d34d7b`:
  - `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh` (89 lines): listed in r04
    section 7 #2 as the direct `_spl_simple_cron_apply` wave-4 candidate with `noun=""`
    once `r04-02` lands (`b42d34d7b` is now on `origin/master`). Verified 100% match to
    `_spl_simple_cron_apply` -> measured here as **row 01** (1.3).
  - Remaining `./run`-based `flock` cron installers (`spl-spawn-fill-install-cron`,
    `spl-security-round-install-cron`, `spl-desk-poll-ack-install-cron`,
    `spl-accepted-close-install-cron`, `spl-spawn-place-install-cron`,
    `spl-review-go-install-cron`, `spl-topic-archive-suggest-install-cron`): surfaced by
    `git grep -n "the crontab does not read back what was written" b42d34d7b -- csi-spl-orc/src/bash/run/`.
    The four cleanest non-live-lane matches (`spl-spawn-fill`, `spl-security-round`,
    `spl-desk-poll-ack`, `spl-accepted-close`) share an identical 32-34 line
    `check`/`DRY_RUN=1`/`remove`/`install` state machine with pure-bash unit tests ->
    measured here as **row 02** (1.4); `spl-spawn-place-install-cron` (2,673-line test),
    `spl-review-go-install-cron` (live `b48-01` touches `spl-review-go.tst.sh`), and
    `spl-topic-archive-suggest-install-cron` (`-r` vs `-x` check) stay in section 7 for
    `r06`+.
  - `orc:src/bash/run/spl-dispatch-rotate-install-cron.func.sh` (134 lines, 2-line
    rotate+heal installer), `spl-agent-boot-restore-install-cron.func.sh` (177 lines,
    retire/removed marker branches and custom install wording),
    `spl-box-restart-install-cron.func.sh` (117 lines, `SPL_DESK_CRON_CREATE` + slot
    check), and `spl-peer-crons.func.sh` (273 lines, `SPL_DESK_CRON_CREATE` + no `"the "`
    prefix) do not match `_spl_simple_cron_apply` or `_spl_run_cron_apply` verbatim and
    stay in section 7.
  - All other r04 section 7 items (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91`
    test-bug, `spl-msg-{dedup,wipe}` PG-heavy, 5 probe actions handling `ROOT_KEY` /
    `MEMBER_PW_FILE`, secret-class `gcp-*alert*`, PG-coupled `spl-channel-agent-*` and
    `spl-{accepted-close,desk-poll-ack,review-go}` action bodies) remain accounted for in
    section 7.
- **(b) R7 notes of r04-01 / r04-02 and r04 W2 (`brc`/`oq` `*_read` and `*_apply`):**
  - `r04-01` (`fc50062f3`, SPL-6551, R7 `a-882` PASS on `883a8daa0`): clean match to r04
    1.3 head1 verbatim, no refactor follow-up.
  - `r04-02` (`b42d34d7b`, SPL-6552, R7 `a-886` PASS on `5caa105c8`): clean match to r04
    1.4 head2 verbatim; its N1 was a brief path note, not a code finding.
  - r04 W2 (`brc`/`oq` `*_read` and `*_apply`, re-measured on `b42d34d7b`):
    - `spl_issue_brc_read` (`brc:91-96`, 6 lines) vs `spl_issue_oq_read` (`oq:62-68`, 7
      lines): `oq` inserts `do_spl_cloud_cnf || return 1` between `spl_db_require_bins`
      and `spl_db_query_rc`, while `brc` calls `do_spl_cloud_cnf` before `plan_path`
      (relied on by both test suites' stubs); extracting a 4-line wrapper adds indirection
      for ~3 lines saved.
    - `spl_issue_brc_apply` (`brc:136-161`, 26 lines) vs `spl_issue_oq_apply`
      (`oq:111-137`, 27 lines): `diff -u` -> 15 differing lines (`brc` runs `chmod 600`
      on undo, redirects get stderr `2>/dev/null` with `|| now=""`, and checks
      `[[ "$now" != "$status" ]]`; `oq` merges get stderr `2>&1` and checks
      `[[ "$now" == "done" || "$now" == "diss" ]]`, with distinct log and undo header
      strings). Unifying them requires a status-predicate callback or mode flag and
      either alters `oq`'s undo chmod/stderr handling or carries branching. Left out and
      accounted for in section 7 while cleaner zero-behaviour-change cron duplicates
      exist.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to this planner/holder
  box only and not on the panel seat's box; 142 lines, 31,775 bytes, read 03:08Z):
  - Unchanged since r04 (`wc -l` 142, last section is b48 `spl-review-go.func.sh`
    false-hold, bug-shaped).
  - Re-checked all 9 refactor-labelled entries on `b42d34d7b` (6 served, 3 open out of
    scope):
    - line 1 (`spl-watchdog.func.sh:72,:1323`, `spl-lane-rotate.func.sh` literal `/var`
      paths) -> 0 `/var/csi` literals; `spl-watchdog.func.sh` uses
      `spl_claude_login_state_dir` (`<SPL_VAR_APP_DIR>/agent-login-check`) (served).
    - line 25 (`reverse-tunnel-cron.sh:27`) -> already uses
      `$SPL_VAR_APP_DIR/reverse-tunnel` (served).
    - line 48 (`agent-boot-restore` dir in `spl-watchdog.func.sh:541` and
      `spl-agent-boot-restore-install-cron.func.sh:60`) -> both sides call
      `spl_var_app_subdir ... agent-boot-restore` (served).
    - line 76 (`spl-desk-reply.sh:9` usage kinds) -> already lists all 12 kinds
      `note|result|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs` (served).
    - line 104 (`spl-lane-mix.func.sh` `needs_agy_review` / `agy has the final word`) ->
      0 hits in `csi-spl-orc/` (served).
    - line 133 (`spl-unanswered-sweep.func.sh:196` `send_to_peers_on`) -> 0 hits in
      `spl-unanswered-sweep.func.sh` (served).
    - line 113 (`_ppe_keys` exact-key matching in
      `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh:121-128`) -> open; gate-design
      input (prefix matching adds +9 to every menu test; not a narrow refactor row).
    - line 115 (`csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` still names
      `'Lang-review: a-NNN <msg id>'` while the gate requires `gct`) -> open; 1-line JSON
      doc comment (doc/bug-shaped, not a coding refactor row).
    - line 125 (WUI entry-chunk headroom, `ci_initial_gzip_kb` ceiling 155 KB) -> open;
      perf-shaped (belongs in a perf round, not a refactor round).
  - All other items are bug, perf, doc, test-hardening, or other-repo items, accounted for
    in section 7.
- **(d) spec 011 tasks:**
  `git log ffba81845..b42d34d7b --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r04's base; remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `spl-orch-rotate-install-cron.func.sh` delegates to `_spl_simple_cron_apply` (wave 4, completing 10/10 single-line script cron installers)

`orc:` = `csi-spl-orc/`. On `b42d34d7b`:

- `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh:54-88` (35 lines) carries the
  exact `current="$(spl_desk_cron_line "$tag")"` + `check` / `DRY_RUN=1` / `remove` /
  `install` crontab state machine hosted in `_spl_simple_cron_apply`
  (`orc:src/bash/run/setup-box-stats-cron.func.sh:64-107`, def at `:68-107`, which already
  supports optional 11th arg `noun="${11- cron}"` after `r04-02` `b42d34d7b`): `diff -u` of
  `spl-orch-rotate-install-cron.func.sh:54-88` against
  `setup-box-stats-cron.func.sh:71-105` -> 10 diff lines (the 4 log lines using `"$subj"`
  plus `local subj` and trailing `spl_desk_cron_say`, n=1).
- Passing `"orchestrator rotation"` as arg 8, `"runs hourly at :$(printf '%02d' "$min") as the box user"`
  as arg 9, `": the orchestrator session is never renewed"` as arg 10, and `""` as arg 11
  (`noun`) produces byte-identical output across `check`, `DRY_RUN=1`, `remove`, and
  `install` with **zero edits** to `setup-box-stats-cron.func.sh` or
  `box-stats-cron.tst.sh`.
- Lazy-sourcing `setup-box-stats-cron.func.sh` behind a `declare -F _spl_simple_cron_apply`
  guard inside `do_spl_orch_rotate_install_cron` adds zero top-level lines (the sourced
  file's own top-level guards are already `declare -F`-protected, same as r04-02; panel
  N7), keeps `run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged, and
  preserves `tag="$SPL_ORG_APP:orch-rotate"` at `:41` (checked directly by
  `iac:src/bash/tests/satellite-ansible.tst.sh:372`). Note (N6): `$(printf '%02d' "$min")`
  is now evaluated before `_spl_simple_cron_apply` on every action rather than only on
  `install`; output and exit codes are identical. The file handles no token, credential,
  or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `do_spl_orch_rotate_install_cron`
  59 -> 29 lines. Neither edited file has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh`: drop unused `current` from
  `local` at `:40`; replace `:54-88` (keeping closing `}` at `:89`) with lazy-source +
  `_spl_simple_cron_apply` passing `"orchestrator rotation"`,
  `"runs hourly at :$(printf '%02d' "$min") as the box user"`,
  `": the orchestrator session is never renewed"`, `""`. 89 -> 59 lines (`+6 -36`).
- `orc:src/bash/tests/orch-rotate.tst.sh`: insert section `10c` immediately before
  `# --- 13. spec 061 L6:` at `:948` (followed by one blank line): 1 one-copy check,
  1 hermetic (`env -u`) standalone lazy-load `check`-missing check asserting exact
  `miss_why` and no `"orchestrator rotation cron"`, and 1 hermetic standalone `DRY_RUN=0`
  lifecycle check (`install`, `check`, `remove`) asserting all three exact OK lines and
  no `"orchestrator rotation cron"`. 1,255 -> 1,286 lines (`+31 -0`). Total edited files:
  **2**.
- head1's files, sha256 (12 chars): `spl-orch-rotate-install-cron.func.sh` `ca7ee0ca64b6`,
  `orch-rotate.tst.sh` `f6f6d04202b0`.
- Note for the row and its reviewer: build `gc1`, `m1a`, and `m1b` in detached git
  worktrees, not single-file temp copies, because the lazy-source guard loads its sibling
  via `dirname "${BASH_SOURCE[0]}"`.

Verbatim caller and test hunks (head1 on `b42d34d7b`):

`orc:src/bash/run/spl-orch-rotate-install-cron.func.sh` (replaces `:54-88`, keeping
closing `}` at `:89`; also remove `current` from `local` at `:40`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "orchestrator rotation" "runs hourly at :$(printf '%02d' "$min") as the box user" \
    ": the orchestrator session is never renewed" ""
```

`orc:src/bash/tests/orch-rotate.tst.sh` section `10c` (inserted immediately before
`# --- 13. spec 061 L6:` at `:948`, followed by one blank line):
```bash
# --- 10c. r05-01 one copy and standalone lazy-source (delegates to _spl_simple_cron_apply) ---
or_f="$PROJ_ROOT/src/bash/run/spl-orch-rotate-install-cron.func.sh"
or_own="$(grep -nE "the crontab does not read back what was written|is installed and its script is executable|OK DRY_RUN nothing was touched" "$or_f" || true)"
[[ -z "$or_own" ]] && grep -q "_spl_simple_cron_apply " "$or_f" &&
  pass "10c. r05-01 one copy: spl-orch-rotate-install-cron.func.sh delegates apply to _spl_simple_cron_apply" ||
  fail "10c. r05-01 one copy: own=[$or_own]"
printf '%s\n' '*/3 * * * * other job # csi-spl:desk-reconcile' >"$T/crontab.10c"
out="$(env -u CRON_REMOVE -u ROTATE_CRON_ACTION -u ROTATE_CRON_MINUTE PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.10c" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ROTATE_CRON_LOG_DIR="$T/log-10c" ROTATE_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-orch-rotate-install-cron.func.sh"
  do_spl_orch_rotate_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the orchestrator rotation is NOT installed (no line tagged csi-spl:orch-rotate): the orchestrator session is never renewed"* && "$out" != *"orchestrator rotation cron"* && "$out" != *"command not found"* ]] &&
  pass "10c. r05-01 lazy load: spl-orch-rotate-install-cron.func.sh loads _spl_simple_cron_apply standalone" ||
  fail "10c. r05-01 lazy load (rc=$rc): $out"
out="$(env -u CRON_REMOVE -u ROTATE_CRON_ACTION -u ROTATE_CRON_MINUTE PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.10c" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ROTATE_CRON_LOG_DIR="$T/log-10c" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-orch-rotate-install-cron.func.sh"
  do_spl_orch_rotate_install_cron; echo "rc1=$?"
  ROTATE_CRON_ACTION=check do_spl_orch_rotate_install_cron; echo "rc2=$?"
  ROTATE_CRON_ACTION=remove do_spl_orch_rotate_install_cron; echo "rc3=$?"' 2>&1)"
[[ "$out" == *"OK the orchestrator rotation runs hourly at :05 as the box user:"* && "$out" == *"rc1=0"* \
  && "$out" == *"OK the orchestrator rotation is installed and its script is executable"* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the orchestrator rotation is out of the crontab"* && "$out" == *"rc3=0"* \
  && "$out" != *"orchestrator rotation cron"* ]] &&
  pass "10c. r05-01 lifecycle: install, check and remove keep exact messages without ' cron'" ||
  fail "10c. r05-01 lifecycle: $out"
```

**Behaviour:** zero behaviour change. Every log line, exit code, crontab line, and path
is byte-identical (both standalone checks `10c. r05-01 lazy load` and `10c. r05-01
lifecycle` pass on unmodified `base` too). All row-01 and shared suites pass on base and
head1 with identical counts plus the 3 new checks in `orch-rotate.tst.sh` (1.5).

### 1.4 Row 02's site: `_spl_run_cron_apply` helper and wave-1 delegation for `spl-spawn-fill-install-cron`, `spl-security-round-install-cron`, `spl-desk-poll-ack-install-cron`, and `spl-accepted-close-install-cron`

`orc:` = `csi-spl-orc/`. On `b42d34d7b`:

- Four `./run`-based `flock` crontab installers duplicate the exact same 32-34 line
  `check` (`spl_*_cron_check`) / `DRY_RUN=1` / `remove` / `install` state machine:
  1. `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh:47-78` (32 lines)
  2. `orc:src/bash/run/spl-security-round-install-cron.func.sh:51-82` (32 lines; `diff -u`
     vs `spl-spawn-fill:47-78` -> 12 diff lines: 4 log lines + `spl_*_cron_check` name, n=1)
  3. `orc:src/bash/run/spl-desk-poll-ack-install-cron.func.sh:48-81` (34 lines; `diff -u`
     vs `spl-spawn-fill:47-78` -> 14 diff lines: 4 log lines + `spl_*_cron_check` name +
     `if ...; then ... fi` vs `&& { ...; }` formatting, n=1)
  4. `orc:src/bash/run/spl-accepted-close-install-cron.func.sh:48-81` (34 lines; `diff -u`
     vs `spl-spawn-fill:47-78` -> 14 diff lines: identical shape to `desk-poll-ack`, n=1)
- `_spl_run_cron_apply` has **0 collisions** anywhere in the repo
  (`git grep -nE '_spl_run_cron_apply' b42d34d7b` -> 0). None of the four per-file check
  helpers (`spl_spawn_fill_cron_check`, `spl_security_round_cron_check`,
  `spl_poll_ack_cron_check`, `spl_accepted_close_cron_check`) has any caller or test
  reference outside its own file (`git grep -nE` -> 2 hits each: definition + single call
  in the same `.func.sh` file, n=1).
- Hosting `_spl_run_cron_apply` in `spl-spawn-fill-install-cron.func.sh` (which already
  guards its only top-level source with `declare -F spl_desk_cron_checkout`) lets all four
  installers drop their duplicated `spl_*_cron_check` functions and state machines; the
  three wave-1 siblings lazy-source `spl-spawn-fill-install-cron.func.sh` behind a
  `declare -F _spl_run_cron_apply` guard inside their action function, adding zero
  top-level lines, keeping `run-lazy-loader.tst.sh` and `run-eager-files.tst.sh`
  unchanged, and working when sourced standalone (with `spl-desk-install-service.func.sh`,
  which defines `spl_desk_cron_src`). None of the four `.func.sh` files handles any token,
  credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_spl_spawn_fill_install_cron` 40 -> 24 lines; `_spl_run_cron_apply` is 34 lines;
  `do_spl_security_round_install_cron` 39 -> 25 lines;
  `do_spl_desk_poll_ack_install_cron` 42 -> 26 lines;
  `do_spl_accepted_close_install_cron` 42 -> 26 lines; all four 10-line
  `spl_*_cron_check` functions deleted. None of the 5 edited files has any entry in
  `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh`: drop unused `current` from
  `local` at `:30`; replace `:47-78` with `_spl_run_cron_apply` call + helper definition
  (dropping `spl_spawn_fill_cron_check`). 78 -> 89 lines (`+26 -15`).
- `orc:src/bash/run/spl-security-round-install-cron.func.sh`: drop unused `current` from
  `local` at `:35`; replace `:51-82` (dropping `spl_security_round_cron_check`) with
  lazy-source + `_spl_run_cron_apply`. 82 -> 57 lines (`+7 -32`).
- `orc:src/bash/run/spl-desk-poll-ack-install-cron.func.sh`: drop unused `current` from
  `local` at `:31`; replace `:48-81` (dropping `spl_poll_ack_cron_check`) with lazy-source
  + `_spl_run_cron_apply`. 81 -> 54 lines (`+7 -34`).
- `orc:src/bash/run/spl-accepted-close-install-cron.func.sh`: drop unused `current` from
  `local` at `:31`; replace `:48-81` (dropping `spl_accepted_close_cron_check`) with
  lazy-source + `_spl_run_cron_apply`. 81 -> 54 lines (`+7 -34`).
- `orc:src/bash/tests/spl-spawn-fill.tst.sh`: insert section `11` immediately before
  `echo` / `(( fails == 0 ))` at `:387` (line `:386` is already blank, so adding section
  `11` followed by one blank line leaves exactly one blank line before and after):
  1 direct `_spl_run_cron_apply` lifecycle check (check-missing, dry-run, install,
  check-ok, check-bad-run, remove; note N5: block 1 inherits caller env — unset in normal
  runs; `env -u SPL_DESK_CRON_CREATE` is optional if a caller sets it), 4 one-copy checks
  (host + 3 wave-1 installers), and 6 hermetic (`env -u`) standalone lazy-load checks (3
  `check`-missing + 3 `DRY_RUN=0` install `ok_msg` checks) against an isolated stub
  crontab `$T/crontab.s11`. 390 -> 485 lines (`+95 -0`). Total edited files: **5** (within
  rulebook 3.1's max 5; the other three wave-1 test suites run unmodified in the test
  column). Note (N6): `$(id -un)` in `desk-poll-ack` and `accepted-close` is now evaluated
  before `_spl_run_cron_apply` on every action rather than only on `install`; output and
  exit codes are identical.
- head2's files, sha256 (12 chars): `spl-spawn-fill-install-cron.func.sh` `c71f5c44e8d4`,
  `spl-security-round-install-cron.func.sh` `727e2cc53868`,
  `spl-desk-poll-ack-install-cron.func.sh` `76f014422c8c`,
  `spl-accepted-close-install-cron.func.sh` `3510782ee880`,
  `spl-spawn-fill.tst.sh` `1b29f5d84f85`.
- Note for the row and its reviewer: build `gc2a`-`gc2c` and `m2a`-`m2c` in detached git
  worktrees, not single-file temp copies, because the lazy-source guard loads its sibling
  via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper, caller, and test hunks (head2 on `b42d34d7b`):

`orc:src/bash/run/spl-spawn-fill-install-cron.func.sh` (replaces `:47-78`; also remove
`current` from `local` at `:30`):
```bash
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "idle filler" \
    "runs every $min min as the box user (it queues only on the orch holder's machine, while its switch is on)" \
    ": spare capacity is not filled from issues"
}

# _spl_run_cron_apply <act> <tag> <src> <trunk> <run> <logdir> <line> <label>
#   <ok_msg> [miss_why] -> run check, dry-run, remove, or install for a
#   single-line tagged ./run crontab action.
_spl_run_cron_apply() {
  local act="$1" tag="$2" src="$3" trunk="$4" run="$5" logdir="$6" line="$7"
  local label="$8" ok_msg="$9" miss_why="${10:-}" current
  current="$(spl_desk_cron_line "$tag")"
  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the $label is NOT installed (no line tagged $tag)$miss_why"
      return 1
    fi
    spl_desk_cron_say "$current"
    [[ -x "$run" ]] || { do_log "FAIL $run is gone or not executable"; return 1; }
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
  [[ -x "$run" ]] || { do_log "FATAL $run is missing or not executable in $src"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the $label $ok_msg:"
  spl_desk_cron_say "$line"
}
```

`orc:src/bash/run/spl-security-round-install-cron.func.sh` (replaces `:51-82`; also
remove `current` from `local` at `:35`):
```bash
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "weekly security round" \
    "runs Friday at :30 in the night phase (UTC Friday, do_spl_rhythm_phase night) as the box user (it queues only on the orch holder's machine, while its switch is on)" \
    ": Friday's round is not queued"
}
```

`orc:src/bash/run/spl-desk-poll-ack-install-cron.func.sh` (replaces `:48-81`; also
remove `current` from `local` at `:31`):
```bash
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "poll acknowledgement" \
    "runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease)" \
    ": an owner poll answer waits for a model to notice it"
}
```

`orc:src/bash/run/spl-accepted-close-install-cron.func.sh` (replaces `:48-81`; also
remove `current` from `local` at `:31`):
```bash
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "accepted close" \
    "runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease)" \
    ": a landed, reviewed lane waits for a model to send its ACCEPTED"
}
```

`orc:src/bash/tests/spl-spawn-fill.tst.sh` section `11` (inserted immediately before
`echo` / `(( fails == 0 ))` at `:387`, followed by one blank line; `:386` is already blank):
```bash
# --- 11. _spl_run_cron_apply and wave-1 delegation (r05-02 one copy) --------------
printf '%s\n' '# keep me' >"$T/crontab.s11"
cp "$T/crontab.s11" "$T/crontab.s11.orig"
out="$(env PROJ_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SRC="$SRC" T="$T" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply check "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc1=$?"
  DRY_RUN=1 _spl_run_cron_apply install "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc2=$?"
  _spl_run_cron_apply install "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc3=$?"
  _spl_run_cron_apply check "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc4=$?"
  _spl_run_cron_apply check "csi-spl:widget" "$SRC" master "$T/no-such-run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc5=$?"
  _spl_run_cron_apply remove "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc6=$?"' 2>&1)"
[[ "$out" == *"FAIL the widget is NOT installed (no line tagged csi-spl:widget): no widget"* && "$out" == *"rc1=1"* \
  && "$out" == *"OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the widget runs every 1m:"* && "$out" == *"rc3=0"* \
  && "$out" == *"OK the widget is installed"* && "$out" == *"rc4=0"* \
  && "$out" == *"FAIL $T/no-such-run is gone or not executable"* && "$out" == *"rc5=1"* \
  && "$out" == *"OK the widget is out of the crontab"* && "$out" == *"rc6=0"* ]] &&
  cmp -s "$T/crontab.s11" "$T/crontab.s11.orig" &&
  pass "11. _spl_run_cron_apply covers check-missing, dry-run, install, check-ok, check-bad-run and remove" || fail "11. helper lifecycle: $out"

sf_f="$PROJ_ROOT/src/bash/run/spl-spawn-fill-install-cron.func.sh"
sr_f="$PROJ_ROOT/src/bash/run/spl-security-round-install-cron.func.sh"
pa_f="$PROJ_ROOT/src/bash/run/spl-desk-poll-ack-install-cron.func.sh"
ac_f="$PROJ_ROOT/src/bash/run/spl-accepted-close-install-cron.func.sh"
sf_old="$(grep -n 'spl_spawn_fill_cron_check' "$sf_f" || true)"
[[ -z "$sf_old" && "$(grep -c 'the crontab does not read back what was written' "$sf_f")" -eq 1 && "$(grep -c '_spl_run_cron_apply ' "$sf_f")" -ge 1 ]] &&
  pass "11. one copy: spl-spawn-fill-install-cron.func.sh hosts the single _spl_run_cron_apply helper" || fail "11. host one copy: old=[$sf_old]"
for sib in "$sr_f" "$pa_f" "$ac_f"; do
  own="$(grep -nE "spl_(security_round|poll_ack|accepted_close)_cron_check|the crontab does not read back what was written|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_run_cron_apply " "$sib" &&
    pass "11. one copy: $(basename "$sib") delegates apply to _spl_run_cron_apply" || fail "11. one copy $(basename "$sib"): own=[$own]"
done

out="$(env -u SECURITY_ROUND_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SECURITY_ROUND_CRON_LOG_DIR="$T/log-sr" SECURITY_ROUND_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-security-round-install-cron.func.sh"
  do_spl_security_round_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the weekly security round is NOT installed (no line tagged csi-spl:security-round): Friday's round is not queued"* && "$out" != *"command not found"* ]] &&
  pass "11. lazy load: spl-security-round-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "11. lazy sr (rc=$rc): $out"

out="$(env -u SECURITY_ROUND_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SECURITY_ROUND_CRON_LOG_DIR="$T/log-sr" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-security-round-install-cron.func.sh"
  do_spl_security_round_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the weekly security round runs Friday at :30 in the night phase (UTC Friday, do_spl_rhythm_phase night) as the box user (it queues only on the orch holder's machine, while its switch is on):"* ]] &&
  pass "11. security-round install keeps exact ok_msg" || fail "11. sr ok (rc=$rc): $out"

out="$(env -u POLL_ACK_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" POLL_ACK_CRON_LOG_DIR="$T/log-pa" POLL_ACK_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-desk-poll-ack-install-cron.func.sh"
  do_spl_desk_poll_ack_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the poll acknowledgement is NOT installed (no line tagged csi-spl:poll-ack): an owner poll answer waits for a model to notice it"* && "$out" != *"command not found"* ]] &&
  pass "11. lazy load: spl-desk-poll-ack-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "11. lazy pa (rc=$rc): $out"

out="$(env -u POLL_ACK_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" POLL_ACK_CRON_LOG_DIR="$T/log-pa" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-desk-poll-ack-install-cron.func.sh"
  do_spl_desk_poll_ack_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the poll acknowledgement runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"* ]] &&
  pass "11. poll-ack install keeps exact ok_msg" || fail "11. pa ok (rc=$rc): $out"

out="$(env -u ACCEPT_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ACCEPT_CRON_LOG_DIR="$T/log-ac" ACCEPT_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-accepted-close-install-cron.func.sh"
  do_spl_accepted_close_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the accepted close is NOT installed (no line tagged csi-spl:accepted-close): a landed, reviewed lane waits for a model to send its ACCEPTED"* && "$out" != *"command not found"* ]] &&
  pass "11. lazy load: spl-accepted-close-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "11. lazy ac (rc=$rc): $out"

out="$(env -u ACCEPT_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ACCEPT_CRON_LOG_DIR="$T/log-ac" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-accepted-close-install-cron.func.sh"
  do_spl_accepted_close_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the accepted close runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"* ]] &&
  pass "11. accepted-close install keeps exact ok_msg" || fail "11. ac ok (rc=$rc): $out"
```

**Behaviour:** zero behaviour change. All four installers emit their exact check-missing,
check-ok, dry-run, remove, and install log lines and exit codes (all 6 standalone
lazy-load and install `ok_msg` checks pass on unmodified `base` too). All row-02 and
shared suites pass on base and head2 with identical counts plus the 11 new checks in
`spl-spawn-fill.tst.sh` (1.5).

### 1.5 Before and on the rows' heads

2026-11-26T03:25:18Z-03:32:52Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal
to base: same rc, pass and fail counts; "-" means that row's head does not touch the
suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/orch-rotate.tst.sh` | 01 | 0 / 196 / 0 | 0 / 199 / 0 (+3 new checks) | - |
| `iac:src/bash/tests/satellite-ansible.tst.sh` | 01 | 0 / 96 / 0 | = | - |
| `orc:src/bash/tests/box-stats-cron.tst.sh` | 01 | 0 / 54 / 0 | = | - |
| `orc:src/bash/tests/spl-spawn-fill.tst.sh` | 02 | 0 / 44\* / 0 | - | 0 / 55\* / 0 (+11 new checks) |
| `orc:src/bash/tests/spl-security-round-queue.tst.sh` | 02 | 0 / 33\* / 0 | - | = |
| `orc:src/bash/tests/spl-desk-poll-ack.tst.sh` | 02 | 0 / 37 / 0 | - | = |
| `orc:src/bash/tests/spl-accepted-close.tst.sh` | 02 | 0 / 32 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note (\*): `spl-spawn-fill.tst.sh` and `spl-security-round-queue.tst.sh` print a trailing
`PASS: all` line on success (counted by `grep -ciE '^ *(ok|pass)'`: `spl-spawn-fill` base
= 43 `PASS:` + 1 `PASS: all`, head2 = 54 `PASS:` + 1 `PASS: all`) and a trailing
`FAIL: <N>` line on failure (counted by `grep -ciE '^ *(not ok|fail)'`, documented per
control below). On `m1a`, multi-line `$out` dumped inside `fail "10c. r05-01 lifecycle"`
includes 2 `OK ...` log lines on their own lines, which `grep -ciE '^ *(ok|pass)'` also
counts (197 real `PASS:` + 2 `OK` lines = 199). Run every suite and control in a git
worktree (not a plain `git archive` export): outside a git tree, `no-literal-paths.tst.sh`
reads `STALE` on base and heads alike (`0/15/0` in a git worktree).

`shellcheck 0.10.0 -S warning -x` on all 7 edited files (head1: 2 files, head2: 5 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `b42d34d7b`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `orch-rotate.tst.sh` on base): rc 1, 198 pass, 1 fail
  (`FAIL: 10c. r05-01 one copy: own=[66: ... 73: ... 86: ...]`; both standalone checks
  `10c. r05-01 lazy load` and `10c. r05-01 lifecycle` pass on base, proving equivalence);
  head1: rc 0, 199 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with `declare -F _spl_simple_cron_apply` deleted in
  `spl-orch-rotate-install-cron.func.sh`): rc 1, 192 pass, 7 fail (`10. dry`,
  `10b. derived log dir`, `10. install`, `10. lines`, `10. check`, `10c. r05-01 lazy load`,
  `10c. r05-01 lifecycle`, with `spl-orch-rotate-install-cron.func.sh: line 55:
  _spl_simple_cron_apply: command not found`).
- Row 02 red control (`rc2`, head2's `spl-spawn-fill.tst.sh` on base): rc 1, 49 pass (43
  base + all 6 standalone lazy-load and install `ok_msg` checks passing on base, proving
  equivalence), 6 fail lines (5 real `FAIL:` checks + trailing `FAIL: 5`:
  `FAIL: 11. helper lifecycle: bash: line 5: _spl_run_cron_apply: command not found`,
  `FAIL: 11. host one copy: old=[48: ... spl_spawn_fill_cron_check ...]`,
  `FAIL: 11. one copy spl-security-round-install-cron.func.sh: own=[52: ...]`,
  `FAIL: 11. one copy spl-desk-poll-ack-install-cron.func.sh: own=[50: ...]`,
  `FAIL: 11. one copy spl-accepted-close-install-cron.func.sh: own=[50: ...]`); head2:
  rc 0, 55 pass (54 `PASS:` + `PASS: all`), 0 fail.
- Row 02 guard control a (`gc2a`, head2 with `declare -F _spl_run_cron_apply` deleted in
  `spl-security-round-install-cron.func.sh`): rc 1, 52 pass, 3 fail lines (2 `FAIL:`
  checks `11. lazy sr` and `11. sr ok`, both rc=127 `line 52: _spl_run_cron_apply:
  command not found`, + trailing `FAIL: 2`).
- Row 02 guard control b (`gc2b`, head2 with `declare -F _spl_run_cron_apply` deleted in
  `spl-desk-poll-ack-install-cron.func.sh`): rc 1, 52 pass, 3 fail lines (2 `FAIL:`
  checks `11. lazy pa` and `11. pa ok`, both rc=127 `line 49: _spl_run_cron_apply:
  command not found`, + trailing `FAIL: 2`).
- Row 02 guard control c (`gc2c`, head2 with `declare -F _spl_run_cron_apply` deleted in
  `spl-accepted-close-install-cron.func.sh`): rc 1, 52 pass, 3 fail lines (2 `FAIL:`
  checks `11. lazy ac` and `11. ac ok`, both rc=127 `line 49: _spl_run_cron_apply:
  command not found`, + trailing `FAIL: 2`).

**Mutation checks** (n=1 each, detached worktrees of `b42d34d7b` with head1/head2
applied, then one defect injected):
- `m1a` (`spl-orch-rotate-install-cron.func.sh` omits 11th arg `""`, falling back to
  `" cron"`): `orch-rotate.tst.sh` rc 1, 199 `ok|pass` lines (197 `PASS:` + 2 `OK` lines
  dumped inside `10c. r05-01 lifecycle`'s failure output), 2 fail (`FAIL: 10c. r05-01 lazy
  load` + `FAIL: 10c. r05-01 lifecycle`).
- `m1b` (`spl-orch-rotate-install-cron.func.sh` replaces arg 10 `miss_why` with `""`,
  keeping arg 11 `""`): `orch-rotate.tst.sh` rc 1, 198 pass, 1 fail (`FAIL: 10c. r05-01
  lazy load`).
- `m2a` (`spl-security-round-install-cron.func.sh` replaces arg 10 `miss_why` with `""`):
  `spl-spawn-fill.tst.sh` rc 1, 53 pass, 2 fail lines (`FAIL: 11. lazy sr` + trailing
  `FAIL: 1`).
- `m2b` (`spl-desk-poll-ack-install-cron.func.sh` replaces arg 10 `miss_why` with `""`):
  `spl-spawn-fill.tst.sh` rc 1, 53 pass, 2 fail lines (`FAIL: 11. lazy pa` + trailing
  `FAIL: 1`).
- `m2c` (`spl-accepted-close-install-cron.func.sh` replaces arg 10 `miss_why` with `""`):
  `spl-spawn-fill.tst.sh` rc 1, 53 pass, 2 fail lines (`FAIL: 11. lazy ac` + trailing
  `FAIL: 1`).

The tests that name the sites (R2): `git grep -lE` over `*tst.sh`, `features/*/tests/*`,
`csi-spl-api/`, and `csi-spl-iac/` for row 01
(`spl-orch-rotate-install-cron|do_spl_orch_rotate_install_cron`) ->
`orc:src/bash/tests/orch-rotate.tst.sh`, `iac:src/bash/tests/satellite-ansible.tst.sh`
(line 372 directly greps `tag="$SPL_ORG_APP:orch-rotate"` in
`spl-orch-rotate-install-cron.func.sh`, bolded in section 2), and
`orc:src/bash/tests/spl-box-deploy.tst.sh:58` (stub function definition only; does not
source the `.func.sh` file, stays out of the test column); `box-stats-cron.tst.sh` also
runs as the `_spl_simple_cron_apply` host suite. For row 02
(`spl-(spawn-fill|security-round|desk-poll-ack|accepted-close)-install-cron|do_spl_(spawn_fill|security_round|desk_poll_ack|accepted_close)_install_cron`)
-> `orc:src/bash/tests/spl-spawn-fill.tst.sh`,
`orc:src/bash/tests/spl-security-round-queue.tst.sh`,
`orc:src/bash/tests/spl-desk-poll-ack.tst.sh`,
`orc:src/bash/tests/spl-accepted-close.tst.sh` (0 hits in `csi-spl-api/` or
`csi-spl-iac/`). 30-char non-header comment grep across the 5 `.func.sh` files -> 6
comments >= 30 chars, 4 hits (only the untouched `# shellcheck disable=SC2016 # $HOME...`
directives at lines 45/49/46/46 matching tests' own shellcheck directives, never grepping
source text). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r05-01-orc-orch-rotate-simple-cron-apply)` | one fact, one copy (developer guide 2.2.4) | `spl-orch-rotate-install-cron.func.sh:54-88` duplicates the exact 35-line `check`/`DRY_RUN=1`/`remove`/`install` crontab state machine hosted in `_spl_simple_cron_apply` (`setup-box-stats-cron.func.sh:64-107`, def `:68-107`, optional `noun=""` landed in `r04-02` `b42d34d7b`); last remaining matching script cron installer (1.3, r04 section 7 #2) | `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh:40,54-88`<br>`orc:src/bash/tests/orch-rotate.tst.sh:948` | copies of the single-line script cron check/dry-run/remove/install state machine in `spl-orch-rotate-install-cron` 1 -> 0 own copy (delegated to `_spl_simple_cron_apply` with `noun=""`; completes 10/10 wave-1..4 consolidation; `setup-box-stats-cron.func.sh` untouched) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head's `orch-rotate.tst.sh` on parent FAILs 1 check (`rc1`, rc 1, 198 pass, 1 fail: `10c. r05-01 one copy` naming `:66`, `:73`, `:86`; standalone checks pass on base), then GREEN (`0/199/0`); guard control (`gc1`, `declare -F _spl_simple_cron_apply` deleted, built in worktree: rc 1, `192/7` with `_spl_simple_cron_apply: command not found`); mutations `m1a` (omit arg 11 `""`, rc 1 `199*/2`) and `m1b` (arg 10 `""`, rc 1 `198/1`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 3 new checks in `orch-rotate.tst.sh`. Tests: **`orc:.../orch-rotate.tst.sh`**, **`iac:.../satellite-ansible.tst.sh`**, `orc:.../box-stats-cron.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r05-02-orc-run-cron-apply-wave1)` | one fact, one copy (developer guide 2.2.4) | `spl-spawn-fill-install-cron.func.sh:47-78`, `spl-security-round-install-cron.func.sh:51-82`, `spl-desk-poll-ack-install-cron.func.sh:48-81`, and `spl-accepted-close-install-cron.func.sh:48-81` duplicate the exact 32-34 line `./run` crontab `check` (`spl_*_cron_check`) / `DRY_RUN=1` / `remove` / `install` state machine (1.4) | `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh:30,47-78`<br>`orc:src/bash/run/spl-security-round-install-cron.func.sh:35,51-82`<br>`orc:src/bash/run/spl-desk-poll-ack-install-cron.func.sh:31,48-81`<br>`orc:src/bash/run/spl-accepted-close-install-cron.func.sh:31,48-81`<br>`orc:src/bash/tests/spl-spawn-fill.tst.sh:387` | copies of the `./run` cron check/dry-run/remove/install state machine and `spl_*_cron_check` across these 4 installers 4 -> 1 (hosted in `spl-spawn-fill-install-cron.func.sh` as `_spl_run_cron_apply`; 3 siblings lazy-source and delegate) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head's `spl-spawn-fill.tst.sh` on parent FAILs 5 checks (`rc2`, rc 1, 49 pass, 6 fail lines = 5 `FAIL:` + `FAIL: 5`: helper lifecycle + 4 one-copy checks naming `:48`, `:52`, `:50`, `:50`; all 6 standalone checks pass on base), then GREEN (`0/55*/0`); guard controls (`gc2a`, `gc2b`, `gc2c`, `declare -F _spl_run_cron_apply` deleted in each wave-1 installer, built in worktrees: rc 1, `52/3` = 2 `FAIL:` + `FAIL: 2` each with `_spl_run_cron_apply: command not found`); mutations `m2a`/`m2b`/`m2c` (arg 10 `""` in each wave-1 installer: rc 1, `53/2` = 1 `FAIL:` + `FAIL: 1` each) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 11 new checks in `spl-spawn-fill.tst.sh`. Tests: **`orc:.../spl-spawn-fill.tst.sh`**, `orc:.../spl-security-round-queue.tst.sh`, `orc:.../spl-desk-poll-ack.tst.sh`, `orc:.../spl-accepted-close.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r05-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r05-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows delegate duplicated internal crontab-installer scaffolding with zero
change to any output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper delegation; no behaviour changes)` (row 01) and
`Docs: none (internal helper extraction and delegation; no behaviour changes)` (row 02).
The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-orch-rotate-install-cron.func.sh`, `orch-rotate.tst.sh`; row 02: `csi-spl-orc`
  `spl-spawn-fill-install-cron.func.sh`, `spl-security-round-install-cron.func.sh`,
  `spl-desk-poll-ack-install-cron.func.sh`, `spl-accepted-close-install-cron.func.sh`,
  `spl-spawn-fill.tst.sh`).
- No row edits `orc:src/bash/run/setup-box-stats-cron.func.sh`,
  `orc:src/bash/tests/box-stats-cron.tst.sh`,
  `orc:src/bash/run/spl-spawn-place-install-cron.func.sh`,
  `orc:src/bash/run/spl-review-go-install-cron.func.sh`,
  `orc:src/bash/run/spl-topic-archive-suggest-install-cron.func.sh`,
  `orc:src/bash/run/spl-dispatch-rotate-install-cron.func.sh`,
  `orc:src/bash/run/spl-agent-boot-restore-install-cron.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-checkout.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-lock.func.sh`,
  `orc:src/bash/run/spl-desk-install-service.func.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, `csi-spl-utl/`, or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7 edited + 3 wave-1 regression-run test files = 10 checked; `satellite-ansible.tst.sh`
and `box-stats-cron.tst.sh` are read-only in row 01's test column; note `box-stats-cron.tst.sh`
was flagged by `lane-map.sh` at 03:11Z as dirty in `a-886`'s worktree during r04-02 review
and is intentionally NOT edited by either row):
`orc:src/bash/run/spl-orch-rotate-install-cron.func.sh`,
`orc:src/bash/tests/orch-rotate.tst.sh`;
`orc:src/bash/run/spl-spawn-fill-install-cron.func.sh`,
`orc:src/bash/run/spl-security-round-install-cron.func.sh`,
`orc:src/bash/run/spl-desk-poll-ack-install-cron.func.sh`,
`orc:src/bash/run/spl-accepted-close-install-cron.func.sh`,
`orc:src/bash/tests/spl-spawn-fill.tst.sh`,
`orc:src/bash/tests/spl-security-round-queue.tst.sh`,
`orc:src/bash/tests/spl-desk-poll-ack.tst.sh`,
`orc:src/bash/tests/spl-accepted-close.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 10 paths> --agent a-891`, n=1, at
  2026-11-26T03:12:03Z: **exit 4** ("no live lane lists <the 10 paths>, but 16 live lane(s)
  record no files"); re-checked at 2026-11-26T03:58:11Z after `c-823` (`b48-01`) landed
  (`61a325ebc`, panel N3): **exit 4**, 15 `unknown:` live lanes (all on the other box:
  13 channel/workspace/other-repo seats `c-029`, `c-041`, `c-086`, `c-146`, `c-187`,
  `c-398`, `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-936`, plus spec 125
  doc/R7 seats `c-957`, `c-965`), 0 owned. Verified via `do_spl_lane_map` at 03:08:54Z —
  live lanes on this box (`a-891`, `a-852` r04 closing, `a-886` / `c-879` r04-02 closing,
  `a-846` b48 planner, `c-298` Reporting Taxes tab, `a-826` / `c-722` SPL-6517 latency
  action 7) and other-box `c-827` (`b48-03`) / `c-838` (`r04-01` closing) / `c-935` (gig
  doc set) touch none of the 10 paths. No live lane owns any of the 10 paths; the holder
  re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-26T03:08:57Z):
  2 queued, 0 placing:
  - `77c6180c` (`c002-refactor-round-05-claude-panel-seat`, refactor): this round's panel
    seat; 0 overlap.
  - `5b1b7d82` (`c001-s186-m9-n2-qto-sync`, feature): s186 M9 Qto sync; 0 overlap.
  None touches any of the 10 paths.
- **Unlanded rows from r04:** **0** (`r04-01` landed `fc50062f3`, `r04-02` landed
  `b42d34d7b`).
- **Briefs on this box** modified in the last 24 h matching any of the 5 `.func.sh` paths
  (at 03:12Z): only the already-landed `c002-r04-02-orc-simple-cron-apply-wave3.md`
  (naming `spl-orch-rotate-install-cron` in its NOT list); **0 live briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 03:12Z):
  `git diff --name-only $(git merge-base b42d34d7b <b>) <b> -- <the 10 paths>` ->
  **0 unlanded branches**.
- **Commits in the last 24 h** on the 10 paths (`git log b42d34d7b --since='24 hours ago'`,
  at 03:12Z) -> **0** commits.

## 3. Per row: what the lane does

- **r05-01:** `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh` drops unused
  `current` from `local` at `:40`, lazy-sources `setup-box-stats-cron.func.sh` behind
  `declare -F _spl_simple_cron_apply` inside `do_spl_orch_rotate_install_cron`, and
  replaces `:54-88` with a call to `_spl_simple_cron_apply` passing
  `"orchestrator rotation"`, `"runs hourly at :$(printf '%02d' "$min") as the box user"`,
  `": the orchestrator session is never renewed"`, and `""` as arg 11 (`noun`).
  `orc:src/bash/tests/orch-rotate.tst.sh` inserts section `10c` before `:948` (1 one-copy
  check, 1 hermetic standalone lazy-load `check`-missing check, and 1 hermetic standalone
  `DRY_RUN=0` install/check/remove lifecycle check). `setup-box-stats-cron.func.sh` and
  `box-stats-cron.tst.sh` are untouched.
- **r05-02:** `orc:src/bash/run/spl-spawn-fill-install-cron.func.sh` drops unused
  `current` from `local` at `:30`, drops `spl_spawn_fill_cron_check`, extracts
  `_spl_run_cron_apply` (`<act> <tag> <src> <trunk> <run> <logdir> <line> <label> <ok_msg>
  [miss_why]`), and delegates `do_spl_spawn_fill_install_cron`'s apply tail to it.
  `orc:src/bash/run/spl-security-round-install-cron.func.sh`,
  `orc:src/bash/run/spl-desk-poll-ack-install-cron.func.sh`, and
  `orc:src/bash/run/spl-accepted-close-install-cron.func.sh` each drop unused `current`
  from `local`, drop their `spl_*_cron_check` function, lazy-source
  `spl-spawn-fill-install-cron.func.sh` behind `declare -F _spl_run_cron_apply` inside
  their action function, and delegate their apply tail to `_spl_run_cron_apply`.
  `orc:src/bash/tests/spl-spawn-fill.tst.sh` inserts section `11` before `:387` (1 direct
  `_spl_run_cron_apply` lifecycle check, 4 one-copy checks, and 6 hermetic standalone
  lazy-load `check`-missing and `DRY_RUN=0` install `ok_msg` checks).

## 4. Panel and reviewers (R7)

- Editor: **a-891** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-893**
  (live on this box, queued with this planner). Returned **PASS** on v0.1
  (`e97c0dcc55aae42f058b608f5f7a7beea06f0a84`, seat commit `94f7de00a`, msg `78c4d74e` /
  `860e85fe`; `do_spl_review_line_check` rc 0, 7/7 tests in log, holder msg `739cc265`),
  and final **PASS** signature on v1.0 (`78812b3d7`, seat commit `81022372b`, msg
  `45e1ab76` / `aec30545`; `do_spl_review_line_check` rc 0, `DOCS-ONLY`, holder GO LAND
  `16edd42c`). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-26T03:09:25Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 03:09:42Z (`pick=agy`, `main=agy`, `backup=claude`; mistral sits on no review), R7
    review of a claude coding row goes to an **agy seat** per row (claude waiver backup
    only while agy is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 03:09:34Z picked an available box
    (the other box, 74% < 80% aim); the holder re-checks agy capacity at row placement
    and uses the claude waiver backup only if agy is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r05-01 | `c002-r05-01-orc-orch-rotate-simple-cron-apply` | `refactor(r05-01-orc-orch-rotate-simple-cron-apply, SPL-<row issue>): ...` | `review/r05-01` | 1 |
| r05-02 | `c002-r05-02-orc-run-cron-apply-wave1` | `refactor(r05-02-orc-run-cron-apply-wave1, SPL-<row issue>): ...` | `review/r05-02` | 1 |

**r05-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-orch-rotate-install-cron.func.sh` (drop unused `current` at
`:40`, lazy-source `setup-box-stats-cron.func.sh` behind `declare -F _spl_simple_cron_apply`,
replace `:54-88` with `_spl_simple_cron_apply` passing `"orchestrator rotation"`,
`"runs hourly at :$(printf '%02d' "$min") as the box user"`,
`": the orchestrator session is never renewed"`, `""`), and
`csi-spl-orc/src/bash/tests/orch-rotate.tst.sh` (insert section `10c` before `:948`:
1 one-copy check, 1 hermetic standalone lazy-load `check`-missing check, 1 hermetic
standalone `DRY_RUN=0` install/check/remove lifecycle check). NOT
`setup-box-stats-cron.func.sh`, NOT `box-stats-cron.tst.sh`, NOT
`spl-dispatch-rotate-install-cron.func.sh`, NOT `.shellcheck-warning-baseline.txt`, or
any other file. Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3);
red control (`rc1`, head's `orch-rotate.tst.sh` on parent) RED then GREEN in the body;
guard control (`gc1`, `declare -F _spl_simple_cron_apply` deleted, built in a worktree);
mutations `m1a`/`m1b` caught by section `10c`. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper delegation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota,
valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the
claude backup is used; never mistral; re-checked at placement).

**r05-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-spawn-fill-install-cron.func.sh` (drop unused `current` at
`:30`, drop `spl_spawn_fill_cron_check`, extract `_spl_run_cron_apply` and delegate
`:47-78`),
`csi-spl-orc/src/bash/run/spl-security-round-install-cron.func.sh` (drop unused `current`
at `:35`, drop `spl_security_round_cron_check`, lazy-source
`spl-spawn-fill-install-cron.func.sh` and delegate `:51-82` to `_spl_run_cron_apply`),
`csi-spl-orc/src/bash/run/spl-desk-poll-ack-install-cron.func.sh` (drop unused `current`
at `:31`, drop `spl_poll_ack_cron_check`, lazy-source `spl-spawn-fill-install-cron.func.sh`
and delegate `:48-81` to `_spl_run_cron_apply`),
`csi-spl-orc/src/bash/run/spl-accepted-close-install-cron.func.sh` (drop unused `current`
at `:31`, drop `spl_accepted_close_cron_check`, lazy-source
`spl-spawn-fill-install-cron.func.sh` and delegate `:48-81` to `_spl_run_cron_apply`),
and `csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh` (insert section `11` before `:387`:
1 direct `_spl_run_cron_apply` lifecycle check, 4 one-copy checks, and 6 hermetic
standalone lazy-load `check`-missing and `DRY_RUN=0` install `ok_msg` checks). NOT
`spl-spawn-place-install-cron.func.sh`, NOT `spl-review-go-install-cron.func.sh`, NOT
`spl-topic-archive-suggest-install-cron.func.sh`, NOT `spl-desk-install-service.func.sh`,
NOT `.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02
verbatim, 1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head's
`spl-spawn-fill.tst.sh` on parent) RED then GREEN in the body; guard controls
(`gc2a`, `gc2b`, `gc2c`, `declare -F _spl_run_cron_apply` deleted in each wave-1
installer, built in worktrees); mutations `m2a`/`m2b`/`m2c` caught by section `11`.
Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper extraction and delegation; no behaviour changes)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row
brief if the claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the single-line script cron check/dry-run/remove/install block in `spl-orch-rotate-install-cron` (1.3) | 1 on `b42d34d7b` -> 0 own copy (delegated to `_spl_simple_cron_apply`; 10/10 wave-1..4 consolidated) after row 01 |
| copies of the `./run` cron check/dry-run/remove/install state machine and `spl_*_cron_check` across row 02's 4 installers (1.4) | 4 on `b42d34d7b` (`spl-spawn-fill`, `spl-security-round`, `spl-desk-poll-ack`, `spl-accepted-close`) -> 1 (`_spl_run_cron_apply` in `spl-spawn-fill-install-cron.func.sh`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-orch-rotate-install-cron.func.sh` +6 -36, `orch-rotate.tst.sh` +31 -0; row 02: `spl-spawn-fill-install-cron.func.sh` +26 -15, `spl-security-round-install-cron.func.sh` +7 -32, `spl-desk-poll-ack-install-cron.func.sh` +7 -34, `spl-accepted-close-install-cron.func.sh` +7 -34, `spl-spawn-fill.tst.sh` +95 -0 |
| measured on | `b42d34d7b`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Remaining `./run` flock cron installers matching `_spl_run_cron_apply`: `orc:src/bash/run/spl-spawn-place-install-cron.func.sh:46-79` (79 lines), `spl-review-go-install-cron.func.sh:46-79` (79 lines), and `spl-topic-archive-suggest-install-cron.func.sh:44-77` (77 lines) | direct `_spl_run_cron_apply` wave-2 candidates for `r06`+ once `r05-02` lands; deferred here because row 02 already hits rulebook 3.1's 5-file cap, `spl-review-go.tst.sh` is live in `b48-01` (`c-823`), `spl-spawn-queue.tst.sh` is 2,673 lines, and `spl-topic-archive-suggest-install-cron` checks `-r "$script"` instead of `-x "$run"` with `"is gone"` / `"is missing in $src"` wording | file reads and `diff -u` on `b42d34d7b` (`spl-spawn-place:46-79` vs `spl-spawn-fill:47-78`, `spl-review-go:46-79`, `spl-topic-archive-suggest:44-77`, n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` (`brc:91-96` vs `oq:62-68`) and `*_apply` (`brc:136-161` vs `oq:111-137`) scaffolding (r04 W2 / section 7 #1) | re-measured on `b42d34d7b`: `oq_read` inserts `do_spl_cloud_cnf` between `spl_db_require_bins` and `spl_db_query_rc` (~3 lines saved); `*_apply` differs by 15 lines (`chmod 600` on undo, `2>/dev/null` vs `2>&1`, `!= "$status"` vs `== done \|\| == diss`, distinct log/undo strings); left out while cleaner zero-behaviour-change duplicates exist | file reads and `diff -u` on `b42d34d7b` (`brc:136-161` vs `oq:111-137`: 15 diff lines, n=1) |
| Remaining non-matching cron installers: `orc:src/bash/run/spl-dispatch-rotate-install-cron.func.sh` (134 lines, 2-line rotate+heal), `spl-agent-boot-restore-install-cron.func.sh` (177 lines, retire/removed markers and custom install wording), `spl-box-restart-install-cron.func.sh` (117 lines, `SPL_DESK_CRON_CREATE` + slot check), `spl-peer-crons.func.sh` (273 lines, `SPL_DESK_CRON_CREATE` + no `"the "` prefix) | none matches `_spl_simple_cron_apply` or `_spl_run_cron_apply` verbatim; each needs separate inspection or a distinct helper | file reads on `b42d34d7b` (n=1) |
| `orc:src/bash/run/spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` (5 live probe sidecar setup/pin/detach/kill blocks) | touches 5+ files and passes `ROOT_KEY` (`--root-key "$key"`) / `MEMBER_PW_FILE` (secret-handling path; brief: secret-class sites stay out) | file reads on `b42d34d7b` (n=1) |
| `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 vacuous red control (`r03-02` note / r04 section 7) | test-bug fix, not a refactor row (brief: "bug rows and test rows are not yours"); belongs in a bug round | r04 section 7 |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line tenant/dry-run/confirm/pin/backup preflight) | heavy PG R2 gate (`msg-dedup.tst.sh` and `msg-wipe.tst.sh` build `cmd/spool` against throwaway `postgres:16-alpine` containers) | r04 section 7 |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop) | passes `-K "${cfg}/auth.curl"` (Bearer access token file, secret-class); kept out per brief | r04 section 7 |
| Candidates-file open refactor-labelled items: `_ppe_keys` exact-key in `iac:src/bash/run/check-pre-push-e2e.func.sh:121-128` (line 113), `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` saying `Lang-review: a-NNN` (line 115), and WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125) | `_ppe_keys` is gate-design input (prefix matching adds +9 to every menu test; not a narrow refactor row); `i18n-lang-review-exempt.json:2` is a 1-line JSON doc comment (doc/bug-shaped); WUI entry-chunk headroom is perf-shaped (belongs in a perf round). Lines 1 (`spl-watchdog.func.sh:72,:1323`, `spl-lane-rotate.func.sh`), 25 (`reverse-tunnel-cron.sh:27`), 48 (`agent-boot-restore` in `spl-watchdog.func.sh:541` and `spl-agent-boot-restore-install-cron.func.sh:60`), 76 (`spl-desk-reply.sh:9`), 104 (`spl-lane-mix.func.sh`), and 133 (`spl-unanswered-sweep.func.sh`) are served on `b42d34d7b` | `git show` / `git grep` on `b42d34d7b` (1.2 (c), n=1) |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh`, `spl-{accepted-close,desk-poll-ack,review-go}.func.sh` action bodies, `spl-hub-box-band.func.sh`, `spl-wui-perf-report.func.sh`, `csi-spl-utl/**`, `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, spec 011 deferred/owner-decision tasks, and remaining non-refactor candidates-file items | each pulls PostgreSQL or 30+ tests into R2, is secret-class, or stays out for its r04/r03 section 7 reason | 1.2 (a), (c), (d); r04 section 7 |

## 8. Changes

- v0.1 (a-891): the rows and every read on `b42d34d7b`; both heads built in detached
  scratch worktrees; the 16-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; all 6 red and guard
  controls (`rc1`, `gc1`, `rc2`, `gc2a`, `gc2b`, `gc2c`) and all 5 mutation checks
  (`m1a`, `m1b`, `m2a`, `m2b`, `m2c`) run on detached worktrees and verified RED; all
  helper, caller, and test hunks included verbatim in 1.3 and 1.4. Pushed to
  `review/c002-refactor-round-05-planner` (`e97c0dcc5`).
- v1.0 (a-891): folded cross-vendor claude panel (`c-893`, PASS on v0.1 `e97c0dcc5`,
  seat commit `94f7de00a`, msg `78c4d74e` / `860e85fe`; `do_spl_review_line_check` rc 0,
  holder msg `739cc265`) W1, W2, and N1-N7 (no row change; all 7 fenced `bash` blocks
  **byte-identical** to v0.1 `e97c0dcc5`):
  - **W1:** named and verified all 9 refactor-labelled entries from
    `c002-next-round-candidates.md` in 1.2 (c) and section 7 (lines 1, 25, 48, 76, 104,
    133 served on `b42d34d7b`; lines 113 `_ppe_keys`, 115 `i18n-lang-review-exempt.json:2`,
    and 125 WUI entry-chunk headroom open and out of scope with dispositions).
  - **W2:** aligned `spl-spawn-fill.tst.sh` prose, line count (`390 -> 485`, `+95 -0`),
    and sha256 (`1b29f5d84f85`) to one blank line before and after section `11` (line
    `:386` is already blank; verified matching `1b29f5d84f85` on `b42d34d7b`).
  - **N1-N7:** corrected `setup-box-stats-cron.func.sh:64-107` (def `:68-107`, N1);
    re-checked zero drift across all 13 row/test/host files `b42d34d7b..5dbcaec84` (N2);
    updated `lane-map.sh` count after `c-823`/`b48-01` landed (`61a325ebc`: exit 4, 15
    unknown on the other box, 0 owned, N3); noted N4 (sibling remove lines checked by
    shared `$label`), N5 (section 11 block 1 inherits env; `env -u SPL_DESK_CRON_CREATE`
    optional), N6 (`$(printf)` / `$(id -un)` evaluated before helper call, output same),
    and N7 (lazy-source loads `setup-box-stats-cron.func.sh`'s guarded top level, same as
    r04-02). Pushed fast-forward to `review/c002-refactor-round-05-planner` (`78812b3d7`).
- v1.0 signed (a-891): recorded final panel **PASS** signature by `c-893` (claude) on
  v1.0 `78812b3d75ee018ce4497ad5d82af3ac37d39cd8` (seat commit
  `81022372b5e70e0ecee0134f213ece27308993ac`, msg `45e1ab76` / `aec30545`;
  `do_spl_review_line_check` rc 0, `DOCS-ONLY`, holder GO LAND `16edd42c`). Zero change
  to any row, site, batch, test hunk, sha256, or vendor (7/7 fenced `bash` blocks
  byte-identical); zero drift on all 13 row/test/host files from `b42d34d7b` to
  `origin/master` `5dbcaec84`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-891 (agy): v0.1 (`e97c0dcc5`), v1.0 (`78812b3d7`, signed).
- Panel reviewer seat: c-893 (claude, seat `81022372b5e70e0ecee0134f213ece27308993ac` on
  `review/c002-refactor-round-05-claude-seat`):
  - v0.1 `e97c0dcc55aae42f058b608f5f7a7beea06f0a84`: **PASS** (seat commit `94f7de00a`,
    msg `78c4d74e` / `860e85fe`; `do_spl_review_line_check` rc 0, 7/7 tests in log,
    holder msg `739cc265`).
  - v1.0 `78812b3d75ee018ce4497ad5d82af3ac37d39cd8`: **PASS** (seat commit
    `81022372b5e70e0ecee0134f213ece27308993ac`, msg `45e1ab76` / `aec30545`;
    `do_spl_review_line_check` rc 0, `DOCS-ONLY`, holder GO LAND `16edd42c`; 7/7 fenced
    `bash` blocks byte-identical, zero open W).
- Row R7 seats: section 4; agy seat per row (claude waiver backup only while agy is out
  of quota under ruling `dc84300a`; never mistral).
