#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_cloud_billing_api_enable, offline (gcloud stubbed):
#   1. DRY_RUN is the default: lists, enables nothing, says what it would run.
#   2. DRY_RUN=0 enables cloudbilling.googleapis.com with --account.
#   3. already on: no enable call, even with DRY_RUN=0.
#   4. a failed list stops it; a bad DRY_RUN value is refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
A="$PROJ_ROOT/src/bash/run/gcp-cloud-billing-api-enable.func.sh"
require_action "$A"
unset DRY_RUN ACCOUNT GCP_ACCOUNT
do_log() { echo "$*"; }
do_gcp_spl_proj_id() { export PROJ_ID=o-a-dev; }
do_gcp_pin_account() { export GCP_ACCOUNT=o-a-dev@o-a-dev.iam.gserviceaccount.com; }
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gcloud.log"
[[ "\$*" == *"services list"* ]] && { [[ -n "\${STUB_LIST_FAIL:-}" ]] && exit 1; printf '%b' "\${STUB_ENABLED:-}"; }
exit 0
STUB
chmod +x "$T/bin/gcloud"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1090
source "$A"

# --- 1. dry run ---------------------------------------------------------------
: >"$T/gcloud.log"
out=$(STUB_ENABLED='compute.googleapis.com\n' do_gcp_cloud_billing_api_enable 2>&1); rc=$?
(( rc == 0 )) && grep -q 'DRY_RUN would run: gcloud services enable cloudbilling.googleapis.com' <<<"$out" \
  && ! grep -q '^services enable' "$T/gcloud.log" \
  && pass "DRY_RUN is the default and enables nothing" || fail "dry run: rc=$rc out=$out"

# --- 2. enable ----------------------------------------------------------------
: >"$T/gcloud.log"
STUB_ENABLED='compute.googleapis.com\n' DRY_RUN=0 do_gcp_cloud_billing_api_enable >/dev/null 2>&1
grep -qx 'services enable cloudbilling.googleapis.com --project=o-a-dev --account=o-a-dev@o-a-dev.iam.gserviceaccount.com' "$T/gcloud.log" \
  && pass "DRY_RUN=0 enables the API as the pinned project SA" || fail "no pinned enable call: $(cat "$T/gcloud.log")"
grep -qv -- '--account=' "$T/gcloud.log" \
  && fail "a gcloud call without --account" || pass "every gcloud call carries --account"

# --- 3. already on ------------------------------------------------------------
: >"$T/gcloud.log"
out=$(STUB_ENABLED='cloudbilling.googleapis.com\n' DRY_RUN=0 do_gcp_cloud_billing_api_enable 2>&1)
grep -q 'already enabled' <<<"$out" && ! grep -q '^services enable' "$T/gcloud.log" \
  && pass "already on: nothing is enabled" || fail "already on: $out"

# --- 4. refusals --------------------------------------------------------------
if STUB_LIST_FAIL=1 DRY_RUN=0 do_gcp_cloud_billing_api_enable >/dev/null 2>&1; then fail "a failed list was accepted"; else pass "a failed list stops it"; fi
if DRY_RUN=2 do_gcp_cloud_billing_api_enable >/dev/null 2>&1; then fail "DRY_RUN=2 was accepted"; else pass "a bad DRY_RUN is refused"; fi

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
