#!/bin/sh
# NetworkManager dispatcher script (no-wait.d: NM runs it at once, in
# parallel, never waits for it). Installed by do_net_beat_continuity
# (networking round row 08, spec 102 10.2). On a network change it touches
# the spool watchdog's poke file; the watchdog loop sees the newer mtime
# within a second and beats the hub at once instead of at its next 30 s
# tick, so an uplink switch is acked before the 120 s fence is near.
# It only touches one file: it never fences, restarts or kills anything,
# and it always exits 0 so NM never logs it as failed.
# $1 = interface, $2 = action (NetworkManager-dispatcher(8)).
case "$2" in
  up|down|connectivity-change) ;;
  *) exit 0 ;;
esac
f="${SPL_WD_POKE_FILE:-/var/run/spl/watchdog.poke}"
mkdir -p "${f%/*}" 2>/dev/null
touch "$f" 2>/dev/null
exit 0
