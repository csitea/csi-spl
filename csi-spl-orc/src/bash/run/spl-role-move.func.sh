#!/bin/bash
#------------------------------------------------------------------------------
# @description Move the orch or the dispatch role of the fleet lease to a named
# @description box (SPL-2643; owner HUM-10, csitea 1be68c11 msgs f1fd503c and
# @description 9c88c2ef). It writes the hub pin row (fleet, "pin-<role>"),
# @description holder "<seat>@<box>", that every box's fleet loop reads
# @description (spl_fleet_pin in spl-dispatch-lease.func.sh): every box then
# @description ranks that box first for the role, and the role moves by the
# @description loops' own handback (LEASE_HOLDDOWN, then one LEASE_PERIOD before
# @description the new seat is told ACTIVE). No lease file is edited, and the
# @description per-box ranking (do_spl_lease_rank) stays as it is.
# @description It fails fast, one line, before writing: an unknown box (in no
# @description ranking of the role), a box the hub's beats judge degraded,
# @description recovering or not at all (no live box, LEASE_HEALTH=0 skips it),
# @description or, for this machine, no seat of the role able to act. Then it
# @description waits until the hub row is held and renewed from the target
# @description box; past ROLE_MOVE_WAIT it undoes the pin and fails: the
# @description target's seat could not take it (not able, a worse vendor than
# @description the holder's, or its loop runs code without pins).
# @description The pin sticks against every ranking until it is older than
# @description LEASE_PIN_TTL on the hub's clock (default 86400 s, 0 = never)
# @description or is undone: TO_BOX=none. A target that fails goes stale and the
# @description role fails over as before; the pin brings it back when it is able.
# @description Dry run by default: the checks run, nothing is written.
# @param ROLE - orch or dispatch
# @param TO_BOX - the box to move the role to (a desk box id, e.g. sat), or none to undo the pin
# @param DRY_RUN (optional) - 0 writes the pin and waits; default 1
# @param ROLE_MOVE_WAIT (optional) - seconds to wait for the target box to hold the role, default LEASE_HOLDDOWN + LEASE_PIN_READ + 3 LEASE_PERIOD
# @param ROLE_MOVE_POLL (optional) - seconds between two hub reads while waiting, default 15
# @example ROLE=orch TO_BOX=sat ./run -a do_spl_role_move
# @example ROLE=orch TO_BOX=sat DRY_RUN=0 ./run -a do_spl_role_move
# @example ROLE=orch TO_BOX=none DRY_RUN=0 ./run -a do_spl_role_move
#------------------------------------------------------------------------------
declare -F spl_fleet_pin >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

