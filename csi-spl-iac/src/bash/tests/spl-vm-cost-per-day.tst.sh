#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_vm_cost_per_day (spec 181 row B4, gap G5), offline: gcloud,
#          curl (BigQuery REST) and psql are stubs; the rows are synthetic.
#   1. ENV / WORKSPACE / DAY wrong -> refused before any call.
#   2. B4's red control: a fixture row with another workspace's label (and one
#      whose label only starts with it, and `7` / `1000` for WORKSPACE=007 /
#      1e3: a string compare, never awk's numeric one) is not counted, though
#      the stubbed export returns it; CONTROL: the action with its label filter
#      cut out (or compared as awk compares by default) counts it.
#   2b. Only the VM's services count (Q-8 A, Q-10, P5): a Vertex AI token line
#      and a Cloud Storage line labelled ws-a are not counted, the day reads
#      partial naming them; CONTROL: the allow-list cut out counts the tokens.
#   3. Per day and box: compute, disk and traffic by SKU, credits netted;
#      ok / partial (a USD line held, the export's newest day) / none (no line
#      of this workspace); a row outside the window ignored.
#   4. The export absent -> every day `missing` with the reason, never 0.
#   5. The read is spec 123's: the export table by prefix in the source
#      dataset, the reader SA, its query with the workspace label and the SKU;
#      read-only (no psql, no write), the token never logged; VM_COST_OUT.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
F="$PROJ_ROOT/src/bash/run/spl-vm-cost-per-day.func.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/spl-cost-gcp.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

TABLE="gcp_billing_export_v1_0A1B2C_3D4E5F_6A7B8C"
# rows: day project workspace box service sku currency amount_micros usd_micros
row() { printf '{"f":[{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"},{"v":"%s"}]}' "$@"; }
{
  echo '['
  row 2026-11-05 csi-spl-prd ws-a vm-a "Compute Engine" "N2 Instance Core running in Finland" EUR 1000000 1100000; echo ,
  row 2026-11-05 csi-spl-prd ws-a vm-a "Compute Engine" "N2 Instance Ram running in Finland" EUR 400000 440000; echo ,
  row 2026-11-05 csi-spl-prd ws-a vm-a "Compute Engine" "Sustained use discount" EUR -100000 -110000; echo ,
  row 2026-11-05 csi-spl-prd ws-a vm-a "Compute Engine" "Balanced PD Capacity in Finland" EUR 200000 220000; echo ,
  row 2026-11-05 csi-spl-prd ws-a vm-a "Networking" "Network Internet Egress from Finland to Europe" EUR 50000 55000; echo ,
  row 2026-11-05 csi-spl-prd ws-b vm-b "Compute Engine" "N2 Instance Core running in Finland" EUR 9000000 9900000; echo ,
  row 2026-11-05 csi-spl-prd 7 vm-x "Compute Engine" "N2 Instance Core running in Finland" EUR 5000 5500; echo ,
  row 2026-11-05 csi-spl-prd 1000 vm-y "Compute Engine" "N2 Instance Core running in Finland" EUR 6000 6600; echo ,
  row 2026-11-06 csi-spl-prd ws-a vm-a "Compute Engine" "N2 Instance Core running in Finland" EUR 300 330; echo ,
  row 2026-11-06 csi-spl-prd ws-a vm-a "Compute Engine" "Snapshot Storage" USD 50 50; echo ,
  row 2026-11-07 csi-spl-prd ws-b vm-b "Compute Engine" "N2 Instance Core running in Finland" EUR 7000 7700; echo ,
  row 2026-11-08 csi-spl-prd ws-a vm-a "Compute Engine" "N2 Instance Core running in Finland" EUR 10 11; echo ,
  row 2026-11-08 csi-spl-prd ws-a-old vm-c "Compute Engine" "N2 Instance Core running in Finland" EUR 777 800; echo ,
  row 2026-11-08 csi-spl-prd ws-a "" "Vertex AI" "Gemini 2.5 Pro Input Tokens" EUR 123456 135000; echo ,
  row 2026-11-08 csi-spl-prd ws-a "" "Cloud Storage" "Standard Storage Europe" EUR 20 22; echo ,
  row 2026-11-09 csi-spl-prd ws-a vm-a "Compute Engine" "N2 Instance Core running in Finland" EUR 5 6; echo ,
  row 2026-11-01 csi-spl-prd ws-a vm-a "Compute Engine" "N2 Instance Core running in Finland" EUR 999 999
  echo ']'
} >"$T/rows.json"

