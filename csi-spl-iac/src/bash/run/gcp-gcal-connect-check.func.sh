#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 149: check, per env, the Google side of the Calendar
# @description connect, and do the one part Google lets a script do. The
# @description steps and their sources: csi-spl-doc/doc/md/isg/google-calendar-connect.ISG.md.
# @description   1. Calendar API (calendar-json.googleapis.com) on the project:
# @description      SCRIPTED. Listed with gcloud services; terraform step 001
# @description      enables it from the cnf list, and DRY_RUN=0 enables it here
# @description      with gcloud services enable (the same idempotent call).
# @description   2. S3, the redirect URI on the sign-in OAuth client: CHECKED,
# @description      not set. No API sets it; Google's public authorize endpoint
# @description      (cnf env.gcal.auth_url) answers redirect_uri_mismatch for a
# @description      URI the client does not list, so the check needs no account.
# @description   3. S2 (consent-screen scope, test users) and the branding:
# @description      CONSOLE ONLY, no public API. Printed as MANUAL lines.
# @description The per-env project SA only (do_gcp_pin_account), --account on
# @description every gcloud call; the client id is never printed.
# @description Returns 0 when every scripted check holds, 3 when one does not,
# @description 1 on an error (bad input, no cnf value, no account).
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): read and report. 0: also enable the API.
# @example ENV=dev ./run -a do_gcp_gcal_connect_check
# @example ENV=prd DRY_RUN=0 ./run -a do_gcp_gcal_connect_check
#------------------------------------------------------------------------------
GCAL_API=calendar-json.googleapis.com
GCAL_SCOPE=https://www.googleapis.com/auth/calendar.app.created
GCAL_CALLBACK_PATH=/v1/me/google-calendar/callback

do_gcp_gcal_connect_check() {
  local dry_run="${DRY_RUN:-1}" cnf fqdn cid auth_url signin bad=0
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  command -v curl &>/dev/null || { do_log "FATAL curl is not installed"; return 1; }
  do_gcp_spl_proj_id || return 1

  cnf=$(mktemp) || return 1
  # shellcheck disable=SC2064  # expand now: cnf is local
  trap "rm -f '${cnf}'" RETURN
  do_spl_merged_cnf "${APP_PATH}/${ORG}-${APP}-cnf/${ORG}-${APP}" "${ENV}" "${cnf}" || return 1
  fqdn=$(yq -r '.env.dns.fqdn // ""' "${cnf}")
  cid=$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID // ""' "${cnf}")
  auth_url=$(yq -r '.env.gcal.auth_url // ""' "${cnf}")
  signin=$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI // ""' "${cnf}")
  [[ -n "${fqdn}" && -n "${auth_url}" ]] || { do_log "FATAL cnf ${ENV} has no env.dns.fqdn or env.gcal.auth_url"; return 1; }
  [[ -n "${cid}" && "${cid}" != PLACEHOLDER-* ]] || { do_log "FATAL cnf ${ENV} has no SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID"; return 1; }
  do_log "INFO PROJ_ID=${PROJ_ID} app host=${fqdn} DRY_RUN=${dry_run}"

  _gcal_check_api "${cnf}" "${dry_run}" || bad=$?
  (( bad > 1 )) && return 1
  _gcal_check_redirect "${auth_url}" "${cid}" "${signin}" "https://${fqdn}${GCAL_CALLBACK_PATH}" || bad=1
  _gcal_print_manual "${fqdn}" "$(yq -r '.env.gcal.scopes // ""' "${cnf}")"

  if (( bad )); then
    do_log "FAIL a scripted check does not hold on ${PROJ_ID}: see the FAIL lines above"
    return 3
  fi
  do_log "OK the scripted checks hold on ${PROJ_ID}; the MANUAL lines are checked in the console"
}

# _gcal_check_api <merged cnf> <dry_run>: step 1, the Calendar API. Returns 0
# when it is on (or was just enabled), 1 when it is not, 2 on no account.
_gcal_check_api() {
  local cnf="$1" dry_run="$2" enabled rc
  if grep -qx "${GCAL_API}" <<<"$(yq -r '.env.steps."001-enable-gcp-services".gcp_services[]?' "${cnf}")"; then
    do_log "OK cnf lists ${GCAL_API} for terraform step 001"
  else
    do_log "WARN cnf does not list ${GCAL_API} in steps.001-enable-gcp-services.gcp_services"
  fi
  do_gcp_pin_account || return 2
  enabled=$(gcloud services list --enabled --project="${PROJ_ID}" --account="${GCP_ACCOUNT}" --format='value(config.name)' 2>&1)
  rc=$?
  [[ ${rc} -eq 0 ]] || { do_log "FAIL cannot list the enabled services of ${PROJ_ID} (rc=${rc}): ${enabled}"; return 1; }
  if grep -qx "${GCAL_API}" <<<"${enabled}"; then
    do_log "OK step 1: ${GCAL_API} is enabled on ${PROJ_ID}"
    return 0
  fi
  if [[ "${dry_run}" == 1 ]]; then
    do_log "FAIL step 1: ${GCAL_API} is not enabled on ${PROJ_ID}"
    do_log "INFO DRY_RUN would run: gcloud services enable ${GCAL_API} --project=${PROJ_ID} --account=${GCP_ACCOUNT}"
    return 1
  fi
  gcloud services enable "${GCAL_API}" --project="${PROJ_ID}" --account="${GCP_ACCOUNT}" \
    || { do_log "FAIL step 1: gcloud services enable ${GCAL_API} failed on ${PROJ_ID} as ${GCP_ACCOUNT}"; return 1; }
  do_log "OK step 1: enabled ${GCAL_API} on ${PROJ_ID}"
}

