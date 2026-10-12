#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_unseat takes ONE live agent off a desk (t1 prd
#          2026-10-11: review lanes seated on the desk answered owner posts,
#          and nothing unseated one live agent).
#   1. a dry run names the move and touches nothing
#   2. DRY_RUN=0 moves exactly that agent's dir to retired/, inbox kept;
#      CONTROL: every other seat and the sidecar's .hub dir stay
#   3. an agent not seated on the desk, a non-id and an orchestrator or
#      dispatcher seat (lease.conf) are refused, and nothing moves
# No tmux, no cloud call: the action reads the desk's state dir only.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

in_orc() {
  env -u SPOOL_DESK_BOX PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
      SPL_ORG_APP="$(basename "$PROJ_ROOT" | sed 's/-orc$//')" \
      SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/no-box.env" ENV=dev TENANT_ID=t1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_desk_unseat'
}

D="$T/state/dev/desk/t1/box-desk"
mkdir -p "$D/spool/.hub" "$D/spool/c-001" "$D/spool/a-175" "$D/spool/m-033" "$D/spool/g-010" "$T/spool/dispatch"
printf 'an unread owner post\n' >"$D/spool/a-175/inbox.json"
printf 'LEASE_ORCH=g-010\n' >"$T/spool/dispatch/lease.conf"
seats() { (cd "$D/spool" && ls -A | LC_ALL=C sort | tr '\n' ' '); }
before="$(seats)"

# --- 1. dry run -------------------------------------------------------------------
out=$(in_orc DESK_AGENT=a-175 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"DRY_RUN would: move $D/spool/a-175 to $D/retired/"* ]] &&
  pass "the dry run names the one dir it would move" || fail "dry run (rc=$rc): $out"
[[ "$(seats)" == "$before" && ! -e "$D/retired" ]] && pass "…and touches nothing" || fail "dry run moved: $(seats)"

# --- 2. DRY_RUN=0 moves exactly one dir ---------------------------------------------
out=$(in_orc DESK_AGENT=a-175 DRY_RUN=0 2>&1); rc=$?
moved=( "$D"/retired/a-175.* )
[[ $rc -eq 0 && ! -e "$D/spool/a-175" && ${#moved[@]} -eq 1 && -f "${moved[0]}/inbox.json" ]] &&
  pass "unseat moves a-175's dir to retired/, inbox kept" || fail "unseat (rc=$rc): $out"
[[ "$(seats)" == ".hub c-001 g-010 m-033 " ]] &&
  pass "CONTROL the other seats and the sidecar's .hub stay: exactly one dir moved" || fail "CONTROL seats: $(seats)"

# --- 3. refusals --------------------------------------------------------------------
before="$(seats)"
out=$(in_orc DESK_AGENT=a-999 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"a-999 is not seated on box-desk"* ]] && pass "an agent not seated on the desk is refused" ||
  fail "unknown agent (rc=$rc): $out"
out=$(in_orc DESK_AGENT=a-175 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "unseating the same agent twice is refused (it is no longer seated)" || fail "second unseat: $out"
out=$(in_orc DESK_AGENT="not an id" DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"is not an agent id"* ]] && pass "a DESK_AGENT that is not an agent id is refused" || fail "bad id: $out"
out=$(in_orc DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "no DESK_AGENT is refused" || fail "no agent: $out"
out=$(in_orc DESK_AGENT=g-010 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"orchestrator or dispatcher seat"* ]] && pass "an orchestrator seat (lease.conf) is refused" ||
  fail "od seat (rc=$rc): $out"
[[ "$(seats)" == "$before" ]] && pass "CONTROL no refusal moved a dir" || fail "a refusal moved: $(seats)"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-unseat.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
