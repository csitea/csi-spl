#!/bin/bash
#------------------------------------------------------------------------------
# @description Create (or reuse) the Stripe webhook endpoint of an env and store
# @description its signing secret, without a human ever copying a whsec_ (spec
# @description 006 T022). csi-rel's do_provision_stripe_endpoints, copied with
# @description names adapted and ONE deviation: the hub verifies one secret
# @description (payments.VerifyStripe), there is no Stripe Connect, so there is
# @description one endpoint (role hub), not the platform + connect pair, and no
# @description connected-account creation.
# @description Stripe returns an endpoint's signing secret ONLY in the create
# @description response: it goes straight from that response into a 0600 scratch
# @description file and from there into the cnf slot
# @description payment.secret_env.SPOOL_HUB_STRIPE_WEBHOOK_SECRET in the same run
# @description (spl_secret_put: stdin, sha256-verified); never printed, never argv.
# @description A lost secret means rolling the endpoint: RECREATE=1.
# @description Reconciliation is by metadata, not URL: what this action creates
# @description carries metadata[managed_by]=<org>-<app> + metadata[role]=hub, and
# @description only that is reused; an untagged endpoint on the same URL (made by
# @description hand) is reported and left alone. Webhook-only: the secret key
# @description itself is stored by do_spl_payment_secret_seed.
# @description The secret key comes from the owner file
# @description $HOME/.stripe/.<org>/.<app>/stripe-<env>.env (0600, parsed, never
# @description sourced; dev test keys only, prd live only; a key shared with
# @description another app's dir needs STRIPE_SHARED_ACCOUNT_OK=1) and reaches curl
# @description on stdin (--config -), never argv. The endpoint URL is
# @description https://<env.dns.api_fqdn>/api/v1/webhooks/payment/stripe from cnf.
# @param ENV - required: dev or prd
# @param STRIPE_API_BASE - required, no default: the Stripe REST base URL (e.g. the vendor's public API base, or a local mock)
# @param WEBHOOK_URL (optional) - override the endpoint URL (https only)
# @param RECREATE (optional) - 1: delete this action's endpoint and make a new one (the only way to recover a lost whsec_)
# @param STRIPE_KEY_APP (optional) - use that app's key files in place (e.g. rel: the owner-approved shared account); needs STRIPE_SHARED_ACCOUNT_OK=1. The endpoint is still OURS (tagged managed_by=<org>-<app>), so events never mix
# @param STRIPE_SHARED_ACCOUNT_OK (optional) - 1: allow a key another app also uses (owner go only)
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): validate, resolve the URL, print the plan, touch nothing. 0: do it.
# @example ENV=dev STRIPE_API_BASE=<stripe rest base> DRY_RUN=0 ./run -a do_spl_provision_stripe_endpoints
#------------------------------------------------------------------------------

# The events the hub consumes (payments.stripeKind + the dispute alarm).
_SPL_STRIPE_WEBHOOK_EVENTS=(
  payment_intent.succeeded
  payment_intent.payment_failed
  charge.refunded
  charge.dispute.created
  charge.dispute.closed
)

# _spl_stripe_api <method> <path> <base> <sk-file> [form...] -> "<body>\n<status>";
# the key goes to curl on stdin as a header, never on the command line.
_spl_stripe_api() {
  local method="$1" path="$2" base="$3" skf="$4"; shift 4
  local -a form=()
  local arg
  for arg in "$@"; do form+=(--data-urlencode "$arg"); done
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$skf")" |
    curl -sS --config - -w '\n%{http_code}' -X "$method" "${form[@]}" "${base}${path}" 2>/dev/null
}

