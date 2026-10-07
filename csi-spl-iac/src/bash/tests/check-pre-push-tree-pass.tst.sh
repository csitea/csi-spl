#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the tree-pass record (fleet-hot-commands 3.2): the pre-push hook
#          (PRE_PUSH_SKIP_PASSED=1) skips a whole gate run when this exact
#          clean tree, parts set, tier, merge-base and gate code already passed
#          whole -- and runs as before in every other case. Counted on the
#          hygiene part, which has no verdict cache and so runs on every gate
#          run that is not skipped. STUB parts (pass iff <tree>/<dir>/flag says
#          'good'), so nothing heavy runs.
#     1. same tree passed by hand -> the hook run skips (0 runs, PART tree PASS-tree)
#        ... an advisory WARN (release-note, typos) still records the pass
#        CONTROL: without PRE_PUSH_SKIP_PASSED the same tree runs again
#     2. one byte changed and committed -> runs
#        ... uncommitted (dirty tree) -> runs, and records nothing
#     3. a failed run -> records nothing; the hook run runs (and fails)
#     4. an override run (PRE_PUSH_ONLY=override) -> records nothing
#        ... nor a lint-only run, PRE_PUSH_LINT=0, nor a WARN-pre-existing pass
#     5. the gate's own code changed -> runs
#     6. a part that rewrites the tree during the run -> records nothing
#     7. PRE_PUSH_NO_CACHE=1 -> runs
#     8. the knobs never reach a part's processes (the iac suite runs this gate
#        in its own tests), and the record defaults to beside PRE_PUSH_CACHE
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$(cd "$TEST_DIR/../run" && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# A private copy of the gate's code, so case 5 can change it.
GD="$ROOT/gate"; mkdir -p "$GD"
cp "$RUN_DIR/check-pre-push.func.sh" "$RUN_DIR/check-pre-push-lint.func.sh" "$RUN_DIR/check-release-note.func.sh" "$GD/"
FUNC="$GD/check-pre-push.func.sh"

HYG="$ROOT/hygiene.runs"
R="$ROOT/repo"; LOG="$ROOT/pp.log"; CACHE="$ROOT/parts.green"; PASSF="$ROOT/tree.pass"
git init -q "$R"
for d in csi-spl-api csi-spl-iac csi-spl-orc; do mkdir -p "$R/$d"; echo good >"$R/$d/flag"; done
git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch trunk; git -C "$R" checkout -q -b lane
echo x >"$R/csi-spl-iac/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm "lane: iac"

# One gate run in a fresh shell (as ./run does). Stubs: hygiene counts, iac/api
# pass iff their flag is good, MUTATE=1 makes iac rewrite a tracked file, no
# lint parts, no tool preflight; RN_WARN=1 adds the advisory release-note WARN.
gate() {  # [env...] -> rc; this run's verdict lines in $LOG
  : >"$LOG"
  ( env "$@" PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" PRE_PUSH_CACHE="$CACHE" \
      PRE_PUSH_PASS="$PASSF" PRE_PUSH_EXTRA_PATH='' HYG="$HYG" \
      bash -c '. "$0"
        do_log() { :; }
        do_check_dist_hygiene() { echo x >>"$HYG"; }
        _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }
        _pp_release_note() { [ "${RN_WARN:-0}" = 1 ] && _pp_record "release-note (WARN only)" WARN 0; return 0; }
        _pp_part_iac() { [ -n "${SEEN:-}" ] && bash -c '"'"'echo "${PRE_PUSH_SKIP_PASSED-unset} ${PRE_PUSH_PASS-unset}"'"'"' >"$SEEN"
          [ "${MUTATE:-0}" = 1 ] && echo m >>"$1/csi-spl-iac/flag"; grep -q good "$1/csi-spl-iac/flag"; }
        _pp_part_api() { grep -q good "$1/csi-spl-api/flag" || { echo "FAIL: api flag is not good"; return 1; }; }
        do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
}
hook() { gate PRE_PUSH_SKIP_PASSED=1 "$@"; }
runs() { wc -l <"$HYG" 2>/dev/null | tr -d ' '; }
skipped() { grep -q ' PART tree PASS-tree ' "$LOG" && echo yes || echo no; }
recs() { wc -l <"$PASSF" 2>/dev/null | tr -d ' ' || echo 0; }

# 1. a manual pass, then the hook on the same tree
: >"$HYG"; gate RN_WARN=1; eq "1. manual run passes (with an advisory release-note WARN)" 0 "$?"
eq "1. ... and records the tree pass (an advisory WARN is not a red)" 1 "$(recs)"
: >"$HYG"; hook; eq "1. hook on the same tree -> passes" 0 "$?"
eq "1. ... without running any part (hygiene runs)" 0 "$(runs)"
eq "1. ... logged PART tree PASS-tree" yes "$(skipped)"
: >"$HYG"; gate; eq "1. CONTROL: without PRE_PUSH_SKIP_PASSED the same tree runs again" 1 "$(runs)"
eq "1. CONTROL: ... and is not logged as skipped" no "$(skipped)"

# 2. one byte changed
echo y >>"$R/csi-spl-iac/a.sh"; git -C "$R" commit -qam "one byte"
: >"$HYG"; hook; eq "2. one byte changed (committed) -> hook runs" 1 "$(runs)"
eq "2. ... not skipped" no "$(skipped)"
: >"$HYG"; hook; eq "2. ... and that hook pass now vouches for the new tree" 0 "$(runs)"
n0="$(recs)"; echo z >>"$R/csi-spl-iac/a.sh"
: >"$HYG"; hook; eq "2. one byte changed, uncommitted (dirty) -> hook runs" 1 "$(runs)"
eq "2. ... and a dirty tree records nothing" "$n0" "$(recs)"
git -C "$R" checkout -q -- csi-spl-iac/a.sh

# 3. a failed run
echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "break api"
n0="$(recs)"; gate; eq "3. a failing run -> rc 1" 1 "$?"
eq "3. ... records nothing" "$n0" "$(recs)"
: >"$HYG"; hook; eq "3. the hook run on that tree -> runs and fails" "1 1" "$? $(runs)"
echo good >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "fix api"

# 4. partial runs never vouch for the whole tree
n0="$(recs)"
gate PRE_PUSH_ONLY=override; eq "4. override run passes" 0 "$?"
eq "4. ... records nothing" "$n0" "$(recs)"
gate PRE_PUSH_ONLY=lint; eq "4. lint-only run records nothing" "$n0" "$(recs)"
gate PRE_PUSH_LINT=0; eq "4. PRE_PUSH_LINT=0 run records nothing" "$n0" "$(recs)"
gate PRE_PUSH_LINT_ONLY=lint-migration; eq "4. PRE_PUSH_LINT_ONLY run records nothing" "$n0" "$(recs)"
: >"$HYG"; hook PRE_PUSH_NO_CACHE=1; eq "4. after the override etc., the hook still runs" 1 "$(runs)"
# a WARN-pre-existing pass: api red on trunk AND on the lane, same failure
git -C "$R" checkout -q trunk; echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "trunk red"
git -C "$R" checkout -q lane; git -C "$R" merge -q --no-edit trunk
echo t >"$R/csi-spl-api/touch.go"; git -C "$R" add -A; git -C "$R" commit -qm "touch api"
n0="$(recs)"; gate; eq "4. a WARN-pre-existing pass -> rc 0" 0 "$?"
grep -q ' PART api WARN-pre-existing ' "$LOG" && pass "4. ... (setup) api logged WARN-pre-existing" \
  || fail "4. ... (setup) api logged WARN-pre-existing" "$(cat "$LOG")"
eq "4. ... records nothing" "$n0" "$(recs)"
git -C "$R" checkout -q trunk; echo good >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "trunk green"
git -C "$R" checkout -q lane; git -C "$R" merge -q --no-edit trunk

# 5. the gate's own code changed
gate; : >"$HYG"; hook; eq "5. (setup) the hook skips a passed tree" 0 "$(runs)"
echo '# a gate change' >>"$GD/check-pre-push-lint.func.sh"
: >"$HYG"; hook; eq "5. gate code changed -> hook runs" 1 "$(runs)"
eq "5. ... not skipped" no "$(skipped)"

# 6. a part that rewrites the tree during the run
echo w >"$R/csi-spl-iac/b.sh"; git -C "$R" add -A; git -C "$R" commit -qm "iac again"
n0="$(recs)"; gate MUTATE=1; eq "6. a run whose part rewrites the tree records nothing" "$n0" "$(recs)"
git -C "$R" checkout -q -- csi-spl-iac/flag

# 7. PRE_PUSH_NO_CACHE=1 ignores the record
gate; : >"$HYG"; hook PRE_PUSH_NO_CACHE=1; eq "7. PRE_PUSH_NO_CACHE=1 -> hook runs" 1 "$(runs)"

# 8. no leak into the parts; default record path
echo v >"$R/csi-spl-iac/c.sh"; git -C "$R" add -A; git -C "$R" commit -qm "iac 8"
hook SEEN="$ROOT/seen8" PRE_PUSH_NO_CACHE=1
eq "8. a part's child sees neither PRE_PUSH_SKIP_PASSED nor PRE_PUSH_PASS" "unset unset" "$(cat "$ROOT/seen8" 2>/dev/null)"
( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" PRE_PUSH_CACHE="$ROOT/c8/parts.green" PRE_PUSH_EXTRA_PATH='' HYG="$HYG" \
    XDG_CACHE_HOME="$ROOT/xdg8" bash -c '. "$0"; do_log() { :; }; do_check_dist_hygiene() { :; }
      _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }; _pp_release_note() { :; }
      _pp_part_iac() { :; }; _pp_part_api() { :; }; do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
[ -s "$ROOT/c8/pre-push.tree.pass" ] && [ ! -e "$ROOT/xdg8/csi-spl/pre-push.tree.pass" ] \
  && pass "8. the record defaults to beside PRE_PUSH_CACHE, not the user cache" \
  || fail "8. the record defaults to beside PRE_PUSH_CACHE" "$(find "$ROOT/c8" "$ROOT/xdg8" -type f 2>/dev/null)"

echo "-- check-pre-push-tree-pass.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
