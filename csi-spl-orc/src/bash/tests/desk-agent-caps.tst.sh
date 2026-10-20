#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_up refuses an agent whose vendor is at its workspace
#          cap, before any desk dir or process (spec 147 5.2, R3, SPL-2675).
#   1. RED control: with claude capped at 1 in example-ws and c-004 seated,
#      seating c-005 exits 1 with the FATAL naming agent, vendor, workspace,
#      cap and live count, and starts nothing; without the pre-check it seats
#   2. agy cap 2 seats two and refuses the third; uncapped qwen seats freely
#   3. a released seat (desk dir removed) seats the next claude; a re-seat
#      (dir already there) skips the check
#   4. no pin here yet, or a hub that does not answer the caps lane: the
#      check steps aside (the hub's SetRoster gate decides) and the seat goes on
#   5. do_spl_agent_caps prints the hub's answer; refuses on an unpinned box
# No cloud: `spool` is a stub that answers `caps check` from a caps file and
# counts the desk's agent dirs as the live roster; every seam past the check
# prints STARTED, so "nothing started" is its absence.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DESK="$T/state/dev/desk/example-ws/box-desk"
mkdir -p "$T/bin" "$DESK/spool" "$DESK/keys"
echo pub >"$DESK/pinned"
printf 'claude 1\nagy 2\n' >"$T/caps"
# The stub `spool caps [check <agent>]`: live = the desk's agent dirs of the
# agent's vendor letter; STUB_CAPS_RC forces an answer code (an older hub).
cat >"$T/bin/spool" <<'EOF_STUB'
#!/usr/bin/env bash
[[ "$1" == caps ]] || { echo "stub spool: $*" >&2; exit 2; }
if [[ -n "${STUB_CAPS_RC:-}" ]]; then echo "spool: unknown lane op" >&2; exit "$STUB_CAPS_RC"; fi
if [[ $# -eq 1 ]]; then echo '{"workspace_id":"'"$SPOOL_TENANT"'","caps":{"claude":1},"live":{"claude":0},"can_edit":false}'; exit 0; fi
agent="$3"
case "$agent" in c-*) kind=claude ;; a-*) kind=agy ;; g-*) kind=grok ;; m-*) kind=mistral ;; q-*) kind=qwen ;; esac
cap="$(awk -v k="$kind" '$1 == k { print $2 }' "$CAPS_FILE")"
live="$(find "$SPOOL_ROOT" -mindepth 1 -maxdepth 1 -type d -name "${agent%%-*}-*" | wc -l | tr -d ' ')"
if [[ -n "$cap" ]] && (( live >= cap )); then
  echo "agent $agent ($kind) exceeds workspace $SPOOL_TENANT cap of $cap (currently $live live); seating refused"; exit 3
fi
echo "ok $agent ($kind): ${live} live in $SPOOL_TENANT"
EOF_STUB
chmod +x "$T/bin/spool"

