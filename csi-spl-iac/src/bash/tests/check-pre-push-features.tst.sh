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
#      that only appears inside a longer word select nothing
#   3. _ppf_parts adds the part only when a feature is selected; FULL tier =
#      every feature; PRE_PUSH_FEATURES=0 never selects it
#   4. the part runs only the selected features present in the tree, with
#      the agent's SPOOL_* env dropped and a TMPDIR short enough for tmux
#   5. a red file fails the part and prints FAILED: <feature>/<file>; a
#      feature absent in the tree (new in the push) runs nothing and passes
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
do_log() { :; }
_pp_timeout=60
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

echo "-- check-pre-push-features.tst.sh: $fails failed"
[[ "$fails" -eq 0 ]]
