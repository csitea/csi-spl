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
# window stays for a human and nothing is typed into it. No box in time, the
# pane still alive: one WARN, exit 0, the window kept for a human. The pane
# ended or tmux went away (SPL-2627): exit 4 like a pane gone before its
# seed, no "<ID> <PANE>" line (it is printed after the check), the window
# killed and the claim released. SPAWN_START_CHECK=0 skips it (the
# rotation and the agent restart run their own after the pid is known).
#
# Exit: 0 ok, 2 usage, 3 id taken, 4 tmux printed no pane id, the new pane
# is gone before its seed, or it ended during the start check (all three
# release the claim), 5 no session,
# 6 this machine is draining (do_spl_box_leave; do_spl_box_join ends it),
# 7 refused by the peer gate (spec 068 L5: a seat spawns only under the
# `spawn` mutex with its fence held; do_spl_peer_gate says why), 8 the
# remote spawn on an explicit SPAWN_BOX did not start (PLACEMENT below),
# 9 the requester is a lane, 10 HOLD: every fleet box is at or above the
# load target's high mark (LOAD TARGET below), so queue the lane, 11 the
# new session is stopped on a dialog (START CHECK above), 12 the lane has
# no issue (LANE ISSUE below), 13 the box has no <kind> CLI (VENDOR CLI
# below). Only c-001, c-002 and c-003 (any box), or a
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
# WARN on stderr, after withdrawing that request (spawn-remote.sh --cancel)
# so the target's serve does not start it later. pick=hold (exit 10) files
# no request; a request already filed is withdrawn the same way.
# SPAWN_BOX=<box> always wins (local, or this box's id, =
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
#
# VENDOR CLI (SPL-1649): a lane goes only to a box that can start its kind.
# Measured, never listed by hand: this box runs spool_vendor_clis (the agent
# user's `command -v` of each *_BIN, as spool-harness.sh execs it); another
# box publishes the same in the cli= of its BOX-0 load row, read from the lane
# map's .load[].clis. Before it, an agy lane placed on a box without agy ended
# in `agent command 'agy' not found`, three watchdog restarts, three registry
# rows. The load target pick (BOX_PICK_KIND) and the busy count both skip a
# box measured without the kind; `pick=nokind` = exit 13. A pick of this box
# that lacks it (an older pick action) is overruled (WARN) by the filtered
# busy count; no box left and this one lacks it too = exit 13, nothing
# spawned. An explicit SPAWN_BOX (this box or another) measured without it =
# exit 13 at once, and so does the fallback to this box after a failed remote
# spawn. A box nobody measured (an older box: no cli= in its row) stays a
# candidate. Seam: SPOOL_VENDOR_CLIS_CMD prints this box's kinds
# ("claude,qwen").
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
# The tries journal (spec 115 section 6): ONE row per spawn, appended under a
# flock to $SPOOL_ROOT/dispatch/attempts.tsv on exit, read by
# do_spl_lane_mix_journal. `task_id kind vendor id start_epoch outcome source`:
# outcome `run` on a started lane, `fail:F1` on any other non-zero exit; exit
# 10 (HOLD) and a dry run write nothing. task_id is LANE_MIX_TASK, else
# SPAWN_LANE_TOPIC, else "-"; kind is LANE_MIX_KIND. A journal that cannot be
# written is one WARN, never a changed exit code.
SW_START="$(date -u +%s)"; SW_JOURNAL_ID=""
sw_journal() {
  local rc="$1" outcome f id
  case "$rc" in 0) outcome=run ;; 10) return 0 ;; *) outcome=fail:F1 ;; esac
  [ "${SPAWN_DRY_RUN:-0}" != 1 ] || return 0
  id="${SW_JOURNAL_ID:-$TITLE}"; [ "$id" != auto ] || id="auto-$$"
  f="${SPOOL_ROOT}/dispatch/attempts.tsv"
  { mkdir -p "${f%/*}" && (
      flock -w 10 9 || exit 1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${LANE_MIX_TASK:-${SPAWN_LANE_TOPIC:--}}" \
        "${LANE_MIX_KIND:--}" "$KIND" "$id" "$SW_START" "$outcome" spawn-window >&9
    ) 9>>"$f"; } 2>/dev/null || echo "spawn-window: WARN no journal row in $f" >&2
}
trap 'sw_journal $?' EXIT
# Before a claim, a window, or a remote placement: a lane must not start one.
SPAWN_REQUESTER="$(spool_spawn_gate)" || exit $?
export SPAWN_REQUESTER
[ ! -e "${SPOOL_ROOT}/dispatch/box.leave" ] || { echo "spawn-window: this machine is draining ($(head -c 200 "${SPOOL_ROOT}/dispatch/box.leave")): spawn on another box, or run ./run -a do_spl_box_join here" >&2; exit 6; }
# shellcheck source=../lib/spool-fleet.inc.sh
. "$HERE/../lib/spool-fleet.inc.sh"
# Withdraw a remote request this process filed and will not use. OUT is
# spawn-remote's stdout (`task <id>` once the request is filed and no agent
# line came back). A SPAWN_REMOTE_CMD stub filed nothing here. HOLD calls
# this before rc 10; the local fallback calls it before starting here.
sw_withdraw_remote() {  # BOX OUT
  local task
  [ -z "${SPAWN_REMOTE_CMD:-}" ] || return 0
  [ -n "${1:-}" ] || return 0
  task="$(printf '%s\n' "${2:-}" | sed -n 's/^task //p' | tail -1)"
  [ -n "$task" ] || return 0
  if bash "$HERE/spawn-remote.sh" --cancel --box "$1" --task "$task" >/dev/null 2>&1; then
    echo "spawn-window: withdrew remote request $task on $1" >&2
    return 0
  fi
  echo "spawn-window: WARN could not withdraw remote request $task on $1: it may still spawn there" >&2
  return 1
}
# The lane map JSON, read at most once per process (SW_MAP).
sw_load_map() {
  [ -z "${SW_MAP_READ:-}" ] || return 0
  SW_MAP_READ=1
  if [ -n "${SPAWN_PLACE_MAP_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    SW_MAP="$($SPAWN_PLACE_MAP_CMD 2>/dev/null | grep -m1 '^{')"
  else
    SW_MAP="$(timeout "${SPAWN_PLACE_TIMEOUT:-60}" bash "$HERE/lane-map.sh" --json 2>/dev/null | grep -m1 '^{')"
  fi
}
# 0 when BOX is measured without the $KIND CLI (VENDOR CLI above); a box
# nobody measured is 1 (a candidate). Sets SW_CLIS to what was measured.
sw_lacks_kind() {  # BOX
  SW_CLIS=""
  if [ "$1" = "$(spool_fleet_box)" ]; then
    SW_CLIS="$(spool_vendor_clis 2>/dev/null)" || return 1
  else
    sw_load_map
    SW_CLIS="$(jq -r --arg b "$1" '.load[]? | select(.box == $b) | .clis
      | if . == null then "?" else join(",") end' <<<"${SW_MAP:-}" 2>/dev/null | head -1)"
    case "$SW_CLIS" in ""|"?") return 1 ;; esac
  fi
  [[ ",$SW_CLIS," != *",$KIND,"* ]]
}
sw_refuse_kind() {  # BOX WHY
  echo "spawn-window: REFUSED ${TITLE} (${KIND}) on $1: $2 (measured there: ${SW_CLIS:-none}); nothing was spawned" >&2
  return 13
}
# The busy count (PLACEMENT above) over the boxes that can start $KIND.
sw_place_by_busy() {  # HERE
  local here="$1" floor best
  sw_load_map
  jq -e '.load | type == "array"' >/dev/null 2>&1 <<<"${SW_MAP:-}" || {
    ! sw_lacks_kind "$here" || { sw_refuse_kind "$here" "no lane map load and this box has no ${KIND} CLI"; return; }
    echo "spawn-window: WARN no lane map load (hub or lane map down): starting here" >&2; return 0; }
  floor="${SPAWN_MEM_FLOOR_MB:-4096}"
  [[ "$floor" =~ ^[0-9]+$ ]] || { echo "spawn-window: SPAWN_MEM_FLOOR_MB must be a number of MB, got '$floor'" >&2; return 2; }
  best="$(jq -r --arg here "$here" --argjson floor "$((floor * 1024))" --arg kind "$KIND" '
    [.load[] | select((.live or .box == $here) and (.mem_kb == null or .mem_kb >= $floor)
                      and (.clis == null or (.clis | index($kind)) != null))]
    | sort_by([.busy, -(.mem_kb // -1), (if .box == $here then 0 else 1 end)])
    | .[0].box // "-"' <<<"$SW_MAP")"
  case "$best" in
    "$here") return 0 ;;
    -) ! sw_lacks_kind "$here" || { sw_refuse_kind "$here" "no fleet box with room has a ${KIND} CLI and this one has none"; return; }
       return 0 ;;
  esac
  printf '%s' "$best"
}
# The box this lane starts on; "" = here.
place_box() {
  local want="${SPAWN_BOX:-}" here holder="" fleet
  here="$(spool_fleet_box)"
  case "$want" in local|"$here")
    ! sw_lacks_kind "$here" || { sw_refuse_kind "$here" "SPAWN_BOX names a box with no ${KIND} CLI for the agent user"; return; }
    return 0 ;;
  esac
  if [ -n "$want" ]; then
    [[ "$want" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "spawn-window: SPAWN_BOX must be local or ONE box id, got '$want'" >&2; return 2; }
    ! sw_lacks_kind "$want" || { sw_refuse_kind "$want" "SPAWN_BOX names a box with no ${KIND} CLI for the agent user"; return; }
    printf '%s' "$want"; return 0
  fi
  [ "$TITLE" = auto ] || return 0
  fleet="${LANE_FLEET:-$(_spool_fleet_conf LEASE_FLEET)}"
  [ -n "$fleet" ] || return 0
  [ -r "$SPOOL_ROOT/dispatch/lease.orch" ] && read -r holder _ <"$SPOOL_ROOT/dispatch/lease.orch"
  case "$holder" in ""|*@"$here") ;; *) return 0 ;; esac
  if [ "${SPAWN_BOX_PICK:-1}" != 0 ]; then
    local out pick k pick_hop=()
    export BOX_PICK_KIND="$KIND"
    # The desk state (the seated desk, its hub key) lives under the BOX user's
    # HOME: an agent-user spawner hops there, the way lane-map.sh does.
    if [ "$(id -un)" != "$SPOOL_BOX_USER" ]; then
      # shellcheck disable=SC2206 # a command prefix, split on purpose
      pick_hop=(${SPAWN_PICK_HOP_CMD:-sudo -n -u} "$SPOOL_BOX_USER" env HOME="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)" "SPOOL_ROOT=$SPOOL_ROOT")
      for k in ENV BOX_PICK_SINCE BOX_PICK_OVERFLOW BOX_PICK_CNF BOX_PICK_KIND LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_BOX SPOOL_DESK_BOX SPOOL_BOX_ENV; do
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
    # The pick leaves out the boxes measured without the kind; this box is
    # re-checked here (cheap, and an older pick action does not know the kind).
    if [ "$pick" = "$here" ] && sw_lacks_kind "$here"; then
      echo "spawn-window: WARN load target picked $pick, which has no ${KIND} CLI (measured: ${SW_CLIS:-none}): placing by the busy count among the boxes that have it" >&2
      pick=""; out=""
    fi
    case "$pick" in
      nokind)
        sw_withdraw_remote "${SW_REMOTE_BOX:-}" "${SW_REMOTE_OUT:-}"
        echo "spawn-window: REFUSED ${TITLE} (${KIND}): $(sed -n 's/^pick=nokind reason=//p' <<<"$out" | sed -n 1p); nothing was spawned" >&2
        return 13 ;;
      hold)
        sw_withdraw_remote "${SW_REMOTE_BOX:-}" "${SW_REMOTE_OUT:-}"
        echo "spawn-window: HOLD ${TITLE}: $(sed -n 's/^pick=hold reason=//p' <<<"$out" | sed -n 1p). Queue it; nothing was spawned." >&2
        return 10 ;;
      "") [ -z "$out" ] || echo "spawn-window: WARN no load target pick ($(tail -1 <<<"$out" | cut -c1-200)): placing by the busy count" >&2 ;;
      "$here") echo "spawn-window: ${TITLE} stays on $here (load target: $(sed -n 's/^pick=[^ ]* reason=//p' <<<"$out" | sed -n 1p))" >&2; return 0 ;;
      *) echo "spawn-window: load target: $(sed -n 's/^pick=[^ ]* reason=//p' <<<"$out" | sed -n 1p)" >&2
         printf '%s' "$pick"; return 0 ;;
    esac
  fi
  sw_place_by_busy "$here"
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
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then printf '%s\n' "$line"; SW_JOURNAL_ID="${line%% *}"; exit 0; fi
  [ -z "${SPAWN_BOX:-}" ] || { echo "spawn-window: the spawn on SPAWN_BOX=${TARGET} did not start (spawn-remote exit ${rc})" >&2; exit 8; }
  SW_REMOTE_BOX="$TARGET" SW_REMOTE_OUT="$out"
  sw_withdraw_remote "$TARGET" "$out"
  ! sw_lacks_kind "$(spool_fleet_box)" || { sw_refuse_kind "$(spool_fleet_box)" "the spawn on ${TARGET} did not start (spawn-remote exit ${rc}) and this box has no ${KIND} CLI"; exit 13; }
  echo "spawn-window: WARN the spawn on ${TARGET} did not start (spawn-remote exit ${rc}: 3 not sent, 4 refused, 5 no answer within ${SPAWN_REMOTE_WAIT:-300}s): starting here instead" >&2
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
  # A role seat respawned by its rotation keeps its id under another vendor
  # (ROTATE_ROLE_VENDOR, SPL-1605); every other kind/id mismatch is refused.
  [ "$(spl_kind_of_agent_id "$TITLE")" = "$KIND" ] ||
    { [ "${SPAWN_REUSE_ID:-0}" = 1 ] && spool_spawn_is_seat "$TITLE"; } ||
    { echo "spawn-window: ${TITLE} is not a ${KIND} id" >&2; exit 2; }
  if [ "${SPAWN_REUSE_ID:-0}" != 1 ]; then
    if [ "$DRY" = 1 ]; then
      [ ! -e "${SPOOL_ROOT}/${TITLE}" ] || { echo "spawn-window: ${TITLE} is taken (${SPOOL_ROOT}/${TITLE})" >&2; exit 3; }
    else
      bash "$HERE/next-agent-id.sh" --claim "$TITLE" >/dev/null || exit $?
    fi
  fi
