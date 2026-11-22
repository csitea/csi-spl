#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 123 16.6.3, row L3w (SPL-6223). The hub's cost labels draft
#          through Google Cloud Translation v3 only when it is told where:
#          SPOOL_HUB_COST_LABELS_TRANSLATE_URL (no default in code; "" = 503
#          translate_unavailable), with _TIMEOUT (a Go duration) and
#          _DAILY_CHARS. This test proves the chain cnf -> tfvars -> 030:
#            1. the rendered dev and prd 030 tfvars carry
#               cost_labels_translate_url = <env.cost.labels_translate_api_base>
#               /projects/<env gcp_project>/locations/<labels_translate_location>,
#               cost_labels_translate_timeout = "<labels_translate_timeout_s>s"
#               and cost_labels_translate_daily_chars = <labels_translate_daily_chars>;
#            2. the tpl-gen template renders all three lines;
#            3. 030 declares the three variables, merges the three env vars
#               into local.hub_env only while the url is set, and keeps all
#               three in its template hash (a changed value rolls a revision).
#          RED CONTROLS, each on a copy: a 030 that drops the timeout var, a
#          030 whose hub_env leaves local.translate_env out, a template hash
#          that misses the url, a template that misses the daily cap line, a
#          tfvars whose url names the other env's project: every one fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
tmp_dir
STEP_DIR="$PROJ_ROOT/src/terraform/030-cloud-run-hub"
TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

# cnf_get <env> <key under env.cost>: the env file's value, else all.env.yaml's
cnf_get() {
  local v
  v="$(yq -r ".env.cost.$2 // \"\"" "$CNF/$1.env.yaml")"
  [[ -n "$v" && "$v" != null ]] || v="$(yq -r ".env.cost.$2 // \"\"" "$CNF/all.env.yaml")"
  [[ "$v" == null ]] && v=""
  printf '%s' "$v"
}

# tfvars_gaps <env> <tfvars>: why the tfvars do not carry cnf's three values
tfvars_gaps() {
  local env="$1" v="$2" base loc tmo cap proj url
  base="$(cnf_get "$env" labels_translate_api_base)"
  loc="$(cnf_get "$env" labels_translate_location)"
  tmo="$(cnf_get "$env" labels_translate_timeout_s)"
  cap="$(cnf_get "$env" labels_translate_daily_chars)"
  proj="$(yq -r '.env.gcp.gcp_project // ""' "$CNF/$env.env.yaml")"
  [[ -n "$proj" && "$proj" != null ]] || { echo "no env.gcp.gcp_project in $env.env.yaml"; return 0; }
  url=""
  [[ -n "$base" ]] && url="${base%/}/projects/$proj/locations/$loc"
  grep -qxE "cost_labels_translate_url += \"${url//./\\.}\"" "$v" || echo "url is not '$url'"
  grep -qxE "cost_labels_translate_timeout += \"${tmo}s\"" "$v" || echo "timeout is not '${tmo}s'"
  grep -qxE "cost_labels_translate_daily_chars += ${cap}" "$v" || echo "daily_chars is not '$cap'"
  return 0
}

# tpl_gaps <template>: the translate lines the template does not render
tpl_gaps() {
  local k
  for k in url timeout daily_chars; do
    grep -qE "^cost_labels_translate_$k += \{\{" "$1" || echo "the template renders no cost_labels_translate_$k"
  done
  return 0
}

# step_gaps <variables .tf> <service .tf>: why 030 does not pass the three
step_gaps() {
  local vars="$1" svc="$2" k
  for k in url timeout daily_chars; do
    grep -qE "^variable \"cost_labels_translate_$k\" \{" "$vars" || echo "no variable cost_labels_translate_$k"
  done
  grep -qF 'translate_env = var.cost_labels_translate_url == "" ? {} : { SPOOL_HUB_COST_LABELS_TRANSLATE_URL = var.cost_labels_translate_url, SPOOL_HUB_COST_LABELS_TRANSLATE_TIMEOUT = var.cost_labels_translate_timeout, SPOOL_HUB_COST_LABELS_TRANSLATE_DAILY_CHARS = tostring(var.cost_labels_translate_daily_chars) }' "$svc" ||
    echo "translate_env does not pass the three SPOOL_HUB_COST_LABELS_TRANSLATE_* vars only while the url is set"
  grep -qE '^[[:space:]]*hub_env += merge\(.*, local\.translate_env\)$' "$svc" || echo "hub_env does not merge local.translate_env"
  grep -qE '^[[:space:]]*tr_url += var\.cost_labels_translate_url$' "$svc" || echo "the template hash misses the url"
  grep -qE '^[[:space:]]*tr_timeout += var\.cost_labels_translate_timeout$' "$svc" || echo "the template hash misses the timeout"
  grep -qE '^[[:space:]]*tr_daily_chars += var\.cost_labels_translate_daily_chars$' "$svc" || echo "the template hash misses the daily cap"
  return 0
}

