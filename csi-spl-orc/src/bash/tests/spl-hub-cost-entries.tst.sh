#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_cost_entries (SPL-4824, rdb 0245), with the hub
#          operator call stubbed:
#   1. list (the default) GETs as the SA, no DRY_RUN needed; COST_TYPE and
#      COST_MONTH ride the query
#   2. create and delete are dry by default: print, call nothing
#   3. bad input is refused before any call
#   4. DRY_RUN=0 create POSTs the exact body; delete DELETEs the id
#   5. hub refusals (400, 403) fail
#   6. the amount is the NET (owner poll 68d7f768, answer 4): COST_GROSS
#      rides the note as "gross <x> <cur>"; a gross below the net, or a
#      note too long with it, is refused before any call
#   7. figure-free (SPL-4877): create (dry, 201, 400) and the input refusals,
#      run through the real ./run (HOME, VAR_DIR, TMPDIR in the test dir, a
#      stub gcloud and a stub hub behind curl), print no amount, currency or
#      note: no sentinel figure in stdout, stderr or any file the run wrote
#   8. index (SPL-4891): the list GET, printed as id period type per row and
#      <period> rows=<n> per period; COST_EXPECT_FILE adds sum=OK|MISMATCH|
#      UNCHECKED (raw amounts, no FX, within half a cent: one cent off is a
#      MISMATCH) | BADROW (an amount that is not a number); COST_MONTH keeps
#      only its period of the file; a bad file line (by its number), a
#      directory as the file and a malformed hub answer are refused; through
#      the real ./run no amount, currency, label, note or expected sum
#      reaches stdout, stderr or a file
# RED CONTROL: case 2 fails when the dry-run guard is dropped (the call file
# then holds the POST). Case 7 fails on the action before SPL-4877 (it logged
# the body, the created row's amount and currency, and the hub's detail).
# Case 8 fails when the index prints a row's amount, or compares whole units
# instead of cents (the plants in the commit).
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
    spl_hub_operator_call() { echo "hub $1 $2 ${3:-}" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; return 0; }
    do_spl_hub_cost_entries' >"$T/o" 2>&1
}
ID=0a1b2c3d-1111-4222-8333-444455556666
ENTRY='{"id":"'$ID'","type":"cloud","label":"Suite fixture","amount":64.8,"currency":"EUR","period":"2020-01","note":"","created_by":"sa@example.iam.gserviceaccount.com"}'
CREATE=(COST_CMD=create COST_TYPE=cloud "COST_LABEL=Suite fixture" COST_AMOUNT=64.80 COST_CURRENCY=EUR COST_PERIOD=2020-01)
BODY='{"type":"cloud","label":"Suite fixture","amount":64.8,"currency":"EUR","period":"2020-01","note":""}'

# --- 1. reads -------------------------------------------------------------------
run STUB_BODY="{\"entries\":[$ENTRY]}"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/cost-entries ' "$T/calls" && grep -q '^OK dev cost entries: 1' "$T/o" \
  && grep -qxF "  $ID 2020-01 cloud 64.8 EUR Suite fixture" "$T/o" && pass "1. list GETs and prints each entry" || fail "1. list: rc=$rc $(cat "$T/calls" "$T/o")"
run COST_TYPE=cloud COST_MONTH=2026-01 STUB_BODY='{"entries":[]}'; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/cost-entries?type=cloud&month=2026-01 ' "$T/calls" && grep -q '^OK dev cost entries: 0' "$T/o" \
  && pass "1. the type and month filters ride the query" || fail "1. filters: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. dry by default ----------------------------------------------------------
run "${CREATE[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qF "OK DRY_RUN would POST /v1/operator/cost-entries period=2020-01 type=cloud label=Suite fixture to https://hub.invalid in dev" "$T/o" \
  && ! grep -qF '64.8' "$T/o" && pass "2. create is dry by default: period, type, label, no figure, 0 calls" || fail "2. dry create: rc=$rc $(cat "$T/calls" "$T/o")"
run COST_CMD=delete COST_ID=$ID; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would DELETE /v1/operator/cost-entries/$ID" "$T/o" \
  && pass "2. delete is dry by default, 0 calls" || fail "2. dry delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. refusals before any call ------------------------------------------------
for bad in COST_TYPE=ai COST_LABEL= "COST_LABEL=   " COST_AMOUNT=0 COST_AMOUNT=-1 COST_AMOUNT=1e3 COST_CURRENCY=eur COST_PERIOD=2020-13 COST_PERIOD=2020-01-01 DRY_RUN=yes; do
  run "${CREATE[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "3. create $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
