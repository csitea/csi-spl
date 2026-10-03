#!/bin/bash
#------------------------------------------------------------------------------
# @description The one-line START of this machine (spec 064 L9), the way back
# @description from do_spl_box_leave: spawns are taken here again (the
# @description box.leave marker goes), the LEASE_PRIORITY* lines the leave
# @description changed are put back as they were, and the lease loop is
# @description replaced on them (LEASE_CMD=ensure) - so this machine re-enters
# @description the ranking as lease.conf says, and takes a role back by
# @description priority on the loop's next tick when it ranks first. Ends with
# @description one status line. Idempotent: on a machine that never left it
# @description changes nothing. DRY_RUN=1 prints what it WOULD do.
# @param DRY_RUN (optional) - 1 = print what it would do, change nothing; default 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param LEASE_MACHINE (optional) - this machine's box (else lease.conf, else its desk box id)
# @example ./run -a do_spl_box_join
# @example DRY_RUN=1 ./run -a do_spl_box_join
#------------------------------------------------------------------------------
declare -F spl_box_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-leave.func.sh"

do_spl_box_join() {
  spl_box_init || return 1
  local dry="${DRY_RUN:-0}" w="WOULD " k rank=""
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 1; }
  [[ "$dry" == 0 ]] && w=""
  if [[ -e "$SPL_BOX_MARK" ]]; then
    echo "1. spawns: ${w}take agents here again (remove $SPL_BOX_MARK)"
    [[ "$dry" == 0 ]] && { rm -f "$SPL_BOX_MARK" || { do_log "FATAL cannot remove $SPL_BOX_MARK"; return 1; }; }
  else
    echo "1. spawns: already taken here"
  fi
  spl_box_rank join "$dry" || return 1
  [[ "$dry" == 0 ]] && rm -f "$SPL_BOX_STATE"/noted.* 2>/dev/null
  for k in ORCH DISPATCH; do
    local v; v="$(spl_box_conf_get "LEASE_PRIORITY_$k")"; [[ -n "$v" ]] || v="$(spl_box_conf_get LEASE_PRIORITY)"
    [[ -n "$v" ]] && rank+=" ${k,,} $(( $(spl_fleet_rank_of "$SPL_BOX_ME" "$v") + 1 ))/$(tr ',' '\n' <<<"$v" | grep -c .)"
  done
  if [[ "$dry" == 1 ]]; then
    echo "DRY_RUN=1: nothing changed; $SPL_BOX_ME $([[ -e "$SPL_BOX_MARK" ]] && echo "is draining now" || echo "takes agents now")"
    return 0
  fi
  echo "JOINED: $SPL_BOX_ME takes agents again${rank:+; lease rank$rank}"
}

# The 0-based position of <box> in the comma list <ranking>.
spl_fleet_rank_of() {
  local i=0 m
  IFS=, read -ra _rk <<<"$2"
  for m in "${_rk[@]}"; do [[ "$m" == "$1" ]] && { echo "$i"; return; }; i=$((i + 1)); done
  echo "$i"
}
