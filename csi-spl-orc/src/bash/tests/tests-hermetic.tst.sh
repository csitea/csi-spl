#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: orc tests stay hermetic and date-proof (refactor r3-14).
#
# A grep cannot prove absence. This file does not execute the other tests,
# so it cannot see an id built at runtime, a SPOOL_NOW pin inherited from a
# parent (run-all-tests.sh exports one, which is why many CLE- fixtures still
# pass inside the suite), or a desk box passed by a path the patterns below
# do not name. A clean run means those shapes are absent, not that every
# test is hermetic.
#
#   1. A *.tst.sh that does not source test-lib.inc.sh (that file pins
#      SPOOL_NOW before the legacy-id cutoff, and exports SPOOL_TEST=1 plus
#      an empty SPOOL_BOX_ENV) and still writes a CLE-<digits> id into one
#      of the actions measured red after 2026-10-03T20:59:59Z, without a
#      refusal assertion on that line, fails. Three files are allow-listed:
#      the same bug, left for a later row.
#   2. A *.tst.sh that sources run/*.func.sh and calls one of those desk
#      actions, and sets neither SPOOL_TEST=1 nor SPOOL_BOX_ENV, fails.
#      A file that sources test-lib.inc.sh gets both from there.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# Later row, same cause (plan section 4). Not judged here.
allow=(
  asks.tst.sh
  channel-agent-remove-op.tst.sh
  desk-install-service-envs.tst.sh
)
# Actions whose standalone tests were red on a legacy id or a live box.env.
write_rx='do_spl_desk_session_upload|do_spl_desk_mirror_check|do_spl_agent_mcp_probe|do_spl_channel_agent_add_op|do_spl_desk_owners|do_spl_desk_welcome|do_spl_desk_greeter|do_spl_channel_agent_remove_op|do_spl_desk_install_service'
# A real asks call (the command, not a case arm such as `do_spl_asks_open)`).
asks_rx='do_spl_asks_[a-z0-9_]+[[:space:]]'
desk_rx='do_spl_desk_session_upload|do_spl_desk_mirror_check|do_spl_desk_mirror_settings|do_spl_desk_owners|do_spl_desk_welcome|do_spl_desk_greeter|do_spl_desk_install_service|do_spl_channel_agent_add_op'

allowed() {
  local a
  for a in "${allow[@]}"; do
    [[ "$1" == "$a" ]] && return 0
  done
  return 1
}

lib="$TEST_DIR/test-lib.inc.sh"
grep -qx 'export SPOOL_TEST=1' "$lib" \
  && pass "test-lib exports SPOOL_TEST=1" \
  || fail "test-lib does not export SPOOL_TEST=1"
grep -qx ': "${SPOOL_BOX_ENV=}"' "$lib" \
  && pass "test-lib sets an empty SPOOL_BOX_ENV when the caller did not" \
  || fail "test-lib does not default SPOOL_BOX_ENV to empty"
[[ ${#allow[@]} -eq 3 ]] && pass "the allow-list is the three not-yet-fixed files" \
  || fail "allow-list size ${#allow[@]}"

id_bad=0
env_bad=0
n=0
for f in "$TEST_DIR"/*.tst.sh; do
  b=$(basename "$f")
  [[ "$b" == "$(basename "$0")" ]] && continue
  n=$((n + 1))
  if allowed "$b"; then
    [[ -f "$f" ]] && pass "allow-listed $b is present (later row, not judged)" \
      || fail "allow-listed $b is missing"
    continue
  fi
  code=$(grep -vE '^[[:space:]]*#' "$f" || true)
  if ! grep -q 'test-lib.inc.sh' "$f" && { grep -qE "$write_rx" <<<"$code" || grep -qE "$asks_rx" <<<"$code"; }; then
    bad=$(grep -nE 'CLE-[0-9]+' <<<"$code" | grep -viE 'refus|retired' || true)
    if [[ -n "$bad" ]]; then
      id_bad=$((id_bad + 1))
      bad_head=$(awk 'NR<=2 { printf "%s ", $0 }' <<<"$bad")
      fail "1. $b uses a legacy CLE- id without a refusal assertion: ${bad_head}"
    fi
  fi
  if grep -qF 'run/*.func.sh' "$f" && grep -qE "$desk_rx" <<<"$code" \
    && ! grep -q 'test-lib.inc.sh' "$f" \
    && ! grep -q 'SPOOL_TEST=1' "$f" \
    && ! grep -q 'SPOOL_BOX_ENV' "$f"; then
    env_bad=$((env_bad + 1))
    fail "2. $b sources run/*.func.sh and calls a desk action without SPOOL_TEST=1 or SPOOL_BOX_ENV"
  fi
done
[[ "$n" -ge 50 ]] && pass "scanned $n *.tst.sh files" || fail "scanned only $n files"
[[ "$id_bad" -eq 0 ]] && pass "no unlisted test writes a legacy CLE- id into a measured action without asserting a refusal" \
  || fail "$id_bad file(s) still use a legacy id on a measured action"
[[ "$env_bad" -eq 0 ]] && pass "no unlisted test sources run/*.func.sh and calls a desk action without SPOOL_TEST=1 or SPOOL_BOX_ENV" \
  || fail "$env_bad file(s) call a desk action without a hermetic box"

(( fails == 0 )) && echo "=== all tests-hermetic.tst.sh assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
