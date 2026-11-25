# Refactoring round 02 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6526  
Topic: fef8780e-b54d-4116-a28f-ae33f18ea6e7  
Discussion: fef8780e-b54d-4116-a28f-ae33f18ea6e7 (t1 #refactoring, "Refactor round 02", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r02**, plan `refactor-round-02-plan.md` (free: only `refactor-round-2-plan.md` exists,
  so no date suffix), rows `r02-<NN>`, scope `docs(r02-plan, SPL-6526)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 01 ([refactor-round-01-plan.md](refactor-round-01-plan.md)
v1.0 `43a4b3949`) is now closed (`cd8cd4cec`): both `r01-01` (`e108142e8`, SPL-6525) and
`r01-02` (`3582fc44b`, SPL-6530, landed 2026-11-25T19:09:45Z) are on `origin/master`.
The perf floor (rulebook 4.4), measured on `c567245fa` at 2026-11-25T19:04:13Z (14 days):
perf 36, refactor 106, 25.4%, 5 x 36 = 180 >= 142, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r01: a
duplicated setup, output, or execution block that lives in multiple `orc:src/bash/run/`
actions moves to a single shared helper in one sibling file, and each caller delegates to
that one home.
**Row 01:** the two same-workspace desk move actions in `orc:src/bash/run/` —
`spl-msg-move.func.sh` (`do_spl_msg_move`, `:50-60` and `:70-78`) and
`spl-topic-move.func.sh` (`do_spl_topic_move`, `:47-57` and `:76-84`; r01 plan section 7)
— duplicate both the 11-line desk-dir / dry-run / desk-exists / `spl_host_spool` setup
block (differing only in `"message $id to topic $task"` vs `"topic $topic to #$channel"`)
and the 9-line `python3` JSON summary block (differing only in key `"to_task"` vs
`"channel"`). Extracting `_spl_desk_move_prep` and `_spl_desk_move_json` into
`spl-msg-move.func.sh` (zero top-level code) lets `spl-msg-move.func.sh` call both
directly and lets `spl-topic-move.func.sh` lazy-source `spl-msg-move.func.sh` behind a
`declare -F _spl_desk_move_prep` guard and delegate both blocks to one home.
**Row 02:** the three single-line periodic cron installers in `orc:src/bash/run/` —
`setup-box-stats-cron.func.sh:59-93` (`do_setup_box_stats_cron`),
`check-disk-headroom-install-cron.func.sh:57-91` (`do_check_disk_headroom_install_cron`),
and `setup-go-cache-prune-cron.func.sh:57-91` (`do_setup_go_cache_prune_cron`; r01 plan
section 7) — duplicate the exact 35-line `check` / `DRY_RUN` / `remove` / `install`
crontab execution state machine (differing only in the cron label, optional missing-line
suffix, and install OK verb). Extracting `_spl_simple_cron_apply` into
`setup-box-stats-cron.func.sh` lets `setup-box-stats-cron.func.sh` call it directly and
lets `check-disk-headroom-install-cron.func.sh` and `setup-go-cache-prune-cron.func.sh`
lazy-source `setup-box-stats-cron.func.sh` behind a `declare -F _spl_simple_cron_apply`
guard inside their action functions and delegate all crontab check/dry-run/remove/install
handling to one home.
The rows share no file: both are batch 1.

**Status: v0.3 draft** (panel W1-W3, N1, N2, N4, N6 folded; pending cross-vendor panel
re-review and signing on `review/c002-refactor-round-02-planner`, never master before the
GO). Editor: **a-712** (agy). Cross-vendor panel seat live: **c-646** (claude).

**One sha:** every count is measured on **`c567245fa`** (`c567245fa3b0eb149ea4eff9412a60fe193a2d31`,
`origin/master` at 2026-11-25T19:02:15Z; zero drift on all 10 row/test files to
`origin/master` `5fdfae32b` at 2026-11-25T20:00:22Z,
`git diff --name-only c567245fa origin/master -- <10 files>` -> empty), n=1 per command unless
stated. Reads are on `c567245fa` with `git show` / `git grep`. The tests of 1.5 ran in
detached scratch worktrees of `c567245fa` (not committed, removed on exit): "base"
unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" = base with row
02 applied in 1.4's shape; each red control, guard control, and mutation check (1.5) ran
in a detached worktree of its own. All helper definitions and all three test hunks are
reproduced verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2,
all 6 red/guard controls, and all 5 mutation checks byte-for-byte on `c567245fa` and
verify every sha256. Queue, lane map, brief and branch reads are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-25T19:02:38Z (re-checked on `5fdfae32b` at 20:03:23Z), n=1, after a fresh fetch
(`git-fetch-fresh.sh`):

- **Window: W=2026-11-25T18:51:33+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r01-plan'`:
  `43a4b3949bb37c9c4bec3fdbeac5b0d556458fe5`
  (`docs(r01-plan, SPL-6520): refactor round 01 plan v1.0, signed by c-650 (claude) PASS on 78277dc10, N1-N6 folded`),
  read once at the start as 5.3 says (round 01 had no close record yet when r02 started;
  its close record `cd8cd4cec` landed later at 2026-11-25T21:35:25+02:00). Per rulebook
  5.3, `W` stays fixed at this recorded date (`2026-11-25T18:51:33+02:00`); all later R4,
  R6, 2.7.5, and `PRUNE_SINCE` reads for r02 must use `W=2026-11-25T18:51:33+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r02-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r02-*' 'refs/heads/*-r02-*' 'refs/heads/*refactor-round-02*' 'refs/heads/wip/*r02*'`
  -> nothing (before this plan's review branch and the panel seat branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r02-[0-9]{2}|refactor-round-02'` (on the
  planner's box) -> **2** briefs only: this planner's brief and the panel seat's brief
  (`c002-refactor-round-02-claude-panel-seat.md`); 0 `r02-NN` row briefs.
- `git ls-tree --name-only c567245fa csi-spl-doc/doc/md/ | grep -c refactor-round-02`
  -> **0** (only `refactor-round-2-plan.md` exists, so `refactor-round-02-plan.md` is free
  with no date suffix per rulebook 5.3).

### 1.2 The brief's inputs, re-measured

- **(a) r01 section 7:** re-read on `c567245fa`.
  - `orc:src/bash/run/spl-msg-move.func.sh` and `spl-topic-move.func.sh` (desk setup,
    dry-run, and JSON output block): clean 2-file duplicate with fast pure-bash tests ->
    measured here as **row 01** (1.3).
  - `orc:src/bash/run/{setup-box-stats-cron,check-disk-headroom-install-cron,setup-go-cache-prune-cron}.func.sh`
    (check / dry-run / remove / install crontab execution block): clean 3-file duplicate
    with fast pure-bash tests -> measured here as **row 02** (1.4).
  - `orc:src/bash/run/spl-hub-{agent-kinds,runner-cpu}.func.sh` (`ORDERED_BY`/`ORDERED_VIA`
    guard): `r01-02` (`3582fc44b`, SPL-6530) landed at 19:09:45Z (after `c567245fa`, and
    round 01 closed at `cd8cd4cec`), leaving the write-mode guard intact on `origin/master`
    `5fdfae32b` (`:30-32,40` vs `:29-31,39`); kept in section 7 for `r03` because r02
    already carries 2 full, verified rows on `c567245fa` (rulebook 5.1).
  - `git diff --name-only fe1f82671 c567245fa` (54 files): among r01 section 7's items,
    only `spl-hub-request-minutes.func.sh` and `spl-hub-run-metrics.func.sh` changed
    (`r01-01` `e108142e8`); none of the remaining section 7 candidates changed on
    `c567245fa`, and `r01-02` (`3582fc44b`) later touched `spl-hub-{agent-kinds,runner-cpu}.func.sh`
    without removing the write-mode guard; each stays accounted for in section 7.
- **(b) R7 and panel notes:**
  - `r01-01` R7 (`a-697`, agy, PASS on `934b7c371`, landed `e108142e8`): N1 noted rebase
    onto `bbc2adb26` with zero drift on the 3 row files (already folded in `e108142e8`).
    No refactor row.
  - `r01-02` (`3582fc44b`, SPL-6530, R7 `a-705`, agy, PASS on `043e458ed`, recorded in
    round 01 close `cd8cd4cec`): landed at 19:09:45Z with all 4 files matching r01 plan
    1.4 head2 verbatim. No refactor row.
  - `r99-01` (`05129cff9`, R7 `a-565`) and `r99-02` (`83a6b0d7d`, R7 `a-562`): verification
    notes only, already checked in r01 1.2 (b). No refactor row.
  - r01 panel (`c-650`, claude, recorded in r01 plan v1.0 `43a4b3949`): PASS on
    `78277dc10`; N1-N6 already folded into `43a4b3949`. No refactor row.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 139 lines, read 19:02Z):
  - No `## for refactor round 02` block; only change since r01 is a dropped b47 line.
  - All earlier refactor-shaped items remain served or out of scope (bug, perf,
    other-repo, or gate-design items), accounted for in section 7.
- **(d) spec 011 tasks:**
  `git log fe1f82671..c567245fa --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r01's base; remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `spl-msg-move.func.sh` and `spl-topic-move.func.sh` share `_spl_desk_move_prep` and `_spl_desk_move_json`

`orc:` = `csi-spl-orc/`. On `c567245fa`:

- `orc:src/bash/run/spl-msg-move.func.sh:50-60` (in `do_spl_msg_move`) and
  `orc:src/bash/run/spl-topic-move.func.sh:47-57` (in `do_spl_topic_move`) carry the same
  11-line desk-dir lookup, dry-run logging, desk-exists check, and `spl_host_spool` call,
  differing only in line 4 (`"message $id to topic $task"` vs `"topic $topic to #$channel"`):
  `diff -u <(git show c567245fa:csi-spl-orc/src/bash/run/spl-msg-move.func.sh | sed -n '50,60p') <(git show c567245fa:csi-spl-orc/src/bash/run/spl-topic-move.func.sh | sed -n '47,57p')`
  -> 1 single differing line (n=1).
- `orc:src/bash/run/spl-msg-move.func.sh:70-78` and
  `orc:src/bash/run/spl-topic-move.func.sh:76-84` carry the exact same 9-line `python3`
  JSON summary emitter, differing only in key name (`"to_task"` vs `"channel"`) and value
  (`"$task"` vs `"$channel"`):
  `diff -u <(git show c567245fa:csi-spl-orc/src/bash/run/spl-msg-move.func.sh | sed -n '70,78p') <(git show c567245fa:csi-spl-orc/src/bash/run/spl-topic-move.func.sh | sed -n '76,84p')`
  -> 3 differing lines for key/variable name only (n=1).
- `_spl_desk_move_prep`, `_spl_desk_move_json`, `SPL_MOVE_DIR`, and `SPL_MOVE_DRY_DONE`
  have **0 collisions** anywhere in the repo (`git grep` -> 0). Both `.func.sh` files
  contain only function definitions (zero top-level code). Placing both helpers in
  `spl-msg-move.func.sh` (right before `# _spl_msg_move_why`, `:82`) and adding a
  `declare -F _spl_desk_move_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-msg-move.func.sh"`
  guard in `do_spl_topic_move` keeps both actions lazy under `./run`
  (`run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged) while also making
  standalone sourcing of `spl-topic-move.func.sh` work (once `_spl_desk_move_prep` loads
  `spl-msg-move.func.sh`, `_spl_desk_move_json` is defined too).
- Neither extracted block handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_desk_move_prep` is 15 lines;
  `_spl_desk_move_json` is 10 lines; `do_spl_msg_move` 49 -> 34 lines; `_spl_msg_move_why`
  stays 16 lines; `do_spl_topic_move` 57 -> 44 lines. None of the 4 files has any entry
  in `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-msg-move.func.sh`: replace `:50-60` with `local hub="$SPL_HUB_URL" d`,
  `_spl_desk_move_prep "$dry" "$tenant" "$box" "$agent" "$act_for" "message $id to topic $task" || return 1`,
  `(( SPL_MOVE_DRY_DONE )) && return 0`, `d="$SPL_MOVE_DIR"`; replace `:70-78` with
  `_spl_desk_move_json "$tenant" "$box" "$agent" to_task "$task" "$out"`; insert
  `_spl_desk_move_prep` (with its 3-line header documenting process globals
  `SPL_MOVE_DIR` and `SPL_MOVE_DRY_DONE`, and `# shellcheck disable=SC2034`) and
  `_spl_desk_move_json` right before `# _spl_msg_move_why` (`:82`). 98 -> 118 lines
  (`+35 -15`).
- `orc:src/bash/run/spl-topic-move.func.sh`: replace `:47-57` with `local hub="$SPL_HUB_URL" d`,
  `# shellcheck source=spl-msg-move.func.sh`,
  `declare -F _spl_desk_move_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-msg-move.func.sh"`,
  `_spl_desk_move_prep "$dry" "$tenant" "$box" "$agent" "$act_for" "topic $topic to #$channel" || return 1`,
  `(( SPL_MOVE_DRY_DONE )) && return 0`, `d="$SPL_MOVE_DIR"`; replace `:76-84` with
  `_spl_desk_move_json "$tenant" "$box" "$agent" channel "$channel" "$out"`. 86 -> 73
  lines (`+7 -20`).
- `orc:src/bash/tests/spl-msg-move.tst.sh`: append section 6 before `:74`
  (`echo "fails=$fails"`): 4 direct `_spl_desk_move_prep` checks (dry-run with desk,
  dry-run missing desk, `DRY_RUN=0` missing desk before `spl_host_spool`, `DRY_RUN=0`
  with desk setting `SPL_MOVE_DIR` and calling `spl_host_spool`), 2 direct
  `_spl_desk_move_json` checks (parsed JSON payload and non-JSON string fallback), and
  1 one-copy check. 75 -> 125 lines (`+50 -0`: 49-line hunk + 1 trailing blank line).
- `orc:src/bash/tests/spl-topic-move.tst.sh`: append section 6 before `:71`
  (`echo "fails=$fails"`): 1 top-level JSON key assertion (`channel == "dev"` and
  `"to_task"` absent, catching `m1b` which section 4's substring match misses because
  the stub's nested `.move` object also contains `"channel": "dev"`), 1 one-copy check,
  and 1 standalone lazy-load check (sourcing only `spl-topic-move.func.sh`). 72 -> 90
  lines (`+18 -0`: 17-line hunk + 1 trailing blank line).
- head1's files, sha256 (12 chars): `spl-msg-move.func.sh` `4a442ccdc5ef`,
  `spl-topic-move.func.sh` `66ee11218bed`, `spl-msg-move.tst.sh` `5b907bd5d703`,
  `spl-topic-move.tst.sh` `1a42b8064d83`.
- Note for the row and its reviewer: under `./run`, `run.sh`'s lazy stub loader defines
  stubs for `_spl_desk_move_prep` and `_spl_desk_move_json`, so the
  `declare -F _spl_desk_move_prep` guard acts on the standalone-source path outside
  `./run` (the `in_orc` suites source `.func.sh` eagerly). Build `gc1` in a worktree, not
  a single-file temp copy, because the guard loads its sibling via
  `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper and test hunks (head1 on `c567245fa`):

`orc:src/bash/run/spl-msg-move.func.sh` (inserted immediately before
`# _spl_msg_move_why names a hub refusal of a message move in one line.` at `:82`,
separated by one blank line):
```bash
# _spl_desk_move_prep <dry> <tenant> <box> <agent> <act_for> <what> -> resolve
# the desk dir (SPL_MOVE_DIR), handle dry-run (SPL_MOVE_DRY_DONE=1), or verify
# the desk dir exists and locate host spool for DRY_RUN=0.
# shellcheck disable=SC2034 # SPL_MOVE_* globals are read by callers
_spl_desk_move_prep() {
  local dry="$1" tenant="$2" box="$3" agent="$4" act_for="$5" what="$6"
  local hub="$SPL_HUB_URL" d
  SPL_MOVE_DIR="" SPL_MOVE_DRY_DONE=0
  d="$(spl_desk_dir "$tenant" "$box")" || [[ $? -eq 1 ]] || return 1
  if (( dry )); then
    do_log "INFO DRY_RUN would: move $what as $agent${act_for:+ for $act_for} on $box in $tenant ($hub)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to move."
    SPL_MOVE_DRY_DONE=1
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1
  SPL_MOVE_DIR="$d"
}

# _spl_desk_move_json <tenant> <box> <agent> <key> <val> <out> -> print the
# single JSON summary line for do_spl_msg_move / do_spl_topic_move.
_spl_desk_move_json() {
  python3 - "$ENV" "$1" "$2" "$3" "$4" "$5" "$6" <<'EOF_PY'
import json, sys
env, tenant, box, agent, key, val, out = sys.argv[1:]
try:
    out = json.loads(out)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, key: val, "move": out}, sort_keys=True))
EOF_PY
}
```

`orc:src/bash/tests/spl-msg-move.tst.sh` section 6 (inserted immediately before
`echo "fails=$fails"` at `:74`, followed by one blank line):
```bash
# --- 6. _spl_desk_move_prep / _spl_desk_move_json (r02-01 one copy) -----------
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/state/dev/desk/$1/$2"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 1 t1 box-desk CLE-00 HUM-1 "message m1 to topic t2" || exit 1
  printf "DONE=%s DIR=%s\n" "$SPL_MOVE_DRY_DONE" "$SPL_MOVE_DIR"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"INFO DRY_RUN would: move message m1 to topic t2 as CLE-00 for HUM-1 on box-desk in t1 (https://hub.test)"* && "$out" == *"DONE=1 DIR="* && "$out" != *"there is no desk"* && "$out" != *"SPOOL-CALLED"* ]] \
  && pass "6. _spl_desk_move_prep dry run with existing desk sets SPL_MOVE_DRY_DONE=1 and skips spool" || fail "6. prep dry ok: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/no-desk"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 1 t1 box-desk CLE-00 "" "message m1 to topic t2" || exit 1
  printf "DONE=%s\n" "$SPL_MOVE_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"INFO DRY_RUN there is no desk for CLE-00 on box-desk in t1 yet ($T/no-desk)"* && "$out" == *"DONE=1"* ]] \
  && pass "6. _spl_desk_move_prep dry run notes missing desk" || fail "6. prep dry nodesk: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/no-desk"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 0 t1 box-desk CLE-00 "" "message m1 to topic t2"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no desk for CLE-00 on box-desk in t1: run do_spl_desk_up first ($T/no-desk)"* && "$out" != *"SPOOL-CALLED"* ]] \
  && pass "6. _spl_desk_move_prep refuses missing desk on DRY_RUN=0 before host spool" || fail "6. prep nodesk: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/state/dev/desk/$1/$2"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 0 t1 box-desk CLE-00 "" "message m1 to topic t2" || exit 1
  printf "DONE=%s DIR=%s\n" "$SPL_MOVE_DRY_DONE" "$SPL_MOVE_DIR"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"SPOOL-CALLED"* && "$out" == *"DONE=0 DIR=$T/state/dev/desk/t1/box-desk"* ]] \
  && pass "6. _spl_desk_move_prep sets SPL_MOVE_DIR and calls spl_host_spool on DRY_RUN=0" || fail "6. prep live: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" ENV=dev PAYLOAD='{"ok":true}' bash -c '
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_json t1 box-desk CLE-00 to_task t2 "$PAYLOAD"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == '{"agent": "CLE-00", "box": "box-desk", "env": "dev", "move": {"ok": true}, "tenant": "t1", "to_task": "t2"}' ]] \
  && pass "6. _spl_desk_move_json embeds parsed JSON move payload" || fail "6. json obj: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" ENV=prd bash -c '
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_json t1 box-desk CLE-00 channel dev "plain-text"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == '{"agent": "CLE-00", "box": "box-desk", "channel": "dev", "env": "prd", "move": "plain-text", "tenant": "t1"}' ]] \
  && pass "6. _spl_desk_move_json falls back to raw string when move output is non-JSON" || fail "6. json str: rc=$rc $out"
mm_f="$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
[[ "$(grep -c "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to move." "$mm_f")" -eq 1 && "$(grep -c "EOF_PY" "$mm_f")" -eq 2 && "$(grep -c "_spl_desk_move_prep " "$mm_f")" -ge 1 && "$(grep -c "_spl_desk_move_json " "$mm_f")" -ge 1 ]] \
  && pass "6. one copy: spl-msg-move.func.sh defines and calls _spl_desk_move_prep and _spl_desk_move_json once" || fail "6. msg one copy"
```

`orc:src/bash/tests/spl-topic-move.tst.sh` section 6 (inserted immediately before
`echo "fails=$fails"` at `:71`, followed by one blank line):
```bash
# --- 6. r02-01 one copy and standalone lazy-source -----------------------------
jline="$(run_mv TOPIC_ID=$TOPIC CHANNEL='#dev' DRY_RUN=0 2>&1 | grep '^{')"
python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert d.get("channel") == "dev" and "to_task" not in d' "$jline" \
  && pass "6. topic move emits top-level channel key (not to_task)" || fail "6. topic json key: $jline"
tm_f="$PROJ_ROOT/src/bash/run/spl-topic-move.func.sh"
own="$(grep -nE "OK DRY_RUN nothing was sent\. Re-run with DRY_RUN=0 to move\.|EOF_PY" "$tm_f" || true)"
[[ -z "$own" ]] && grep -q "_spl_desk_move_prep " "$tm_f" && grep -q "_spl_desk_move_json " "$tm_f" \
  && pass "6. one copy: spl-topic-move.func.sh delegates prep and JSON output to shared helpers" || fail "6. topic one copy: own=[$own]"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BOX=box-desk TOPIC_ID="$TOPIC" CHANNEL=dev bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_desk_cnf(){ SPL_HUB_URL="https://hub.test"; }; spl_dry_run(){ return 0; }
  spl_desk_box_default(){ echo box-desk; }; spl_desk_validate(){ return 0; }
  spl_desk_dir(){ echo "$T/state/dev/desk/$1/$2"; }
  source "$PROJ_ROOT/src/bash/run/spl-topic-move.func.sh"
  do_spl_topic_move' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"INFO DRY_RUN would: move topic $TOPIC to #dev as CLE-00 on box-desk in t1 (https://hub.test)"* && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-topic-move.func.sh loads _spl_desk_move_prep standalone" || fail "6. lazy topic: rc=$rc $out"
```

**Behaviour:** `_spl_desk_move_prep` executes the exact `spl_desk_dir`, dry-run log,
missing-desk check, and `spl_host_spool` sequence removed from both actions, in the exact
same order; its only new state is the two unexported process globals `SPL_MOVE_DIR` and
`SPL_MOVE_DRY_DONE` documented in its header (unread by other callers).
`_spl_desk_move_json` runs the exact `python3` JSON serialization with the caller's key
(`to_task` or `channel`). All row-01 and shared suites pass on base and head1 with
identical counts plus the 7 + 3 new checks (1.5).

### 1.4 Row 02's site: `setup-box-stats-cron.func.sh`, `check-disk-headroom-install-cron.func.sh`, and `setup-go-cache-prune-cron.func.sh` share `_spl_simple_cron_apply`

`orc:` = `csi-spl-orc/`. On `c567245fa`:

- `orc:src/bash/run/setup-box-stats-cron.func.sh:59-93`,
  `orc:src/bash/run/check-disk-headroom-install-cron.func.sh:57-91`, and
  `orc:src/bash/run/setup-go-cache-prune-cron.func.sh:57-91` carry the exact same 35-line
  `current="$(spl_desk_cron_line "$tag")"` + `check` / `DRY_RUN=1` / `remove` / `install`
  crontab execution block, differing only in 4 log lines (the cron label, optional
  missing-line suffix on `check`, and install OK verb):
  `diff -u` of `setup-box-stats-cron.func.sh:59-93` against each sibling -> 4 single-line
  hunks each (n=1 each); every control-flow branch, return code, `spl_desk_cron_*` call,
  and error string is byte-identical.
- `_spl_simple_cron_apply` has **0 collisions** anywhere in the repo (`git grep` -> 0).
  All three files already carry the same three top-level `declare -F ... || source` lines
  for `spl-desk-cron-lock`, `spl-desk-install-service`, and `spl-desk-cron-checkout`.
  Hosting `_spl_simple_cron_apply` in `setup-box-stats-cron.func.sh` and lazy-sourcing
  `setup-box-stats-cron.func.sh` inside `do_check_disk_headroom_install_cron` and
  `do_setup_go_cache_prune_cron` behind a `declare -F _spl_simple_cron_apply` guard adds
  zero top-level lines, avoids touching `lib/bash/funcs/spl-desk-cron-checkout.func.sh`
  (19 installers depend on it), keeps `run-lazy-loader.tst.sh` and
  `run-eager-files.tst.sh` unchanged, and works standalone (each sibling test sources its
  `.func.sh` alone).
- None of the three installers handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_simple_cron_apply` is 37 lines;
  `do_setup_box_stats_cron` 61 -> 29 lines; `do_check_disk_headroom_install_cron` 62 ->
  32 lines; `do_setup_go_cache_prune_cron` 61 -> 30 lines. None of the 4 edited files has
  any entry in `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/setup-box-stats-cron.func.sh`: drop unused `current` from `local` at
  `:43`; replace `:59-94` (body plus `do_setup_box_stats_cron`'s closing `}`) with the
  verbatim 1.4 block calling `_spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" "box-stats" "posts a sample every ${every}m as the box user" ": the hub gets no regular samples of this box"`,
  closing `do_setup_box_stats_cron`, and defining `_spl_simple_cron_apply`. 94 -> 105 lines (`+16 -5`).
- `orc:src/bash/run/check-disk-headroom-install-cron.func.sh`: drop unused `current` from
  `local` at `:41`; replace `:57-91` with `# shellcheck source=setup-box-stats-cron.func.sh`,
  `declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"`,
  and `_spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" "disk headroom" "ticks every ${every}m as the box user" ": a filling disk warns nobody"`. 92 -> 62 lines (`+6 -36`).
- `orc:src/bash/run/setup-go-cache-prune-cron.func.sh`: drop unused `current` from
  `local` at `:41`; replace `:57-91` with `# shellcheck source=setup-box-stats-cron.func.sh`,
  `declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"`,
  and `_spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" "go-cache prune" "ticks every ${every}m as the box user"`. 92 -> 61 lines (`+5 -36`).
- `orc:src/bash/tests/box-stats-cron.tst.sh`: append section 4 before `:219` (`echo` /
  `if [ "$fails" -eq 0 ]`): 2 exact-message checks on `do_setup_box_stats_cron` (check
  missing with suffix + install `ok_msg`), 1 direct `_spl_simple_cron_apply` round-trip
  check (`check` missing -> `install` -> `check` ok -> `remove`), 3 one-copy checks (host
  + both siblings), and 2 standalone lazy-load checks (sourcing only
  `check-disk-headroom-install-cron.func.sh` and only `setup-go-cache-prune-cron.func.sh`,
  each verifying exact label and missing-line text). 221 -> 275 lines (`+54 -0`: 53-line
  hunk + 1 trailing blank line). Total
  edited files: **4** (within rulebook 3.1's max 5; `check-disk-headroom.tst.sh` and
  `prune-go-build-cache.tst.sh` run unmodified in the test column).
- head2's files, sha256 (12 chars): `setup-box-stats-cron.func.sh` `2b1f19013437`,
  `check-disk-headroom-install-cron.func.sh` `6106f57f2059`,
  `setup-go-cache-prune-cron.func.sh` `7e4e89ea9bd4`,
  `box-stats-cron.tst.sh` `c880d0a28021`.
- Note for the row and its reviewer: `check-disk-headroom-install-cron.func.sh` and
  `setup-go-cache-prune-cron.func.sh` now depend on sibling
  `setup-box-stats-cron.func.sh` (held by the one-copy and lazy-load checks; if
  `setup-box-stats-cron` is ever retired, move `_spl_simple_cron_apply` first). Build
  `gc2a` and `gc2b` in a worktree, not a single-file temp copy, because the guard loads
  its sibling via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper and test hunks (head2 on `c567245fa`):

`orc:src/bash/run/setup-box-stats-cron.func.sh` (replaces `:59-94` — its block brings
`do_setup_box_stats_cron`'s closing `}` on line 4 and defines `_spl_simple_cron_apply`
after it; also remove `current` from `local` at `:43`):
```bash
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "box-stats" "posts a sample every ${every}m as the box user" \
    ": the hub gets no regular samples of this box"
}

# _spl_simple_cron_apply <act> <tag> <src> <trunk> <script> <logdir> <line>
#   <label> <ok_msg> [miss_why] -> run check, dry-run, remove, or install for
#   a single-line tagged crontab action.
_spl_simple_cron_apply() {
  local act="$1" tag="$2" src="$3" trunk="$4" script="$5" logdir="$6" line="$7"
  local label="$8" ok_msg="$9" miss_why="${10:-}" current
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the $label cron is NOT installed (no line tagged $tag)$miss_why"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the $label cron is installed and its script is executable"
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
    do_log "OK the $label cron is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the $label cron $ok_msg:"
  spl_desk_cron_say "$line"
}
```

`orc:src/bash/run/check-disk-headroom-install-cron.func.sh` (replaces `:57-91`, keeping
the closing `}` at `:92`; also remove `current` from `local` at `:41`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "disk headroom" "ticks every ${every}m as the box user" \
    ": a filling disk warns nobody"
```

`orc:src/bash/run/setup-go-cache-prune-cron.func.sh` (replaces `:57-91`, keeping the
closing `}` at `:92`; also remove `current` from `local` at `:41`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "go-cache prune" "ticks every ${every}m as the box user"
```

`orc:src/bash/tests/box-stats-cron.tst.sh` section 4 (inserted immediately before the
blank `echo` / `if [ "$fails" -eq 0 ]` summary at `:219`, followed by one blank line):
```bash
# 4. _spl_simple_cron_apply (r02-02 one copy) ----------------------------------
out="$(setup BOX_STATS_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the box-stats cron is NOT installed (no line tagged csi-spl:box-stats): the hub gets no regular samples of this box"* ]] &&
  pass "4. box-stats check-missing keeps exact label and suffix" || fail "4. box miss (rc=$rc): $out"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the box-stats cron posts a sample every 5m as the box user:"* ]] &&
  pass "4. box-stats install keeps exact ok_msg" || fail "4. box ok (rc=$rc): $out"
setup DRY_RUN=0 BOX_STATS_CRON_ACTION=remove >/dev/null
printf '#!/bin/sh\n' >"$T/demo.sh"; chmod +x "$T/demo.sh"
out="$(env PROJ_ROOT="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" T="$T" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }
  source "$PROJ_ROOT/src/bash/run/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply check "csi-spl:demo" "$T" master "$T/demo.sh" "$T/dlog" "* * * * * $T/demo.sh # csi-spl:demo" "demo" "ticks every 1m" ": no demo"
  echo "rc1=$?"
  _spl_simple_cron_apply install "csi-spl:demo" "$T" master "$T/demo.sh" "$T/dlog" "* * * * * $T/demo.sh # csi-spl:demo" "demo" "ticks every 1m" ": no demo"
  echo "rc2=$?"
  _spl_simple_cron_apply check "csi-spl:demo" "$T" master "$T/demo.sh" "$T/dlog" "* * * * * $T/demo.sh # csi-spl:demo" "demo" "ticks every 1m" ": no demo"
  echo "rc3=$?"
  _spl_simple_cron_apply remove "csi-spl:demo" "$T" master "$T/demo.sh" "$T/dlog" "* * * * * $T/demo.sh # csi-spl:demo" "demo" "ticks every 1m" ": no demo"
  echo "rc4=$?"' 2>&1)"
[[ "$out" == *"FAIL the demo cron is NOT installed (no line tagged csi-spl:demo): no demo"* && "$out" == *"rc1=1"* \
  && "$out" == *"OK the demo cron ticks every 1m:"* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the demo cron is installed and its script is executable"* && "$out" == *"rc3=0"* \
  && "$out" == *"OK the demo cron is out of the crontab"* && "$out" == *"rc4=0"* ]] &&
  cmp -s "$T/crontab" "$T/crontab.orig" &&
  pass "4. _spl_simple_cron_apply handles check-missing, install, check-ok and remove directly" || fail "4. apply direct: $out"
bs_f="$PROJ_ROOT/src/bash/run/setup-box-stats-cron.func.sh"
dh_f="$PROJ_ROOT/src/bash/run/check-disk-headroom-install-cron.func.sh"
gc_f="$PROJ_ROOT/src/bash/run/setup-go-cache-prune-cron.func.sh"
[[ "$(grep -c "the crontab does not read back what was written" "$bs_f")" -eq 1 && "$(grep -c "_spl_simple_cron_apply " "$bs_f")" -ge 1 ]] &&
  pass "4. one copy: setup-box-stats-cron.func.sh defines and calls _spl_simple_cron_apply once" || fail "4. box one copy"
for sib in "$dh_f" "$gc_f"; do
  own="$(grep -nE "the crontab does not read back what was written|is installed and its script is executable|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_simple_cron_apply " "$sib" &&
    pass "4. one copy: $(basename "$sib") delegates apply to _spl_simple_cron_apply" || fail "4. one copy $(basename "$sib"): own=[$own]"
done
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh"
chmod +x "$SH/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh" "$SH/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" DISK_HEADROOM_CRON_LOG_DIR="$T/log-dh" DISK_HEADROOM_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/check-disk-headroom-install-cron.func.sh"
  do_check_disk_headroom_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the disk headroom cron is NOT installed (no line tagged csi-spl:disk-headroom): a filling disk warns nobody"* && "$out" != *"command not found"* ]] &&
  pass "4. lazy load: check-disk-headroom-install-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "4. lazy dh (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" GO_CACHE_CRON_LOG_DIR="$T/log-gc" GO_CACHE_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-go-cache-prune-cron.func.sh"
  do_setup_go_cache_prune_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the go-cache prune cron is NOT installed (no line tagged csi-spl:go-cache-prune)"* && "$out" != *"command not found"* ]] &&
  pass "4. lazy load: setup-go-cache-prune-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "4. lazy gc (rc=$rc): $out"
```

**Behaviour:** `_spl_simple_cron_apply` executes the exact `spl_desk_cron_line`, `check`,
`DRY_RUN=1`, `remove`, and `install` logic removed from all three actions, emitting
byte-identical log lines and exit codes for every caller; all row-02 and shared suites
pass on base and head2 with identical counts plus the 8 new checks in
`box-stats-cron.tst.sh` (1.5).

### 1.5 Before and on the rows' heads

2026-11-25T19:07:08Z-19:20:39Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal
to base: same rc, pass and fail counts; "-" means that row's head does not touch the
suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-msg-move.tst.sh` | 01 | 0 / 19 / 1* | 0 / 26 / 1* (+7 new checks) | - |
| `orc:src/bash/tests/spl-topic-move.tst.sh` | 01 | 0 / 18 / 1* | 0 / 21 / 1* (+3 new checks) | - |
| `orc:src/bash/tests/box-stats-cron.tst.sh` | 02 | 0 / 36 / 0 | - | 0 / 44 / 0 (+8 new checks) |
| `orc:src/bash/tests/check-disk-headroom.tst.sh` | 02 | 0 / 43 / 0 | - | = |
| `orc:src/bash/tests/prune-go-build-cache.tst.sh` | 02 | 0 / 58 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note (\*): `spl-msg-move.tst.sh` and `spl-topic-move.tst.sh` print a final `fails=0`
summary line on rc 0 (matched by `grep -ciE '^ *(not ok|fail)'`), so `fail=1` with rc 0
represents 0 failed assertions + 1 `fails=0` summary line; on failure `fails=k` adds 1 to
the `FAIL:` line count. `box-stats-cron.tst.sh`, `check-disk-headroom.tst.sh`, and
`prune-go-build-cache.tst.sh` print `all passed` / `0 failure(s)` on rc 0 (0 fail lines).
Run every suite and control in a git worktree (not a plain `git archive` export): outside
a git tree, `no-literal-paths.tst.sh` reads `1/13/2` (`STALE` baseline) on base and heads
alike (`0/15/0` in a git worktree; panel N2).

`shellcheck -S warning -x` on all 8 edited files (head1: 4 files, head2: 4 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `c567245fa`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control a (`rc1a`, head1's `spl-msg-move.tst.sh` on base): rc 1, 19 pass,
  8 fail lines (7 assertions: `FAIL: 6. prep dry ok` / `prep dry nodesk` / `prep live`
  rc 1 and `prep nodesk` rc 127 `_spl_desk_move_prep: command not found`,
  `FAIL: 6. json obj` / `json str` rc 127 `_spl_desk_move_json: command not found`,
  `FAIL: 6. msg one copy`, plus `fails=7`); head1: rc 0, 26 pass, 1 (`fails=0`).
- Row 01 red control b (`rc1b`, head1's `spl-topic-move.tst.sh` on base): rc 1, 20 pass,
  2 fail lines (1 assertion: `FAIL: 6. topic one copy: own=[53: do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to move." ...]`
  plus `fails=1`; the top-level JSON key and standalone dry-run checks pass on base,
  proving equivalence); head1: rc 0, 21 pass, 1 (`fails=0`).
- Row 01 guard control (`gc1`, head1 with the `declare -F _spl_desk_move_prep`
  lazy-source line deleted in `spl-topic-move.func.sh`): rc 1, 20 pass, 2 fail lines
  (`FAIL: 6. lazy topic: rc=1 .../spl-topic-move.func.sh: line 49: _spl_desk_move_prep: command not found`,
  plus `fails=1`).
- Row 02 red control (`rc2`, head2's `box-stats-cron.tst.sh` on base): rc 1, 40 pass,
  4 fail (`FAIL: 4. apply direct: bash: line 4: _spl_simple_cron_apply: command not found`,
  `FAIL: 4. box one copy`, `FAIL: 4. one copy check-disk-headroom-install-cron.func.sh: own=[69: ...]`,
  `FAIL: 4. one copy setup-go-cache-prune-cron.func.sh: own=[69: ...]`; the 2 box-stats
  exact-message checks and 2 standalone sibling checks pass on base, proving equivalence);
  head2: rc 0, 44 pass, 0 fail.
- Row 02 guard control a (`gc2a`, head2 with the `declare -F _spl_simple_cron_apply`
  lazy-source line deleted in `check-disk-headroom-install-cron.func.sh`): rc 1, 43 pass,
  1 fail (`FAIL: 4. lazy dh (rc=127): .../check-disk-headroom-install-cron.func.sh: line 58: _spl_simple_cron_apply: command not found`).
- Row 02 guard control b (`gc2b`, head2 with the `declare -F _spl_simple_cron_apply`
  lazy-source line deleted in `setup-go-cache-prune-cron.func.sh`): rc 1, 43 pass, 1 fail
  (`FAIL: 4. lazy gc (rc=127): .../setup-go-cache-prune-cron.func.sh: line 58: _spl_simple_cron_apply: command not found`).

**Mutation checks** (n=1 each, detached worktrees of `c567245fa` with head1/head2
applied, then one defect injected):
- `m1a` (`spl-msg-move.func.sh` passes `channel` instead of `to_task` to
  `_spl_desk_move_json`): `spl-msg-move.tst.sh` rc 1, 26 pass, 2 fail lines (`FAIL: move (rc=0)` + `fails=1`).
- `m1b` (`spl-topic-move.func.sh` passes `to_task` instead of `channel` to
  `_spl_desk_move_json`): `spl-topic-move.tst.sh` rc 1, 20 pass, 2 fail lines (`FAIL: 6. topic json key` + `fails=1`).
- `m2a` (`setup-box-stats-cron.func.sh` drops `": the hub gets no regular samples of this box"`):
  `box-stats-cron.tst.sh` rc 1, 43 pass, 1 fail (`FAIL: 4. box miss (rc=1)`).
- `m2b` (`check-disk-headroom-install-cron.func.sh` passes `"box-stats"` instead of
  `"disk headroom"`): `box-stats-cron.tst.sh` rc 1, 43 pass, 1 fail (`FAIL: 4. lazy dh (rc=1)`).
- `m2c` (`setup-go-cache-prune-cron.func.sh` passes `"box-stats"` instead of
  `"go-cache prune"`): `box-stats-cron.tst.sh` rc 1, 43 pass, 1 fail (`FAIL: 4. lazy gc (rc=1)`).

The tests that name the sites (R2): `git grep -lE` over `*.tst.sh` and `features/*/tests/*`
for `spl-msg-move|spl-topic-move|do_spl_msg_move|do_spl_topic_move|_spl_msg_move_why|check-disk-headroom-install-cron|setup-box-stats-cron|setup-go-cache-prune-cron|do_check_disk_headroom_install_cron|do_setup_box_stats_cron|do_setup_go_cache_prune_cron`
-> `spl-msg-move.tst.sh` and `spl-topic-move.tst.sh` for row 01; `box-stats-cron.tst.sh`,
`check-disk-headroom.tst.sh`, and `prune-go-build-cache.tst.sh` for row 02 (plus the 8
shared iac/orc gates). 30-char non-separator comment grep across all `*.tst.sh` and
`test-*.sh` -> **0 hits** (only 1 non-header comment >= 30 chars across the 5 `.func.sh`
files, 0 test hits). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r02-01-orc-desk-move-common)` | one fact, one copy (developer guide 2.2.4) | `spl-msg-move.func.sh:50-60,70-78` and `spl-topic-move.func.sh:47-57,76-84` duplicate both the 11-line desk-dir / dry-run / desk-exists / `spl_host_spool` setup and the 9-line `python3` JSON summary block (1.3, r01 section 7) | `orc:src/bash/run/spl-msg-move.func.sh:50-60,70-78,82`<br>`orc:src/bash/run/spl-topic-move.func.sh:47-57,76-84`<br>`orc:src/bash/tests/spl-msg-move.tst.sh:74`<br>`orc:src/bash/tests/spl-topic-move.tst.sh:71` | copies of desk-move prep and JSON summary blocks 2 -> 1 (`_spl_desk_move_prep` and `_spl_desk_move_json` in `spl-msg-move.func.sh`) | 1.3's shape (verbatim blocks in 1.3; header documents process globals `SPL_MOVE_DIR`, `SPL_MOVE_DRY_DONE`). **Red control:** head's `spl-msg-move.tst.sh` on parent FAILs 7 checks (`rc1a`, rc 1, 19 pass, 8 fail lines incl. `fails=7`, `_spl_desk_move_prep` / `_spl_desk_move_json` command not found + one-copy) and head's `spl-topic-move.tst.sh` on parent FAILs one-copy naming `:53` (`rc1b`, rc 1, 20 pass, 2 fail lines incl. `fails=1`), then GREEN (26/1* and 21/1*, `fails=0`); guard control (`gc1`, `declare -F _spl_desk_move_prep` deleted in `spl-topic-move.func.sh`: rc 1, 20 pass, 2 fail lines with `_spl_desk_move_prep: command not found`; proves standalone-source path outside `./run`), built in a worktree; JSON key checks catch `m1a`/`m1b` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 7 + 3 new checks. Tests: **`orc:.../spl-msg-move.tst.sh`**, **`orc:.../spl-topic-move.tst.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r02-02-orc-simple-cron-install)` | one fact, one copy (developer guide 2.2.4) | `setup-box-stats-cron.func.sh:59-93`, `check-disk-headroom-install-cron.func.sh:57-91`, and `setup-go-cache-prune-cron.func.sh:57-91` duplicate the exact 35-line `check` / `DRY_RUN=1` / `remove` / `install` crontab state machine differing only in label, optional missing-line suffix, and install OK verb (1.4, r01 section 7) | `orc:src/bash/run/setup-box-stats-cron.func.sh:43,59-94`<br>`orc:src/bash/run/check-disk-headroom-install-cron.func.sh:41,57-91`<br>`orc:src/bash/run/setup-go-cache-prune-cron.func.sh:41,57-91`<br>`orc:src/bash/tests/box-stats-cron.tst.sh:219` | copies of the single-line periodic cron check/dry-run/remove/install state machine 3 -> 1 (`_spl_simple_cron_apply` in `setup-box-stats-cron.func.sh`) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head's `box-stats-cron.tst.sh` on parent FAILs 4 checks (`rc2`, rc 1, 40 pass, 4 fail: `_spl_simple_cron_apply: command not found` + 3 one-copy checks naming `:69`), then GREEN (44/0); guard controls (`gc2a`, `declare -F _spl_simple_cron_apply` deleted in `check-disk-headroom-install-cron.func.sh`: rc 1, 43/1; `gc2b`, deleted in `setup-go-cache-prune-cron.func.sh`: rc 1, 43/1; prove standalone-source path), built in worktrees; label/suffix checks catch `m2a`/`m2b`/`m2c` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 8 new checks in `box-stats-cron.tst.sh`. Tests: **`orc:.../box-stats-cron.tst.sh`**, `orc:.../check-disk-headroom.tst.sh`, `orc:.../prune-go-build-cache.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r02-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r02-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row extracts a duplicated setup, output, or execution block into shared
helpers and points its callers at that single home; no output, exit code, env var, path
or file a caller sees changes (1.3, 1.4, 1.5). Each: `Docs: none (<why>)`. The developer
guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-msg-move.func.sh`, `spl-topic-move.func.sh`, `spl-msg-move.tst.sh`,
  `spl-topic-move.tst.sh`; row 02: `csi-spl-orc` `setup-box-stats-cron.func.sh`,
  `check-disk-headroom-install-cron.func.sh`, `setup-go-cache-prune-cron.func.sh`,
  `box-stats-cron.tst.sh`).
- No row edits `orc:src/bash/run/spl-hub-agent-kinds.func.sh`,
  `orc:src/bash/run/spl-hub-runner-cpu.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-checkout.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-lock.func.sh`,
  `orc:src/bash/run/spl-desk-install-service.func.sh`,
  `orc:src/bash/tests/check-disk-headroom.tst.sh`,
  `orc:src/bash/tests/prune-go-build-cache.tst.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/`,
  `csi-spl-iac/`, `csi-spl-utl/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (8 edited + 2 regression-run test files = 10 checked):
