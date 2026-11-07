#!/bin/bash
#------------------------------------------------------------------------------
# @description The fleet-stopped alarm (SPL-4964, spec 146, what-broke-20261106
# @description consensus section 7 item 1): on 2026-11-06 the placer held every
# @description new lane from 09:05Z and nothing told anyone the whole fleet had
# @description stopped. It alarms on the outcome, not on one cause: the spawn
# @description queue is above 0, every box with a fresh sample is under
# @description load_max_pct of its cores (load5 / cpus, the box pick's measure)
# @description and nothing landed on master for quiet_min; or, whatever the load
# @description and the samples, nothing landed for quiet_max_min (a stuck process
# @description family keeps one box busy for ever). Then ONE post in the
# @description ops alarm channel, naming the hold (the placer's fresh .place.wait
# @description reasons). One post per episode: an episode ends only when master
# @description moves or the queue empties, never when the load moves, so a load
# @description around the mark does not post twice. Across boxes the channel
# @description itself is the memory: a FLEET STOPPED topic newer than the last
# @description landing and the last empty queue means the episode was already
# @description told; after read_fail_max_min of failed reads a channel no longer
# @description holds the post. "Landed" is the later
# @description of the head's committer time and when this box first saw that
# @description head, since a commit waits in the gate after its last rebase.
# @description No verdict, and no post, when the hub, the samples or the fetch do
# @description not answer. Only the machine that places (the orch holder's, as
# @description do_spl_spawn_place) posts; another machine only tracks the head and
# @description the empty queue.
# @description Dry run unless DRY_RUN=0: prints the post, writes nothing.
# @param FLEET_STOPPED_LOAD_PCT (optional) - default cnf env.ops_alarms.fleet_stopped.load_max_pct
# @param FLEET_STOPPED_QUIET_MIN (optional) - default cnf env.ops_alarms.fleet_stopped.quiet_min
# @param FLEET_STOPPED_QUIET_MAX_MIN (optional) - default cnf env.ops_alarms.fleet_stopped.quiet_max_min
# @param FLEET_STOPPED_READ_FAIL_MIN (optional) - default cnf env.ops_alarms.fleet_stopped.read_fail_max_min
# @param FLEET_STOPPED_SAMPLE_MIN (optional) - a box sample older than this many minutes does not count, default 15
# @param FLEET_STOPPED_STATE (optional) - the state file, default $XDG_STATE_HOME/csi-spl/fleet-stopped-alarm.state
# @param FLEET_STOPPED_AGENT (optional) - the post's author, default the orch holder, then the first seat this box's desk announces (spl_lane_issue_desk), then LEASE_ORCH
# @param DESK_CHANNEL (optional) - default cnf env.ops_alarms.channel (spl_ops_alarm_channel)
# @param FLEET_STOPPED_NOW (optional, tests) - the clock, epoch seconds
# @param FLEET_STOPPED_LAND_CMD (optional, tests) - prints "<head sha> <committer epoch>" instead of fetching
# @param FLEET_STOPPED_CMD (optional, tests) - replaces the post: the text on stdin, exit 0 = posted
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ASKS_HOLDER (optional) - as do_spl_asks_tick
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_fleet_stopped_alarm
# @example DRY_RUN=0 ./run -a do_spl_fleet_stopped_alarm
#------------------------------------------------------------------------------
do_spl_fleet_stopped_alarm() {
  local rows n
  FSA_DRY="${DRY_RUN:-1}" FSA_NOW="${FLEET_STOPPED_NOW:-$(date +%s)}"
  [[ "$FSA_DRY" == 0 || "$FSA_DRY" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$FSA_DRY'"; return 1; }
  spl_fsa_limits || return 1
  spl_asks_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "INFO no fleet hub here: no spawn queue to watch"; return 0; }
  FSA_STATE="${FLEET_STOPPED_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/fleet-stopped-alarm.state}"
  spl_fsa_state_read
  spl_fsa_land || { do_log "WARN master could not be read: no verdict this tick"; return 0; }
  rows="$(spl_spawn_q_rows)" || { spl_fsa_state_save; do_log "WARN the hub did not answer: no verdict this tick"; return 0; }
  n="$(jq 'length' <<<"$rows")"
  # Every machine tracks this, as it does the head: the role may move here later.
  (( n > 0 )) || { FSA_POSTED=0 FSA_EMPTIED="$FSA_NOW" FSA_READ_FAIL=0; }
  spl_fsa_state_save
  FSA_HOLDER="$(spl_asks_holder)"
  if [[ -n "$FSA_HOLDER" && "${FSA_HOLDER##*@}" != "$ASKS_BOX" ]]; then
    do_log "INFO the orch role is held on ${FSA_HOLDER##*@}: its machine alarms"
    return 0
  fi
  (( n > 0 )) || { do_log "INFO the spawn queue is empty: no alarm"; return 0; }
  spl_fsa_verdict "$n"
}

# The verdict on a queue of N, with the head already tracked.
spl_fsa_verdict() {  # N
  local loads="" txt why
  FSA_AGE=$(( (FSA_NOW - FSA_LAND) / 60 ))
  (( FSA_AGE >= FSA_QUIET )) || { do_log "INFO landed ${FSA_AGE} min ago, under ${FSA_QUIET} min: no alarm"; return 0; }
  loads="$(spl_fsa_loads)" || loads=""
  [[ -z "$loads" ]] || txt="$(jq -r 'map("\(.box) \(.pct | floor)%") | join(", ")' <<<"$loads")"
  why="$1 asks queued and nothing landed for ${FSA_AGE} min: fired on the ${FSA_QUIET_MAX} min ceiling, with a box still at or over ${FSA_PCT}% of its cores (${txt:-})"
  [[ -n "$loads" ]] || why="$1 asks queued and nothing landed for ${FSA_AGE} min: fired on the ${FSA_QUIET_MAX} min ceiling, with no box reporting a fresh load sample"
  if [[ -n "$loads" ]] && jq -e --argjson m "$FSA_PCT" 'all(.[]; .pct < $m)' >/dev/null <<<"$loads"; then
    why="$1 asks queued, every box is under ${FSA_PCT}% of its cores ($txt), and nothing landed for ${FSA_AGE} min"
  elif (( FSA_AGE < FSA_QUIET_MAX )); then
    [[ -n "$loads" ]] || { do_log "WARN no fresh box sample: no verdict this tick"; return 0; }
    do_log "INFO a box is at or over ${FSA_PCT}% of its cores: no alarm"
    return 0
  fi
  (( FSA_POSTED == 0 )) || { do_log "INFO the fleet stays stopped, already posted for this episode"; return 0; }
  spl_fsa_fire "$why"
}

# The four limits, env over cnf; no literal default in code.
spl_fsa_limits() {
  local cnf="${OPS_ALARM_CNF:-$PROJ_PATH/../csi-spl-cnf/csi-spl/all.env.yaml}" v
  FSA_PCT="${FLEET_STOPPED_LOAD_PCT:-$(yq -r '.env.ops_alarms.fleet_stopped.load_max_pct // ""' "$cnf" 2>/dev/null)}"
  FSA_QUIET="${FLEET_STOPPED_QUIET_MIN:-$(yq -r '.env.ops_alarms.fleet_stopped.quiet_min // ""' "$cnf" 2>/dev/null)}"
  FSA_QUIET_MAX="${FLEET_STOPPED_QUIET_MAX_MIN:-$(yq -r '.env.ops_alarms.fleet_stopped.quiet_max_min // ""' "$cnf" 2>/dev/null)}"
  FSA_READ_MAX="${FLEET_STOPPED_READ_FAIL_MIN:-$(yq -r '.env.ops_alarms.fleet_stopped.read_fail_max_min // ""' "$cnf" 2>/dev/null)}"
  for v in "$FSA_PCT" "$FSA_QUIET" "$FSA_QUIET_MAX" "$FSA_READ_MAX"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL env.ops_alarms.fleet_stopped.load_max_pct, quiet_min, quiet_max_min and read_fail_max_min must be set in $cnf, got: '$FSA_PCT' '$FSA_QUIET' '$FSA_QUIET_MAX' '$FSA_READ_MAX'"; return 1; }
  done
}

# The state file: head sha TAB first seen epoch TAB 1 when this episode posted
# TAB when the queue was last seen empty TAB when the channel reads began to fail.
spl_fsa_state_read() {
  FSA_HEAD="" FSA_SEEN=0 FSA_POSTED=0 FSA_EMPTIED=0 FSA_READ_FAIL=0
  [[ -r "$FSA_STATE" ]] && IFS=$'\t' read -r FSA_HEAD FSA_SEEN FSA_POSTED FSA_EMPTIED FSA_READ_FAIL <"$FSA_STATE"
  [[ "${FSA_EMPTIED:-}" =~ ^[0-9]+$ ]] || FSA_EMPTIED=0
  [[ "${FSA_READ_FAIL:-}" =~ ^[0-9]+$ ]] || FSA_READ_FAIL=0
  [[ "${FSA_SEEN:-}" =~ ^[0-9]+$ ]] || FSA_SEEN=0
  [[ "${FSA_POSTED:-}" == 1 ]] || FSA_POSTED=0
}

spl_fsa_state_save() {
  [[ "$FSA_DRY" == 0 ]] || return 0
  mkdir -p "$(dirname "$FSA_STATE")" || { do_log "FATAL cannot create the dir of $FSA_STATE"; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$FSA_HEAD" "$FSA_SEEN" "$FSA_POSTED" "$FSA_EMPTIED" "$FSA_READ_FAIL" >"$FSA_STATE.tmp.$$" && mv -f "$FSA_STATE.tmp.$$" "$FSA_STATE"
}

# Sets FSA_HEAD, FSA_SEEN, FSA_LAND; a moved head ends the episode. A failed
# fetch is exit 1, never an old origin/master read as "nothing landed".
spl_fsa_land() {
  local out sha ct
  if [[ -n "${FLEET_STOPPED_LAND_CMD:-}" ]]; then
    out="$($FLEET_STOPPED_LAND_CMD)" || return 1
  else
    bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/git-fetch-fresh.sh" -C "$PROJ_PATH" >/dev/null 2>&1 || return 1
    out="$(git -C "$PROJ_PATH" log -1 --format='%H %ct' origin/master)" || return 1
  fi
  read -r sha ct <<<"$out"
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ && "$ct" =~ ^[0-9]+$ ]] || return 1
  if [[ "$sha" != "$FSA_HEAD" ]]; then
    if [[ -n "$FSA_HEAD" ]]; then FSA_SEEN="$FSA_NOW"; else FSA_SEEN="$ct"; fi
    FSA_HEAD="$sha" FSA_POSTED=0 FSA_READ_FAIL=0
  fi
  FSA_LAND=$(( ct > FSA_SEEN ? ct : FSA_SEEN ))
}

