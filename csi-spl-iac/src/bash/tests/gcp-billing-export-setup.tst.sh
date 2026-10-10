#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_billing_export_setup (spec 123 section 4.2, lane 2), offline:
#   1. GCP_BILLING_ACCOUNT_ID malformed, DRY_RUN not 0/1 -> refused before any
#      gcloud or BigQuery call. GCP_BILLING_ACCOUNT_ID unset -> read as the
#      pinned SA from the export project's billing link and the run proceeds;
#      unreadable -> FATAL after that one read, nothing else called.
#   2. DRY_RUN=1 (the default) on an empty estate: every step is printed as
#      "would run", and NO mutating call reaches gcloud or BigQuery.
#      CONTROL: the same stubs under DRY_RUN=0 record the mutations, so the
#      stubs can see one.
#   3. Everything present -> nothing to do (idempotent), still no mutation.
#   4. The identity is a service account: an owner (user) account is refused.
#   5. The billing account id is never logged whole, in any case of this file;
#      the token never reaches curl's argv.
# Stubs: gcloud and curl on PATH (they log their argv), the project / account
# resolvers as functions. Nothing reaches GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
F="$PROJ_ROOT/src/bash/run/gcp-billing-export-setup.func.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/spl-cost-gcp.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

require_action "$F"
bash -n "$F" && bash -n "$LIB" && pass "bash -n the action and its lib" || fail "bash -n"

BILL="0A1B2C-3D4E5F-6A7B8C"
READER="spl-cost-reader@csi-spl-all.iam.gserviceaccount.com"
stub gcloud '
echo "gcloud $*" >>"$LOG"
case "$*" in
  "auth print-access-token"*) echo tok-SECRET-1 ;;
  "billing projects describe"*) [[ -n "${STUB_BILL_FAIL:-}" ]] && { echo "ERROR: PERMISSION_DENIED" >&2; exit 1; }; echo "billingAccounts/$STUB_BILL" ;;
  "services list"*) echo bigquery.googleapis.com; [[ "$STATE" == present ]] && printf "%s\n" bigquerydatatransfer.googleapis.com iamcredentials.googleapis.com ;;
  "iam service-accounts describe"*) [[ "$STATE" == present ]] && { echo "$READER"; exit 0; }; echo "ERROR: NOT_FOUND: Unknown service account" >&2; exit 1 ;;
  "projects get-iam-policy"*) [[ "$STATE" == present ]] && echo "{\"bindings\":[{\"role\":\"roles/bigquery.jobUser\",\"members\":[\"serviceAccount:$READER\"]}]}" || echo "{}" ;;
  "iam service-accounts get-iam-policy"*) [[ "$STATE" == present ]] && echo "{\"bindings\":[{\"role\":\"roles/iam.serviceAccountTokenCreator\",\"members\":[\"serviceAccount:csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com\",\"serviceAccount:csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com\"]}]}" || echo "{}" ;;
esac
exit 0'
stub curl '
m=GET; for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -X ]] && { j=$((i + 1)); m="${!j}"; }; done
url="${!#}"; echo "curl $m ${url#*/v2/} argv: $*" >>"$LOG"; cat >>"$LOG.stdin"
for a in "$@"; do [[ "$m" == PATCH && "$a" == @* ]] && cp "${a#@}" "$LOG.patch"; done
case "$m ${url#*/v2/}" in
  "POST projects/csi-spl-all/datasets") : >"$LOG.created"; printf "{}\n200" ;;
  "GET projects/csi-spl-all/datasets/spl_billing_export")
    [[ -f "$LOG.created" && -n "${READBACK_FAIL:-}" ]] && { printf "{\"error\":{\"message\":\"backend\"}}\n500"; exit 0; }
    if [[ "$STATE" == present ]]; then printf "{\"etag\":\"e\",\"access\":[{\"role\":\"READER\",\"userByEmail\":\"%s\"}]}\n200" "$READER"
    elif [[ -f "$LOG.created" ]]; then printf "{\"etag\":\"e\",\"access\":[{\"role\":\"OWNER\",\"specialGroup\":\"projectOwners\"}]}\n200"
    else printf "{\"error\":{\"message\":\"Not found\"}}\n404"; fi ;;
  "GET projects/csi-spl-all/datasets/spl_billing_export/tables"*)
    [[ "$STATE" == present ]] && printf "{\"tables\":[{\"tableReference\":{\"tableId\":\"gcp_billing_export_v1_0A1B2C_3D4E5F_6A7B8C\"}}]}\n200" || printf "{\"error\":{\"message\":\"Not found\"}}\n404" ;;
  *) printf "{}\n200" ;;