stub gcloud '
echo "gcloud $*" >>"$LOG"
case "$*" in "auth print-access-token"*) echo tok-SECRET ;; esac
exit 0'
# the stubbed export answers every row whatever the query asks: the action's
# own label filter is what keeps another workspace out
stub curl '
m=GET; for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -X ]] && { j=$((i + 1)); m="${!j}"; }; done
url="${!#}"; p="${url#*/v2/}"; echo "curl $m $p" >>"$LOG"; cat >/dev/null
body=""; for a in "$@"; do [[ "$a" == @* ]] && body=$(cat "${a#@}"); done
case "$m $p" in
  "GET projects/csi-spl-prd/datasets/csi_spl_prd/tables"*)
    if [[ "${EXPORT:-present}" == nodataset ]]; then printf "{\"error\":{\"message\":\"Not found: Dataset\"}}\n404"
    else printf "{\"tables\":[{\"tableReference\":{\"tableId\":\"%s\"}}]}\n200" "$TABLE"; fi ;;
  "POST projects/csi-spl-all/queries")
    echo "$body" >>"$LOG.queries"
    if grep -q "MAX(DATE" <<<"$body"; then printf "{\"jobComplete\":true,\"jobReference\":{\"jobId\":\"jf\"},\"rows\":[{\"f\":[{\"v\":\"2026-11-09\"}]}]}\n200"
    else printf "{\"jobComplete\":true,\"jobReference\":{\"jobId\":\"jr\"},\"rows\":%s}\n200" "$(jq -c . "$ROWS")"; fi ;;
  *) printf "{\"error\":{\"message\":\"unexpected %s\"}}\n500" "$m $p" ;;
esac'
stub psql 'echo "psql $*" >>"$LOG"; exit 0'

# run_case <out> <action file> [VAR=value ...] - the action in a fresh shell
run_case() {
  local out="$1" file="$2"; shift 2
  : >"$T/log"; : >"$T/log.queries"
  env -u DRY_RUN -u ACCOUNT -u GCP_ACCOUNT -u COST_READER_KEY_FILE -u DAY -u VM_COST_OUT -u WORKSPACE \
    PATH="$T/bin:$PATH" LOG="$T/log" HOME="$T/home" TABLE="$TABLE" ROWS="$T/rows.json" F="$file" LIB="$LIB" \
    APP_PATH="$APP_ROOT" ENV=prd DAY=2026-11-09 WORKSPACE=ws-a "$@" bash -c '
    do_log(){ echo "$*"; }
    do_resolve_oap(){ case "$1" in ORG) ORG=csi ;; APP) APP=spl ;; esac; }
    do_gcp_pin_account(){
      [[ -z "${GCP_ACCOUNT:-}" ]] && GCP_ACCOUNT="${PROJ_ID:-none}@${PROJ_ID:-none}.iam.gserviceaccount.com"
      export GCP_ACCOUNT; }
    source "$LIB"; source "$F"
    do_spl_vm_cost_per_day; echo "rc=$?"' >"$out" 2>&1
}
# day <d> - the TSV row(s) of day <d>, fields 3..8 (box state compute disk traffic total)
day() { awk -F'\t' -v d="$1" '$1 == d { print $3, $4, $5, $6, $7, $8 }' "$T/o"; }

# --- 1. refusals ------------------------------------------------------------------
for c in "ENV=" "WORKSPACE=" "WORKSPACE=Ws-A" "WORKSPACE=ws;a" "DAY=2026-13-40"; do
  run_case "$T/o" "$F" "$c"
  grep -q '^FATAL ' "$T/o" && grep -q '^rc=1$' "$T/o" && [[ ! -s "$T/log" ]] \
    && pass "$c -> refused before any gcloud / BigQuery call" || fail "$c: $(cat "$T/o")"
done

