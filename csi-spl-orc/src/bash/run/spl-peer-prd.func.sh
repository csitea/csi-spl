#!/bin/bash
#------------------------------------------------------------------------------
# @description The prd wrapper of the OD seats (spec 068 section 5, lane L5):
# @description runs ONE pre-approved prd action (a deploy, a prd desk or issue
# @description write) only after the gate (do_spl_peer_gate) gave this seat
# @description the mutex prd-<target> and its fence still holds. Two seats
# @description running the same target race no more: the second is refused
# @description (exit 5) until the first one's mutex runs out; a seat that lost
# @description the message while it was thinking stops (exit 3 / 4) and the
# @description action never starts.
# @description With no <spool root>/peer/seats (order A) the gate is a no-op
# @description and this is exactly `ENV=prd ./run -a <action>`.
# @param PRD_ACTION - required: the ./run action, do_<name>
# @param PRD_TARGET (optional) - the mutex target, default <name> in kebab case (the role is prd-<target>, up to 32)
# @param PRD_ENV (optional) - the ENV the action runs under, default prd
# @param PEER_SEAT / PEER_MSG / PEER_GEN - the seat and the message it acts for (do_spl_peer_gate)
# @example PRD_ACTION=do_spl_desk_up PEER_SEAT=c-002 PEER_MSG=<msg id> PEER_GEN=3 ./run -a do_spl_peer_prd
#------------------------------------------------------------------------------
declare -F spl_peer_gate >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-gate.func.sh"

do_spl_peer_prd() {
  local act="${PRD_ACTION:-}" target rc=0
  [[ "$act" =~ ^do_[a-z0-9_]+$ ]] || { do_log "FATAL PRD_ACTION must name a ./run action (do_<name>), got: '$act'"; return 1; }
  [[ "$act" != do_spl_peer_prd ]] || { do_log "FATAL PRD_ACTION cannot be the wrapper itself"; return 1; }
  declare -F "$act" >/dev/null || { do_log "FATAL no action $act"; return 1; }
  target="${PRD_TARGET:-$(tr _ - <<<"${act#do_}")}"
  [[ "$target" =~ ^[a-z0-9][a-z0-9-]{0,27}$ ]] ||
    { do_log "FATAL prd target '$target' is no slug of up to 28: set PRD_TARGET"; return 1; }
  spl_peer_gate "prd-$target" || { rc=$?; do_log "ERROR $act refused by the gate (exit $rc): not run"; return "$rc"; }
  do_log "INFO prd-$target: running $act (ENV=${PRD_ENV:-prd})"
  ( export ENV="${PRD_ENV:-prd}"; "$act" )
}
