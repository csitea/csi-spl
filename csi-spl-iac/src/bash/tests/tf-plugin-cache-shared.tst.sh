#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2821, one terraform plugin cache for every env + step.
#   1. do_tf_init for dev/010-a and prd/020-b -> terraform init sees the SAME
#      TF_PLUGIN_CACHE_DIR, $HOME/.terraform.d/plugin-cache.
#      CONTROL: the same run with the old per-step export line puts the two
#      inits in two caches, so assertion 1 can fail.
#   2. init runs under the flock beside the cache; plan does not take it.
#   3. two inits of two different steps at once are serialised (the cache is
#      not safe for concurrent init writers): their stub runs never overlap.
#          No terraform, no network: terraform and tfswitch are stubs.
# TF_INIT_SRC (optional) - the tf-init.func.sh under test (red runs).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC="${TF_INIT_SRC:-$PROJ_ROOT/src/bash/run/tf-init.func.sh}"
require_action "$SRC"
command -v flock >/dev/null || { echo "FAIL: no flock on PATH"; exit 1; }

# terraform: records the cache dir and whether the init lock is held, and for
# init a start/end pair around a short sleep (overlap check)
stub terraform 'lock=free; flock -n "${TF_PLUGIN_CACHE_DIR%/}.lock" true || lock=held
echo "$1 $2 cache=$TF_PLUGIN_CACHE_DIR lock=$lock" >>"$CALLS"
if [ "$2" = init ]; then echo "start $STEP" >>"$CALLS.seq"; sleep 0.4; echo "end $STEP" >>"$CALLS.seq"; fi
exit 0'
stub tfswitch 'exit 0'
stub git 'echo deadbee'

A="$T/app"; P="$A/csi-spl-iac"
for s in 010-a 020-b; do mkdir -p "$P/src/terraform/$s"; echo "# $s" >"$P/src/terraform/$s/main.tf"; done
mkdir -p "$P/src/terraform/modules/m"; echo "# m" >"$P/src/terraform/modules/m/main.tf"

# step_init <env> <step> <subcommand>: do_tf_init, then terraform <sub> in the run dir
step_init() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" CALLS="$T/calls" PROJ_PATH="$P" APP_PATH="$A" \
    BASE_PATH="$T" ORG_PATH="$T" ORG=csi APP=spl ENV="$1" STEP="$2" ACTION=provision \
    GCP_PROJECT=p TERRAFORM_VERSION=1.0.0 INFRA_VERSION=0 SRC="$SRC" SUB="$3" bash -c '
    set -u
    do_log() { :; }; do_require_var() { :; }; quit_on() { :; }
    do_export_json_section_vars() { :; }; do_export_json_section_vars_as_tf_vars() { :; }
    source "$SRC"
    do_tf_init && terraform -chdir="$tf_run_path" "$SUB" -input=false'
}

# --- 1. two step inits share one cache ---------------------------------------
step_init dev 010-a init; step_init prd 020-b init
mapfile -t caches < <(sed -n 's/^.* init cache=\([^ ]*\) .*/\1/p' "$T/calls")
if [[ ${#caches[@]} == 2 && "${caches[0]}" == "${caches[1]}" && "${caches[0]}" == "$T/home/.terraform.d/plugin-cache" ]]; then
  pass "dev/010-a and prd/020-b init into one cache: ${caches[0]#$T/}"
else
  fail "the two step inits use one cache (got: ${caches[*]:-none})"
fi

# CONTROL: the old per-step line -> two caches, the check above would fail
sed 's|export TF_PLUGIN_CACHE_DIR=.*|export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache/$ORG/$APP/$ENV/$STEP"|' "$SRC" >"$T/old-tf-init.func.sh"
: >"$T/calls"
SRC="$T/old-tf-init.func.sh" step_init dev 010-a init; SRC="$T/old-tf-init.func.sh" step_init prd 020-b init
mapfile -t old < <(sed -n 's/^.* init cache=\([^ ]*\) .*/\1/p' "$T/calls")
[[ ${#old[@]} == 2 && "${old[0]}" != "${old[1]}" ]] \
  && pass "control: the old per-step line gives two caches (${old[0]#$T/home/}, ${old[1]#$T/home/})" \
  || fail "control: the old per-step line should give two caches (got: ${old[*]:-none})"

# --- 2. init holds the lock, plan does not -------------------------------------
: >"$T/calls"
step_init dev 010-a init; step_init dev 010-a plan
grep -q '^-chdir=.* init .* lock=held$' "$T/calls" && pass "init runs under the cache lock" \
  || fail "init runs under the cache lock ($(cat "$T/calls"))"
grep -q '^-chdir=.* plan .* lock=free$' "$T/calls" && pass "plan does not take the init lock" \
  || fail "plan does not take the init lock ($(cat "$T/calls"))"

# --- 3. two different steps at once: the inits never overlap ----------------
: >"$T/calls.seq"
step_init dev 010-a init & step_init prd 020-b init & wait
seq=$(awk '{print $1}' "$T/calls.seq" | paste -sd' ' -)
[[ "$seq" == "start end start end" ]] && pass "two concurrent step inits are serialised ($seq)" \
  || fail "two concurrent step inits are serialised (got: $seq)"

echo "---"
((fails == 0)) && { echo "OK: tf-plugin-cache-shared"; exit 0; }
echo "FAILED: $fails"; exit 1