# The newest fresh sample per box as [{box, pct}]; exit 1 when no box has one,
# so an empty set can never read as "every box is idle".
spl_fsa_loads() {
  local fresh="${FLEET_STOPPED_SAMPLE_MIN:-15}" out
  out="$(spl_lane_spool box-stats list --since "${fresh}m" 2>/dev/null)" || return 1
  jq -e -c --argjson now "$FSA_NOW" --argjson max "$(( fresh * 60 ))" '
    [.rows[] | . + {t: (.at | sub("\\.[0-9]+"; "") | fromdateiso8601)}
     | select(.cpus > 0 and $now - .t <= $max and .t <= $now)]
    | group_by(.box) | map(max_by(.t) | {box, pct: (.load5 * 100 / .cpus)})
    | select(length > 0)' <<<"$out" 2>/dev/null
}

# What holds the placer: its reasons of the last quiet_min, most asks first.
spl_fsa_hold() {
  local f txt=""
  [[ -n "$FSA_HOLDER" ]] || { printf 'nobody holds the orch role, so nothing is placed'; return 0; }
  f="$(spool_asks_dir)/.place.wait"
  [[ -r "$f" ]] && txt="$(awk -F'\t' -v min="$(( FSA_NOW - FSA_QUIET * 60 ))" '$2 + 0 >= min { c[$3]++ }
      END { for (r in c) printf "%d\t%s\n", c[r], r }' "$f" | sort -rn | head -3 |
    awk -F'\t' '{ printf "%s%s (%d %s)", (NR > 1 ? "; " : ""), $2, $1, ($1 == 1 ? "ask" : "asks") }')"
  [[ -n "$txt" ]] || txt="the placer recorded no hold in the last ${FSA_QUIET} min, so read its spawn-place log"
  printf '%s' "$txt"
}

