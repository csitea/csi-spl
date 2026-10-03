#!/bin/bash
#------------------------------------------------------------------------------
# @description Ask the OD seat that restarts NEXT for its own summary (spec 068
# @description section 6.1, lane L6), from the `M+10,M+25,M+40,M+55 * * * *`
# @description cron (tag `# csi-spl:peer-distill`), 5 min before each restart
# @description slot. Only the seat due at the next slot (do_spl_peer_restart's
# @description seat for minute + 5) is poked, with ONE line typed into its pane:
# @description write <spool root>/<id>/handoff/distilled.md, a condensed prompt
# @description for its next incarnation in its own words (what it was doing,
# @description the messages it holds by id, what it waits on and from whom, the
# @description next step), at most PEER_DISTILL_MAX_LINES (40) lines and
# @description PEER_DISTILL_MAX_BYTES (4096) bytes. The poke time goes to
# @description <id>/handoff/distill.poked: the restart takes the summary only
# @description when it is newer. It does not wait for the file.
# @description INERT until a seat exists. Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PEER_RESTART_OFFSET (optional) - M, as do_spl_peer_restart
# @param PEER_DISTILL_SEAT_N (optional) - poke seat N (1..4) whatever the minute
# @param ROTATE_TMUX (optional) - replaces tmux (tests)
# @example ./run -a do_spl_peer_distill
# @example DRY_RUN=0 ./run -a do_spl_peer_distill
#------------------------------------------------------------------------------
declare -F spl_peer_restart_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-restart.func.sh"

do_spl_peer_distill() {
  spl_peer_init ro || return 1
  spl_peer_restart_conf || return 1
  local min n id at pid pane d line
  min="$(spl_peer_minute)"
  n="${PEER_DISTILL_SEAT_N:-$(spl_peer_slot_seat "$((min + 5))" "$PEER_RESTART_OFFSET")}"
  [[ "$n" =~ ^[1-4]$ ]] || { do_log "FATAL PEER_DISTILL_SEAT_N must be 1..4, got: '$n'"; return 1; }
  id="$(spl_peer_seat_n "$n")"
  [[ -n "$id" ]] || { do_log "INFO no seat $n in $PEER_SEATS (minute $min, offset $PEER_RESTART_OFFSET) - nothing to poke"; return 0; }
  spl_peer_seated "$id"
  spl_rotate_conf || return 1
  at="$(printf ':%02d' "$(spl_peer_slot_minute "$n" "$PEER_RESTART_OFFSET")")"
  d="$SPOOL_ROOT/$id/handoff"
  pid="$(spl_peer_pids "$id" | head -1)"
  [[ -n "$pid" ]] || { spl_peer_rlog "distill-$id" DISTILL SKIP "no live session carries $id"; return 0; }
  pane="$(spl_rotate_pane_of_pid "$pid")"
  [[ -n "$pane" ]] || { spl_peer_rlog "distill-$id" DISTILL SKIP "pid $pid of $id is in no tmux pane"; return 0; }
  line="SEAT DISTILL: your seat $id restarts at $at. Now write $d/distilled.md: a condensed prompt for your next incarnation, in your own words - what you were doing, the messages you hold (ids), what you wait on and from whom, the next step. At most $PEER_DISTILL_MAX_LINES lines and $PEER_DISTILL_MAX_BYTES bytes. Post nothing about it."
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_peer_rlog "distill-$id" DISTILL PLAN "poke $id (pid $pid, pane $pane), due at $at: $line"
    echo "---- DRY_RUN: nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  { mkdir -p "$d" && chmod g+ws "$d"; } 2>/dev/null || true
  spl_lease_now > "$d/distill.poked" || { spl_peer_rlog "distill-$id" DISTILL FAIL "cannot write $d/distill.poked"; return 1; }
  spl_rotate_tmux send-keys -t "$pane" -l "$line" 2>/dev/null ||
    { spl_peer_rlog "distill-$id" DISTILL FAIL "tmux could not type into $pane"; return 1; }
  sleep "${PEER_POKE_SETTLE:-1}"
  spl_rotate_tmux send-keys -t "$pane" Enter 2>/dev/null || true
  spl_peer_rlog "distill-$id" DISTILL OK "poked $id (pid $pid, pane $pane), due at $at"
}
