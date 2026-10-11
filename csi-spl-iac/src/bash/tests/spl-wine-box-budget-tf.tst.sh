#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wine_box_budget_tf, offline (gcloud and make stubbed):
#   1. plan: the billing id is read from the dev project's link as the pinned
#      SA, reaches make only through GCP_BILLING_ACCOUNT_ID, and is never in
#      the output (the stub echoes it: the output masks it).
#   2. TF_VERB=provision runs do-provision; any other verb is refused.
#   3. an unreadable link stops it before make; a set GCP_BILLING_ACCOUNT_ID
#      is used without a gcloud read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
A="$PROJ_ROOT/src/bash/run/spl-wine-box-budget-tf.func.sh"
require_action "$A"
unset TF_VERB ACCOUNT GCP_ACCOUNT GCP_BILLING_ACCOUNT_ID
ID=0A1B2C-3D4E5F-678901
export APP_PATH="$T/app"
do_log() { echo "$*"; }
do_gcp_spl_proj_id() { export PROJ_ID=o-a-dev; }
do_gcp_pin_account() { export GCP_ACCOUNT=o-a-dev@o-a-dev.iam.gserviceaccount.com; }
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gcloud.log"
[[ -n "\${STUB_NO_LINK:-}" ]] && exit 1
echo "billingAccounts/$ID"
STUB
cat >"$T/bin/make" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/make.log"
printf '%s\n' "\${GCP_BILLING_ACCOUNT_ID:-}" > "$T/make.env"
echo "billing_account = \${GCP_BILLING_ACCOUNT_ID:-}"
STUB
chmod +x "$T/bin/gcloud" "$T/bin/make"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1090
source "$A"

# --- 1. plan ------------------------------------------------------------------
out=$(do_spl_wine_box_budget_tf 2>&1); rc=$?
(( rc == 0 )) && grep -qx "billing projects describe o-a-dev --account=o-a-dev@o-a-dev.iam.gserviceaccount.com --format=value(billingAccountName)" "$T/gcloud.log" \
  && pass "the id is read from the project's billing link as the pinned SA" || fail "no pinned link read: rc=$rc $(cat "$T/gcloud.log")"
grep -qx -- "-C $T/app/csi-spl-orc do-tf-plan ENV=dev STEP=058-gcp-wine-box-budget" "$T/make.log" \
  && pass "plan runs make do-tf-plan for 058 in dev" || fail "make call: $(cat "$T/make.log")"
grep -qx "$ID" "$T/make.env" && pass "make gets the id in its environment" || fail "make had no GCP_BILLING_ACCOUNT_ID"
if grep -qF "$ID" <<<"$out"; then fail "the id is in the output"; else pass "the id is never in the output"; fi
grep -q 'billing_account = XXXXXX-XXXXXX-XXXXXX' <<<"$out" && pass "an echoed id is masked" || fail "no masked line: $out"

# --- 2. verbs -----------------------------------------------------------------
: >"$T/make.log"
TF_VERB=provision do_spl_wine_box_budget_tf >/dev/null 2>&1
grep -q ' do-provision ENV=dev STEP=058-gcp-wine-box-budget' "$T/make.log" && pass "TF_VERB=provision applies" || fail "provision: $(cat "$T/make.log")"
if TF_VERB=destroy do_spl_wine_box_budget_tf >/dev/null 2>&1; then fail "TF_VERB=destroy accepted"; else pass "an unknown TF_VERB is refused"; fi

# --- 3. no link / a given id --------------------------------------------------
: >"$T/make.log"
if STUB_NO_LINK=1 do_spl_wine_box_budget_tf >/dev/null 2>&1; then fail "an unreadable link was accepted"; else pass "an unreadable link stops it"; fi
[[ -s "$T/make.log" ]] && fail "make ran without an id" || pass "make does not run without an id"
: >"$T/gcloud.log"
GCP_BILLING_ACCOUNT_ID=$ID do_spl_wine_box_budget_tf >/dev/null 2>&1
grep -q 'billing projects describe' "$T/gcloud.log" && fail "a set GCP_BILLING_ACCOUNT_ID was re-read" || pass "a set GCP_BILLING_ACCOUNT_ID is used as is"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
