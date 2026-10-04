#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_dist_hygiene predicts the 10 ci "distribution-hygiene" job
#          from a lane's own checkout, by running the workflow's OWN Sweep step
#          (extracted with yq) over a tracked-file export of the tree.
#   1. a clean throwaway checkout -> rc 0
#   2. a planted banned literal   -> rc 1, and the output names file:line
#   3. the planted literal in an UNTRACKED file -> rc 0
#      (actions/checkout never sees it; a gate that failed here would cry wolf)
#   CONTROLS -- the check cannot pass vacuously:
#     a. the action reads the GIVEN workflow's patterns, not a copy: a pattern
#        that exists only in a doctored workflow still fails the tree
#     b. a Sweep step stripped of its allow-list is REFUSED, not passed
#     c. a workflow with no Sweep step at all is REFUSED, not passed
#     d. a tree that is not a git checkout is REFUSED, not passed
#   The banned literal is assembled at run time, so this file carries none.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-dist-hygiene.func.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it: src/bash/run/$(basename "$FUNC")" \
  || { echo "FAIL: no $FUNC"; exit 1; }
[[ -f "$WF" ]] || { echo "FAIL: no workflow at $WF"; exit 1; }

# check <tree> <workflow> -> rc; combined output in $T/out
check() {
  env HYGIENE_TREE="$1" HYGIENE_WORKFLOW="$2" APP_PATH="$1" bash -c '
    do_log() { echo "$*"; }
    source "'"$FUNC"'"
    do_check_dist_hygiene' >"$T/out" 2>&1
}

# a throwaway checkout with one tracked, clean file
mk_tree() {
  local d="$1"
  mkdir -p "$d" && git -C "$d" init -q
  printf 'a generic line with no banned literal\n' >"$d/README.md"
  git -C "$d" add README.md
}

# --- 1. clean tree ------------------------------------------------------------
mk_tree "$T/clean"
check "$T/clean" "$WF"; rc=$?
[[ $rc -eq 0 ]] && pass "a clean checkout passes (rc 0)" || { fail "a clean checkout did NOT pass (rc=$rc)"; sed 's/^/    | /' "$T/out"; }

# --- 2. planted banned literal ------------------------------------------------
# "y""sg" is the OS user the sweep bans as \bysg\b (the product name ysg-box is
# allowed); assembled here so this test file is not itself a hit.
banned="y""sg"
cp -a "$T/clean" "$T/dirty"
printf 'run it as %s on the box\n' "$banned" >"$T/dirty/notes.md"
git -C "$T/dirty" add notes.md
check "$T/dirty" "$WF"; rc=$?
if [[ $rc -ne 0 ]] && grep -q '\./notes\.md:1' "$T/out"; then
  pass "a planted banned literal fails (rc=$rc) and names file:line: $(grep -o '\./notes\.md:1' "$T/out" | sed -n 1p)"
else
  fail "a planted banned literal did NOT fail with a file:line (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi

# --- 3. the same literal, untracked -------------------------------------------
cp -a "$T/clean" "$T/untracked"
printf 'run it as %s on the box\n' "$banned" >"$T/untracked/scratch.md"   # never git-added
check "$T/untracked" "$WF"; rc=$?
[[ $rc -eq 0 ]] && pass "an UNTRACKED file is not swept (rc 0) -- actions/checkout never sees it" \
  || { fail "an untracked file failed the check (rc=$rc) -- the gate would cry wolf"; sed 's/^/    | /' "$T/out"; }

# --- CONTROL a. the patterns come from the workflow given, not from a copy -----
# A doctored copy of the workflow bans a token the real one does not. Same tree,
# two workflows, two verdicts => the action reads the sweep it is given.
yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$WF" >"$T/body.sh"
printf 'jobs:\n  distribution-hygiene:\n    steps:\n      - name: Sweep\n        run: placeholder\n' >"$T/skel.yml"
doctor() { # doctor <sed-script> <out.yml>
  sed "$1" "$T/body.sh" >"$T/body-doctored.sh"
  BODY=$(cat "$T/body-doctored.sh") yq '.jobs."distribution-hygiene".steps[0].run = strenv(BODY)' "$T/skel.yml" >"$2"
}
token="zzq-control-token-$$"
doctor "s|^exit \"\\\$fail\"\$|sweep \"control pattern\" '$token'\nexit \"\$fail\"|" "$T/wf-extra.yml"
if grep -q "$token" "$T/wf-extra.yml"; then
  cp -a "$T/clean" "$T/ctl-a"
  printf 'a harmless line carrying %s\n' "$token" >"$T/ctl-a/token.md"
  git -C "$T/ctl-a" add token.md
  check "$T/ctl-a" "$WF"; rc_real=$?
  check "$T/ctl-a" "$T/wf-extra.yml"; rc_extra=$?
  if [[ $rc_real -eq 0 && $rc_extra -ne 0 ]]; then
    pass "CONTROL a. a pattern that exists only in the given workflow fails the tree (real rc 0, doctored rc $rc_extra) -- the sweep is read, not copied"
  else
    fail "CONTROL a. the action did not follow the given workflow's patterns (real rc=$rc_real, doctored rc=$rc_extra)"
    sed 's/^/    | /' "$T/out"
  fi
else
  fail "CONTROL a. could not doctor a copy of the workflow (no token in the rendered yml)"
fi

# --- CONTROL b. a Sweep step stripped of its allow-list is refused -------------
doctor 's|allow_line=|NOT_THE_ALLOW_LIST=|' "$T/wf-noallow.yml"
check "$T/clean" "$T/wf-noallow.yml"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'proved nothing' "$T/out"; then
  pass "CONTROL b. a Sweep step without its allow-list is REFUSED (rc=$rc), not passed"
else
  fail "CONTROL b. a Sweep step without its allow-list was not refused (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi

# --- CONTROL c. no Sweep step at all ------------------------------------------
printf 'name: empty\non: {}\njobs: {}\n' >"$T/wf-empty.yml"
check "$T/clean" "$T/wf-empty.yml"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'proved nothing' "$T/out"; then
  pass "CONTROL c. a workflow with no Sweep step is REFUSED (rc=$rc), not passed"
else
  fail "CONTROL c. a workflow with no Sweep step was not refused (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi

# --- CONTROL d. not a git checkout --------------------------------------------
mkdir -p "$T/nogit"
check "$T/nogit" "$WF"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'not a git checkout' "$T/out"; then
  pass "CONTROL d. a tree that is not a git checkout is REFUSED (rc=$rc), not passed"
else
  fail "CONTROL d. a non-checkout was not refused (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi

if [[ $fails -eq 0 ]]; then
  echo "PASS: all check-dist-hygiene.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in check-dist-hygiene.tst.sh"
fi
[[ $fails -eq 0 ]]
