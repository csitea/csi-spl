#!/usr/bin/env bash
# spool-mcp.sh — the spool MCP server of ONE agent seat, for agent CLIs
# (claude, grok, agy) registered as `spool-<env>`:
#
#   spool-mcp <dev|prd> [tenant] [desk box]
#
# It serves `spool mcp --as <ID>`: the five spool tools (spool_send,
# spool_recv, spool_put_file, spool_get_file, spool_tail) acting for the
# CALLING agent only. from / as default to that id and any other id is refused
# (exit 78), so an agent reads and archives no inbox but its own.
#
# Two halves of this one script, installed by do_spl_agent_mcp_install:
#   agent side  <agent home>/.local/bin/spool-mcp, run by the CLI as the agent
#               user. Resolves the id and hops ONCE, at session start, to the
#               box user (sudo resets the env, so the id travels as --as):
#                 $MCP_BOT_AGENT_ID > $SPOOL_AGENT_ID > the tmux window name
#                 of $TMUX_PANE / $CLE_TMUX_PANE (^(<tag>: )?<ID>)
#               No id -> it refuses to start: an unseated server would act for
#               anybody.
#   box side    <box state>/mcp/spool-mcp.sh --serve, run as the box user, who
#               owns the 0700 desk tree and the box key. The agent user never
#               reads either; it talks to the server over stdio only.
#               The desk is <box state>/cloud/<env>/desk/<tenant>/<box>
#               (box default box-desk; tenant: the one whose box holds a seat
#               dir for the id). The settings are the RUNNING sidecar's own
#               (SPOOL_ROOT, SPOOL_KEYS_DIR, SPOOL_BOX_ID, SPOOL_HUB_URL,
#               SPOOL_TENANT from /proc/<hub-run.pid>/environ), so the server
#               signs as the box the hub already knows and a send rides the
#               sidecar's warm socket (<root>/.hub/submit.sock). No live
#               sidecar -> refuse: nothing would arrive.
#               The binary is <box state>/mcp/spool, built by the install
#               action from its checkout and touched by nothing else (the desk
#               actions and the reconcile cron rebuild cloud/<env>/bin/spool).
#
# Agent-side config (written by the install): ${SPOOL_MCP_CONF:-
# ${XDG_CONFIG_HOME:-$HOME/.config}/spool-mcp/env} with SPOOL_MCP_BOX_USER and
# SPOOL_MCP_SERVE (the box-side path).
#
# Exit codes before the server starts: 2 usage, 3 no config, 4 no agent id
# (unseated), 5 no seat / ambiguous seat, 6 no live sidecar, 7 no binary.
set -uo pipefail

say() { echo "spool-mcp: $*" >&2; }
# The id grammar of spool-env.inc.sh's SPOOL_ID_RE (specs/061: c-004, and the
# legacy CLE-07) - inlined: this file is installed as a copy. The hub refuses a
# legacy id after the cutoff, so this copy carries no clock.
ID_RE='^([acgmq]-[0-9]{3}|[A-Z]{2,4}-[0-9]+)$'

SERVE=0 AS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --serve) SERVE=1; shift ;;
    --as) [ "$#" -ge 2 ] || { say "--as needs an id"; exit 2; }; AS="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
