#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 006 T020/T022 -- the M2 payment settings as 030 renders them:
#          the stripe pair + the PayPal secret have EMPTY slots in every env;
#          the stripe pair is injected only while PROVIDER=stripe, the PayPal
#          secret only while ENABLE_PAYPAL=true; none is a plain env var;
#          fake-pay and PayPal are never on in prd (the hub also refuses to
#          boot with them there, internal/payments TestConfigFailClosed).
#          CONTROL: the committed cnf has no real rail, so "not injected"
#          proves nothing alone; scratch renders with each rail on must inject
#          exactly its secrets. A missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }

CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
slots=$(yq -r '.env.payment.secret_env | to_entries | .[].value' "$CNF/all.env.yaml" | sort | tr '\n' ' ')
[[ "$slots" == "csi-spl-hub-paypal-client-secret csi-spl-hub-stripe-secret-key csi-spl-hub-stripe-webhook-secret " ]] \
  && pass "cnf names the 3 payment secret slots" || fail "cnf payment slots: '$slots'"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  envline=$(grep -E '^environment_variables ' "$v")
  secline=$(grep -E '^secret_environment_variables ' "$v")
  for sl in $slots; do
    grep -E '^auth_secret_ids ' "$v" | grep -q "\"$sl\"" || fail "$env 030 lacks the slot $sl"
  done
  pass "$env 030 creates the payment slots"
  grep -qE 'STRIPE_SECRET_KEY|STRIPE_WEBHOOK_SECRET|PAYPAL_CLIENT_SECRET' <<<"$envline" && fail "$env a payment secret is a plain env var" || pass "$env no payment secret is a plain env var"
  inv=$(python3 - "$envline" "$secline" <<'PY'
import json, sys
env = json.loads(sys.argv[1].split("=", 1)[1]); sec = set(json.loads(sys.argv[2].split("=", 1)[1]))
pay = {k for k in sec if k.startswith(("SPOOL_HUB_STRIPE_", "SPOOL_HUB_PAYPAL_"))}
want = set()
if env.get("SPOOL_HUB_PAYMENT_PROVIDER") == "stripe": want |= {"SPOOL_HUB_STRIPE_SECRET_KEY", "SPOOL_HUB_STRIPE_WEBHOOK_SECRET"}
if env.get("SPOOL_HUB_ENABLE_PAYPAL") == "true": want.add("SPOOL_HUB_PAYPAL_CLIENT_SECRET")
print("ok" if pay == want else f"injected {sorted(pay)} != expected {sorted(want)}")
PY
)
  [[ "$inv" == ok ]] && pass "$env injects exactly the payment secrets its rails need" || fail "$env $inv"
done
grep -E '^environment_variables ' "$CNF/prd/tf/030-cloud-run-hub.vars.tfvars" | grep -q '"SPOOL_HUB_ENABLE_PAYPAL": "false"' \
  && pass "prd PayPal is off" || fail "prd PayPal is not \"false\""
grep -E '^environment_variables ' "$CNF/prd/tf/030-cloud-run-hub.vars.tfvars" | grep -q '"SPOOL_HUB_ENABLE_FAKE_PAY": "false"' \
  && pass "prd fake-pay is off" || fail "prd fake-pay is not \"false\""
grep -E '^environment_variables ' "$CNF/dev/tf/030-cloud-run-hub.vars.tfvars" | grep -q '"SPOOL_HUB_ENABLE_FAKE_PAY": "true"' \
  && pass "dev fake-pay is on (M2 dev buys on the fake rail)" || fail "dev fake-pay is not \"true\""

# --- control: the hosted rail injects exactly the payment secret -------------
TPG=""
main_root=$(git -C "$APP_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs -r dirname)
for c in "${TPL_GEN_DIR:-}" "$APP_ROOT/tpl-gen" "${main_root:+$main_root/tpl-gen}"; do
  [[ -n "$c" && -x "$c/src/python/tpl-gen/.venv/bin/python" ]] && { TPG="$c/src/python/tpl-gen"; break; }
done
if [[ -n "$TPG" ]]; then
  tmp=$(mktemp -d)
  # shellcheck disable=SC1091
  source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
  do_spl_merged_cnf "$CNF" prd "$tmp/prd.env.yaml"
  # the controls start from NO payment rail, whatever prd's own provider is
  yq -i '.env.hub.env.SPOOL_HUB_PAYMENT_PROVIDER = "" | .env.hub.env.SPOOL_HUB_ENABLE_PAYPAL = "false"' "$tmp/prd.env.yaml"
  render() { (cd "$TPG" && TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl" CNF="$tmp/prd.env.yaml" \
    .venv/bin/python -c '
import os, yaml, jinja2
cnf = yaml.safe_load(open(os.environ["CNF"]))["env"]
tpl = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(open(os.environ["TPL"]).read())
print(tpl.render(**{**cnf, "ORG": "csi", "APP": "spl", "ENV": "prd"}))' 2>&1); }
  base=$(render | grep -E '^secret_environment_variables ' | grep -oE '"SPOOL_HUB_[A-Z_]+"' | sort | tr '\n' ' ')
  cp "$tmp/prd.env.yaml" "$tmp/base.yaml"
  yq -i '.env.hub.env.SPOOL_HUB_PAYMENT_PROVIDER = "stripe"' "$tmp/prd.env.yaml"
  on=$(render | grep -E '^secret_environment_variables ' | grep -oE '"SPOOL_HUB_[A-Z_]+"' | sort | tr '\n' ' ')
  want=$(printf '%s\n' $base '"SPOOL_HUB_STRIPE_SECRET_KEY"' '"SPOOL_HUB_STRIPE_WEBHOOK_SECRET"' | sort | tr '\n' ' ')
  [[ "$on" == "$want" ]] && pass "control: provider=stripe adds exactly the stripe secret pair" \
    || fail "control: stripe injected '$on', want '$want'"
  cp "$tmp/base.yaml" "$tmp/prd.env.yaml"
  yq -i '.env.hub.env.SPOOL_HUB_ENABLE_PAYPAL = "true"' "$tmp/prd.env.yaml"
  on=$(render | grep -E '^secret_environment_variables ' | grep -oE '"SPOOL_HUB_[A-Z_]+"' | sort | tr '\n' ' ')
  want=$(printf '%s\n' $base '"SPOOL_HUB_PAYPAL_CLIENT_SECRET"' | sort | tr '\n' ' ')
  [[ "$on" == "$want" ]] && pass "control: ENABLE_PAYPAL=true adds exactly the PayPal secret" \
    || fail "control: paypal injected '$on', want '$want'"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
