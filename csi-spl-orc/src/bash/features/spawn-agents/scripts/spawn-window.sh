#!/usr/bin/env bash
# spawn-window.sh — create an agent's tmux window DETACHED in the box user's
# session and start its launcher in it.
#
# Usage: spawn-window.sh <claude|grok|agy|qwen|mistral> <TITLE|auto> <WORKDIR> [BRIEF_FILE] [SLUG]
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
# START CHECK: a claude window is watched up to SPAWN_START_CHECK_WAIT (45 s)
# for its input box (lib/start-check.inc.sh). A known dialog on it (Settings
# Warning, trust prompt, auth/login, usage limit, auto-mode offer) = exit 11
# at once, "<ID> <PANE>" still printed and the dialog named on stderr; the
# window stays for a human and nothing is typed into it. No box in time, or
# the pane ended: one WARN, exit 0. SPAWN_START_CHECK=0 skips it (the
# rotation and the agent restart run their own after the pid is known).
#
# Exit: 0 ok, 2 usage, 3 id taken, 4 tmux printed no pane id, 5 no session,
# 6 this machine is draining (do_spl_box_leave; do_spl_box_join ends it),
# 7 refused by the peer gate (spec 068 L5: a seat spawns only under the
# `spawn` mutex with its fence held; do_spl_peer_gate says why), 8 the
# remote spawn on an explicit SPAWN_BOX did not start (PLACEMENT below),
# 9 the requester is a lane, 10 HOLD: every fleet box is at or above the
# load target's high mark (LOAD TARGET below), so queue the lane, 11 the
# new session is stopped on a dialog (START CHECK above). Only c-001, c-002 and c-003 (any box), or a
# shell with no agent id, may spawn. The id is the caller's SPOOL_AGENT_ID
# or MCP_BOT_AGENT_ID, else the window or registry row of $TMUX_PANE, else
# the closest ancestor that still carries the id (`sudo -u` strips it from
# the child). SPAWN_ALLOW_LANE=1 with a reason in SPAWN_ALLOW_REASON allows
# a lane and appends one line to $SPOOL_ROOT/spawn-allow.log. The registry
# row's last column is that requester ("-" when there is no agent id).
#
# PEER GATE: with <spool root>/peer/seats present, a seat (PEER_SEAT, else
# SPOOL_AGENT_ID) spawns only for the message it holds (PEER_MSG, PEER_GEN):
# do_spl_peer_gate re-checks that fence and takes the fleet mutex `spawn`
# first, so two seats never spawn at once past the 40-window ceiling. A dry
# run only reads the mutex. No seats file (order A) = the gate is not called.
#
# PLACEMENT (owner GO 2026-10-03, real load 2026-10-04): a NEW lane (TITLE
# auto) starts on the fleet box with the fewest BUSY agents, so lanes stop
# piling onto the box the orchestrator runs on. The count is the fleet lane
# map's load (`lane-map.sh --json`, .load): the agents with a live pane on each
# box NOW (this box reads its tmux, another box its own BOX-0 report row; an
# older box without one falls back to its rows of the last 2 h), role seats
# not counted; boxes from lease.conf. Fewest busy wins; on a tie the most free
# memory (MemAvailable; unknown ranks last); then here. A box below
# SPAWN_MEM_FLOOR_MB free (default 4096) is skipped, and only a box that is up
# (a pane, a report or a live row) is a candidate; with no candidate the lane
# stays here. The lane then starts there through `spawn-remote.sh --box <box>`, and
# stdout is its "<ID>@<box> <PANE>". It runs only in a fleet (LANE_FLEET, or
# LEASE_FLEET in lease.conf) and only while THIS box holds the orch lease (the
# remote serve accepts nobody else). A remote spawn that fails, is refused or
# does not answer within SPAWN_REMOTE_WAIT falls back to this box, with a
# WARN on stderr. SPAWN_BOX=<box> always wins (local, or this box's id, =
# here), and never falls back (exit 8): lanes that need one box's checkout
# or browser set it. The remote serve's spawn-window never re-places: that
# box does not hold the orch lease. An explicit
# TITLE is never moved without SPAWN_BOX. Seams (tests): SPAWN_PLACE_MAP_CMD
# prints the lane map JSON, SPAWN_REMOTE_CMD replaces spawn-remote.sh; a dry
# run without SPAWN_REMOTE_CMD prints the PLAN and stops ("auto@<box> -").
#
# LOAD TARGET (owner HUM-10, t1 c13e8023): before the busy count, the same
# new lane asks do_spl_box_pick, which reads the hub's fleet load target
# (rdb 0118: the band, 50..75 % of cores by default, and the box fill order)
# and each box's latest load5 / cpus. `pick=<box>` places the lane there;
# `pick=hold` (every box at or above its high mark) spawns NOTHING and exits
# 10 so the requester queues the lane; no pick line (the action failed) falls
# back to the busy count above, with a WARN. SPAWN_BOX still wins, and the
# 40-window ceiling is unchanged. Seams: SPAWN_BOX_PICK_CMD replaces the
# action; SPAWN_BOX_PICK=0 skips it (the busy count alone). A spawner that is
# not SPOOL_BOX_USER (the agent user) runs the action as SPOOL_BOX_USER, with
# its HOME, whose state dir holds the seated desk (seam SPAWN_PICK_HOP_CMD,
# default "sudo -n -u").
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$HERE/../lib/spool-env.inc.sh"
spool_env_resolve

