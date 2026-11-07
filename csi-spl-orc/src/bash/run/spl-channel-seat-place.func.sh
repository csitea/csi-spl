#!/bin/bash
#------------------------------------------------------------------------------
# @description Carry out one "channel seat" ask (SPL-5000, owner HUM-10 msgs
# @description de2fdb16, 9089e3fe): a member chose an agent kind in a channel's
# @description add-agents list and no agent of it could be picked, so the hub
# @description (POST /v1/channels/{channel}/agent-kinds) left a role orch ask with
# @description topic channel-seat. In order: ack it; start the kind with the
# @description existing launcher, spawn-window.sh, on this box; seat the new id
# @description on the workspace's desk (do_spl_desk_up) so its roster lists it;
# @description add it to the channel (do_spl_channel_agent_add_op); close the
# @description ask. The seating is done here and not by the new lane: agy and
# @description qwen are never handed a credential path (the data rule).
# @description The launcher's lane issue gate is not changed: the generated
# @description brief carries an Issue line, CHANNEL_SEAT_ISSUE (one standing
# @description issue for every seat, required for DRY_RUN=0), and the launch
# @description runs with SPAWN_ISSUE_CREATE=0, so a seat never files an issue
# @description (R7 W4). The launcher's stderr goes to this log. A REFUSED launch
# @description (exit 12: no issue placed, 13: the kind's CLI is on no box it
# @description may use) declines the ask with the launcher's reason, which the
# @description channel's add-agents list then shows (R7 W2). A HOLD (exit 10)
# @description or another failure leaves the ask acked, and the asks tick
# @description re-raises it when its lock runs out. A seat step that fails after
# @description the launch names the id: re-run with CHANNEL_SEAT_AGENT=<id>,
# @description which launches nothing. Dry run unless DRY_RUN=0.
# @param ASK_ID (required) - the ask id, or its first 8 hex digits
# @param CHANNEL_SEAT_AGENT (optional) - an id already started for this ask: skip the launch
# @param CHANNEL_SEAT_ISSUE (required for DRY_RUN=0 with a launch) - the standing issue every seat lane carries, e.g. SPL-123
# @param CHANNEL_SEAT_EPIC (optional) - the seat lane's epic, default SPL-2163
# @param CHANNEL_SEAT_SPEC (optional) - the seat lane's spec folder, default csi-spl-doc/specs/005-spool-wui
# @param CHANNEL_SEAT_BRIEF_DIR (optional) - where the brief goes, default <spool root>/dispatch/briefs
# @param CHANNEL_SEAT_LAUNCH_CMD (optional, tests) - replaces spawn-window.sh
# @param CHANNEL_SEAT_RUN (optional, tests) - replaces this project's ./run for the desk and the add
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=8a70dfd7 ./run -a do_spl_channel_seat_place
# @example ASK_ID=8a70dfd7 DRY_RUN=0 ./run -a do_spl_channel_seat_place
#------------------------------------------------------------------------------
do_spl_channel_seat_place() {
  local id row dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_asks_init || return 1
  spl_asks_load || return 1
  id="$(spl_asks_resolve "${ASK_ID:-}" "$ASKS_ROWS")" || return 1
  row="$(jq -c --arg id "$id" '.[] | select(.ask_id == $id)' <<<"$ASKS_ROWS")"
  _spl_channel_seat_parse "$row" || return 1
  local kind="$_CS_KIND" tenant="$_CS_TENANT" channel="$_CS_CHANNEL"
  local issue="${CHANNEL_SEAT_ISSUE:-}"
  if [[ -z "${CHANNEL_SEAT_AGENT:-}" && ! "$issue" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    (( dry )) || { do_log "FATAL CHANNEL_SEAT_ISSUE=<KEY> is required: the standing issue every seat lane carries, so a seat files none (got '$issue')"; return 1; }
    issue='<CHANNEL_SEAT_ISSUE>'
  fi
  if (( dry )); then
    do_log "OK DRY_RUN would start a $kind agent on $ASKS_BOX under issue $issue, seat it in $tenant and add it to #$channel on $LANE_ENV (ask ${id:0:8}). Re-run with DRY_RUN=0."
    return 0
  fi
  ASK_ID="$id" do_spl_ask_ack || return 1
  local agent="${CHANNEL_SEAT_AGENT:-}" brief rc=0
  if [[ -z "$agent" ]]; then
    brief="$(_spl_channel_seat_brief "$id" "$kind" "$tenant" "$channel" "$issue")" || return 1
    _CS_REFUSED_FILE="$(mktemp)" || return 1
    agent="$(_spl_channel_seat_launch "$kind" "$brief" "$channel")" || rc=$?
    _CS_REFUSED="$(cat "$_CS_REFUSED_FILE")"; rm -f "$_CS_REFUSED_FILE"
    if (( rc == 12 || rc == 13 )); then
      ASK_ID="$id" ASK_STATE=declined ASK_REASON="${_CS_REFUSED:-the launcher refused a $kind agent (exit $rc)}" do_spl_ask_close || return 1
      do_log "WARN ask ${id:0:8}: the launcher refused a $kind agent (exit $rc); the ask is declined with its reason, which #$channel's add-agents list shows"
      return "$rc"
    elif (( rc != 0 )); then
      do_log "WARN ask ${id:0:8}: the launcher did not start a $kind agent (exit $rc); the ask stays acked and is re-raised when its lock runs out"
      return "$rc"
    fi
  fi
  _spl_channel_seat_add "$agent" "$tenant" "$channel" || {
    do_log "FATAL ask ${id:0:8}: $agent runs but is not in #$channel; fix it, then re-run with CHANNEL_SEAT_AGENT=$agent"
    return 1
  }
  ASK_ID="$id" ASK_REASON="$agent@$ASKS_BOX added to #$channel in $tenant" do_spl_ask_close || return 1
  do_log "OK $agent ($kind) is in #$channel in $tenant on $ASKS_BOX (ask ${id:0:8})"
}

# _spl_channel_seat_parse <ask row> -> _CS_KIND, _CS_TENANT, _CS_CHANNEL from
# the summary the hub wrote; any other ask, or a closed one, is refused.
_spl_channel_seat_parse() {
  local topic state summary rx='^channel seat: kind=([a-z]+) tenant=([a-z0-9-]+) channel=([a-z0-9-]+) by='
  topic="$(jq -r '.topic // ""' <<<"$1")"
  state="$(jq -r '.state // ""' <<<"$1")"
  summary="$(jq -r '.summary // ""' <<<"$1")"
  [[ "$topic" == channel-seat && "$summary" =~ $rx ]] || { do_log "FATAL this ask is not a channel seat (topic '$topic')"; return 1; }
  _CS_KIND="${BASH_REMATCH[1]}" _CS_TENANT="${BASH_REMATCH[2]}" _CS_CHANNEL="${BASH_REMATCH[3]}"
  [[ "$state" =~ ^(open|acked)$ ]] || { do_log "FATAL this ask is already $state"; return 1; }
}

# _spl_channel_seat_brief <ask id> <kind> <tenant> <channel> <issue> -> the brief's path.
_spl_channel_seat_brief() {
  local dir="${CHANNEL_SEAT_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" f
  mkdir -p "$dir" || return 1
  f="$dir/channel-seat-${1:0:8}.md"
  cat >"$f" <<BRIEF || return 1
# Channel seat: a $2 agent for #$4 in workspace $3

Issue: $5
Epic: ${CHANNEL_SEAT_EPIC:-SPL-2163}
Spec: ${CHANNEL_SEAT_SPEC:-csi-spl-doc/specs/005-spool-wui}
Class: feature
Kind: specs_and_docs

A member of workspace $3 added a $2 agent to channel #$4 (ask ${1:0:8}). The orchestrator seats you there; you do not seat yourself.
Your work is what that channel's people ask of you. There is no code task in this brief: stay idle until a post reaches you, and open no worktree change without an ask.
BRIEF
  printf '%s' "$f"
}

# _spl_channel_seat_launch <kind> <brief> <channel> -> the new id on stdout. On
# this box: the desk and the add below run here. Exit 10 is the launcher's HOLD.
# Its stderr goes to this log, line by line; the first REFUSED line, without
# the launcher's prefix, is left in _CS_REFUSED for the decline. The caller
# runs it in $(...), so _CS_REFUSED is read back from a file.
_spl_channel_seat_launch() {
  local out rc=0 agent err line slug="channel-seat-$1-${3:0:32}"
  err="$(mktemp)" || return 1
  if [[ -n "${CHANNEL_SEAT_LAUNCH_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(SPAWN_BOX="$ASKS_BOX" SPAWN_ISSUE_CREATE=0 $CHANNEL_SEAT_LAUNCH_CMD "$1" auto "${APP_PATH:-}" "$2" "$slug" 2>"$err")" || rc=$?
  else
    out="$(SPAWN_BOX="$ASKS_BOX" SPAWN_ISSUE_CREATE=0 bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh" "$1" auto "$APP_PATH" "$2" "$slug" 2>"$err" 6>&-)" || rc=$?
  fi
  while IFS= read -r line; do do_log "INFO launcher: ${line:0:500}" >&2; done <"$err"
  sed -n 's/^.*REFUSED //p' "$err" | sed -n 1p | cut -c1-400 >"$_CS_REFUSED_FILE"
  rm -f "$err"
  (( rc == 0 )) || return "$rc"
  # shellcheck disable=SC2153 # SPOOL_AGENT_ID_NEW_RX comes from spool-env.inc.sh
  [[ "${out%% *}" =~ ^(${SPOOL_AGENT_ID_NEW_RX})(@|$) ]] && agent="${BASH_REMATCH[1]}"
  [[ -n "$agent" ]] || { do_log "FATAL the launcher named no agent id: ${out:0:200}" >&2; return 1; }
  printf '%s' "$agent"
}

# _spl_channel_seat_add <agent> <tenant> <channel>: the desk seat, which puts the
# id on the workspace's roster, then the channel row, each its own ./run.
_spl_channel_seat_add() {
  local run="${CHANNEL_SEAT_RUN:-$PROJ_PATH/run}"
  ENV="$LANE_ENV" TENANT_ID="$2" DESK_BOX="$ASKS_BOX" DESK_AGENT="$1" DRY_RUN=0 bash "$run" -a do_spl_desk_up || return 1
  ENV="$LANE_ENV" TENANT_ID="$2" CHANNEL="$3" AGENTS="$1" AGENT_BOX="$ASKS_BOX" DRY_RUN=0 bash "$run" -a do_spl_channel_agent_add_op
}