for bad in "COST_CMD=drop" "COST_CMD=delete COST_ID=1;rm" "COST_MONTH=2020-1" "COST_TYPE=ai"; do
  # shellcheck disable=SC2086 # two assignments on purpose
  run DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "3. $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 4. writes ------------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ENTRY"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub POST /v1/operator/cost-entries $BODY" "$T/calls" && grep -qxF "OK dev cost entry created: $ID 2020-01 cloud Suite fixture" "$T/o" \
  && pass "4. create POSTs the body as the SA" || fail "4. create: rc=$rc $(cat "$T/calls" "$T/o")"
run "${CREATE[@]}" "COST_NOTE=invoice 1" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ENTRY"; rc=$?
grep -qF '"note":"invoice 1"' "$T/calls" && pass "4. the note rides the body" || fail "4. note: $(cat "$T/calls")"
run COST_CMD=delete COST_ID=$ID DRY_RUN=0 STUB_CODE=204; rc=$?
[[ $rc -eq 0 ]] && grep -qx "hub DELETE /v1/operator/cost-entries/$ID " "$T/calls" && grep -q "deleted" "$T/o" \
  && pass "4. delete DELETEs the id" || fail "4. delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_cost_entry","detail":"period must be a month YYYY-MM"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qx 'FATAL the hub refused it (400) (bad_cost_entry)' "$T/o" && pass "5. 400 fails with the hub's error code, not its detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"forbidden"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"
run COST_CMD=delete COST_ID=$ID DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'answered 404' "$T/o" && pass "5. a 404 on delete fails" || fail "5. 404: rc=$rc $(cat "$T/o")"

# --- 6. net amount, gross kept in the note -----------------------------------------
run "${CREATE[@]}" COST_GROSS=80.35 DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ENTRY"; rc=$?
[[ $rc -eq 0 ]] && grep -qF '"amount":64.8,"currency":"EUR","period":"2020-01","note":"gross 80.35 EUR"}' "$T/calls" \
  && pass "6. the net is the amount, the gross rides the note" || fail "6. gross: rc=$rc $(cat "$T/calls" "$T/o")"
run "${CREATE[@]}" COST_GROSS=64.80 "COST_NOTE=invoice 1" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ENTRY"; rc=$?
grep -qF '"note":"gross 64.80 EUR; invoice 1"' "$T/calls" && pass "6. a gross equal to the net (VAT 0 %) and a note: both kept" || fail "6. gross+note: $(cat "$T/calls")"
for bad in COST_GROSS=64.79 COST_GROSS=0 COST_GROSS=abc; do
  run "${CREATE[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "6. $bad refused, no call" || fail "6. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run "${CREATE[@]}" COST_GROSS=64.80 "COST_NOTE=$(printf 'x%.0s' {1..1995})" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'FATAL COST_NOTE with the gross' "$T/o" && pass "6. a note too long once the gross is in it: refused, no call" || fail "6. long note: rc=$rc $(cat "$T/o")"