`orc:src/bash/run/spl-msg-move.func.sh`,
`orc:src/bash/run/spl-topic-move.func.sh`,
`orc:src/bash/tests/spl-msg-move.tst.sh`,
`orc:src/bash/tests/spl-topic-move.tst.sh`;
`orc:src/bash/run/setup-box-stats-cron.func.sh`,
`orc:src/bash/run/check-disk-headroom-install-cron.func.sh`,
`orc:src/bash/run/setup-go-cache-prune-cron.func.sh`,
`orc:src/bash/tests/box-stats-cron.tst.sh`,
`orc:src/bash/tests/check-disk-headroom.tst.sh`,
`orc:src/bash/tests/prune-go-build-cache.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 10 paths> --agent a-712`, n=1,
  re-checked at 2026-11-25T20:01:50Z: **exit 4** ("no live lane lists <the 10 paths>, but
  18 live lane(s) record no files"). Verified via `do_spl_lane_map --all` at 20:01:03Z —
  the 18 `unknown:` lanes, all on the other box: 13 channel/workspace/other-repo seats
  (`c-029`, `c-041`, `c-086`, `c-146`, `c-187`, `c-398`, `c-407`, `c-416`, `c-474`,
  `c-535`, `c-728`, `c-927`, `c-936`), latency action 3 (`c-569`), WUI e2e bfcache red
  (`c-645`), r02 panel seat (`c-646`), and spec 125 doc/R7 seats (`c-957`, `c-965`). Live
  lanes on this box (`a-712`, `a-709` b47 editor, `a-748`/`c-737` SPL-6533 y9 rules,
  `a-678`/`a-746`/`c-722`/`c-718` latency actions 3/4/6/7, `a-743` topic-tags spec,
  `c-716` nightly reflection, `c-298`/`c-625` Reporting Taxes tab) touch none of the 10
  paths (panel N3 also found 0 owning lanes at 19:44:40Z). No live lane owns any of the
  10 paths; the holder re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, re-checked at
  2026-11-25T20:00:32Z): 7 queued, 0 placing:
  - `6b14cdc6` (`c002-refactor-reserve-reads-box-gh-credential`, refactor, reflection
    2026-11-25 SPL-6532; panel N4): brief read on this box — touches
    `orc:src/bash/run/spl-tenant-host-reserve.func.sh`, `do_spl_private_overlay_install_cron`,
    and spec 158 / reserve doc; 0 overlap with r02's 10 paths.
  - `deb08462` (`c002-b47-01-api-mcp-harness-scrub-spool-env`, bug): `csi-spl-api`
    `internal/mcp/{mcp_test.go,topic_pdf_test.go}`; 0 overlap.
  - `8dc4c754` (`c002-b47-02-orc-dispatch-hum-skip-note-to-self`, bug):
    `orc:src/bash/run/spl-dispatch-subscribe.func.sh` and
    `orc:src/bash/tests/dispatch-inbound-pg.tst.sh`; 0 overlap.
  - `8a1d4064` (`c002-b47-03-orc-pin-hold-weekly-quota`, bug):
    `orc:src/bash/run/spl-spawn-place.func.sh` and
    `orc:src/bash/tests/spl-spawn-queue.tst.sh`; 0 overlap.
  - `5b1b7d82` (`c001-s186-m9-n2-qto-sync`, feature), `bf4cec9a` (blog edit, feature),
    and `ec5462db` (`c002-wui-notes-delete-key-selected`, feature); 0 overlap.
  None touches any of the 10 paths.
