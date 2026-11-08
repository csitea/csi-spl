#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_public_dataset_customer_check (SPL-5124, spec 091 5.5),
#          offline: the database read is a stub returning invented rows.
#   1. a listed domain's new host, a listed prefix and ignored ones pass
#   2. a new domain or a new prefix fails, counted, the value in no output
#   3. the --out file lists them, mode 600
#   4. no overlay, no customer_strings, no customer_channels, a bad channel
#      entry: FATAL; a template such as $host is not a host
#   5. the SQL is one statement over the listed channels only
#   6. red control: with the coverage test removed nothing is uncovered
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in yq python3; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done

ok_overlay() {
  printf 'customer_strings:\n  - key:QZX\n  - domain:planted-customer.example.invalid\ncustomer_ignore:\n  - key:OKK\n  - domain:okay.example.org\ncustomer_channels:\n  - wsa/chan-x\n' >"$T/o.yaml"
}
ok_rows() { printf 'host|jira.new.planted-customer.example.invalid\nhost|sub.okay.example.org\nkey|QZX\nkey|OKK\nhost|$bb_host\nhost|ok\n' >"$T/rows"; }
ok_overlay; ok_rows
run() {
  local n="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev SPL_PRIVATE_CNF="$T/o.yaml" ROWS="$T/rows" SQLF="$T/$n.sql" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    do_gcp_pin_account() { GCP_ACCOUNT=x; }
    do_gcp_require_live_account() { :; }
    spl_via_proxy() { printf "%s" "$2" >"$SQLF"; cp "$ROWS" "$3"; }
    source "$PROJ_PATH/src/bash/run/spl-public-dataset-customer-check.func.sh"
    do_spl_public_dataset_customer_check' >"$T/$n.log" 2>&1 </dev/null
  echo $? >"$T/$n.rc"
}
run good
[[ "$(cat "$T/good.rc")" == 0 ]] && grep -q '^OK customer list' "$T/good.log" && pass "1. covered and ignored entries pass; a template is no host" || fail "1. good: $(cat "$T/good.log")"
[[ "$(grep -c ';' "$T/good.sql")" == 0 && "$(grep -o "('wsa','chan-x')" "$T/good.sql" | wc -l)" == 2 ]] && pass "5. one statement, over the listed channels" || fail "5. sql: $(cat "$T/good.sql")"

printf 'host|jira.brandnew.example.net\nkey|NEWP\nkey|QZX\n' >"$T/rows"
run new PD_CUSTOMER_NEW_OUT="$T/new.txt"
[[ "$(cat "$T/new.rc")" == 1 ]] && grep -q '1 host(s), 1 key prefix(es)' "$T/new.log" && pass "2. a new domain and prefix fail, counted" || fail "2. new: $(cat "$T/new.log")"
grep -qE 'brandnew|NEWP' "$T/new.log" && fail "2. a value reached the output" || pass "2. the output holds counts only"
[[ "$(stat -c %a "$T/new.txt")" == 600 && "$(paste -sd, "$T/new.txt")" == 'host:jira.brandnew.example.net,key:NEWP' ]] && pass "3. the out file lists them, mode 600" || fail "3. out: $(cat "$T/new.txt")"

ok_rows
run noov SPL_PRIVATE_CNF="$T/none.yaml"; [[ "$(cat "$T/noov.rc")" != 0 ]] && grep -q 'no private overlay' "$T/noov.log" && pass "4. no overlay is FATAL" || fail "4. no overlay: $(cat "$T/noov.log")"
printf 'customer_channels:\n  - wsa/chan-x\n' >"$T/o.yaml"; run nolist; [[ "$(cat "$T/nolist.rc")" != 0 ]] && grep -q 'no customer_strings' "$T/nolist.log" && pass "4. no customer_strings is FATAL" || fail "4. no list: $(cat "$T/nolist.log")"
printf 'customer_strings:\n  - key:QZX\n' >"$T/o.yaml"; run nochan; [[ "$(cat "$T/nochan.rc")" != 0 ]] && grep -q 'no customer_channels' "$T/nochan.log" && pass "4. no customer_channels is FATAL" || fail "4. no channels: $(cat "$T/nochan.log")"
printf "customer_strings:\n  - key:QZX\ncustomer_channels:\n  - wsa/x');drop\n" >"$T/o.yaml"; run badc; [[ "$(cat "$T/badc.rc")" != 0 ]] && grep -q 'not <workspace>/<channel>' "$T/badc.log" && pass "4. a bad channel entry is FATAL" || fail "4. bad channel: $(cat "$T/badc.log")"

mkdir -p "$T/mut"; cp "$PROJ_ROOT/src/bash/scripts/public-dataset-gate.py" "$T/mut/"
sed 's/if not (cover.search(probe) or (ignore and ignore.search(probe))):/if False:/' "$PROJ_ROOT/src/bash/scripts/public-dataset-customer-check.py" >"$T/mut/c.py"
cmp -s "$T/mut/c.py" "$PROJ_ROOT/src/bash/scripts/public-dataset-customer-check.py" && fail "6. the mutant was not built"
printf 'host|jira.brandnew.example.net\n' >"$T/rows"; printf 'key:QZX\n' >"$T/l"; printf 'key:OKK\n' >"$T/i"
python3 "$T/mut/c.py" --rows "$T/rows" --customer-list "$T/l" --ignore-list "$T/i" >"$T/red.log"; [[ $? == 0 ]] && pass "6. red control: without the coverage test a new domain passes" || fail "6. red control: $(cat "$T/red.log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
