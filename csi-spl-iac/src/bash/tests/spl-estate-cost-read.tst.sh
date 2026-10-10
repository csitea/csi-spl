#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_estate_cost_read (spec 123 section 4.2, lane 2; rdb 0166),
#          offline: gcloud, curl (BigQuery REST) and psql are stubs.
#   1. ENV / DAY / DRY_RUN wrong -> refused before any call.
#   2. The export absent (no dataset, no table, no reader identity) -> one
#      cost_coverage row per window day, `missing` with the reason, NO
#      cost_lines and no delete: an absent export is never 0.
#   3. A fixture export: per day ok / partial (newest export day, a line in a
#      currency with no EUR rate) / missing (no row); credits and the box label
#      as rendered; any csi-spl-* project counted (the LIKE parameter, not a
#      list); a row outside the window ignored; polling and paging followed.
#   4. DRY_RUN=1 (default) never calls psql; DRY_RUN=0 applies ONE transaction
#      in the operator RLS scope with the 0166 UPSERT key.
#   5. Re-read is idempotent: two runs apply the same SQL but for the run id;
#      CONTROL: a revised day changes the amount in the second run's SQL.
#   6. Identity: a reader key is used as is; a key of another SA, or a user
#      (owner) account to impersonate from, is refused (`missing`).
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
F="$PROJ_ROOT/src/bash/run/spl-estate-cost-read.func.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/spl-cost-gcp.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

READER="spl-cost-reader@csi-spl-all.iam.gserviceaccount.com"
TABLE="gcp_billing_export_v1_0A1B2C_3D4E5F_6A7B8C"
# rows: day project box service currency amount_micros usd_micros
row() { printf '{"f":[{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"}]}' "$@"; }
{
  echo '['
  row 2026-10-05 csi-spl-prd "" "Cloud Run" EUR 1234567 1400000; echo ,
  row 2026-10-05 csi-spl-prd "" "Cloud SQL" EUR 2000000 2300000; echo ,
  row 2026-10-05 csi-spl-all satellite "Compute Engine" EUR 500000 560000; echo ,
  row 2026-10-06 csi-spl-x "" "Cloud Run" EUR 100 110; echo ,
  row 2026-10-07 csi-spl-dev "" "Cloud Run" USD 300 300; echo ,
  row 2026-10-09 csi-spl-prd "" "Cloud Run" EUR 10 11; echo ,
  row 2026-10-01 csi-spl-prd "" "Cloud Run" EUR 999 999
  echo ']'
} >"$T/rows.json"
sed 's/1234567/7654321/' "$T/rows.json" >"$T/rows-revised.json"

stub gcloud '
echo "gcloud $*" >>"$LOG"
case "$*" in
  "auth print-access-token"*"--impersonate-service-account"*)
    [[ "${IMP:-ok}" == fail ]] && { echo "ERROR: (gcloud.auth.print-access-token) NOT_FOUND: Failed to impersonate [x]. Make sure ..." >&2; exit 1; }
    echo tok-IMP ;;
  "auth print-access-token"*) echo tok-KEY ;;
esac
exit 0'
stub curl '
m=GET; for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -X ]] && { j=$((i + 1)); m="${!j}"; }; done
url="${!#}"; p="${url#*/v2/}"; echo "curl $m $p" >>"$LOG"; cat >/dev/null
body=""; for a in "$@"; do [[ "$a" == @* ]] && body=$(cat "${a#@}"); done
case "$m $p" in
  "GET projects/csi-spl-all/datasets/spl_billing_export/tables"*)
    case "${EXPORT:-present}" in
      nodataset) printf "{\"error\":{\"message\":\"Not found: Dataset\"}}\n404" ;;
      notable) printf "{\"tables\":[{\"tableReference\":{\"tableId\":\"other\"}}]}\n200" ;;
      *) printf "{\"tables\":[{\"tableReference\":{\"tableId\":\"%s\"}}]}\n200" "$TABLE" ;;
    esac ;;
  "POST projects/csi-spl-all/queries")
    echo "$body" >>"$LOG.queries"
    if grep -q "MAX(DATE" <<<"$body"; then printf "{\"jobComplete\":true,\"jobReference\":{\"jobId\":\"jf\"},\"rows\":[{\"f\":[{\"v\":\"2026-10-09\"}]}]}\n200"
    elif [[ -n "${POLL:-}" ]]; then printf "{\"jobComplete\":false,\"jobReference\":{\"jobId\":\"jr\"}}\n200"
    else printf "{\"jobComplete\":true,\"jobReference\":{\"jobId\":\"jr\"},\"rows\":%s}\n200" "$(cat "$ROWS")"; fi ;;
  "GET projects/csi-spl-all/queries/jr"*pageToken=p2*)
    printf "{\"jobComplete\":true,\"jobReference\":{\"jobId\":\"jr\"},\"rows\":%s}\n200" "$(jq -c ".[3:]" "$ROWS")" ;;
  "GET projects/csi-spl-all/queries/jr"*)
    printf "{\"jobComplete\":true,\"jobReference\":{\"jobId\":\"jr\"},\"pageToken\":\"p2\",\"rows\":%s}\n200" "$(jq -c ".[:3]" "$ROWS")" ;;
  *) printf "{\"error\":{\"message\":\"unexpected %s\"}}\n500" "$m $p" ;;
