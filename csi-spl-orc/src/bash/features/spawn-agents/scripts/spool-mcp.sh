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
#               No id: a session the spool did not start (a plain `claude`
#               the owner runs by hand, SPL-2112) gets one minted on this box
#               (--mint <kind>, below); SPOOL_MCP_MINT=0 refuses instead (4).
#               It never borrows a person's identity or another agent's id:
#               an unseated server would act for anybody.
#   box side    <box state>/mcp/spool-mcp.sh --serve, run as the box user, who
#               owns the 0700 desk tree and the box key. The agent user never
#               reads either; it talks to the server over stdio only.
#               The desk is <box state>/cloud/<env>/desk/<tenant>/<box>
#               (box default box-desk; tenant: the one whose box holds a seat
#               dir for the id; with none or several, SPL-2112, the fleet
#               tenant's desk, else the first seated, else the first live one:
#               the WORKSPACE of a link comes from the link, so spool_read_link
#               and spool_reply follow it into any desk of this box, --desks).
#               The settings are the RUNNING sidecar's own
#               (SPOOL_ROOT, SPOOL_KEYS_DIR, SPOOL_BOX_ID, SPOOL_HUB_URL,
#               SPOOL_TENANT from /proc/<hub-run.pid>/environ), so the server
#               signs as the box the hub already knows and a send rides the
#               sidecar's warm socket (<root>/.hub/submit.sock). No live
#               sidecar -> refuse: nothing would arrive. SPOOL_FLEET_ROOT too
#               (SPL-3959): a seat's DM delivered on this desk is also copied
#               into the agent's inbox under the fleet root, the one a lane
#               reads; a lane's own DM here is refused (internal/mcp).
#               The binary is <box state>/mcp/spool, built by the install
#               action from its checkout and touched by nothing else (the desk
#               actions and the reconcile cron rebuild cloud/<env>/bin/spool).
#
# Agent-side config (written by the install): ${SPOOL_MCP_CONF:-
# ${XDG_CONFIG_HOME:-$HOME/.config}/spool-mcp/env} with SPOOL_MCP_BOX_USER and
# SPOOL_MCP_SERVE (the box-side path).
#
# The desk user (spec 069 section 8.3, row B5): when the box config names
# SPOOL_DESK_USER, the install puts the box side in THAT user's home, writes
# its cloud root to <box side dir>/state-root (read here in place of
# <box state>/cloud), and the config's SPOOL_MCP_BOX_USER is the desk user;
# SPOOL_MCP_TMUX_USER keeps the tmux server's user for the window lookup.
# Unset: no state-root and no SPOOL_MCP_TMUX_USER, as before.
# A desk that moves while it is served (do_spl_desk_move renames the source)
# ends the server: every SPOOL_MCP_WATCH_S seconds (default 5) the box side
# checks that the desk dir is still the one it started on, and when it is gone
# or replaced it stops `spool mcp` and exits 75. The CLI then starts
# spool-mcp again, which reads the config the cutover rewrote.
#
# Two more box-side modes, SPL-2112 (owner HUM-10, csitea topic e055195c: a
# hand-started claude, given a discussion link, reads it and contributes):
#   --mint <kind>  the agent half found no id: claim the next free id of that
#               kind (claude, grok, agy, qwen, mistral) with the fleet's own
#               allocator, next-agent-id.sh of the checkout the desk sidecar
#               runs from (its PROJ_PATH), in its fleet root. The id is a
#               spool dir like any agent id, and it is retired
#               (agent-id-retire.sh, seats included) on ANY exit of this box
#               half, a refusal after the mint too (SPL-3263). The record
#               <fleet root>/<id>/minted names the CLI's pid (ppid) and this
#               box half's (pid); a killed box half leaves it, and every mint
#               first starts, in the background, the minted-id reaper
#               (agent-id-reap.sh --minted --apply) that retires each minted
#               id whose recorded pids are gone (no window, no registry row).
#   --seat <env> <box> <tenant> <agent>   seat <agent> on <tenant>'s desk
#               with the existing action (do_spl_desk_up, DESK_POKE=0, of the
#               sidecar's checkout). `spool mcp --seat-cmd` runs it when
#               spool_reply posts into a workspace the seat has no seat in:
#               the reply is the request, no operator step.
#
# Exit codes before the server starts: 2 usage, 3 no config, 4 no agent id
# (unseated; SPOOL_MCP_MINT=0, or the mint failed), 5 a named tenant the id
# has no seat in (an unnamed one never refuses since SPL-2112), 6 no live
# sidecar, 7 no binary. After it started: the server's own code, or 75 when
# the desk moved away.
set -uo pipefail

