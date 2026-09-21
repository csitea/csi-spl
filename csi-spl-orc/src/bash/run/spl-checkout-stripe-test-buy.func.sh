#!/bin/bash
#------------------------------------------------------------------------------
# @description Buy a tenant on the Stripe CARD rail in TEST mode end to end
# @description (006 T022 proof, contracts/checkout-v1.md) against the dev hub:
# @description plan (rail card, available) -> checkout -> the tenant host is
# @description still unknown -> the PaymentIntent is confirmed server-side with
# @description Stripe's test card payment method (what the WUI Payment Element
# @description does in a browser) -> Stripe's REAL signed webhook marks it paid
# @description (polled via GET /api/v1/checkout/<id>) -> claim ONCE -> a second
# @description claim is 410 -> the tenant host resolves. No money moves: the
# @description secret key must be a TEST key (sk_test_/rk_test_), and ENV=prd is
# @description refused. The key comes from the owner file as in
# @description do_spl_payment_secret_seed (STRIPE_KEY_APP / STRIPE_SHARED_ACCOUNT_OK)
# @description and reaches curl on stdin only. The root PRIVATE key (minted at
# @description the claim) goes to KEY_OUT (0600), never stdout or a log.
# @description DRY_RUN=1 (default): only reads GET /api/v1/checkout/plan.
# @param TENANT_ID - the slug to buy (msg.ValidTenantID)
# @param BUYER_EMAIL - where the one claim-link mail goes (no default)
# @param LOCALE (optional) - the language the buyer is reading the checkout in
# @param   (spec 021 T022), one of the 19 internal/i18n Supported codes: sent as
# @param   the checkout body's `locale`, kept on the row (rdb 0025 buyer_locale)
# @param   and read back from GET /checkout/{id} `locale`, which this action
# @param   ASSERTS. The claim mail and its link prefix follow it. Unset = say
# @param   nothing: the mail stays on SPOOL_HUB_DEFAULT_LOCALE.
# @param STRIPE_API_BASE - required, no default: the Stripe REST base URL
# @param ENV (optional) - dev (default; the only env)
# @param STRIPE_KEY_APP / STRIPE_SHARED_ACCOUNT_OK (optional) - as do_spl_payment_secret_seed
# @param TEST_PAYMENT_METHOD (optional) - Stripe test payment method id (default: the vendor's generic test visa id)
# @param PAID_WAIT (optional) - seconds to wait for the webhook, default 90
# @param DRY_RUN (optional) - 1 (default): plan only. 0: buy.
# @param KEY_OUT (optional) - claim JSON file; default <state dir>/tenants/<tenant>.<utc>.json, mode 0600
# @example ENV=dev DRY_RUN=0 TENANT_ID=m2card1 BUYER_EMAIL=<you> STRIPE_API_BASE=<stripe rest base> STRIPE_KEY_APP=rel STRIPE_SHARED_ACCOUNT_OK=1 ./run -a do_spl_checkout_stripe_test_buy
#------------------------------------------------------------------------------
do_spl_checkout_stripe_test_buy() {
  do_require_bin curl jq yq || return 1
  local tenant="${TENANT_ID:-}" email="${BUYER_EMAIL:-}" dry="${DRY_RUN:-1}"
  local locale="${LOCALE:-}"
  # The 19 locales of internal/i18n Supported / rdb 0017+0025, listed here so a
  # typo fails before it holds a slug (the hub would silently drop it).
  if [[ -n "$locale" ]]; then
    case " bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl " in
      *" $locale "*) : ;;
      *) do_log "FATAL LOCALE '$locale' is not one of the 19 supported locales (bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl)"; return 1 ;;
    esac
  fi
  [[ "${ENV:=dev}" == dev ]] || { do_log "FATAL ENV=$ENV: the test-card buy runs on dev only (prd takes real money)"; return 1; }
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must match ^[a-z0-9][a-z0-9-]{0,31}$, got: '$tenant'"; return 1; }
  [[ "$email" == *@*.* ]] || { do_log "FATAL BUYER_EMAIL must be an address (no default)"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  : "${STRIPE_API_BASE:?STRIPE_API_BASE must be set (no default) - the Stripe REST base URL}"
  do_spl_cloud_cnf || return 1
  local base="https://${SPL_FQDN}" sbase="${STRIPE_API_BASE%/}" state="${SPL_STATE_DIR}"
  local api="$base/api/v1/checkout"

  local plan
  plan="$(curl -fsS "$api/plan")" || { do_log "FATAL GET $api/plan failed"; return 1; }
  [[ "$(jq -r .rail <<<"$plan")" == card && "$(jq -r .available <<<"$plan")" == true ]] ||
    { do_log "FATAL dev checkout is not an available card rail: $(jq -c '{rail, available}' <<<"$plan")"; return 1; }
  if [[ "$dry" == 1 ]]; then
    jq -c --arg t "$tenant" '{dry_run:true, tenant:$t, rail, amount_cents, currency, would:"checkout, confirm with a test card, wait for the webhook, claim once"}' <<<"$plan"
    do_log "OK DRY_RUN dev rail=card available; nothing bought"
    return 0
  fi

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}" h
  spl_stripe_key_dir "$org" "$app" || return 1
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  spl_stripe_load_secret_key "$SPL_STRIPE_KEY_DIR/stripe-dev.env" "$h/sk" dev || return 1
  [[ "$SPL_STRIPE_MODE" == test ]] || { do_log "FATAL not a test-mode key"; return 1; }

  local _code _body
  _req() { # <method> <url> [json] [extra-header-line]
    local args=(-sS -o "$h/body" -w '%{http_code}' -X "$1" "$2")
    [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' --data "$3")
    [[ -n "${4:-}" ]] && args+=(-H "$4")
    _code="$(curl "${args[@]}")" || return 1
    _body="$(cat "$h/body")"
  }
  # tenant probe (specs/026): the hub API host's box door with the tenant named
  # in X-Spool-Tenant: unknown -> 404 unknown_tenant, known -> 426 (a plain GET
  # is no websocket). tenant_url is the WUI sign-in page, never a host.
  local turl hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  _tenant() { _req GET "$hub/v1/ws" "" "X-Spool-Tenant: $tenant"; }

  local id tok pi
  # `locale` rides the BODY (checkout-v1 1.2): never a header, so no CORS
  # allow-list can refuse the checkout.
  _req POST "$api" "$(jq -nc --arg t "$tenant" --arg e "$email" --arg l "$locale" \
    '{tenant_id:$t, email:$e} + (if $l == "" then {} else {locale:$l} end)')" || return 1
  [[ "$_code" == 201 ]] || { do_log "FATAL checkout $tenant: HTTP $_code $(jq -c 'del(.claim_token, .client_secret)' <<<"$_body" 2>/dev/null)"; return 1; }
  id="$(jq -r .checkout_id <<<"$_body")" tok="$(jq -r .claim_token <<<"$_body")"
  turl="$(jq -r .tenant_url <<<"$_body")"
  pi="$(jq -r .client_secret <<<"$_body")"; pi="${pi%%_secret_*}"
  [[ "$pi" == pi_* ]] || { do_log "FATAL the checkout answer carries no PaymentIntent client secret"; return 1; }
  _tenant || return 1
  [[ "$(jq -r .error <<<"$_body" 2>/dev/null)" == unknown_tenant ]] || { do_log "FATAL before payment tenant $tenant must be unknown_tenant, got HTTP $_code"; return 1; }
  local before="$_code"

  # the browser's confirmPayment, server-side: test card, return_url = the success page
  local pm="${TEST_PAYMENT_METHOD:-pm_card_visa}" out status
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$h/sk")" |
    curl -sS --config - -w '\n%{http_code}' -X POST --data-urlencode "payment_method=$pm" \
      --data-urlencode "return_url=$base/checkout/success" "$sbase/v1/payment_intents/$pi/confirm" 2>/dev/null)"
  status="${out##*$'\n'}"
  [[ "$status" == 200 && "$(jq -r .status <<<"${out%$'\n'*}")" == succeeded ]] ||
    { do_log "FATAL confirm $pi: HTTP $status $(jq -c '{status, error: .error.message}' <<<"${out%$'\n'*}" 2>/dev/null)"; return 1; }
  do_log "INFO $pi succeeded in Stripe test mode; waiting for the signed webhook"

  local waited=0 wait="${PAID_WAIT:-90}"
  while :; do
    _req GET "$api/$id" || return 1
    [[ "$(jq -r .status <<<"$_body")" == paid ]] && break
    (( waited >= wait )) && { do_log "FATAL checkout $id not paid ${wait}s after the confirm: the webhook did not arrive or was refused (see the hub log)"; return 1; }
    sleep 3; waited=$((waited + 3))
  done
  local status_json="$_body"
  # spec 021 T022: the row kept the buyer's locale (or "" when none was sent),
  # which is what the claim mail and its link prefix follow.
  local kept
  kept="$(jq -r '.locale // ""' <<<"$_body")"
  [[ "$kept" == "$locale" ]] || {
    do_log "FATAL checkout $id kept locale '$kept', sent '${locale:-<none>}' (hub too old for checkout-v1 1.3 locale, or it dropped the value)"
    return 1
  }

  local kout="${KEY_OUT:-$state/tenants/$tenant.$(date -u +%Y%m%dT%H%M%SZ).json}"
  mkdir -p "$(dirname "$kout")" && chmod 700 "$(dirname "$kout")" || return 1
  _req POST "$api/claim" "$(jq -nc --arg c "$id" --arg k "$tok" '{checkout_id:$c, claim_token:$k}')" || return 1
  [[ "$_code" == 200 ]] || { do_log "FATAL claim $id: HTTP $_code $(jq -c 'del(.root_private_key)' <<<"$_body" 2>/dev/null)"; return 1; }
  (umask 077 && printf '%s\n' "$_body" >"$kout") || return 1
  local keylen
  keylen="$(jq -r '.root_private_key | length' <<<"$_body")"
  _body=""
  _req POST "$api/claim" "$(jq -nc --arg c "$id" --arg k "$tok" '{checkout_id:$c, claim_token:$k}')" || return 1
  local again="$_code"
  tok=""
  [[ "$again" == 410 ]] || { do_log "FATAL a second claim answered HTTP $again, want 410"; return 1; }
  _tenant || return 1
  [[ "$(jq -r .error <<<"$_body" 2>/dev/null)" != unknown_tenant ]] || { do_log "FATAL after payment $tenant is still unknown_tenant"; return 1; }

  jq -nc --arg t "$tenant" --arg c "$id" --arg p "$pi" --arg u "$turl" --arg f "$kout" --arg b "$before" \
    --arg a "$_code" --arg r "$again" --arg l "$keylen" --arg w "$waited" --argjson s "$status_json" --arg loc "$kept" \
    '{tenant:$t, checkout_id:$c, payment_intent:$p, tenant_url:$u, key_file:$f, tenant_before:($b|tonumber),
      confirm:"succeeded", webhook_paid_after_s:($w|tonumber), status:$s, claim:200, key_b64_len:($l|tonumber),
      claim_again:($r|tonumber), tenant_after:($a|tonumber), locale:$loc}'
  do_log "OK bought $tenant on the dev Stripe TEST card rail ($pi) in locale '${kept:-<hub default>}'; paid by the real webhook; root key in $kout (0600)"
}
