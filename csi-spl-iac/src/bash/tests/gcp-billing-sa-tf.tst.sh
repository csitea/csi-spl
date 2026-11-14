#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_billing_sa_tf (SPL-5506, owner a508c121), offline (gcloud
#          and make stubbed):
#   1. plan: the ids are listed as the pinned csi-spl-all SA, reach make only
#      through GCP_BILLING_ACCOUNT_IDS (comma separated), and are never in the
#      output (the make stub echoes them: the output masks each one).
#   2. TF_VERB=provision runs do-provision; any other verb is refused.
#   3. fails fast: no account listed, or an id that is no billing account id,
#      stops it before make; a set GCP_BILLING_ACCOUNT_IDS is used without a
#      gcloud read.
#   CONTROL: the same make output without the mask carries an id (the masking
#   check sees a leak when there is one).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
A="$PROJ_ROOT/src/bash/run/gcp-billing-sa-tf.func.sh"
require_action "$A"
unset TF_VERB ACCOUNT GCP_ACCOUNT GCP_BILLING_ACCOUNT_IDS
ID1=0A1B2C-3D4E5F-678901
ID2=ABCDEF-012345-6789AB
SA=o-a-all@o-a-all.iam.gserviceaccount.com
export APP_PATH="$T/app"
do_log() { echo "$*"; }
do_resolve_oap() { :; }
# shellcheck disable=SC2034 # read by the sourced action
do_gcp_billing_cnf() { BILL_PROJECT=o-a-all; BILL_EMAIL=b@o-a-all.iam.gserviceaccount.com; }
do_gcp_pin_account() { [[ "${PROJ_ID:-}" == o-a-all ]] && export GCP_ACCOUNT=$SA; }
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gcloud.log"
[[ -n "\${STUB_NONE:-}" ]] && exit 0
printf '%s\n' "billingAccounts/$ID1" "billingAccounts/$ID2"
STUB
cat >"$T/bin/make" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/make.log"
printf '%s\n' "\${GCP_BILLING_ACCOUNT_IDS:-}" > "$T/make.env"
IFS=, read -ra l <<<"\${GCP_BILLING_ACCOUNT_IDS:-}"
for i in "\${l[@]}"; do echo "  + google_billing_account_iam_member.billing_viewer[\"\$i\"]"; done
STUB
chmod +x "$T/bin/gcloud" "$T/bin/make"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1090
source "$A"

# --- 1. plan ------------------------------------------------------------------
out=$(do_gcp_billing_sa_tf 2>&1); rc=$?
(( rc == 0 )) && grep -qx "billing accounts list --account=$SA --format=value(name)" "$T/gcloud.log" \
  && pass "the ids are listed as the pinned csi-spl-all SA" || fail "no pinned list: rc=$rc $(cat "$T/gcloud.log" 2>/dev/null) $out"
grep -qx -- "-C $T/app/csi-spl-orc do-tf-plan ENV=prd STEP=002-gcp-billing-sa" "$T/make.log" \
  && pass "plan runs make do-tf-plan for 002 in prd" || fail "make call: $(cat "$T/make.log" 2>/dev/null)"
grep -qx "$ID1,$ID2" "$T/make.env" && pass "make gets both ids, comma separated, in its environment" || fail "make env: $(cat "$T/make.env" 2>/dev/null)"
if grep -qE "$ID1|$ID2" <<<"$out"; then fail "an id is in the output"; else pass "no id is ever in the output"; fi
[[ $(grep -c 'billing_viewer\["XXXXXX-XXXXXX-XXXXXX"\]' <<<"$out") == 2 ]] && pass "each echoed id is masked" || fail "masked lines: $out"
grep -q '2 billing account(s)' <<<"$out" && pass "the count is logged" || fail "no count: $out"

# --- 2. verbs -----------------------------------------------------------------
: >"$T/make.log"
TF_VERB=provision do_gcp_billing_sa_tf >/dev/null 2>&1
grep -q ' do-provision ENV=prd STEP=002-gcp-billing-sa' "$T/make.log" && pass "TF_VERB=provision applies" || fail "provision: $(cat "$T/make.log")"
if TF_VERB=destroy do_gcp_billing_sa_tf >/dev/null 2>&1; then fail "TF_VERB=destroy accepted"; else pass "an unknown TF_VERB is refused"; fi

# --- 3. fail fast / a given list ----------------------------------------------
: >"$T/make.log"
if STUB_NONE=1 do_gcp_billing_sa_tf >/dev/null 2>&1; then fail "no listed account was accepted"; else pass "no listed account stops it"; fi
[[ -s "$T/make.log" ]] && fail "make ran without an id" || pass "make does not run without an id"
if GCP_BILLING_ACCOUNT_IDS="$ID1,not-an-id" do_gcp_billing_sa_tf >/dev/null 2>&1; then fail "a bad id was accepted"; else pass "a bad id stops it"; fi
[[ -s "$T/make.log" ]] && fail "make ran with a bad id" || pass "make does not run with a bad id"
: >"$T/gcloud.log"
GCP_BILLING_ACCOUNT_IDS="$ID2" do_gcp_billing_sa_tf >/dev/null 2>&1
grep -q 'billing accounts list' "$T/gcloud.log" && fail "a set GCP_BILLING_ACCOUNT_IDS was re-read" || pass "a set GCP_BILLING_ACCOUNT_IDS is used as is"
grep -qx "$ID2" "$T/make.env" && pass "make gets the given id" || fail "make env: $(cat "$T/make.env")"

# --- CONTROL ------------------------------------------------------------------
raw=$(GCP_BILLING_ACCOUNT_IDS="$ID1" make 2>&1)
grep -qF "$ID1" <<<"$raw" && pass "control: the unmasked make output carries the id" || fail "control: the stub echoes no id: $raw"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
