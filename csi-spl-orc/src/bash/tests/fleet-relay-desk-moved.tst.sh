#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a cross-box relay run by the box user reaches the fleet desk where
# it lives NOW (SPL-5246, spec 069 section 8.4). A satellite box, 2026-11-10: every placer
# launch pinned to another box exited 8, "no live hub-run sidecar for <box>
# in t1": the
# placer cron runs as the box user, box.env has no SPOOL_DESK_USER (the move
# writes it only once every desk moved), so spool-fleet-relay.sh read the
# box user's stub desk dir (no pid, not pinned) while the agent user's pinned
# desk had the live sidecar. Sandbox: caller A (this user, home $T/home-a),
# agent user B (t-agent-user, home $T/home-b), getent and the as-user command
# (SPL_DESK_AS_CMD) stubs; a fake /proc; no hub, no sudo, no tmux.
#   1. moved (A stub, B pinned + live sidecar): sent through B's sidecar, one
#      hop as B, every argument kept, one INFO line naming B
#   2. CONTROL not moved: A's own desk with a live sidecar is used, no hop
#   3. CONTROL B's copy not pinned (spl_desk_moved_to's asymmetric signal):
#      refused rc 3 as before, no hop
#   4. one hop only: SPL_DESK_HOPPED set -> refused rc 3, no hop
#   5. SPOOL_FLEET_STATE_ROOT pins the root: refused rc 3, no hop
#   6. under SPOOL_TEST=1 without SPL_DESK_AS_CMD: never a hop (no real sudo)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/bash/features/spawn-agents/scripts"
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)" AU=t-agent-user
HA="$T/home-a" HB="$T/home-b"
RA="$HA/.local/share/$OA/cloud" RB="$HB/.local/share/$OA/cloud"
STUB_LOG="$T/stub.log"
mkdir -p "$T/stub" "$T/spool"
cat >"$T/stub/getent" <<STUB
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $ME) echo "$ME:x:5001:5001::$HA:/bin/sh" ;;
  $AU) echo "$AU:x:5002:5002::$HB:/bin/sh" ;;
  *) exit 2 ;;
esac
STUB
# as-user USER -- CMD...: logs the call, then runs CMD as this same user (the
# sandbox has one OS user; the hop's SPOOL_DESK_USER picks B's root).
printf '#!/bin/sh\necho "as $*" >>"%s"\nshift 2\nexec "$@"\n' "$STUB_LOG" >"$T/stub/as-user"
chmod +x "$T/stub/"*

has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: ${3:0:600})"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: ${3:0:600})"; }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }

# sidecar ROOT PID TAG: a live fake sidecar of desk box-x in t9 (prd) under
# ROOT; its bin/spool echoes TAG and its arguments.
sidecar() {
  local d="$1/prd/desk/t9/box-x/spool"
  mkdir -p "$d/.hub" "$d/c-010" "$1/prd/bin" "$T/proc/$2"
  echo "$2" >"$d/.hub/hub-run.pid"
  printf 'spool\0hub-run\0' >"$T/proc/$2/cmdline"
  printf 'SPOOL_ROOT=/x\0SPOOL_KEYS_DIR=/x\0SPOOL_PINS_DIR=/x\0SPOOL_BOX_ID=box-x\0SPOOL_HUB_URL=http://127.0.0.1:9\0SPOOL_TENANT=t9\0' \
    >"$T/proc/$2/environ"
  printf '#!/bin/sh\necho "{\\"delivery\\":\\"sent\\",\\"via\\":\\"%s\\",\\"args\\":\\"$*\\"}"\n' "$3" >"$1/prd/bin/spool"
  chmod +x "$1/prd/bin/spool"
}
pin() { echo "box-x pinned" >"$1/prd/desk/t9/box-x/pinned"; }
# stub ROOT: what the move leaves under the caller: the desk dir, no pid, no pin
stub() { mkdir -p "$1/prd/desk/t9/box-x/spool/.hub"; }
fresh() { rm -rf "$HA" "$HB" "$T/proc" "$STUB_LOG"; mkdir -p "$HA" "$HB"; : >"$STUB_LOG"; }
# relay [ENV=VAL...]: the relay as A, the fleet desk box-x of t9 (prd)
relay() {
  env -u SPOOL_DESK_USER -u SPOOL_FLEET_STATE_ROOT -u SPL_STATE_DIR -u SPL_DESK_HOPPED \
    PATH="$T/stub:$PATH" HOME="$HA" SPOOL_TEST=1 SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV= \
    SPOOL_BOX_USER="$ME" SPOOL_AGENT_USER="$AU" SPL_DESK_AS_CMD=as-user \
    SPOOL_FLEET_ENV=prd SPOOL_FLEET_TENANT=t9 SPOOL_DESK_BOX=box-x SPOOL_FLEET_PROC_ROOT="$T/proc" \
    "$@" bash "$S/spool-fleet-relay.sh" --from c-010 --to c-020 --kind note --body hi --task spawn-queue-x 2>&1
}