verdict() { # <label> <reasons>
  [[ -z "$2" ]] && pass "$1" || fail "$1: $(tr '\n' ';' <<<"$2")"
}

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  if [[ ! -f "$v" ]]; then fail "1. $env: no $v (ENV=$env ./run -a do_tpl_gen)"; continue; fi
  verdict "1. $env 030 tfvars carry cnf env.cost.labels_translate_* (url in csi-spl-$env)" "$(tfvars_gaps "$env" "$v")"
done
verdict "2. the 030 template renders the three translate lines" "$(tpl_gaps "$TPL")"
verdict "3. 030 declares the three vars, merges them into hub_env while the url is set, and hashes them" \
  "$(step_gaps "$STEP_DIR/02-variables.tf" "$STEP_DIR/04-cloud-run-service.tf")"

# --- RED CONTROLS -------------------------------------------------------------
svc="$STEP_DIR/04-cloud-run-service.tf"
cp "$svc" "$T/no-timeout.tf"
sed -i -E 's/, SPOOL_HUB_COST_LABELS_TRANSLATE_TIMEOUT = var\.cost_labels_translate_timeout//' "$T/no-timeout.tf"
[[ -n "$(step_gaps "$STEP_DIR/02-variables.tf" "$T/no-timeout.tf")" ]] && pass "CONTROL a 030 that drops the timeout var is refused" ||
  fail "CONTROL a 030 without SPOOL_HUB_COST_LABELS_TRANSLATE_TIMEOUT passed"
cp "$svc" "$T/no-merge.tf"
sed -i -E 's/, local\.translate_env\)$/)/' "$T/no-merge.tf"
[[ -n "$(step_gaps "$STEP_DIR/02-variables.tf" "$T/no-merge.tf")" ]] && pass "CONTROL a hub_env without local.translate_env is refused" ||
  fail "CONTROL a hub_env without local.translate_env passed"
cp "$svc" "$T/no-hash.tf"
sed -i -E '/^[[:space:]]*tr_url += /d' "$T/no-hash.tf"
[[ -n "$(step_gaps "$STEP_DIR/02-variables.tf" "$T/no-hash.tf")" ]] && pass "CONTROL a template hash without the url is refused" ||
  fail "CONTROL a template hash without the url passed"
cp "$STEP_DIR/02-variables.tf" "$T/no-var.tf"
sed -i -E 's/^variable "cost_labels_translate_daily_chars"/variable "x_daily_chars"/' "$T/no-var.tf"
[[ -n "$(step_gaps "$T/no-var.tf" "$svc")" ]] && pass "CONTROL a 030 without the daily cap variable is refused" ||
  fail "CONTROL a 030 without the daily cap variable passed"
cp "$TPL" "$T/no-cap.tpl"
sed -i -E '/^cost_labels_translate_daily_chars /d' "$T/no-cap.tpl"
[[ -n "$(tpl_gaps "$T/no-cap.tpl")" ]] && pass "CONTROL a template that misses the daily cap line is refused" ||
  fail "CONTROL a template without the daily cap line passed"
cp "$CNF/dev/tf/030-cloud-run-hub.vars.tfvars" "$T/dev-wrong.tfvars"
sed -i -E 's|/projects/csi-spl-dev/|/projects/csi-spl-prd/|' "$T/dev-wrong.tfvars"
[[ -n "$(tfvars_gaps dev "$T/dev-wrong.tfvars")" ]] && pass "CONTROL a dev tfvars whose url names prd's project is refused" ||
  fail "CONTROL a dev tfvars with prd's project passed"

[[ $fails -eq 0 ]] && echo "PASS: all $(basename "$0") assertions" || { echo "FAIL: $fails"; exit 1; }
