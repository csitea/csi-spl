#!/bin/bash
#------------------------------------------------------------------------------
# @description Give a DEV test account (a native 015 login an action keeps in
# @description the state dir) a new password through the hub's own reset flow:
# @description password/forgot -> the dev hub's debug token -> password/reset,
# @description then one sign-in to TENANT_ID with it. The new password is
# @description written to RESET_PW_FILE (0600) only after both worked, so a
# @description failed run leaves the file as it was. The way back for a test
# @description login whose stored password was lost or replaced: on 2026-10-11
# @description the first do_spl_probe_member_seat replaced the dev t1 e2e
# @description member's <state>/m3-e2e/t1/pw-human with the probe member's.
# @description Nobody needs the old password: the account gets a new one.
# @description dev only (prd mails the link and has no debug token). A file
# @description the first probe seat still owns (probe-invited beside it) is
# @description refused: run do_spl_probe_member_seat first, which moves it out.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev
# @param TENANT_ID - required: the tenant the account signs in to
# @param RESET_EMAIL - required: the account's email (do_spl_hub_member_list shows it)
# @param RESET_PW_FILE - required: where its password is kept, e.g. <state>/m3-e2e/t1/pw-human
# @param RESET_CMD (optional) - the reset script (the tests' seam)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 RESET_EMAIL=m3-e2e-human@example.com RESET_PW_FILE=$HOME/.local/share/csi-spl/cloud/dev/m3-e2e/t1/pw-human ./run -a do_spl_dev_password_reset
#------------------------------------------------------------------------------
do_spl_dev_password_reset() {
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev: only the dev hub answers password/forgot with a debug token"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local tenant="${TENANT_ID:-}" email="${RESET_EMAIL:-}" pwf="${RESET_PW_FILE:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID is not a workspace slug: '$tenant'"; return 1; }
  [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}$ ]] || { do_log "FATAL RESET_EMAIL is not an email: '$email'"; return 1; }
  [[ "$pwf" == /* && -d "$(dirname "$pwf")" ]] || { do_log "FATAL RESET_PW_FILE must be an absolute path in an existing dir, got: '$pwf'"; return 1; }
  [[ -e "$(dirname "$pwf")/probe-invited" ]] &&
    { do_log "FATAL $(dirname "$pwf") still holds the first probe seat's login (probe-invited): run ENV=dev TENANT_ID=$tenant DRY_RUN=0 ./run -a do_spl_probe_member_seat first, it moves it out"; return 1; }
  do_spl_cloud_cnf || return 1
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO DRY_RUN would: reset the password of $email on the dev hub, sign it in to $tenant, then write it to $pwf"
    do_log "OK DRY_RUN nothing was reset or written. Re-run with DRY_RUN=0."
    return 0
  fi
  local api out rc=0
  spl_cnf_api_fqdn api || return 1
  out="$(RESET_API="https://$api" RESET_EMAIL="$email" RESET_TENANT="$tenant" RESET_PW_FILE="$pwf" \
    ${RESET_CMD:-python3 $PROJ_PATH/src/bash/scripts/dev-password-reset.py})" || rc=$?
  echo "$out"
  (( rc == 0 )) || { do_log "FAIL $email was not reset: $out ($pwf unchanged)"; return 1; }
  do_log "OK $email has a new password, signs in to $tenant ($ENV), kept in $pwf"
}