# --- 7. figure-free through the real ./run (SPL-4877) ---------------------------------
# The sentinels: no real figure, and none of them is in any line a figure-free
# run prints (ids, dates, the hub URL, the SA email).
SENT=(98765.4321 XTS NOTE-SENTINEL 99999.1234)
mkdir -p "$T/fs/stub"
printf '#!/bin/sh\ncase "$*" in *print-identity-token*|*print-access-token*) echo tok-stub;; esac\n' >"$T/fs/stub/gcloud"
# the stub hub: the request body to $HUB_LOG (outside the scanned dirs: the
# proof the figures did reach the hub), $STUB_BODY to curl's -o, $STUB_CODE out
cat >"$T/fs/stub/curl" <<'EOF'
#!/usr/bin/env bash
out=""; while (($#)); do case "$1" in -o) out="$2"; shift ;; --data) printf '%s\n' "$2" >>"$HUB_LOG" ;; esac; shift; done
printf '%s' "$STUB_BODY" >"$out"; printf '%s' "$STUB_CODE"
EOF
chmod +x "$T/fs/stub/gcloud" "$T/fs/stub/curl"
# real_run <name> [VAR=value]... -> ./run -a do_spl_hub_cost_entries in a clean
# env with its own HOME, VAR_DIR and TMPDIR under $T/fs/<name>
real_run() {
  local d="$T/fs/$1"; shift
  mkdir -p "$d/home" "$d/var" "$d/tmp"
  (cd "$PROJ_ROOT" && env -i PATH="$T/fs/stub:$PATH" HOME="$d/home" VAR_DIR="$d/var" TMPDIR="$d/tmp" \
    SPOOL_TEST=1 SPL_PRIVATE_CNF="$SPL_PRIVATE_CNF" SPL_PRIVATE_WARN=0 HUB_LOG="$T/fs/hub.log" ENV=dev \
    GCP_ACCOUNT=sa@example.iam.gserviceaccount.com COST_CMD=create COST_TYPE=cloud COST_LABEL=fs-fixture \
    COST_AMOUNT=98765.4321 COST_GROSS=99999.1234 COST_CURRENCY=XTS COST_PERIOD=2020-01 COST_NOTE=NOTE-SENTINEL \
    "$@" ./run -a do_spl_hub_cost_entries >"$d/stdout" 2>"$d/stderr")
}
# leaks <name> -> each sentinel found in that run's stdout, stderr or any file
# under its HOME, VAR_DIR and TMPDIR, as "<sentinel>:<file>"; nothing = clean
leaks() {
  local d="$T/fs/$1" s f
  for s in "${SENT[@]}"; do
    while IFS= read -r f; do echo "$s:${f#"$d"/}"; done < <(grep -rlF -- "$s" "$d" 2>/dev/null)
  done
}
NEW_ROW='{"id":"'$ID'","type":"cloud","label":"fs-fixture","amount":98765.4321,"currency":"XTS","period":"2020-01","note":"gross 99999.1234 XTS; NOTE-SENTINEL"}'
REFUSED='{"error":"bad_cost_entry","detail":"amount 98765.4321 XTS NOTE-SENTINEL refused"}'
real_run dry; rc=$?
[[ $rc -eq 0 && ! -s "$T/fs/hub.log" ]] && grep -qF 'would POST /v1/operator/cost-entries period=2020-01 type=cloud label=fs-fixture' "$T/fs/dry/stdout" \
  && pass "7. ./run DRY_RUN=1 create: one line with period, type, label, no call" || fail "7. dry: rc=$rc $(cat "$T/fs/dry/stdout" "$T/fs/dry/stderr")"
real_run ok DRY_RUN=0 STUB_CODE=201 STUB_BODY="$NEW_ROW"; rc=$?
[[ $rc -eq 0 ]] && grep -qF "cost entry created: $ID 2020-01 cloud fs-fixture" "$T/fs/ok/stdout" \
  && grep -qF '"amount":98765.4321,"currency":"XTS"' "$T/fs/hub.log" && grep -qF 'NOTE-SENTINEL' "$T/fs/hub.log" \
  && pass "7. ./run create 201: id period type label; the figures went to the hub" || fail "7. 201: rc=$rc $(cat "$T/fs/ok/stdout" "$T/fs/ok/stderr" "$T/fs/hub.log")"
real_run refused DRY_RUN=0 STUB_CODE=400 STUB_BODY="$REFUSED"; rc=$?
[[ $rc -ne 0 ]] && grep -qF 'the hub refused it (400) (bad_cost_entry)' "$T/fs/refused/stdout" \
  && pass "7. ./run create 400: the HTTP code and the hub's error code" || fail "7. 400: rc=$rc $(cat "$T/fs/refused/stdout" "$T/fs/refused/stderr")"
real_run r403 DRY_RUN=0 STUB_CODE=403 STUB_BODY="$REFUSED"; rc4=$?
real_run r404 DRY_RUN=0 STUB_CODE=404 STUB_BODY="$REFUSED"; rc5=$?
real_run r500 DRY_RUN=0 STUB_CODE=500 STUB_BODY="$REFUSED"; rc6=$?
[[ $rc4 -ne 0 && $rc5 -ne 0 && $rc6 -ne 0 ]] && grep -qF '(403) (bad_cost_entry)' "$T/fs/r403/stdout" \
  && grep -qF 'answered 404 (bad_cost_entry)' "$T/fs/r404/stdout" && grep -qF 'answered 500 (bad_cost_entry)' "$T/fs/r500/stdout" \
  && pass "7. ./run 403, 404, 500: the HTTP code and the hub's error code" || fail "7. 403/404/500: rc=$rc4/$rc5/$rc6"
real_run badamount DRY_RUN=0 COST_AMOUNT=98765.43210; rc=$?
real_run badcur DRY_RUN=0 COST_CURRENCY=XTSX; rc2=$?
real_run grossbelow DRY_RUN=0 COST_GROSS=1; rc3=$?
real_run swapped DRY_RUN=0 COST_PERIOD=98765.4321; rc7=$?
[[ $rc -ne 0 && $rc2 -ne 0 && $rc3 -ne 0 && $rc7 -ne 0 ]] && grep -q 'FATAL COST_AMOUNT' "$T/fs/badamount/stdout" "$T/fs/badamount/stderr" \
  && grep -q 'FATAL COST_GROSS is below' "$T/fs/grossbelow/stdout" "$T/fs/grossbelow/stderr" \
  && pass "7. ./run input refusals (amount, currency, gross below net, a figure as the period) fail" || fail "7. input refusals: rc=$rc/$rc2/$rc3/$rc7"
for r in dry ok refused r403 r404 r500 badamount badcur grossbelow swapped; do
  n=$(find "$T/fs/$r" -type f | wc -l)
  l="$(leaks "$r" | tr "\n" " ")"
  [[ -z "$l" && $n -gt 2 ]] && pass "7. $r: no amount, currency or note in stdout, stderr or the $((n - 2)) file(s) the run wrote" \
    || fail "7. $r leaks (files=$n): $l"
done

# --- 8. index: figure-free read back (SPL-4891) ---------------------------------------
ROWS='{"entries":[
 {"id":"'$ID'","type":"cloud","label":"LABEL-SENTINEL","amount":98765.4321,"currency":"XTS","period":"2020-01","note":"NOTE-SENTINEL"},
 {"id":"'$ID'","type":"cloud","label":"fs-fixture","amount":11111.5555,"currency":"XTS","period":"2020-01","note":""},
 {"id":"not-a-uuid 98765.4321","type":"hr","label":"fs-fixture","amount":"22222.7777","currency":"XTS","period":"2020-02","note":""},
 {"id":"'$ID'","type":"hr","label":"fs-fixture","amount":1,"currency":"XTS","period":"2020-04","note":""}]}'
