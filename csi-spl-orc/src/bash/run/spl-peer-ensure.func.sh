#!/bin/bash
#------------------------------------------------------------------------------
# @description Start the missing poll loop of every OD seat of this machine
# @description (spec 068 section 6.1, the `* * * * *` peer-ensure cron: the
# @description reboot path), and replace a loop whose code or seat list has
# @description changed. Nothing else. No <spool root>/peer/seats = no seat =
# @description nothing to start (inert until the seat setup, L7).
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param PEER_RUN (optional) - the ./run that starts a loop (tests)
# @example ./run -a do_spl_peer_ensure
#------------------------------------------------------------------------------
declare -F spl_peer_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-poll.func.sh"

do_spl_peer_ensure() {
  spl_peer_init ro || return 1
  local id d ver
  [[ -n "$(spl_peer_seats)" ]] || { do_log "INFO no seat in $PEER_SEATS - no poll loop to run"; return 0; }
  ver="$(spl_peer_code_ver)"
  while read -r id _; do
    d="$PEER_DIR/$id"
    mkdir -p "$d" || { do_log "FATAL cannot create $d"; return 1; }
    if spl_peer_running "$id"; then
      # a loop that took its lock a moment ago writes its version just after
      [[ "$(cat "$d/poll.ver" 2>/dev/null)" == "$ver" ]] || sleep 1
      if [[ "$(cat "$d/poll.ver" 2>/dev/null)" == "$ver" ]]; then
        do_log "INFO $id poll loop running (pid $(cat "$d/poll.pid" 2>/dev/null))"; continue
      fi
      spl_peer_log "$id ensure replaces the poll loop (code $(cat "$d/poll.ver" 2>/dev/null || echo unknown) -> $ver)"
      spl_peer_stop "$id" || return 1
    fi
    PEER_SEAT="$id" PEER_BOX="$PEER_BOX" spl_lease_detach "$d/poll.out" "${PEER_RUN:-$PROJ_PATH/run}" -a do_spl_peer_poll
    spl_peer_log "$id ensure started the poll loop"
    do_log "INFO $id poll loop started (log $d/poll.out)"
  done < <(spl_peer_seats)
  return 0
}

spl_peer_running() {
  [[ -f "$PEER_DIR/$1/poll.run" ]] || return 1
  ! flock -n "$PEER_DIR/$1/poll.run" true
}

# Stop one seat's loop by its pid file, never by a command-line pattern.
spl_peer_stop() {
  local d="$PEER_DIR/$1" pid
  spl_peer_running "$1" || return 0
  pid="$(cat "$d/poll.pid" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { do_log "FATAL $1 poll runs but $d/poll.pid holds no pid"; return 1; }
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
  for _ in $(seq 1 50); do spl_peer_running "$1" || break; sleep 0.1; done
  spl_peer_running "$1" && { do_log "FATAL $1 poll loop pid $pid did not stop"; return 1; }
  spl_peer_log "$1 poll stop pid=$pid"
}
