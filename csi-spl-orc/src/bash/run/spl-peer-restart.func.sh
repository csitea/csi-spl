#!/bin/bash
#------------------------------------------------------------------------------
# @description Restart the OD seat whose quarter-hour slot this is (spec 068
# @description section 6.1, lane L6), from the `M,M+15,M+30,M+45 * * * *`
# @description cron (tag `# csi-spl:peer-restart`). M = PEER_RESTART_OFFSET
# @description (0 on the first box, 7 on the second, so the same seat never
# @description restarts on both boxes at once); seat N = (minute - M)/15 + 1,
# @description i.e. seat 001 at M, 002 at M+15, 003 at M+30, 004 at M+45.
# @description Mechanical, no model call. On this box, one seat at a time:
# @description   GATE    - the seat is in <spool root>/peer/seats, one live
# @description             session at most (none: a fresh one is started),
# @description             the seat's id lock (spec 102 4.2; held = exit 4)
# @description   LOOP    - stop its poll loop (its locks stay: the hub names
# @description             the SEAT as responsible, not the session)
# @description   HANDOFF - the 060 handoff file minus its lease lines, in
# @description             <spool root>/<id>/handoff/<rid>.md
# @description   SEED    - the seat's own distilled.md (do_spl_peer_distill,
# @description             written after its poke; cut at PEER_DISTILL_MAX_LINES
# @description             / _BYTES with a [cut] line) + the handoff. No
# @description             summary: the handoff alone and ONE
# @description             `WARN distill-missing <id>` in rotate.log; the
# @description             restart never waits for it
# @description   SPAWN   - a fresh session under the same id (spawn-window.sh,
# @description             SPAWN_REUSE_ID=1, the seat's harness); none within
# @description             PEER_START_WAIT (300 s): the new one is closed, the
# @description             old one keeps the seat, its poll loop is started
# @description             again, and the owner is alerted (060 D2)
# @description   RETIRE  - /exit-clean the old session, TERM after
# @description             PEER_EXIT_WAIT (300 s), then KILL (060 D4)
# @description   LOOP    - start the seat's poll loop (do_spl_peer_poll)
# @description One line per step in <spool root>/dispatch/rotate.log. INERT
# @description until a seat exists. Dry run unless DRY_RUN=0 (PLAN lines).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PEER_RESTART_OFFSET (optional) - M, 0..14; env > <spool root>/peer/peer.conf > 0
# @param PEER_RESTART_SEAT_N (optional) - restart seat N (1..4) whatever the minute
# @param PEER_START_WAIT / PEER_EXIT_WAIT (optional) - seconds, default 300 / 300
# @param PEER_DISTILL_MAX_LINES / PEER_DISTILL_MAX_BYTES (optional) - default 40 / 4096
# @param PEER_RETIRE_CMD / PEER_RUN / ROTATE_SPAWN / ROTATE_TMUX / ROTATE_AI (optional) - replace the retire, the ./run that starts the loop, spawn-window.sh, tmux, the identity map (tests)
# @example ./run -a do_spl_peer_restart
# @example DRY_RUN=0 ./run -a do_spl_peer_restart
# @example PEER_RESTART_SEAT_N=2 ./run -a do_spl_peer_restart
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"
declare -F spl_peer_stop >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-ensure.func.sh"

do_spl_peer_restart() {
  spl_peer_init ro || return 1
  spl_peer_restart_conf || return 1
  local min n id
  min="$(spl_peer_minute)"
  n="${PEER_RESTART_SEAT_N:-$(spl_peer_slot_seat "$min" "$PEER_RESTART_OFFSET")}"
  [[ "$n" =~ ^[1-4]$ ]] || { do_log "FATAL PEER_RESTART_SEAT_N must be 1..4, got: '$n'"; return 1; }
  id="$(spl_peer_seat_n "$n")"
  [[ -n "$id" ]] || { do_log "INFO no seat $n in $PEER_SEATS (minute $min, offset $PEER_RESTART_OFFSET) - nothing to restart"; return 0; }
  spl_peer_seated "$id"
  spl_rotate_conf || return 1
  spl_peer_restart_seat "$id"
}