# The desk box defaults to this machine's (specs/058, as spl_desk_box_default in
# lib/bash/funcs/spl-desk-box.func.sh - inlined: this file is installed as a copy).
_desk_box="${SPOOL_DESK_BOX:-}"
[ -n "$_desk_box" ] || _desk_box="$(sed -n "s/^SPOOL_DESK_BOX=[\"']\{0,1\}\([a-z0-9-]*\).*/\1/p" "${SPOOL_BOX_ENV:-/var/spool-hub/box.env}" 2>/dev/null | tail -1)"
ENVN="${1:-}" TENANT="${2:-}" BOX="${3:-${_desk_box:-box-desk}}"
[[ "$ENVN" =~ ^(dev|prd)$ ]] || { say "usage: spool-mcp <dev|prd> [tenant] [desk box]"; exit 2; }
[[ -z "$TENANT" || "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "bad tenant '$TENANT'"; exit 2; }
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || { say "bad desk box '$BOX'"; exit 2; }

# ── agent side ───────────────────────────────────────────────────────────────
agent_id() {
  local id="${MCP_BOT_AGENT_ID:-${SPOOL_AGENT_ID:-}}" pane="${TMUX_PANE:-${CLE_TMUX_PANE:-}}" w
  if [ -z "$id" ] && [ -n "$pane" ]; then
    w="$(sudo -n -u "$SPOOL_MCP_BOX_USER" tmux -S "${CLE_TMUX_SOCK:-/tmp/tmux-$(id -u "$SPOOL_MCP_BOX_USER")/default}" \
          display-message -p -t "$pane" '#W' 2>/dev/null)"
    id="$(printf '%s\n' "$w" | sed -nE 's/^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|[A-Z]{2,4}-[0-9]+)(@[a-z0-9][a-z0-9-]*)?( .*)?$/\2/p')"
  fi
  printf '%s' "$id"
}

if [ "$SERVE" = 0 ]; then
  conf="${SPOOL_MCP_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/spool-mcp/env}"
  # shellcheck disable=SC1090
  [ -r "$conf" ] && . "$conf"
  [ -n "${SPOOL_MCP_BOX_USER:-}" ] && [ -n "${SPOOL_MCP_SERVE:-}" ] ||
    { say "no box user / box-side path in $conf: run do_spl_agent_mcp_install"; exit 3; }
  [ -n "$AS" ] || AS="$(agent_id)"
  [[ "$AS" =~ $ID_RE ]] || {
    say "refusing to start unseated: no agent id (MCP_BOT_AGENT_ID / SPOOL_AGENT_ID / tmux window), got '${AS}'"; exit 4; }
  if [ "$(id -un)" = "$SPOOL_MCP_BOX_USER" ]; then
    exec bash "$SPOOL_MCP_SERVE" --serve --as "$AS" "$ENVN" "$TENANT" "$BOX"
  fi
  exec sudo -n -u "$SPOOL_MCP_BOX_USER" -- "$SPOOL_MCP_SERVE" --serve --as "$AS" "$ENVN" "$TENANT" "$BOX"
fi

# ── box side ─────────────────────────────────────────────────────────────────
[[ "$AS" =~ $ID_RE && "${AS%%-*}" != BOX ]] || { say "refusing to start unseated: --as '$AS' is not an agent id"; exit 4; }
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE="${SPOOL_MCP_STATE_ROOT:-$(dirname "$HERE")/cloud}/$ENVN"
BIN="${SPOOL_MCP_BIN:-$HERE/spool}"
[ -x "$BIN" ] || { say "no spool binary at $BIN: run do_spl_agent_mcp_install"; exit 7; }

if [ -z "$TENANT" ]; then
  mapfile -t seats < <(ls -d "$STATE"/desk/*/"$BOX"/spool/"$AS" 2>/dev/null)
  [ "${#seats[@]}" = 1 ] || {
    say "$AS has ${#seats[@]} seats on $BOX in $ENVN (${seats[*]:-none}): seat it with do_spl_desk_up, or name the tenant"; exit 5; }
  TENANT="$(basename "$(dirname "$(dirname "$(dirname "${seats[0]}")")")")"
fi
d="$STATE/desk/$TENANT/$BOX"
[ -d "$d/spool/$AS" ] || { say "$AS is not seated on $BOX in $TENANT ($ENVN): run do_spl_desk_up"; exit 5; }

pid="$(cat "$d/spool/.hub/hub-run.pid" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null ||
  { say "no live hub-run sidecar for $BOX in $TENANT ($ENVN): run do_spl_desk_up"; exit 6; }
declare -a envv=()
while IFS= read -r -d '' kv; do
  case "${kv%%=*}" in
    SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_PINS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPOOL_MIRROR_LOCAL|SPOOL_MSG_VERSION) envv+=("$kv") ;;
  esac
done <"/proc/$pid/environ"
[ "${#envv[@]}" -ge 5 ] || { say "cannot read the sidecar's settings (pid $pid)"; exit 6; }

umask 022 # a spool_get_file dest must be readable by the agent user
exec env -i HOME="$HOME" PATH=/usr/bin:/bin USER="$(id -un)" SPOOL_LOG_LEVEL=error "${envv[@]}" "$BIN" mcp --as "$AS"