printf '2020-01\t109876.99\n2020-02\t33333.33\r\n\n2020-03\t0\n' >"$T/fs/expect.tsv"
INDEX_OUT=("  $ID 2020-01 cloud" "  $ID 2020-01 cloud" "  ? 2020-02 hr" "  $ID 2020-04 hr")
run COST_CMD=index COST_TYPE=cloud STUB_BODY="$ROWS"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/cost-entries?type=cloud ' "$T/calls" && grep -qx 'OK dev cost entries (index, figure-free): 4' "$T/o" \
  && diff <(grep '^  ' "$T/o") <(printf '%s\n' "${INDEX_OUT[@]}") >/dev/null \
  && diff <(grep '^2020' "$T/o") <(printf '%s\n' '2020-01 rows=2' '2020-02 rows=1' '2020-04 rows=1') >/dev/null \
  && pass "8. index GETs with the filters and prints id period type per row, rows per period" || fail "8. index: rc=$rc $(cat "$T/calls" "$T/o")"
run COST_CMD=index COST_EXPECT_FILE="$T/fs/expect.tsv" STUB_BODY="$ROWS"; rc=$?
[[ $rc -eq 0 ]] && diff <(grep '^2020' "$T/o") <(printf '%s\n' '2020-01 rows=2 sum=OK' '2020-02 rows=1 sum=MISMATCH' \
  '2020-03 rows=0 sum=OK' '2020-04 rows=1 sum=UNCHECKED') >/dev/null \
  && pass "8. COST_EXPECT_FILE: OK to the cent, MISMATCH, an empty expected month OK, UNCHECKED" || fail "8. expect: rc=$rc $(cat "$T/o")"
for bad in '2020-01 109876.99' '2020-01\t1e5' '2020-13\t1' '2020-01\t-1' '2020-01\t01.5'; do
  printf '%b\n' "$bad" >"$T/fs/bad.tsv"
  run COST_CMD=index COST_EXPECT_FILE="$T/fs/bad.tsv" STUB_BODY="$ROWS"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -qx 'FATAL COST_EXPECT_FILE line 1 must be period<TAB>sum (the value is not printed)' "$T/o" \
    && pass "8. expect line '$bad' refused by its number, no call" || fail "8. bad expect '$bad': rc=$rc $(cat "$T/calls" "$T/o")"
done
run COST_CMD=index COST_EXPECT_FILE="$T/fs/no-such.tsv"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "8. an unreadable COST_EXPECT_FILE is refused, no call" || fail "8. unreadable: rc=$rc $(cat "$T/o")"
ROWS2='{"entries":[
 {"id":"'$ID'","type":"cloud","amount":7.5,"currency":"XTS","period":"2020-05"},
 {"id":"'$ID'","type":"cloud","amount":1.0012,"currency":"XTS","period":"2020-06"},
 {"id":"'$ID'","type":"cloud","amount":0.9999,"currency":"XTS","period":"2020-06"},
 {"id":"'$ID'","type":"cloud","amount":"n/a","currency":"XTS","period":"2020-07"},
 {"id":"'$ID'","type":"cloud","amount":3,"currency":"XTS","period":"2020-08"}]}'
