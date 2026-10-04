#!/usr/bin/env bash
# Ported from the frozen box engine's tmux-windows feature (specs/069 Y5):
# the same colours, target rules and exit codes, on this feature's resolver
# (lib/spool-env.inc.sh: server owner, socket, box tag) and window-name rules
# (lib/agent-state.inc.sh).
#
# tmux-window-color.sh — colour one tmux window's entry in the status bar.
#
#   tmux-window-color.sh [--agent ID | --target %PANE|@WINDOW] <colour>
#   tmux-window-color.sh --list
#
# Colours:
#   blue    white on blue        default / active work
#   red     white on red         blocked / error
#   green   black on green       done / healthy
#   yellow  black on yellow      waiting / needs attention
#   orange  black on colour208   warning
#   purple  white on magenta     special / tooling
#   cyan    black on cyan        info
#   pink    black on colour213   personal
#   white   black on white       neutral
#   reset   back to the theme
#
# The window's CURRENT style becomes "fg=<fg>,bg=<bg>,bold"; its OTHER style
# is tinted "fg=<bg>,bg=default", so the window stays recognisable when it is
# not focused. The colour name is also kept in the window option @window-colour.
#
# TARGET, first match wins: --target (a pane id %N or a window id @N; never an
# index, which the sorter moves), --agent ID (the window whose name carries
# that id, tagged or not), then $TMUX_PANE, $CLE_TMUX_PANE, $GRK_TMUX_PANE,
# $AGY_TMUX_PANE, $QWN_TMUX_PANE. Runs as anyone: tmux calls hop to the
# server owner ($SPOOL_BOX_USER).
#
# Exit: 0 applied; 1 bad usage or unknown colour; 2 no target, or no server.
set -uo pipefail

_tw_lib="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_tw_lib/spool-env.inc.sh" || { echo "tmux-window-color: cannot load $_tw_lib/spool-env.inc.sh" >&2; exit 2; }
# shellcheck source=../lib/agent-state.inc.sh
. "$_tw_lib/agent-state.inc.sh" || { echo "tmux-window-color: cannot load $_tw_lib/agent-state.inc.sh" >&2; exit 2; }

COLOURS="blue red green yellow orange purple cyan pink white reset"

colour_of() {  # NAME -> sets FG BG; 1 when unknown
  case "$1" in
    blue)   FG=white; BG=blue ;;
    red)    FG=white; BG=red ;;
    green)  FG=black; BG=green ;;
    yellow) FG=black; BG=yellow ;;
    orange) FG=black; BG=colour208 ;;
    purple) FG=white; BG=magenta ;;
    cyan)   FG=black; BG=cyan ;;
    pink)   FG=black; BG=colour213 ;;
    white)  FG=black; BG=white ;;
    reset)  FG=""; BG="" ;;
    *) return 1 ;;
  esac
}

usage() { sed -n '/^#   tmux-window-color\.sh /p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2; exit 1; }

AGENT="" TARGET="" COLOUR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)    AGENT="${2:?--agent requires an id}"; shift 2 ;;
    --agent=*)  AGENT="${1#*=}"; shift ;;
    --target)   TARGET="${2:?--target requires %PANE or @WINDOW}"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --socket)   SPOOL_TMUX_SOCKET="${2:?--socket requires a path}"; shift 2 ;;
    --list)     printf '%s\n' $COLOURS; exit 0 ;;
    -h|--help)  sed -n '/^# tmux-window-color\.sh — /,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    -*)         echo "tmux-window-color: unknown option: $1" >&2; usage ;;
    *)          [ -z "$COLOUR" ] || usage; COLOUR="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; shift ;;
  esac
done
[ -n "$COLOUR" ] || usage
colour_of "$COLOUR" || { echo "tmux-window-color: unknown colour '$COLOUR' (one of: $COLOURS)" >&2; exit 1; }

SPOOL_ENV_NO_BINS=1 spool_env_resolve
# Only the server's owner may talk to it. -n: never hang on a password prompt
# nobody can see.
TM=(tmux -u -S "$SPOOL_TMUX_SOCKET")
[ "$(id -un)" = "$SPOOL_BOX_USER" ] || TM=(sudo -n -u "$SPOOL_BOX_USER" tmux -u -S "$SPOOL_TMUX_SOCKET")
# Asked through the owner hop, not with `[ -S ]`: the socket dir is mode 0700.
"${TM[@]}" list-sessions >/dev/null 2>&1 || { echo "tmux-window-color: no tmux server at $SPOOL_TMUX_SOCKET" >&2; exit 2; }

# Exact match against the live lists: display-message -t <gone target> prints
# the ACTIVE window instead of failing, which would colour the wrong window.
target_exists() {
  case "$1" in
    %*) "${TM[@]}" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -xF -- "$1" >/dev/null ;;
    @*) "${TM[@]}" list-windows -a -F '#{window_id}' 2>/dev/null | grep -xF -- "$1" >/dev/null ;;
    *)  return 1 ;;
  esac
}

agent_window() {  # ID -> window id of the first window whose name carries that id
  local w n id up
  up="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  while IFS='	' read -r w n; do
    id="$(an_strip "$n")"; id="${id%% *}"
    if [ "$id" = "$1" ] || [ "$id" = "$up" ]; then printf '%s' "$w"; return 0; fi
  done < <("${TM[@]}" list-windows -a -F '#{window_id}	#{window_name}' 2>/dev/null)
  return 1
}

if [ -n "$TARGET" ]; then
  case "$TARGET" in %*|@*) ;; *) echo "tmux-window-color: --target must be a pane id (%N) or window id (@N), never an index" >&2; exit 1 ;; esac
elif [ -n "$AGENT" ]; then
  TARGET="$(agent_window "$AGENT")" || { echo "tmux-window-color: no live window for agent '$AGENT'" >&2; exit 2; }
else
  TARGET="${TMUX_PANE:-${CLE_TMUX_PANE:-${GRK_TMUX_PANE:-${AGY_TMUX_PANE:-${QWN_TMUX_PANE:-}}}}}"
  [ -n "$TARGET" ] || { echo "tmux-window-color: no target (no --target/--agent, \$TMUX_PANE unset — a sudo hop strips it; pass --agent ID)" >&2; exit 2; }
fi
target_exists "$TARGET" || { echo "tmux-window-color: target '$TARGET' does not exist on $SPOOL_TMUX_SOCKET" >&2; exit 2; }

if [ "$COLOUR" = reset ]; then
  "${TM[@]}" set-option -w -u -t "$TARGET" window-status-current-style \; \
             set-option -w -u -t "$TARGET" window-status-style \; \
             set-option -w -u -t "$TARGET" @window-colour 2>/dev/null
else
  "${TM[@]}" set-option -w -t "$TARGET" window-status-current-style "fg=${FG},bg=${BG},bold" \; \
             set-option -w -t "$TARGET" window-status-style "fg=${BG},bg=default" \; \
             set-option -w -t "$TARGET" @window-colour "$COLOUR"
fi || { echo "tmux-window-color: tmux refused the style for '$TARGET'" >&2; exit 2; }
echo "tmux-window-color: $TARGET -> $COLOUR"
