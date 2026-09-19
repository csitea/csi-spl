#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every `variable "x"` a step declares is SET in that step's rendered
#          tfvars, in every env: no step silently runs on a terraform default.
#          The value then lives in <env>.env.yaml / all.env.yaml and reaches
#          the tfvars through the step's *.tfvars.tpl and tpl-gen.
#          Keys are the top-level (column 0) assignments of
#          csi-spl-cnf/csi-spl/<env>/tf/<step>.vars.tfvars.
#          Control: a copy of 031's dev tfvars with one key dropped MUST fail;
#          a check that passes it proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
TF_DIR="$PROJ_ROOT/src/terraform"
CNF_DIR="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

declared() { cat "$1"/*.tf | sed -nE 's/^[[:space:]]*variable[[:space:]]+"([^"]+)".*/\1/p' | sort -u; }
set_keys() { sed -nE 's/^([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=.*/\1/p' "$1" | sort -u; }
# missing <step-dir> <tfvars>: declared names the tfvars does not set
missing() { comm -23 <(declared "$1") <(set_keys "$2"); }

n=0
for env in dev prd; do
  for d in "$TF_DIR"/[0-9]*/; do
    step=$(basename "$d")
    v="$CNF_DIR/$env/tf/$step.vars.tfvars"
    [[ -f "$v" ]] || { fail "$env $step: no $v"; continue; }
    n=$((n + 1))
    m=$(missing "$d" "$v" | paste -sd, -)
    [[ -z "$m" ]] && pass "$env $step: every declared variable is set" || fail "$env $step: not in tfvars: $m"
  done
done
(( n > 0 )) && pass "$n step x env tfvars checked" || fail "no step tfvars checked"

# --- control: drop one key -> the check must see it ---------------------------
tmp=$(mktemp -d)
src="$CNF_DIR/dev/tf/031-gcp-hub-ingress.vars.tfvars"
grep -v '^hub_path_regex[[:space:]]*=' "$src" >"$tmp/031.vars.tfvars"
if [[ "$(missing "$TF_DIR/031-gcp-hub-ingress/" "$tmp/031.vars.tfvars")" == hub_path_regex ]]; then
  pass "CONTROL: 031 dev tfvars without hub_path_regex is caught"
else
  fail "CONTROL: a dropped hub_path_regex was not caught"
fi
rm -rf "$tmp"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
