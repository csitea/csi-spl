#!/bin/bash
# @description The spawn queue's placer, one tick (owner HUM-10, t1 c9beaa77
# @description msg ca668844: "once resources are free they will be just
# @description taken"; rdb 0180). It replaces the orchestrator's hand-kept
# @description queue file and runner loop. Every machine may run it; only the
# @description machine whose agent holds the orch role acts (the same rule as
# @description the asks tick). Each tick, in order:
# @description   1. STALLED - a request the placer took (acked, "placing") and
# @description      not closed within SPAWN_PLACE_LOCK_MIN goes back in line at
# @description      its old place (enqueued_at is set once), before the asks
# @description      tick's own lock timeout could ever re-raise it
# @description   2. ONE AT A TIME - a request still placing: nothing else
# @description   3. ROOM - position 1 is taken only when the agent windows on
# @description      this box are below SPOOL_AGENT_CEILING (40), the fleet load
# @description      target does not say hold (do_spl_box_pick) and the last
# @description      placement started SPAWN_PLACE_GAP_MIN ago. No room: it stays
# @description      queued, one INFO line says why
# @description   4. TAKE - the head is acked by the orch holder (placing), then
# @description      a. with a placement <vendor>:<slug> and its brief file: the
# @description         existing launcher, `spawn-window.sh <vendor> auto
# @description         <SPAWN_PLACE_WORKDIR> <brief> <slug>`; the new id -> done
# @description         "placed: <ID>@<box>" and the sender is told; spawn-window's
# @description         HOLD (exit 10) or a failure -> back in line (a failure
# @description         also tells the holder)
# @description      b. otherwise (no placement, or no brief file here: the brief
# @description         needs judgement) the holder gets ONE blocker "place ask X
# @description         now" with the summary and the close command
# @description         (do_spl_spawn_placed); 1 brings it back if it is not placed
# @description Installed by do_spl_spawn_place_install_cron (every minute).
# @param SPAWN_PLACE_LOCK_MIN (optional) - minutes a placing request may stay unclosed before it goes back in line, default 30
# @param SPAWN_PLACE_GAP_MIN (optional) - minutes between two placements, default 10
# @param SPOOL_AGENT_CEILING (optional) - the agent window ceiling, default 40
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where <slug>.md (or c001-<slug>.md) is, default <spool root>/dispatch/briefs
# @param SPAWN_PLACE_WORKDIR (optional) - the launcher's WORKDIR, default the checkout this action runs from
# @param SPAWN_PLACE_TMUX_SOCKET (optional) - the box user's tmux socket, default /tmp/tmux-<uid>/default
# @param SPAWN_PLACE_WINDOWS_CMD SPAWN_PLACE_PICK_CMD SPAWN_PLACE_LAUNCH_CMD (optional, tests) - print the window count / the box pick / run the launch
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ASKS_HOLDER (optional) - as do_spl_asks_tick
# @example ./run -a do_spl_spawn_place
# @example SPAWN_PLACE_GAP_MIN=0 ./run -a do_spl_spawn_place

do_spl_spawn_place() {
  spl_asks_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "INFO no fleet hub here: no spawn queue to place"; return 0; }
  local holder rows head why
  holder="$(spl_asks_holder)"
  [[ -n "$holder" ]] || { do_log "INFO nobody holds the orch role right now: nothing placed"; return 0; }
  [[ "${holder##*@}" == "$ASKS_BOX" ]] || { do_log "INFO the orch role is held on ${holder##*@} ($holder): its machine places"; return 0; }
  exec 6>>"$(spool_asks_dir)/.place.lock"
  flock -n 6 || { do_log "INFO another placer tick is running: skipped"; return 0; }
  rows="$(spl_spawn_q_rows)" || { do_log "WARN the hub did not answer: nothing placed this tick"; return 0; }
  if spl_spawn_place_stalled "$holder" "$rows"; then
    rows="$(spl_spawn_q_rows)" || return 0
  fi
  if jq -e 'any(.[]; .state == "acked")' >/dev/null <<<"$rows"; then
    do_log "INFO placing $(jq -r '[.[] | select(.state == "acked") | .ask_id[0:8]] | join(" ")' <<<"$rows"): one at a time, $(jq '[.[] | select(.state == "queued")] | length' <<<"$rows") queued"
    return 0
  fi
  head="$(jq -c '[.[] | select(.state == "queued" and .position == 1)][0] // empty' <<<"$rows")"
  [[ -n "$head" ]] || { do_log "INFO the spawn queue is empty"; return 0; }
  if why="$(spl_spawn_place_no_room)"; then
    do_log "INFO hold: $why; ask $(jq -r '.ask_id[0:8]' <<<"$head") stays position 1 of $(jq -r '.queue_len' <<<"$head")"
    return 0
  fi
  spl_spawn_place_take "$holder" "$head"
}

