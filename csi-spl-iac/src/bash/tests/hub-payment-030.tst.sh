#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 006 T020/T022 -- the M2 payment settings as 030 renders them:
#          the payment secret has an EMPTY slot in every env and is injected
#          only while SPOOL_HUB_PAYMENT_PROVIDER=hosted-hmac; it is never a
#          plain env var; fake-pay is never on in prd (the hub also refuses
#          to boot with it there, internal/payments TestConfigFailClosed).
#          CONTROL: the committed cnf has no hosted rail, so "not injected"
#          proves nothing alone; a scratch render with the rail on must inject
#          exactly the payment secret. A missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }

CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
slot=$(yq -r '.env.payment.secret_env.SPOOL_HUB_PAYMENT_SECRET_KEY // ""' "$CNF/all.env.yaml")
[[ "$slot" == csi-spl-hub-payment-secret-key ]] && pass "cnf names the payment secret slot" || fail "cnf payment slot: '$slot'"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  envline=$(grep -E '^environment_variables ' "$v")
  secline=$(grep -E '^secret_environment_variables ' "$v")
  grep -E '^auth_secret_ids ' "$v" | grep -q "\"$slot\"" && pass "$env 030 creates the payment slot" || fail "$env 030 lacks the payment slot"
  grep -q 'SPOOL_HUB_PAYMENT_SECRET_KEY' <<<"$envline" && fail "$env payment secret is a plain env var" || pass "$env payment secret is not a plain env var"
  provider=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1].split("=",1)[1]).get("SPOOL_HUB_PAYMENT_PROVIDER",""))' "$envline")
  if [[ "$provider" == hosted-hmac ]]; then
    grep -q '"SPOOL_HUB_PAYMENT_SECRET_KEY"' <<<"$secline" && pass "$env hosted rail injects the payment secret" || fail "$env hosted rail without its secret"
  else
    grep -q 'SPOOL_HUB_PAYMENT_SECRET_KEY' <<<"$secline" && fail "$env injects the payment secret with provider '$provider'" \
      || pass "$env provider '$provider': payment secret not injected (no version needed)"
  fi
done
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
  render() { (cd "$TPG" && TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl" CNF="$tmp/prd.env.yaml" \
    .venv/bin/python -c '
import os, yaml, jinja2
cnf = yaml.safe_load(open(os.environ["CNF"]))["env"]
tpl = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(open(os.environ["TPL"]).read())
print(tpl.render(**{**cnf, "ORG": "csi", "APP": "spl", "ENV": "prd"}))' 2>&1); }
  base=$(render | grep -E '^secret_environment_variables ' | grep -oE '"SPOOL_HUB_[A-Z_]+"' | sort | tr '\n' ' ')
  yq -i '.env.hub.env.SPOOL_HUB_PAYMENT_PROVIDER = "hosted-hmac"' "$tmp/prd.env.yaml"
  on=$(render | grep -E '^secret_environment_variables ' | grep -oE '"SPOOL_HUB_[A-Z_]+"' | sort | tr '\n' ' ')
  want=$(printf '%s\n' $base '"SPOOL_HUB_PAYMENT_SECRET_KEY"' | sort | tr '\n' ' ')
  [[ "$on" == "$want" ]] && pass "control: provider=hosted-hmac adds exactly the payment secret" \
    || fail "control: hosted-hmac injected '$on', want '$want'"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