- **Unlanded rows from r01:** **0** (`r01-01` landed `e108142e8`, `r01-02` landed
  `3582fc44b` at 2026-11-25T19:09:45Z, and round 01 closed at `cd8cd4cec`).
- **Briefs on this box** changed in the last 24 h matching any of the 10 paths (re-checked
  at 20:03:23Z): **0 briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, re-checked at
  20:02:23Z over every recent remote-tracking ref in the planner box's fetch; panel N6
  also checked the other box's fetch at 20:10:40Z):
  `git diff --name-only $(git merge-base c567245fa <b>) <b> -- <the 10 paths>` -> **0 hits**.
- **Commits in the last 24 h** on the 5 `.func.sh` paths (`git log origin/master --since='24 hours ago'`,
  re-checked on `5fdfae32b` at 20:03:23Z) -> **0**.

## 3. Per row: what the lane does

- **r02-01:** `orc:src/bash/run/spl-msg-move.func.sh` inserts `_spl_desk_move_prep`
  (setting documented process globals `SPL_MOVE_DIR` and `SPL_MOVE_DRY_DONE`) and
  `_spl_desk_move_json` before `# _spl_msg_move_why` (`:82`), replacing `:50-60` and
  `:70-78` with calls to them; `orc:src/bash/run/spl-topic-move.func.sh` lazy-sources
  sibling `spl-msg-move.func.sh` behind a `declare -F _spl_desk_move_prep` guard and
  replaces `:47-57` and `:76-84` with calls to `_spl_desk_move_prep` and
  `_spl_desk_move_json`. `orc:src/bash/tests/spl-msg-move.tst.sh` appends section 6 (4
  direct `_spl_desk_move_prep` checks, 2 direct `_spl_desk_move_json` checks, 1 one-copy
  check); `orc:src/bash/tests/spl-topic-move.tst.sh` appends section 6 (1 top-level JSON
  key check, 1 one-copy check, 1 standalone lazy-load check).