say() { echo "spool-mcp: $*" >&2; }
# The id grammar of spool-env.inc.sh's SPOOL_ID_RE (specs/061: c-004, and the
# legacy CLE-07) - inlined: this file is installed as a copy. The hub refuses a
# legacy id after the cutoff, so this copy carries no clock.
ID_RE='^([acgmq]-[0-9]{3}|[A-Z]{2,4}-[0-9]+)$'

SERVE=0 AS="" MINT="" SEAT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --serve) SERVE=1; shift ;;
    --as) [ "$#" -ge 2 ] || { say "--as needs an id"; exit 2; }; AS="$2"; shift 2 ;;
    --mint) [ "$#" -ge 2 ] || { say "--mint needs a kind"; exit 2; }; MINT="$2"; shift 2 ;;
    --seat) SEAT=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
# The desk box defaults to this machine's (specs/058, as spl_desk_box_default in
# lib/bash/funcs/spl-desk-box.func.sh - inlined: this file is installed as a copy).
_desk_box="${SPOOL_DESK_BOX:-}"
[ -n "$_desk_box" ] || _desk_box="$(sed -n "s/^SPOOL_DESK_BOX=[\"']\{0,1\}\([a-z0-9-]*\).*/\1/p" "${SPOOL_BOX_ENV:-/var/spool-hub/box.env}" 2>/dev/null | tail -1)"
# The pid of the live `spool hub-run` sidecar of one desk dir, or nothing.
live_pid() {  # DESK_DIR
  local pid
  pid="$(cat "$1/spool/.hub/hub-run.pid" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null && printf '%s' "$pid"
}
# One variable of a live sidecar's environment (read, never sourced).
sidecar_var() {  # PID NAME
  tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p;T;q"
}
# The cloud root that holds the desks, <root>/<env>/desk/...: SPOOL_MCP_STATE_ROOT,
# else the desk user's root the install wrote to <box side dir>/state-root,
# else <box side dir>/../cloud (the box user's, as before).
state_root() {  # BOX_SIDE_DIR
  local r=""
  [ -r "$1/state-root" ] && r="$(head -n 1 "$1/state-root")"
  printf '%s' "${SPOOL_MCP_STATE_ROOT:-${r:-$(dirname "$1")/cloud}}"
}

if [ "$SEAT" = 1 ]; then
  # --seat <env> <box> <tenant> <agent>: called by `spool mcp --seat-cmd`.
  ENVN="${1:-}" BOX="${2:-}" TENANT="${3:-}" AS="${4:-}"
  [[ "$ENVN" =~ ^(dev|prd)$ && "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui &&
     "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$AS" =~ $ID_RE && "${AS%%-*}" != BOX ]] ||
    { say "usage: spool-mcp --seat <dev|prd> <desk box> <tenant> <agent id>"; exit 2; }
  HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  d="$(state_root "$HERE")/$ENVN/desk/$TENANT/$BOX"
  pid="$(live_pid "$d")" || { say "no live hub-run sidecar for $BOX in $TENANT ($ENVN): nothing to seat $AS on"; exit 6; }
  proj="$(sidecar_var "$pid" PROJ_PATH)"
  [ -x "$proj/run" ] || { say "the sidecar of $BOX in $TENANT names no checkout with ./run (PROJ_PATH '$proj')"; exit 7; }
  say "seating $AS on $BOX in $TENANT ($ENVN) on request: do_spl_desk_up of $proj"
  cd "$proj" && exec env PATH="/usr/local/bin:/usr/bin:/bin" ENV="$ENVN" TENANT_ID="$TENANT" DESK_AGENT="$AS" DESK_BOX="$BOX" \
    DESK_POKE=0 DRY_RUN=0 ./run -a do_spl_desk_up
fi

