#!/usr/bin/env bash
# wd-restart-seed-stable-paths.tst.sh - a watchdog restart run from a wd code
# snapshot names the stable desk-cron checkout in the new seed, never the
# snapshot (SPL-5569)
#
# The watchdogs run from <wd>/code/<sha>/ (spl-wd-self-update.func.sh); the
# self-update prunes a snapshot after two rollouts. ROTATE_SPAWN and
# ROTATE_SEND defaulted to the run's own spawn-agents dir, so a restart seed
# (and the prompt.txt spawn-window.sh renders from the dir it runs from)
# named wd/code/<sha>/.../spool-send.sh and lane-map.sh: a lane restarted
# 2026-11-15 11:53Z, lost them ~40 min later; a second seed the same. Cases:
#   (a) from a snapshot, DESK_CRON_SRC set: ROTATE_SPAWN, ROTATE_SEND name the
#       checkout; the seat seed text names no wd/code/ path
#   (b) from a snapshot, no DESK_CRON_SRC: <wd>/starter.src names the checkout
#   (c) not in a snapshot (no .sha): the run's own dir, as before
#   (d) a snapshot whose checkout lacks the dir: the run's own dir (no
#       dangling path)
#   (e) ROTATE_SPAWN / ROTATE_SEND given (the tests' seam): kept
#
# Run: bash csi-spl-orc/src/bash/tests/wd-restart-seed-stable-paths.tst.sh </dev/null
set -uo pipefail
while read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(SPOOL_|ROTATE_|LEASE_|WD_|DESK_CRON_)')
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SHA=ccef654f0000000000000000000000000000beef
ON="$(basename "$ORC")"
FEAT=src/bash/features/spawn-agents
# a snapshot laid out as spl_wd_upd_export makes it, its files linked to this tree
SNAP="$T/spool/dispatch/wd/code/$SHA"
mkdir -p "$SNAP/$ON/src/bash" "$T/plain/$ON/src/bash" "$T/desk/$ON/$FEAT/scripts" "$T/bare"
echo "$SHA" > "$SNAP/.sha"
for d in "$SNAP" "$T/plain"; do
  for s in run features; do ln -s "$ORC/src/bash/$s" "$d/$ON/src/bash/$s"; done
  ln -s "$ORC/lib" "$d/$ON/lib"
done

# conf TREE [VAR=value ...]: spl_rotate_conf run from TREE's orc under
# ./run's set -E + ERR trap; prints ROTATE_SPAWN|ROTATE_SEND|seat seed text
conf() {
  local tree="$1"; shift
  env -i PATH="$PATH" HOME="$T/home" SPOOL_ROOT="$T/spool" DRY_RUN=1 "$@" \
    bash -c 'set -E; trap "echo ERRTRAP; exit 9" ERR; do_log() { echo "LOG $*" >&2; }
      source "$1/src/bash/run/spl-rotate-lib.func.sh"
      source "$1/src/bash/run/spl-agent-restart.func.sh"
      PROJ_PATH="$1"; spl_rotate_conf >/dev/null || { echo CONF-FAILED; exit 0; }
      echo "$ROTATE_SPAWN|$ROTATE_SEND"
      echo "handoff" > "$HOME/hand.md"
      ARS_SEAT=1 ARS_CAUSE=crash ARS_EV=x ARS_N=2 REBIRTH_MAX=3 TASK_RESTART_MAX=3 \
        spl_ars_seed_text c-893 rid1 20261115T1153Z "$HOME/hand.md" "" 0 1' _ "$tree/$ON"
}
mkdir -p "$T/home"
want_desk="$T/desk/$ON/$FEAT/scripts/spawn-window.sh|$T/desk/$ON/$FEAT/scripts/spool-send.sh"

# (a)
out="$(conf "$SNAP" DESK_CRON_SRC="$T/desk")"
[[ "$(head -n 1 <<<"$out")" == "$want_desk" ]] && pass "(a) from a snapshot: spawn + send name the checkout" ||
  fail "(a) want $want_desk, got: $(head -n 1 <<<"$out")"
seed="$(tail -n +2 <<<"$out")"
if [[ "$seed" == *"$T/desk/$ON/$FEAT/scripts/spool-send.sh"* && "$seed" != *"wd/code/"* ]]; then
  pass "(a) the restart seed names the checkout's spool-send.sh and no wd/code/ path"
else fail "(a) seed: $(grep -n 'spool-send\|wd/code' <<<"$seed")"; fi

# (b)
echo "$T/desk" > "$T/spool/dispatch/wd/starter.src"
out="$(conf "$SNAP")"
[[ "$(head -n 1 <<<"$out")" == "$want_desk" ]] && pass "(b) no DESK_CRON_SRC: <wd>/starter.src names the checkout" ||
  fail "(b) got: $(head -n 1 <<<"$out")"

# (c)
out="$(conf "$T/plain" DESK_CRON_SRC="$T/desk")"
[[ "$(head -n 1 <<<"$out")" == "$T/plain/$ON/$FEAT/scripts/spawn-window.sh|$T/plain/$ON/$FEAT/scripts/spool-send.sh" ]] &&
  pass "(c) not in a snapshot: the run's own dir" || fail "(c) got: $(head -n 1 <<<"$out")"

# (d)
out="$(conf "$SNAP" DESK_CRON_SRC="$T/bare")"
[[ "$(head -n 1 <<<"$out")" == "$SNAP/$ON/$FEAT/scripts/spawn-window.sh|$SNAP/$ON/$FEAT/scripts/spool-send.sh" ]] &&
  pass "(d) the checkout lacks the dir: the run's own dir" || fail "(d) got: $(head -n 1 <<<"$out")"

# (e)
out="$(conf "$SNAP" DESK_CRON_SRC="$T/desk" ROTATE_SPAWN=/x/spawn ROTATE_SEND=/x/send)"
[[ "$(head -n 1 <<<"$out")" == "/x/spawn|/x/send" ]] && pass "(e) the seams are kept" || fail "(e) got: $(head -n 1 <<<"$out")"

echo "fails=$fails"
(( fails == 0 ))