# 1. Placing requests quiet SPAWN_PLACE_LOCK_MIN go back in line. 0 = one did.
spl_spawn_place_stalled() {  # HOLDER ROWS
  local id n=0 lock=$(( ${SPAWN_PLACE_LOCK_MIN:-30} * 60 ))
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    spl_spawn_q_op queue "$id" "$1" >/dev/null || continue
    do_log "INFO ask ${id:0:8} was not placed within ${SPAWN_PLACE_LOCK_MIN:-30} min: back in line at its place"
    n=$((n + 1))
  done < <(jq -r --argjson l "$lock" '.[] | select(.state == "acked" and .quiet_s >= $l) | .ask_id' <<<"$2")
  (( n > 0 ))
}

# 3. Prints why there is no room and returns 0; returns 1 when there is room.
spl_spawn_place_no_room() {
  local n ceil="${SPOOL_AGENT_CEILING:-40}" pick last gap=$(( ${SPAWN_PLACE_GAP_MIN:-10} * 60 ))
  n="$(spl_spawn_place_windows)"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf 'the agent windows could not be counted'; return 0; }
  (( n < ceil )) || { printf 'agent windows %s >= the ceiling %s' "$n" "$ceil"; return 0; }
  last="$(stat -c %Y "$(spool_asks_dir)/.place.last" 2>/dev/null || echo 0)"
  (( $(date +%s) - last >= gap )) || { printf 'the last placement started under %s min ago' "${SPAWN_PLACE_GAP_MIN:-10}"; return 0; }
  pick="$(spl_spawn_place_pick)"
  [[ "$pick" == hold* ]] && { printf 'the fleet load target says %s' "$pick"; return 0; }
  SPAWN_PLACE_ROOM="windows $n/$ceil, load pick ${pick:-unknown}"
  return 1
}