usage() { sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2; exit 2; }

KIND="${1:-}"; TITLE="${2:-}"
case "$KIND" in claude|grok|agy|qwen|mistral) ;; *) usage ;; esac
[ -n "$TITLE" ] && [ -n "${3:-}" ] || usage
LAUNCHER="$HERE/spawn-$KIND.sh"
[ -r "$LAUNCHER" ] || { echo "spawn-window: no launcher $LAUNCHER" >&2; exit 2; }
# Before a claim, a window, or a remote placement: a lane must not start one.
SPAWN_REQUESTER="$(spool_spawn_gate)" || exit $?
export SPAWN_REQUESTER
[ ! -e "${SPOOL_ROOT}/dispatch/box.leave" ] || { echo "spawn-window: this machine is draining ($(head -c 200 "${SPOOL_ROOT}/dispatch/box.leave")): spawn on another box, or run ./run -a do_spl_box_join here" >&2; exit 6; }
# shellcheck source=../lib/spool-fleet.inc.sh
. "$HERE/../lib/spool-fleet.inc.sh"
# The box this lane starts on; "" = here.
place_box() {
  local want="${SPAWN_BOX:-}" here json holder="" fleet floor
  here="$(spool_fleet_box)"
  case "$want" in local|"$here") return 0 ;; esac
  if [ -n "$want" ]; then
    [[ "$want" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "spawn-window: SPAWN_BOX must be local or ONE box id, got '$want'" >&2; return 2; }
    printf '%s' "$want"; return 0
  fi
  [ "$TITLE" = auto ] || return 0
  fleet="${LANE_FLEET:-$(_spool_fleet_conf LEASE_FLEET)}"
  [ -n "$fleet" ] || return 0
  [ -r "$SPOOL_ROOT/dispatch/lease.orch" ] && read -r holder _ <"$SPOOL_ROOT/dispatch/lease.orch"
  case "$holder" in ""|*@"$here") ;; *) return 0 ;; esac
  if [ "${SPAWN_BOX_PICK:-1}" != 0 ]; then
    local out pick k pick_hop=()
    # The desk state (the seated desk, its hub key) lives under the BOX user's
    # HOME: an agent-user spawner hops there, the way lane-map.sh does.
    if [ "$(id -un)" != "$SPOOL_BOX_USER" ]; then
      # shellcheck disable=SC2206 # a command prefix, split on purpose
      pick_hop=(${SPAWN_PICK_HOP_CMD:-sudo -n -u} "$SPOOL_BOX_USER" env HOME="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)" "SPOOL_ROOT=$SPOOL_ROOT")
      for k in ENV BOX_PICK_SINCE BOX_PICK_OVERFLOW BOX_PICK_CNF LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_BOX SPOOL_DESK_BOX SPOOL_BOX_ENV; do
        [ -n "${!k:-}" ] && pick_hop+=("$k=${!k}")
      done
    fi
    if [ -n "${SPAWN_BOX_PICK_CMD:-}" ]; then
      # shellcheck disable=SC2086 # a command line, split on purpose
      out="$($SPAWN_BOX_PICK_CMD 2>&1)"
    else
      out="$(timeout "${SPAWN_PLACE_TIMEOUT:-60}" "${pick_hop[@]}" bash "${SPAWN_ORC_RUN:-$HERE/../../../../../run}" -a do_spl_box_pick 2>&1)"
    fi
    pick="$(sed -n 's/^pick=\([a-z0-9][a-z0-9-]*\)\( .*\)\{0,1\}$/\1/p' <<<"$out" | tail -1)"
    case "$pick" in
      hold)
        echo "spawn-window: HOLD ${TITLE}: $(sed -n 's/^pick=hold reason=//p' <<<"$out" | sed -n 1p). Queue it; nothing was spawned." >&2
        return 10 ;;
      "") echo "spawn-window: WARN no load target pick ($(tail -1 <<<"$out" | cut -c1-200)): placing by the busy count" >&2 ;;
      "$here") echo "spawn-window: ${TITLE} stays on $here (load target: $(sed -n 's/^pick=[^ ]* reason=//p' <<<"$out" | sed -n 1p))" >&2; return 0 ;;
      *) echo "spawn-window: load target: $(sed -n 's/^pick=[^ ]* reason=//p' <<<"$out" | sed -n 1p)" >&2
         printf '%s' "$pick"; return 0 ;;
    esac
  fi
  if [ -n "${SPAWN_PLACE_MAP_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    json="$($SPAWN_PLACE_MAP_CMD 2>/dev/null | grep -m1 '^{')"
  else
    json="$(timeout "${SPAWN_PLACE_TIMEOUT:-60}" bash "$HERE/lane-map.sh" --json 2>/dev/null | grep -m1 '^{')"
  fi
  jq -e '.load | type == "array"' >/dev/null 2>&1 <<<"$json" ||
    { echo "spawn-window: WARN no lane map load (hub or lane map down): starting here" >&2; return 0; }
  floor="${SPAWN_MEM_FLOOR_MB:-4096}"
  [[ "$floor" =~ ^[0-9]+$ ]] || { echo "spawn-window: SPAWN_MEM_FLOOR_MB must be a number of MB, got '$floor'" >&2; return 2; }
  jq -r --arg here "$here" --argjson floor "$((floor * 1024))" '
    [.load[] | select((.live or .box == $here) and (.mem_kb == null or .mem_kb >= $floor))]
    | sort_by([.busy, -(.mem_kb // -1), (if .box == $here then 0 else 1 end)])
    | .[0].box // empty | select(. != $here)' <<<"$json"
}
TARGET="$(place_box)" || exit $?
if [ -n "$TARGET" ]; then
  echo "spawn-window: placing ${TITLE} on ${TARGET} (${SPAWN_BOX:+SPAWN_BOX}${SPAWN_BOX:-fewest busy agents, then most free memory}), not on $(spool_fleet_box)" >&2
  if [ "${SPAWN_DRY_RUN:-0}" = 1 ] && [ -z "${SPAWN_REMOTE_CMD:-}" ]; then
    printf 'PLAN %-10s %s\n' place "$TARGET" remote "spawn-remote.sh --box $TARGET $KIND $TITLE ${*:3}"
    printf '%s@%s -\n' "$TITLE" "$TARGET"
    exit 0
  fi
  if [ -n "${SPAWN_REMOTE_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_REMOTE_CMD --box "$TARGET" "$KIND" "$TITLE" "${@:3}")"; rc=$?
  else
    out="$(bash "$HERE/spawn-remote.sh" --box "$TARGET" "$KIND" "$TITLE" "${@:3}")"; rc=$?
  fi
  line="$(printf '%s\n' "$out" | grep -E '^[A-Za-z][A-Za-z0-9-]*@[a-z0-9-]+ (%[0-9]+|-)$' | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then printf '%s\n' "$line"; exit 0; fi
  [ -z "${SPAWN_BOX:-}" ] || { echo "spawn-window: the spawn on SPAWN_BOX=${TARGET} did not start (spawn-remote exit ${rc})" >&2; exit 8; }
  echo "spawn-window: WARN the spawn on ${TARGET} did not start (spawn-remote exit ${rc}: 3 not sent, 4 refused, 5 no answer within ${SPAWN_REMOTE_WAIT:-300}s, so it may still start there): starting here instead" >&2
fi
if [ -f "${SPOOL_ROOT}/peer/seats" ]; then
  gate_dry=0; [ "${SPAWN_DRY_RUN:-0}" = 1 ] && gate_dry=1
  PEER_GATE_ROLE=spawn PEER_GATE_DRY="$gate_dry" SPOOL_ROOT="$SPOOL_ROOT" \
    bash "${SPAWN_ORC_RUN:-$HERE/../../../../../run}" -a do_spl_peer_gate >&2 ||
    { rc=$?; echo "spawn-window: refused by the peer gate (do_spl_peer_gate exit $rc: 3 fence lost, 4 fence unconfirmed, 5 spawn mutex held, 6 hub unreachable, 1 usage)" >&2; exit 7; }
fi

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
         SPOOL_BOX_TAG SPOOL_ORCHESTRATOR_ID SPOOL_BIN CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN MISTRAL_BIN SPOOL_MISTRAL_MAX_PRICE SPAWN_GIT_IDENTITY \
         SPAWN_REQUESTER SPAWN_LANE_SCOPE SPAWN_LANE_FILES SPAWN_LANE_TOPIC LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX; do
  [ -n "${!v:-}" ] && envs+=("$v=${!v}")
done
printf -v cmd '%q ' env "${envs[@]}" bash "$LAUNCHER" "$TITLE" "$@"

# The pane id is the first line that IS one: an after-new-window hook that
# prints shares new-window -P's output.
out="$("${SPOOL_TM[@]}" new-window -d -t "${sess}:" -n "$(spool_decorate "$TITLE")" -P -F '#{pane_id}' "$cmd")"; rc=$?
pane="$(printf '%s\n' "$out" | grep -m1 -xE '%[0-9]+')"
[ -n "$pane" ] || { echo "spawn-window: new-window (rc=$rc) printed no pane id: ${out:-<nothing>}" >&2; exit 4; }

# --- ORC-2: Write the journal row after the pane is created ---
# Fields: task_id, kind, vendor, id, start_epoch, outcome=run
# Location: $SPOOL_ROOT/<agent-id>/attempts.tsv
ATTEMPTS_DIR="${SPOOL_ROOT}/${TITLE}"
ATTEMPTS_FILE="${ATTEMPTS_DIR}/attempts.tsv"
if [ ! -d "$ATTEMPTS_DIR" ]; then
  mkdir -p "$ATTEMPTS_DIR" || { echo "spawn-window: failed to create attempts dir ${ATTEMPTS_DIR}" >&2; exit 4; }
fi

# Extract task_id from the brief file or use the agent id as fallback
TASK_ID="${TITLE}"
if [ -n "${3:-}" ] && [ -r "${3:-}" ]; then
  TASK_ID="$(grep -m1 '^task_id:' "${3:-}" | cut -d: -f2 | tr -d '[:space:]')"
  [ -z "$TASK_ID" ] && TASK_ID="${TITLE}"
fi

# Write the journal row
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "${TASK_ID}" \
  "${LANE_MIX_KIND:-simple_coding}" \
  "${KIND}" \
  "${TITLE}" \
  "$(date -u +%s)" \
  "run" \
  >> "${ATTEMPTS_FILE}"
# --- End ORC-2 ---

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

if [ "$KIND" = claude ] && [ "${SPAWN_START_CHECK:-1}" != 0 ]; then
  # shellcheck source=../lib/start-check.inc.sh
  . "$HERE/../lib/start-check.inc.sh"
  sw_capture() { "${SPOOL_TM[@]}" capture-pane -p -e -t "$1" 2>/dev/null; }
  sw_gone() { [ "$("${SPOOL_TM[@]}" display-message -p -t "$1" '#{pane_dead}' 2>/dev/null || echo 1)" = 1 ]; }
  why="$(spool_start_check "$pane" "${SPAWN_START_CHECK_WAIT:-45}" sw_capture sw_gone)"; rc=$?
  case "$rc" in
    0) ;;
    3) echo "spawn-window: START FAIL ${TITLE} ${pane}: the session is stopped on a '${why}' dialog; nothing was answered: fix its cause$(spool_start_hint "$why"), then the window" >&2
       exit 11 ;;
    *) echo "spawn-window: WARN ${TITLE} ${pane}: ${why} (start check)" >&2 ;;
  esac
fi