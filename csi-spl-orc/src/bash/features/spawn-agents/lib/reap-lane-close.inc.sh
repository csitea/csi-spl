# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # RLC_TOPIC is read and now_s, say, APPLY are set by agent-id-reap.sh
# reap-lane-close.inc.sh — what agent-id-retire.sh and agent-id-reap.sh share so
# a retired id's hub lane row cannot stay live unnoticed, and a reaped seat's
# owner topic does not lose its voice silently (SPL-4650).
#
#   $SPOOL_ROOT/.reap/lane-close.tsv      id<TAB>first failed (UTC)<TAB>why: a
#                                         close the hub did not take; the reaper
#                                         retries REAP_LANE_RETRY_MAX (20) a tick,
#                                         a failed one goes to the back; an id
#                                         with no hub row on this box just leaves
#   $SPOOL_ROOT/.reap/lane-close.alerted  epoch of the last alert
#   $SPOOL_ROOT/.reap/topic-tell.tsv      id<TAB>topic: a note the send did not take
#
# rlc_why and rlc_add are the retire's. The rest is the reaper's and needs its
# say(), now_s, APPLY, REAP_H, has_window, has_reg_row and spool-fleet.inc.sh.
# REAP_SEND_CMD and REAP_TOPIC_KIND_CMD (tests) replace spool-send.sh and
# spool-topic-kind.sh.

rlc_queue() { printf '%s' "$SPOOL_ROOT/.reap/lane-close.tsv"; }

# rlc_why OUTPUT: the line of lane-map.sh's output that says why it failed.
rlc_why() {
  local why
  why="$(grep -vE 'spool-env:|not writable, logging|^FATAL Command|^ERROR Action' <<<"$1" | grep -m1 -E 'FATAL|WARN|not found' | tr '\t' ' ' | cut -c1-200)"
  printf '%s' "${why:-no reason printed}"
}

# rlc_add ID WHY: queue a failed close; an id already queued keeps its first
# failure. Non-zero when the queue cannot be written.
rlc_add() {
  local q; q="$(rlc_queue)"
  mkdir -p "${q%/*}" 2>/dev/null || return 1
  ( flock -w 30 9 || exit 1
    if [ -r "$q" ] && cut -f1 "$q" | grep -qx -- "$1"; then exit 0; fi
    printf '%s\t%s\t%s\n' "$1" "$(date -u +%FT%TZ)" "$2" >>"$q"
  ) 9>>"$q.lock"
}

# rlc_drop ID...: take the ids off the queue, under its lock, so a retire
# appending meanwhile keeps its line.
rlc_drop() {
  [ "$#" -gt 0 ] || return 0
  local q ids; q="$(rlc_queue)"; ids="$(printf '%s\n' "$@")"
  ( flock -w 30 9 || exit 1
    grep -vFf <(sed 's/$/\t/' <<<"$ids") "$q" >"$q.tmp"
    cat "$q.tmp" >"$q" && rm -f "$q.tmp"
  ) 9>>"$q.lock"
}

# rlc_back ID...: move the ids to the back of the queue, under its lock, so ids
# that keep failing cannot starve the ones behind them.
rlc_back() {
  [ "$#" -gt 0 ] || return 0
  local q ids; q="$(rlc_queue)"; ids="$(printf '%s\n' "$@")"
  ( flock -w 30 9 || exit 1
    { grep -vFf <(sed 's/$/\t/' <<<"$ids") "$q"; grep -Ff <(sed 's/$/\t/' <<<"$ids") "$q"; } >"$q.tmp"
    cat "$q.tmp" >"$q" && rm -f "$q.tmp"
  ) 9>>"$q.lock"
}

# rlc_holder: who hears it, the dispatch lease holder as <ID>@<box> (a bare id
# from another box reaches this box's standby), else the orchestrator.
rlc_holder() {
  local h=""
  [ -r "$SPOOL_ROOT/dispatch/lease" ] && read -r h _ <"$SPOOL_ROOT/dispatch/lease"
  case "$h" in none@*|unknown:*|'') spool_fleet_orchestrator ;; *) printf '%s' "$h" ;; esac
}

# rlc_tell TASK BODY: one note to the holder, from the orch seat. Exit 5..7 of
# spool-send.sh are delivered with no pane rung.
rlc_tell() {
  local from rc=0; from="$(_spool_fleet_conf LEASE_ORCH)"
  ${REAP_SEND_CMD:-bash "$_here/spool-send.sh"} --from "${from:-$SPOOL_ORCHESTRATOR_ID}" --to "$(rlc_holder)" --kind note \
    --task "$1" --no-ask --body "$2" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|5|6|7) return 0 ;; *) return 1 ;; esac
}