fi
shift 2

# LANE ISSUE (owner HUM-10, t1 5ea2e615 msg 346238a8; the rule:
# csi-spl-doc/doc/md/lane-issue-and-docs.md): a git lane with a brief starts
# only with an issue. do_spl_lane_issue links the key in SPAWN_ISSUE or the
# brief's `Issue: <KEY>` line (status wip, assignee the lane), or files one
# from the brief, and writes <spool root>/<id>/lifetime/issue, which
# spawn-core puts in the seed. It runs on the box that launches (the remote
# serve's spawn-window included), after the claim and before the window, so a
# refusal reaches the spawner: exit 12, the fresh claim released. A respawn
# (SPAWN_REUSE_ID=1) keeps the key it has. SPAWN_ISSUE_CREATE=0 refuses a
# brief with no key instead of filing one. Seam: SPAWN_ISSUE_CMD replaces the
# action (tests).
sw_issue() {  # WORKDIR BRIEF
  local wd="$1" brief="${2:-}" key hop=() out rc=0
  [ -n "$brief" ] && [ "${SPAWN_REUSE_ID:-0}" != 1 ] || return 0
  git -C "$wd" remote get-url origin >/dev/null 2>&1 || return 0
  # shellcheck source=../lib/lane-issue.inc.sh
  . "$HERE/../lib/lane-issue.inc.sh"
  key="${SPAWN_ISSUE:-$(li_key_from_brief "$brief")}"
  if [ -z "$key" ] && [ "${SPAWN_ISSUE_CREATE:-1}" = 0 ]; then
    echo "spawn-window: REFUSED ${TITLE}: a lane without an issue key does not start. Put 'Issue: <KEY>' in the brief, pass SPAWN_ISSUE=<KEY>, or file one: cd csi-spl-orc && AGENT_ID=${TITLE} BRIEF=${brief} DRY_RUN=0 ./run -a do_spl_lane_issue" >&2
    return 12
  fi
  if [ "$DRY" = 1 ]; then
    printf 'PLAN %-10s %s\n' issue "${key:+link ${key} -> wip, assignee ${TITLE}}${key:-file one from ${brief} (wip, assignee ${TITLE})} -> ${SPOOL_ROOT}/${TITLE}/lifetime/issue"
    return 0
  fi
  if [ "$(id -un)" != "$SPOOL_BOX_USER" ] && [ -z "${SPAWN_ISSUE_CMD:-}" ]; then
    hop=(sudo -n -u "$SPOOL_BOX_USER" env HOME="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)")
  fi
  if [ -n "${SPAWN_ISSUE_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(AGENT_ID="$TITLE" BRIEF="$brief" LANE_ISSUE_KEY="$key" LANE_ISSUE_TOPIC="${SPAWN_LANE_TOPIC:-}" $SPAWN_ISSUE_CMD 2>&1)" || rc=$?
  else
    out="$(timeout "${SPAWN_ISSUE_TIMEOUT:-120}" "${hop[@]}" env SPOOL_ROOT="$SPOOL_ROOT" AGENT_ID="$TITLE" BRIEF="$brief" \
      LANE_ISSUE_KEY="$key" LANE_ISSUE_TOPIC="${SPAWN_LANE_TOPIC:-}" DRY_RUN=0 \
      bash "${SPAWN_ORC_RUN:-$HERE/../../../../../run}" -a do_spl_lane_issue 2>&1)" || rc=$?
  fi
  key="$(li_key_of_agent "$SPOOL_ROOT" "$TITLE")"
  if [ "$rc" -ne 0 ] || [ -z "$key" ]; then
    echo "spawn-window: REFUSED ${TITLE}: no issue placed (exit ${rc}): $(printf '%s' "$out" | grep -E 'FATAL|WARN' | grep -v 'failed at line' | tail -2 | tr '\n' ' ' | cut -c1-400). A lane without an issue key does not start; fix it, or put an existing 'Issue: <KEY>' in the brief and spawn again" >&2
    return 12
  fi
  echo "spawn-window: ${TITLE} carries issue ${key} (wip)" >&2
}
# A refused issue releases the id this call just claimed (empty spool dirs,
# and the notice strip's .pokes of a window that died in the start check).
sw_release_claim() {
  [ "$DRY" = 1 ] || [ "${SPAWN_REUSE_ID:-0}" = 1 ] && return 0
  rm -f "${SPOOL_ROOT}/${TITLE}/lifetime/issue" 2>/dev/null
  rm -rf "${SPOOL_ROOT:?}/${TITLE:?}/.pokes" 2>/dev/null
  rmdir "${SPOOL_ROOT}/${TITLE}/inbox" "${SPOOL_ROOT}/${TITLE}/outbox" "${SPOOL_ROOT}/${TITLE}/archive" \
    "${SPOOL_ROOT}/${TITLE}/lifetime" "${SPOOL_ROOT}/${TITLE}" 2>/dev/null || true
}
sw_issue "$@" || { rc=$?; sw_release_claim; exit "$rc"; }

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
# tmux server does not inherit this process's environment. SPAWN_REUSE_ID
# too: the launcher re-checks the kind/id pair and keeps a respawn's brief
# (a role seat under ROTATE_ROLE_VENDOR failed live without it, SPL-1605).
envs=()
for v in SPOOL_ROOT SPOOL_BOX_USER SPOOL_AGENT_USER SPOOL_RUN_AS_AGENT SPOOL_TMUX_SOCKET \
         SPOOL_BOX_TAG SPOOL_ORCHESTRATOR_ID SPOOL_BIN CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN MISTRAL_BIN SPOOL_MISTRAL_MAX_PRICE SPAWN_GIT_IDENTITY \
         SPAWN_REUSE_ID SPAWN_REQUESTER SPAWN_LANE_SCOPE SPAWN_LANE_FILES SPAWN_LANE_TOPIC SPAWN_PROMPT_HEAD_FILE LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX; do
  [ -n "${!v:-}" ] && envs+=("$v=${!v}")
done
printf -v cmd '%q ' env "${envs[@]}" bash "$LAUNCHER" "$TITLE" "$@"

# The pane id is the first line that IS one: an after-new-window hook that
# prints shares new-window -P's output.
out="$("${SPOOL_TM[@]}" new-window -d -t "${sess}:" -n "$(spool_decorate "$TITLE")" -P -F '#{pane_id}' "$cmd")"; rc=$?
pane="$(printf '%s\n' "$out" | grep -m1 -xE '%[0-9]+')"
# A failed new-window made no window (the server died, SPL-2353): its claim
# goes, as for a refused issue. A window that printed no pane keeps its id.
if [ -z "$pane" ]; then
  [ "$rc" -eq 0 ] || { sw_release_claim; out="${out:-<nothing>}; the claim on ${TITLE} is released"; }
  echo "spawn-window: new-window (rc=$rc) printed no pane id: ${out:-<nothing>}" >&2; exit 4
fi
# A pane gone right after new-window (the server died, SPL-2408) never ran its
# launcher to the seed: a failed spawn, its claim released like the above.
# tmux's exit code says it (no server, no such pane), not its output.
if ! "${SPOOL_TM[@]}" display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
  sw_release_claim
  echo "spawn-window: the pane ${pane} of ${TITLE} is gone before its seed (tmux server died?); the claim on ${TITLE} is released" >&2; exit 4
fi

# The notice strip is split NOW, before the CLI has painted anything, so the
# TUI starts at the size it will keep and never takes a mid-session resize.
#
# This is the fix for the distortion reported by the owner (2026-09-22): a
# HEIGHT split (-v) of a pane that has already painted its UI destroys the
# top rows and moves everything under them, corrupting the screen. A WIDTH
# split (-h) leaves every row where it is, so the CLI's row anchor survives.
# Measured by spool-strip-resize-proof.sh on tmux 3.5a.
#
# Splitting BEFORE the CLI paints costs nothing: the pane has drawn nothing yet,
# and there is no later resize to survive. A CLI already running when its strip
# arrives takes exactly one width change, once, and it is still not free: a WIDTH
# split clips every transcript line at the new width, permanently, because no
# process holds a copy to repaint.
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

# "<ID> <PANE>" goes out only once the start check has not failed the spawn:
# the od pool, the claude handover and the peer restart grep it without
# reading the exit code, so a pane that ended must never print it (SPL-2627).
rc=0
if [ "$KIND" = claude ] && [ "${SPAWN_START_CHECK:-1}" != 0 ]; then
  # shellcheck source=../lib/start-check.inc.sh
  . "$HERE/../lib/start-check.inc.sh"
  sw_capture() { "${SPOOL_TM[@]}" capture-pane -p -e -t "$1" 2>/dev/null; }
  sw_gone() { [ "$("${SPOOL_TM[@]}" display-message -p -t "$1" '#{pane_dead}' 2>/dev/null || echo 1)" = 1 ]; }
  why="$(spool_start_check "$pane" "${SPAWN_START_CHECK_WAIT:-45}" sw_capture sw_gone)"; rc=$?
  # The pane ended or tmux went away: no session will ever ack, a failed
  # spawn like the pane gone before its seed. Its dead window goes with the
  # claim; a server that is gone took it already.
  if [ "$rc" -eq 5 ]; then
    "${SPOOL_TM[@]}" kill-window -t "$pane" 2>/dev/null || true
    sw_release_claim
    echo "spawn-window: ${TITLE} ${pane}: ${why} (start check); the claim on ${TITLE} is released" >&2
    exit 4
  fi
fi

printf '%s %s\n' "$TITLE" "$pane"

case "$rc" in
  0) ;;
  3) echo "spawn-window: START FAIL ${TITLE} ${pane}: the session is stopped on a '${why}' dialog; nothing was answered: fix its cause$(spool_start_hint "$why"), then the window" >&2
     exit 11 ;;
  *) echo "spawn-window: WARN ${TITLE} ${pane}: ${why} (start check)" >&2 ;;
esac