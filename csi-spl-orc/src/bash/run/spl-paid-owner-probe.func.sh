#!/bin/bash
#------------------------------------------------------------------------------
# @description 047 W1 live proof (SPL-1161): after a paid TEST checkout
# @description (do_spl_checkout_stripe_test_buy), the buyer signs in with the
# @description checkout email and lands as biz_owner with NO operator invite,
# @description and any other verified address is refused. Makes two native
# @description accounts on the env's API host (env.dns.api_fqdn): register,
# @description verify with the debug token only a dev hub answers, sign in
# @description naming the tenant, read GET /v1/view/me. Random passwords, never
# @description printed or kept. dev only (prd has no debug tokens).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev
# @param TENANT_ID - required: the tenant the test checkout bought
# @param BUYER_EMAIL - required: that checkout's email (no account yet)
# @param OTHER_EMAIL - required: a second address with no invite (no account yet)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=w1probe1 BUYER_EMAIL=<buyer> OTHER_EMAIL=<other> DRY_RUN=0 ./run -a do_spl_paid_owner_probe
#------------------------------------------------------------------------------
do_spl_paid_owner_probe() {
  do_require_bin yq python3 || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev (the debug verify token exists on dev only), got: '${ENV:-}'"; return 1; }
  local tenant="${TENANT_ID:-}" buyer="${BUYER_EMAIL:-}" other="${OTHER_EMAIL:-}" api out rc=0
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$buyer" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { do_log "FATAL BUYER_EMAIL must be an address"; return 1; }
  [[ "$other" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { do_log "FATAL OTHER_EMAIL must be an address"; return 1; }
  [[ "${buyer,,}" != "${other,,}" ]] || { do_log "FATAL BUYER_EMAIL and OTHER_EMAIL must differ"; return 1; }
  do_spl_cloud_cnf || return 1
  spl_cnf_api_fqdn api || return 1
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would register, verify and sign in the buyer and one other address on https://$api for tenant $tenant (DRY_RUN=0 to run)"
    return 0
  fi
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_BUYER_EMAIL="$buyer" PROBE_OTHER_EMAIL="$other" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/paid-owner-probe.py")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL paid-owner probe on $ENV/$tenant (exit $rc): $out"; return 1; }
  do_log "OK paid-owner probe on $ENV/$tenant: $out"
}