# _gcal_probe <auth_url> <client id> <redirect uri>: prints registered,
# mismatch or unknown:<http code> <location path>. Google's authorize endpoint
# sends a listed URI on to its sign-in page (.../signin/identifier) and an
# unlisted one to /signin/oauth/error?authError=<base64, "redirect_uri_mismatch">.
_gcal_probe() {
  local out code loc err
  out=$(curl -s -o /dev/null --max-time 20 -w '%{http_code} %{redirect_url}' -G "$1" \
    --data-urlencode "client_id=$2" --data-urlencode "redirect_uri=$3" \
    --data-urlencode response_type=code --data-urlencode scope=openid)
  code=${out%% *}; loc=${out#* }
  if [[ "${code}" == 302 && "${loc}" == */signin/oauth/error* ]]; then
    err=$(grep -o 'authError=[^&]*' <<<"${loc}" | cut -c11- | python3 -I -c \
      'import sys,base64,urllib.parse;s=urllib.parse.unquote(sys.stdin.read().strip());print(base64.urlsafe_b64decode(s+"==").decode("latin-1"))' 2>/dev/null)
    [[ "${err}" == *redirect_uri_mismatch* ]] && { echo mismatch; return 0; }
  elif [[ "${code}" == 302 && "${loc}" == */signin/identifier* ]]; then
    echo registered; return 0
  fi
  echo "unknown:${code} ${loc%%\?*}"
}

# _gcal_check_redirect <auth_url> <client id> <sign-in uri> <calendar uri>: S3.
_gcal_check_redirect() {
  local auth_url="$1" cid="$2" signin="$3" cal="$4" v rc=0
  if [[ -n "${signin}" ]]; then
    v=$(_gcal_probe "${auth_url}" "${cid}" "${signin}")
    if [[ "${v}" == registered ]]; then
      do_log "OK the sign-in redirect URI is on <client id>: ${signin}"
    else
      do_log "FAIL the sign-in redirect URI ${signin}: ${v} (S3 keeps the sign-in line)"; rc=1
    fi
  fi
  v=$(_gcal_probe "${auth_url}" "${cid}" "${cal}")
  case "${v}" in
    registered) do_log "OK step S3: ${cal} is an authorised redirect URI of <client id>" ;;
    mismatch)   do_log "FAIL step S3: Google answers redirect_uri_mismatch for ${cal}"
                do_log "MANUAL S3 (console only, no public API): project ${PROJ_ID}, APIs & Services, Credentials, the Web client <client id>, Authorised redirect URIs, Add URI: ${cal} (not JavaScript origins), Save; Google may take 5 min or more"
                rc=1 ;;
    *)          do_log "FAIL step S3: Google's answer for ${cal} was not read: ${v}"; rc=1 ;;
  esac
  return "${rc}"
}

# _gcal_print_manual <app host> <cnf gcal.scopes>: the console-only steps.
_gcal_print_manual() {
  local fqdn="$1" scopes="$2"
  do_log "MANUAL S2 scope (console only, no public API): Google Auth Platform, project ${PROJ_ID}, Data access, Add or remove scopes: ${GCAL_SCOPE}, Update, Save"
  do_log "MANUAL S2 test users (console only, no public API): Google Auth Platform, Audience, Test users, Add users: each tester's Google address"
  do_log "MANUAL branding (console only; the IAP brand API is IAP-only and deprecated): Google Auth Platform, Branding: home https://${fqdn}/, privacy https://${fqdn}/privacy, terms https://${fqdn}/terms"
  if [[ " ${scopes} " == *" ${GCAL_SCOPE} "* ]]; then
    do_log "OK cnf gcal.scopes asks for ${GCAL_SCOPE}: the consent screen must list it (S2)"
  else
    do_log "INFO cnf gcal.scopes is '${scopes}': it gets ${GCAL_SCOPE} after S2 (google-review-submission.md 1.2)"
  fi
}
