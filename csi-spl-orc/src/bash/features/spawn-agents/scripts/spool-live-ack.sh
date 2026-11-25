#!/usr/bin/env bash
# spool-live-ack.sh <agent> <msg_id>... — the agent hook's shown ack
# (spec 053 S1 and section 4.5, SPL-6517, latency action 7).
#
# spool-agent-hook.sh starts it detached (stdin, stdout and stderr on
# /dev/null, its own session) when inject() has shown inbox messages, with
# their msg ids; the hook never waits for it. It runs
# `spool live-ack --as <id> -- <msg_id>...` against a box sidecar's submit
# socket: the sidecar writes one ack frame, outcome shown, per id on its warm
# hub session, and the hub records it once. The verb never dials the hub
# itself; no sidecar = the ack is dropped.
#
# Which sidecar (R7 a-826 W1): the hook's SPOOL_ROOT is the fleet root
# (/var/spool-hub), and no sidecar listens there on a fleet box. The live
# ones are the desks, <desk_root>/<env>/desk/<workspace>/<box>/spool, one per
# workspace (desk-root.inc.sh, as spool-fleet-relay.sh reads it).
#   1. SPOOL_SUBMIT_SOCKET set, or $SPOOL_ROOT/.hub/submit.sock present (a
#      single-root box, the tests): that one socket, the binary below.
#   2. else every desk socket whose spool has a dir (or link) named <id>:
#      that desk announces <id>, so the hub may have delivered to it. A desk
#      that did not deliver a message records nothing for it (the hub's
#      deliveries gate), so asking each such desk is safe. Its binary is
#      <desk_root>/<env>/bin/spool, the one the desk actions build, else the
#      one below. A socket the agent user cannot open (a distinct
#      SPOOL_DESK_USER, mode 0600) fails that run only.
#
#   <agent>               the hook's agent dir name; a qualified <id>@<box>
#                         is acked as <id>
#   SPOOL_BIN             the spool binary (default: spool on PATH, else
#                         $HOME/.local/bin/spool; none = nothing to do)
#   SPOOL_FLEET_STATE_ROOT  the desk root (default: desk-root.inc.sh)
#   SPOOL_LIVE_ACK_TIMEOUT  seconds each verb run may take (default 20)
#   log                   one line per verb run, "<ts> <id> rc=<n> <where>
#                         <output>", in $SPOOL_ROOT/<agent>/lifetime/
#                         live-ack.log when that dir exists; kept to the
#                         last 200 lines once it passes 400
# Exit 0 always: the ack is best effort and nobody reads this exit code.
set -uo pipefail
raw="${1:-}"
[ "$#" -gt 0 ] && shift
id="${raw%%@*}"
[ -n "$id" ] && [ "$#" -gt 0 ] || exit 0
root="${SPOOL_ROOT:-/var/spool-hub}"
bin="${SPOOL_BIN:-}"
[ -n "$bin" ] || bin="$(command -v spool 2>/dev/null || true)"
[ -z "$bin" ] && [ -x "$HOME/.local/bin/spool" ] && bin="$HOME/.local/bin/spool"
lt="$root/$raw/lifetime"

log() {  # RC WHERE OUTPUT
  [ -d "$lt" ] || return 0
  printf '%s %s rc=%s %s %s\n' "$(date -u +%FT%TZ)" "$id" "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-300)" \
    >> "$lt/live-ack.log" 2>/dev/null
}
ack() {  # SOCKET BINARY MSG_ID...
  local sock="$1" b="$2" out rc
  shift 2
  [ -n "$b" ] || { log 127 "$sock" "no spool binary"; return 0; }
  out="$(SPOOL_SUBMIT_SOCKET="$sock" timeout "${SPOOL_LIVE_ACK_TIMEOUT:-20}" "$b" live-ack --as "$id" -- "$@" 2>&1)"
  rc=$?
  log "$rc" "$sock" "$out"
}

if [ -n "${SPOOL_SUBMIT_SOCKET:-}" ] || [ -S "$root/.hub/submit.sock" ]; then
  ack "${SPOOL_SUBMIT_SOCKET:-$root/.hub/submit.sock}" "$bin" "$@"
else
  state="${SPOOL_FLEET_STATE_ROOT:-$(bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/desk-root.inc.sh" \
    "$HOME" "${SPOOL_BOX_ENV:-$root/box.env}" 2>/dev/null)}"
  n=0
  if [ -n "$state" ]; then
    for sock in "$state"/*/desk/*/*/spool/.hub/submit.sock; do
      [ -S "$sock" ] || continue
      d="${sock%/.hub/submit.sock}"
      [ -e "$d/$id" ] || continue
      env="${sock#"$state"/}"; env="${env%%/*}"
      b="$state/$env/bin/spool"
      [ -x "$b" ] || b="$bin"
      ack "$sock" "$b" "$@"
      n=$((n + 1))
    done
  fi
  [ "$n" -gt 0 ] || log 0 "-" "no desk sidecar announces $id under ${state:-<no desk root>}; ack dropped"
fi
if [ -f "$lt/live-ack.log" ] && [ "$(wc -l < "$lt/live-ack.log")" -gt 400 ]; then
  tail -n 200 "$lt/live-ack.log" > "$lt/live-ack.log.tmp" 2>/dev/null && mv -f "$lt/live-ack.log.tmp" "$lt/live-ack.log" 2>/dev/null
fi
exit 0
