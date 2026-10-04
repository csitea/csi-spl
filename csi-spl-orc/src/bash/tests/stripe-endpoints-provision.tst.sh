#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 006 T022 do_spl_provision_stripe_endpoints (csi-rel's
#          do_provision_stripe_endpoints, one endpoint), CALLED against a stub
#          curl that plays the Stripe REST API and a stubbed gcloud with a
#          file-backed secret store:
#          - refused: no STRIPE_API_BASE (no default URL), a live key on dev,
#            a missing 030 slot (before any endpoint is created)
#          - dry run calls nothing; DRY_RUN=0 creates ONE endpoint on
#            https://<api_fqdn>/api/v1/webhooks/payment/stripe with the five
#            events and metadata managed_by=csi-spl role=hub, and the slot
#            holds exactly the whsec_ from the create response
#          - a re-run reuses it (no create, secret unchanged); RECREATE=1
#            deletes it, creates a new one and stores the NEW secret
#          - an untagged endpoint on the same URL is reported and left alone
#          - CONTROL: a create response without a secret stores nothing
#          - the secret key and the whsec_ are in no output and no argv (curl
#            gets the key on stdin); every gcloud call carries --account
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SD="$T/home/.stripe/.csi/.spl"
mkdir -p "$T/store" "$SD" "$T/bin" "$T/api"
rnd() { head -c 24 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c 1-24; }
p_sk=sk
SK_TEST="${p_sk}_test_$(rnd)" SK_LIVE="${p_sk}_live_$(rnd)"
printf 'STRIPE_SECRET_KEY=%s\n' "$SK_TEST" >"$SD/stripe-dev.env"; chmod 600 "$SD/stripe-dev.env"
echo '[]' >"$T/api/endpoints.json"

# stub curl = the Stripe REST API. State: $API/endpoints.json. Checks the
# bearer from the stdin config; NOSECRET=1 answers a create without a secret.
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
python3 - "$method" "$url" "$API" "${NOSECRET:-0}" "${form[@]}" <<'PY'
import json, sys, os, secrets
method, url, api, nosecret, form = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
p = os.path.join(api, "endpoints.json")
eps = json.load(open(p))
path = url.split("://", 1)[1].split("/", 1)[1]
if method == "GET" and path.startswith("v1/webhook_endpoints"):
    print(json.dumps({"data": eps})); print("200", end="")
elif method == "POST" and path == "v1/webhook_endpoints":
    f = {}
    for kv in form:
        k, v = kv.split("=", 1); f[k] = v
    ep = {"id": "we_" + secrets.token_hex(4), "url": f["url"],
          "metadata": {k[9:-1]: v for k, v in f.items() if k.startswith("metadata[")},
          "enabled_events": [v for k, v in sorted(f.items()) if k.startswith("enabled_events[")]}
    eps.append(ep); json.dump(eps, open(p, "w"))
    out = dict(ep)
    if nosecret != "1":
        out["secret"] = "whsec_" + secrets.token_hex(12)
        open(os.path.join(api, "last_secret"), "w").write(out["secret"])
    print(json.dumps(out)); print("200", end="")
elif method == "DELETE" and path.startswith("v1/webhook_endpoints/"):
    eid = path.rsplit("/", 1)[1]
    json.dump([e for e in eps if e["id"] != eid], open(p, "w"))
    print(json.dumps({"id": eid, "deleted": True})); print("200", end="")
else:
    print('{"error":{"message":"not found"}}'); print("404", end="")
PY
SH
chmod +x "$T/bin/curl"

