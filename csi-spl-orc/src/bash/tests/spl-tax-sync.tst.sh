#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-6438 do_spl_tax_sync (spec 143 taxes-tab.md S4), with the hub
# call stubbed (the hub side is internal/hub/tax_test.go). Every row of the
# index below is invented.
#   1. DRY_RUN (the default) reads the index, calls nothing, prints no value
#   2. a missing or bad input fails fast, before any call, naming no value:
#      no file, a changed header (a tenth column), a short row, a bad date,
#      a bad year, DRY_RUN=yes
#   3. DRY_RUN=0 pins the SA and POSTs one snapshot: 2 documents, D.M.YYYY
#      dates as YYYY-MM-DD, the hash lowercased, NO file_name, the tax year
#      from the parent dir
#   4. a refusal fails the action
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-$ENV; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { echo "pin" >>"$CALLS"; GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "hub $1 $2" >>"$CALLS"; cp "${3#@}" "$CALLS.body"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-{\"snapshot_id\":\"s-1\",\"tax_year\":2026,\"documents\":2\}}"
    }
    do_spl_tax_sync' >"$T/o" 2>&1
}

H=$'arrival_date\tkind\ttype\ttax_type\tperiod\tdue_date\tcategory\tsha256\tfile_name'
SHA_A=$(printf 'a%.0s' {1..64}); SHA_B=$(printf 'B%.0s' {1..64})
mkdir -p "$T/2026"
IDX="$T/2026/index.tsv"
printf '%s\n%s\n%s\n' "$H" \
  $'2026-03-02\tkind-sekret-1\tdecision\tvat\t2026-01\t14.3.2026\tdecisions\t'"$SHA_A"$'\tdoc-sekret-1.pdf' \
  $'5.3.2026\tkind-sekret-2\tmsg\tincome\t2026\t\tmsgs\t'"$SHA_B"$'\tdoc-sekret-2.pdf' >"$IDX"
named() { grep -qE "sekret|doc-sekret" "$T/o"; }

# --- 1. dry run ---------------------------------------------------------------
run ENV=dev TAX_INDEX_FILE="$IDX"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "OK DRY_RUN would file 2 document(s) of tax year 2026 in dev" "$T/o" && ! named \
  && pass "1. DRY_RUN (default): 0 calls, counts only" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
printf '%s\tamount\n' "$H" >"$T/2026/wide.tsv"
printf '%s\n%s\n' "$H" $'2026-03-02\tkind-sekret-1\tdecision' >"$T/2026/short.tsv"
printf '%s\n%s\n' "$H" $'March 2\tkind-sekret-1\tdecision\tvat\t2026-01\t\tdecisions\t'"$SHA_A"$'\tdoc-sekret-1.pdf' >"$T/2026/date.tsv"
for bad in "ENV=" "ENV=stg" "TAX_INDEX_FILE=" "TAX_INDEX_FILE=$T/none.tsv" "TAX_INDEX_FILE=$T/2026/wide.tsv" \
           "TAX_INDEX_FILE=$T/2026/short.tsv" "TAX_INDEX_FILE=$T/2026/date.tsv" "TAX_YEAR=26" "DRY_RUN=yes"; do
  set -- ENV=dev TAX_INDEX_FILE="$IDX" DRY_RUN=0 "$bad"
  run "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && ! named && pass "2. ${bad##*/} fails fast, no call, no value" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
grep -q "line 2: 3 columns, want 9" <(run ENV=dev TAX_INDEX_FILE="$T/2026/short.tsv"; cat "$T/o") \
  && pass "2. a short row is named by its line number" || fail "2. short row: $(cat "$T/o")"

# --- 3. the write -------------------------------------------------------------
run ENV=prd TAX_INDEX_FILE="$IDX" DRY_RUN=0; rc=$?
body="$T/calls.body"
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] && grep -qx "hub POST /v1/operator/tax/snapshots" "$T/calls" \
  && [[ "$(jq -r '.tax_year' "$body")" == 2026 && "$(jq -r '.documents | length' "$body")" == 2 ]] \
  && [[ "$(jq -r '.documents[0].due_date' "$body")" == 2026-03-14 && "$(jq -r '.documents[1].arrival_date' "$body")" == 2026-03-05 ]] \
  && [[ "$(jq -r '.documents[1].due_date' "$body")" == "" && "$(jq -r '.documents[1].content_sha256' "$body")" == "${SHA_B,,}" ]] \
  && [[ "$(jq -r '.documents[0].doc_type' "$body")" == decision ]] \
  && ! grep -q "file_name\|doc-sekret" "$body" && [[ "$(jq -r '.snapshot_id' "$body")" =~ ^[0-9a-f-]{36}$ ]] \
  && grep -q "OK filed tax snapshot s-1: 2 document(s) of tax year 2026" "$T/o" && ! named \
  && pass "3. DRY_RUN=0 POSTs one snapshot as the SA, no file_name, dates normalised" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o" "$body")"

# --- 4. a refusal -------------------------------------------------------------
run ENV=dev TAX_INDEX_FILE="$IDX" DRY_RUN=0 STUB_CODE=409 STUB_BODY='{"error":"duplicate"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL the tax snapshot was not filed (http 409, duplicate)" "$T/o" && ! named \
  && pass "4. a refusal fails" || fail "4. refusal: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-tax-sync" || { echo "FAILED: $fails"; exit 1; }