ENVN="${1:-}" TENANT="${2:-}" BOX="${3:-${_desk_box:-box-desk}}"
[[ "$ENVN" =~ ^(dev|prd)$ ]] || { say "usage: spool-mcp <dev|prd> [tenant] [desk box]"; exit 2; }
[[ -z "$TENANT" || "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "bad tenant '$TENANT'"; exit 2; }
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || { say "bad desk box '$BOX'"; exit 2; }

# ── agent side ───────────────────────────────────────────────────────────────
agent_id() {
  local id="${MCP_BOT_AGENT_ID:-${SPOOL_AGENT_ID:-}}" pane="${TMUX_PANE:-${CLE_TMUX_PANE:-}}" w
  local tu="${SPOOL_MCP_TMUX_USER:-$SPOOL_MCP_BOX_USER}"  # the tmux server's user, not the desk user's
  if [ -z "$id" ] && [ -n "$pane" ]; then
    w="$(sudo -n -u "$tu" tmux -S "${CLE_TMUX_SOCK:-/tmp/tmux-$(id -u "$tu")/default}" \
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
  declare -a who=(--as "$AS")
  if [ -z "$AS" ] && [ "${SPOOL_MCP_MINT:-1}" != 0 ]; then
    # A session the spool did not start (SPL-2112): the box mints its id. The
    # kind is the CLI that started this server (its parent process).
    kind="$(ps -o comm= -p "$PPID" 2>/dev/null | tr -d ' ')"
    case "$kind" in claude|grok|agy|qwen) ;; vibe|"VibeCLI") kind=mistral ;; *) kind=claude ;; esac
    who=(--mint "$kind")
  elif [[ ! "$AS" =~ $ID_RE ]]; then
    say "refusing to start unseated: no agent id (MCP_BOT_AGENT_ID / SPOOL_AGENT_ID / tmux window), got '${AS}'"; exit 4
  fi
  if [ "$(id -un)" = "$SPOOL_MCP_BOX_USER" ]; then
    exec bash "$SPOOL_MCP_SERVE" --serve "${who[@]}" "$ENVN" "$TENANT" "$BOX"
  fi
  exec sudo -n -u "$SPOOL_MCP_BOX_USER" -- "$SPOOL_MCP_SERVE" --serve "${who[@]}" "$ENVN" "$TENANT" "$BOX"
fi