# --- 2. B4's red control: another workspace's label is not counted -----------------
run_case "$T/o" "$F"
grep -q '^rc=0$' "$T/o" && pass "the fixture export is read, rc 0" || fail "read: $(tail -n 3 "$T/o")"
[[ "$(day 2026-11-05)" == "vm-a ok 1300000 200000 50000 1550000" ]] \
  && pass "2026-11-05: ws-b's 9000000 line is not counted in ws-a's VM (1550000, not 10550000)" \
  || fail "another workspace counted: $(day 2026-11-05)"
[[ "$(day 2026-11-07)" == "- none 0 0 0 0" ]] && grep -qP '^2026-11-07\t.*\tno line labelled workspace=ws-a$' "$T/o" \
  && pass "2026-11-07: a day with only ws-b's line reads none, 0, for ws-a" || fail "only-ws-b day: $(day 2026-11-07)"
[[ "$(day 2026-11-08)" == "vm-a partial 10 0 0 10" ]] \
  && pass "2026-11-08: a label that only starts with ws-a (ws-a-old) is not counted" || fail "prefix label: $(day 2026-11-08)"
for w in 007 1e3; do
  run_case "$T/o" "$F" WORKSPACE="$w"
  [[ "$(day 2026-11-05)" == "- none 0 0 0 0" ]] \
    && pass "WORKSPACE=$w: the rows labelled 7 and 1000 are not counted (a string compare, not awk's numeric one)" || fail "WORKSPACE=$w numeric match: $(day 2026-11-05)"
done
# CONTROL: cut the label filter out of the action -> ws-b's line is counted
# mutant <name> <sed expr> - a copy of the action with <sed expr> applied, beside spec 123's reader
mutant() {
  mkdir -p "$T/$1"; cp "$PROJ_ROOT/src/bash/run/spl-estate-cost-read.func.sh" "$T/$1/"
  sed "$2" "$F" >"$T/$1/spl-vm-cost-per-day.func.sh"
  cmp -s "$F" "$T/$1/spl-vm-cost-per-day.func.sh" && fail "CONTROL $1: the sed found nothing to change"
  M="$T/$1/spl-vm-cost-per-day.func.sh"
}
mutant nolabel 's/ \&\& (\$3 "") == (ws "")//'
run_case "$T/o" "$M"
grep -qx "vm-b ok 9000000 0 0 9000000" <<<"$(day 2026-11-05)" \
  && pass "CONTROL: without the label filter ws-b's 9000000 line is counted: the filter is what keeps it out" \
  || fail "CONTROL: without the label filter ws-b's line should be counted, got $(day 2026-11-05 | tr '\n' ';')"
mutant numeric 's/(\$3 "") == (ws "")/$3 == ws/'
run_case "$T/o" "$M" WORKSPACE=007
grep -qx "vm-x ok 5000 0 0 5000" <<<"$(day 2026-11-05)" \
  && pass "CONTROL: compared as awk does by default, WORKSPACE=007 counts the row labelled 7" \
  || fail "CONTROL numeric: $(day 2026-11-05 | tr '\n' ';')"

# --- 2b. only the VM's services count ----------------------------------------------
run_case "$T/o" "$F"
grep -qP '^2026-11-08\tws-a\tvm-a\tpartial\t10\t0\t0\t10\t2 line\(s\) of a service that is not the VM not counted: Vertex AI, Cloud Storage$' "$T/o" \
  && pass "2026-11-08: a Vertex AI token line and a Cloud Storage line labelled ws-a are not counted; the day reads partial naming them" \
  || fail "non-VM service: $(grep '^2026-11-08' "$T/o")"
mutant noallow 's/if (!(\$5 in vm_svc))/if (0)/'
run_case "$T/o" "$M"
[[ "$(day 2026-11-08)" == "vm-a ok 10 0 0 10"$'\n'"- ok 123456 20 0 123476" ]] \
  && pass "CONTROL: without the service allow-list the Vertex AI tokens count as compute (123456): the allow-list is what keeps them out" \
  || fail "CONTROL allow-list: $(day 2026-11-08 | tr '\n' ';')"

