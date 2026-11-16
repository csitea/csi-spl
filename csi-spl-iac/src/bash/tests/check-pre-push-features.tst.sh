#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push part orc-features (spec 133 F1, CI-refactor round 3)
#          maps a csi-spl-orc change to the features whose tests it touches
#          and runs features/run-ci-tests.sh for them. Hermetic: a throwaway
#          tree whose run-ci-tests.sh is a stub that records its arguments
#          and env, and fails a file when the tree says so.
#   1. a file under features/<f>/ selects <f>; a file directly under
#      features/ (the runner, ci-skip.txt) selects every feature
#   2. another orc file selects the features whose tests name its basename
#      or its stem; CONTROL: a .md, a file outside csi-spl-orc, and a name
#      that only appears inside a longer word select nothing; a path that
#      selects nothing, even the last one, is no error (exit 0), an
#      undiffable FEATURES_RANGE or an unreadable feature test still is
#      (SPL-5651)
#   3. _ppf_parts adds the part only when a feature is selected; FULL tier =
#      every feature; PRE_PUSH_FEATURES=0 never selects it
#   4. the part runs only the selected features present in the tree, with
#      the agent's SPOOL_* env dropped and a TMPDIR short enough for tmux
#   5. a red file fails the part and prints FAILED: <feature>/<file>; a
#      feature absent in the tree (new in the push) runs nothing and passes
#   6. the REAL runner under a part budget that runs out: the part fails
#      (rc 124) and names each file still running as FAILED: <feature>/<file>
#      (still running at the timeout), never a file that finished (a full-tier
#      run on a loaded sat TIMED OUT naming nothing, c-981, n=1)
#------------------------------------------------------------------------------
set -uo pipefail
unset PRE_PUSH_NO_CACHE PRE_PUSH_MODE PRE_PUSH_SKIP_PASSED PRE_PUSH_ONLY PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_CROSS PRE_PUSH_E2E PRE_PUSH_FEATURES 2>/dev/null || true  # SPL-5063: the caller's gate switches must not change these verdicts; a case sets its own
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
export PRE_PUSH_BUDGET_CNF="$TEST_DIR/fixtures/pre-push-budgets-pre-spl5574.yaml"  # the pre-SPL-5574 values: these cases test the rule, not the measured table
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
do_log() { :; }
_pp_b_default=60
_pp_budget() { echo 60; }
# shellcheck source=../run/check-pre-push-features.func.sh
. "$PROJ_ROOT/src/bash/run/check-pre-push-features.func.sh"

T="$ROOT/tree"; F="$T/csi-spl-orc/src/bash/features"
mkdir -p "$F/alpha/tests" "$F/beta/tests" "$F/gamma" "$T/csi-spl-api/src/bash"
printf 'source run/lane-thing.func.sh\n' >"$F/alpha/tests/test-alpha.sh"
printf 'echo beta; do_spl_other\n# mentions wide-lane-thingy only\n' >"$F/beta/tests/test-beta.sh"
# the stub runner: records argv + env, fails a file named in <tree>/red
cat >"$F/run-ci-tests.sh" <<'EOF'
here=$(cd "$(dirname "$0")" && pwd)
echo "ARGS $*" >>"$here/../../../../calls"
env | grep -c '^SPOOL_' | sed 's/^/SPOOLVARS /' >>"$here/../../../../calls"
echo "TMPLEN ${#TMPDIR}" >>"$here/../../../../calls"
rc=0
for f in "$@"; do
  if grep -qx "$f" "$here/../../../../red" 2>/dev/null; then
    printf '%-55s %-11s %6.1f\n' "$f/test-$f.sh" "FAIL(rc=1)" 1.0; rc=1
  else
    printf '%-55s %-11s %6.1f\n' "$f/test-$f.sh" PASS 1.0
  fi
done
exit "$rc"
EOF