# ---- shared by restart, distill and the cron installers ------------------------

# PEER_RESTART_OFFSET (env > <spool root>/peer/peer.conf, read, never sourced
# > 0) and the restart knobs. Needs spl_peer_init.
spl_peer_restart_conf() {
  local k v
  if [[ -z "${PEER_RESTART_OFFSET:-}" && -f "$PEER_DIR/peer.conf" ]]; then
    PEER_RESTART_OFFSET="$(sed -n 's/^PEER_RESTART_OFFSET=\([0-9]*\)$/\1/p' "$PEER_DIR/peer.conf" | tail -1)"
  fi
  : "${PEER_RESTART_OFFSET:=0}" "${PEER_START_WAIT:=300}" "${PEER_EXIT_WAIT:=300}"
  : "${PEER_DISTILL_MAX_LINES:=40}" "${PEER_DISTILL_MAX_BYTES:=4096}"
  [[ "$PEER_RESTART_OFFSET" =~ ^[0-9]+$ ]] && (( 10#$PEER_RESTART_OFFSET < 15 )) ||
    { do_log "FATAL PEER_RESTART_OFFSET must be 0..14 (four slots 15 min apart), got: '$PEER_RESTART_OFFSET'"; return 1; }
  PEER_RESTART_OFFSET=$((10#$PEER_RESTART_OFFSET))
  for k in PEER_START_WAIT PEER_EXIT_WAIT PEER_DISTILL_MAX_LINES PEER_DISTILL_MAX_BYTES; do
    v="${!k}"; [[ "$v" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $k must be a positive integer, got: '$v'"; return 1; }
  done
  (( PEER_DISTILL_MAX_LINES >= 2 && PEER_DISTILL_MAX_BYTES >= 16 )) ||
    { do_log "FATAL PEER_DISTILL_MAX_LINES must be >= 2 and PEER_DISTILL_MAX_BYTES >= 16"; return 1; }
  return 0
}

# The minute of the hour, on the LEASE_NOW clock (tests) or the real one.
spl_peer_minute() { local m; m="$(date -u -d "@$(spl_lease_now)" +%M)"; echo $((10#$m)); }

# spl_peer_slot_seat MINUTE OFFSET: the seat number (1..4) of the slot that
# MINUTE falls in; a cron line that starts late still names its own seat.
spl_peer_slot_seat() { echo $(( ((($1 - $2) % 60 + 60) % 60) / 15 + 1 )); }

# spl_peer_slot_minute N OFFSET: the minute seat N restarts at.
spl_peer_slot_minute() { echo $(( ($2 + ($1 - 1) * 15) % 60 )); }

# spl_peer_seat_n N: the id of this box's seat number N (c-001 .. g-004), or nothing.
spl_peer_seat_n() {
  spl_peer_seats | awk -v n="$(printf '%03d' "$1")" '{ split($1, a, "-"); if (a[2] == n) { print $1; exit } }'
}

# spl_peer_pids ID: every live session process of a seat, ascending. Any
# harness (claude, or a grok seat's CLI / node / bun), matched by its
# SPOOL_AGENT_ID, as spl_rotate_pids does for claude alone.
spl_peer_pids() {
  local id="$1" d pid comm root="${LEASE_PROC_ROOT:-/proc}"
  local -a other=()
  {
    for d in "$root"/[0-9]*; do
      pid="${d##*/}"
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null || true
      spl_peer_harness_comm "$comm" || continue
      if [[ -r "$d/environ" ]]; then
        if grep -zx "SPOOL_AGENT_ID=$id" "$d/environ" >/dev/null 2>&1; then echo "$pid"; fi
      else
        other+=("$pid")
      fi
    done
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" | awk -v id="$id" '$2 == id {print $1}'
    fi
  } | sort -n
}
spl_peer_harness_comm() { [[ "$1" == claude || "$1" == node || "$1" == bun || ( -n "${PEER_HARNESS:-}" && "$1" == "$PEER_HARNESS" ) ]]; }

# 0 while PID is a live session process of any harness (spl_rotate_alive
# knows claude only: a grok seat would read dead at once).
spl_peer_alive() {
  local comm=""
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  { read -r comm < "${LEASE_PROC_ROOT:-/proc}/$1/comm"; } 2>/dev/null || true
  spl_peer_harness_comm "$comm"
}

# spl_peer_rlog RID PHASE RESULT DETAIL: one rotate.log line (and stdout).
# Not spl_rotate_log: that one also writes rotate.<orch|dispatch>.state,
# which belongs to the 060 rotations still running until the hand-over.
spl_peer_rlog() {
  local line
  line="$(date -u +%FT%TZ) $1 $2 $3 ${4:-}"
  printf '%s\n' "$line"
  [[ "$3" == PLAN || "${DRY_RUN:-1}" == 1 ]] && return 0
  echo "$line" >> "$ROTATE_LOG"
}

# spl_peer_with_lib CMD...: a rotate-lib call with its log, liveness and
# role lookups pointed at the seat (in a subshell, so nothing leaks).
spl_peer_with_lib() {
  (
    spl_rotate_log() { spl_peer_rlog "$1" "$2" "$3" "${4:-}"; }
    spl_rotate_alive() { spl_peer_alive "$1"; }
    spl_rotate_role_id() { echo "$PEER_RESTART_ID"; }
    "$@"
  )
}

# ---- the restart -----------------------------------------------------------------

spl_peer_restart_seat() {
  local id="$1" rid d hand seed pid="" pane="" name="" n
  local -a pids
  PEER_RESTART_ID="$id"
  rid="$(date -u -d "@$(spl_lease_now)" +%Y%m%dT%H%MZ)-peer-$id"
  d="$SPOOL_ROOT/$id/handoff"
  hand="$d/$rid.md" seed="$d/$rid.seed.md"
  mkdir -p "$PEER_DIR" || { do_log "FATAL cannot create $PEER_DIR"; return 1; }
  exec 6>> "$PEER_DIR/restart.lock"
  flock -n 6 || { spl_peer_rlog "$rid" GATE SKIP "another seat restart runs on this box"; return 0; }
  # spec 102 4.2: the id lock. Refused: stdout only, not rotate.log, where a
  # line under this run id would read as the end of the holder's run
  local idl=0
  spl_agent_id_lock "$id" do_spl_peer_restart "$rid" || idl=$?
  (( idl == 0 )) || { echo "$(date -u +%FT%TZ) $rid GATE REFUSED id lock: $SPL_ID_LOCK_WHY"; return "$idl"; }
  mapfile -t pids < <(spl_peer_pids "$id")
  if (( ${#pids[@]} > 1 )); then
    spl_peer_rlog "$rid" GATE SKIP "duplicate: ${#pids[@]} live processes carry $id (pids ${pids[*]})"; return 0
  fi
  if (( ${#pids[@]} == 1 )); then
    pid="${pids[0]}"
    pane="$(spl_rotate_pane_of_pid "$pid")"
    [[ -n "$pane" ]] || { spl_peer_rlog "$rid" GATE SKIP "pid $pid of $id is in no tmux pane"; return 0; }
    name="$(spl_rotate_tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null || true)"
  fi
  ROTATE_RID="$rid" ROTATE_OLD_PID="$pid" ROTATE_OLD_PANE="$pane" ROTATE_OLD_NAME="$name" ROTATE_NEW_PID="" ROTATE_NEW_PANE=""
  # shellcheck disable=SC2034 # read by spl_rotate_handoff (spl-rotate-lib.func.sh)
  ROTATE_QUIESCE="not run (seat restart)"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_peer_rlog "$rid" GATE PLAN "seat $id ($PEER_HARNESS): ${pid:+pid $pid in $pane '$name'}${pid:-no live session: start a fresh one}"
    spl_peer_rlog "$rid" LOOP PLAN "stop the $id poll loop (its locks stay on the hub)"
    spl_peer_rlog "$rid" HANDOFF PLAN "$hand (the 060 handoff, no lease lines)"
    spl_peer_rlog "$rid" SEED PLAN "$seed: $(spl_peer_distill_state "$id") + the handoff"
    spl_peer_rlog "$rid" SPAWN PLAN "$ROTATE_SPAWN $PEER_HARNESS $id $(spl_rotate_workdir "$id") <seed> (SPAWN_REUSE_ID=1); wait ${PEER_START_WAIT}s for its pid"
    [[ -n "$pid" ]] && spl_peer_rlog "$rid" RETIRE PLAN "/exit-clean into $pane, TERM after ${PEER_EXIT_WAIT}s, KILL after ${ROTATE_TERM_WAIT}s more"
    spl_peer_rlog "$rid" LOOP PLAN "start the $id poll loop"
    echo "---- DRY_RUN: nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi

  spl_peer_stop "$id" >/dev/null || { spl_peer_rlog "$rid" LOOP FAIL "the $id poll loop did not stop: no restart"; return 1; }
  spl_peer_rlog "$rid" LOOP OK "the $id poll loop is stopped"

  # the agent writes its distilled.md here; the box user runs this
  { mkdir -p "$d" && chmod g+ws "$d"; } 2>/dev/null || true
  [[ -d "$d" ]] || { spl_peer_rlog "$rid" HANDOFF FAIL "cannot create $d"; spl_peer_loop_start "$id" "$rid"; return 1; }
  spl_rotate_handoff peer "$id" "$rid" - | grep -v '^- lease' > "$hand" || true
  chmod 0640 "$hand" 2>/dev/null || true
  spl_peer_rlog "$rid" HANDOFF OK "$hand ($(wc -l < "$hand") lines)"
  spl_peer_seed "$id" "$rid" "$hand" "$seed"
  chmod 0640 "$seed" 2>/dev/null || true

  if ! spl_peer_restart_spawn "$id" "$seed"; then
    spl_peer_with_lib spl_rotate_restore "$id" "$pane" "$ROTATE_NEW_PANE"
    spl_peer_rlog "$rid" SPAWN FAIL "$ROTATE_ERR; ${pid:+the old session (pid $pid) keeps the seat}${pid:-the seat has no session}"
    spl_peer_with_lib spl_rotate_alert peer "$rid" SPAWN "$ROTATE_ERR"
    spl_peer_loop_start "$id" "$rid"
    return 1
  fi
  spl_peer_rlog "$rid" SPAWN OK "new pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"

  if [[ -n "$pid" ]]; then
    if spl_peer_retire "$pane" "$pid"; then
      spl_peer_rlog "$rid" RETIRE OK "pid $pid gone"
    else
      spl_peer_rlog "$rid" RETIRE FAIL "pid $pid survived SIGKILL: two sessions carry $id until a human clears it"
      spl_peer_with_lib spl_rotate_alert peer "$rid" RETIRE "old pid $pid survived SIGKILL"
    fi
    spl_rotate_tmux kill-window -t "$pane" 2>/dev/null || true
  fi
  spl_peer_loop_start "$id" "$rid"
  n="$(spl_peer_pids "$id" | grep -c . || true)"
  spl_peer_rlog "$rid" DONE OK "$id@$PEER_BOX is pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE ($n process(es))"
  return 0
}

# Start the seat's poll loop, as do_spl_peer_ensure does.
spl_peer_loop_start() {
  mkdir -p "$PEER_DIR/$1"
  PEER_SEAT="$1" PEER_BOX="$PEER_BOX" spl_lease_detach "$PEER_DIR/$1/poll.out" "${PEER_RUN:-$PROJ_PATH/run}" -a do_spl_peer_poll
  spl_peer_rlog "$2" LOOP OK "the $1 poll loop is started (log $PEER_DIR/$1/poll.out)"
}

# The old session out: PEER_RETIRE_CMD PANE PID (tests), else /exit-clean,
# /exit once its turn ends, TERM after PEER_EXIT_WAIT, KILL (060 D4).
spl_peer_retire() {
  if [[ -n "${PEER_RETIRE_CMD:-}" ]]; then "$PEER_RETIRE_CMD" "$1" "$2"; return; fi
  spl_peer_with_lib spl_rotate_end "$1" "$2" /exit-clean "$PEER_EXIT_WAIT" "$ROTATE_TERM_WAIT" /exit
}

# spl_peer_restart_spawn ID SEED: rename the old window (if any) to its
# retiring name, start a fresh session of the seat's harness under the same
# id, wait PEER_START_WAIT for its pid, check it runs as the agent user,
# adopt it in the identity map. Sets ROTATE_NEW_PANE / ROTATE_NEW_PID;
# non-zero = failed, the reason in ROTATE_ERR.
# shellcheck disable=SC2034 # ROTATE_ERR is read by the caller
spl_peer_restart_spawn() {
  local id="$1" seed="$2" sess="" tag="${SPOOL_BOX_TAG:-}" bin="" out pid user t0 got
  ROTATE_ERR="" ROTATE_NEW_PANE="" ROTATE_NEW_PID=""
  if [[ -n "$ROTATE_OLD_PANE" ]]; then
    spl_rotate_tmux rename-window -t "$ROTATE_OLD_PANE" "$(spl_rotate_retiring_name "$id")" 2>/dev/null ||
      { ROTATE_ERR="tmux refused to rename $ROTATE_OLD_PANE"; return 1; }
    sess="$(spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{session_id}' 2>/dev/null || true)"
    [[ -z "$tag" && "$ROTATE_OLD_NAME" =~ ^$id@([a-z0-9][a-z0-9-]*) ]] && tag="${BASH_REMATCH[1]}"
  fi
  if [[ "$PEER_HARNESS" == claude ]]; then
    bin="${ROTATE_CLAUDE_BIN:-${CLAUDE_BIN:-}}"
    [[ -z "$bin" && -x "$ROTATE_AGENT_HOME/.local/bin/claude" ]] && bin="$ROTATE_AGENT_HOME/.local/bin/claude"
  fi
  out="$(env ${sess:+"SPOOL_SESSION=$sess"} SPAWN_REUSE_ID=1 SPOOL_BOX_TAG="$tag" ${bin:+"CLAUDE_BIN=$bin"} \
    SPAWN_LANE_SCOPE="seat $id (restart $ROTATE_RID)" \
    bash "$ROTATE_SPAWN" "$PEER_HARNESS" "$id" "$(spl_rotate_workdir "$id")" "$seed" peer-restart 2>&1 6>&- 7>&- 8>&- 9>&-)" || true
  ROTATE_NEW_PANE="$(grep -m1 -oE "^$id %[0-9]+" <<<"$out" | cut -d' ' -f2)"
  [[ -n "$ROTATE_NEW_PANE" ]] || { ROTATE_ERR="spawn printed no pane: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  t0=$SECONDS
  while :; do
    for pid in $(spl_peer_pids "$id"); do
      [[ "$pid" != "$ROTATE_OLD_PID" && "$(spl_rotate_pane_of_pid "$pid")" == "$ROTATE_NEW_PANE" ]] && { ROTATE_NEW_PID="$pid"; break 2; }
    done
    (( SECONDS - t0 < PEER_START_WAIT )) || break
    sleep "$ROTATE_POLL"
  done
  [[ -n "$ROTATE_NEW_PID" ]] || { ROTATE_ERR="no $PEER_HARNESS session carrying $id started in $ROTATE_NEW_PANE within ${PEER_START_WAIT}s"; return 1; }
  user="$(spl_rotate_user "$ROTATE_NEW_PID")"
  if [[ -n "${SPOOL_AGENT_USER:-}" && "$user" != "$SPOOL_AGENT_USER" ]]; then
    ROTATE_ERR="the new session runs as '$user', not the agent user $SPOOL_AGENT_USER"; return 1
  fi
  spl_rotate_ai adopt "$id" "$ROTATE_NEW_PID" >/dev/null 2>&1 || true
  got="$(spl_rotate_ai pane-of "$id" 2>/dev/null || true)"
  [[ "$got" == "$ROTATE_NEW_PANE" ]] ||
    { ROTATE_ERR="the identity map routes $id to '${got:-nothing}', not the new pane $ROTATE_NEW_PANE"; return 1; }
  return 0
}

# ---- the seed (spec 068 6.1) ---------------------------------------------------------

# "fresh" when <id>'s distilled.md was written after its last distill poke,
# else why not.
spl_peer_distill_state() {
  local d="$SPOOL_ROOT/$1/handoff" poked
  poked="$(cat "$d/distill.poked" 2>/dev/null || true)"
  [[ "$poked" =~ ^[0-9]+$ ]] || { echo "no distill poke"; return 0; }
  [[ -f "$d/distilled.md" ]] || { echo "no distilled.md"; return 0; }
  (( $(stat -c %Y "$d/distilled.md") >= poked )) || { echo "distilled.md older than the poke"; return 0; }
  echo fresh
}

# spl_peer_cap FILE: the file, verbatim, when it is within
# PEER_DISTILL_MAX_LINES and PEER_DISTILL_MAX_BYTES; longer, its whole lines
# up to the cap and a "[cut]" line, all of it inside both caps.
spl_peer_cap() {
  local f="$1" body
  if (( $(wc -l < "$f") <= PEER_DISTILL_MAX_LINES && $(wc -c < "$f") <= PEER_DISTILL_MAX_BYTES )); then
    cat "$f"; [[ -z "$(tail -c1 "$f")" ]] || echo
    return 0
  fi
  # "[cut]\n" is 6 bytes and the body's own last newline 1
  body="$(head -c "$((PEER_DISTILL_MAX_BYTES - 7))" <(head -n "$((PEER_DISTILL_MAX_LINES - 1))" "$f"))"
  # a line the byte cap split is dropped whole
  [[ -z "$(head -c "$((PEER_DISTILL_MAX_BYTES - 7))" <(head -n "$((PEER_DISTILL_MAX_LINES - 1))" "$f") | tail -c1)" ]] ||
    body="$(sed '$d' <<<"$body")"
  [[ -n "$body" ]] && printf '%s\n' "$body"
  echo "[cut]"
}

# spl_peer_seed ID RID HANDOFF OUT: the fresh session's brief: the seat, its
# own summary (when fresh, between the distilled markers), the handoff. A
# consumed distilled.md is renamed distilled.<rid>.md.
spl_peer_seed() {
  local id="$1" rid="$2" hand="$3" out="$4" d="$SPOOL_ROOT/$1/handoff" st app spec
  app="$(basename "$PROJ_PATH")"; app="${app%-orc}"
  spec="$(cd "$PROJ_PATH/.." && pwd)/$app-doc/specs/068-peer-seats/spec.md"
  st="$(spl_peer_distill_state "$id")"
  {
    echo "# Brief: you are the OD $id@$PEER_BOX (seat restart $rid)"
    echo
    echo "You are the fresh session of seat $id@$PEER_BOX, started by the quarter-hour"
    echo "seat restart (spec 068 section 6.1): same id, same inbox, and the messages the"
    echo "seat holds (the hub names the SEAT as responsible, not the session). Your poll"
    echo "loop is restarted for you. Do not greet; post nothing about the restart."
    echo
    echo "1. Your role: $spec sections 2, 4 and 5."
    echo "2. Read section A (your previous session's own summary), then section B."
    echo "3. Then drain your inbox: SPOOL_ROOT=$SPOOL_ROOT spool recv --as $id"
    echo
    if [[ "$st" == fresh ]]; then
      echo "## A. Your own summary (distilled.md, verbatim)"
      echo "<!-- distilled:begin -->"
      spl_peer_cap "$d/distilled.md"
      echo "<!-- distilled:end -->"
    else
      echo "## A. Your own summary: none ($st)"
    fi
    echo
    echo "## B. The mechanical handoff"
    echo
    cat "$hand"
  } > "$out"
  if [[ "$st" == fresh ]]; then
    mv -f "$d/distilled.md" "$d/distilled.$rid.md" 2>/dev/null || true
    spl_peer_rlog "$rid" SEED OK "$out: the distilled summary + the handoff"
  else
    spl_peer_rlog "$rid" SEED WARN "distill-missing $id ($st): $out holds the mechanical handoff alone"
  fi
}
