#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_id_retire (specs/061 section 3.6) on a throwaway root.
#   1. AGENT_ID is required; DRY_RUN (the default) plans and moves nothing
#   2. DRY_RUN=0 moves the spool dir aside and the registry row to
#      registry.retired.tsv; the lane row is skipped (RETIRE_LANE=0)
#   3. RETIRE_SUCCESSOR writes the alias row and the desk seat is dropped;
#      HUB_ENV is validated (owner 2026-10-05, t1 dc6d5e3f)
#   4. do_spl_desk_legacy_drop lists the legacy seats per desk, and drops
#      them only with DRY_RUN=0
# The script's own cases (refusals, records, quarantine, the /exit-clean hook)
# are features/spawn-agents/tests/test-agent-id-retire.sh.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"
mkdir -p "$R/c-004/inbox"
printf 'c-004\tclaude\t%%1\t/x\t20261002T080000Z\n' >"$R/registry.tsv"
run() { SNIPPET='do_spl_agent_id_retire' in_orc SPOOL_ROOT="$R" SPOOL_TEST=1 SPOOL_TMUX_SOCKET="$T/none.sock" "$@" 2>&1; }

out="$(run)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'AGENT_ID must be set' <<<"$out" && pass "1. AGENT_ID is required" || fail "1. AGENT_ID is required (rc $rc: $out)"
out="$(run AGENT_ID=c-004)"
grep -q 'PLAN move' <<<"$out" && pass "1. the default is a dry run that plans" || fail "1. dry run plans ($out)"
[ -d "$R/c-004/inbox" ] && pass "1. ...and moves nothing" || fail "1. the dry run moved the dir"

out="$(run AGENT_ID=c-004 DRY_RUN=0 RETIRE_LANE=0)"; rc=$?
[ "$rc" -eq 0 ] && pass "2. DRY_RUN=0 exits 0" || fail "2. DRY_RUN=0 rc $rc ($out)"
[ ! -e "$R/c-004" ] && [ -d "$R/.retired/c-004.20261002T080000Z/inbox" ] && pass "2. the spool dir moved aside" || fail "2. the spool dir did not move"
[ ! -s "$R/registry.tsv" ] && grep -q '^c-004	claude	.*	20261002T080000Z	2026' "$R/registry.retired.tsv" \
  && pass "2. the registry row moved to registry.retired.tsv" || fail "2. registry ($(cat "$R/registry.retired.tsv" 2>/dev/null))"
grep -q 'PLAN\|DO *lane' <<<"$out" && fail "2. RETIRE_LANE=0 still touched the lane" || pass "2. RETIRE_LANE=0 skips the lane row"

D="$T/desks/prd/desk/csi-rel/tb/spool"
mkdir -p "$D"/{AGY-3499,CLE-002,c-002}/inbox
run2() { run SPOOL_DESK_BOX=tb DESK_STATE_ROOT="$T/desks" "$@"; }

out="$(run2 AGENT_ID=AGY-3499 RETIRE_SUCCESSOR=c-030 HUB_ENV=qa DRY_RUN=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'HUB_ENV must be dev or prd' <<<"$out" && [ -d "$D/AGY-3499" ] \
  && pass "3. a bad HUB_ENV is refused before anything moves" || fail "3. bad HUB_ENV (rc $rc: $out)"
out="$(run2 AGENT_ID=AGY-3499 RETIRE_SUCCESSOR=c-030 DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$D/AGY-3499" ] && pass "3. the seat of a retired legacy id leaves the desk" || fail "3. desk seat (rc $rc: $out)"
grep -q '^AGY-3499	c-030	agy	tb	' "$R/agent-id-aliases.tsv" 2>/dev/null \
  && pass "3. RETIRE_SUCCESSOR writes the alias row" || fail "3. alias row ($(cat "$R/agent-id-aliases.tsv" 2>/dev/null))"

out="$(SNIPPET='do_spl_desk_legacy_drop' in_orc DESK_STATE_ROOT="$T/desks" DESK_ENVS=prd SPOOL_TEST=1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^SEATED prd/csi-rel/tb CLE-002$' <<<"$out" && [ -d "$D/CLE-002" ] \
  && pass "4. the dry run lists the legacy seat and drops nothing" || fail "4. dry run (rc $rc: $out)"
out="$(SNIPPET='do_spl_desk_legacy_drop' in_orc DESK_STATE_ROOT="$T/desks" DESK_ENVS=prd SPOOL_TEST=1 DRY_RUN=0 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$D/CLE-002" ] && [ -d "$D/c-002" ] \
  && pass "4. DRY_RUN=0 drops the legacy seat, the new id stays" || fail "4. apply (rc $rc: $out)"

echo "agent-id-retire: ${fails} failure(s)"
[ "$fails" -eq 0 ]
