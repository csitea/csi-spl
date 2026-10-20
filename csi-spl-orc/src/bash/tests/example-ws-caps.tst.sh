#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 147 section 8, the example-ws acceptance sequence (R6,
#          SPL-2676), in order, through the box actions: caps claude 1,
#          grok 1, agy 2, mistral 1, qwen unlisted.
#   1. c-004 seats; RED control: c-005 is refused (exit 1, the FATAL names
#      agent, vendor, workspace, cap and live count) and starts nothing.
#      RED before R3: the 2nd claude seated alongside the 1st.
#   2. a-004, a-005 seat, a-006 is refused; g-004 seats, g-005 is refused;
#      m-004 seats, m-005 is refused; uncapped q-004 and q-005 both seat
#   3. c-004 leaves: do_spl_desk_down DESK_AGENT=c-004 releases its seat at
#      once while the shared sidecar keeps serving the others (R4); the live
#      claude count is 0 (RED before R4: the seat stayed, c-005 refused)
#   4. c-005 then seats: 1/1 claude live
# No cloud: `spool` is a stub that answers `caps check` from the caps file and
# counts the desk's agent dirs as the live roster (what the sidecar
# announces); every seam past the check prints STARTED.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DESK="$T/state/dev/desk/example-ws/box-desk"
PIDF="$DESK/spool/.hub/hub-run.pid"
mkdir -p "$T/bin" "$DESK/spool/.hub" "$DESK/keys" "$T/spool/dispatch"
echo pub >"$DESK/pinned"
printf 'LEASE_ORCH=c-001\n' >"$T/spool/dispatch/lease.conf"
printf 'claude 1\ngrok 1\nagy 2\nmistral 1\n' >"$T/caps"
cat >"$T/bin/spool" <<'EOF_STUB'
#!/usr/bin/env bash
[[ "$1 $2" == "caps check" ]] || { echo "stub spool: $*" >&2; exit 2; }
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

# A fake shared sidecar: its cmdline carries " hub-run" (spl_desk_alive).
SC=""
# shellcheck disable=SC2016 # expands in the fake's own shell
bash -c 'trap "kill \$c 2>/dev/null; exit 0" TERM; sleep 120 & c=$!; wait' hub-run &
SC=$!; echo "$SC" >"$PIDF"
trap 'kill "$SC" 2>/dev/null; wait "$SC" 2>/dev/null; rm -rf "$T"' EXIT

# box <env assignments...>: one box action ($ACTION, default do_spl_desk_up)
# in example-ws, the cloud seams stubbed
box() {
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
live() { find "$DESK/spool" -mindepth 1 -maxdepth 1 -type d -name "$1-*" | wc -l | tr -d ' '; }
admits() { # <agent> <live after>
  local out rc; out=$(box DESK_AGENT="$1"); rc=$?
  [[ $rc -eq 0 ]] && seated "$1" && [[ "$(live "${1%%-*}")" == "$2" ]] &&
    pass "$1 seats ($2 live)" || fail "$1 (rc=$rc, live $(live "${1%%-*}")): $out"
}
refuses() { # <agent> <vendor> <cap>
  local out rc; out=$(box DESK_AGENT="$1"); rc=$?
  [[ $rc -eq 1 && "$out" == *"FATAL agent $1 ($2) exceeds workspace example-ws cap of $3 (currently $3 live); seating refused"* &&
     "$out" != *STARTED* ]] && ! seated "$1" &&
    pass "$1 is refused: $2 at its cap of $3, nothing started" || fail "$1 over the $2 cap (rc=$rc): $out"
}

# --- 1. claude cap 1, RED control ---------------------------------------------------
admits c-004 1
refuses c-005 claude 1

# --- 2. agy 2, grok 1, mistral 1, qwen uncapped ---------------------------------------
admits a-004 1; admits a-005 2; refuses a-006 agy 2
admits g-004 1; refuses g-005 grok 1
admits m-004 1; refuses m-005 mistral 1
admits q-004 1; admits q-005 2

# --- 3. c-004 leaves: the seat is released at once ------------------------------------
out=$(ACTION=do_spl_desk_down box DESK_AGENT=c-004); rc=$?
[[ $rc -eq 0 && "$out" == *'"released": true'* && "$(live c)" == 0 ]] && kill -0 "$SC" 2>/dev/null && seated q-005 &&
  pass "do_spl_desk_down DESK_AGENT=c-004 releases its seat (0 claude live); the shared sidecar keeps serving the rest" ||
  fail "c-004 leaving (rc=$rc, live claude $(live c)): $out"

# --- 4. c-005 seats now -----------------------------------------------------------------
admits c-005 1

echo "=== $([[ $fails -eq 0 ]] && echo 'all example-ws-caps.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