do_spl_role_move() {
  local role="${ROLE:-}" to="${TO_BOX:-}" dry="${DRY_RUN:-1}" seat out
  [[ "$role" == orch || "$role" == dispatch ]] || { do_log "FATAL ROLE must be orch or dispatch, got '$role'"; return 1; }
  [[ "$to" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TO_BOX must be a box id (e.g. sat) or none, got '$to'"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_lease_init ro || return 1
  [[ -f "$LEASE_CONF" ]] || { do_log "FATAL no $LEASE_CONF - this box runs no lease (do_spl_dispatch_setup first)"; return 1; }
  spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init || return 1
  seat="$LEASE_ORCH"; [[ "$role" == dispatch ]] && seat="$LEASE_MASTER"
  [[ "$to" == none ]] && { spl_role_move_undo "$role" "$seat" "$dry"; return; }
  spl_role_move_check "$role" "$to" || return 1
  out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" && spl_fleet_read "$out" ||
    { do_log "FATAL the hub did not answer the $role lease read: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  if [[ "$dry" == 1 ]]; then
    echo "PLAN pin $role to $seat@$to (holder now ${FH:-none}); every box ranks $to first for $role until undone or LEASE_PIN_TTL ${LEASE_PIN_TTL:-86400}s (dry run)"
    echo "RUN ROLE=$role TO_BOX=$to DRY_RUN=0 ./run -a do_spl_role_move"
    return 0
  fi
  spl_role_move_pin "$role" "$seat@$to" || return 1
  spl_lease_log "MOVE $role: pinned to $seat@$to by do_spl_role_move (holder was ${FH:-none})"
  spl_role_move_wait "$role" "$to" && return 0
  spl_role_move_pin "$role" "$seat@none" >/dev/null &&
    spl_lease_log "MOVE $role: $to did not take it; pin undone"
  return 1
}

# spl_role_move_check <role> <box>: 0 when the box may take the role; else
# one FATAL line.
spl_role_move_check() {
  local role="$1" to="$2" k st why
  k="LEASE_PRIORITY_${role^^}"
  [[ ",${!k:-$LEASE_PRIORITY},${LEASE_PRIORITY}," == *",$to,"* ]] ||
    { do_log "FATAL $to is in no ranking of $role (${!k:-$LEASE_PRIORITY}): not a box of fleet $LEASE_FLEET"; return 1; }
  if [[ "${LEASE_HEALTH:-1}" != 0 ]]; then
    st="$(spl_fleet_health_get | jq -r --arg b "$to" '.[$b] | if . == null then "unjudged: no beats from it" else "\(.state): \(.why // "")" end' 2>/dev/null)"
    [[ "$st" == healthy:* ]] || { do_log "FATAL $to is not a live box for $role (hub beats: ${st:-unread})"; return 1; }
  fi
  if [[ "$to" == "$LEASE_MACHINE" ]]; then
    [[ -n "$(spl_fleet_candidate "$role")" ]] ||
      { why="$(spl_fleet_why "$role")"; do_log "FATAL no $role seat on $to can act (${why:-no seat})"; return 1; }
  fi
  return 0
}

# spl_role_move_pin <role> <holder>: compare-and-set the pin row to <holder>.
spl_role_move_pin() {
  local role="$1" holder="$2" out FH FG FA FW
  out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "pin-$role" 2>&1)" && spl_fleet_read "$out" &&
    out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "pin-$role" --holder "$holder" --if-gen "$FG" 2>&1)" &&
    spl_fleet_read "$out" && [[ "$FW" == true ]] ||
    { do_log "FATAL the pin-$role write to $holder did not land: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  echo "PIN $role -> $holder (gen $FG)"
}

# spl_role_move_undo <role> <seat> <dry>: write the pin to box none.
spl_role_move_undo() {
  local role="$1" seat="$2" dry="$3" out FH FG FA FW
  out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "pin-$role" 2>&1)" && spl_fleet_read "$out" ||
    { do_log "FATAL the hub did not answer the pin-$role read: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  [[ "$FH" == *@* && "${FH##*@}" != none ]] || { echo "OK $role is pinned to no box"; return 0; }
  [[ "$dry" == 1 ]] && { echo "PLAN unpin $role (pinned to $FH): the rankings decide again (dry run)"; return 0; }
  spl_role_move_pin "$role" "$seat@none" || return 1
  spl_lease_log "MOVE $role: pin $FH undone by do_spl_role_move; the rankings decide again"
  echo "DONE $role unpinned: the box ranked first takes it back after LEASE_HOLDDOWN"
}

# spl_role_move_wait <role> <box>: 0 once the hub row is held from <box> and
# renewed again at least one LEASE_PERIOD later (the loop there tells its
# seat ACTIVE one LEASE_PERIOD after its win); 1 past ROLE_MOVE_WAIT.
spl_role_move_wait() {
  # shellcheck disable=SC2034 # FA, FW: set by spl_fleet_read
  local role="$1" to="$2" poll="${ROLE_MOVE_POLL:-15}" wait n=0 tries need first="" out FH FG FA FW
  wait="${ROLE_MOVE_WAIT:-$(( ${LEASE_HOLDDOWN:-300} + ${LEASE_PIN_READ:-60} + 3 * LEASE_PERIOD ))}"
  [[ "$poll" =~ ^[1-9][0-9]*$ && "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL ROLE_MOVE_POLL and ROLE_MOVE_WAIT must be seconds"; return 1; }
  tries=$(( (wait + poll - 1) / poll )) need=$(( (LEASE_PERIOD + poll - 1) / poll ))
  while (( n < tries )); do
    "${ROLE_MOVE_SLEEP:-sleep}" "$poll"; n=$((n + 1))
    out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" && spl_fleet_read "$out" || continue
    if [[ "${FH##*@}" != "$to" ]]; then first=""; continue; fi
    [[ -z "$first" ]] && { first="$n $FG"; continue; }
    if (( n - ${first% *} >= need && FG > ${first#* } )); then
      echo "DONE $role held by $FH on the hub, renewed (gen ${first#* } -> $FG): the loop on $to told its seat ACTIVE"
      return 0
    fi
  done
  do_log "FATAL $to did not take $role in ${wait}s (hub holder ${FH:-unread}): its seat is not able, ranks below the holder's vendor, or its loop runs code without pins; the pin is undone"
  return 1
}