run_act() {  # [VAR=value ...]
  local o rc
  o=$(env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" API="$T/api" WANT_SK="$SK_TEST" ENV=dev GCP_ACCOUNT=stub-sa@example.com \
      STRIPE_API_BASE="${BASE-https://stripe-mock.example.com}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "secrets describe "*) [[ "${NO_SLOT:-0}" == 1 ]] && return 1; return 0 ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*) local s="$4"; cat >"$STORE/$s"; echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    [[ -z "${STRIPE_API_BASE}" ]] && unset STRIPE_API_BASE
    do_spl_provision_stripe_endpoints' 2>&1); rc=$?
  printf '%s\n' "$o" >>"$T/allout"; printf '%s\n' "$o"; return $rc
}
WHS=csi-spl-hub-stripe-webhook-secret
n_eps() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/api/endpoints.json"; }
creates() { grep -c -- '-X POST' "$T/api/argv" 2>/dev/null || echo 0; }

out=$(BASE="" run_act DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(creates) -eq 0 ]] && pass "refused: no STRIPE_API_BASE (no default URL)" || fail "no base: rc=$rc $out"
printf 'STRIPE_SECRET_KEY=%s\n' "$SK_LIVE" >"$SD/stripe-dev.env"
out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(creates) -eq 0 ]] && pass "refused: a live key on dev" || fail "live on dev: rc=$rc $out"
printf 'STRIPE_SECRET_KEY=%s\n' "$SK_TEST" >"$SD/stripe-dev.env"
out=$(run_act DRY_RUN=0 NO_SLOT=1); rc=$?
[[ $rc -ne 0 && $(creates) -eq 0 && $(n_eps) -eq 0 ]] && pass "refused: a missing 030 slot, before any endpoint is created" || fail "no slot: rc=$rc $out"

out=$(run_act); rc=$?
[[ $rc -eq 0 && ! -s "$T/api/argv" ]] && pass "default is a dry run: no Stripe call" || fail "dry run: rc=$rc $out"
grep -q "endpoint  : https://dev.api.[^ ]*/api/v1/webhooks/payment/stripe" <<<"$out" && pass "the endpoint URL is the cnf api_fqdn + the hub webhook path" || fail "url: $out"
pinned="$(sed -n 's/^const DefaultStripeAPIVersion = "\(.*\)"$/\1/p' "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/payments/stripe_payments.go")"
[[ -n "$pinned" ]] && grep -qF "api_version $pinned" <<<"$out" && pass "the endpoint pins the hub driver's Stripe API version ($pinned)" || fail "api_version: $out"

out=$(run_act DRY_RUN=0); rc=$?
ep=$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))[0]; print(e["metadata"].get("managed_by"), e["metadata"].get("role"), len(e["enabled_events"]), e["url"].endswith("/api/v1/webhooks/payment/stripe"))' "$T/api/endpoints.json" 2>/dev/null)
[[ $rc -eq 0 && $(n_eps) -eq 1 && "$ep" == "csi-spl hub 5 True" ]] && pass "DRY_RUN=0 creates one tagged endpoint with the five events" || fail "create: rc=$rc ep=$ep $out"
[[ "$(cat "$T/store/$WHS" 2>/dev/null)" == "$(cat "$T/api/last_secret")" ]] && pass "the slot holds exactly the whsec_ of the create response" || fail "stored secret differs"
first="$(cat "$T/api/last_secret")"

c=$(creates); out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 && $(creates) -eq $c && "$(cat "$T/store/$WHS")" == "$first" ]] && pass "a re-run reuses the endpoint, secret unchanged" || fail "re-run: rc=$rc $out"

out=$(run_act DRY_RUN=0 RECREATE=1); rc=$?
[[ $rc -eq 0 && $(n_eps) -eq 1 && "$(cat "$T/store/$WHS")" == "$(cat "$T/api/last_secret")" && "$first" != "$(cat "$T/api/last_secret")" ]] &&
  pass "RECREATE=1 rolls the endpoint and stores the new secret" || fail "recreate: rc=$rc $out"

python3 - "$T/api/endpoints.json" <<'PY'
import json, sys
eps = json.load(open(sys.argv[1]))
eps.append({"id": "we_hand", "url": eps[0]["url"], "metadata": {}})
json.dump(eps, open(sys.argv[1], "w"))
PY
out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 ]] && grep -q "without this action's tag" <<<"$out" && grep -q we_hand "$T/api/endpoints.json" &&
  pass "an untagged endpoint on the URL is reported and left alone" || fail "untagged: rc=$rc $out"

# CONTROL: a create without a secret must store nothing
held="$(cat "$T/store/$WHS")"
out=$(run_act DRY_RUN=0 RECREATE=1 NOSECRET=1); rc=$?
[[ $rc -ne 0 && "$(cat "$T/store/$WHS")" == "$held" ]] && pass "CONTROL: a create response without a secret stores nothing" || fail "nosecret: rc=$rc $out"

all="$(cat "$T/argv" "$T/api/argv" "$T/allout")"
leak=0
for v in "$SK_TEST" "$SK_LIVE" "$first" "$held"; do grep -qF "$v" <<<"$all" && leak=1; done
(( leak == 0 )) && pass "no secret key or whsec_ in any output or argv" || fail "a secret leaked into output or argv"
[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
