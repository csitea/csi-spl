#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_dist_hygiene predicts the 10 ci "distribution-hygiene" job
#          from a lane's own checkout, by running the workflow's OWN Sweep step
#          (extracted with yq) over a tracked-file export of the tree.
#   1. a clean throwaway checkout -> rc 0
#   2. a planted banned literal   -> rc 1, and the output names file:line
#   3. the planted literal in an UNTRACKED file -> rc 0
#      (actions/checkout never sees it; a gate that failed here would cry wolf)
#   4. spec 110 2.3: a tracked .vibe/hooks.toml (at the root or nested) -> rc 1
#      naming it; the same file untracked, or a dir merely named like it
#      (my.vibe/), -> rc 0
#   5. SPL-5585 (perf round 9 row 03): the five ASCII sweeps run under
#      LC_ALL=C -- a grep PATH shim logs the locale of each recursive call:
#      5 calls under C, the retired-relay and hidden-workspace sweeps 1 call
#      each under the locale they ran under before; a plant of one hit per
#      ASCII sweep is still reported; the named narrowing is pinned: the
#      same words spelled with U+017F / U+212A are NOT reported under C
#   CONTROLS -- the check cannot pass vacuously:
#     a. the action reads the GIVEN workflow's patterns, not a copy: a pattern
#        that exists only in a doctored workflow still fails the tree
#     b. a Sweep step stripped of its allow-list is REFUSED, not passed
#     c. a workflow with no Sweep step at all is REFUSED, not passed
#     d. a tree that is not a git checkout is REFUSED, not passed
#     e. the .vibe/ rule is the workflow's: a Sweep step with it removed lets
#        the planted .vibe/hooks.toml pass -- the action holds no second list
#     f. the step with its LC_ALL=C prefixes stripped (the step before
#        SPL-5585) makes 0 calls under C and reports the U+017F / U+212A plant
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

# --- 4. a tracked .vibe/ dir is refused (spec 110 2.3) ------------------------
for p in .vibe/hooks.toml sub/dir/.vibe/hooks.toml; do
  rm -rf "$T/vibe"; cp -a "$T/clean" "$T/vibe"
  mkdir -p "$T/vibe/$(dirname "$p")"; printf '[[pre_tool]]\ncommand = "true"\n' >"$T/vibe/$p"
  git -C "$T/vibe" add -f "$p"
  check "$T/vibe" "$WF"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qF "::error file=$p::a tracked .vibe/ file" "$T/out"; then
    pass "a tracked $p is refused (rc=$rc) and named"
  else
    fail "a tracked $p was NOT refused (rc=$rc)"; sed 's/^/    | /' "$T/out"
  fi
done
git -C "$T/vibe" rm -q --cached sub/dir/.vibe/hooks.toml
check "$T/vibe" "$WF"; rc=$?
[[ $rc -eq 0 ]] && pass "the same .vibe/hooks.toml UNTRACKED passes (rc 0)" \
  || { fail "an untracked .vibe/ failed the check (rc=$rc)"; sed 's/^/    | /' "$T/out"; }
mkdir -p "$T/vibe/my.vibe"; printf 'x\n' >"$T/vibe/my.vibe/notes.md"; git -C "$T/vibe" add my.vibe/notes.md
check "$T/vibe" "$WF"; rc=$?
[[ $rc -eq 0 ]] && pass "a dir merely named like it (my.vibe/) passes (rc 0)" \
  || { fail "my.vibe/ was refused (rc=$rc)"; sed 's/^/    | /' "$T/out"; }

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

# --- CONTROL e. the .vibe/ rule is read from the workflow, not held here ------
git -C "$T/vibe" add -f sub/dir/.vibe/hooks.toml
check "$T/vibe" "$WF"; rc_real=$?
doctor 's|^vibe=.*$|vibe=""|' "$T/wf-novibe.yml"
check "$T/vibe" "$T/wf-novibe.yml"; rc_novibe=$?
if [[ $rc_real -ne 0 && $rc_novibe -eq 0 ]]; then
  pass "CONTROL e. the .vibe/ refusal comes from the workflow's Sweep step (real rc $rc_real, rule removed rc 0) -- one list, CI's"
else
  fail "CONTROL e. the .vibe/ verdict did not follow the given workflow (real rc=$rc_real, rule removed rc=$rc_novibe)"
  sed 's/^/    | /' "$T/out"
fi

# --- 5. the five ASCII sweeps run under LC_ALL=C (SPL-5585) -------------------
# A grep shim first on PATH logs "<LC_ALL>\t<pattern>" for each recursive call
# (the sweeps' grep -rnIoP), then runs the real grep. The tree carries the
# overlay library and a synthetic overlay, so the hidden-workspace sweep runs.
real_grep=$(type -P grep)
mkdir -p "$T/shim"
printf '#!/usr/bin/env bash\n[[ "$1" == -rnIoP ]] && printf "%%s\\t%%s\\n" "${LC_ALL-<unset>}" "${*: -2:1}" >>"$GREP_LOG"\nexec %q "$@"\n' \
  "$real_grep" >"$T/shim/grep"
