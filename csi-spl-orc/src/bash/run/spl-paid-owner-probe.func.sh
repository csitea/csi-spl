#!/bin/bash
#------------------------------------------------------------------------------
# @description 047 W1 live proof (SPL-1161): after a paid TEST checkout
# @description (do_spl_checkout_stripe_test_buy), the buyer signs in with the
# @description checkout email and lands as biz_owner with NO operator invite,
# @description and any other verified address is refused. Makes two native
# @description accounts on the env's API host (env.dns.api_fqdn): register,
# @description verify with the link in the verify mail (the dev hub answers no
# @description debug token since SPL-2157), read over IMAP from the relay
# @description mailbox (mail.env.SPOOL_HUB_MAIL_SMTP_USER, its password read
# @description as the env's project SA into a 0600 file removed after the run),
# @description sign in naming the tenant, read GET /v1/view/me. So both
# @description addresses must be plus-addresses of that mailbox: make the test
# @description checkout with one. Random passwords, never printed or kept.
# @description dev only (prd checkouts are real).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev
# @param TENANT_ID - required: the tenant the test checkout bought
# @param BUYER_EMAIL - required: that checkout's email (no account yet), <relay>+<tag>@<relay domain>
# @param OTHER_EMAIL - required: a second address with no invite (no account yet), also a relay plus-address
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=w1probe1 BUYER_EMAIL=<buyer> OTHER_EMAIL=<other> DRY_RUN=0 ./run -a do_spl_paid_owner_probe
#------------------------------------------------------------------------------
do_spl_paid_owner_probe() {
  do_require_bin yq python3 || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev (a test checkout; prd checkouts are real), got: '${ENV:-}'"; return 1; }
  local tenant="${TENANT_ID:-}" buyer="${BUYER_EMAIL:-}" other="${OTHER_EMAIL:-}" api out rc=0
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$buyer" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { do_log "FATAL BUYER_EMAIL must be an address"; return 1; }
  [[ "$other" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { do_log "FATAL OTHER_EMAIL must be an address"; return 1; }
  [[ "${buyer,,}" != "${other,,}" ]] || { do_log "FATAL BUYER_EMAIL and OTHER_EMAIL must differ"; return 1; }
  do_spl_cloud_cnf || return 1
  spl_cnf_api_fqdn api || return 1
  local relay a
  relay="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  relay="${relay,,}"
  [[ "$relay" =~ ^[^@+]+@[^@]+$ ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER mailbox in the $ENV cnf (got '$relay')"; return 1; }
  for a in "$buyer" "$other"; do
    [[ "${a,,}" == "${relay%@*}"+*"@${relay#*@}" ]] ||
      { do_log "FATAL $a is no plus-address of the relay mailbox: the verify mail is read there (the hub answers no debug token since SPL-2157); use ${relay%@*}+<tag>@${relay#*@}"; return 1; }
  done
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would register, verify (the mail over IMAP) and sign in the buyer and one other address on https://$api for tenant $tenant (DRY_RUN=0 to run)"
    return 0
  fi
  local st host
  st="$(mktemp -d)" || return 1
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  export M3_IMAP_USER="$relay" M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" M3_IMAP_PASS_FILE="$st/imap-pass"
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE" || { rm -rf "$st"; return 1; }
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_BUYER_EMAIL="$buyer" PROBE_OTHER_EMAIL="$other" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/paid-owner-probe.py")" || rc=$?
  rm -rf "$st"
  (( rc == 0 )) || { do_log "FATAL paid-owner probe on $ENV/$tenant (exit $rc): $out"; return 1; }
  do_log "OK paid-owner probe on $ENV/$tenant: $out"
}
