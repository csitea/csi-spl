#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_load_probe is a bounded, read-only load on DEV only
# (SPL-2880). Offline:
#   1. any ENV but dev, DBL_MINUTES outside 1..15 and DBL_CLIENTS outside
#      1..12 are refused BEFORE gcloud or docker is called
#   2. the default is a dry run: it prints the plan and calls nothing.
#      CONTROL: the stub log records a call
#   3. the session is read-only: default_transaction_read_only=on and a
#      BEGIN READ ONLY script with no write verb
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-db-load-probe.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. refusals never reach the cloud ----------------------------------------------
for kv in ENV=prd ENV= "ENV=dev DBL_MINUTES=0" "ENV=dev DBL_MINUTES=16" "ENV=dev DBL_CLIENTS=0" "ENV=dev DBL_CLIENTS=13" \
          "ENV=prd DRY_RUN=0"; do
  : >"$T/calls.log"
  # shellcheck disable=SC2086
  SNIPPET=do_spl_db_load_probe in_orc $kv >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && pass "$kv: the refusal is FATAL and named" || fail "$kv: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no cloud call" || fail "$kv: called: $(cat "$T/calls.log")"
done

# --- 2. dry run by default --------------------------------------------------------------
: >"$T/calls.log"
OUT=$(SNIPPET=do_spl_db_load_probe in_orc ENV=dev 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q '^DRY RUN: would run pgbench on dev for 10 min with 8' <<<"$OUT" &&
  pass "the default is a dry run with the plan" || fail "dry run: rc=$rc $OUT"
[[ ! -s "$T/calls.log" ]] && pass "the dry run calls nothing" || fail "dry run called: $(cat "$T/calls.log")"
SNIPPET='docker probe' in_orc >/dev/null 2>&1
grep -q "docker probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 3. read-only ---------------------------------------------------------------------
grep -q "PGOPTIONS='-c default_transaction_read_only=on'" "$FN" && pass "the session is default read-only" || fail "no read-only session"
SCRIPT=$(SNIPPET=spl_db_load_probe_script in_orc)
[[ $(head -1 <<<"$SCRIPT") == "BEGIN READ ONLY;" ]] && pass "the script opens BEGIN READ ONLY" || fail "script head: $SCRIPT"
grep -qiE '\b(insert|update|delete|truncate|create|drop|alter)\b' <<<"$SCRIPT" && fail "a write verb in the script" || pass "no write verb in the script"
grep -q 'pgbench -n ' "$FN" && pass "pgbench -n: no init (no tables created)" || fail "pgbench without -n"

echo "fails=$fails"
[[ $fails == 0 ]]
