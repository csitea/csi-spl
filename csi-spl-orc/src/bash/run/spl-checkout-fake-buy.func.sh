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
# @param ENV (optional) - lde (default) or dev
# @param DRY_RUN (optional) - 1 (default): plan only. 0: buy.
# @param BASE_URL (optional) - hub base; default lde http://127.0.0.1:<lde hub
# @param   port>, dev https://<env.dns.fqdn> (cnf, no baked host)
# @param KEY_OUT (optional) - claim JSON file; default <state dir>/tenants/
# @param   <tenant>.<utc>.json, mode 0600
# @example ENV=lde TENANT_ID=acme BUYER_EMAIL=buyer@example.com ./run -a do_spl_checkout_fake_buy
# @example ENV=dev DRY_RUN=0 TENANT_ID=m2proof1 BUYER_EMAIL=<you> ./run -a do_spl_checkout_fake_buy
#------------------------------------------------------------------------------
do_spl_checkout_fake_buy() {
  do_require_bin curl || return 1
  do_require_bin jq || return 1
  local tenant="${TENANT_ID:-}" email="${BUYER_EMAIL:-}" env="${ENV:-lde}" dry="${DRY_RUN:-1}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must match ^[a-z0-9][a-z0-9-]{0,31}$, got: '$tenant'"; return 1; }
  [[ "$email" == *@*.* ]] || { do_log "FATAL BUYER_EMAIL must be an address (no default)"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }

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
  plan="$(curl -fsS "$api/plan")" || { do_log "FATAL GET $api/plan failed"; return 1; }
  rail="$(jq -r .rail <<<"$plan")"
  [[ "$rail" == fake ]] || { do_log "FATAL $env checkout rail is '$rail', not fake (SPOOL_HUB_ENABLE_FAKE_PAY off or not deployed)"; return 1; }
  if [[ "$dry" == 1 ]]; then
    jq -c --arg t "$tenant" '{dry_run:true, tenant:$t, rail, amount_cents, currency, would:"checkout, fake-pay, claim once"}' <<<"$plan"
    do_log "OK DRY_RUN $env rail=fake; nothing bought"
    return 0
  fi

  # one curl helper: body in $_body, HTTP code in $_code (never logs a body)
  local _code _body
  _req() { # <method> <url> [json] [host-header]
    local out
    out="$(mktemp)" || return 1
    local args=(-sS -o "$out" -w '%{http_code}' -X "$1" "$2")
    [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' --data "$3")
    [[ -n "${4:-}" ]] && args+=(-H "Host: $4")
    _code="$(curl "${args[@]}")" || { rm -f "$out"; return 1; }
    _body="$(cat "$out")"
    rm -f "$out"
  }

  local id tok turl thost
  _req POST "$api" "$(jq -nc --arg t "$tenant" --arg e "$email" '{tenant_id:$t, email:$e}')" || return 1
  [[ "$_code" == 201 ]] || { do_log "FATAL checkout $tenant: HTTP $_code $(jq -c 'del(.claim_token)' <<<"$_body" 2>/dev/null)"; return 1; }
  id="$(jq -r .checkout_id <<<"$_body")"
  tok="$(jq -r .claim_token <<<"$_body")"
  turl="$(jq -r .tenant_url <<<"$_body")"
  thost="${turl#*://}"

  _req GET "$base/v1/view/threads" "" "$thost" || return 1
  [[ "$(jq -r .error <<<"$_body" 2>/dev/null)" == unknown_tenant ]] || {
    do_log "FATAL before payment the tenant host $thost must be unknown_tenant, got HTTP $_code"
    return 1
  }
  local before="$_code"

  _req POST "$api/fake-pay" "$(jq -nc --arg c "$id" '{checkout_id:$c}')" || return 1
  [[ "$_code" == 200 && "$(jq -r .applied <<<"$_body")" == true ]] || { do_log "FATAL fake-pay $id: HTTP $_code $_body"; return 1; }

  _req GET "$api/$id" || return 1
  [[ "$(jq -r .status <<<"$_body")" == paid ]] || { do_log "FATAL checkout $id is not paid after fake-pay: $_body"; return 1; }

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

  _req GET "$base/v1/view/threads" "" "$thost" || return 1
  [[ "$(jq -r .error <<<"$_body" 2>/dev/null)" != unknown_tenant ]] || { do_log "FATAL after payment $thost is still unknown_tenant"; return 1; }
  local after="$_code"

  jq -nc --arg t "$tenant" --arg c "$id" --arg u "$turl" --arg f "$out" --arg b "$before" --arg a "$after" \
    --arg r "$again" --arg l "$keylen" \
    '{tenant:$t, checkout_id:$c, tenant_url:$u, key_file:$f, tenant_before:($b|tonumber), fake_pay:"applied",
      status:"paid", claim:200, key_b64_len:($l|tonumber), claim_again:($r|tonumber), tenant_after:($a|tonumber)}'
  do_log "OK bought $tenant on the $env fake rail; root key in $out (0600), shown once, second claim $again"
}
