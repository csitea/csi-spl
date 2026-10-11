#!/bin/bash
#------------------------------------------------------------------------------
# @description Start the login proof of spec 132 (sections 3 and 4) on the
# @description refresher box, in ONE step: after a person ran /login on every
# @description peer box (each peer then holds its own credential), empty
# @description SPOOL_LOGIN_PEERS here and record the proof start, under the
# @description login check's tick lock, so no tick of this box can push its
# @description credential over a peer's between the two. It writes
# @description <state>/proof.start ("<UTC> peers-before=<list>") and a
# @description credential sample at that time in <state>/cred.log, then
# @description prints the proof command for this box and for each peer.
# @description It never runs /login and never copies a credential. Refused
# @description while a peer is unreachable or still holds this box's
# @description credential (the same sha prefix: no /login there yet).
# @description Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LOGIN_STATE_DIR (optional) - default /var/csi/csi-spl/agent-login-check
# @param LOGIN_NOW (optional) - the clock, epoch (tests)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_login_proof_start
# @example DRY_RUN=0 ./run -a do_spl_agent_login_proof_start
#------------------------------------------------------------------------------
do_spl_agent_login_proof_start() {
  local dry="${DRY_RUN:-1}" now="${LOGIN_NOW:-$(date +%s)}" state p tag dest here hsha hexp psha bad=0 peers utc
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 2; }
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then
    source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
    spool_test_guard || return 96
  fi
  state="${LOGIN_STATE_DIR:-/var/csi/csi-spl/agent-login-check}"
  LC_CRED="${LOGIN_CRED_CMD:-bash $PROJ_PATH/src/bash/scripts/agent-login-cred.sh}"
  # the file's peers, never a LOGIN_PEERS override: the file is what the tick reads
  peers="$(unset LOGIN_PEERS; _lc_peer_list | xargs)"
  [[ -n "$peers" ]] || { echo "login-proof-start: REFUSED SPOOL_LOGIN_PEERS is already empty here: this is no refresher box (a proof already started? see $state/proof.start)"; return 2; }
  here="$($LC_CRED stat 2>/dev/null | sed -n 1p)"; hsha="${here%% *}"
  [[ "$hsha" =~ ^[0-9a-f]{12}$ ]] || { echo "login-proof-start: REFUSED no credential on this box"; return 2; }
  echo "login-proof-start: here $hsha; peers: $peers"
  for p in $peers; do
    tag="${p%%=*}"; dest="${p#*=}"
    psha="$(_lc_cred_at "$dest" stat 2>/dev/null | sed -n 1p | cut -d' ' -f1)"
    if [[ ! "$psha" =~ ^[0-9a-f]{12}$ ]]; then echo "  $tag: no credential to read (unreachable?)"; bad=1
    elif [[ "$psha" == "$hsha" ]]; then echo "  $tag: $psha, the same as here: no /login on $tag yet"; bad=1
    else echo "  $tag: $psha, its own login"; fi
  done
  (( bad == 0 )) || { echo "login-proof-start: REFUSED a person runs /login on each peer box first (spec 132 section 4)"; return 2; }
  utc="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$dry" == 1 ]]; then
    echo "PLAN under $state/tick.lock: SPOOL_LOGIN_PEERS= in box.env, then $state/proof.start = $utc (DRY_RUN)"
    _lps_commands "<the start time>" "$peers"; return 0
  fi
  mkdir -p "$state" || return 1
  exec 8>>"$state/tick.lock" || return 1
  flock -w "${LOGIN_PROOF_LOCK_WAIT:-120}" 8 || { echo "login-proof-start: FAILED the login check holds $state/tick.lock"; exec 8>&-; return 1; }
  if ! SPOOL_ROOT="$SPOOL_ROOT" bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/box-config.sh" SPOOL_LOGIN_PEERS= >/dev/null ||
     [[ -n "$(unset LOGIN_PEERS; _lc_peer_list | xargs)" ]]; then
    echo "login-proof-start: FAILED SPOOL_LOGIN_PEERS is not empty after the edit"; exec 8>&-; return 1
  fi
  printf '%s peers-before=%s\n' "$utc" "${peers// /,}" >"$state/proof.start"
  read -r hsha hexp _ <<<"$here"
  printf '%s %s %s peers=0\n' "$utc" "$hsha" "$hexp" >>"$state/cred.log"
  exec 8>&-
  echo "login-proof-start: STARTED $utc; SPOOL_LOGIN_PEERS emptied (was $peers)"
  _lps_commands "$utc" "$peers"
}

# The proof command for this box and for each peer (which reads its own logs).
_lps_commands() {
  local utc="$1" p
  echo "  proof here:   cd csi-spl-orc && ./run -a do_spl_agent_login_proof"
  for p in $2; do echo "  proof on ${p%%=*}: cd csi-spl-orc && LOGIN_PROOF_START=$utc ./run -a do_spl_agent_login_proof"; done
}