# The agent windows on this box (the fleet's ceiling count).
spl_spawn_place_windows() {
  if [[ -n "${SPAWN_PLACE_WINDOWS_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_PLACE_WINDOWS_CMD; return
  fi
  local sock="${SPAWN_PLACE_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" names
  names="$(tmux -S "$sock" list-windows -a -F '#{window_name}' 2>/dev/null)" || return 0
  grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)' <<<"$names"
}

# The fleet load target's pick: "<box> ..." or "hold ...", "" when it said nothing.
spl_spawn_place_pick() {
  local out
  if [[ -n "${SPAWN_PLACE_PICK_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_PLACE_PICK_CMD 2>&1)"
  else
    out="$(timeout "${SPAWN_PLACE_TIMEOUT:-60}" bash "$PROJ_PATH/run" -a do_spl_box_pick 2>&1)"
  fi
  sed -n 's/^pick=//p' <<<"$out" | tail -1
}

# 4. Take the head: placing, then launch it or hand it to the holder.
spl_spawn_place_take() {  # HOLDER HEAD
  local holder="$1" id place brief
  id="$(jq -r '.ask_id' <<<"$2")"
  place="$(jq -r '.placement // ""' <<<"$2")"
  spl_spawn_q_op ack "$id" "$holder" >/dev/null || return 0
  touch "$(spool_asks_dir)/.place.last"
  brief="$(spl_spawn_place_brief "${place#*:}")"
  if [[ -n "$place" && -n "$brief" ]]; then
    spl_spawn_place_launch "$holder" "$2" "${place%%:*}" "${place#*:}" "$brief"
  else
    spl_spawn_place_hand "$holder" "$2" "$(if [[ -z "$place" ]]; then echo "no placement was recorded"; else echo "no brief file for ${place#*:} under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}"; fi)"
  fi
}

# The brief file of SLUG on this box, or nothing.
spl_spawn_place_brief() {  # SLUG
  local d="${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" f
  [[ -n "$1" ]] || return 0
  for f in "$d/$1.md" "$d/c001-$1.md"; do
    [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# 4a. The existing launcher. The new id closes the ask; HOLD or a failure
# puts it back in line.
spl_spawn_place_launch() {  # HOLDER ROW VENDOR SLUG BRIEF
  local holder="$1" id out err rc=0 agent
  id="$(jq -r '.ask_id' <<<"$2")"
  err="$(mktemp)" || return 1
  # stdout is the launcher's "<ID>[@<box>] <PANE>"; its stderr names other ids
  if [[ -n "${SPAWN_PLACE_LAUNCH_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_PLACE_LAUNCH_CMD "$3" auto "${SPAWN_PLACE_WORKDIR:-$APP_PATH}" "$5" "$4" 2>"$err")" || rc=$?
  else
    out="$(SPOOL_AGENT_ID="${holder%@*}" bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh" \
      "$3" auto "${SPAWN_PLACE_WORKDIR:-$APP_PATH}" "$5" "$4" 2>"$err" 6>&-)" || rc=$?
  fi
  out="$out"$'\n'"$(tail -3 "$err")"; rm -f "$err"
  agent="$(grep -oE '^[acgmq]-[0-9]{3}(@[a-z0-9][a-z0-9-]{0,31})?( |$)' <<<"$out" | tail -1 | tr -d ' ')"
  if (( rc == 0 )) && [[ -n "$agent" ]]; then
    [[ "$agent" == *@* ]] || agent="$agent@$ASKS_BOX"
    spl_spawn_placed_close "$id" "$holder" "$agent"
    return 0
  fi
  spl_spawn_q_op queue "$id" "$holder" >/dev/null
  if (( rc == 10 )); then
    do_log "INFO ask ${id:0:8}: the launcher says HOLD (every box is past its load mark): back in line at position 1"
    return 0
  fi
  do_log "WARN ask ${id:0:8}: the launch of $3:$4 failed (exit $rc): back in line"
  spl_spawn_q_send "$holder" "$holder" blocker spawn-queue "**SPAWN QUEUE: the launch of ask ${id:0:8} ($3:$4) failed** (spawn-window exit $rc); it is back at position 1 and the placer retries it in ${SPAWN_PLACE_GAP_MIN:-10} min. Last lines: $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-400)" || true
}

# 4b. The brief needs the orchestrator: one blocker to the holder.
spl_spawn_place_hand() {  # HOLDER ROW WHY
  local id8
  id8="$(jq -r '.ask_id[0:8]' <<<"$2")"
  if spl_spawn_q_send "$1" "$1" blocker spawn-queue "$(jq -r --arg why "$3" --arg room "${SPAWN_PLACE_ROOM:-}" --arg lock "${SPAWN_PLACE_LOCK_MIN:-30}" '
    "**SPAWN QUEUE: place ask \(.ask_id[0:8]) now** - it is next and the box has room (\($room)). It needs you: \($why).\n\n"
    + "- from \(.from), topic \(.topic), in line \((.wait_s // 0) / 60 | floor) min: \(.summary)\n\n"
    + "Place it with the launcher (spawn-window.sh / spawn-remote.sh), then: `ASK_ID=\(.ask_id[0:8]) PLACED_AS=<ID>@<box> ./run -a do_spl_spawn_placed` (tells the sender). "
    + "Not placed within \($lock) min: it goes back to position 1."' <<<"$2")"; then
    do_log "OK ask $id8 handed to $1 to place ($3)"
  else
    spl_spawn_q_op queue "$(jq -r '.ask_id' <<<"$2")" "$1" >/dev/null
    do_log "WARN ask $id8 could not be handed to $1: back in line"
  fi
}
