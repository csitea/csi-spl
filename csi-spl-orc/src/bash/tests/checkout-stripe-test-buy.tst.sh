#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: 006 T022 do_spl_checkout_stripe_test_buy, CALLED against a stub
#          curl that plays both the dev hub and the Stripe REST API:
#          - refused: ENV=prd, no STRIPE_API_BASE, a plan that is not an
#            available card rail, a LIVE key (no real money, ever)
#          - dry run reads only the plan
#          - DRY_RUN=0: checkout -> tenant unknown -> confirm the intent with the
#            test card (key on stdin, never argv) -> webhook paid -> claim once
#            (key to a 0600 file) -> second claim 410 -> tenant resolves
#          - CONTROL: a webhook that never marks it paid fails the run and no
#            claim is attempted
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SD="$T/home/.stripe/.csi/.spl"; mkdir -p "$SD" "$T/bin" "$T/st"
rnd() { head -c 24 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c 1-24; }
p_sk=sk; SK="${p_sk}_test_$(rnd)"
printf 'STRIPE_SECRET_KEY=%s\n' "$SK" >"$SD/stripe-dev.env"; chmod 600 "$SD/stripe-dev.env"

cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ST/argv"
o="" w="" m=GET url="" cfg=""
while (($#)); do
  case "$1" in
    -o) o="$2"; shift 2 ;; -w) w="$2"; shift 2 ;; -X) m="$2"; shift 2 ;;
    --config) cfg="$(cat)"; shift 2 ;; -H|--data|--data-urlencode) shift 2 ;;
    -*) shift ;; *) url="$1"; shift ;;
  esac
done
reply() { if [[ -n "$o" ]]; then printf '%s' "$2" >"$o"; printf '%s' "$1"; elif [[ -n "$w" ]]; then printf '%s\n%s' "$2" "$1"; else printf '%s' "$2"; fi; }
case "$m $url" in
  "GET "*/api/v1/checkout/plan) reply 200 "{\"rail\":\"${RAIL:-card}\",\"available\":true,\"amount_cents\":2000,\"currency\":\"eur\"}" ;;
  "POST "*/api/v1/checkout) reply 201 '{"checkout_id":"co_1","claim_token":"tok","tenant_url":"https://dev.example.com/login?tenant=t1","client_secret":"pi_1_secret_x"}' ;;
  "POST "*/v1/payment_intents/pi_1/confirm)
    [[ "$cfg" == *"Bearer $WANT_SK"* ]] || { reply 401 '{"error":{"message":"bad key"}}'; exit 0; }
    touch "$ST/confirmed"; reply 200 '{"id":"pi_1","status":"succeeded"}' ;;
  "GET "*/api/v1/checkout/co_1)
    if [[ -f "$ST/confirmed" && "${NEVER_PAID:-0}" != 1 ]]; then reply 200 '{"status":"paid","claimed":false}'; else reply 200 '{"status":"pending"}'; fi ;;
  "POST "*/api/v1/checkout/claim)
    if [[ -f "$ST/claimed" ]]; then reply 410 '{"error":"claimed"}'; else touch "$ST/claimed"; reply 200 '{"tenant_id":"t1","root_private_key":"AAAA"}'; fi ;;
  "GET "*/v1/ws) if [[ -f "$ST/claimed" ]]; then reply 426 'Upgrade Required'; else reply 404 '{"error":"unknown_tenant"}'; fi ;;
  *) reply 404 '{"error":"stub"}' ;;
esac
SH
chmod +x "$T/bin/curl"

run_act() {
  rm -f "$T/st/confirmed" "$T/st/claimed"
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" ST="$T/st" \
      WANT_SK="$SK" TENANT_ID=t1 BUYER_EMAIL=b@example.com PAID_WAIT=3 STRIPE_API_BASE="${BASE-https://stripe-mock.example.com}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    sleep() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    [[ -z "$STRIPE_API_BASE" ]] && unset STRIPE_API_BASE
    do_spl_checkout_stripe_test_buy' 2>&1
}
confirms() { grep -c '/confirm' "$T/st/argv" 2>/dev/null || true; }

out=$(run_act ENV=prd DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(confirms) -eq 0 ]] && pass "refused: ENV=prd" || fail "prd: rc=$rc $out"
out=$(BASE="" run_act DRY_RUN=0); rc=$?
[[ $rc -ne 0 ]] && pass "refused: no STRIPE_API_BASE" || fail "no base: rc=$rc $out"
out=$(run_act DRY_RUN=0 RAIL=fake); rc=$?
[[ $rc -ne 0 && $(confirms) -eq 0 ]] && pass "refused: a plan that is not the card rail" || fail "fake rail: rc=$rc $out"
out=$(run_act); rc=$?
[[ $rc -eq 0 && $(grep -c 'api/v1/checkout ' "$T/st/argv" || true) -eq 0 ]] && grep -q '"dry_run":true' <<<"$out" && pass "dry run reads only the plan" || fail "dry: rc=$rc $out"
printf 'STRIPE_SECRET_KEY=%s\n' "${p_sk}_live_$(rnd)" >"$SD/stripe-dev.env"
out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(confirms) -eq 0 ]] && pass "refused: a live key" || fail "live: rc=$rc $out"
printf 'STRIPE_SECRET_KEY=%s\n' "$SK" >"$SD/stripe-dev.env"

out=$(run_act DRY_RUN=0 NEVER_PAID=1); rc=$?
[[ $rc -ne 0 && ! -f "$T/st/claimed" ]] && grep -q "not paid" <<<"$out" && pass "CONTROL: no paid webhook -> fails, no claim" || fail "never paid: rc=$rc $out"

out=$(run_act DRY_RUN=0 KEY_OUT="$T/k/t1.json"); rc=$?
sum="$(grep '^{' <<<"$out" | tail -1)"
[[ $rc -eq 0 && "$(jq -r '"\(.tenant_before) \(.confirm) \(.status.status) \(.claim) \(.claim_again) \(.tenant_after)"' <<<"$sum")" == "404 succeeded paid 200 410 426" ]] &&
  pass "buy: unknown -> confirmed -> paid by webhook -> claim once -> 410 -> tenant resolves" || fail "buy: rc=$rc $out"
[[ "$(stat -c %a "$T/k/t1.json" 2>/dev/null)" == 600 ]] && pass "the claim lands in a 0600 file" || fail "key file mode"
grep -q AAAA <<<"$out" && fail "the root key reached stdout" || pass "no root key on stdout"
{ grep -qF "$SK" "$T/st/argv" || grep -qF "$SK" <<<"$out"; } && fail "the secret key reached argv or output" || pass "the secret key is in no argv and no output"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