# One post, unless the channel already holds this episode's.
spl_fsa_fire() {  # WHY
  local text chan
  text="**FLEET STOPPED** $1 (head ${FSA_HEAD:0:9}). The hold: $(spl_fsa_hold). Check: \`./run -a do_spl_spawn_queue\`."
  if [[ "$FSA_DRY" == 1 ]]; then
    echo "PLAN post: $text"
    do_log "OK DRY_RUN no post, no state written. Re-run with DRY_RUN=0."
    return 0
  fi
  chan="$(spl_ops_alarm_channel)" || { do_log "FATAL fleet-stopped: no channel (cnf env.ops_alarms.channel), nothing posted"; return 1; }
  FSA_WHO="$(spl_fsa_who)"
  spl_fsa_told "$chan" || case $? in
    2) spl_fsa_read_failed || return 0 ;&
    *) spl_fsa_post "$chan" "$text" || { do_log "WARN the fleet-stopped post failed: retried next tick"; return 1; }
       do_log "ALERT posted in #$chan: $text" ;;
  esac
  FSA_POSTED=1 FSA_READ_FAIL=0
  spl_fsa_state_save
}

# A failed read holds the post for read_fail_max_min, counted from the first
# failure: an extra post is cheaper than silence. Exit 0: post unread.
spl_fsa_read_failed() {
  (( FSA_READ_FAIL > 0 )) || FSA_READ_FAIL="$FSA_NOW"
  if (( (FSA_NOW - FSA_READ_FAIL) / 60 < FSA_READ_MAX )); then
    spl_fsa_state_save
    do_log "WARN the channel could not be read: retried next tick, for up to ${FSA_READ_MAX} min"
    return 1
  fi
  do_log "WARN the channel could not be read for ${FSA_READ_MAX} min: posting unread"
}

