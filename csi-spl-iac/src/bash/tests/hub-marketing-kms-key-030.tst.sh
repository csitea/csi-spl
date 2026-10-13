#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 090 T006 (SPL-1634) -- the KMS key that seals LinkedIn member
#          tokens reaches the hub as SPOOL_HUB_MARKETING_KMS_KEY, the full
#          CryptoKey name of step 055's key, only while cnf
#          marketing.kms_key.inject is "true"; and never otherwise.
#          CONTROL: the name is built from the same cnf the 055 tfvars carry.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ENVVAR=SPOOL_HUB_MARKETING_KMS_KEY
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
grep -qF "env:\"$ENVVAR\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
  && pass "the hub reads exactly $ENVVAR (config.go MarketingKMSKey)" || fail "config.go does not name $ENVVAR"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  k="$CNF/$env/tf/055-gcp-kms-marketing.vars.tfvars"
  inject=$(yq -r '.env.marketing.kms_key.inject // "false"' "$CNF/$env.env.json")
  tfv() { sed -nE "s/^$1 *= *\"(.*)\"/\\1/p" "$k"; }
  want="projects/$(tfv gcp_project)/locations/$(tfv gcp_region)/keyRings/$(tfv key_ring)/cryptoKeys/$(tfv crypto_key)"
  line=$(grep -E '^environment_variables ' "$v")
  if [[ "$inject" == "true" ]]; then
    grep -F "\"$ENVVAR\": \"$want\"" <<<"$line" >/dev/null \
      && pass "$env 030 carries $ENVVAR = 055's key ($want)" || fail "$env 030 lacks $ENVVAR=\"$want\""
  else
    grep -qF "\"$ENVVAR\"" <<<"$line" && fail "$env 030 carries $ENVVAR while inject is $inject" \
      || pass "$env 030 has no $ENVVAR (inject $inject)"
  fi
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
