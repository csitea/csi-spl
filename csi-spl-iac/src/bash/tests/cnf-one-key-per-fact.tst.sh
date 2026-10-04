#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 072 A44 (research 04 C4, C5): the cnf states each fact once.
#          1. no terraform step setting is written in BOTH dev.env.yaml and
#             prd.env.yaml with the same value: a shared one lives once, in
#             all.env.yaml env.steps (KEEP below names the exceptions and why)
#          2. the GitHub repository is one key (017 github_repository); 120
#             gh_repo is derived from it by do_spl_merged_cnf
#          3. every per-env slot (~) of all.env.yaml env.steps is filled by
#             every cloud env, and lde (no terraform) gets no env.steps
#          The renders staying byte-identical is tf-steps-render-and-validate's
#          and tpl-gen-step-render-parity's job, not this test's.
#
#          CONTROLS: a scratch cnf with one identical step key planted in both
#          env files, and one with an empty slot, must each be caught.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Kept per env on purpose although dev = prd today:
#   005, 046, 059, 060   our estate's own data (072 A12 makes them optional)
#   019 wui_default_tenant / wui_tenant_hosts: the tenant-host actions read
#                        them from <env>.env.yaml itself, not from the merge
#   052 workspaces       each env's own workspace list; its entries match only
#                        by chance (t1, the apex of both), never as one fact
KEEP='^(00[5]-|046-|059-|060-|019-firebase-static-site\.wui_(default_tenant|tenant_hosts) |052-gcs-workspace-docs\.workspaces\.)'

# same_step_keys <cnf dir> -> each env.steps leaf dev and prd set to one value
same_step_keys() {
  comm -12 <(yq -o=props '.env.steps' "$1/dev.env.yaml" | grep -v '^#' | sort) \
           <(yq -o=props '.env.steps' "$1/prd.env.yaml" | grep -v '^#' | sort) | grep -Ev "$KEEP"
}

# null_slots <merged yaml> -> each env.steps leaf still null after the merge
null_slots() {
  yq '.env.steps | .. | select(tag == "!!null") | path | join(".")' "$1" | grep -v '^$'
}

# --- 1. one place for a shared step setting ---------------------------------------
same=$(same_step_keys "$CNF")
[[ -z "$same" ]] && pass "no step setting is written twice (dev = prd): shared ones live in all.env.yaml" ||
  fail "dev and prd both write these step settings with one value (move them to all.env.yaml env.steps): $(tr '\n' ';' <<<"$same")"

# --- 2. the GitHub repository is one key --------------------------------------------
n=$(cat "$CNF"/*.env.yaml | grep -cE '^\s*(gh_repo|github_repository):')
[[ "$n" == 1 ]] && pass "the GitHub repository is written once in the cnf" || fail "github_repository / gh_repo written $n times, want 1"

# --- 3. merged: 120 derived, every slot filled, lde without steps ----------------------
for env in dev prd; do
  m="$tmp/$env.yaml"
  do_spl_merged_cnf "$CNF" "$env" "$m" || { fail "$env: cannot merge cnf"; continue; }
  repo=$(yq -r '.env.steps."017-github-wif-deploy".github_repository // ""' "$m")
  got=$(yq -r '.env.steps."120-github-general-secrets".gh_repo // ""' "$m")
  [[ -n "$repo" && "$got" == "$repo" ]] && pass "$env 120 gh_repo = 017 github_repository ($got)" ||
    fail "$env 120 gh_repo '$got' is not 017 github_repository '$repo'"
  slots=$(null_slots "$m")
  [[ -z "$slots" ]] && pass "$env fills every per-env slot of all.env.yaml env.steps" ||
    fail "$env leaves these all.env.yaml slots empty (set them in $env.env.yaml): $(tr '\n' ' ' <<<"$slots")"
done
do_spl_merged_cnf "$CNF" lde "$tmp/lde.yaml" || fail "lde: cannot merge cnf"
[[ "$(yq '.env.steps | tag' "$tmp/lde.yaml")" == '!!null' ]] && pass "lde (no terraform) gets no env.steps" ||
  fail "lde got env.steps from all.env.yaml"

# --- CONTROLS: a planted duplicate and an empty slot are caught ------------------------
mkdir -p "$tmp/ctl"
cp "$CNF"/all.env.yaml "$CNF"/dev.env.yaml "$CNF"/prd.env.yaml "$tmp/ctl/"
for e in dev prd; do yq -i '.env.steps."020-gcp-relay-bucket".object_max_age_days = 3' "$tmp/ctl/$e.env.yaml"; done
grep -q '^020-gcp-relay-bucket.object_max_age_days = 3$' <<<"$(same_step_keys "$tmp/ctl")" &&
  pass "CONTROL: a step setting planted in both env files is caught" || fail "CONTROL: a planted duplicate was not caught"
yq -i 'del(.env.steps."020-gcp-relay-bucket".relay_bucket_name)' "$tmp/ctl/dev.env.yaml"
do_spl_merged_cnf "$tmp/ctl" dev "$tmp/ctl.yaml" &&
  grep -qx 'env.steps.020-gcp-relay-bucket.relay_bucket_name' <(null_slots "$tmp/ctl.yaml") &&
  pass "CONTROL: an env file that leaves a slot empty is caught" || fail "CONTROL: an empty slot was not caught"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