# up <env assignments...>: one do_spl_desk_up in example-ws, cloud seams stubbed
up() {
  env -u AGENT_ID -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u TMUX_PANE -u CLE_TMUX_PANE -u SPOOL_DESK_BOX -u DESK_BOX \
      PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
      SPL_ORG_APP="$(basename "$PROJ_ROOT" | sed 's/-orc$//')" CAPS_FILE="$T/caps" \
      SPOOL_ROOT="$T/spool" SPOOL_BOX_USER="$(id -un)" SPOOL_TMUX_SOCKET="$T/nosuch.sock" \
      SPOOL_BOX_ENV="$T/no-box.env" ENV=dev TENANT_ID=example-ws DESK_NOTIFY_CMD=off DESK_WAIT_SECS=0 DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_box_ws_guard() { return 0; }
    do_spl_desk_cnf() { SPL_HUB_URL=https://hub.example.com SPL_WUI_URL=https://example.com; return 0; }
    spl_host_spool() { SPL_SPOOL="$(command -v spool)"; }
    spl_desk_pin() { echo pub; }
    spl_desk_mute() { :; }
    spl_desk_purge_pokes() { :; }
    spl_desk_sidecar() { echo STARTED sidecar; SPL_DESK_PID=1; }
    spl_desk_wait_roster() { return 0; }
    spl_desk_show_pane() { :; }
    "${ACTION:-do_spl_desk_up}"' 2>&1
}
seated() { [[ -d "$DESK/spool/$1" ]]; }

# --- 1. RED control: the 2nd claude over cap 1 ------------------------------------
out=$(up DESK_AGENT=c-004); rc=$?
[[ $rc -eq 0 && "$out" == *"STARTED sidecar"* ]] && seated c-004 &&
  pass "c-004 seats: 1 of claude cap 1" || fail "c-004 (rc=$rc): $out"
out=$(up DESK_AGENT=c-005); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL agent c-005 (claude) exceeds workspace example-ws cap of 1 (currently 1 live); seating refused"* ]] &&
  pass "RED control: c-005 is refused with exit 1, naming agent, vendor, workspace, cap and live count" ||
  fail "c-005 over the claude cap (rc=$rc): $out"
[[ "$out" != *STARTED* ]] && ! seated c-005 &&
  pass "…and nothing started: no sidecar, no c-005 desk dir" || fail "c-005 started something: $out"

# --- 2. agy cap 2, uncapped qwen ---------------------------------------------------
for a in a-004 a-005 q-004 q-005 m-004; do
  out=$(up DESK_AGENT=$a); rc=$?
  [[ $rc -eq 0 ]] && seated $a && pass "$a seats" || fail "$a (rc=$rc): $out"
done
out=$(up DESK_AGENT=a-006); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL agent a-006 (agy) exceeds workspace example-ws cap of 2 (currently 2 live)"* ]] && ! seated a-006 &&
  pass "a-006 is refused: agy at its cap of 2" || fail "a-006 (rc=$rc): $out"

# --- 3. release, then re-seat --------------------------------------------------------
rm -rf "$DESK/spool/c-004"
out=$(up DESK_AGENT=c-005); rc=$?
[[ $rc -eq 0 && "$out" == *"STARTED sidecar"* ]] && seated c-005 &&
  pass "c-004's desk dir gone (desk down): c-005 seats" || fail "c-005 after release (rc=$rc): $out"
out=$(up DESK_AGENT=c-005); rc=$?
[[ $rc -eq 0 && "$out" == *"already has its desk dir"* ]] &&
  pass "a re-seat of c-005 skips the pre-check" || fail "re-seat (rc=$rc): $out"

# --- 4. the check steps aside ---------------------------------------------------------
out=$(up DESK_AGENT=c-006 DESK_BOX=box-new); rc=$?
[[ $rc -eq 0 && "$out" == *"not pinned in example-ws here yet: no cap pre-check"* && "$out" == *"STARTED sidecar"* ]] &&
  pass "a box with no pin here yet: no pre-check, the hub decides" || fail "unpinned box (rc=$rc): $out"
out=$(up DESK_AGENT=c-007 STUB_CAPS_RC=1); rc=$?
[[ $rc -eq 0 && "$out" == *"WARN cap pre-check of c-007 (claude) in example-ws not answered (rc 1"* && "$out" == *"STARTED sidecar"* ]] &&
  pass "a hub that does not answer the caps lane: WARN, the seat goes on" || fail "older hub (rc=$rc): $out"

# --- 5. do_spl_agent_caps ---------------------------------------------------------------
out=$(up ACTION=do_spl_agent_caps); rc=$?
[[ $rc -eq 0 && "$out" == *'"workspace_id":"example-ws"'* && "$out" == *'"caps":{"claude":1}'* ]] &&
  pass "do_spl_agent_caps prints the hub's caps of example-ws" || fail "do_spl_agent_caps (rc=$rc): $out"
out=$(up ACTION=do_spl_agent_caps DESK_BOX=box-none); rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL box-none is not pinned in example-ws"* ]] &&
  pass "do_spl_agent_caps refuses on a box not pinned here" || fail "unpinned do_spl_agent_caps (rc=$rc): $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-agent-caps.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
