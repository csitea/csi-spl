#!/usr/bin/env bash
# spawn-window.sh — create an agent's tmux window DETACHED in the box user's
# session and start its launcher in it.
#
# Usage: spawn-window.sh <claude|grok|agy|qwen> <TITLE|auto> <WORKDIR> [BRIEF_FILE] [SLUG]
#   TITLE "auto" allocates (and claims) the next free id with next-agent-id.sh;
#   an explicit TITLE is validated and claimed as-is (exit 3 when taken, unless
#   SPAWN_REUSE_ID=1, which respawns an id whose spool dir already exists).
#   stdout: "<ID> <PANE>" — the agent id and its pane id (%NN). Capture the pane
#   id, never a window index: indices move when the window bar is re-sorted.
#
# DRY RUN: SPAWN_DRY_RUN=1 claims no id, makes no window and pokes nothing: it
# prints `PLAN claim` / `PLAN window`, then runs the launcher in THIS process,
# where spawn-core's own dry run prints the rest of the plan (worktree, lane,
# spool dir, registry, launch) and changes nothing. The last stdout line is
# "<ID> -" (no pane). Before CLE-77968 the flag reached only the pane, after
# the claim and the window: a "dry run" spawned a real agent.
#
# VISIBILITY (hard requirement, unchanged from the box engine): the window goes
# into SPOOL_SESSION when set, else the session a client is ATTACHED to on the
# box user's socket ($SPOOL_TMUX_SOCKET), else that server's first session. It
# is created with `new-window -d` and nothing here ever runs select-window or
# refresh-client, so a spawn never steals the attached client's focus. Prove it
# with `tmux -S $SPOOL_TMUX_SOCKET list-windows -a`. Run it as anyone: tmux calls
# hop to $SPOOL_BOX_USER when needed.
#
# Exit: 0 ok, 2 usage, 3 id taken, 4 tmux printed no pane id, 5 no session.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$HERE/../lib/spool-env.inc.sh"
spool_env_resolve

usage() { sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2; exit 2; }

KIND="${1:-}"; TITLE="${2:-}"
case "$KIND" in claude|grok|agy|qwen) ;; *) usage ;; esac
[ -n "$TITLE" ] && [ -n "${3:-}" ] || usage
LAUNCHER="$HERE/spawn-$KIND.sh"
[ -r "$LAUNCHER" ] || { echo "spawn-window: no launcher $LAUNCHER" >&2; exit 2; }

# The session first: an id is claimed only once there is a window to put it
# in, so a spawn that cannot start leaves no orphan claim behind.
spool_tmux_argv
sess="${SPOOL_SESSION:-}"
if [ -z "$sess" ]; then
  sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_attached} #{session_id}' 2>/dev/null | awk '$1 > 0 {print $2; exit}')"
  [ -n "$sess" ] || sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_id}' 2>/dev/null | head -1)"
fi
[ -n "$sess" ] || { echo "spawn-window: no tmux session on ${SPOOL_TMUX_SOCKET}" >&2; exit 5; }

DRY=0; [ "${SPAWN_DRY_RUN:-0}" = 1 ] && DRY=1
if [ "$TITLE" = auto ]; then
  if [ "$DRY" = 1 ]; then
    TITLE="$(bash "$HERE/next-agent-id.sh" --kind "$KIND" --no-reserve)" || exit $?
  else
    TITLE="$(bash "$HERE/next-agent-id.sh" --kind "$KIND")" || exit $?
  fi
else
  spool_valid_id "$TITLE" || exit 2
  [ "$(spl_kind_of_agent_id "$TITLE")" = "$KIND" ] || { echo "spawn-window: ${TITLE} is not a ${KIND} id" >&2; exit 2; }
  if [ "${SPAWN_REUSE_ID:-0}" != 1 ]; then
    if [ "$DRY" = 1 ]; then
      [ ! -e "${SPOOL_ROOT}/${TITLE}" ] || { echo "spawn-window: ${TITLE} is taken (${SPOOL_ROOT}/${TITLE})" >&2; exit 3; }
    else
      bash "$HERE/next-agent-id.sh" --claim "$TITLE" >/dev/null || exit $?
    fi
  fi