esac'

# run_case <out> [VAR=value ...] - the action in a fresh shell; prints its log and "rc=<n>"
run_case() {
  local out="$1"; shift
  : >"$T/log"; : >"$T/log.stdin"; rm -f "$T/log.created"
  env -u DRY_RUN -u GCP_BILLING_ACCOUNT_ID -u ACCOUNT -u GCP_ACCOUNT PATH="$T/bin:$PATH" LOG="$T/log" STATE=absent \
    STUB_BILL="$BILL" READER="$READER" F="$F" LIB="$LIB" APP_PATH="$APP_ROOT" "$@" bash -c '
    do_log(){ echo "$*"; }
    do_resolve_oap(){ case "$1" in ORG) ORG=csi ;; APP) APP=spl ;; esac; }
    do_gcp_pin_account(){ GCP_ACCOUNT="${STUB_ACCT:-csi-spl-all@csi-spl-all.iam.gserviceaccount.com}"; }
    do_gcp_require_live_account(){ :; }
    source "$LIB"; source "$F"
    do_gcp_billing_export_setup; echo "rc=$?"' >"$out" 2>&1
  cat "$out" "$T/log" >>"$T/all"
}
mutations() { grep -E '^gcloud (services enable|iam service-accounts create|.*add-iam-policy-binding)|^curl (POST|PATCH|PUT|DELETE)' "$T/log"; }

# --- 1. the id: unset is resolved, malformed is refused ------------------------------
# A = the pinned SA of the stubs; the resolve reads as it, nobody else.
A=csi-spl-all@csi-spl-all.iam.gserviceaccount.com
run_case "$T/o"
grep -q '^rc=0$' "$T/o" && grep -q '^OK csi-spl-all is billed by XXXXXX-XXXXXX-6A7B8C (GCP_BILLING_ACCOUNT_ID unset' "$T/o" \
  && [[ "$(grep -c 'DRY_RUN would run' "$T/o")" -eq 7 ]] && [[ -z "$(mutations)" ]] \
  && pass "GCP_BILLING_ACCOUNT_ID unset -> resolved from the billing link, masked 'billed by' line, the dry run proceeds (7 would-run)" \
  || fail "unset id: $(cat "$T/o") / $(cat "$T/log")"
[[ "$(grep -c '^gcloud billing projects describe' "$T/log")" -eq 1 ]] \
  && grep -qx "gcloud billing projects describe csi-spl-all --account=$A --format=value(billingAccountName)" "$T/log" \
  && pass "the resolve is ONE read of csi-spl-all's billing link, --account the pinned SA" \
  || fail "resolve call: $(grep billing "$T/log")"
run_case "$T/o" STUB_BILL_FAIL=1
grep -q 'GCP_BILLING_ACCOUNT_ID is unset and the billing link of csi-spl-all cannot be read' "$T/o" && grep -q '^rc=1$' "$T/o" \
  && [[ "$(cat "$T/log")" == "gcloud billing projects describe"* && "$(wc -l <"$T/log")" -eq 1 ]] \
  && pass "unset + the billing link unreadable -> FATAL rc 1 after that one read, nothing else called" \
  || fail "unset unreadable: $(cat "$T/o") / $(cat "$T/log")"
run_case "$T/o" STUB_BILL=not-an-id
grep -q 'cannot be read' "$T/o" && grep -q '^rc=1$' "$T/o" && [[ "$(wc -l <"$T/log")" -eq 1 ]] \
  && pass "unset + the link names no billing account id -> FATAL rc 1, nothing else called" || fail "unset malformed link: $(cat "$T/o")"
run_case "$T/o" STUB_ACCT=owner@example.com
grep -q 'is no service account' "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "unset + a user (owner) identity -> refused before the billing link is read" || fail "unset owner: $(cat "$T/o") / $(cat "$T/log")"
run_case "$T/o" GCP_BILLING_ACCOUNT_ID=not-an-id
grep -q 'no billing account id' "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "a malformed GCP_BILLING_ACCOUNT_ID -> refused, no call" || fail "malformed id: $(cat "$T/o")"
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL" DRY_RUN=2
grep -q 'DRY_RUN must be 0 or 1' "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "DRY_RUN=2 -> refused, no call" || fail "DRY_RUN=2: $(cat "$T/o")"