sel() { _ppf_select "$T" "$(tr ' ' '\n' <<<"$1")" | paste -sd' '; }
# 1
eq "a file under features/beta selects beta" "beta" "$(sel csi-spl-orc/src/bash/features/beta/lib.sh)"
eq "the runner selects every feature" "alpha beta" "$(sel csi-spl-orc/src/bash/features/run-ci-tests.sh)"
eq "ci-skip.txt selects every feature" "alpha beta" "$(sel csi-spl-orc/src/bash/features/ci-skip.txt)"
# 2
eq "a file the alpha tests name selects alpha" "alpha" "$(sel csi-spl-orc/src/bash/run/lane-thing.func.sh)"
eq "its stem alone selects alpha too" "alpha" "$(sel csi-spl-orc/src/bash/lib/lane-thing.sh)"
eq "CONTROL: a .md selects nothing" "" "$(sel csi-spl-orc/src/bash/features/alpha/README.md)"
eq "CONTROL: a file outside csi-spl-orc selects nothing" "" "$(sel csi-spl-wui/src/lane-thing.sh)"
eq "CONTROL: a stem only inside a longer word (do_spl_other) selects nothing" "" "$(sel csi-spl-orc/src/bash/run/other.sh)"
eq "a feature dir without tests/ selects by name only" "" "$(sel csi-spl-orc/src/bash/features/gamma/x.sh)"
eq "two changes select the union" "alpha beta" "$(sel 'csi-spl-orc/src/bash/run/lane-thing.func.sh csi-spl-orc/src/bash/features/beta/x.sh')"
# 2b (SPL-5651): a path no test names is no error, also when it comes LAST
# (under pipefail the bare grep made the action exit 1); a real failure still is
out="$(PRE_PUSH_TREE="$T" FEATURES_CHANGED="csi-spl-orc/src/bash/features/beta/x.sh csi-spl-orc/src/bash/run/other.sh" do_check_pre_push_features)"; rc=$?
eq "a last path that names no test: the action exits 0" 0 "$rc"; eq "... and still prints what the others select" "beta" "$out"
out="$(PRE_PUSH_TREE="$T" FEATURES_CHANGED="csi-spl-orc/src/bash/run/other.sh" do_check_pre_push_features)"; rc=$?
eq "a path that selects nothing: exit 0" 0 "$rc"; eq "... and prints nothing" "" "$out"
out="$(PRE_PUSH_TREE="$T" FEATURES_RANGE="no-such-ref..HEAD" do_check_pre_push_features 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "CONTROL: an undiffable FEATURES_RANGE still fails (rc=$rc)" || fail "CONTROL: an undiffable range fails" "rc=$rc"
# a feature test grep cannot read (grep rc 2) is a real failure: the
# selection may miss a feature (g-365 R7 W1)
TU="$ROOT/unreadable"; cp -r "$T" "$TU"; mkdir -p "$TU/csi-spl-orc/src/bash/features/delta/tests"
printf 'other.sh\n' >"$TU/csi-spl-orc/src/bash/features/delta/tests/test-delta.sh"
chmod 000 "$TU/csi-spl-orc/src/bash/features/delta/tests/test-delta.sh"
if [[ -r "$TU/csi-spl-orc/src/bash/features/delta/tests/test-delta.sh" ]]; then
  pass "SKIP unreadable-test case: this user reads a mode-000 file (root)"