printf '2020-05\t7.51\n2020-06\t2.00\n2020-07\t0\n2020-08\t3.00\n2020-09\t4\n' >"$T/fs/expect2.tsv"
run COST_CMD=index COST_EXPECT_FILE="$T/fs/expect2.tsv" STUB_BODY="$ROWS2"; rc=$?
[[ $rc -eq 0 ]] && diff <(grep '^2020' "$T/o") <(printf '%s\n' '2020-05 rows=1 sum=MISMATCH' '2020-06 rows=2 sum=OK' \
  '2020-07 rows=1 sum=BADROW' '2020-08 rows=1 sum=OK' '2020-09 rows=0 sum=MISMATCH') >/dev/null \
  && pass "8. one cent off: MISMATCH; within half a cent: OK; a non-number amount: BADROW" || fail "8. cents: rc=$rc $(cat "$T/o")"
run COST_CMD=index COST_MONTH=2020-05 COST_EXPECT_FILE="$T/fs/expect2.tsv" STUB_BODY="$(jq -c '.entries |= map(select(.period == "2020-05"))' <<<"$ROWS2")"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/cost-entries?month=2020-05 ' "$T/calls" && [[ "$(grep '^2020' "$T/o")" == '2020-05 rows=1 sum=MISMATCH' ]] \
  && pass "8. COST_MONTH keeps only its period of the expect file" || fail "8. month+expect: rc=$rc $(cat "$T/o")"
run COST_CMD=index COST_EXPECT_FILE="$T/fs"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -qx 'FATAL COST_EXPECT_FILE is not a readable file or pipe' "$T/o" \
  && pass "8. a directory as COST_EXPECT_FILE is refused, no call" || fail "8. dir: rc=$rc $(cat "$T/o")"
run COST_CMD=index STUB_BODY='{"entries":"98765.4321xx"}'; rc=$?
[[ $rc -ne 0 ]] && grep -qx "FATAL the hub's answer is not a list of cost entries (it is not printed)" "$T/o" && ! grep -qF 98765 "$T/o" \
  && pass "8. a malformed hub answer fails and is not quoted" || fail "8. malformed: rc=$rc $(cat "$T/o")"
real_run indexmalformed COST_CMD=index STUB_CODE=200 STUB_BODY='{"entries":"98765.4321xx"}'
SENT+=(LABEL-SENTINEL 11111.5555 22222.7777 109876.99 33333.33)
printf '2020-01\t1e5\n' >"$T/fs/bad.tsv"
real_run index COST_CMD=index STUB_CODE=200 STUB_BODY="$ROWS"; rc=$?
real_run indexexp COST_CMD=index COST_EXPECT_FILE="$T/fs/expect.tsv" STUB_CODE=200 STUB_BODY="$ROWS"; rc2=$?
real_run indexbad COST_CMD=index COST_EXPECT_FILE="$T/fs/bad.tsv" STUB_CODE=200 STUB_BODY="$ROWS"; rc3=$?
real_run indexrefused COST_CMD=index STUB_CODE=500 STUB_BODY="$REFUSED"; rc4=$?
[[ $rc -eq 0 && $rc2 -eq 0 && $rc3 -ne 0 && $rc4 -ne 0 ]] && grep -qx '2020-01 rows=2' "$T/fs/index/stdout" \
  && grep -qx '2020-02 rows=1 sum=MISMATCH' "$T/fs/indexexp/stdout" && grep -qF 'answered 500 (bad_cost_entry)' "$T/fs/indexrefused/stdout" \
  && pass "8. ./run index, with the expect file, a bad expect line, a 500: as above" || fail "8. ./run index: rc=$rc/$rc2/$rc3/$rc4 $(cat "$T/fs/index/stdout" "$T/fs/indexexp/stdout")"
for r in dry ok refused r403 r404 r500 badamount badcur grossbelow swapped index indexexp indexbad indexrefused indexmalformed; do
  n=$(find "$T/fs/$r" -type f | wc -l)
  l="$(leaks "$r" | tr "\n" " ")"
  [[ -z "$l" && $n -gt 2 ]] && pass "8. $r: none of the ${#SENT[@]} sentinels in stdout, stderr or the $((n - 2)) file(s) the run wrote" \
    || fail "8. $r leaks (files=$n): $l"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
