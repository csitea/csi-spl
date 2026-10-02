#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every `variable "x"` a step declares is SET in that step's rendered
#          tfvars, in every env: no step silently runs on a terraform default.
#          The value then lives in <env>.env.yaml / all.env.yaml and reaches
#          the tfvars through the step's *.tfvars.tpl and tpl-gen.
#          Keys are the top-level (column 0) assignments of
#          csi-spl-cnf/csi-spl/<env>/tf/<step>.vars.tfvars.
#          Two declared exceptions, each a marker line IN the rendered tfvars
#          (so it is reviewed with the template, never a list in this test):
#          '# prd-only-step' (spec 057: the dev render of a prd-only step,
#          whose env validation refuses dev) skips that env x step, and
#          '# runtime-vars: a,b' names variables set at run time by TF_VAR_*
#          (e.g. billing_account_id from GCP_BILLING_ACCOUNT_ID: never cnf).
#          Control: a copy of 032's dev tfvars with one key dropped MUST fail;
#          a check that passes it proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
TF_DIR="$PROJ_ROOT/src/terraform"
CNF_DIR="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0

declared() { cat "$1"/*.tf | sed -nE 's/^[[:space:]]*variable[[:space:]]+"([^"]+)".*/\1/p' | sort -u; }
set_keys() {
  { sed -nE 's/^([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=.*/\1/p' "$1"
    sed -nE 's/^# runtime-vars: (.*)$/\1/p' "$1" | tr ', ' '\n\n' | sed '/^$/d'; } | sort -u
}
# missing <step-dir> <tfvars>: declared names the tfvars does not set
missing() { comm -23 <(declared "$1") <(set_keys "$2"); }

n=0
for env in dev prd; do
  for d in "$TF_DIR"/[0-9]*/; do
    step=$(basename "$d")
    v="$CNF_DIR/$env/tf/$step.vars.tfvars"
    [[ -f "$v" ]] || { fail "$env $step: no $v"; continue; }
    if [[ "$env" != prd ]] && grep -qx '# prd-only-step' "$v"; then
      pass "$env $step: a prd-only step (its env validation refuses $env)"; continue
    fi
    n=$((n + 1))
    m=$(missing "$d" "$v" | paste -sd, -)
    [[ -z "$m" ]] && pass "$env $step: every declared variable is set" || fail "$env $step: not in tfvars: $m"
  done
done
(( n > 0 )) && pass "$n step x env tfvars checked" || fail "no step tfvars checked"

# --- control: drop one key -> the check must see it ---------------------------
tmp=$(mktemp -d)
src="$CNF_DIR/dev/tf/032-gcp-cloud-run-domain-mapping.vars.tfvars"
grep -v '^cloud_run_service_name[[:space:]]*=' "$src" >"$tmp/032.vars.tfvars"
if [[ "$(missing "$TF_DIR/032-gcp-cloud-run-domain-mapping/" "$tmp/032.vars.tfvars")" == cloud_run_service_name ]]; then
  pass "CONTROL: 032 dev tfvars without cloud_run_service_name is caught"
else
  fail "CONTROL: a dropped cloud_run_service_name was not caught"
fi
rm -rf "$tmp"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
