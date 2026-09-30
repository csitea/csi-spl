#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_report_unheard (SPL-1225) - the READ-ONLY monitor that counts
#          the human posts a cloud env dropped - builds a safe single-statement
#          query and refuses anything that could break out of it. No cloud
#          call: do_spl_cloud_cnf, the account pin and the proxy are stubbed, so
#          the test asserts the query it WOULD run, never a live DB.
#   1. the good default reaches the proxy, and the SQL it carries is ONE
#      read-only statement that keys off a reply in the topic (the whole point:
#      not "an agent box was sent it"). CONTROL: the good path runs
#   2. an interval that is not a plain "N unit" is refused before the proxy -
#      a ';' or a quote in UNHEARD_WINDOW / UNHEARD_GRACE cannot smuggle a
#      second statement. CONTROL: the good "24 hours" / "90 seconds" pass
#   3. a TENANT_ID that is not a slug is refused before the proxy
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# in_orc sources ONLY the action, with every cloud leg stubbed. spl_via_proxy
# is stubbed to print the query the action assembled instead of running it, so
# the test reads what would hit the DB without touching one.
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" SQL_OUT="$T/sql" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; export SPL_CNF; return 0; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example; export GCP_ACCOUNT; return 0; }
    do_gcp_require_live_account() { return 0; }
    spl_via_proxy() { printf "%s" "$SPL_UNHEARD_SQL" >"$SQL_OUT"; echo "PROXY-CALLED"; }
    source "$PROJ_PATH/src/bash/run/spl-report-unheard.func.sh"
    eval "$SNIPPET"'
}

# --- 1. the good default reaches the proxy with a safe single statement ------------
if SNIPPET='do_spl_report_unheard' ENV=prd in_orc >"$T/o" 2>&1 && grep -q PROXY-CALLED "$T/o"; then
  pass "the default run reaches the proxy"
else
  fail "the default run did not reach the proxy: $(cat "$T/o")"
fi
if [ -s "$T/sql" ] && ! grep -q ';' "$T/sql"; then
  pass "the assembled SQL is a single statement (no ';')"
else
  fail "the assembled SQL carries a ';' or is empty"
fi
if grep -q "from messages r" "$T/sql" && grep -q "not exists" "$T/sql"; then
  pass "the SQL keys off a reply in the topic (from messages r ... not exists)"
else
  fail "the SQL does not test for a reply in the topic"
fi

# --- 2. a bad interval is refused before the proxy; a good one passes ---------------
for bad in "7 days; drop table messages" "1 fortnight" "'; select 1" "5" "7  days evil"; do
  if SNIPPET='do_spl_report_unheard' ENV=prd UNHEARD_WINDOW="$bad" in_orc >"$T/o" 2>&1 &&
     grep -q PROXY-CALLED "$T/o"; then
    fail "UNHEARD_WINDOW '$bad' reached the proxy"
  else
    pass "UNHEARD_WINDOW '$bad' is refused before the proxy"
  fi
done
for good in "24 hours" "90 seconds" "2 weeks"; do
  if SNIPPET='do_spl_report_unheard' ENV=prd UNHEARD_GRACE="$good" in_orc >"$T/o" 2>&1 &&
     grep -q PROXY-CALLED "$T/o"; then
    pass "UNHEARD_GRACE '$good' passes"
  else
    fail "UNHEARD_GRACE '$good' was refused: $(cat "$T/o")"
  fi
done

# --- 3. a non-slug tenant is refused ------------------------------------------------
if SNIPPET='do_spl_report_unheard' ENV=prd TENANT_ID="t1'; drop table" in_orc >"$T/o" 2>&1 &&
   grep -q PROXY-CALLED "$T/o"; then
  fail "an injected TENANT_ID reached the proxy"
else
  pass "an injected TENANT_ID is refused before the proxy"
fi

echo "----"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
