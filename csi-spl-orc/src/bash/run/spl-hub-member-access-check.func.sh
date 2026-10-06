#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: print one member's access_until and whether the
# @description access has ended (at or past access_until, as the hub's door
# @description decides), from the member list (do_spl_hub_member_list).
# @description Exit 0 when the access HAS ended, 1 when it has not (no end, or
# @description an end still ahead), 2 when the member could not be read.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param MEMBER_EMAIL - the member's email; or HUMAN_ID (e.g. HUM-4), not both
# @example ENV=prd TENANT_ID=<tenant> HUMAN_ID=HUM-4 ./run -a do_spl_hub_member_access_check
#------------------------------------------------------------------------------
do_spl_hub_member_access_check() {
  do_require_bin jq || return 2
  local tenant="${TENANT_ID:-}" email human row
  _spl_hub_member_target || return 2
  row="$(_spl_hub_member_row "$tenant" "$email" "$human")" || return 2
  jq -c '{tenant_id, human_id, role, access_until, access_ended}' <<<"$row"
  human="$(jq -r .human_id <<<"$row")"
  if [[ "$(jq -r '.access_ended' <<<"$row")" == true ]]; then
    do_log "OK the access of $human in $tenant HAS ENDED (access_until $(jq -r .access_until <<<"$row")): the hub refuses this member (403)"
    return 0
  fi
  do_log "WARN the access of $human in $tenant has NOT ended (access_until $(jq -r '.access_until // "none"' <<<"$row"))"
  return 1
}