else
  out="$(PRE_PUSH_TREE="$TU" FEATURES_CHANGED="csi-spl-orc/src/bash/run/lane-thing.func.sh" do_check_pre_push_features 2>"$ROOT/err")"; rc=$?
  [[ "$rc" -ne 0 ]] && pass "an unreadable feature test fails the action (rc=$rc)" || fail "an unreadable feature test fails the action" "rc=$rc"
  eq "... still prints what it could select" "alpha" "$out"
  grep -q 'cannot read every feature test for csi-spl-orc/src/bash/run/lane-thing.func.sh' "$ROOT/err" \
    && pass "... and says so on stderr" || fail "unreadable test named on stderr" "$(cat "$ROOT/err")"
  # SPL-5669: the gate's plan fails closed on it (before, _ppf_parts dropped
  # the rc and the plan ran only alpha): every feature runs, ERROR named
  parts="hygiene orc"; _PPF_FEATS=""
  _ppf_parts "csi-spl-orc/src/bash/run/lane-thing.func.sh" "$TU" 2>"$ROOT/err"
  eq "an unreadable feature test: the plan runs every feature" "alpha beta delta" "$(paste -sd' ' <<<"$_PPF_FEATS")"
  eq "... as the orc-features part" "hygiene orc orc-features" "$parts"
  grep -q 'ERROR orc-features: a feature test is unreadable, the part runs every feature' "$ROOT/err" \
    && pass "... and names the ERROR" || fail "plan ERROR line" "$(cat "$ROOT/err")"
  # without pipefail too (the rc comes from PIPESTATUS, not sed or sort)
  (set +o pipefail; _ppf_select "$TU" "csi-spl-orc/src/bash/run/lane-thing.func.sh" >/dev/null 2>&1); rc=$?
  [[ "$rc" -ne 0 ]] && pass "_ppf_select fails without pipefail too (rc=$rc)" || fail "_ppf_select without pipefail" "rc=$rc"
  # CONTROL: a readable no-match in the same tree keeps the narrow selection
  parts="hygiene orc"; _PPF_FEATS=""; chmod 644 "$TU/csi-spl-orc/src/bash/features/delta/tests/test-delta.sh"
  _ppf_parts "csi-spl-orc/src/bash/run/lane-thing.func.sh" "$TU" 2>"$ROOT/err"
  eq "CONTROL: readable, no match in delta: only alpha" "alpha" "$_PPF_FEATS"
  eq "CONTROL: ... and no ERROR" "" "$(cat "$ROOT/err")"
fi
chmod -R u+rwX "$TU"
TN="$ROOT/notests"; mkdir -p "$TN/csi-spl-orc/src/bash/features/gamma"
out="$(PRE_PUSH_TREE="$TN" FEATURES_CHANGED="csi-spl-orc/src/bash/run/other.sh" do_check_pre_push_features 2>&1)"; rc=$?
eq "a tree with no feature tests at all: exit 0" 0 "$rc"; eq "... and prints nothing" "" "$out"

# 3
parts="hygiene orc"; _PPF_FEATS=""; _ppf_parts "csi-spl-orc/src/bash/features/beta/x.sh" "$T"
eq "_ppf_parts adds the part" "hygiene orc orc-features" "$parts"; eq "... with its features" "beta" "$_PPF_FEATS"
parts="hygiene orc"; _ppf_parts "csi-spl-orc/README.md" "$T"
eq "_ppf_parts: nothing mapped, no part" "hygiene orc" "$parts"
parts="hygiene"; _PP_TIER=full _ppf_parts "" "$T"
eq "FULL tier: every feature" "alpha beta" "$(paste -sd' ' <<<"$_PPF_FEATS")"; eq "FULL tier: the part" "hygiene orc-features" "$parts"
parts="hygiene"; PRE_PUSH_FEATURES=0 _ppf_parts "csi-spl-orc/src/bash/features/beta/x.sh" "$T"
eq "PRE_PUSH_FEATURES=0 never selects it" "hygiene" "$parts"

# 4 + 5
_PPF_FEATS="alpha newfeat"; : >"$T/calls"
out="$(SPOOL_ROOT=/x SPOOL_BOX_TAG=y _pp_part_orc_features "$T")"; rc=$?
eq "green features pass" 0 "$rc"
eq "only the features present in the tree run" "ARGS alpha" "$(grep '^ARGS' "$T/calls")"
eq "the agent's SPOOL_* env is dropped" "SPOOLVARS 0" "$(grep '^SPOOLVARS' "$T/calls")"
len="$(sed -n 's/^TMPLEN //p' "$T/calls")"
[[ "$len" -gt 0 && "$len" -le 30 ]] && pass "TMPDIR is short ($len bytes) for tmux sockets" || fail "short TMPDIR" "got $len bytes"
echo alpha >"$T/red"
out="$(_pp_part_orc_features "$T")"; rc=$?
[[ "$rc" -ne 0 ]] && pass "a red file fails the part" || fail "a red file fails the part" "rc=$rc"
grep -qx 'FAILED: alpha/test-alpha.sh' <<<"$out" && pass "the red file is named as FAILED: alpha/test-alpha.sh" \
  || fail "FAILED line" "$out"
