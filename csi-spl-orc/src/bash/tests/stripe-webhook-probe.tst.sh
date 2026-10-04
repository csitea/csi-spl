#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_stripe_webhook_probe (owner "send it", t1 bea3a4e6), CALLED
#          against a stub curl that plays the Stripe REST API:
#          - refused: no STRIPE_API_BASE, a bad ENV, a non-test payment method,
#            no tagged hub endpoint, a disabled endpoint
#          - the default is a dry run: endpoint list only, no PaymentIntent
#          - DRY_RUN=0 confirms ONE intent with the decline method, finds its
#            payment_intent.payment_failed event, reports pending_webhooks 0
#            and cancels the intent
#          - CONTROL: an event still pending after PROBE_WAIT fails the run
#          - the secret key is in no output and no argv (curl gets it on stdin)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SD="$T/home/.stripe/.csi/.spl"
mkdir -p "$SD" "$T/bin" "$T/api"
rnd() { head -c 24 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c 1-24; }
p_sk=sk
SK_TEST="${p_sk}_test_$(rnd)"
printf 'STRIPE_SECRET_KEY=%s\n' "$SK_TEST" >"$SD/stripe-dev.env"; chmod 600 "$SD/stripe-dev.env"

# stub curl = the Stripe REST API. EP_STATUS / EP_URL shape the one endpoint,
# PENDING the event's pending_webhooks. Every call is appended to $API/argv.
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$API/argv"
cfg="$(cat)"
[[ "$cfg" == *"Bearer $WANT_SK"* ]] || { printf '{"error":{"message":"bad key"}}\n401'; exit 0; }
method=GET url="" form=()
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-urlencode) form+=("$2"); shift 2 ;;
    -w|--config) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
python3 - "$method" "$url" "$API" "${form[@]}" <<'PY'
import json, sys, os
method, url, api, form = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
path = url.split("://", 1)[1].split("/", 1)[1]
env = os.environ
if method == "GET" and path.startswith("v1/webhook_endpoints"):
    eps = [] if env.get("NO_EP") == "1" else [{"id": "we_hub", "url": env["EP_URL"], "status": env.get("EP_STATUS", "enabled"),
            "metadata": {"managed_by": "csi-spl", "role": "hub"},
            "enabled_events": ["payment_intent.succeeded", "payment_intent.payment_failed"]}]
    print(json.dumps({"data": eps})); print("200", end="")
elif method == "POST" and path == "v1/payment_intents":
    open(os.path.join(api, "pi_form"), "w").write("\n".join(form))
    print(json.dumps({"error": {"code": "card_declined", "decline_code": "generic_decline",
          "payment_intent": {"id": "pi_probe1", "status": "requires_payment_method"}}})); print("402", end="")
elif method == "GET" and path.startswith("v1/events"):
    ev = {"id": "evt_probe1", "type": "payment_intent.payment_failed", "pending_webhooks": int(env.get("PENDING", "0")),
          "data": {"object": {"id": "pi_probe1"}}}
    print(json.dumps({"data": [ev]})); print("200", end="")
elif method == "POST" and path == "v1/payment_intents/pi_probe1/cancel":
    open(os.path.join(api, "cancelled"), "w").write("1")
    print('{"id":"pi_probe1","status":"canceled"}'); print("200", end="")
else:
    print('{"error":{"message":"not found"}}'); print("404", end="")
PY
SH
chmod +x "$T/bin/curl"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"; chmod +x "$T/bin/sleep"

run_act() {  # [VAR=value ...]
  local o rc
  rm -f "$T/api/argv" "$T/api/pi_form" "$T/api/cancelled"
  o=$(env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      API="$T/api" WANT_SK="$SK_TEST" ENV=dev EP_URL="${EP_URL:-}" PROBE_WAIT=10 \
      STRIPE_API_BASE="${BASE-https://stripe-mock.example.com}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    [[ -z "${STRIPE_API_BASE}" ]] && unset STRIPE_API_BASE
    do_spl_stripe_webhook_probe' 2>&1); rc=$?
  printf '%s\n' "$o" >>"$T/allout"; printf '%s\n' "$o"; return $rc
}

# the endpoint URL the action derives from cnf (read off its dry-run log)
EP_URL="$(run_act NO_EP=1 | sed -n 's/.*tagged managed_by=csi-spl role=hub on \([^ ]*\).*/\1/p' | sed -n 1p)"
[[ "$EP_URL" == https://*/api/v1/webhooks/payment/stripe ]] && pass "the probe targets https://<api_fqdn>/api/v1/webhooks/payment/stripe" || fail "url: '$EP_URL'"
export EP_URL

out=$(BASE="" run_act DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -s "$T/api/argv" ]] && pass "refused: no STRIPE_API_BASE (no default URL)" || fail "no base: rc=$rc $out"
out=$(run_act ENV=stg DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -s "$T/api/argv" ]] && pass "refused: ENV other than dev|prd" || fail "env: rc=$rc $out"
out=$(run_act DRY_RUN=0 PROBE_PAYMENT_METHOD=pm_real123); rc=$?
[[ $rc -ne 0 && ! -s "$T/api/argv" ]] && pass "refused: a payment method that is not a vendor test one" || fail "pm: rc=$rc $out"
out=$(run_act DRY_RUN=0 NO_EP=1); rc=$?
[[ $rc -ne 0 && ! -f "$T/api/pi_form" ]] && pass "refused: no tagged hub endpoint, no intent created" || fail "no ep: rc=$rc $out"
out=$(run_act DRY_RUN=0 EP_STATUS=disabled); rc=$?
[[ $rc -ne 0 && ! -f "$T/api/pi_form" ]] && pass "refused: a disabled endpoint, no intent created" || fail "disabled: rc=$rc $out"

out=$(run_act); rc=$?
[[ $rc -eq 0 && ! -f "$T/api/pi_form" ]] && pass "default is a dry run: no PaymentIntent" || fail "dry: rc=$rc $out"

out=$(run_act DRY_RUN=0); rc=$?
line=$(grep '^{"env"' <<<"$out")
[[ $rc -eq 0 && "$(jq -r '.event_id, .pending_webhooks, .payment_intent' <<<"$line" | tr '\n' ' ')" == "evt_probe1 0 pi_probe1 " ]] &&
  pass "DRY_RUN=0 reports the delivered payment_intent.payment_failed event" || fail "probe: rc=$rc $out"
grep -qx 'payment_method=pm_card_chargeDeclined' "$T/api/pi_form" && grep -qx 'confirm=true' "$T/api/pi_form" &&
  pass "the intent is confirmed with the decline test method" || fail "form: $(cat "$T/api/pi_form" 2>/dev/null)"
[[ -f "$T/api/cancelled" ]] && pass "the intent is cancelled afterwards" || fail "not cancelled"

out=$(run_act DRY_RUN=0 PENDING=1); rc=$?
[[ $rc -ne 0 && -f "$T/api/cancelled" ]] && grep -q "pending webhook" <<<"$out" &&
  pass "CONTROL: an undelivered event fails the run (intent still cancelled)" || fail "pending: rc=$rc $out"

! grep -qF "$SK_TEST" "$T/allout" "$T/api/argv" 2>/dev/null && pass "the secret key is in no output and no argv" || fail "key leaked"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