# Exit 0: a FLEET STOPPED topic newer than the last landing and the last empty
# queue is in CHAN (another machine told it, before the lease moved). 1: none.
# 2: the read failed.
spl_fsa_told() {  # CHAN
  local out mark=$(( FSA_LAND > FSA_EMPTIED ? FSA_LAND : FSA_EMPTIED ))
  [[ -n "$FSA_WHO" ]] || return 2
  out="$(spl_lane_spool topics --as "$FSA_WHO" --channel "$1" --limit 100 --json 2>/dev/null)" || return 2
  jq -e '.topics | type == "array"' >/dev/null 2>&1 <<<"$out" || return 2
  jq -e --argjson mark "$mark" 'any(.topics[]; (.subject | contains("FLEET STOPPED"))
      and ((.last_ts | sub("\\.[0-9]+"; "") | fromdateiso8601) > $mark))' >/dev/null 2>&1 <<<"$out"
}

# The author and reader. A role seat with no holder is dropped from the desk's
# roster after a while and refused from_not_announced, so with no holder take
# the seat this box's desk announces, as the issue filing does.
spl_fsa_who() {
  local a="${FLEET_STOPPED_AGENT:-${FSA_HOLDER%@*}}"
  [[ -n "$a" ]] || a="$(unset DESK_AGENT; export ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX"
    spl_lane_issue_desk "$SPOOL_ROOT" 0 >/dev/null 2>&1 && printf '%s' "${DESK_AGENT:-}")"
  printf '%s' "${a:-${LEASE_ORCH:-}}"
}

# As the weekly limit alert posts: do_spl_desk_post from this box's desk.
spl_fsa_post() {  # CHAN TEXT
  if [[ -n "${FLEET_STOPPED_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $FLEET_STOPPED_CMD <<<"$2" >/dev/null
    return
  fi
  [[ -n "$FSA_WHO" && -z "${LANE_HUB_CMD:-}" ]] || { do_log "ALERT (not posted, author '${FSA_WHO}'): $2"; return 1; }
  ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="$FSA_WHO" DESK_CHANNEL="$1" \
    DESK_KIND=blocker DESK_BODY="$2" DRY_RUN=0 do_spl_desk_post >/dev/null 2>&1
}