# --- 2. the default dry run mutates nothing -----------------------------------------
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL"
n_would=$(grep -c 'DRY_RUN would run' "$T/o")
grep -q '^rc=0$' "$T/o" && [[ "$n_would" -eq 7 ]] \
  && pass "DRY_RUN unset = 1: 7 would-run lines (apis, dataset, SA, dataViewer, jobUser, 2 tokenCreators), rc 0" \
  || fail "dry run: $n_would would-run lines: $(cat "$T/o")"
[[ -z "$(mutations)" ]] && pass "DRY_RUN=1: no mutating gcloud or BigQuery call ($(wc -l <"$T/log") read call(s))" \
  || fail "DRY_RUN=1 mutated: $(mutations)"
grep -q 'datasets.patch .*roles/bigquery.dataViewer.*spl-cost-reader' "$T/o" && ! grep -q 'projects add-iam-policy-binding .*dataViewer' "$T/o" \
  && pass "dataViewer is a DATASET access entry, never a project binding (Q-2)" || fail "dataViewer scope: $(grep -i viewer "$T/o")"
grep -q 'console.cloud.google.com/billing/<GCP_BILLING_ACCOUNT_ID>/export' "$T/o" \
  && pass "the export not on -> the owner's console step is printed" || fail "no console step: $(cat "$T/o")"

# CONTROL: the stubs see a mutation when one happens
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL" DRY_RUN=0
n_mut=$(mutations | wc -l)
grep -q '^rc=0$' "$T/o" && [[ "$n_mut" -eq 7 ]] \
  && pass "CONTROL: DRY_RUN=0 on the same stubs makes the 7 mutations (so a mutation is visible to the check above)" \
  || fail "CONTROL DRY_RUN=0: $n_mut mutation(s): $(mutations) / $(cat "$T/o")"
jq -e --arg m "$READER" '([.access[] | select(.specialGroup == "projectOwners")] | length == 1) and
    ([.access[] | select(.userByEmail == $m and .role == "roles/bigquery.dataViewer")] | length == 1)' "$T/log.patch" >/dev/null 2>&1 \
  && pass "the access patch keeps the dataset's entries and adds the reader's dataViewer" || fail "access patch body: $(cat "$T/log.patch" 2>&1)"

# a failed read-back after the create stops the run: the access list is never
# patched from a read that did not work (a patch REPLACES the whole list)
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL" DRY_RUN=0 READBACK_FAIL=1
grep -q '^rc=1$' "$T/o" && grep -q 'read back csi-spl-all.spl_billing_export' "$T/o" && ! grep -q '^curl PATCH' "$T/log" \
  && pass "DRY_RUN=0, the read-back after the create fails -> rc 1, the access list is not patched" \
  || fail "read-back failure: $(cat "$T/o") / $(grep '^curl' "$T/log")"

# --- 3. idempotent ---------------------------------------------------------------
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL" DRY_RUN=0 STATE=present
grep -q '^rc=0$' "$T/o" && [[ -z "$(mutations)" ]] && ! grep -q 'would run' "$T/o" && grep -q 'the billing export is on' "$T/o" \
  && pass "everything present + DRY_RUN=0 -> nothing to do, no mutation, export reported on" || fail "idempotent: $(mutations) / $(cat "$T/o")"

# --- 4. never the owner account ---------------------------------------------------
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL" STUB_ACCT=owner@example.com
grep -q 'is no service account' "$T/o" && grep -q '^rc=1$' "$T/o" && [[ -z "$(grep -v 'gcloud auth' "$T/log")" ]] \
  && pass "a user (owner) identity is refused before any read" || fail "owner identity: $(cat "$T/o") / $(cat "$T/log")"

# --- 5. no id, no token in the open ----------------------------------------------
run_case "$T/o" GCP_BILLING_ACCOUNT_ID="$BILL" STATE=present
! grep -qF "$BILL" "$T/o" && ! grep -qF "${BILL//-/_}" "$T/o" && grep -q 'XXXXXX-XXXXXX-6A7B8C' "$T/o" \
  && pass "the billing account id is logged masked only" || fail "id leaked: $(grep -F "${BILL:0:6}" "$T/o")"
! grep -q 'tok-SECRET' "$T/log" "$T/o" && grep -q 'Bearer tok-SECRET-1' "$T/log.stdin" \
  && pass "the access token reaches curl on stdin only, never argv or the log" || fail "token in argv/log"

# every case above, every output and every stub call: the id only masked
! grep -qF "$BILL" "$T/all" && ! grep -qF "${BILL//-/_}" "$T/all" \
  && pass "the billing account id appears in no output of any case ($(grep -c '^rc=' "$T/all") runs)" \
  || fail "id leaked: $(grep -F "${BILL:0:6}" "$T/all")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
