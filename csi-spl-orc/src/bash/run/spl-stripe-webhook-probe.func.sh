#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove an env's Stripe webhook end to end with a REAL event that
# @description charges nothing (owner "send it", t1 bea3a4e6, 2026-10-01).
# @description Stripe has no "send test event" for a live endpoint, so this
# @description makes Stripe itself emit one: a PaymentIntent confirmed with
# @description the vendor's test DECLINE payment method. In test mode it is
# @description declined as a test card; in live mode Stripe refuses a known
# @description test card. Either way no money moves and Stripe emits
# @description payment_intent.payment_failed, one of the five events the hub
# @description endpoint (do_spl_provision_stripe_endpoints) subscribes to.
# @description The hub verifies the signature, finds no checkout of ours for
# @description that intent, logs "payment webhook: no checkout of ours names
# @description that payment" with the event id and answers 200 (audit only).
# @description Proof printed as one JSON line: the tagged endpoint (enabled,
# @description subscribed), the intent, the event id and its pending_webhooks
# @description reaching 0 (every endpoint answered 2xx). The intent is then
# @description cancelled. Read the hub side with do_gcp_tail_logs and the
# @description printed event id. The secret key reaches curl on stdin only.
# @param ENV - required: dev or prd
# @param STRIPE_API_BASE - required, no default: the Stripe REST base URL
# @param PROBE_PAYMENT_METHOD (optional) - the vendor's test decline payment method id (default pm_card_chargeDeclined)
# @param PROBE_AMOUNT (optional) - minor units, default 100 (never charged)
# @param PROBE_WAIT (optional) - seconds to wait for the delivery, default 90
# @param STRIPE_KEY_APP / STRIPE_SHARED_ACCOUNT_OK (optional) - as do_spl_payment_secret_seed
# @param DRY_RUN (optional) - 1 (default): check the endpoint only. 0: emit the event.
# @example ENV=prd STRIPE_API_BASE=<stripe rest base> DRY_RUN=0 ./run -a do_spl_stripe_webhook_probe
#------------------------------------------------------------------------------
do_spl_stripe_webhook_probe() {
  do_require_bin yq jq curl python3 sha256sum || return 1
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  : "${STRIPE_API_BASE:?STRIPE_API_BASE must be set (no default) - the Stripe REST base URL, or a local mock}"
  local sbase="${STRIPE_API_BASE%/}"
  case "$sbase" in
    https://?*) ;;
    http://127.0.0.1*|http://localhost*) do_log "WARN non-TLS Stripe base: only valid against a local mock" ;;
    *) do_log "FATAL STRIPE_API_BASE must be an https:// URL (got '$sbase')"; return 1 ;;
  esac
  local amount="${PROBE_AMOUNT:-100}" wait="${PROBE_WAIT:-90}" pm="${PROBE_PAYMENT_METHOD:-pm_card_chargeDeclined}"
  [[ "$amount" =~ ^[1-9][0-9]{1,5}$ ]] || { do_log "FATAL PROBE_AMOUNT must be 10..999999 minor units"; return 1; }
  [[ "$pm" == pm_card_* ]] || { do_log "FATAL PROBE_PAYMENT_METHOD must be a vendor test payment method (pm_card_*)"; return 1; }
  do_spl_cloud_cnf || return 1

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}" slug="$SPL_ORG_APP"
  local api_fqdn currency hook_url
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  currency="$(yq -r '.env.hub.env.SPOOL_HUB_PAYMENT_CURRENCY // "eur"' "$SPL_CNF")"
  [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  hook_url="https://$api_fqdn/api/v1/webhooks/payment/stripe"

  spl_stripe_key_dir "$org" "$app" || return 1
  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  spl_stripe_load_secret_key "$SPL_STRIPE_KEY_DIR/stripe-$ENV.env" "$h/sk" "$ENV" || return 1

  local out status body
  out="$(_spl_stripe_api GET "/v1/webhook_endpoints?limit=100" "$sbase" "$h/sk")" ||
    { do_log "FATAL could not reach $sbase"; return 1; }
  status="${out##*$'\n'}" body="${out%$'\n'*}"
  [[ "$status" == 200 ]] || { do_log "FATAL listing webhook endpoints: HTTP $status"; return 1; }
  local ep
  ep="$(jq -c --arg u "$hook_url" --arg s "$slug" '[.data[]? | select(.url == $u and .metadata.managed_by == $s and .metadata.role == "hub")]
    | first // empty | {id, status, subscribed: (.enabled_events | index("payment_intent.payment_failed") != null)}' <<<"$body")"
  [[ -n "$ep" ]] || { do_log "FATAL no endpoint tagged managed_by=$slug role=hub on $hook_url (do_spl_provision_stripe_endpoints)"; return 1; }
  [[ "$(jq -r .status <<<"$ep")" == enabled && "$(jq -r .subscribed <<<"$ep")" == true ]] ||
    { do_log "FATAL the hub endpoint is not enabled or not subscribed to payment_intent.payment_failed: $ep"; return 1; }
  do_log "INFO ENV=$ENV key mode $SPL_STRIPE_MODE, endpoint $(jq -r .id <<<"$ep") enabled on $hook_url"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would confirm a $amount $currency PaymentIntent with $pm (declined, nothing charged) and wait for its payment_intent.payment_failed delivery"
    return 0
  fi

  local t0 pi
  t0="$(date -u +%s)"
  out="$(_spl_stripe_api POST "/v1/payment_intents" "$sbase" "$h/sk" "amount=$amount" "currency=$currency" \
    "payment_method_types[]=card" "payment_method=$pm" "confirm=true" "description=$slug $ENV webhook probe (no charge)" \
    "metadata[managed_by]=$slug" "metadata[purpose]=webhook-probe")"
  status="${out##*$'\n'}" body="${out%$'\n'*}"
  pi="$(jq -r '.error.payment_intent.id // .id // ""' <<<"$body" 2>/dev/null)"
  [[ "$pi" == pi_* ]] || { do_log "FATAL no PaymentIntent from the probe: HTTP $status $(jq -c '.error | {code, decline_code}' <<<"$body" 2>/dev/null)"; return 1; }
  [[ "$(jq -r '.status // .error.payment_intent.status' <<<"$body")" != succeeded ]] ||
    { do_log "FATAL $pi SUCCEEDED: $pm is not a decline method - refund it by hand"; return 1; }
  do_log "INFO $pi declined (HTTP $status, $(jq -r '.error.decline_code // .error.code // "-"' <<<"$body")): nothing charged; waiting for its event"

  local waited=0 evt="" pending=""
  while :; do
    out="$(_spl_stripe_api GET "/v1/events?type=payment_intent.payment_failed&limit=20&created%5Bgte%5D=$((t0 - 60))" "$sbase" "$h/sk")"
    body="${out%$'\n'*}"
    evt="$(jq -r --arg p "$pi" '[.data[]? | select(.data.object.id == $p)] | first // empty | "\(.id) \(.pending_webhooks)"' <<<"$body" 2>/dev/null)"
    pending="${evt#* }" evt="${evt%% *}"
    [[ -n "$evt" && "$pending" == 0 ]] && break
    (( waited >= wait )) && break
    sleep 5; waited=$((waited + 5))
  done
  _spl_stripe_api POST "/v1/payment_intents/$pi/cancel" "$sbase" "$h/sk" >/dev/null ||
    do_log "WARN could not cancel $pi (it stays requires_payment_method, uncharged)"
  jq -nc --arg env "$ENV" --argjson ep "$ep" --arg pi "$pi" --arg e "$evt" --arg p "$pending" --arg w "$waited" \
    '{env:$env, endpoint:$ep, payment_intent:$pi, event_id:$e, pending_webhooks:($p|tonumber? // null), waited_s:($w|tonumber)}'
  [[ -n "$evt" ]] || { do_log "FATAL no payment_intent.payment_failed event for $pi after ${wait}s"; return 1; }
  [[ "$pending" == 0 ]] || { do_log "FATAL $evt still has $pending pending webhook(s) after ${wait}s: an endpoint did not answer 2xx (see the hub log)"; return 1; }
  do_log "OK $evt delivered to every endpoint (2xx); hub side: cd csi-spl-iac && ENV=$ENV FILTER='jsonPayload.event_id=\"$evt\"' ./run -a do_gcp_tail_logs"
}
