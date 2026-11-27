#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034  # the stubs are called by the sourced action and set its globals
#------------------------------------------------------------------------------
# Purpose: do_spl_private_ws_invoice_issue (spec 181 row B14), offline: the
#   hub operator call is a fake hub (two private workspaces, acme with 2
#   humans and beta with 1; the hub never lists the non-private one), B4's
#   do_spl_vm_cost_per_day is a stub that answers its trailing 5-day window
#   of synthetic rows. MONTH 2020-02 (29 days, closed).
#   1. DRY_RUN unset -> both quotes printed with the exact summed cost and
#      the hub's count; zero POST calls. DRY_RUN=1 the same.
#   2. DRY_RUN=0 -> two POSTs (acme, beta; never the non-private one) with
#      the exact vmCostMicros; the fake hub holds two invoices.
#   3. a second DRY_RUN=0 -> the same two POSTs answer 200 (replay), the
#      fake hub still holds two invoices, the action says "already issued".
#   4. RED: a partial day, a missing day, a day B4 never read -> refused,
#      zero POSTs, even with DRY_RUN=0.
#   5. RED: an open month (this UTC month) or a future month -> refused
#      before any hub call; a bad MONTH or ENV too.
#   6. WORKSPACE=beta -> the list is asked for beta only, one POST.
#   7. the hub refuses a POST -> rc 1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$ORC/src/bash/run/spl-private-ws-invoice-issue.func.sh"
fails=0
ok() { echo "PASS: $1"; }
ko() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] || { echo "FAIL: no action file $FUNC"; exit 1; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset ENV MONTH WORKSPACE DRY_RUN STUB_DAY STUB_STATE STUB_SKIP STUB_POST
export APP_PATH="$T/app" PROJ_PATH="$T/app/csi-spl-orc"

do_log() { echo "$*"; }
do_require_bin() { :; }
spl_require_cloud_env() { [[ "$1" == dev || "$1" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '$1'"; return 1; }; }
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}
do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
spl_hub_operator_url() { SPL_HUB_URL=https://hub.example; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }

# The fake hub: GET lists the private workspaces (never "plain"), POST issues
# once per (workspace, month) and replays after; every call is logged.
spl_hub_operator_call() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$T/calls.log"
  if [[ "$1" == GET ]]; then
    SPL_HUB_OP_STATUS=200
    case "$2" in
      *'?workspace=beta') SPL_HUB_OP_BODY='{"workspaces":[{"workspace":"beta","humans":1}]}' ;;
      *'?workspace='*) SPL_HUB_OP_BODY='{"workspaces":[]}' ;;
      *) SPL_HUB_OP_BODY='{"workspaces":[{"workspace":"acme","humans":2},{"workspace":"beta","humans":1}]}' ;;
    esac
    return 0
  fi
  local w m c h key
  w=$(jq -r .workspace <<<"$3"); m=$(jq -r .month <<<"$3"); c=$(jq -r .vm_cost_micros <<<"$3")
  [[ "$w" == acme ]] && h=2 || h=1
  [[ -n "${STUB_POST:-}" ]] && { SPL_HUB_OP_STATUS="$STUB_POST"; SPL_HUB_OP_BODY='{"error":"not_private_workspace"}'; return 0; }
  key="$w|$m"
  touch "$T/issued.tsv"
  if grep -q "^$key	" "$T/issued.tsv"; then
    SPL_HUB_OP_STATUS=200; c=$(grep "^$key	" "$T/issued.tsv" | cut -f2)
  else
    SPL_HUB_OP_STATUS=201; printf '%s\t%s\n' "$key" "$c" >>"$T/issued.tsv"
  fi
  SPL_HUB_OP_BODY=$(jq -cn --arg w "$w" --arg m "$m" --argjson c "$c" --argjson h "$h" \
    '{created: true, invoice: {workspace: $w, month: $m, humans: $h, vm_cost_micros: $c, total_micros: "1", issued_on: "x", due_on: "y"}}')
}

# shellcheck disable=SC1090
source "$FUNC"

