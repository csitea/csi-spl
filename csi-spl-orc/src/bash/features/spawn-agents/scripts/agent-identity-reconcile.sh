#!/usr/bin/env bash
# agent-identity-reconcile.sh — derive every agent window's name from the
# identity map ($SPOOL_ROOT/agents). The entry point the tmux hooks and the
# per-minute cron line call (both installed by do_spl_agent_identity_install);
# by hand, use ./run -a do_spl_agent_identity_reconcile.
#
# Usage: agent-identity-reconcile.sh [--apply] [--delay SEC]
#   --apply      write the records and rename (default: print the plan)
#   --delay SEC  wait first: a hook fires before the new pane's CLI has
#                started, so the new agent is not a process yet
# Settings come from ${XDG_CONFIG_HOME:-~/.config}/spool-agent/env when the
# environment lacks them (a tmux hook and cron start with a bare one).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/spool-agent/env"
for v in SPOOL_ROOT SPOOL_TMUX_SOCKET SPOOL_BOX_TAG; do
  [ -n "${!v:-}" ] || [ ! -r "$CFG" ] && continue
  val="$( . "$CFG" >/dev/null 2>&1; printf '%s' "${!v:-}" )"
  [ -n "$val" ] && export "$v=$val"
done
apply=() delay=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=(--apply); shift ;;
    --delay) delay="${2:?--delay needs seconds}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) echo "agent-identity-reconcile: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ "$delay" -gt 0 ] 2>/dev/null && sleep "$delay"
# shellcheck source=../lib/agent-identity.inc.sh
. "$HERE/../lib/agent-identity.inc.sh"
ai_reconcile "${apply[@]}"
