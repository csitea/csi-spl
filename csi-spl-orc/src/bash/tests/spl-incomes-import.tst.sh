#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_incomes_import (SPL-4697, rdb 0256) checks a TSV of income
#          invoices and sends it to PUT /v1/operator/incomes. The hub is
#          stubbed; every row is synthetic (csi-spl is public).
#   1. DRY_RUN=1 (default): checks, prints the count and the period span,
#      sends nothing and prints no figure
#   2. DRY_RUN=0: one PUT carrying {tenant, invoices} with the TSV's rows,
#      amounts as numbers; the hub's counts are logged
#   3. a bad row (net + vat != total, a day as the period, a 3-decimal net,
#      a duplicate invoice number, a missing column) is refused before any call,
#      naming its line
#   4. the hub's 400 is reported with its index, the run fails
#   5. CONTROL: ENV, INCOMES_TENANT and INCOMES_FILE are required
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-incomes-import.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

HDR=$'invoice_no\tpayer\tperiod\tissue_date\tdue_date\thours\tunit_price\tnet\tvat_pct\tvat\ttotal\tcurrency'
printf '%s\n' "$HDR" \
  $'INV-0001\tACME\t2025-02\t2025-03-02\t2025-04-06\t28.5\t10.00\t285.00\t25\t71.25\t356.25\tEUR' \
  $'INV-0002\tACME\t2025-03\t2025-04-01\t2025-05-01\t100\t10\t1000\t25\t250\t1250\tEUR' >"$T/good.tsv"

# runa [VAR=val ...]: the action, the hub recorded in $T/calls.
runa() {
  : >"$T/calls"
  env -u DRY_RUN -u INCOMES_TENANT -u INCOMES_FILE FUNC="$FUNC" T="$T" PROJ_PATH="$PROJ_ROOT" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { return 0; }
    spl_require_cloud_env() { [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { echo "FATAL ENV must be dev or prd" >&2; return 1; }; }
    source "$FUNC"
    spl_cost_hub_login() { echo login >>"$T/calls"; }
    spl_hub_operator_call() {
      printf "%s %s %s\n" "$1" "$2" "$3" >>"$T/calls"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"
      SPL_HUB_OP_BODY="${STUB_BODY:-{\"inserted\":2,\"updated\":0\}}"
    }
    do_spl_incomes_import' >"$T/o" 2>"$T/e"
}

# 1. dry run ----------------------------------------------------------------
runa ENV=dev INCOMES_TENANT=ta INCOMES_FILE="$T/good.tsv"; rc=$?
[[ $rc == 0 && ! -s "$T/calls" ]] && grep -q "2 invoice(s), periods 2025-02..2025-03" "$T/e" && grep -q "dry run: nothing sent" "$T/e" &&
  ! grep -qE '356|1250|ACME' "$T/e" "$T/o" &&
  pass "1. dry run: count and span, no call, no figure" || fail "1. rc=$rc $(cat "$T/e" "$T/calls")"

# 2. the import -------------------------------------------------------------
runa ENV=dev INCOMES_TENANT=ta INCOMES_FILE="$T/good.tsv" DRY_RUN=0; rc=$?
body=$(grep '^PUT /v1/operator/incomes ' "$T/calls" | cut -d' ' -f3-)
[[ $rc == 0 && "$(head -1 "$T/calls")" == login ]] &&
  jq -e '.tenant == "ta" and (.invoices | length) == 2 and .invoices[0].invoice_no == "INV-0001"
    and .invoices[0].hours == 28.5 and .invoices[0].total == 356.25 and .invoices[1].unit_price == 10
    and .invoices[1].period == "2025-03" and .invoices[1].due_date == "2025-05-01"' <<<"$body" >/dev/null &&
  grep -q "OK the dev hub took them: 2 new, 0 replaced" "$T/e" &&
  pass "2. DRY_RUN=0: one PUT {tenant, invoices}, numbers as numbers; the hub's counts logged" || fail "2. rc=$rc $body $(cat "$T/e")"

# 3. bad rows ---------------------------------------------------------------
bad_case() { # <name> <want> <row...>
  local name="$1" want="$2"; shift 2
  printf '%s\n' "$HDR" "$@" >"$T/bad.tsv"
  runa ENV=dev INCOMES_TENANT=ta INCOMES_FILE="$T/bad.tsv" DRY_RUN=0; rc=$?
  [[ $rc != 0 && ! -s "$T/calls" ]] && grep -q "$want" "$T/e" &&
    pass "3. $name refused before any call" || fail "3. $name: rc=$rc $(cat "$T/e" "$T/calls")"
}
bad_case "a wrong total" "line 2: net + vat must equal total" $'INV-1\tACME\t2025-02\t2025-03-02\t2025-04-06\t1\t10\t10\t25\t2.5\t12.6\tEUR'
bad_case "a day as the period" "line 2: period must be a month" $'INV-1\tACME\t2025-02-01\t2025-03-02\t2025-04-06\t1\t10\t10\t25\t2.5\t12.5\tEUR'
bad_case "a 3-decimal net" "line 2: net, total must be numbers" $'INV-1\tACME\t2025-02\t2025-03-02\t2025-04-06\t1\t10\t10.001\t25\t2.5\t12.501\tEUR'
bad_case "a duplicate number" "line 3: invoice_no appears twice" \
  $'INV-1\tACME\t2025-02\t2025-03-02\t2025-04-06\t1\t10\t10\t25\t2.5\t12.5\tEUR' $'INV-1\tACME\t2025-03\t2025-04-02\t2025-05-06\t1\t10\t10\t25\t2.5\t12.5\tEUR'
printf 'invoice_no\tpayer\n' >"$T/cols.tsv"
runa ENV=dev INCOMES_TENANT=ta INCOMES_FILE="$T/cols.tsv"; rc=$?
[[ $rc != 0 ]] && grep -q "the header lacks period" "$T/e" && pass "3. a missing column refused" || fail "3. columns: rc=$rc $(cat "$T/e")"

# 4. the hub refuses ----------------------------------------------------------
runa ENV=dev INCOMES_TENANT=ta INCOMES_FILE="$T/good.tsv" DRY_RUN=0 STUB_CODE=400 \
  STUB_BODY='{"error":"bad_income_invoice","detail":"due_date must not be before issue_date","index":1}'; rc=$?
[[ $rc != 0 ]] && grep -q "FATAL the dev hub refused the import (http 400): bad_income_invoice due_date must not be before issue_date 1" "$T/e" &&
  pass "4. the hub's 400 reported with its index, the run fails" || fail "4. rc=$rc $(cat "$T/e")"

# 5. CONTROL: required inputs -------------------------------------------------
for c in "ENV=stg INCOMES_TENANT=ta INCOMES_FILE=$T/good.tsv" "ENV=dev INCOMES_FILE=$T/good.tsv" \
  "ENV=dev INCOMES_TENANT=ta INCOMES_FILE=$T/none.tsv" "ENV=dev INCOMES_TENANT=ta INCOMES_FILE=$T/good.tsv DRY_RUN=2"; do
  # shellcheck disable=SC2086
  runa $c; rc=$?
  [[ $rc != 0 && ! -s "$T/calls" ]] && pass "5. refused: $c" || fail "5. $c: rc=$rc"
done

echo "---"
(( fails == 0 )) && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
