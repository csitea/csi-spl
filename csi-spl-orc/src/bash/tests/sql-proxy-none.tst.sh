#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_sql_proxy_start is the db_proxy start seam (spec 076 T005).
#   1. SPOOL_CLOUD_PROVIDER=none -> rc 0 at once, SPL_PROXY_PORT=5432 (even
#      over a preset port), SPL_PROXY_DSN=$SPOOL_HUB_DB_DSN, and NOTHING
#      started: no cloud-sql-proxy, no docker, no gcloud call, no background
#      job left in the shell; spl_sql_proxy_stop afterwards touches nothing.
#   2. env.cloud.provider: none in the cnf ($SPL_CNF) -> the same no-op.
#   3. control: under gcp the same stubs ARE reached (gcloud token, then
#      cloud-sql-proxy), so the silence in 1 and 2 is the seam, not a stub that
#      could not be called. gcp's full behaviour: sql-proxy-port.tst.sh.
# No GCP, no docker, no network: gcloud, cloud-sql-proxy and docker are stubs
# that record every call.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub" "$T/state"
for b in gcloud cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\necho tok\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*
printf 'env:\n  cloud:\n    provider: none\n' >"$T/none.yaml"

# start [VAR=value]... - spl-cloud-cnf sourced in a fresh bash, then
# spl_sql_proxy_start; prints its log, "RC=<rc> PORT=<port> DSN=<dsn>" and
# "JOBS=<n background jobs>", then stops the proxy.
start() {
  env -u SPOOL_CLOUD_PROVIDER -u SPL_CNF -u APP_PATH T="$T" STUB_LOG="$T/calls.log" SPL_STATE_DIR="$T/state" \
    PATH="$T/stub:$PATH" GCP_ACCOUNT=sa@example.com SPL_SQL_CONN=p:r:i SPL_ORG_APP=csi-spl ENV=dev \
    SPL_SQL_PROXY_IMAGE=img SPOOL_HUB_DB_DSN='postgres://u:pw@db:5432/spool?sslmode=disable' "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
    spl_sql_proxy_start; rc=$?
    echo "RC=$rc PORT=${SPL_PROXY_PORT:-} DSN=${SPL_PROXY_DSN:-}"
    echo "JOBS=$(jobs -p | wc -l)"
    spl_sql_proxy_stop
    wait'
}
export PROJ_ROOT
want_dsn='postgres://u:pw@db:5432/spool?sslmode=disable'

# check_none <label> <out>: the none verdicts on one run's output
check_none() {
  local label="$1" out="$2"
  grep -qx "RC=0 PORT=5432 DSN=$want_dsn" <<<"$out" \
    && pass "$label: rc 0, SPL_PROXY_PORT=5432, SPL_PROXY_DSN=\$SPOOL_HUB_DB_DSN" \
    || fail "$label: $(tr '\n' ' ' <<<"$out")"
  grep -qx "JOBS=0" <<<"$out" && pass "$label: no background process" || fail "$label: a background job: $(tr '\n' ' ' <<<"$out")"
  [[ ! -s "$T/calls.log" ]] && pass "$label: no gcloud, cloud-sql-proxy or docker call" \
    || fail "$label: a cloud call under none: $(tr '\n' ' ' <"$T/calls.log")"
}

# --- 1. SPOOL_CLOUD_PROVIDER=none -------------------------------------------
: >"$T/calls.log"
check_none "SPOOL_CLOUD_PROVIDER=none" "$(start SPOOL_CLOUD_PROVIDER=none 2>&1)"
: >"$T/calls.log"
check_none "none over a preset SPL_PROXY_PORT" "$(start SPOOL_CLOUD_PROVIDER=none SPL_PROXY_PORT=6543 2>&1)"

# --- 2. env.cloud.provider: none in the effective cnf -----------------------
: >"$T/calls.log"
check_none "cnf env.cloud.provider none" "$(start SPL_CNF="$T/none.yaml" 2>&1)"

# --- 3. control: gcp reaches the stubs ---------------------------------------
: >"$T/calls.log"
out=$(start SPOOL_CLOUD_PROVIDER=gcp 2>&1)
grep -q '^gcloud auth print-access-token' "$T/calls.log" && grep -q '^cloud-sql-proxy --address 127.0.0.1' "$T/calls.log" \
  && pass "control: under gcp the gcloud and cloud-sql-proxy stubs are called" \
  || fail "control: gcp did not reach the stubs: $(tr '\n' ' ' <"$T/calls.log") / $(tr '\n' ' ' <<<"$out")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
