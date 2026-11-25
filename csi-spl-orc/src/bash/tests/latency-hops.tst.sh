#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_latency_hops (spec 053 section 8, SPL-6511) prints the per-hop
#          table of the poke ledger, read-only.
#   1. a fixture tree of two agents' ledgers gives the exact n, p50, p90 and
#      max of every hop, and counts the poke exit codes (a refused poke, rc 6,
#      is counted and never priced as a poke)
#   2. a row outside LAT_HOURS is not counted. CONTROL: a wider window counts it
#   3. with no ENV it never queries the hub; with ENV it runs P-A and P-B
#      through do_spl_db_query, read-only, naming no body column
#   4. bad input fails fast: LAT_HOURS not a number, no spool root, ENV with no
#      TENANT_ID
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

in_orc() {
  env -u ENV -u TENANT_ID -u LAT_HOURS -u LAT_SPOOL_ROOT -u SPOOL_ROOT \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SQL_LOG="$T/sql.log" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_db_query() { printf "%s\n" "$SQL" >>"$SQL_LOG"; echo "(hub rows for $ENV)"; }
    do_spl_latency_hops'
}

# --- the fixture: NOW = 1800000000 s; two agents, ms stamps -----------------
NOW=1800000000; B=$((NOW * 1000 - 600000))   # ten minutes before NOW
R="$T/spool"; mkdir -p "$R/c-101/lifetime" "$R/c-102/lifetime"
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
{
  # event ts to msg written start rc via send0
  row poke $((B + 400)) c-101 m1 $((B + 100)) $((B + 150)) 0 send $B
  row poke $((B + 1400)) c-101 m2 $((B + 1000)) $((B + 1100)) 0 sidecar -
  row poke $((B + 2100)) c-101 m3 $((B + 2000)) $((B + 2050)) 6 send $((B + 1900))
  row prompt $((B + 900)) c-101 - - - - UserPromptSubmit -
  row surfaced $((B + 900)) c-101 m1 $((B + 100)) - - UserPromptSubmit -
  row surfaced $((B + 3000)) c-101 m2 $((B + 1000)) - - PostToolUse -
  row surfaced $((B + 3500)) c-101 m2 $((B + 1000)) - - PostToolUse -
  # three hours old: outside a 2 h window
  row poke $((B - 3 * 3600000)) c-101 old $((B - 3 * 3600000 - 10)) $((B - 3 * 3600000)) 0 sidecar -
} >"$R/c-101/lifetime/poke-ledger.tsv"
row poke $((B + 700)) c-102 m4 $((B + 200)) $((B + 500)) 0 sidecar - >"$R/c-102/lifetime/poke-ledger.tsv"

# --- 1. the table ---------------------------------------------------------------
in_orc LAT_SPOOL_ROOT="$R" LAT_HOURS=2 LAT_NOW=$NOW >"$T/o" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "the action exits 0 on a fixture tree" || fail "rc $rc: $(cat "$T/o")"
want() {  # LABEL ROW
  grep -qxF "$2" "$T/o" && pass "$1" || fail "$1: want '$2' in: $(cat "$T/o")"
}
TAB=$'\t'
want "send script: m1 and the refused m3 (100, 100)" "send script (start -> inbox file)${TAB}2${TAB}100${TAB}100${TAB}100"
want "inbox -> poke, send path: 50, 50" "inbox file -> poke start (send)${TAB}2${TAB}50${TAB}50${TAB}50"
want "inbox -> poke, sidecar: 100 and 300" "inbox file -> poke start (sidecar)${TAB}2${TAB}100${TAB}300${TAB}300"
want "poke: rc 0 only (250, 300, 200)" "poke (start -> Enter)${TAB}3${TAB}250${TAB}300${TAB}300"
want "poke -> next prompt: m1 only (500)" "poke -> next prompt${TAB}1${TAB}500${TAB}500${TAB}500"
want "seen idle: m1 (800)" "inbox file -> seen, idle (UserPromptSubmit)${TAB}1${TAB}800${TAB}800${TAB}800"
want "seen busy: m2 FIRST surfacing only (2000)" "inbox file -> seen, busy (PostToolUse)${TAB}1${TAB}2000${TAB}2000${TAB}2000"
want "the rc count names the refused poke" "poke rc (last 2h): rc 0 n=3, rc 6 n=1"
grep -q 'hub hops skipped' "$T/o" && pass "no ENV: the hub is not queried" || fail "no ENV: no skip line"
[ ! -s "$T/sql.log" ] && pass "no ENV: no SQL ran" || fail "no ENV ran SQL: $(cat "$T/sql.log")"

# --- 2. the window ------------------------------------------------------------
in_orc LAT_SPOOL_ROOT="$R" LAT_HOURS=4 LAT_NOW=$NOW >"$T/o4" 2>&1
grep -qF "poke rc (last 4h): rc 0 n=4, rc 6 n=1" "$T/o4" && pass "CONTROL: a 4 h window counts the old row" ||
  fail "CONTROL: the 4 h window: $(cat "$T/o4")"

# --- 3. the hub hops ----------------------------------------------------------
in_orc LAT_SPOOL_ROOT="$R" LAT_NOW=$NOW ENV=prd TENANT_ID=t9 >"$T/oh" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "ENV: exits 0" || fail "ENV: rc $rc: $(cat "$T/oh")"
[ "$(grep -c '^(hub rows for prd)$' "$T/oh")" -eq 2 ] && pass "ENV: P-A and P-B both ran" || fail "ENV: $(cat "$T/oh")"
grep -q "tenant_id = 't9'" "$T/sql.log" && pass "the SQL is scoped to TENANT_ID" || fail "no tenant scope: $(cat "$T/sql.log")"
grep -qi 'body\|env_sig\|"msg"\| msg,' "$T/sql.log" && fail "the SQL names a body column: $(cat "$T/sql.log")" ||
  pass "the SQL reads ids and timestamps only"
grep -q ';' "$T/sql.log" && fail "the SQL holds a ';' (do_spl_db_query refuses it)" || pass "each SQL is one statement"

# --- 4. fail fast -------------------------------------------------------------
in_orc LAT_SPOOL_ROOT="$R" LAT_HOURS=abc >"$T/ob" 2>&1 && fail "LAT_HOURS=abc passed" || pass "LAT_HOURS=abc is refused"
in_orc LAT_SPOOL_ROOT="$T/none" >"$T/ob" 2>&1 && fail "a missing root passed" || pass "a missing spool root is refused"
in_orc LAT_SPOOL_ROOT="$R" ENV=prd >"$T/ob" 2>&1 && fail "ENV with no TENANT_ID passed" || pass "ENV with no TENANT_ID is refused"

[ "$fails" -eq 0 ] && echo "PASS latency-hops.tst.sh" || { echo "FAIL latency-hops.tst.sh ($fails)"; exit 1; }
