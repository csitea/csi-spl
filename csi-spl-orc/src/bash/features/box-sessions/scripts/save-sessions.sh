#!/usr/bin/env bash
# save-sessions.sh — snapshot every window of the box's tmux server into
# <state dir>/state.tsv, once a minute from the box user's crontab (spec 069
# C1, the csi-spl copy of the engine's claude-save-sessions). sessions-boot.sh
# reads it after a reboot.
#
# One row per window: session, index, name, cwd, active, kind, agent id.
#   agent   the name carries an agent id and the pane runs something
#   exited  the name carries an agent id and the pane is a bare prompt
#           (nothing under it): the agent ended, nothing comes back for it
#   shell   any other window: recreated as a shell in its cwd
# An agent's own session, worktree and user are NOT kept here: the identity
# map ($SPOOL_ROOT/agents) has them, and do_spl_agent_boot_restore starts the
# agents from it. This file only says which seats and windows existed.
#
# It never clobbers a good state. Each of these keeps the previous state.tsv:
#   * no tmux server, or a server with no windows;
#   * the boot restore (or another save) holds the lock;
#   * a server younger than BOX_SESSIONS_SAVE_GRACE_SEC that no boot restore
#     has run on yet (cron's first minute after a reboot beats the restore).
#
# Settings (env):
#   BOX_SESSIONS_DIR            state dir, default /var/<org>/<org>-<app>/box-sessions
#   BOX_SESSIONS_TMUX_SOCKET    tmux socket, else SPOOL_TMUX_SOCKET, else /tmp/tmux-<uid>/default
#   BOX_SESSIONS_SAVE_GRACE_SEC default 600; 0 = off
#   BOX_SESSIONS_ARCHIVE_KEEP   snapshots kept under archive/, default 60
#   BOX_SESSIONS_LOG_MAX_BYTES  save.log is trimmed past this, default 1048576
#
# Usage: save-sessions.sh            (append one line to <state dir>/save.log)
#        save-sessions.sh --stdout   (log to stdout instead)
# Exit: 0 saved or deliberately kept; 1 the state dir or the write failed;
#       2 usage or a missing library.
set -uo pipefail

BS_SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BS_ORC="$(cd "$BS_SELF/../../../../.." && pwd)"
# shellcheck source=../../spawn-agents/lib/spool-env.inc.sh
. "$BS_SELF/../../spawn-agents/lib/spool-env.inc.sh" || exit 2

bs_org_app="$(basename "$BS_ORC")"; bs_org_app="${bs_org_app%-orc}"
BS_DIR="${BOX_SESSIONS_DIR:-/var/${bs_org_app%%-*}/$bs_org_app/box-sessions}"
BS_SOCK="${BOX_SESSIONS_TMUX_SOCKET:-${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}}"
BS_GRACE="${BOX_SESSIONS_SAVE_GRACE_SEC:-600}"
BS_KEEP="${BOX_SESSIONS_ARCHIVE_KEEP:-60}"
BS_LOG_MAX="${BOX_SESSIONS_LOG_MAX_BYTES:-1048576}"
BS_STATE="$BS_DIR/state.tsv"
BS_HEADER=$'#session\tindex\tname\tcwd\tactive\tkind\tid'
TAG="box-sessions save"

case "${1:-}" in
  --stdout|"") ;;
  *) echo "save-sessions: unknown argument: $1" >&2; exit 2 ;;
esac
for v in BS_GRACE BS_KEEP BS_LOG_MAX; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "save-sessions: $v must be a number, got '${!v}'" >&2; exit 2; }
done

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
# 9>&-: a server this starts must not inherit the lock fd and hold it forever.
btmux() { tmux -u -S "$BS_SOCK" "$@" 9>&-; }

mkdir -p "$BS_DIR/archive" 2>/dev/null || { echo "$TAG: cannot create $BS_DIR" >&2; exit 1; }
if [ "${1:-}" != --stdout ]; then
  if [ "$(stat -c %s "$BS_DIR/save.log" 2>/dev/null || echo 0)" -gt "$BS_LOG_MAX" ]; then
    tail -c "$((BS_LOG_MAX / 2))" "$BS_DIR/save.log" > "$BS_DIR/save.log.trim" && mv -f "$BS_DIR/save.log.trim" "$BS_DIR/save.log"
  fi
  exec >> "$BS_DIR/save.log" 2>&1
fi

exec 9>>"$BS_DIR/.lock" || { log "$TAG: cannot open $BS_DIR/.lock"; exit 1; }
flock -n 9 || { log "$TAG: the boot restore or another save holds the lock - skipped"; exit 0; }

if ! btmux has-session 2>/dev/null; then
  log "$TAG: no tmux server at $BS_SOCK - previous state kept"; exit 0
fi
srv="$(btmux display -p '#{pid} #{start_time}' 2>/dev/null)"
srv_pid="${srv%% *}"; srv_start="${srv##* }"
if [ "$BS_GRACE" -gt 0 ] && [ -s "$BS_STATE" ] && [[ "$srv_start" =~ ^[0-9]+$ ]] \
   && [ ! -e "$BS_DIR/.restored.$srv_pid.$srv_start" ] \
   && [ $(( $(date +%s) - srv_start )) -lt "$BS_GRACE" ]; then
  log "$TAG: tmux server $srv_pid is younger than ${BS_GRACE}s and no boot restore ran on it - previous state kept"
  exit 0
fi

# Each field carries a "." prefix so an empty one survives the TAB split.
data="$(btmux list-windows -a -F '.#{session_name}	.#{window_index}	.#{window_name}	.#{pane_current_path}	.#{window_active}	.#{pane_pid}' 2>/dev/null)"
[ -n "$data" ] || { log "$TAG: no windows - previous state kept"; exit 0; }

tmp="$(mktemp "$BS_DIR/.state.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
printf '%s\n' "$BS_HEADER" > "$tmp"
rows=0; agents=0; exited=0
while IFS= read -r line; do
  IFS=$'\t' read -r -a f <<< "$line"
  s="${f[0]#.}"; i="${f[1]#.}"; nm="${f[2]#.}"; c="${f[3]#.}"; a="${f[4]#.}"; p="${f[5]#.}"
  [ -n "$i" ] || continue
  spool_id_of_window_var id "$nm"
  kind=shell
  if [ -n "$id" ]; then
    # A bare prompt: the pane's process is alive with nothing under it.
    if [ -d "/proc/$p" ] && [ -z "$(pgrep -P "$p" 2>/dev/null)" ]; then kind=exited; exited=$((exited + 1))
    else kind=agent; agents=$((agents + 1)); fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$i" "$nm" "${c:--}" "${a:-0}" "$kind" "${id:--}" >> "$tmp"
  rows=$((rows + 1))
done <<< "$data"

chmod 0644 "$tmp"
mv -f "$tmp" "$BS_STATE" || { log "$TAG: replacing $BS_STATE FAILED"; exit 1; }
cp -f "$BS_STATE" "$BS_DIR/archive/state.$(date -u +%Y%m%dT%H%M%SZ).tsv"
# shellcheck disable=SC2012  # the names are our own timestamps
ls -t "$BS_DIR"/archive/state.*.tsv 2>/dev/null | tail -n +$((BS_KEEP + 1)) | xargs -r rm -f
log "$TAG: $rows windows ($agents agent seats, $exited exited) -> $BS_STATE"