# B4's stub, after the source: its 5-day window ending DAY. acme costs
# 41000 a day on two boxes (40000 + 1000), beta 1000 x the day of the
# month. STUB_DAY gets STUB_STATE (missing: empty amounts); STUB_SKIP is
# left out of every window.
_spl_pwi_b4() {
  local env="$1" w="$2" day="$3" out="$4" i d dom
  printf '%s\n' "B4 $w $day" >>"$T/b4.log"
  printf 'day\tworkspace\tbox\tstate\tcompute_eur_micros\tdisk_eur_micros\ttraffic_eur_micros\ttotal_eur_micros\treason\n' >"$out"
  for ((i = 4; i >= 0; i--)); do
    d=$(date -u -d "$day -$i day" +%F); dom=$((10#${d:8:2}))
    [[ "$d" == "${STUB_SKIP:-}" ]] && continue
    if [[ "$d" == "${STUB_DAY:-}" && "${STUB_STATE:-}" == missing ]]; then
      printf '%s\t%s\t-\tmissing\t\t\t\t\tthe export has not reached %s\n' "$d" "$w" "$d" >>"$out"; continue
    fi
    local st=ok; [[ "$d" == "${STUB_DAY:-}" ]] && st="$STUB_STATE"
    if [[ "$w" == acme ]]; then
      printf '%s\t%s\tvm-a\t%s\t40000\t0\t0\t40000\t\n' "$d" "$w" "$st" >>"$out"
      printf '%s\t%s\tvm-b\t%s\t1000\t0\t0\t1000\t\n' "$d" "$w" "$st" >>"$out"
    else
      printf '%s\t%s\tvm-b\t%s\t%d\t0\t0\t%d\t\n' "$d" "$w" "$st" "$((dom * 1000))" "$((dom * 1000))" >>"$out"
    fi
  done
}

ACME=$((29 * 41000))   # 1189000
BETA=$((435 * 1000))   # 1+..+29 = 435 -> 435000
posts() { grep -c '^POST' "$T/calls.log" 2>/dev/null || true; }
reset() { rm -f "$T/calls.log" "$T/b4.log"; unset STUB_DAY STUB_STATE STUB_SKIP STUB_POST DRY_RUN WORKSPACE; }
run() { ( ENV=dev MONTH="${M-2020-02}" do_spl_private_ws_invoice_issue ) 2>&1; }

# --- 1. dry run --------------------------------------------------------------
for d in unset 1; do
  reset; [[ "$d" == 1 ]] && export DRY_RUN=1
  out=$(run); rc=$?
  if [[ $rc -eq 0 && "$(posts)" == 0 && "$out" == *"quote acme 2020-02: humans=2 vm_cost_micros=$ACME "* &&
        "$out" == *"quote beta 2020-02: humans=1 vm_cost_micros=$BETA "* && "$out" == *"2 quote(s) above, nothing issued"* ]]; then
    ok "1. DRY_RUN $d: both quotes, exact sums ($ACME, $BETA), zero POST calls"
  else ko "1. DRY_RUN $d: rc=$rc posts=$(posts) out=$out"; fi
done
reset; out=$(run)
[[ "$(grep -c '^B4 acme ' "$T/b4.log")" == 6 && "$(grep '^B4 acme ' "$T/b4.log" | tail -n 1)" == "B4 acme 2020-02-04" ]] &&
  ok "1. six 5-day windows back from 2020-02-29; the last (ending 02-04) reaches the month's first day" ||
  ko "1. the windows: $(cat "$T/b4.log")"

# --- 2. DRY_RUN=0 issues two invoices -----------------------------------------
reset; export DRY_RUN=0; out=$(run); rc=$?
want=$(printf '%s\n' "POST /v1/operator/invoices/issue {\"workspace\":\"acme\",\"month\":\"2020-02\",\"vm_cost_micros\":$ACME}" \
  "POST /v1/operator/invoices/issue {\"workspace\":\"beta\",\"month\":\"2020-02\",\"vm_cost_micros\":$BETA}")
if [[ $rc -eq 0 && "$(grep '^POST' "$T/calls.log")" == "$want" && "$(wc -l <"$T/issued.tsv")" == 2 &&
      "$out" == *"2 invoice(s) issued, 0 already there"* && "$out" == *'"humans":2'* ]]; then
  ok "2. DRY_RUN=0: two POSTs with the exact vm_cost_micros, none for the non-private workspace, two invoices"
else ko "2. DRY_RUN=0: rc=$rc calls=$(cat "$T/calls.log") out=$out"; fi
grep -q plain "$T/calls.log" && ko "2. the non-private workspace was posted" || ok "2. the non-private workspace is never posted"

# --- 3. replay ----------------------------------------------------------------
reset; export DRY_RUN=0; out=$(run); rc=$?
if [[ $rc -eq 0 && "$(posts)" == 2 && "$(wc -l <"$T/issued.tsv")" == 2 && "$out" == *"0 invoice(s) issued, 2 already there"* &&
      "$out" == *"acme 2020-02 was already issued, unchanged"* ]]; then
  ok "3. a second DRY_RUN=0: two replays (200), still two invoices, nothing new"
else ko "3. replay: rc=$rc posts=$(posts) issued=$(wc -l <"$T/issued.tsv") out=$out"; fi

# --- 4. RED: incomplete month -> refused, zero POSTs ---------------------------
rm -f "$T/issued.tsv"
for c in "partial 2020-02-14" "missing 2020-02-29" "missing 2020-02-01" "skip 2020-02-10"; do
  reset; export DRY_RUN=0
  set -- $c
  if [[ "$1" == skip ]]; then export STUB_SKIP="$2"; else export STUB_STATE="$1" STUB_DAY="$2"; fi
  out=$(run); rc=$?
  if [[ $rc -ne 0 && "$(posts)" == 0 && ! -s "$T/issued.tsv" && "$out" == *"$2"* && "$out" == *"NOTHING issued for any workspace"* ]]; then
    ok "4. RED a $1 day ($2), DRY_RUN=0 -> refused, zero POSTs, zero invoices"
  else ko "4. RED $c: rc=$rc posts=$(posts) out=$out"; fi
done
set --

# --- 5. RED: open / future / bad month, bad ENV -> refused before any call ---
for M in "$(date -u +%Y-%m)" 2999-01 2020-13 2020-2 ""; do
  reset; export DRY_RUN=0
  out=$(run); rc=$?
  if [[ $rc -ne 0 && ! -s "$T/calls.log" && ! -s "$T/b4.log" ]]; then ok "5. RED MONTH='$M' -> refused, no hub call, no B4 read"
  else ko "5. RED MONTH='$M': rc=$rc calls=$(cat "$T/calls.log" 2>/dev/null) out=$out"; fi
done
unset M
reset; out=$( ( ENV=prod MONTH=2020-02 DRY_RUN=0 do_spl_private_ws_invoice_issue ) 2>&1); rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && ok "5. ENV=prod -> refused, no call" || ko "5. ENV=prod: rc=$rc $out"

# --- 6. one WORKSPACE -----------------------------------------------------------
rm -f "$T/issued.tsv"; reset; export DRY_RUN=0 WORKSPACE=beta
out=$(run); rc=$?
if [[ $rc -eq 0 && "$(grep -c '^GET /v1/operator/invoices/private-workspaces?workspace=beta ' "$T/calls.log")" == 1 &&
      "$(grep '^POST' "$T/calls.log")" == "POST /v1/operator/invoices/issue {\"workspace\":\"beta\",\"month\":\"2020-02\",\"vm_cost_micros\":$BETA}" ]]; then
  ok "6. WORKSPACE=beta: the list asks for beta only, one POST"
else ko "6. WORKSPACE=beta: rc=$rc calls=$(cat "$T/calls.log") out=$out"; fi
reset; export WORKSPACE=plain DRY_RUN=0; out=$(run); rc=$?
[[ $rc -eq 0 && "$(posts)" == 0 && "$out" == *"no private workspace named plain"* ]] && ok "6. WORKSPACE=plain (not private): nothing to invoice, zero POSTs" ||
  ko "6. WORKSPACE=plain: rc=$rc out=$out"

# --- 7. the hub refuses ---------------------------------------------------------
rm -f "$T/issued.tsv"; reset; export DRY_RUN=0 STUB_POST=409
out=$(run); rc=$?
[[ $rc -eq 1 && "$(posts)" == 1 && "$out" == *"did not issue acme 2020-02 (http 409: not_private_workspace)"* ]] &&
  ok "7. a hub refusal stops the run (rc 1) after that POST" || ko "7. hub refusal: rc=$rc posts=$(posts) out=$out"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
