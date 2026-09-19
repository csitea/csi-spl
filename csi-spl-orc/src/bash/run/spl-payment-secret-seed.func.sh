#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the M2 payment secret VERSIONS (spec 006 T022) into the
# @description slots 030 creates empty (cnf payment.secret_env), from the
# @description owner's key files in csi-rel's layout, as $HOME/.stripe/.<org>/.<app>/:
# @description   stripe-<env>.env                   STRIPE_SECRET_KEY=sk_|rk_..
# @description                                      STRIPE_WEBHOOK_SECRET=whsec_..
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
  local want_mode=test
  [[ "$ENV" == prd ]] && want_mode=live

  local sk_slot wh_slot pp_slot paypal cnf_pk
  sk_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_STRIPE_SECRET_KEY // ""' "$SPL_CNF")"
  wh_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_STRIPE_WEBHOOK_SECRET // ""' "$SPL_CNF")"
  pp_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_PAYPAL_CLIENT_SECRET // ""' "$SPL_CNF")"
  paypal="$(yq -r '.env.hub.env.SPOOL_HUB_ENABLE_PAYPAL // "false"' "$SPL_CNF")"
  cnf_pk="$(yq -r '.env.hub.env.SPOOL_HUB_STRIPE_PUBLISHABLE_KEY // ""' "$SPL_CNF")"
  [[ -n "$sk_slot" && -n "$wh_slot" ]] || { do_log "FATAL cnf payment.secret_env lacks the stripe secret-key / webhook-secret slot names"; return 1; }

  _pss_owner_file() {  # <path> -> refuses a missing or non-0600 file
    [[ -s "$1" ]] || { do_log "FATAL no owner key file at $1 (0600)"; return 1; }
    [[ "$(stat -c %a "$1")" == 600 ]] || { do_log "FATAL $1 must be mode 0600"; return 1; }
  }
  _pss_get() {  # <file> <NAME> -> the value of NAME=..., quotes and CR stripped; never evaluated
    local line v=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"; line="${line#export }"
      [[ "$line" == "$2="* ]] || continue
      v="${line#"$2"=}"; v="${v#[\"\']}"; v="${v%[\"\']}"
    done <"$1"
    printf '%s' "$v"
  }

  _pss_owner_file "$envf" || return 1
  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  (umask 077 && _pss_get "$envf" STRIPE_SECRET_KEY >"$h/sk" && _pss_get "$envf" STRIPE_WEBHOOK_SECRET >"$h/wh") || return 1

  local sk_mode=""
  case "$(head -c 8 "$h/sk")" in
    sk_test_|rk_test_) sk_mode=test ;;
    sk_live_|rk_live_) sk_mode=live ;;
  esac
  [[ -n "$sk_mode" && "$(wc -c <"$h/sk")" -gt 8 ]] ||
    { do_log "FATAL STRIPE_SECRET_KEY in $envf is unset or not sk_/rk_ test|live shaped"; return 1; }
  [[ "$sk_mode" == "$want_mode" ]] ||
    { do_log "FATAL $ENV takes a $want_mode-mode secret key; $envf holds a $sk_mode-mode one"; return 1; }
  [[ "$(head -c 6 "$h/wh")" == whsec_ && "$(wc -c <"$h/wh")" -gt 6 ]] ||
    { do_log "FATAL STRIPE_WEBHOOK_SECRET in $envf is unset or not whsec_ shaped"; return 1; }

  # the shared-account guard: the same secret key under another app's dir
  local want_sk other shared=""
  want_sk="$(sha256sum <"$h/sk" | cut -d' ' -f1)"
  shopt -s nullglob
  for other in "$HOME/.stripe/.$org"/.*/stripe-*.env; do
    [[ "$(dirname "$other")" == "$sdir" ]] && continue
    [[ -r "$other" ]] || continue
    [[ "$(_pss_get "$other" STRIPE_SECRET_KEY | sha256sum | cut -d' ' -f1)" == "$want_sk" ]] && shared="$other"
  done
  shopt -u nullglob
  if [[ -n "$shared" ]]; then
    [[ "${STRIPE_SHARED_ACCOUNT_OK:-0}" == 1 ]] ||
      { do_log "FATAL the secret key in $envf is the one in $shared: another app's Stripe account needs the owner's go (STRIPE_SHARED_ACCOUNT_OK=1)"; return 1; }
    do_log "WARN the secret key is shared with $shared (STRIPE_SHARED_ACCOUNT_OK=1)"
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

  local seeds=("$sk_slot:$h/sk" "$wh_slot:$h/wh")
  if [[ "$paypal" == true ]]; then
    [[ -n "$pp_slot" ]] || { do_log "FATAL cnf payment.secret_env lacks the paypal slot name"; return 1; }
    local ppf="$pdir/paypal-$ENV.env"
    _pss_owner_file "$ppf" || return 1
    (umask 077 && _pss_get "$ppf" PAYPAL_CLIENT_SECRET >"$h/pp") || return 1
    [[ -s "$h/pp" ]] || { do_log "FATAL PAYPAL_CLIENT_SECRET in $ppf is unset"; return 1; }
    seeds+=("$pp_slot:$h/pp")
  else
    do_log "INFO SPOOL_HUB_ENABLE_PAYPAL is not true for $ENV: $pp_slot left alone"
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local s slot f want have rc=0
  for s in "${seeds[@]}"; do
    slot="${s%%:*}" f="${s#*:}"
    gcloud secrets describe "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
      { do_log "ERROR no slot $slot in $SPL_PROJECT (030 creates it)"; rc=1; continue; }
    want="$(sha256sum <"$f" | cut -d' ' -f1)"
    have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    if [[ "$have" == "$want" ]]; then
      do_log "INFO $slot already holds this value: nothing to add"
      continue
    fi
    if (( dry )); then
      do_log "INFO DRY_RUN would add a version to $slot in $SPL_PROJECT"
      continue
    fi
    gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- <"$f" >/dev/null 2>&1 ||
      { do_log "ERROR could not add a version to $slot"; rc=1; continue; }
    have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "$have" == "$want" ]] || { do_log "ERROR $slot latest version does not match its owner file (sha256)"; rc=1; continue; }
    do_log "INFO $slot: version added and verified by sha256 (value not logged)"
  done
  (( rc )) && { do_log "ERROR payment secrets for $ENV: see above"; return 1; }
  do_log "OK payment secrets for $ENV ($want_mode mode). Next: PROVIDER stripe + publishable key in $ENV.env.yaml, render, 030 apply"
}
