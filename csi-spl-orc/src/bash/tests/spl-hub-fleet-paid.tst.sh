#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_fleet_paid (SPL-2342, rdb 0205), with the hub operator
#          call stubbed:
#   1. list (the default) and effective GET as the SA, no DRY_RUN needed;
#      FROM / TO ride the query
#   2. create and delete are dry by default: print, call nothing
#   3. bad input is refused before any call
#   4. DRY_RUN=0 create POSTs the exact body; delete DELETEs the id
#   5. hub refusals (400, 403) fail
#   6. PAID_FX=1 effective (SPL-3791): per vendor, the non-USD items of the
#      read and how many took a rate on or before their period start (their
#      own period) rather than the first one after it; counts only, no amount
#   7. update (SPL-3890) PATCHes PAID_ID with only the fields given, dry by
#      default; no field, a bad field or a bad id is refused before any call
#   8. index (SPL-4843), through the real ./run: id, vendor, kind and the
#      period days only; no amount, currency, quantity, note or plan label on
#      stdout, stderr or in any file the run wrote, a refusal included; red
#      control: the same check finds list's figures
#   9. index when the hub breaks its contract (SPL-5084): a multi-line error
#      stays out of the log line, a field off its format prints "?", a
#      non-object item or a second JSON document is refused before any OK line;
#      the body file is written 0600
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() { echo "hub $1 $2 ${3:-}" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; [[ "$2" == */paid && -n "${STUB_LIST:-}" ]] && SPL_HUB_OP_BODY="$STUB_LIST"; return 0; }
    do_spl_hub_fleet_paid' >"$T/o" 2>&1
}
ID=0a1b2c3d-1111-4222-8333-444455556666
ITEM='{"id":"'$ID'","vendor":"agy","kind":"topup","plan_label":"fixture","quantity":1,"amount":1,"currency":"USD","period_start":"2020-01-01","period_end":"2020-01-02","created_by":"sa@example.iam.gserviceaccount.com"}'
CREATE=(PAID_CMD=create VENDOR=agy KIND=topup PLAN_LABEL=fixture AMOUNT=1 CURRENCY=USD PERIOD_START=2020-01-01 PERIOD_END=2020-01-02)
BODY='{"vendor":"agy","kind":"topup","plan_label":"fixture","quantity":1,"amount":1,"currency":"USD","period_start":"2020-01-01","period_end":"2020-01-02","note":""}'

# --- 1. reads -------------------------------------------------------------------
run STUB_BODY="{\"items\":[$ITEM]}"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-tokens/paid ' "$T/calls" && grep -q '^OK dev paid items: 1' "$T/o" \
  && grep -qF "$ID agy topup fixture 1 x 1 USD [2020-01-01, 2020-01-02)" "$T/o" && pass "1. list GETs and prints each item" || fail "1. list: rc=$rc $(cat "$T/calls" "$T/o")"
run STUB_BODY='{"items":[]}'; rc=$?
[[ $rc -eq 0 ]] && grep -q '^OK dev paid items: 0' "$T/o" && pass "1. an empty list reads 0" || fail "1. empty: rc=$rc $(cat "$T/o")"
run PAID_CMD=effective FROM=2026-09-01 TO=2026-10-01 STUB_BODY='{"from":"2026-09-01","to":"2026-10-01","days":30,"vendors":[{"vendor":"agy","status":"not_metered","tokens":0,"cache_read":0,"paid_usd":20,"paid_per_day_usd":0.6667,"effective_usd_per_mtok":null,"list_usd_per_mtok":null}]}'; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-tokens/effective?from=2026-09-01&to=2026-10-01 ' "$T/calls" \
  && grep -q 'agy not_metered tokens=0 cache_read=0 paid_usd=20 per_day=0.6667' "$T/o" && pass "1. effective GETs with from and to" || fail "1. effective: rc=$rc $(cat "$T/calls" "$T/o")"
run PAID_CMD=effective STUB_BODY='{"from":"a","to":"b","days":30,"vendors":[]}'; rc=$?
grep -qx 'hub GET /v1/operator/fleet-tokens/effective ' "$T/calls" && pass "1. effective without FROM / TO sends no query" || fail "1. bare effective: $(cat "$T/calls")"

