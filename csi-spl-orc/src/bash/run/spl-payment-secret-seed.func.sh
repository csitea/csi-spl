#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the M2 payment secret VERSIONS (spec 006 T022) into the
# @description slots 030 creates empty (cnf payment.secret_env), from the
# @description owner's key files in csi-rel's layout, as $HOME/.stripe/.<org>/.<app>/:
# @description   stripe-<env>.env                   STRIPE_SECRET_KEY=sk_|rk_..
# @description                                      STRIPE_WEBHOOK_SECRET=whsec_.. OPTIONAL: only for
# @description                                      a hand-registered endpoint; normally
# @description                                      do_spl_provision_stripe_endpoints creates the
# @description                                      endpoint and stores its whsec_ itself
# @description   stripe-publishable-key-<env>.txt   pk_.. (public; compared with
# @description                                      cnf SPOOL_HUB_STRIPE_PUBLISHABLE_KEY)
# @description and, only while cnf SPOOL_HUB_ENABLE_PAYPAL is "true",
# @description $HOME/.paypal/.<org>/.<app>/paypal-<env>.env PAYPAL_CLIENT_SECRET=..
# @description Every file must be mode 0600 and is PARSED, never sourced.
# @description Shape rules (csi-rel provision-stripe-prd): dev takes TEST keys
# @description only, prd LIVE keys only; the publishable key's mode must match.
# @description Shared-account guard: a secret key equal to one in another
# @description app's dir ($HOME/.stripe/.<org>/.*/stripe-*.env, e.g. csi-rel's)
# @description is refused unless STRIPE_SHARED_ACCOUNT_OK=1 (the owner's go).
# @description Values travel on stdin only: never argv, stdout or a log; a
# @description version is added only when it differs from the latest (sha256)
# @description and is verified by sha256 afterwards. After it: PROVIDER stripe
# @description + the publishable key in <env>.env.yaml, render, 030 apply.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param STRIPE_SHARED_ACCOUNT_OK (optional) - 1: allow a key another app also uses (owner go only)
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): report only. 0: add the versions.
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_payment_secret_seed
#------------------------------------------------------------------------------
do_spl_payment_secret_seed() {
  do_require_bin yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}"
  local sdir="$HOME/.stripe/.$org/.$app" pdir="$HOME/.paypal/.$org/.$app"
  local envf="$sdir/stripe-$ENV.env" pkf="$sdir/stripe-publishable-key-$ENV.txt"

  local sk_slot wh_slot pp_slot paypal cnf_pk
  sk_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_STRIPE_SECRET_KEY // ""' "$SPL_CNF")"
  wh_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_STRIPE_WEBHOOK_SECRET // ""' "$SPL_CNF")"
  pp_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_PAYPAL_CLIENT_SECRET // ""' "$SPL_CNF")"
  paypal="$(yq -r '.env.hub.env.SPOOL_HUB_ENABLE_PAYPAL // "false"' "$SPL_CNF")"
  cnf_pk="$(yq -r '.env.hub.env.SPOOL_HUB_STRIPE_PUBLISHABLE_KEY // ""' "$SPL_CNF")"
  [[ -n "$sk_slot" && -n "$wh_slot" ]] || { do_log "FATAL cnf payment.secret_env lacks the stripe secret-key / webhook-secret slot names"; return 1; }

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  spl_stripe_load_secret_key "$envf" "$h/sk" "$ENV" || return 1
  local want_mode="$SPL_STRIPE_MODE"
  local seeds=("$sk_slot:$h/sk")

  (umask 077 && spl_stripe_env_get "$envf" STRIPE_WEBHOOK_SECRET >"$h/wh") || return 1
  if [[ ! -s "$h/wh" ]]; then
    do_log "INFO no STRIPE_WEBHOOK_SECRET in $envf: $wh_slot left to do_spl_provision_stripe_endpoints"
  elif [[ "$(head -c 6 "$h/wh")" == whsec_ && "$(wc -c <"$h/wh")" -gt 6 ]]; then
    seeds+=("$wh_slot:$h/wh")
  else
    do_log "FATAL STRIPE_WEBHOOK_SECRET in $envf is not whsec_ shaped"; return 1
  fi

  # the publishable key is public, but it must match the secret key's mode and cnf
  if [[ -s "$pkf" ]]; then
    local pk
    pk="$(tr -d '[:space:]' <"$pkf")"
    [[ "$pk" == "pk_${want_mode}_"?* ]] || { do_log "FATAL $pkf is not a pk_${want_mode}_ key"; return 1; }
    if [[ "$cnf_pk" == "$pk" ]]; then
      do_log "INFO cnf SPOOL_HUB_STRIPE_PUBLISHABLE_KEY matches $(basename "$pkf")"
    else
      do_log "WARN cnf SPOOL_HUB_STRIPE_PUBLISHABLE_KEY differs from $pkf: set it in $ENV.env.yaml hub.env before PROVIDER=stripe"
    fi
  else
    do_log "WARN no $pkf: the card rail stays 503 (Guard) until cnf carries the publishable key"
  fi

  if [[ "$paypal" == true ]]; then
    [[ -n "$pp_slot" ]] || { do_log "FATAL cnf payment.secret_env lacks the paypal slot name"; return 1; }
    local ppf="$pdir/paypal-$ENV.env"
    spl_stripe_owner_file "$ppf" || return 1
    (umask 077 && spl_stripe_env_get "$ppf" PAYPAL_CLIENT_SECRET >"$h/pp") || return 1
    [[ -s "$h/pp" ]] || { do_log "FATAL PAYPAL_CLIENT_SECRET in $ppf is unset"; return 1; }
    seeds+=("$pp_slot:$h/pp")
  else
    do_log "INFO SPOOL_HUB_ENABLE_PAYPAL is not true for $ENV: $pp_slot left alone"
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local s rc=0
  for s in "${seeds[@]}"; do
    spl_secret_put "${s%%:*}" "${s#*:}" "$dry" || rc=1
  done
  (( rc )) && { do_log "ERROR payment secrets for $ENV: see above"; return 1; }
  do_log "OK payment secrets for $ENV ($want_mode mode). Next: PROVIDER stripe + publishable key in $ENV.env.yaml, render, 030 apply"
}