esac'
mkdir -p "$T/failbin"; printf '#!/bin/bash\nexit 3\n' >"$T/failbin/psql"; chmod +x "$T/failbin/psql"
stub psql '
echo "psql user=$PGUSER host=$PGHOST port=$PGPORT db=$PGDATABASE $*" >>"$LOG"
n=$(ls "$LOG".sql.* 2>/dev/null | wc -l); for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -f ]] && { j=$((i + 1)); cp "${!j}" "$LOG.sql.$((n + 1))"; }; done
exit 0'

# run_case <out> [VAR=value ...] - the action in a fresh shell; prints its log and "rc=<n>"
run_case() {
  local out="$1"; shift
  : >"$T/log"
  env -u DRY_RUN -u ACCOUNT -u GCP_ACCOUNT -u COST_DB_DSN -u COST_READER_KEY_FILE -u DAY \
    PATH="$T/bin:$PATH" LOG="$T/log" HOME="$T/home" TABLE="$TABLE" ROWS="$T/rows.json" F="$F" LIB="$LIB" \
    APP_PATH="$APP_ROOT" ENV=prd DAY=2026-10-09 "$@" bash -c '
    do_log(){ echo "$*"; }
    do_resolve_oap(){ case "$1" in ORG) ORG=csi ;; APP) APP=spl ;; esac; }
    do_gcp_pin_account(){
      if [[ -n "${GCP_SA_KEY_FILE:-}" ]]; then GCP_ACCOUNT=$(jq -r .client_email "$GCP_SA_KEY_FILE")
      elif [[ -z "${GCP_ACCOUNT:-}" ]]; then GCP_ACCOUNT="${PROJ_ID:-none}@${PROJ_ID:-none}.iam.gserviceaccount.com"; fi
      export GCP_ACCOUNT; }
    do_gcp_require_live_account(){ :; }
    source "$LIB"; source "$F"
    do_spl_estate_cost_read; echo "rc=$?"' >"$out" 2>&1
}
cov() { grep -E "^INFO $1 gcp " "$T/o" | awk '{print $4}'; }

# --- 1. refusals ------------------------------------------------------------------
run_case "$T/o" ENV=
grep -q "ENV must be dev or prd" "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "ENV unset -> fails fast, no gcloud / BigQuery / psql call" || fail "ENV unset: $(cat "$T/o")"
run_case "$T/o" DAY=2026-13-40
grep -q "DAY must be a UTC day" "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "DAY=2026-13-40 -> refused, no call" || fail "bad DAY: $(cat "$T/o")"
run_case "$T/o" DRY_RUN=yes
grep -q "DRY_RUN must be 0 or 1" "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
  && pass "DRY_RUN=yes -> refused, no call" || fail "bad DRY_RUN: $(cat "$T/o")"

# --- 2. the export absent: missing, never 0 ----------------------------------------
for ex in nodataset notable imp; do
  rm -f "$T/log".sql.*
  if [[ "$ex" == imp ]]; then run_case "$T/o" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db IMP=fail
  else run_case "$T/o" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db EXPORT="$ex"; fi
  sql="$T/log.sql.1"
  n_missing=$(grep -cE "^  \(DATE '2026-10-0[5-9]', 'gcp', 'missing', '" "$sql" 2>/dev/null)
  if grep -q '^rc=0$' "$T/o" && [[ "$n_missing" -eq 5 ]] && ! grep -q 'INSERT INTO cost_lines' "$sql" && ! grep -q 'DELETE' "$sql"; then
    pass "export $ex -> 5 window days 'missing' with a reason, no cost_lines row, nothing deleted"
  else fail "export $ex: missing=$n_missing $(cat "$T/o") / $(cat "$sql" 2>&1)"; fi
