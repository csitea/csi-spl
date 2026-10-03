#!/bin/bash
#------------------------------------------------------------------------------
# @description The gate an OD seat passes immediately before an outward action
# @description that needs ONE actor (spec 068 sections 4.2 and 5, lane L5): a
# @description spawn (mutex `spawn`), a prd action (mutex `prd-<target>`), a
# @description fleet config write (mutex `fleet-config`). In order:
# @description   1. fence: the seat still holds the message it acts for
# @description      (L3's spl_peer_fence: 0 mine, 1 lost, 2 unconfirmed)
# @description   2. mutex: a fleet_leases row under role PEER_GATE_ROLE, read
# @description      then compare-and-set to <seat>@<box>; free when it has no
# @description      holder, is this seat's, or is older than PEER_MUTEX_TTL
# @description      (120 s: a dead holder's mutex simply runs out)
# @description   3. fence again, so the check stays next to the action
# @description INERT (exit 0, nothing read or written) while this machine has
# @description no <spool root>/peer/seats (order A: today's single
# @description orchestrator), and for a caller that is no seat (a human
# @description shell, a lane): only a seat has a message to fence on.
# @description The mutex is never released: the hub has no "free" write, so a
# @description second seat waits for the TTL (PEER_MUTEX_WAIT) or retries.
# @description Exit: 0 go, 1 usage / config, 3 fence lost, 4 fence
# @description unconfirmed (never act on it), 5 mutex held by another seat,
# @description 6 mutex unreachable.
# @param PEER_GATE_ROLE - required: spawn, fleet-config or prd-<target>
# @param PEER_SEAT (optional) - the acting seat, default SPOOL_AGENT_ID
# @param PEER_MSG / PEER_GEN - required for a seat: the message it acts for and the responsible_gen it holds
# @param PEER_MUTEX_TTL (optional) - seconds a mutex is held, default 120
# @param PEER_MUTEX_WAIT (optional) - seconds to wait for a held mutex, default 0 (refuse at once)
# @param PEER_GATE_DRY (optional) - 1: fence and READ the mutex, write nothing (a dry run)
# @param LEASE_FLEET / LEASE_TENANT / LEASE_ENV / LEASE_DESK_BOX (optional) - the hub, as for the fleet lease (env or lease.conf)
# @param LEASE_HUB_CMD / PEER_HUB_CMD (optional) - replace the lease / claim hub calls (tests)
# @example PEER_GATE_ROLE=spawn PEER_SEAT=c-002 PEER_MSG=<msg id> PEER_GEN=3 ./run -a do_spl_peer_gate
#------------------------------------------------------------------------------
declare -F spl_peer_fence >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-poll.func.sh"
declare -F spl_fleet_hub >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

do_spl_peer_gate() {
  spl_peer_gate "${PEER_GATE_ROLE:-}"
}

# spl_peer_gate <role>: the whole gate; the wrappers call it in-process.
spl_peer_gate() {
  local role="$1" seat="${PEER_SEAT:-${SPOOL_AGENT_ID:-}}"
  [[ "$role" =~ ^(spawn|fleet-config|prd-[a-z0-9][a-z0-9-]{0,27})$ ]] ||
    { do_log "FATAL PEER_GATE_ROLE must be spawn, fleet-config or prd-<target> (up to 32), got: '$role'"; return 1; }
  spl_peer_init ro || return 1
  [[ -f "$PEER_SEATS" ]] || return 0
  spl_peer_seated "$seat" || { do_log "INFO ${seat:-<no seat>} is no seat in $PEER_SEATS - $role is not gated"; return 0; }
  [[ "${PEER_MSG:-}" =~ ^[A-Za-z0-9-]+$ && "${PEER_GEN:-}" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL seat $seat: PEER_MSG and PEER_GEN are required - a seat acts only for a message it holds"; return 1; }
  PEER_MUTEX_TTL="${PEER_MUTEX_TTL:-120}"; PEER_MUTEX_WAIT="${PEER_MUTEX_WAIT:-0}"
  [[ "$PEER_MUTEX_TTL" =~ ^[1-9][0-9]*$ && "$PEER_MUTEX_WAIT" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL PEER_MUTEX_TTL must be a positive integer and PEER_MUTEX_WAIT a whole number"; return 1; }
  spl_peer_gate_fence "$seat" || return
  spl_peer_mutex "$role" "$seat@$PEER_BOX" || return
  spl_peer_gate_fence "$seat" || return
  [[ "${PEER_GATE_DRY:-0}" == 1 ]] || spl_peer_log "$seat GATE $role go (msg $PEER_MSG gen $PEER_GEN)"
  return 0
}

# The fence in the gate's exit codes: 1 lost -> 3, 2 unconfirmed -> 4.
spl_peer_gate_fence() {
  local rc=0
  spl_peer_fence "$1" "$PEER_MSG" "$PEER_GEN" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) do_log "ERROR $1 lost $PEER_MSG (gen $PEER_GEN): another seat is responsible now - stop"; return 3 ;;
    *) do_log "ERROR $1 cannot confirm $PEER_MSG (gen $PEER_GEN) on the hub - never act on an unconfirmed lock"; return 4 ;;
  esac
}

# spl_peer_mutex <role> <holder>: take the mutex or say who has it. One read,
# one compare-and-set on the gen read (the fleet lease's `lease cas` frame);
# a lost race reads and decides again while PEER_MUTEX_WAIT lasts.
spl_peer_mutex() {
  local role="$1" me="$2" out deadline FH FG FA FW
  spl_lease_init ro || return 1
  spl_lease_conf
  [[ "${LEASE_FLEET:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL LEASE_FLEET is not set (env or $LEASE_CONF)"; return 1; }
  spl_fleet_hub_init || return 6
  deadline=$(( $(spl_lease_now) + PEER_MUTEX_WAIT ))
  while :; do
    if ! out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" || ! spl_fleet_read "$out"; then
      do_log "ERROR mutex $role: hub unreachable: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 6
    fi
    if (( FG == 0 )) || [[ "$FH" == "$me" ]] || (( FA >= PEER_MUTEX_TTL )); then
      [[ "${PEER_GATE_DRY:-0}" == 1 ]] && { do_log "INFO mutex $role is free for $me (dry run: not taken)"; return 0; }
      if ! out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" --holder "$me" --if-gen "$FG" 2>&1)" || ! spl_fleet_read "$out"; then
        do_log "ERROR mutex $role: hub unreachable on the write: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 6
      fi
      [[ "$FW" == true ]] && { spl_peer_log "${me%@*} MUTEX $role taken (gen $FG)"; return 0; }
    fi
    if (( $(spl_lease_now) >= deadline )); then
      do_log "ERROR mutex $role is held by $FH for ${FA}s (free after ${PEER_MUTEX_TTL}s) - not taken"
      return 5
    fi
    sleep "${PEER_MUTEX_POLL:-5}"
  done
}
