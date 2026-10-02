#!/bin/bash
#------------------------------------------------------------------------------
# Shared by the buy actions (do_spl_checkout_fake_buy and
# do_spl_checkout_stripe_test_buy): the checks on what a buyer passes in,
# before anything reaches the hub.
#------------------------------------------------------------------------------

# spl_checkout_require_locale <locale> -> 0 for "" (the hub default) or one of
# the 19 locales of internal/i18n Supported / rdb 0017+0025, listed here so a
# typo fails before it holds a slug (the hub would silently drop it).
spl_checkout_require_locale() {
  local locales=" bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl "
  [[ -z "$1" || "$locales" == *" $1 "* ]] && return 0
  do_log "FATAL LOCALE '$1' is not one of the 19 supported locales (bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl)"
  return 1
}

# spl_checkout_require_buyer <tenant> <email> <dry> -> 0 when the tenant is a
# slug, the email an address and DRY_RUN 0 or 1; else the FATAL, and 2 for a
# bad DRY_RUN (1 otherwise).
spl_checkout_require_buyer() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must match ^[a-z0-9][a-z0-9-]{0,31}$, got: '$1'"; return 1; }
  [[ "$2" == *@*.* ]] || { do_log "FATAL BUYER_EMAIL must be an address (no default)"; return 1; }
  [[ "$3" == 0 || "$3" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $3"; return 2; }
}