# --- 2. dry by default ----------------------------------------------------------
run "${CREATE[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qF "OK DRY_RUN would POST /v1/operator/fleet-tokens/paid $BODY to https://hub.invalid in dev" "$T/o" \
  && pass "2. create is dry by default: the exact body, 0 calls" || fail "2. dry create: rc=$rc $(cat "$T/calls" "$T/o")"
run PAID_CMD=delete PAID_ID=$ID; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would DELETE /v1/operator/fleet-tokens/paid/$ID" "$T/o" \
  && pass "2. delete is dry by default, 0 calls" || fail "2. dry delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. refusals before any call ------------------------------------------------
for bad in VENDOR=gpt KIND=gift PLAN_LABEL= AMOUNT=0 AMOUNT=-1 AMOUNT=1e3 CURRENCY=usd PERIOD_END=2020-01-01 PERIOD_START=2020-1-1 QUANTITY=0 DRY_RUN=yes; do
  run "${CREATE[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "3. create $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
for bad in "PAID_CMD=drop" "PAID_CMD=delete PAID_ID=1;rm" "PAID_CMD=effective FROM=yesterday"; do
  # shellcheck disable=SC2086 # two assignments on purpose
  run DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "3. $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 4. writes ------------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ITEM"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub POST /v1/operator/fleet-tokens/paid $BODY" "$T/calls" && grep -q "^OK dev paid item created: $ID (agy topup fixture)" "$T/o" \
  && pass "4. create POSTs the body as the SA" || fail "4. create: rc=$rc $(cat "$T/calls" "$T/o")"
run "${CREATE[@]}" QUANTITY=3 AMOUNT=200.5 NOTE="three seats" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ITEM"; rc=$?
grep -qF '"quantity":3,"amount":200.5' "$T/calls" && grep -qF '"note":"three seats"' "$T/calls" \
  && pass "4. quantity, a decimal amount and the note ride the body" || fail "4. qty: $(cat "$T/calls")"
run PAID_CMD=delete PAID_ID=$ID DRY_RUN=0 STUB_CODE=204; rc=$?
[[ $rc -eq 0 ]] && grep -qx "hub DELETE /v1/operator/fleet-tokens/paid/$ID " "$T/calls" && grep -q "deleted" "$T/o" \
  && pass "4. delete DELETEs the id" || fail "4. delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_paid_item","detail":"currency must be USD or one the hub holds an exchange rate for"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused it (400): currency must be USD' "$T/o" && pass "5. 400 fails with the hub's detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"forbidden"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"