# _spl_stripe_json_get <dotted.key> <- JSON on stdin
_spl_stripe_json_get() { python3 -c '
import json,sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(0)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
if d is not None:
    print(d if not isinstance(d, bool) else str(d).lower())
' "$1"; }

do_spl_provision_stripe_endpoints() {
  do_require_bin yq curl python3 sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  : "${STRIPE_API_BASE:?STRIPE_API_BASE must be set (no default) - the Stripe REST base URL, or a local mock}"
  local api_base="${STRIPE_API_BASE%/}"
  case "$api_base" in
    https://?*) ;;
    http://127.0.0.1*|http://localhost*) do_log "WARN non-TLS Stripe base: only valid against a local mock" ;;
    *) do_log "FATAL STRIPE_API_BASE must be an https:// URL (got '$api_base')"; return 1 ;;
  esac

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}" slug="$SPL_ORG_APP"
  spl_stripe_key_dir "$org" "$app" || return 1
  local envf="$SPL_STRIPE_KEY_DIR/stripe-$ENV.env"
  local wh_slot api_fqdn api_version hook_url
  wh_slot="$(yq -r '.env.payment.secret_env.SPOOL_HUB_STRIPE_WEBHOOK_SECRET // ""' "$SPL_CNF")"
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  api_version="$(yq -r '.env.hub.env.SPOOL_HUB_STRIPE_API_VERSION // ""' "$SPL_CNF")"
  [[ -n "$wh_slot" ]] || { do_log "FATAL cnf payment.secret_env lacks SPOOL_HUB_STRIPE_WEBHOOK_SECRET"; return 1; }
  hook_url="${WEBHOOK_URL:-}"
  if [[ -z "$hook_url" ]]; then
    [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF (or set WEBHOOK_URL)"; return 1; }
    hook_url="https://$api_fqdn/api/v1/webhooks/payment/stripe"
  fi
  [[ "$hook_url" == https://?* ]] || { do_log "FATAL WEBHOOK_URL must be an https:// URL (got '$hook_url')"; return 1; }

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  spl_stripe_load_secret_key "$envf" "$h/sk" "$ENV" || return 1

  do_log "INFO Stripe endpoint for ENV=$ENV (key mode: $SPL_STRIPE_MODE)"
  do_log "INFO   REST base : $api_base"
  do_log "INFO   endpoint  : $hook_url"
  do_log "INFO   events    : ${_SPL_STRIPE_WEBHOOK_EVENTS[*]}"
  do_log "INFO   stores    : the new signing secret into $wh_slot only (the secret key: do_spl_payment_secret_seed)"
  if (( dry )); then
    do_log "OK DRY_RUN would list /v1/webhook_endpoints, reuse the one tagged managed_by=$slug role=hub, else create it and store its whsec_"
    return 0
  fi

  # the GCP identity first: a whsec_ captured with nowhere to go is lost
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  gcloud secrets describe "$wh_slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { do_log "FATAL no slot $wh_slot in $SPL_PROJECT (030 creates it): no endpoint created"; return 1; }
  local out status body
  out="$(_spl_stripe_api GET "/v1/webhook_endpoints?limit=100" "$api_base" "$h/sk")" ||
    { do_log "FATAL could not reach $api_base to list webhook endpoints"; return 1; }
  status="${out##*$'\n'}" body="${out%$'\n'*}"
  [[ "$status" == 200 ]] ||
    { do_log "FATAL listing webhook endpoints failed with HTTP $status: $(printf '%s' "$body" | _spl_stripe_json_get error.message)"; return 1; }

  local existing have="" untagged=0 role epid
  existing="$(printf '%s' "$body" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read() or "{}")
url, slug = sys.argv[1], sys.argv[2]
for ep in d.get("data", []):
    if ep.get("url") != url:
        continue
    md = ep.get("metadata") or {}
    role = md.get("role", "") if md.get("managed_by") == slug else "untagged"
    print(role + "\t" + ep.get("id", ""))
' "$hook_url" "$slug")"
  while IFS=$'\t' read -r role epid; do
    case "$role" in
      hub) have="$epid" ;;
      untagged) untagged=$((untagged + 1)) ;;
    esac
  done <<<"$existing"
  if (( untagged > 0 )); then
    do_log "WARN $untagged endpoint(s) already point at $hook_url without this action's tag: made by hand, left untouched."
    do_log "WARN   Stripe delivers each event to every endpoint on the URL; remove the duplicates once this run is verified."
  fi

  if [[ "${RECREATE:-0}" == 1 && -n "$have" ]]; then
    out="$(_spl_stripe_api DELETE "/v1/webhook_endpoints/$have" "$api_base" "$h/sk")"
    [[ "${out##*$'\n'}" == 200 ]] || { do_log "FATAL RECREATE: could not delete $have (HTTP ${out##*$'\n'})"; return 1; }
    do_log "INFO RECREATE: deleted $have"
    have=""
  fi
  if [[ -n "$have" ]]; then
    do_log "OK the hub endpoint already exists ($have): reused, secret unchanged, $wh_slot left alone"
    return 0
  fi

  local -a form=("url=$hook_url" "description=$slug $ENV hub endpoint (006 T022)"
    "metadata[managed_by]=$slug" "metadata[role]=hub" "metadata[env]=$ENV")
  [[ -n "$api_version" ]] && form+=("api_version=$api_version")
  local i=0 ev
  for ev in "${_SPL_STRIPE_WEBHOOK_EVENTS[@]}"; do form+=("enabled_events[$i]=$ev"); i=$((i + 1)); done
  out="$(_spl_stripe_api POST "/v1/webhook_endpoints" "$api_base" "$h/sk" "${form[@]}")"
  status="${out##*$'\n'}" body="${out%$'\n'*}"
  [[ "$status" == 200 ]] ||
    { do_log "FATAL creating the hub endpoint failed with HTTP $status: $(printf '%s' "$body" | _spl_stripe_json_get error.message)"; return 1; }
  local created
  created="$(printf '%s' "$body" | _spl_stripe_json_get id)"
  (umask 077 && printf '%s' "$body" | _spl_stripe_json_get secret | tr -d '\n' >"$h/wh") || return 1
  if [[ "$(head -c 6 "$h/wh")" != whsec_ ]]; then
    do_log "FATAL the endpoint was created ($created) but the response carried no signing secret: Stripe never returns it again, re-run with RECREATE=1"
    return 1
  fi
  do_log "INFO created the hub endpoint $created (signing secret captured, not printed)"

  spl_secret_put "$wh_slot" "$h/wh" 0 ||
    { do_log "FATAL the endpoint $created exists but its signing secret could NOT be stored: re-run with RECREATE=1 to roll it"; return 1; }
  do_log "OK hub endpoint $created for $ENV, signing secret in $wh_slot. Next: do_spl_payment_secret_seed (the secret key), PROVIDER stripe, render, 030 apply"
}