# --- 3. the parts, the states, the window -----------------------------------------
run_case "$T/o" "$F"
pass_parts="compute 1000000 + 400000 - 100000 (credit-netted discount), disk = Balanced PD, traffic = egress"
[[ "$(day 2026-11-05)" == "vm-a ok 1300000 200000 50000 1550000" ]] && pass "$pass_parts" || fail "parts: $(day 2026-11-05)"
[[ "$(day 2026-11-06)" == "vm-a partial 300 0 0 300" ]] && grep -qP '^2026-11-06\t.*\t1 line\(s\) held back' "$T/o" \
  && pass "2026-11-06: a USD line is held back, the day reads partial" || fail "held: $(grep '^2026-11-06' "$T/o")"
[[ "$(day 2026-11-09)" == "vm-a partial 5 0 0 5" ]] && grep -qP '^2026-11-09\t.*still filling' "$T/o" \
  && pass "2026-11-09: the export's newest day reads partial" || fail "frontier: $(grep '^2026-11-09' "$T/o")"
[[ "$(awk -F'\t' '$1 ~ /^2026-/' "$T/o" | wc -l)" -eq 5 ]] && ! grep -q '^2026-11-01' "$T/o" && ! grep -q 999 "$T/o" \
  && pass "one row per window day (11-05..11-09), the 11-01 row outside the window ignored" || fail "window: $(grep '^2026-' "$T/o")"
grep -q "workspace=ws-a window=2026-11-05..2026-11-09" <<<"$(head -n 2 "$T/o")" \
  && grep -qP '^day\tworkspace\tbox\tstate\tcompute_eur_micros\tdisk_eur_micros\ttraffic_eur_micros\ttotal_eur_micros\treason$' "$T/o" \
  && pass "the TSV header names every column" || fail "header: $(head -n 3 "$T/o")"
! grep -qi token "$T/o" && pass "the TSV carries no token line (spec 181 Q-10)" || fail "token line: $(grep -i token "$T/o")"

# --- 4. the export absent: missing, never 0 ----------------------------------------
run_case "$T/o" "$F" EXPORT=nodataset
[[ "$(awk -F'\t' '$1 ~ /^2026-/ && $4 == "missing" && $5 == "" && $8 == "" && $9 ~ /not found/' "$T/o" | wc -l)" -eq 5 ]] && grep -q '^rc=0$' "$T/o" \
  && pass "no export dataset -> 5 days missing with the reason, no amount (never 0)" || fail "absent: $(cat "$T/o")"

# --- 5. spec 123's read, read-only ----------------------------------------------------
run_case "$T/o" "$F"
grep -q '^curl GET projects/csi-spl-prd/datasets/csi_spl_prd/tables' "$T/log" \
  && [[ "$(grep -c '^curl POST projects/csi-spl-all/queries$' "$T/log")" -eq 2 ]] \
  && grep -q "gcloud auth print-access-token --account=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com --impersonate-service-account=spl-cost-reader@csi-spl-all.iam.gserviceaccount.com" "$T/log" \
  && pass "spec 123's read: the source dataset of the cnf, jobs in csi-spl-all, the prd SA acting as the reader" \
  || fail "reader: $(grep -E '^(curl|gcloud)' "$T/log")"
q=$(jq -rs '.[] | .query | select(test("MAX\\(DATE") | not)' "$T/log.queries")
grep -q "FROM \`csi-spl-prd.csi_spl_prd.$TABLE\`" <<<"$q" && grep -q "l.key = 'workspace'" <<<"$q" \
  && grep -q 'sku.description AS sku' <<<"$q" && grep -q "AND EXISTS (SELECT 1 FROM UNNEST(labels) l WHERE l.key = 'workspace')" <<<"$q" \
  && pass "the row query reads the export table by prefix, keeps the workspace label and the SKU" || fail "query: $q"
! grep -q '^psql' "$T/log" && pass "read-only: psql is never called" || fail "psql called: $(grep psql "$T/log")"
! grep -q 'tok-SECRET' "$T/o" "$T/log" "$T/log.queries" && pass "the token is never logged" || fail "token logged"
run_case "$T/o" "$F" VM_COST_OUT="$T/vm.tsv"
grep -qP '^2026-11-05\tws-a\tvm-a\tok\t1300000\t200000\t50000\t1550000\t$' "$T/vm.tsv" && ! grep -qP '^2026-11-05\t' "$T/o" \
  && pass "VM_COST_OUT gets the TSV, stdout only the log" || fail "VM_COST_OUT: $(cat "$T/vm.tsv" 2>&1)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