# --- 6. PAID_FX=1: own-period rate counts -----------------------------------------
it() { printf '{"id":"%s","vendor":"%s","currency":"%s","period_start":"%s","amount":7}' "$@"; }
LIST="{\"items\":[$(it i1 claude EUR 2024-07-01),$(it i2 claude GBP 2025-03-01),$(it i3 claude USD 2025-04-01),$(it i4 agy EUR 2026-10-01),$(it i5 agy EUR 2026-09-01)]}"
sh() { printf '{"id":"%s","fx_rate":%s,"fx_rate_day":%s,"paid_usd":7}' "$@"; }
EFF="{\"from\":\"2024-07-01\",\"to\":\"2025-07-01\",\"days\":365,\"vendors\":[{\"vendor\":\"claude\",\"status\":\"effective\",\"items\":[$(sh i1 0.9 '"2024-07-01"'),$(sh i2 0.8 '"2026-09-28"'),$(sh i3 null null)]},{\"vendor\":\"agy\",\"status\":\"effective\",\"items\":[$(sh i4 0.9 '"2026-09-30"'),$(sh i5 null null)]},{\"vendor\":\"qwen\",\"status\":\"list_only\",\"items\":[]}]}"
run PAID_CMD=effective PAID_FX=1 STUB_BODY="$EFF" STUB_LIST="$LIST"; rc=$?
if [[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-tokens/paid ' "$T/calls" \
  && grep -qx '  claude fx non_usd=2 own_period=1 first_after=1 no_rate=0' "$T/o" \
  && grep -qx '  agy fx non_usd=2 own_period=1 first_after=0 no_rate=1' "$T/o" \
  && grep -qx '  qwen fx non_usd=0 own_period=0 first_after=0 no_rate=0' "$T/o"; then
  pass "6. PAID_FX=1 counts per vendor: own period (rate day <= start), first after, no rate; USD left out"
else
  fail "6. PAID_FX: rc=$rc $(cat "$T/calls" "$T/o")"
fi
grep -q 'fx non_usd' "$T/o" && ! grep -qE 'fx .*(amount|paid_usd|0\.9|=7)' "$T/o" && pass "6. the fx lines carry counts only (no amount, no rate)" || fail "6. fx lines leak: $(grep fx "$T/o")"
run PAID_CMD=effective STUB_BODY="$EFF" STUB_LIST="$LIST"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'fleet-tokens/paid ' "$T/calls" && ! grep -q 'fx non_usd' "$T/o" && pass "6. without PAID_FX: no list call, no fx line (unchanged)" || fail "6. no PAID_FX: $(cat "$T/calls")"

# --- 7. update: PATCH only the fields given (SPL-3890) ------------------------------
UPD=(PAID_CMD=update "PAID_ID=$ID" PERIOD_END=2027-10-01 "NOTE=paid once for 12 months")
UBODY='{"period_end":"2027-10-01","note":"paid once for 12 months"}'
run "${UPD[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qF "OK DRY_RUN would PATCH /v1/operator/fleet-tokens/paid/$ID $UBODY to https://hub.invalid in dev" "$T/o" \
  && pass "7. update is dry by default: the exact body, 0 calls" || fail "7. dry update: rc=$rc $(cat "$T/calls" "$T/o")"
UITEM='{"id":"'$ID'","vendor":"mistral","kind":"topup","plan_label":"fixture","quantity":1,"amount":479.8,"currency":"EUR","period_start":"2026-10-01","period_end":"2027-10-01"}'
run "${UPD[@]}" DRY_RUN=0 STUB_BODY="$UITEM"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub PATCH /v1/operator/fleet-tokens/paid/$ID $UBODY" "$T/calls" \
  && grep -qxF "OK dev paid item $ID updated: mistral topup fixture 1 x 479.8 EUR [2026-10-01, 2027-10-01)" "$T/o" \
  && pass "7. update PATCHes only the given fields and prints the item as stored" || fail "7. update: rc=$rc $(cat "$T/calls" "$T/o")"
run PAID_CMD=update PAID_ID=$ID AMOUNT=12.5 QUANTITY=2 DRY_RUN=0 STUB_BODY="$UITEM"; rc=$?
grep -qxF "hub PATCH /v1/operator/fleet-tokens/paid/$ID {\"quantity\":2,\"amount\":12.5}" "$T/calls" \
  && pass "7. numbers ride as numbers, nothing else in the body" || fail "7. numbers: $(cat "$T/calls")"
for bad in "PAID_ID=" "PAID_ID=1;rm" "PERIOD_END=" "PERIOD_END=2027-1-1" "AMOUNT=0" "KIND=gift" "PERIOD_START=2027-10-01" "DRY_RUN=yes"; do
  run PAID_CMD=update PAID_ID=$ID PERIOD_END=2027-10-01 DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "7. update $bad refused, no call" || fail "7. update $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run PAID_CMD=update PAID_ID=$ID DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'FATAL update needs at least one field' "$T/o" && pass "7. update with no field refused, no call" || fail "7. no field: rc=$rc $(cat "$T/calls" "$T/o")"
run "${UPD[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'answered 404' "$T/o" && pass "7. a 404 on update fails" || fail "7. 404: rc=$rc $(cat "$T/o")"

# --- 8. index (SPL-4843): no figure on stdout, stderr or in any file the run wrote ---
# Through the real ./run (its stdout / stderr tees, do_log's day log, the state
# dir), with only gcloud and curl stubbed on PATH and HOME / VAR_DIR in $T.
mkdir -p "$T/real/stub"
cat >"$T/real/stub/gcloud" <<'STUB'
#!/usr/bin/env bash
case "$*" in "auth print-identity-token "*|"auth print-access-token "*) echo tok-fake ;; esac
STUB
cat >"$T/real/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while (( $# )); do case "$1" in -o) out="$2"; shift ;; -X) echo "curl $2" >>"$STUB_CALLS"; shift ;; http*) url="$1" ;; esac; shift; done
echo "url $url" >>"$STUB_CALLS"; cp "$STUB_BODY_FILE" "$out"; echo "mode $(stat -c %a "$out")" >>"$STUB_CALLS"; printf '%s' "${STUB_CODE:-200}"
STUB
chmod +x "$T/real/stub/gcloud" "$T/real/stub/curl"
SECRET_ITEM='{"id":"'$ID'","vendor":"agy","kind":"topup","plan_label":"LABEL-SENTINEL","quantity":4321,"amount":98765.4321,"currency":"XTS","note":"NOTE-SENTINEL","period_start":"2020-01-01","period_end":"2020-01-02","created_by":"sa@example.iam.gserviceaccount.com"}'
echo "{\"items\":[$SECRET_ITEM]}" >"$T/real/items.json"
echo '{"error":"forbidden","detail":"98765.4321 XTS NOTE-SENTINEL LABEL-SENTINEL"}' >"$T/real/refusal.json"
run_real() { # <name> <PAID_CMD> <body file> [VAR=value]... -> $T/real/<name>/{out,err,home,var,calls}
  local d="$T/real/$1" cmd="$2" body="$3"; shift 3
  rm -rf "$d"; mkdir -p "$d/home" "$d/var"
  # the compact log form, whatever the caller's: an outer ./run on a tty
  # exports RUN_LOG_COMPACT=0, and legs 8 and 9 grep the compact FATAL line
  env RUN_LOG=compact RUN_LOG_COMPACT=1 HOME="$d/home" VAR_DIR="$d/var" PATH="$T/real/stub:$PATH" STUB_BODY_FILE="$body" STUB_CALLS="$d/calls" \
    GCP_ACCOUNT=sa@example.iam.gserviceaccount.com ENV=dev PAID_CMD="$cmd" "$@" "$PROJ_ROOT/run" -a do_spl_hub_fleet_paid >"$d/out" 2>"$d/err"
}
leaks() { # <dir> -> each file of the run holding a sentinel: out, err, anything under home / var
  grep -rlE '98765|4321|XTS|NOTE-SENTINEL|LABEL-SENTINEL' "$1/out" "$1/err" "$1/home" "$1/var" 2>/dev/null
}
logs() { find "$1/home" "$1/var" -type f -name '*.log' | wc -l; }
run_real index index "$T/real/items.json"; rc=$?
d="$T/real/index"
[[ $rc -eq 0 ]] && grep -qx 'curl GET' "$d/calls" && grep -q '^url https://.*/v1/operator/fleet-tokens/paid$' "$d/calls" \
  && grep -qxF "  $ID agy topup [2020-01-01, 2020-01-02)" "$d/out" \
  && pass "8. index GETs the list through ./run and prints id, vendor, kind and both period days" \
  || fail "8. index: rc=$rc $(cat "$d/calls" "$d/out" "$d/err")"
found=$(leaks "$d"); n=$(logs "$d")
[[ $n -ge 3 && -z "$found" ]] && pass "8. index: no amount, currency, quantity, note or label on stdout, stderr or in any file the run wrote ($n log files)" \
  || fail "8. index leaks (log files=$n): $found"
run_real refused index "$T/real/refusal.json" STUB_CODE=403; rc=$?
d="$T/real/refused"; found=$(leaks "$d"); n=$(logs "$d")
[[ $rc -ne 0 && $n -ge 3 && -z "$found" ]] && grep -q 'FATAL the hub answered 403 (forbidden)' "$d/out" \
  && pass "8. a refused index fails with its code only, the body's detail nowhere ($n log files)" \
  || fail "8. refused index: rc=$rc logs=$n leaks=$found $(cat "$d/out")"
run_real list list "$T/real/items.json"; rc=$?
found=$(leaks "$T/real/list")
[[ $rc -eq 0 ]] && grep -qxF "$T/real/list/out" <<<"$found" \
  && pass "8. red control: the same check finds PAID_CMD=list's figures ($(wc -l <<<"$found") files)" \
  || fail "8. red control: rc=$rc, list showed no sentinel, so the check proves nothing"

# --- 9. index when the hub breaks its contract (SPL-5084) ---------------------------
echo '{"error":"line_one\nline_two","detail":"98765.4321 XTS"}' >"$T/real/multiline.json"
run_real multiline index "$T/real/multiline.json" STUB_CODE=403; rc=$?
d="$T/real/multiline"; found=$(leaks "$d")
[[ $rc -ne 0 && -z "$found" ]] && grep -q 'FATAL the hub answered 403 to the paid item index' "$d/out" && ! grep -q 'line_' "$d/out" \
  && pass "9. a multi-line error is left out, the log line stays whole" \
  || fail "9. multi-line: rc=$rc leaks=$found"
echo '{"items":[{"id":{"amount":98765.4321},"vendor":"agy","kind":"topup","period_start":"2020-01-01","period_end":"2020-01-02"}]}' >"$T/real/objfield.json"
run_real objfield index "$T/real/objfield.json"; rc=$?
d="$T/real/objfield"; found=$(leaks "$d")
[[ $rc -eq 0 && -z "$found" ]] && grep -qxF "  ? agy topup [2020-01-01, 2020-01-02)" "$d/out" \
  && pass "9. an object-valued field prints ?, its amount nowhere" \
  || fail "9. object field: rc=$rc leaks=$found"
echo "{\"items\":[$SECRET_ITEM,5]}" >"$T/real/nonobj.json"
run_real nonobj index "$T/real/nonobj.json"; rc=$?
d="$T/real/nonobj"
[[ $rc -ne 0 ]] && grep -q 'FATAL the paid item list is not' "$d/out" && ! grep -q 'paid items:' "$d/out" && ! grep -qF "$ID" "$d/out" \
  && pass "9. a non-object item is refused before any OK line or item" \
  || fail "9. non-object item: rc=$rc"
( umask 022; run_real mode index "$T/real/items.json" ); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'mode 600' "$T/real/mode/calls" \
  && pass "9. the body file is written 0600 under a caller's umask 022" \
  || fail "9. body mode: rc=$rc $(grep '^mode' "$T/real/mode/calls")"
strid() { printf '{"items":[{"id":%s,"vendor":"agy","kind":"topup","period_start":"2020-01-01","period_end":"2020-01-02"}]}\n' "$1"; }
strid '"98765.4321 XTS"' >"$T/real/strfield.json"
run_real strfield index "$T/real/strfield.json"; rc=$?
d="$T/real/strfield"; found=$(leaks "$d")
[[ $rc -eq 0 && -z "$found" ]] && grep -qxF "  ? agy topup [2020-01-01, 2020-01-02)" "$d/out" \
  && pass "9. a string field off its format prints ?, its amount nowhere" \
  || fail "9. string field: rc=$rc leaks=$found"
strid '"a\nFORGED line"' >"$T/real/forge.json"
run_real forge index "$T/real/forge.json"; rc=$?
d="$T/real/forge"
[[ $rc -eq 0 ]] && ! grep -q 'FORGED' "$d/out" && pass "9. a newline in a field forges no line" || fail "9. forged line: rc=$rc"
printf '{"items":98765.4321}\n{"items":[]}\n' >"$T/real/twodocs.json"
run_real twodocs index "$T/real/twodocs.json"; rc=$?
d="$T/real/twodocs"; found=$(leaks "$d")
[[ $rc -ne 0 && -z "$found" ]] && grep -q 'FATAL the paid item list is not' "$d/out" && ! grep -q 'paid items:' "$d/out" \
  && pass "9. two JSON documents are refused, the figure in the first nowhere" \
  || fail "9. two documents: rc=$rc leaks=$found"
printf '{"error":"first_doc"}\n{"error":"second_doc"}\n' >"$T/real/twoerrs.json"
run_real twoerrs index "$T/real/twoerrs.json" STUB_CODE=403; rc=$?
d="$T/real/twoerrs"
[[ $rc -ne 0 ]] && grep -q 'FATAL the hub answered 403 to the paid item index' "$d/out" && ! grep -q '_doc' "$d/out" \
  && pass "9. a two-document refusal names its code only, the log line stays whole" \
  || fail "9. two-document refusal: rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