- **r02-02:** `orc:src/bash/run/setup-box-stats-cron.func.sh` removes unused `current`
  from `local` (`:43`) and replaces `:59-94` with the verbatim 1.4 block (call to
  `_spl_simple_cron_apply`, closing `}`, and `_spl_simple_cron_apply` definition);
  `orc:src/bash/run/check-disk-headroom-install-cron.func.sh` and
  `orc:src/bash/run/setup-go-cache-prune-cron.func.sh` each remove unused `current` from
  `local` (`:41`), lazy-source sibling `setup-box-stats-cron.func.sh` behind a
  `declare -F _spl_simple_cron_apply` guard inside their action function, and replace
  `:57-91` with a call to `_spl_simple_cron_apply`.
  `orc:src/bash/tests/box-stats-cron.tst.sh` appends section 4 (2 exact-message checks,
  1 direct `_spl_simple_cron_apply` round-trip check, 3 one-copy checks, and 2 standalone
  lazy-load checks covering both siblings).

## 4. Panel and reviewers (R7)

- Editor: **a-712** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-646**
  (live on the other box; seat file `csi-spl-doc/doc/md/refactor-round-02/seat-claude.md`
  on `review/c002-refactor-round-02-claude-seat` @ `a417282da`; confirmed W1/W2 fixed on
  v0.2 `74b11a3b5` and returned FAIL for W3 only (the `:59-93` vs `:59-94` range on
  `setup-box-stats-cron.func.sh`); now pending re-review of v0.3 on
  `review/c002-refactor-round-02-planner`). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-25T19:03:19Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `kinds off grok,qwen`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 19:04:09Z (`main=agy backup=claude`; mistral sits on no review), R7 review of a
    claude coding row goes to an **agy seat** per row (claude waiver backup only while agy
    is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 19:03:31Z picked an available box; the
    holder re-checks agy capacity at row placement and uses the claude waiver backup only
    if agy is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r02-01 | `c002-r02-01-orc-desk-move-common` | `refactor(r02-01-orc-desk-move-common, SPL-<row issue>): ...` | `review/r02-01` | 1 |
| r02-02 | `c002-r02-02-orc-simple-cron-install` | `refactor(r02-02-orc-simple-cron-install, SPL-<row issue>): ...` | `review/r02-02` | 1 |

**r02-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-msg-move.func.sh` (insert `_spl_desk_move_prep` and
`_spl_desk_move_json` before `# _spl_msg_move_why` `:82`, documenting process globals
`SPL_MOVE_DIR` and `SPL_MOVE_DRY_DONE`; replace `:50-60` and `:70-78` with calls to them),
`csi-spl-orc/src/bash/run/spl-topic-move.func.sh` (lazy-source sibling
`spl-msg-move.func.sh` behind a `declare -F _spl_desk_move_prep` guard and replace
`:47-57` and `:76-84` with calls to `_spl_desk_move_prep` and `_spl_desk_move_json`),
`csi-spl-orc/src/bash/tests/spl-msg-move.tst.sh` (append section 6 before `:74`: 4 direct
`_spl_desk_move_prep` checks, 2 direct `_spl_desk_move_json` checks, 1 one-copy check),
and `csi-spl-orc/src/bash/tests/spl-topic-move.tst.sh` (append section 6 before `:71`: 1
top-level JSON key check, 1 one-copy check, 1 standalone lazy-load check). NOT
`spl-topic-copy-cross.func.sh`, NOT `.shellcheck-warning-baseline.txt`, or any other file.
Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3); red controls
(`rc1a` + `rc1b`, head's tests on parent) RED then GREEN in the body; guard control
(`gc1`, `declare -F _spl_desk_move_prep` deleted in `spl-topic-move.func.sh`, built in a
worktree, not a temp-dir copy; proves standalone-source path outside `./run`); mutations
`m1a` / `m1b` caught by section 4 + section 6 JSON key checks. Gates: the row's tests
(section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota, valid
only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude
backup is used; never mistral; re-checked at placement).

**r02-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/setup-box-stats-cron.func.sh` (drop unused `current` at `:43`
and replace `:59-94` with the verbatim 1.4 block: call, closing `}`, and
`_spl_simple_cron_apply`),
`csi-spl-orc/src/bash/run/check-disk-headroom-install-cron.func.sh` (drop unused `current`
at `:41`, lazy-source sibling `setup-box-stats-cron.func.sh` behind a
`declare -F _spl_simple_cron_apply` guard inside `do_check_disk_headroom_install_cron`,
and replace `:57-91` with a call to `_spl_simple_cron_apply`),
`csi-spl-orc/src/bash/run/setup-go-cache-prune-cron.func.sh` (drop unused `current` at
`:41`, lazy-source sibling `setup-box-stats-cron.func.sh` behind a
`declare -F _spl_simple_cron_apply` guard inside `do_setup_go_cache_prune_cron`, and
replace `:57-91` with a call to `_spl_simple_cron_apply`), and
`csi-spl-orc/src/bash/tests/box-stats-cron.tst.sh` (append section 4 before `:219`: 2
exact-message checks, 1 direct `_spl_simple_cron_apply` round-trip check, 3 one-copy
checks, and 2 standalone lazy-load checks for both siblings). NOT
`check-disk-headroom.tst.sh`, NOT `prune-go-build-cache.tst.sh`, NOT
`lib/bash/funcs/spl-desk-cron-checkout.func.sh`, NOT `spl-desk-install-service.func.sh`,
NOT `.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02
verbatim, 1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head's
`box-stats-cron.tst.sh` on parent) RED then GREEN in the body; guard controls (`gc2a` and
`gc2b`, `declare -F _spl_simple_cron_apply` deleted in each sibling, built in worktrees);
mutations `m2a`/`m2b`/`m2c` caught by section 4. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota, valid
only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude
backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the desk-move prep and JSON summary blocks (1.3) | 2 on `c567245fa` (`spl-msg-move`, `spl-topic-move`) -> 1 (`_spl_desk_move_prep`, `_spl_desk_move_json`) after row 01 |
| copies of the periodic cron check/dry-run/remove/install block (1.4) | 3 on `c567245fa` (`setup-box-stats-cron`, `check-disk-headroom-install-cron`, `setup-go-cache-prune-cron`) -> 1 (`_spl_simple_cron_apply`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-msg-move.func.sh` +35 -15, `spl-topic-move.func.sh` +7 -20, `spl-msg-move.tst.sh` +50 -0 (49-line hunk + 1 trailing blank line), `spl-topic-move.tst.sh` +18 -0 (17-line hunk + 1 trailing blank line); row 02: `setup-box-stats-cron.func.sh` +16 -5, `check-disk-headroom-install-cron.func.sh` +6 -36, `setup-go-cache-prune-cron.func.sh` +5 -36, `box-stats-cron.tst.sh` +54 -0 (53-line hunk + 1 trailing blank line) |
| measured on | `c567245fa` (zero drift on all 10 row/test files to `5fdfae32b`); n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-hub-{agent-kinds,runner-cpu}.func.sh` (`ORDERED_BY`/`ORDERED_VIA`/`spl_dry_run` write-mode guard, `:30-32,40` vs `:29-31,39` on `5fdfae32b`) | candidate for `r03`: `r01-02` (`3582fc44b`) landed at 19:09:45Z (after r02's `c567245fa` baseline; round 01 closed `cd8cd4cec`), leaving the write-mode guard intact on `origin/master`; deferred to `r03` because r02 already carries 2 full, verified rows on `c567245fa` (rulebook 5.1) | `git show 5fdfae32b`, `git show --stat 3582fc44b` (1.2 (a), 2.2) |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line tenant/dry-run/confirm/pin/backup preflight) | strong candidate for `r03`, unchanged since r01 (`138` / `100` lines), but `msg-dedup.tst.sh` and `msg-wipe.tst.sh` build `cmd/spool` and run against throwaway `postgres:16-alpine` containers (heavy PG R2 gate) | `git diff fe1f82671 c567245fa` (empty), r01 7 |
| `orc:src/bash/run/spl-box-restart-install-cron.func.sh` / `spl-peer-crons.func.sh` and `spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` | candidates for `r03`+ (the 5 probe actions touch 5+ files); unchanged since r01 | `git diff fe1f82671 c567245fa` (empty), r01 7 |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop, `:71-82`, `:89-100`) | passes `-K "${cfg}/auth.curl"` (Bearer access token file); kept out while non-secret `orc` duplicates remain; unchanged since r01 | `git diff fe1f82671 c567245fa` (empty), r01 7 |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh` (`AGENT_BOX` + `AGENTS` validation/dedup) | `dispatch-inbound-pg.tst.sh:141` directly sources `spl-channel-agent-add-op.func.sh`, pulling a PostgreSQL test into R2; unchanged since r01 | `git diff fe1f82671 c567245fa` (empty), r01 7 |
| `orc:src/bash/run/{spl-accepted-close,spl-desk-poll-ack,spl-review-go}.func.sh` (`_spl_*_holder`) | moving the helper to `spl-dispatch-lease.func.sh` pulls 30+ tests (incl. PG) into R2; unchanged since r01 | `git diff fe1f82671 c567245fa` (empty), r01 7 |
| `orc:src/bash/run/spl-hub-box-band.func.sh:110-123`, `orc:src/bash/run/spl-wui-perf-report.func.sh:69-75`, `csi-spl-utl/**`, secret-class sites (`spl-lane-handover*`, `spl-release-note-bans-*`, `spl-secret-*`, `iac` GH repo parsers), `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, remaining r91..r01 non-framework groups, and candidates-file non-refactor / already-served items | unchanged on `c567245fa`; each stays out for its r01/r99..r91 section 7 reason | r01 7; 1.2 (a), (c) |

## 8. Changes

- v0.1 (a-712): the rows and every read on `c567245fa` (zero drift on all 10 row/test
  files to `1a8c1ce1c`); both heads built in detached scratch worktrees; the 13-suite
  column of 1.5 run on base and each row's head; `shellcheck -S warning -x` and
  `do_sec_shellcheck` rc 0; all 6 red and guard controls (`rc1a`, `rc1b`, `gc1`, `rc2`,
  `gc2a`, `gc2b`) and all 5 mutation checks (`m1a`, `m1b`, `m2a`, `m2b`, `m2c`) run on
  detached worktrees and verified RED; both helper blocks and all three test hunks
  included verbatim in 1.3 and 1.4. Pushed as `16c335852` on
  `review/c002-refactor-round-02-planner`.
- v0.2 (a-712): folded panel `c-646` (claude) FAIL findings (`1f6bbf51`, seat file
  `a31cf4054`) and holder `c-002` send-back (`19038e62`) on `16c335852`:
  - **W1** (1.3, 1.4, 6): re-measured all 8 head files on `c567245fa` directly from the
    verbatim hunks; fixed the 3 test-file line counts, numstats (including the trailing
    blank line), and sha256s: `spl-msg-move.tst.sh` 75 -> 125 (`+50 -0`: 49-line hunk + 1
    blank) `5b907bd5d703`, `spl-topic-move.tst.sh` 72 -> 90 (`+18 -0`: 17-line hunk + 1
    blank) `1a42b8064d83`, `box-stats-cron.tst.sh` 221 -> 275 (`+54 -0`: 53-line hunk + 1
    blank) `c880d0a28021`. All 5 `.func.sh` sha256s and numstats re-verified identical.
  - **W2** (intro, 1.1, 1.2, 2.2, 7): recorded `r01-02` `3582fc44b` landed at 19:09:45Z
    and round 01 closed at `cd8cd4cec`; restated section 7's `r03` deferral reason for
    `spl-hub-{agent-kinds,runner-cpu}.func.sh` with line numbers re-verified on `5fdfae32b`
    (keeping `Window: W=2026-11-25T18:51:33+02:00` fixed per rulebook 5.3).
  - **N1** (1.4, 2): unified every row 02 cron line range to the 35-line body form
    `:59-93` / `:57-91` (dropping `:59-94` / `:57-92` and the trailing unchanged `}` from
    the two sibling hunks).
  - **N2** (1.5): noted that suites and controls belong in a git worktree because
    `no-literal-paths.tst.sh` reads `1/13/2` (`STALE`) in a plain `git archive` export.
  - **N3/N4** (2.2): refreshed R3 on `origin/master` `5fdfae32b` (0 drift on all 10
    row/test files, 0 hits across remote refs of the last 24 h, fresh 20:01Z lane map)
    and added all 7 currently queued rows including `6b14cdc6`
    (`c002-refactor-reserve-reads-box-gh-credential`, brief read on this box, 0 overlap).
  - **N5**: noted panel's check of all 10 r01 section 7 items (`c002-next-round-candidates.md`
    lives on the planner's box; no `r02` block).
  Pushed as `74b11a3b5` on `review/c002-refactor-round-02-planner`.
- v0.3 (a-712): folded panel `c-646` (claude) FAIL finding W3 and N6 (`8b026fcd`, seat
  file `a417282da`) and holder `c-002` send-back (`b113f60b`) on `74b11a3b5` (zero block
  bytes changed):
  - **W3** (1.4, 2, 3, 5): restored `setup-box-stats-cron.func.sh`'s replacement range to
    `:59-94` (its 47-line verbatim block brings `do_setup_box_stats_cron`'s closing `}` on
    line 4 and defines `_spl_simple_cron_apply` after it), keeping the two siblings at
    `:57-91` (preserving `:92`'s closing `}`). Literally rebuilt from v0.3: `setup-box-stats-cron.func.sh`
    105 lines `2b1f19013437` (`bash -n` rc 0), `check-disk-headroom-install-cron.func.sh`
    62 lines `6106f57f2059` (`bash -n` rc 0), `setup-go-cache-prune-cron.func.sh` 61 lines
    `7e4e89ea9bd4` (`bash -n` rc 0).
  - **N6** (2.2, 8): dropped the box-local remote-tracking ref count (0 hits on the 10
    paths in both the planner box's 20:02:23Z check and the panel box's 20:10:40Z check).
  Pending panel `c-646` re-review on `review/c002-refactor-round-02-planner`.