_PPF_FEATS="newfeat"; : >"$T/calls"
out="$(_pp_part_orc_features "$T")"; rc=$?
eq "a feature absent in the tree runs nothing" "" "$(cat "$T/calls")"; eq "... and passes" 0 "$rc"

# 6
T6="$ROOT/real"; F6="$T6/csi-spl-orc/src/bash/features"
mkdir -p "$F6/quick/tests" "$F6/slow/tests" "$T6/csi-spl-orc/src/bash/tests" "$ROOT/bin"
cp "$PROJ_ROOT/../csi-spl-orc/src/bash/features/run-ci-tests.sh" "$F6/"
printf 'exit 0\n' >"$F6/quick/tests/test-quick.sh"
printf 'sleep 30\n' >"$F6/slow/tests/test-slow.sh"
printf '#!/bin/sh\nexit 0\n' >"$ROOT/bin/tmux"; chmod +x "$ROOT/bin/tmux"
# 12 s, not 6: on a starved runner 6 s ran out before the runner set its
# TERM trap (wf 10 38693664604), so "slow is running" did not hold; 6b covers
# that case. Still well under the 30 s the slow file sleeps.
_pp_budget() { echo 12; }
_PPF_FEATS="quick slow"; s6=$SECONDS
out="$(PATH="$ROOT/bin:$PATH" _pp_part_orc_features "$T6")"; rc=$?
eq "a part that runs out of time fails with 124" 124 "$rc"
grep -qx 'FAILED: slow/test-slow.sh (still running at the timeout)' <<<"$out" \
  && pass "the file still running is named" || fail "the file still running is named" "$out"
grep -q 'FAILED: quick/' <<<"$out" && fail "CONTROL: a finished file is not named" "$out" \
  || pass "CONTROL: a finished file is not named"
(( SECONDS - s6 < 26 )) && pass "the timeout stops the run (no 30 s wait)" || fail "the timeout stops the run" "$((SECONDS - s6)) s"
# 6b: the TERM lands before the runner sets its trap (BASH_ENV runs before the
# script and sleeps past the budget; the CI shape: "runs quick slow" and
# nothing else). The part still names what it stopped.
printf 'sleep 4\n' >"$ROOT/slow-start.env"
_pp_budget() { echo 2; }
out="$(PATH="$ROOT/bin:$PATH" BASH_ENV="$ROOT/slow-start.env" _pp_part_orc_features "$T6")"; rc=$?
eq "a TERM before the runner's trap fails with 124" 124 "$rc"
grep -qx 'FAILED: run-ci-tests.sh (stopped before it named a file: quick slow)' <<<"$out" \
  && pass "a TERM before the runner's trap still names the runner and its features" || fail "a TERM before the trap names nothing" "$out"
# 7: TERM before the runner lists its files (wf 10 38537641629, a loaded
# runner: no trap yet, "Terminated", nothing named) still names one. A stale
# spool build check that sleeps holds the runner in that phase.
mkdir -p "$F6/spawn-agents/lib" "$T6/csi-spl-api/src/go/spool-hub-api/bin"
printf '_spool_bin_stale() { sleep 10; return 1; }\n' >"$F6/spawn-agents/lib/spool-env.inc.sh"
printf '#!/bin/sh\n' >"$T6/csi-spl-api/src/go/spool-hub-api/bin/spool"; chmod +x "$T6/csi-spl-api/src/go/spool-hub-api/bin/spool"
_pp_budget() { echo 2; }
out="$(PATH="$ROOT/bin:$PATH" _pp_part_orc_features "$T6")"; rc=$?
rm -rf "$F6/spawn-agents" "$T6/csi-spl-api"
eq "a timeout during the listing fails with 124" 124 "$rc"
grep -q '^FAILED: .* (still running at the timeout)$' <<<"$out" \
  && pass "a timeout during the listing still names what it stopped" || fail "a timeout during the listing names something" "$out"
_pp_budget() { echo 60; }

echo "-- check-pre-push-features.tst.sh: $fails failed"
[[ "$fails" -eq 0 ]]
