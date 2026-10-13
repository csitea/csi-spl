#!/bin/bash
#------------------------------------------------------------------------------
# @description The local private spool-hub's live "nothing public" gate (local
# @description hub swarm, lane L5; do_spl_local_hub_status calls it). It reads
# @description `ss -Hltune` (tcp + udp listeners, with the socket's uid): every
# @description listener of the hub user, and every listener on a local hub
# @description port (cnf env.lde.local_hub) by anyone, must be on 127.0.0.0/8
# @description or ::1; exit 1 otherwise. Runs as any user, no sudo.
# @example ./run -a do_spl_local_hub_ports_gate
#------------------------------------------------------------------------------

# do_spl_local_hub_ports_gate -- nothing public: `ss -Hltune` (tcp + udp, the
# socket's uid), every listener of the hub user and every listener on a local
# hub port (cnf) must be on loopback.
do_spl_local_hub_ports_gate() {
  # _slh_cnf and _slh_loopback live in the harden check's file
  declare -F _slh_cnf >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-local-hub-harden-check.func.sh"
  _slh_cnf || return 1
  local uid net addr port owner line n=0 bad=0
  uid="$(id -u "$LOCAL_HUB_USER" 2>/dev/null)" || uid=-1
  while read -r line; do
    [[ -z "$line" ]] && continue
    read -r net _ _ _ addr _ <<<"$line"
    port="${addr##*:}"; addr="${addr%:*}"
    owner="$(grep -oE '(^| )uid:[0-9]+' <<<"$line" | cut -d: -f2)"
    [[ "$owner" == "$uid" || " $LOCAL_HUB_PORTS " == *" $port "* ]] || continue
    n=$((n + 1))
    _slh_loopback "$addr" || { echo "FAIL  $net $addr:$port is public (uid ${owner:-0})"; bad=1; }
  done < <(ss -Hltune 2>/dev/null)
  if ((bad)); then do_log "FATAL local hub ports gate: a listener is public"; return 1; fi
  do_log "OK local hub ports gate: $n listener(s) of $LOCAL_HUB_USER / ports $LOCAL_HUB_PORTS, all loopback"
}
