#!/bin/bash
#------------------------------------------------------------------------------
# @description Drop a retired agent id's channel seats on every workspace desk
# @description of THIS box (spec 061 3.6, SPL-6714). Agent ids are reused
# @description after the quarantine, and a seat a member gave the id
# @description (channel_subscriptions origin 'invite') outlived it, so the next
# @description holder inherited every channel the old one was invited to. Per
# @description desk <state>/<env>/desk/<tenant>/<box> it runs
# @description `spool agent-invites-drop --agent <id>`, signed by that desk's
# @description own key: the hub marks the seats of the id on THAT box removed
# @description in that workspace (lane_op agent_invites_drop); it refuses any
# @description other box. Channel history and agent_seats stay.
# @description agent-id-retire.sh runs it (step 4) as the desk user.
# @description Dry run unless DRY_RUN=0: one PLAN line per desk.
# @param DROP_AGENT_ID (required) - the retired agent id, e.g. c-873
# @param DESK_BOX (optional) - the desk box id, default spl_desk_box_default
# @param DESK_ENVS (optional) - default "dev prd"
# @param DESK_TENANT (optional) - one workspace only, default every desk of the box
# @param DESK_STATE_ROOT (optional) - the desks' state root (<root>/<env>/desk/...), default each env's SPL_STATE_DIR
# @param DROP_HUB_CMD (optional, tests) - replaces the hub call: gets `agent-invites-drop --agent <id>`, with DROP_ENV / DROP_TENANT / DROP_DESK_DIR set
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DROP_AGENT_ID=c-873 ./run -a do_spl_agent_invites_drop
# @example DROP_AGENT_ID=c-873 DESK_ENVS=dev DRY_RUN=0 ./run -a do_spl_agent_invites_drop
#------------------------------------------------------------------------------
do_spl_agent_invites_drop() {
  local id="${DROP_AGENT_ID:-}" box="${DESK_BOX:-}" e rc=0 dry=1
  [[ "$id" =~ ^[a-z]-[0-9]{3}$ || "$id" =~ ^(CLE|GRK|AGY|QWN)-[0-9]+$ ]] ||
    { do_log "FATAL DROP_AGENT_ID must be an agent id (c-873), got: '$id'"; return 1; }
  [[ -n "$box" ]] || box="$(spl_desk_box_default)"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL DESK_BOX must be one box id, got: '$box'"; return 1; }
  [[ -z "${DESK_TENANT:-}" ]] || spl_require_tenant_slug "$DESK_TENANT" || return 1
  spl_dry_run || { (($? == 2)) && return 1; dry=0; }
  for e in ${DESK_ENVS:-dev prd}; do
    spl_require_cloud_env "$e" || return 1
    ( _spl_aid_env "$e" "$box" "$id" "$dry" ) || rc=2
  done
  return "$rc"
}

# _spl_aid_env <env> <box> <id> <dry>: every desk of <box> in one env. The
# hub URL and the spool binary come as do_spl_desk_up resolves them, unless
# DROP_HUB_CMD stands in for the hub. 2 when a desk's drop failed.
_spl_aid_env() {
  local env="$1" box="$2" id="$3" dry="$4" root d t rc=0
  export ENV="$env"
  if [[ -z "${DROP_HUB_CMD:-}" ]]; then
    if ! TENANT_ID="${DESK_TENANT:-${TENANT_ID:-}}" do_spl_desk_cnf || ! spl_host_spool; then
      do_log "WARN $env: no hub URL or spool binary; the invites of $id on $box were not dropped there"; return 2
    fi
  fi
  root="${DESK_STATE_ROOT:+$DESK_STATE_ROOT/$env}"
  root="${root:-${SPL_STATE_DIR:-}}"
  [[ -n "$root" && -d "$root/desk" ]] || { do_log "INFO $env: no desk under ${root:-?}"; return 0; }
  for d in "$root"/desk/${DESK_TENANT:-*}/"$box"; do
    [[ -d "$d/keys" ]] || continue
    t="${d%/*}"; t="${t##*/}"
    if ((dry)); then do_log "PLAN invites $env/$t/$box drop $id"; continue; fi
    _spl_aid_desk "$env" "$t" "$box" "$id" "$d" || rc=2
  done
  return "$rc"
}

# _spl_aid_desk <env> <tenant> <box> <id> <desk dir>: one desk's drop.
_spl_aid_desk() {
  local out chs
  if [[ -n "${DROP_HUB_CMD:-}" ]]; then
    out="$(DROP_ENV="$1" DROP_TENANT="$2" DROP_DESK_DIR="$5" "$DROP_HUB_CMD" agent-invites-drop --agent "$4" 2>&1)"
  else
    out="$(timeout -k 1 "${DROP_TIMEOUT:-30}" env SPOOL_ROOT="$5/spool" SPOOL_KEYS_DIR="$5/keys" SPOOL_BOX_ID="$3" \
      SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$2" "$SPL_SPOOL" agent-invites-drop --agent "$4" 2>&1 </dev/null)"
  fi || { do_log "WARN invites $1/$2/$3 $4 not dropped: $(tail -n 1 <<<"$out")"; return 2; }
  chs="$(grep -m 1 '^{' <<<"$out" | jq -r '(.channels // empty) | join(",")' 2>/dev/null)" ||
    { do_log "WARN invites $1/$2/$3 $4: the hub answer is not JSON: $(tail -n 1 <<<"$out")"; return 2; }
  do_log "DO invites $1/$2/$3 drop $4 -> removed from: ${chs:-none}"
}
