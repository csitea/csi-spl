#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_desk_wait_roster (spl-desk-up.func.sh) reads the roster under
#          the state dir it is GIVEN, whatever the caller calls its variable
#          (refactor round 4, row 13). Its roster path once sat in the same
#          `local` as `d="$1"`: bash expands every word of a `local` before it
#          assigns any, so that `$d` was the caller's `d` (dynamic scope). It
#          worked only because all 7 callers name their state dir `d`.
#   1. a caller whose state dir is `dir`, with an outer `d` pointing at a
#      decoy dir that has no roster: the agent announced under the given dir
#      is found, rc 0. Fails on the old one-`local` line (it reads the decoy)
#   2. CONTROL: an agent the roster does not announce, with no live sidecar,
#      returns 1 and names the dead sidecar, so 1 proves the roster was read
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool tmux
mkdir -p "$T/real/spool/.hub" "$T/decoy/spool/.hub"
printf '{"box-desk":["CLE-07"]}\n' >"$T/real/spool/.hub/roster.json"
CALLER='d="$T/decoy"; caller() { local dir="$1"; spl_desk_wait_roster "$dir" box-desk "$2" 1; }'

# --- 1. the given dir, not the caller's d ------------------------------------------
if SNIPPET="$CALLER; caller '$T/real' CLE-07" in_orc T="$T" >"$T/o1" 2>&1; then
  pass "the roster under the given state dir announces the agent"
else
  fail "the agent under the given dir was not found (read the caller's d?): $(tail -n 2 "$T/o1")"
fi

# --- 2. control: an agent the roster does not announce ------------------------------
if SNIPPET="$CALLER; caller '$T/real' CLE-08" in_orc T="$T" >"$T/o2" 2>&1; then
  fail "an agent the roster does not announce was reported announced"
elif grep -q 'hub-run sidecar of box-desk died' "$T/o2"; then
  pass "an unannounced agent with no live sidecar returns 1 and names the dead sidecar"
else
  fail "the unannounced agent failed for another reason: $(tail -n 2 "$T/o2")"
fi

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
