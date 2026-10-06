#!/bin/bash
#------------------------------------------------------------------------------
# @description End (or clear) one tenant member's access at a set UTC time,
# @description THROUGH THE HUB: PATCH /v1/operator/members/<human_id>
# @description {tenant, access_until} (rdb 0113, spec 072 A27), authenticated as
# @description the env's project service account (do_gcp_pin_account, a Google
# @description id token for the hub URL; never the owner account), as
# @description do_spl_hub_invite does. At or past access_until the hub answers
# @description 403 to that member, sign-in included; the row stays listed. The
# @description hub applies the same last-owner / last-admin guards as the
# @description admin's PATCH. MEMBER_EMAIL resolves to the human id through the
# @description member list (do_spl_hub_member_list, read-only). Confirm it with
# @description do_spl_hub_member_access_check; schedule that confirmation with
# @description do_spl_hub_member_access_schedule_check. DRY_RUN=1 (default):
# @description print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param MEMBER_EMAIL - the member's email; or HUMAN_ID (e.g. HUM-4), not both
# @param ACCESS_UNTIL - required: RFC 3339 UTC (2026-10-07T06:00:00Z), or
# @param   'clear' for no end
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered it, a HUM-* id
# @param ORDERED_VIA (optional) - the agent or channel that carried the order, at most 64 chars
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<tenant> MEMBER_EMAIL=<email> ACCESS_UNTIL=2026-10-07T06:00:00Z ORDERED_BY=HUM-10 ORDERED_VIA=c-001 DRY_RUN=0 ./run -a do_spl_hub_member_access_until
#------------------------------------------------------------------------------
do_spl_hub_member_access_until() {
  do_require_bin yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  local tenant="${TENANT_ID:-}" until="${ACCESS_UNTIL:-}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" email human dry=1
  _spl_hub_member_target || return 1
  [[ "$until" == clear ]] || _spl_utc_time_ok "$until" || { do_log "FATAL ACCESS_UNTIL must be an RFC 3339 UTC time like 2026-10-07T06:00:00Z, or 'clear', got: '$until'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local what="end the access of ${human:-the member with that email} in $tenant at $until"
  [[ "$until" == clear ]] && what="clear the end of access of ${human:-the member with that email} in $tenant"
  if (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to $what (ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}), as the $SPL_PROJECT service account$([[ -n "$email" ]] && echo ', after resolving the email to a human id through the member list'). Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0"; return 1; }
  if [[ -z "$human" ]]; then
    human="$(_spl_hub_member_row "$tenant" "$email" "" | jq -r .human_id)" || return 1
    [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL the member list gave no human id for that email in $tenant"; return 1; }
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local body
  body="$(jq -cn --arg tenant "$tenant" --arg until "$until" --arg ordered_by "$ordby" --arg ordered_via "$ordvia" '
      {tenant: $tenant, access_until: (if $until == "clear" then null else $until end), ordered_by: $ordered_by}
      + (if $ordered_via != "" then {ordered_via: $ordered_via} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
  spl_hub_operator_call PATCH "/v1/operator/members/$human" "$body" || return 1
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200)
      do_log "OK $tenant member $human: access_until=$(jq -r '.access_until // "none"' <<<"$SPL_HUB_OP_BODY") access_ended=$(jq -r '.access_ended' <<<"$SPL_HUB_OP_BODY") (ordered_by=$ordby${ordvia:+ via $ordvia}, $GCP_ACCOUNT)"
      return 0 ;;
    404)
      if [[ "$SPL_HUB_OP_BODY" == *"not enabled"* ]]; then
        do_log "FATAL the hub operator route is not enabled (404) on $ENV. Nothing changed."
      elif [[ "$SPL_HUB_OP_BODY" == *"no such member"* ]]; then
        do_log "FATAL $human is not a member of $tenant (404). Nothing changed."
      else
        do_log "FATAL the hub has no PATCH /v1/operator/members route yet (404: $detail): deploy a hub with it. Nothing changed."
      fi
      return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    *) do_log "FATAL access_until of $human in $tenant not changed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
}

# _spl_hub_member_target: from MEMBER_EMAIL / HUMAN_ID (exactly one) and
# TENANT_ID, set the caller's locals email (lower-cased) and human.
_spl_hub_member_target() {
  spl_require_tenant_slug "$tenant" || return 1
  email="${MEMBER_EMAIL:-}" human="${HUMAN_ID:-}"
  if [[ -n "$email" && -n "$human" ]] || [[ -z "$email" && -z "$human" ]]; then
    do_log "FATAL set exactly one of MEMBER_EMAIL and HUMAN_ID"; return 1
  fi
  [[ -z "$human" || "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  [[ -z "$email" || "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL MEMBER_EMAIL is not an email"; return 1; }
  email="${email,,}"
}

# _spl_utc_time_ok <t>: t is RFC 3339 UTC to the second (…Z) and a real time.
_spl_utc_time_ok() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && date -u -d "$1" +%s >/dev/null 2>&1
}

# _spl_hub_member_row <tenant> <email> <human_id> -> the one member row of the
# member list (compact JSON) whose email (or human id) matches exactly. Fails
# when the list cannot be read or not exactly one member matches.
_spl_hub_member_row() {
  local tenant="$1" email="$2" human="$3" out rc=0 rows n match=""
  [[ -n "$email" && "$email" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] && match="$email"
  out="$(TENANT_ID="$tenant" MATCH="$match" do_spl_hub_member_list)" || rc=$?
  (( rc == 0 || rc == 2 )) || { do_log "FATAL the member list of $tenant could not be read (exit $rc)"; return 1; }
  rows="$(jq -cR --arg e "$email" --arg h "$human" 'fromjson? | select(.type == "member")
      | select(($e != "" and ((.email // "") | ascii_downcase) == $e) or ($h != "" and .human_id == $h))' <<<"$out")"
  n="$(grep -c . <<<"$rows")"
  (( n == 1 )) || { do_log "FATAL $n member(s) of $tenant match ${human:-that email}: want exactly 1"; return 1; }
  printf '%s\n' "$rows"
}