# --- 1. moved: A stub, B pinned with a live sidecar ---------------------------
fresh; stub "$RA"; sidecar "$RB" 424243 B; pin "$RB"
out="$(relay)"; rc=$?
eq "1. moved: rc 0" 0 "$rc"
has "1. moved: sent through B's sidecar" '"via":"B"' "$out"
has "1. moved: one hop as B" "as $AU -- env" "$(cat "$STUB_LOG")"
has "1. moved: the task travels with the hop" "--task " "$out"
has "1. moved: the INFO line names B" "lives under $AU's state root" "$out"
eq "1. moved: exactly one hop" 1 "$(grep -c -- '-- env' "$STUB_LOG")"

# --- 2. CONTROL: the desk did not move (A's own live sidecar) -----------------
fresh; sidecar "$RA" 424244 A; sidecar "$RB" 424245 B; pin "$RB"
out="$(relay)"; rc=$?
eq "2. not moved: rc 0" 0 "$rc"
has "2. not moved: sent through A's own sidecar" '"via":"A"' "$out"
hasnt "2. not moved: no hop" "-- env" "$(cat "$STUB_LOG")"

# --- 3. CONTROL: B's copy is not pinned (no move) -----------------------------
fresh; stub "$RA"; sidecar "$RB" 424246 B
out="$(relay)"; rc=$?
eq "3. B not pinned: refused rc 3" 3 "$rc"
has "3. B not pinned: today's message" "no live hub-run sidecar" "$out"
hasnt "3. B not pinned: no hop" "-- env" "$(cat "$STUB_LOG")"

# --- 4. one hop only ----------------------------------------------------------
fresh; stub "$RA"; sidecar "$RB" 424247 B; pin "$RB"
out="$(relay SPL_DESK_HOPPED="$ME")"; rc=$?
eq "4. already hopped: refused rc 3" 3 "$rc"
hasnt "4. already hopped: no second hop" "-- env" "$(cat "$STUB_LOG")"

# --- 5. SPOOL_FLEET_STATE_ROOT pins the root ----------------------------------
fresh; stub "$RA"; sidecar "$RB" 424248 B; pin "$RB"
out="$(relay SPOOL_FLEET_STATE_ROOT="$RA")"; rc=$?
eq "5. pinned state root: refused rc 3" 3 "$rc"
hasnt "5. pinned state root: no hop" "-- env" "$(cat "$STUB_LOG")"

# --- 6. SPOOL_TEST=1 without SPL_DESK_AS_CMD: no real sudo --------------------
fresh; stub "$RA"; sidecar "$RB" 424249 B; pin "$RB"
out="$(relay SPL_DESK_AS_CMD=)"; rc=$?
eq "6. test guard: refused rc 3" 3 "$rc"
hasnt "6. test guard: no hop" "-- env" "$(cat "$STUB_LOG")"

[[ $fails -eq 0 ]] && echo "fleet-relay-desk-moved: all passed" || echo "fleet-relay-desk-moved: $fails FAILED"
exit $((fails > 0))