# rlc_map_read: RLC_MAP is the lane map, "" when the hub did not answer. Read
# once per tick, only on a reap or with a queue to drain.
RLC_MAP="" RLC_MAP_READ=0 RLC_TOPIC=""
rlc_map_read() {
  [ "$RLC_MAP_READ" = 0 ] || return 0
  RLC_MAP_READ=1
  RLC_MAP="$(timeout 60 bash "$_here/lane-map.sh" list --all --json 2>/dev/null </dev/null | grep '^{' | tail -1)"
  [ "$(jq -r '.hub // ""' <<<"$RLC_MAP" 2>/dev/null)" = ok ] || RLC_MAP=""
}

# rlc_box: the box whose row a close writes, as do_spl_lane_put reads it.
rlc_box() { printf '%s' "${LANE_BOX:-$(spl_desk_box_default)}"; }

# rlc_no_row ID: true only when the hub answered with rows of this box and none
# of them is the id's (SPL-4987). A close then has nothing to close: its write
# would mint a row with no topic, which the hub refuses for good (rdb 0264). The
# map also lists this box's worktrees as src local, state live: those are no hub
# row. No answer, or one with no hub row on this box (a wrong or renamed box name
# reads the same), is "cannot tell": the close is tried, and a failure alerts.
rlc_no_row() {
  rlc_map_read
  [ -n "$RLC_MAP" ] || return 1
  jq -e --arg a "$1" --arg b "$(rlc_box)" \
    '[.lanes[]? | select(.src != "local" and .agent_box == $b)] | length > 0 and (any(.agent_id == $a) | not)' \
    <<<"$RLC_MAP" >/dev/null 2>&1
}

# rlc_no_row_line ID: the retire's one line when the close found no hub row of
# the id on this box (lane-map.sh done exit 6, SPL-5340); rlc_said_no_row ID OUT
# reads it back, so the reaper sends no "held owner topic ?" note for that seat.
rlc_no_row_line() { printf 'agent-id-retire: INFO no hub lane row of %s on %s: nothing to close\n' "$1" "$(rlc_box)"; }
rlc_said_no_row() { grep -qF "INFO no hub lane row of $1 on " <<<"$2"; }

# rlc_seat_topic ID: into RLC_TOPIC the topic of the id's live row on this box,
# "?" when the hub did not answer.
rlc_seat_topic() {
  rlc_map_read
  RLC_TOPIC='?'
  [ -n "$RLC_MAP" ] || return 0
  RLC_TOPIC="$(jq -r --arg a "$1" --arg b "$(spl_desk_box_default)" \
    '[.lanes[]? | select(.agent_id == $a and .agent_box == $b and .state == "live") | .topic // ""] | first // ""' <<<"$RLC_MAP")"
}

# rlc_topic_is_owner TOPIC: a topic a human reads. "Cannot tell" (exit 3) counts
# as yes: one note too many costs a line, one too few leaves a topic silent.
rlc_topic_is_owner() {
  local kind rc=0
  kind="$(${REAP_TOPIC_KIND_CMD:-bash "$_here/spool-topic-kind.sh"} "$1" 2>/dev/null)" || rc=$?
  case "$rc" in 0) [ "$kind" = owner ] ;; 2) return 1 ;; *) return 0 ;; esac
}

# rlc_tell_task TOPIC / rlc_tell_body ID TOPIC: the note about a reaped seat.
# An owner topic's uuid is refused as a --task to an agent: dispatch-<first 8>.
rlc_tell_task() {
  if [[ "$1" =~ ^[0-9a-f]{8}- ]]; then printf 'dispatch-%s' "${1:0:8}"; else printf 'dispatch-reap-live'; fi
}
rlc_tell_body() {
  if [ "$2" = '?' ]; then
    printf '%s' "Seat $1@$(spl_desk_box_default) was reaped (dead ${REAP_H} h or more, id retired). The hub did not answer when its topic was read, so it may have held an owner topic: read its row with lane-map.sh list --all --json."
  else
    printf '%s' "Seat $1@$(spl_desk_box_default) was reaped (dead ${REAP_H} h or more, id retired). It held owner topic $2, and nobody answers there now: place a seat on it or close it. The reaper restarts nothing."
  fi
}

# rlc_seat_reaped ID TOPIC: the one message for a reaped seat that held an owner
# topic ("?" = unknown, tells too). A note the send did not take waits in
# topic-tell.tsv for the next tick.
rlc_seat_reaped() {
  local id="$1" topic="$2"
  [ -n "$topic" ] || return 0
  [ "$topic" = '?' ] || rlc_topic_is_owner "$topic" || return 0
  if [ "$APPLY" != 1 ]; then say "PLAN tell $(rlc_holder): ${id} held owner topic ${topic}"; return 0; fi
  if rlc_tell "$(rlc_tell_task "$topic")" "$(rlc_tell_body "$id" "$topic")"; then
    say "TOLD $(rlc_holder): ${id} held owner topic ${topic}"
  else
    say "WARN the note about ${id} (topic ${topic}) was not sent; retried next tick"
    printf '%s\t%s\n' "$id" "$topic" >>"$SPOOL_ROOT/.reap/topic-tell.tsv"
  fi
}

