#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cloud_provider (spec 076 T002) prints the cloud provider.
#   1. the real cnf says gcp for dev, prd and lde (GCP stays the default)
#   2. SPOOL_CLOUD_PROVIDER overrides the cnf; an unknown value is refused
#   3. $SPL_CNF (the merged cnf) is read when set; a cnf without the key is gcp
#   4. the root docker-compose.yml runs the hub as provider none
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

expect() {
  local name="$1" want="$2" out; shift 2
  out=$(SNIPPET='do_spl_cloud_provider' in_orc "$@" 2>&1)
  [[ "$out" == "$want" ]] && pass "$name: $want" || fail "$name: want '$want', got '$out'"
}

# --- 1. the real cnf ------------------------------------------------------------
for e in dev prd lde; do expect "cnf ENV=$e" gcp ENV="$e"; done

# --- 2. the override --------------------------------------------------------------
for p in none aws gcp; do expect "SPOOL_CLOUD_PROVIDER=$p" "$p" SPOOL_CLOUD_PROVIDER="$p"; done
SNIPPET='do_spl_cloud_provider' in_orc SPOOL_CLOUD_PROVIDER=azure >/dev/null 2>&1 &&
  fail "SPOOL_CLOUD_PROVIDER=azure was accepted" || pass "SPOOL_CLOUD_PROVIDER=azure is refused"

# --- 3. the merged cnf --------------------------------------------------------------
printf 'env:\n  cloud:\n    provider: none\n' >"$T/none.yaml"
printf 'env:\n  dns:\n    BASE_DOMAIN: example.com\n' >"$T/nokey.yaml"
printf 'env:\n  cloud:\n    provider: azure\n' >"$T/azure.yaml"
expect "SPL_CNF provider none" none SPL_CNF="$T/none.yaml"
expect "SPL_CNF without the key" gcp SPL_CNF="$T/nokey.yaml"
SNIPPET='do_spl_cloud_provider' in_orc SPL_CNF="$T/azure.yaml" >/dev/null 2>&1 &&
  fail "a cnf provider azure was accepted" || pass "a cnf provider azure is refused"

# --- 4. compose ------------------------------------------------------------------------
yq -e '.services.hub.environment.SPOOL_CLOUD_PROVIDER == "none"' "$APP_ROOT/docker-compose.yml" >/dev/null &&
  pass "docker-compose.yml hub: SPOOL_CLOUD_PROVIDER=none" || fail "docker-compose.yml hub lacks SPOOL_CLOUD_PROVIDER=none"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
