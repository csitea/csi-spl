#!/bin/bash
#------------------------------------------------------------------------------
# @description Give a DEV test account (a native 015 login an action keeps in
# @description the state dir) a new password, then one sign-in to TENANT_ID
# @description with it through the hub. Since SPL-2157 the dev hub answers no
# @description debug token, so the password is set by the operator route:
# @description `spool hub-reset-password --password-stdin` against the dev hub
# @description DB through a Cloud SQL proxy, as the env's project SA (the path
# @description spl_m3_invite uses); it signs the account out everywhere. The
# @description new password is written to RESET_PW_FILE (0600) only after the
# @description reset and the sign-in worked, so a failed run leaves the file
# @description as it was. The way back for a test login whose stored password
# @description was lost or replaced: on 2026-10-11 the first
# @description do_spl_probe_member_seat replaced the dev t1 e2e member's
# @description <state>/m3-e2e/t1/pw-human with the probe member's. Nobody
# @description needs the old password: the account gets a new one. dev only:
# @description prd accounts are real. A file the first probe seat still owns
# @description (probe-invited beside it, outside probe/) is refused: run
# @description do_spl_probe_member_seat first, which moves it out.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev
# @param TENANT_ID - required: the tenant the account signs in to
# @param RESET_EMAIL - required: the account's email (do_spl_hub_member_list shows it)
# @param RESET_PW_FILE - required: where its password is kept, e.g. <state>/m3-e2e/t1/pw-human
# @param RESET_CMD (optional) - the reset script (the tests' seam)
# @param RESET_VIA (optional) - operator (default) or debug_token (an lde hub that still answers one)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 RESET_EMAIL=m3-e2e-human@example.com RESET_PW_FILE=$HOME/.local/share/csi-spl/cloud/dev/m3-e2e/t1/pw-human ./run -a do_spl_dev_password_reset
#------------------------------------------------------------------------------
do_spl_dev_password_reset() {
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev: a test login of the dev hub (prd accounts are real)"; return 1; }
  [[ "${RESET_VIA:-operator}" == operator || "${RESET_VIA:-}" == debug_token ]] || { do_log "FATAL RESET_VIA must be operator or debug_token"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local tenant="${TENANT_ID:-}" email="${RESET_EMAIL:-}" pwf="${RESET_PW_FILE:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID is not a workspace slug: '$tenant'"; return 1; }
  [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}$ ]] || { do_log "FATAL RESET_EMAIL is not an email: '$email'"; return 1; }
  [[ "$pwf" == /* && -d "$(dirname "$pwf")" ]] || { do_log "FATAL RESET_PW_FILE must be an absolute path in an existing dir, got: '$pwf'"; return 1; }
  # probe-invited marks the probe seat's own dir (<ws>/probe/); beside a file
  # in the ws dir it is the first version's login, not moved out yet.
  [[ "$(basename "$(dirname "$pwf")")" != probe && -e "$(dirname "$pwf")/probe-invited" ]] &&
    { do_log "FATAL $(dirname "$pwf") still holds the first probe seat's login (probe-invited): run ENV=dev TENANT_ID=$tenant DRY_RUN=0 ./run -a do_spl_probe_member_seat first, it moves it out"; return 1; }
  do_spl_cloud_cnf || return 1
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO DRY_RUN would: reset the password of $email on the dev hub (${RESET_VIA:-operator}), sign it in to $tenant, then write it to $pwf"
    do_log "OK DRY_RUN nothing was reset or written. Re-run with DRY_RUN=0."
    return 0
  fi
  local api out rc=0
  spl_cnf_api_fqdn api || return 1
  local -a run=(env RESET_API="https://$api" RESET_EMAIL="$email" RESET_TENANT="$tenant" RESET_PW_FILE="$pwf")
  if [[ "${RESET_VIA:-operator}" == operator ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    spl_host_spool || return 1
    run=(spl_via_proxy "${run[@]}" RESET_SPOOL="$SPL_SPOOL")
  fi
  out="$("${run[@]}" ${RESET_CMD:-python3 $PROJ_PATH/src/bash/scripts/dev-password-reset.py})" || rc=$?
  echo "$out"
  (( rc == 0 )) || { do_log "FAIL $email was not reset: $out ($pwf unchanged)"; return 1; }
  do_log "OK $email has a new password, signs in to $tenant ($ENV), kept in $pwf"
}
