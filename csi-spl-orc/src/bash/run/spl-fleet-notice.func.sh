#!/bin/bash
#------------------------------------------------------------------------------
# @description Post one automatic fleet notice (an orchestrator failover, a
# @description failed or recovered rotation) as a new topic in the fleet's ops
# @description channel, never as a DM to a person (SPL-2584, owner HUM-10 t1
# @description 4b49e47d msgs 6c089b4a, 8b351386; how-to-post.md rule 18).
# @description The channel is cnf env.fleet_notices.channel, read through
# @description do_spl_desk_cnf; an unset key is a FATAL, never a fallback DM.
# @description The post itself is do_spl_desk_post (its go-ask and **Live**
# @description guards apply). FLEET_NOTICE_CMD replaces the post (tests): it
# @description gets the channel and the kind as arguments, the body on stdin.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the posting agent id (a member of the channel)
# @param DESK_BODY - required: the notice text
# @param DESK_BOX (optional) - default this machine's desk box
# @param DESK_KIND (optional) - note (default) | blocker
# @param FLEET_NOTICE_CMD (optional) - replaces the post (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=g-001 DESK_BODY='Orchestrator failover: ...' DRY_RUN=0 ./run -a do_spl_fleet_notice
#------------------------------------------------------------------------------
do_spl_fleet_notice() {
  do_require_bin yq || return 1
  local kind="${DESK_KIND:-note}" chan
  [[ -n "${DESK_BODY:-}" ]] || { do_log "FATAL DESK_BODY must carry the notice text"; return 1; }
  [[ "$kind" =~ ^(note|blocker)$ ]] || { do_log "FATAL DESK_KIND must be note or blocker, got: '$kind'"; return 1; }
  do_spl_desk_cnf || return 1
  chan="$(yq -r '.env.fleet_notices.channel // ""' "$SPL_CNF")"
  [[ "$chan" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] ||
    { do_log "FATAL env.fleet_notices.channel is not set in the $ENV cnf ($SPL_CNF): the notice is not sent (never as a DM, how-to-post.md rule 18)"; return 1; }
  if [[ -n "${FLEET_NOTICE_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $FLEET_NOTICE_CMD "$chan" "$kind" <<<"$DESK_BODY" || { do_log "FATAL FLEET_NOTICE_CMD failed"; return 1; }
    do_log "OK fleet notice posted into #$chan (FLEET_NOTICE_CMD)"; return 0
  fi
  DESK_CHANNEL="$chan" DESK_KIND="$kind" DESK_BODY_FILE='' do_spl_desk_post
}