chmod +x "$T/shim/grep"
hidden="zq""-hidden-loc"
printf 'workspaces:\n  ws-hidden-01: %s\n' "$hidden" >"$T/overlay.yaml"
cp -a "$T/clean" "$T/loc"
mkdir -p "$T/loc/csi-spl-iac/lib/bash/funcs" "$T/loc/csi-spl-cnf/csi-spl"
cp "$PROJ_ROOT/lib/bash/funcs/spl-private-cnf.func.sh" "$T/loc/csi-spl-iac/lib/bash/funcs/"
printf 'env:\n  dns:\n    BASE_DOMAIN: example.test\n' >"$T/loc/csi-spl-cnf/csi-spl/all.env.yaml"
# one hit per ASCII sweep, assembled so this file carries none
printf '%s\n' "a ""nor""dea line" "a sand""holm line" "run as $banned" "see /ho""me/someone/x" "mail flo""k.fi" >"$T/loc/hits.md"
# the same words with s -> U+017F and k -> U+212A: the narrowing under C
printf '%b\n' 'a \xc5\xbfand''holm line' 'run as y\xc5\xbfg' 'mail flo\xe2\x84\xaa.fi' >"$T/loc/fold.md"
git -C "$T/loc" add -A
loc_check() { # loc_check <workflow> -> rc; calls logged in $T/grep.log
  : >"$T/grep.log"
  PATH="$T/shim:$PATH" GREP_LOG="$T/grep.log" SPL_PRIVATE_CNF="$T/overlay.yaml" check "$T/loc" "$1"
}
gate_loc=$(source "$PROJ_ROOT/lib/bash/funcs/spl-private-cnf.func.sh" && spl_private_gate_locale)
loc_today="${LC_ALL-<unset>}"
loc_check "$WF"; rc=$?
n_c=$(awk -F'\t' '$1 == "C"' "$T/grep.log" | wc -l)
relay_word="git""-rel"   # assembled: the retired-relay sweep would flag this file
n_relay=$(awk -F'\t' -v l="$loc_today" -v r="$relay_word" '$1 == l && index($2, r)' "$T/grep.log" | wc -l)
n_hidden=$(awk -F'\t' -v l="$gate_loc" -v h="$hidden" '$1 == l && index($2, h)' "$T/grep.log" | wc -l)
if [[ $n_c -eq 5 && $n_relay -eq 1 && $n_hidden -eq 1 ]]; then
  pass "5. the five ASCII sweeps run under C (5 calls), retired relay 1 call under '$loc_today', hidden workspace 1 call under '$gate_loc'"
else
  fail "5. locale per sweep: $n_c call(s) under C (want 5), relay $n_relay under '$loc_today' (want 1), hidden $n_hidden under '$gate_loc' (want 1)"
  sed 's/^/    | /' "$T/grep.log"
fi
missing=""
for n in 1 2 3 4 5; do grep -q "\./hits\.md:$n\$" "$T/out" || missing+=" hits.md:$n"; done
if [[ $rc -ne 0 && -z "$missing" ]]; then
  pass "5. a plant of one hit per ASCII sweep is still reported under C (rc=$rc, hits.md:1..5)"
else
  fail "5. the ASCII plant under C: rc=$rc, not reported:${missing:- none}"; sed 's/^/    | /' "$T/out"
fi
# The narrowing SPL-5585 names: under C, (?i) folds ASCII only.
if ! grep -q '\./fold\.md:' "$T/out"; then
  pass "5. the named narrowing: the U+017F / U+212A spellings (fold.md) are NOT reported under C"
else
  fail "5. fold.md was reported -- the narrowing this case pins has changed"; grep '\./fold\.md:' "$T/out" | sed 's/^/    | /'
fi

# --- CONTROL f. the step before SPL-5585: no LC_ALL=C prefix ------------------
doctor 's|^LC_ALL=C sweep |sweep |' "$T/wf-noc.yml"
loc_check "$T/wf-noc.yml"; rc=$?
n_c=$(awk -F'\t' '$1 == "C"' "$T/grep.log" | wc -l)
if [[ $n_c -eq 0 ]] && grep -q '\./fold\.md:' "$T/out"; then
  pass "CONTROL f. the prefixes stripped: 0 calls under C and the U+017F / U+212A plant IS reported (rc=$rc) -- case 5 sees the locale"
else
  fail "CONTROL f. the prefixes stripped: $n_c call(s) under C (want 0), fold.md reported: $(grep -c '\./fold\.md:' "$T/out")"
  sed 's/^/    | /' "$T/grep.log"
fi

if [[ $fails -eq 0 ]]; then
  echo "PASS: all check-dist-hygiene.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in check-dist-hygiene.tst.sh"
fi
[[ $fails -eq 0 ]]