done
grep -q "Failed to impersonate" "$T/log.sql.1" && grep -q 'REPORT it' "$T/log.sql.1" \
  && pass "an identity that cannot act as the reader is written as the reason (and logged to REPORT)" || fail "impersonation reason: $(cat "$T/log.sql.1")"

# --- 3. a fixture export ----------------------------------------------------------
rm -f "$T/log".sql.*; : >"$T/log.queries"
run_case "$T/o" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db
sql="$T/log.sql.1"
grep -q '^rc=0$' "$T/o" && grep -q 'OK wrote the window 2026-10-05..2026-10-09 to the prd hub DB' "$T/o" \
  && pass "DRY_RUN=0: the window is written, rc 0" || fail "write: $(tail -n 3 "$T/o")"
[[ "$(cov 2026-10-05) $(cov 2026-10-06) $(cov 2026-10-07) $(cov 2026-10-08) $(cov 2026-10-09)" == "ok ok partial missing partial" ]] \
  && pass "coverage: 05 ok, 06 ok, 07 partial (a USD line, no EUR rate), 08 missing (no row), 09 partial (newest export day)" \
  || fail "coverage: $(grep ' gcp ' "$T/o")"
grep -qF "(DATE '2026-10-05', 'gcp', 'csi-spl-all/box=satellite', NULL, NULL, NULL, 'compute-engine', 0, 500000, 'EUR', 560000, 500000, DATE '2026-10-05', 'billing_export', '" "$sql" \
  && pass "a box-labelled line: project/box=<label>, kind = the service slug, EUR amount = eur_micros, usd from the export's rate" \
  || fail "satellite row: $(grep satellite "$sql")"