# ── box side ─────────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE="$(state_root "$HERE")/$ENVN"
BIN="${SPOOL_MCP_BIN:-$HERE/spool}"
[ -x "$BIN" ] || { say "no spool binary at $BIN: run do_spl_agent_mcp_install"; exit 7; }
# The minted id is retired on every exit from here on: a refusal after the
# mint (5, 6) used to leave it holding the shared line for ever (SPL-3263).
retire_minted() {
  local out
  out="$(SPOOL_ROOT="${fleet:-/var/spool-hub}" SPOOL_DESK_BOX="$BOX" RETIRE_LANE=0 \
    bash "$proj/src/bash/features/spawn-agents/scripts/agent-id-retire.sh" --apply "$AS" 2>&1 </dev/null >/dev/null)" ||
    say "could not retire $AS (${out##*$'\n'}): agent-id-reap.sh --minted will"
}
if [ -n "$MINT" ]; then
  [[ "$MINT" =~ ^(claude|grok|agy|qwen|mistral)$ ]] || { say "--mint: '$MINT' is not an agent kind"; exit 2; }
  # The allocator and the fleet root of the checkout a live desk sidecar runs.
  mpid=""
  for dd in "$STATE"/desk/*/"$BOX"; do mpid="$(live_pid "$dd")" && break; done
  [ -n "$mpid" ] || { say "refusing to start unseated: no id, and no live desk sidecar on $BOX in $ENVN to mint one with"; exit 4; }
  proj="$(sidecar_var "$mpid" PROJ_PATH)" fleet="$(sidecar_var "$mpid" SPOOL_FLEET_ROOT)"
  alloc="$proj/src/bash/features/spawn-agents/scripts/next-agent-id.sh"
  [ -r "$alloc" ] || { say "refusing to start unseated: no id, and no allocator at '$alloc' (the sidecar's PROJ_PATH)"; exit 4; }
  # The ids earlier sessions minted and a kill left behind: retired in the
  # background (detached, no stdio), so this start does not wait for it.
  reap="$proj/src/bash/features/spawn-agents/scripts/agent-id-reap.sh"
  [ -r "$reap" ] && SPOOL_ROOT="${fleet:-/var/spool-hub}" SPOOL_DESK_BOX="$BOX" \
    setsid bash "$reap" --minted --apply </dev/null >/dev/null 2>&1 &
  AS="$(SPOOL_ROOT="${fleet:-/var/spool-hub}" bash "$alloc" --kind "$MINT" 2>/dev/null)"
  [[ "$AS" =~ $ID_RE ]] || { say "refusing to start unseated: the allocator minted no $MINT id (got '$AS')"; exit 4; }
  trap retire_minted EXIT
  printf 'minted %s by spool-mcp for a %s session the spool did not start (ppid %s, pid %s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MINT" "$PPID" "$$" >"${fleet:-/var/spool-hub}/$AS/minted" 2>/dev/null || true
  say "minted $AS for this $MINT session (retired when it ends)"
fi
[[ "$AS" =~ $ID_RE && "${AS%%-*}" != BOX ]] || { say "refusing to start unseated: --as '$AS' is not an agent id"; exit 4; }

if [ -z "$TENANT" ]; then
  # One seat: its tenant. None or several (SPL-2112): the fleet tenant's
  # desk, else the first seated, else the first live one; a link names its
  # own workspace (spool_read_link / spool_reply, --desks).
  mapfile -t seats < <(ls -d "$STATE"/desk/*/"$BOX"/spool/"$AS" 2>/dev/null)
  tenant_of() { basename "$(dirname "$(dirname "$(dirname "$1")")")"; }
  if [ "${#seats[@]}" = 1 ]; then
    TENANT="$(tenant_of "${seats[0]}")"
  else
    ft="$(sed -n "s/^SPOOL_FLEET_TENANT=[\"']\{0,1\}\([a-z0-9-]*\).*/\1/p" "${SPOOL_BOX_ENV:-/var/spool-hub/box.env}" 2>/dev/null | tail -1)"
    declare -a cand=()
    [ -n "$ft" ] && [ -d "$STATE/desk/$ft/$BOX/spool/$AS" ] && cand+=("$ft")
    for s in "${seats[@]}"; do cand+=("$(tenant_of "$s")"); done
    [ -n "$ft" ] && cand+=("$ft")
    for dd in "$STATE"/desk/*/"$BOX"; do [ -d "$dd" ] && cand+=("$(basename "$(dirname "$dd")")"); done
    for t in "${cand[@]}"; do live_pid "$STATE/desk/$t/$BOX" >/dev/null && { TENANT="$t"; break; }; done
    [ -n "$TENANT" ] || { say "$AS has ${#seats[@]} seats on $BOX in $ENVN and no desk there has a live hub-run sidecar: run do_spl_desk_up"; exit 6; }
    say "$AS has ${#seats[@]} seats on $BOX in $ENVN: serving from $TENANT's desk; spool_read_link / spool_reply take a link's workspace from the link"
  fi
  NAMED=0
else
  NAMED=1
fi
d="$STATE/desk/$TENANT/$BOX"
[ "$NAMED" = 0 ] || [ -d "$d/spool/$AS" ] || { say "$AS is not seated on $BOX in $TENANT ($ENVN): run do_spl_desk_up"; exit 5; }

pid="$(live_pid "$d")" || { say "no live hub-run sidecar for $BOX in $TENANT ($ENVN): run do_spl_desk_up"; exit 6; }
declare -a envv=()
while IFS= read -r -d '' kv; do
  case "${kv%%=*}" in
    SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_PINS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPOOL_MIRROR_LOCAL|SPOOL_MSG_VERSION|SPOOL_FLEET_ROOT) envv+=("$kv") ;;
  esac
done <"/proc/$pid/environ"
[ "${#envv[@]}" -ge 5 ] || { say "cannot read the sidecar's settings (pid $pid)"; exit 6; }

umask 022 # a spool_get_file dest must be readable by the agent user
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
declare -a serve=(env -i HOME="$HOME" PATH=/usr/bin:/bin USER="$(id -un)" SPOOL_LOG_LEVEL=error "${envv[@]}" "$BIN" mcp --as "$AS"
  --desks "$STATE/desk" --desk-box "$BOX" --seat-cmd "$SELF --seat $ENVN $BOX")
# Serve as a child, watched: a desk that moves away (renamed, or replaced by a
# copy at the same path: another dev:inode) stops the server, exit 75. A
# minted id lives as long as its session: the EXIT trap above retires it.
desk_ino() { stat -c '%d:%i' "$1" 2>/dev/null; }
ino="$(desk_ino "$d")"
exec 3<&0
"${serve[@]}" <&3 3<&- &
child=$!
exec 3<&-
trap 'kill -TERM "$child" 2>/dev/null' TERM INT HUP
(
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  while kill -0 "$child" 2>/dev/null && kill -0 "$$" 2>/dev/null; do
    sleep "${SPOOL_MCP_WATCH_S:-5}" & s=$!; wait "$s"
    [ "$(desk_ino "$d")" = "$ino" ] && continue
    # Past this line the verdict is 75: the main shell's TERM, sent once the
    # child it waits on ends, would otherwise run the trap above (exit 0) and
    # leave the child's 143 as the exit code (SPL-2913).
    trap '' TERM
    say "the desk $d moved away (gone or replaced): stopping $AS's server, so the CLI starts spool-mcp again"
    kill -TERM "$child" 2>/dev/null; exit 75
  done
) </dev/null >/dev/null &
watcher=$!
rc=0; wait "$child" || rc=$?
while kill -0 "$child" 2>/dev/null; do wait "$child" || rc=$?; done
kill -TERM "$watcher" 2>/dev/null; wrc=0; wait "$watcher" || wrc=$?
[ "$wrc" = 75 ] && rc=75
exit "$rc"
