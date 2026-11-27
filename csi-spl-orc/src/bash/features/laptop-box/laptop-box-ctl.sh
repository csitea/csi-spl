#!/usr/bin/env bash
#------------------------------------------------------------------------------
# laptop-box-ctl.sh - the member's own controls of her laptop box (SPL-6680,
# spec 037 "Laptop box"). do_spl_laptop_box_install copies it, root-owned, to
# /usr/local/bin/spl-laptop-box, so each control is one short line and runs
# a copy the agents' user cannot change:
#   spl-laptop-box status     her hours, the state, the agents running here
#   spl-laptop-box stop       stop for today: running agents move to the
#                             fleet's home box within 5 min; tomorrow as usual
#   spl-laptop-box off        stop until she runs start (agents move too)
#   spl-laptop-box start      undo stop / off: agents run again in her hours
#   spl-laptop-box continue   past her hours: keep the agents 1 more hour
#   sudo spl-laptop-box remove   take it all off the laptop (refused while
#                             agents still run here: stop first)
# The controls only write marker files in the state dir; the tick
# (do_spl_laptop_box_tick, every 5 min) acts on them.
# State dir: $LAPTOP_STATE_DIR, default <spool root>/dispatch/laptop-box:
#   off, stopped (a date), move-now, continue-until (epoch), asked-at,
#   ask-pending (the question text), answer, lanes (written by the tick).
# Env (tests): SPOOL_ROOT, LAPTOP_STATE_DIR, LAPTOP_NOW (epoch),
#   LAPTOP_ROOT_SH (the root runner of remove, default bash -c),
#   LAPTOP_EUID (default $EUID).
# Exit: 0 ok, 2 usage, 3 refused (remove while agents run, or not root).
#------------------------------------------------------------------------------
set -uo pipefail
SR="${SPOOL_ROOT:-/var/spool-hub}"
D="${LAPTOP_STATE_DIR:-$SR/dispatch/laptop-box}"
ENVF="$SR/dispatch/laptop-box.env"
NOW="${LAPTOP_NOW:-$(date +%s)}"

put() { printf '%s\n' "$2" >"$D/$1.tmp" && mv -f "$D/$1.tmp" "$D/$1"; }
envget() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -n 1; }
lanes() { [[ -s "$D/lanes" ]] && grep -c . "$D/lanes" || echo 0; }

status() {
  local st="in use"
  [[ -e "$D/off" ]] && st="off (run: spl-laptop-box start)"
  [[ "$(cat "$D/stopped" 2>/dev/null)" == "$(date -d "@$NOW" +%F)" ]] && st="stopped for today"
  echo "hours:  $(envget LAPTOP_HOURS)"
  echo "state:  $st"
  echo "agents: $(lanes) running here (as of the last check)"
  [[ -s "$D/ask-pending" ]] && echo "asked:  her hours are over; answer the pop-up, or run spl-laptop-box continue / stop"
  return 0
}

remove() {
  [[ "${LAPTOP_EUID:-$EUID}" == 0 ]] || { echo "refused: remove needs root: sudo spl-laptop-box remove" >&2; return 3; }
  [[ "$(lanes)" == 0 ]] || { echo "refused: $(lanes) agent(s) still run here; run: spl-laptop-box stop, wait 5 min for them to move, then remove" >&2; return 3; }
  local u; u="$(envget LAPTOP_AGENT_USER)"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "refused: no agents' user in $ENVF" >&2; return 3; }
  local c
  for c in \
    "systemctl disable --now spl-laptop-box-tick.timer 2>/dev/null; systemctl --global disable spl-laptop-box-ask.timer 2>/dev/null; true" \
    "rm -f /etc/systemd/system/spl-laptop-box-tick.service /etc/systemd/system/spl-laptop-box-tick.timer /etc/systemd/user/spl-laptop-box-ask.service /etc/systemd/user/spl-laptop-box-ask.timer" \
    "systemctl daemon-reload" \
    "pkill -u '$u' || true" \
    "userdel -r '$u' 2>/dev/null || true" \
    "rm -rf '$SR' /usr/local/lib/spl-laptop-box /usr/local/bin/spl-laptop-box"; do
    ${LAPTOP_ROOT_SH:-bash -c} "$c" || { echo "remove: failed: $c" >&2; return 1; }
  done
  echo "OK removed from this laptop. A workspace admin revokes its seat in the web UI (Monitoring -> Boxes)."
}

case "${1:-status}" in
  status) status ;;
  start) rm -f "$D/off" "$D/stopped" "$D/move-now"; echo "OK started: agents run again in your hours (next check within 5 min)" ;;
  stop) put stopped "$(date -d "@$NOW" +%F)" && put move-now "$NOW" && echo "OK stopped for today: running agents move to the fleet within 5 min" ;;
  off) put off "$NOW" && put move-now "$NOW" && echo "OK off until you run: spl-laptop-box start" ;;
  continue) put continue-until "$((NOW + 3600))" && rm -f "$D/asked-at" "$D/ask-pending" "$D/answer" && echo "OK the agents keep running for 1 more hour" ;;
  remove) remove ;;
  *) echo "usage: spl-laptop-box status|start|stop|off|continue|remove" >&2; exit 2 ;;
esac
