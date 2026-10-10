#!/bin/bash
#------------------------------------------------------------------------------
# @description Add a PENDING sign-in email to one human, BY A HUMAN'S ORDER,
# @description THROUGH THE HUB: POST /v1/operator/humans/<human_id>/emails
# @description (human_email_operator.go; owner HUM-10 t1 f265541a msg
# @description 1ee61a2b), authenticated as the env's project service account
# @description (do_gcp_pin_account, a Google id token for the hub URL; never the
# @description owner account). The hub applies the member route's rules
# @description (store/sign_in_emails.go): the address is added PENDING only;
# @description active or pending on another human is 409 email_taken; it turns
# @description ACTIVE only when the human signs in with it at a cloud provider
# @description from their OWN signed-in session (Settings -> Sign-in emails).
# @description A cold sign-in with it does not reach the human. The audit is
# @description added_in operator, added_by "<AGENT_ID> for <ORDERED_BY>".
# @description Both runs print the read-back list, {email, state, providers,
# @description main} per address, from GET /v1/operator/humans/<human_id>/emails.
# @description Every address it prints is MASKED (the first two characters of
# @description the local part, then ***@domain): run.sh tees stdout into the
# @description box's run logs, and an address is personal data. The line of
# @description EMAIL carries requested:true.
# @description DRY_RUN=1 (default): print the body it would send (masked) and
# @description the human's current list (a read), write nothing.
# @param ENV - required: dev or prd
# @param HUMAN_ID - required: the HUM-* id of the human the address goes to
# @param EMAIL - required: the address to add (lower-cased)
# @param ORDERED_BY - required: the HUM-* id of the human who ordered it
# @param AGENT_ID - required: the agent that carries the order, e.g. c-042
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev HUMAN_ID=HUM-4 EMAIL=someone@example.com ORDERED_BY=HUM-10 AGENT_ID=c-042 ./run -a do_spl_human_email_add
# @example ENV=dev HUMAN_ID=HUM-4 EMAIL=someone@example.com ORDERED_BY=HUM-10 AGENT_ID=c-042 DRY_RUN=0 ./run -a do_spl_human_email_add
#------------------------------------------------------------------------------
do_spl_human_email_add() {
  do_require_bin yq jq curl gcloud || return 1
  local body hum="${HUMAN_ID:-}" want="${EMAIL:-}" dry=1
  want="${want,,}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  _spl_human_email_add_body || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( dry )); then
    jq -c --arg m "$(_spl_human_email_mask "$want")" '.email = $m' <<<"$body"
    _spl_human_email_add_list "now" || return 1
    do_log "OK DRY_RUN would POST /v1/operator/humans/$hum/emails to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account, the body above; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_hub_operator_call POST "/v1/operator/humans/$hum/emails" "$body" || return 1
  _spl_human_email_add_status || return 1
  _spl_human_email_add_list "after the add" || return 1
  do_log "OK $hum ($ENV): the address is $(jq -r '.state' <<<"$SPL_HUB_OP_ADD") on $hum, read back through the hub (ordered_by $ORDERED_BY, via $AGENT_ID). It turns active only when $hum signs in with it from Settings -> Sign-in emails while signed in."
}

# _spl_human_email_add_list <when>: GET the human's addresses, print one
# {email, state, providers, main} line each.
_spl_human_email_add_list() {
  spl_hub_operator_call GET "/v1/operator/humans/$hum/emails" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || {
    do_log "FATAL the read-back of $hum ($1) answered http $SPL_HUB_OP_STATUS: $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
    return 1
  }
  do_log "INFO the sign-in emails of $hum ($1):"
  jq -c --arg want "$want" "$_SPL_HUMAN_EMAIL_MASK_JQ"'
    .emails[] | {email: (.email | mask), state, providers, main} + (if .email == $want then {requested: true} else {} end)' <<<"$SPL_HUB_OP_BODY"
}

# The jq mask of an address: the first two characters of the local part, then
# ***@domain.
# shellcheck disable=SC2016 # a jq program, not a shell expansion
_SPL_HUMAN_EMAIL_MASK_JQ='def mask: (split("@")) as $p | ($p[0][0:2]) + "***@" + ($p[1:] | join("@"));'

# _spl_human_email_mask <email>: print the masked address.
_spl_human_email_mask() { jq -rn --arg e "$1" "$_SPL_HUMAN_EMAIL_MASK_JQ"' $e | mask'; }

# _spl_human_email_add_status: map the add's answer to OK or one FATAL.
_spl_human_email_add_status() {
  local detail err
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  err="$(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS:$err" in
    200:*) SPL_HUB_OP_ADD="$SPL_HUB_OP_BODY"; return 0 ;;
    409:email_taken) do_log "FATAL the address is active or pending on ANOTHER human (409 email_taken); there is no merge. Nothing written." ;;
    409:technical) do_log "FATAL $hum is an agent or a clone: it takes no sign-in email (409). Nothing written." ;;
    404:not_found) do_log "FATAL the hub has no human $hum, or no such route (404: $detail): check HUMAN_ID, or deploy a hub with it. Nothing written." ;;
    404:*) do_log "FATAL the hub has no POST /v1/operator/humans/{human_id}/emails, or its operator routes are off (404: $detail): deploy a hub with it. Nothing written." ;;
    401:*|403:*) do_log "FATAL the hub refused the operator call ($SPL_HUB_OP_STATUS): $detail. Is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing written." ;;
    *) do_log "FATAL the address was not added (http $SPL_HUB_OP_STATUS): $detail" ;;
  esac
  return 1
}

# _spl_human_email_add_body: set the caller's local body to the request body
# (compact JSON) from the env vars; every refusal is made here, before cnf,
# gcloud or the hub.
_spl_human_email_add_body() {
  local email="${EMAIL:-}" ordby="${ORDERED_BY:-}" agent="${AGENT_ID:-}"
  email="${email,,}"
  spl_require_cloud_env || return 1
  [[ "$hum" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must be a HUM-* id, got: '$hum'"; return 1; }
  if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || (( ${#email} > 320 )); then
    do_log "FATAL EMAIL must be one address"; return 1
  fi
  [[ "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be the HUM-* id of the human who ordered it, got: '$ordby'"; return 1; }
  [[ "$agent" =~ ^[acgmq]-[0-9]{3}$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  body="$(jq -cn --arg email "$email" --arg agent "$agent" --arg ordby "$ordby" \
      '{email: $email, agent_id: $agent, ordered_by: $ordby}')" \
    || { do_log "FATAL could not build the request body"; return 1; }
}