# rlc_tell_retry: the notes the send did not take; one that fails again stays.
rlc_tell_retry() {
  local f="$SPOOL_ROOT/.reap/topic-tell.tsv" id topic keep=""
  [ "$APPLY" = 1 ] && [ -s "$f" ] || return 0
  while IFS=$'\t' read -r id topic; do
    if rlc_tell "$(rlc_tell_task "$topic")" "$(rlc_tell_body "$id" "$topic")"; then
      say "TOLD $(rlc_holder): ${id} held owner topic ${topic} (retry)"
    else
      keep+="${id}"$'\t'"${topic}"$'\n'
    fi
  done <"$f"
  printf '%s' "$keep" >"$f"
}

# rlc_alert IDS WHY WAITING: tell the holder the rows stay live, and how many
# more wait untried, at most once per REAP_ALERT_GAP_S (default 1 h). A send
# that fails tries again next tick.
rlc_alert() {
  local stamp="$SPOOL_ROOT/.reap/lane-close.alerted" gap="${REAP_ALERT_GAP_S:-3600}" last=0 more=""
  [ "${3:-0}" -gt 0 ] && more=" ${3} more in the queue were not tried this tick."
  [ -r "$stamp" ] && read -r last <"$stamp"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ $((now_s - last)) -lt "$gap" ]; then
    say "INFO the lane-close alert was raised $(( (now_s - last) / 60 )) min ago: no second one inside ${gap} s"
    return 0
  fi
  if rlc_tell dispatch-reap-live "ALERT the hub lane rows of $1 on $(spl_desk_box_default) stay live though their ids are retired: the close failed again ($2). The reaper retries ${REAP_LANE_RETRY_MAX:-20} a tick from $(rlc_queue), the failed ones last.${more} Until then those seats read live on the lane map."; then
    say "ALERT told $(rlc_holder): hub lane rows not closed: $1"
    printf '%s\n' "$now_s" >"$stamp"
  else
    say "WARN the alert about the rows of $1 was not sent; tried again next tick"
  fi
}

# rlc_drain: retry the queued closes, at most REAP_LANE_RETRY_MAX (20) a tick;
# the rest are counted and wait, and the failed ones go behind them.
# An id in use again (re-issued after its quarantine) leaves the queue unclosed:
# its row is a new lane's now. So does an id with no hub row on this box, read
# from the map or by the close itself (exit 6): nothing to close, no retry and no
# alert. The binary's "topic is required" line alone is no such answer: it also
# follows a read the hub did not answer (SPL-5340).
rlc_drain() {
  local q n=0 waiting=0 max="${REAP_LANE_RETRY_MAX:-20}" id first why out rc last_why=""
  local -a gone=() failed=()
  q="$(rlc_queue)"
  [ -s "$q" ] || return 0
  while IFS=$'\t' read -r id first why; do
    [ -n "$id" ] || continue
    if has_window "$id" || has_reg_row "$id" || ai_alive_fast "$id" >/dev/null 2>&1; then
      say "INFO lane-close ${id}: the id is in use again, the row is not the retired seat's; off the queue"
      gone+=("$id"); continue
    fi
    if rlc_no_row "$id"; then
      if [ "$APPLY" = 1 ]; then
        say "INFO lane-close ${id}: no hub row on $(rlc_box), nothing to close; off the queue"
        gone+=("$id")
      else
        say "PLAN lane-close ${id}: no hub row on $(rlc_box), nothing to close; would leave the queue"
      fi
      continue
    fi
    n=$((n + 1)); [ "$n" -le "$max" ] || { waiting=$((waiting + 1)); continue; }
    if [ "$APPLY" != 1 ]; then say "PLAN lane-close ${id}: lane-map.sh done (failing since ${first}: ${why})"; continue; fi
    rc=0; out="$(timeout 60 bash "$_here/lane-map.sh" "done" --agent "$id" 2>&1 </dev/null)" || rc=$?
    if [ "$rc" = 0 ]; then
      say "LANE ${id}: the hub row is closed (failing since ${first})"
      gone+=("$id")
    elif [ "$rc" = 6 ]; then
      say "INFO lane-close ${id}: no hub row on $(rlc_box), nothing to close; off the queue"
      gone+=("$id")
    else
      last_why="$(rlc_why "$out")"
      say "WARN lane-close ${id}: not closed (rc ${rc}): ${last_why}"
      failed+=("$id")
    fi
  done <"$q"
  [ "$APPLY" = 1 ] && { rlc_drop "${gone[@]}"; rlc_back "${failed[@]}"; }
  [ "$waiting" -eq 0 ] || say "INFO lane-close: ${waiting} more wait for a later tick (REAP_LANE_RETRY_MAX=${max})"
  [ "${#failed[@]}" -eq 0 ] || rlc_alert "${failed[*]}" "$last_why" "$waiting"
}