fi
shift 2

if [ "$DRY" = 1 ]; then
  printf 'PLAN %-10s %s\n' claim "${TITLE} -> ${SPOOL_ROOT}/${TITLE}" \
    window "new-window -d -t ${sess}: -n $(spool_decorate "$TITLE") (socket ${SPOOL_TMUX_SOCKET})"
  bash "$LAUNCHER" "$TITLE" "$@" || exit $?
  printf '%s -\n' "$TITLE"
  exit 0
fi

# Size the session first: a detached window otherwise gets 80x24 for good.
"${SPOOL_TM[@]}" set-option -t "$sess" default-size "$(spool_tmux_default_size)" 2>/dev/null || true

# The launcher runs as the box user inside the pane and hops to the agent user
# itself. The SPOOL_* settings this caller resolved travel with it, because the
# tmux server does not inherit this process's environment.
envs=()
for v in SPOOL_ROOT SPOOL_BOX_USER SPOOL_AGENT_USER SPOOL_RUN_AS_AGENT SPOOL_TMUX_SOCKET \
         SPOOL_BOX_TAG SPOOL_ORCHESTRATOR_ID SPOOL_BIN CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN SPAWN_GIT_IDENTITY \
         SPAWN_LANE_SCOPE SPAWN_LANE_FILES SPAWN_LANE_TOPIC LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX; do
  [ -n "${!v:-}" ] && envs+=("$v=${!v}")
done
printf -v cmd '%q ' env "${envs[@]}" bash "$LAUNCHER" "$TITLE" "$@"

# The pane id is the first line that IS one: an after-new-window hook that
# prints shares new-window -P's output.
out="$("${SPOOL_TM[@]}" new-window -d -t "${sess}:" -n "$(spool_decorate "$TITLE")" -P -F '#{pane_id}' "$cmd")"; rc=$?
pane="$(printf '%s\n' "$out" | grep -m1 -xE '%[0-9]+')"
[ -n "$pane" ] || { echo "spawn-window: new-window (rc=$rc) printed no pane id: ${out:-<nothing>}" >&2; exit 4; }

# The notice strip is split NOW, before the CLI has painted anything, so the
# TUI starts at the size it will keep and never takes a mid-session resize.
#
# That ordering is the fix, and the ONLY complete one. Measured on tmux 3.5a
# against a pane already on the alternate screen at 189x51, with a subject
# shaped like an agent CLI - static transcript, live frame repainted on
# SIGWINCH (spool-strip-resize-proof.sh):
#
#   a HEIGHT split destroys the top rows and moves everything under them
#   a WIDTH split moves nothing, and clips every transcript line at the new
#     width, permanently - no process holds a copy to repaint
#
# So a right-hand strip is strictly better than a bottom bar for a CLI that is
# already running, and it is still not free. Splitting BEFORE the CLI paints
# costs nothing at all: the pane has drawn nothing yet, and there is no later
# resize to survive.
#
# Never fatal: a window with no strip is still a window, the notifier will
# split one on the first message, and a spawn that failed for this would be a
# far worse outcome than a missing strip.
#
# The agy CLI paints on the NORMAL screen (alternate_on 0), so without a mark
# the notifier would read its pane as a bare shell: no strip, and every notice
# written into the tty over agy's UI. The launcher knows what it started, so
# it says so on the pane (@spool_strip, lib/spool-poke-queue.inc.sh).
if [ "$KIND" = agy ]; then
  "${SPOOL_TM[@]}" set-option -p -t "$pane" @spool_strip 1 2>/dev/null || true
fi
if [ "${SPOOL_SHOW_PANE:-auto}" != 0 ]; then
  # shellcheck source=../lib/spool-notify.inc.sh
  if . "$HERE/../lib/spool-notify.inc.sh" 2>/dev/null &&
     . "$HERE/../lib/spool-poke-queue.inc.sh" 2>/dev/null; then
    spool_show_notice_pane "$TITLE" "$pane" >/dev/null 2>&1 || true
  fi
fi

printf '%s %s\n' "$TITLE" "$pane"
