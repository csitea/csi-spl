#!/bin/bash
#------------------------------------------------------------------------------
# @description Buy a tenant on the FAKE rail end to end (006 T020/T021,
# @description contracts/checkout-v1.md) against a running hub: plan (rail must
# @description be fake) -> checkout -> the tenant host is still unknown ->
# @description fake-pay -> status paid -> claim ONCE -> a second claim is 410 ->
# @description the tenant host now resolves. The root PRIVATE key is minted at
# @description the claim (017 T008) and goes to KEY_OUT (0600), never to stdout
# @description or do_log; stdout is a JSON summary without secrets. The one
# @description mail (tenant URL + claim link, no key) goes wherever the hub's
# @description mail transport sends it (dev: the mail log).
# @description ENV=prd is refused: fake-pay does not exist there.
# @description DRY_RUN=1 (default): only reads GET /api/v1/checkout/plan.
# @param TENANT_ID - the slug to buy (msg.ValidTenantID)
# @param BUYER_EMAIL - where the one claim-link mail goes (no default)
# @param LOCALE (optional) - the language the buyer is reading the checkout in
# @param   (spec 021 T022), one of the 19 internal/i18n Supported codes: it is
# @param   sent as the checkout body's `locale`, kept on the row (rdb 0025
# @param   buyer_locale) and read back from GET /checkout/{id} `locale`, which
# @param   this action ASSERTS. The claim mail and its link prefix follow it.
# @param   Unset = say nothing: the row keeps "" and the mail stays on
# @param   SPOOL_HUB_DEFAULT_LOCALE, which is what every buy did before 0025.
# @param ENV (optional) - lde (default) or dev
# @param DRY_RUN (optional) - 1 (default): plan only. 0: buy.
# @param BASE_URL (optional) - hub base; default lde http://127.0.0.1:<lde hub
# @param   port>, dev https://<env.dns.fqdn> (cnf, no baked host)
# @param TENANT_HOST_SUFFIX (ignored since specs/026) - the probe names the tenant in X-Spool-Tenant on BASE_URL; no tenant host is involved. tenant_url is the WUI sign-in page since checkout-v1 1.4, never a host
# @param KEY_OUT (optional) - claim JSON file; default <state dir>/tenants/
# @param   <tenant>.<utc>.json, mode 0600
# @example ENV=lde TENANT_ID=acme BUYER_EMAIL=buyer@example.com ./run -a do_spl_checkout_fake_buy
# @example ENV=lde DRY_RUN=0 LOCALE=fi TENANT_ID=acmefi BUYER_EMAIL=buyer@example.com ./run -a do_spl_checkout_fake_buy
# @example ENV=dev DRY_RUN=0 TENANT_ID=m2proof1 BUYER_EMAIL=<you> ./run -a do_spl_checkout_fake_buy
#------------------------------------------------------------------------------
do_spl_checkout_fake_buy() {
  do_require_bin curl || return 1
  do_require_bin jq || return 1
  local tenant="${TENANT_ID:-}" email="${BUYER_EMAIL:-}" env="${ENV:-lde}" dry="${DRY_RUN:-1}"
  local locale="${LOCALE:-}"
  spl_checkout_require_buyer "$tenant" "$email" "$dry" || return $?
  spl_checkout_require_locale "$locale" || return 1

  local base="${BASE_URL:-}" state
  case "$env" in
    lde)
      if [[ -z "$base" ]]; then do_lde_cnf || return 1; base="http://127.0.0.1:${LDE_HUB_PORT}"; fi
      state="${LDE_STATE_DIR:-$HOME/.local/share/csi-spl/lde}"
      ;;
    dev)
      if [[ -z "$base" ]]; then ENV=dev do_spl_cloud_cnf || return 1; base="https://${SPL_FQDN}"; fi
      state="${SPL_STATE_DIR:-$HOME/.local/share/csi-spl/cloud/dev}"
      ;;
    prd)
      do_log "FATAL ENV=prd: fake-pay does not exist on prd (the hub refuses to boot with it); buy on a real rail instead"
      return 1
      ;;
    *)
      do_log "FATAL ENV must be lde or dev, got: '$env'"
      return 1
      ;;
  esac
  base="${base%/}"
  local api="$base/api/v1/checkout"

  local plan rail
  plan="$(curl -fsS -m 30 "$api/plan")" || { do_log "FATAL GET $api/plan failed"; return 1; }
  rail="$(jq -r .rail <<<"$plan")"
  [[ "$rail" == fake ]] || { do_log "FATAL $env checkout rail is '$rail', not fake (SPOOL_HUB_ENABLE_FAKE_PAY off or not deployed)"; return 1; }
  if [[ "$dry" == 1 ]]; then
    jq -c --arg t "$tenant" '{dry_run:true, tenant:$t, rail, amount_cents, currency, would:"checkout, fake-pay, claim once"}' <<<"$plan"
    do_log "OK DRY_RUN $env rail=fake; nothing bought"
    return 0
  fi

  # one curl helper: body in $_body, HTTP code in $_code (never logs a body)
  local _code _body
  _req() { # <method> <url> [json] [extra-header-line]
    local out
    out="$(mktemp)" || return 1
    local args=(-sS -m 30 -o "$out" -w '%{http_code}' -X "$1" "$2")
    [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' --data "$3")
    [[ -n "${4:-}" ]] && args+=(-H "$4")
    _code="$(curl "${args[@]}")" || { rm -f "$out"; return 1; }
    _body="$(cat "$out")"
    rm -f "$out"
  }

  local id tok turl
  # `locale` rides the BODY (checkout-v1 1.2): never a header, so no CORS
  # allow-list can refuse the checkout.
  _req POST "$api" "$(jq -nc --arg t "$tenant" --arg e "$email" --arg l "$locale" \
    '{tenant_id:$t, email:$e} + (if $l == "" then {} else {locale:$l} end)')" || return 1
  [[ "$_code" == 201 ]] || { do_log "FATAL checkout $tenant: HTTP $_code $(jq -c 'del(.claim_token)' <<<"$_body" 2>/dev/null)"; return 1; }
  id="$(jq -r .checkout_id <<<"$_body")"
  tok="$(jq -r .claim_token <<<"$_body")"
  turl="$(jq -r .tenant_url <<<"$_body")"  # the WUI sign-in page (checkout-v1 1.4)
  # tenant probe (specs/026): the box door names a tenant in X-Spool-Tenant
  # and resolves it before any upgrade: unknown -> 404 unknown_tenant, known
  # -> the websocket refusal of a plain GET (426). No tenant host involved.
  _tenant() { _req GET "$base/v1/ws" "" "X-Spool-Tenant: $tenant"; }

  _tenant || return 1
  [[ "$(jq -r .error <<<"$_body" 2>/dev/null)" == unknown_tenant ]] || {
    do_log "FATAL before payment tenant $tenant must be unknown_tenant, got HTTP $_code"
    return 1
  }
  local before="$_code"

  _req POST "$api/fake-pay" "$(jq -nc --arg c "$id" '{checkout_id:$c}')" || return 1
  [[ "$_code" == 200 && "$(jq -r .applied <<<"$_body")" == true ]] || { do_log "FATAL fake-pay $id: HTTP $_code $_body"; return 1; }

  _req GET "$api/$id" || return 1
  [[ "$(jq -r .status <<<"$_body")" == paid ]] || { do_log "FATAL checkout $id is not paid after fake-pay: $_body"; return 1; }
  # spec 021 T022: the row kept the buyer's locale (or "" when none was sent),
  # which is what the claim mail and its link prefix follow.
  local kept
  kept="$(jq -r '.locale // ""' <<<"$_body")"
  [[ "$kept" == "$locale" ]] || {
    do_log "FATAL checkout $id kept locale '$kept', sent '${locale:-<none>}' (hub too old for checkout-v1 1.3 locale, or it dropped the value)"
    return 1
  }

  local out="${KEY_OUT:-$state/tenants/$tenant.$(date -u +%Y%m%dT%H%M%SZ).json}"
  mkdir -p "$(dirname "$out")" && chmod 700 "$(dirname "$out")" || return 1
  _req POST "$api/claim" "$(jq -nc --arg c "$id" --arg k "$tok" '{checkout_id:$c, claim_token:$k}')" || return 1
  [[ "$_code" == 200 ]] || { do_log "FATAL claim $id: HTTP $_code $(jq -c 'del(.root_private_key)' <<<"$_body" 2>/dev/null)"; return 1; }
  (umask 077 && printf '%s\n' "$_body" >"$out") || return 1
  chmod 600 "$out"
  local keylen
  keylen="$(jq -r '.root_private_key | length' <<<"$_body")"
  _body=""

  _req POST "$api/claim" "$(jq -nc --arg c "$id" --arg k "$tok" '{checkout_id:$c, claim_token:$k}')" || return 1
  local again="$_code"
  tok=""
  [[ "$again" == 410 ]] || { do_log "FATAL a second claim answered HTTP $again, want 410"; return 1; }

  _tenant || return 1
  [[ "$(jq -r .error <<<"$_body" 2>/dev/null)" != unknown_tenant ]] || { do_log "FATAL after payment $tenant is still unknown_tenant"; return 1; }
  local after="$_code"

  jq -nc --arg t "$tenant" --arg c "$id" --arg u "$turl" --arg f "$out" --arg b "$before" --arg a "$after" \
    --arg r "$again" --arg l "$keylen" --arg loc "$kept" \
    '{tenant:$t, checkout_id:$c, tenant_url:$u, key_file:$f, tenant_before:($b|tonumber), fake_pay:"applied",
      status:"paid", claim:200, key_b64_len:($l|tonumber), claim_again:($r|tonumber), tenant_after:($a|tonumber),
      locale:$loc}'
  do_log "OK bought $tenant on the $env fake rail in locale '${kept:-<hub default>}'; root key in $out (0600), shown once, second claim $again"
}
