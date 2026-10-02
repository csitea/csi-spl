#!/usr/bin/env bash
# asks.sh — the asks to the orchestrator from anywhere (CLE-77929, owner bug
# t1 #spool-hub-bugs 2f7996aa; SPEC-spool-fleet-roles.md 4.3). A thin front
# for the orc actions do_spl_asks_open / do_spl_ask_ack / do_spl_ask_close /
# do_spl_orch_inbox / do_spl_asks_sync / do_spl_asks_tick, so an agent pane
# names one command.
#
# Usage:
#   asks.sh [open] [--all] [--json]          the open asks, oldest first
#   asks.sh ack <id> [--by <ID>@<box>]       in progress, mine
#   asks.sh done <id> [--reason <text>]      closed
#   asks.sh decline <id> --reason <text>     closed, not done
#   asks.sh inbox [--archive]                the orchestrator's view: asks, untracked, FYI
#   asks.sh sync                             push this machine's journal to the hub
#   asks.sh tick                             the lease loop's timer, by hand
#
# <id> is the ask id or its first 8 hex digits. The action runs as
# $SPOOL_BOX_USER (the desk keys that sign the hub call are theirs). Exit
# codes: the action's own (0 ok, 1 refused, 3 already closed); 64 usage.
#
# ASKS_ORC (tests): the csi-spl-orc dir whose ./run is called.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() { sed -n '9,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

verb=open
case "${1:-}" in open|ack|done|decline|inbox|sync|tick) verb="$1"; shift ;; -h|--help) usage ;; esac
vars=()
case "$verb" in
  ack|done|decline)
    [ -n "${1:-}" ] && [ "${1#-}" = "$1" ] || { echo "asks.sh: $verb needs the ask id" >&2; usage; }
    vars+=("ASK_ID=$1"); shift ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --all)     vars+=("ASKS_ALL=1"); shift ;;
    --json)    vars+=("ASKS_FORMAT=json"); shift ;;
    --by)      vars+=("ASK_BY=${2:-}"); shift 2 ;;
    --reason)  vars+=("ASK_REASON=${2:-}"); shift 2 ;;
    --archive) vars+=("ORCH_INBOX_ARCHIVE=1"); shift ;;
    *) echo "asks.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
case "$verb" in
  open)    action=do_spl_asks_open ;;
  ack)     action=do_spl_ask_ack ;;
  done)    action=do_spl_ask_close; vars+=("ASK_STATE=done") ;;
  decline) action=do_spl_ask_close; vars+=("ASK_STATE=declined") ;;
  inbox)   action=do_spl_orch_inbox ;;
  sync)    action=do_spl_asks_sync ;;
  tick)    action=do_spl_asks_tick ;;
esac

orc="${ASKS_ORC:-$(cd "$_here/../../../../.." && pwd)}"
[ -x "$orc/run" ] || { echo "asks.sh: no orc ./run at $orc" >&2; exit 1; }
# The caller's settings, passed through the user hop.
for k in ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ORCH_ID SPOOL_AGENT_ID SPOOL_DESK_BOX SPOOL_BOX_ENV; do
  [ -n "${!k:-}" ] && vars+=("$k=${!k}")
done
vars+=("SPOOL_ROOT=$SPOOL_ROOT")
if [ "$(id -un)" != "$SPOOL_BOX_USER" ] && [ -z "${ASKS_ORC:-}" ]; then
  home="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)"
  cd "$orc" && exec sudo -n -u "$SPOOL_BOX_USER" env HOME="$home" "${vars[@]}" ./run -a "$action"
fi
cd "$orc" && exec env "${vars[@]}" ./run -a "$action"