[[ "$(grep -c "'billing_export', '" "$sql")" -eq 5 ]] && ! grep -q "2026-10-01" "$sql" && ! grep -q "'USD'" "$sql" \
  && pass "5 cost lines: the out-of-window row and the USD line (held) are not written" || fail "line count: $(grep -c billing_export "$sql")"
grep -qF "'csi-spl-x'" "$sql" && jq -se '.[0].queryParameters[] | select(.name == "like") | .parameterValue.value == "csi-spl-%"' "$T/log.queries" >/dev/null \
  && grep -q 'project.id LIKE @like' "$T/log.queries" \
  && pass "every csi-spl-* project: the query filters LIKE 'csi-spl-%' (cnf), and csi-spl-x is counted" || fail "project filter: $(head -c 600 "$T/log.queries")"
grep -q "^DELETE FROM cost_lines .*day IN (DATE '2026-10-05', DATE '2026-10-06', DATE '2026-10-07', DATE '2026-10-09')" "$sql" \
  && pass "stale lines are deleted only on days that were read (08, missing, keeps what it had)" || fail "delete: $(grep DELETE "$sql")"

# --- 4. one transaction, operator scope, the 0166 key; DRY_RUN=1 never writes -----
[[ "$(head -n 2 "$sql" | tr '\n' ' ')" == "BEGIN; SET LOCAL app.rls_scope = 'operator'; " && "$(tail -n 1 "$sql")" == "COMMIT;" ]] \
  && grep -q '^ON CONFLICT (day, source, project_or_vendor, tenant_id, agent_id, model, kind) WHERE superseded_by IS NULL$' "$sql" \
  && grep -q '^ON CONFLICT (day, source) DO UPDATE' "$sql" \
  && pass "one transaction in the operator RLS scope; UPSERT on the 0166 partial unique key and the coverage key" \
  || fail "transaction shape: $(head -n 3 "$sql") ... $(grep 'ON CONFLICT' "$sql")"
grep -q '^psql user=u host=127.0.0.1 port=5999 db=db -X -q -v ON_ERROR_STOP=1 -f ' "$T/log" && ! grep -q 'u:p@' "$T/log" \
  && pass "COST_DB_DSN reaches psql as PG* env vars, the password never in argv" || fail "psql call: $(grep psql "$T/log")"
rm -f "$T/log".sql.*
run_case "$T/o"
grep -q '^rc=0$' "$T/o" && ! grep -q '^psql' "$T/log" && grep -q 'DRY_RUN=0 applies 5 cost line(s) and 5 coverage row(s)' "$T/o" \
  && pass "DRY_RUN unset = 1: the export is read, psql is never called" || fail "dry run: $(grep -E 'psql|OK' "$T/log" "$T/o")"

# polling and paging: jobComplete false, then two pages
rm -f "$T/log".sql.*
run_case "$T/o" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db POLL=1
[[ "$(grep -c "'billing_export', '" "$T/log.sql.1")" -eq 5 ]] && grep -q 'pageToken=p2' "$T/log" \
  && pass "an unfinished job is polled and every page is read" || fail "poll/page: $(grep curl "$T/log")"

run_case "$T/o" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db PATH="$T/failbin:$T/bin:$PATH"
grep -q '^rc=1$' "$T/o" && grep -q 'could not write the cost rows' "$T/o" \
  && pass "a failed psql fails the action (rc 1), never a silent OK" || fail "psql failure: $(tail -n 2 "$T/o")"

# --- 5. idempotent re-read --------------------------------------------------------
rm -f "$T/log".sql.*
run_case "$T/o" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db
run_case "$T/o2" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db
norm() { sed -E "s/estate-cost-read-[0-9TZ]+-[0-9]+/RUN/g" "$1"; }
diff <(norm "$T/log.sql.1") <(norm "$T/log.sql.2") >/dev/null \
  && pass "the same window read twice applies the same UPSERTs (a re-read adds no row)" || fail "re-read differs: $(diff <(norm "$T/log.sql.1") <(norm "$T/log.sql.2"))"
run_case "$T/o2" DRY_RUN=0 COST_DB_DSN=postgres://u:p@127.0.0.1:5999/db ROWS="$T/rows-revised.json"
grep -q "'cloud-run', 0, 7654321, 'EUR'" "$T/log.sql.3" && ! grep -q "1234567" "$T/log.sql.3" \
  && pass "CONTROL: a revised day in the export rewrites that line's amount on the re-read" || fail "revised: $(grep cloud-run "$T/log.sql.3")"

# --- 6. identity --------------------------------------------------------------------
mkdir -p "$T/home/.gcp/.csi"
printf '{"client_email":"%s"}' "$READER" >"$T/home/.gcp/.csi/key-csi-spl-all-cost-reader.json"
run_case "$T/o"
grep -q "gcloud auth print-access-token --account=$READER$" "$T/log" && ! grep -q impersonate "$T/log" \
  && pass "a reader key on disk (\$HOME/.gcp/.csi/key-csi-spl-all-cost-reader.json) is used as is, no impersonation" \
  || fail "reader key: $(grep gcloud "$T/log")"
printf '{"client_email":"other@csi-spl-all.iam.gserviceaccount.com"}' >"$T/other.json"
run_case "$T/o" COST_READER_KEY_FILE="$T/other.json"
[[ "$(cov 2026-10-05)" == missing ]] && grep -q "is other@csi-spl-all.iam.gserviceaccount.com, not $READER" "$T/o" && ! grep -q print-access-token "$T/log" \
  && pass "a key of another SA is refused: missing, no token minted" || fail "other key: $(cat "$T/o")"
rm -f "$T/home/.gcp/.csi/key-csi-spl-all-cost-reader.json"
run_case "$T/o" GCP_ACCOUNT=owner@example.com
[[ "$(cov 2026-10-05)" == missing ]] && grep -q "owner@example.com is no service account" "$T/o" && ! grep -q print-access-token "$T/log" \
  && pass "a user (owner) account is never used to act as the reader: missing, no token minted" || fail "owner: $(cat "$T/o")"
run_case "$T/o"
grep -q "gcloud auth print-access-token --account=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com --impersonate-service-account=$READER" "$T/log" \
  && pass "no reader key: the prd project SA acts as the reader (--account and --impersonate-service-account)" || fail "impersonation: $(grep gcloud "$T/log")"
! grep -q 'tok-' "$T/o" "$T/log" && pass "the token is never logged" || fail "token logged"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
