#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_db_query_rc and spl_db_require_bins (refactor r5-04), the one
#          connect block of five read-only hub Postgres actions, keep what the
#          five hand copies did, offline (stubbed gcloud, runtime and query):
#   1. spl_db_require_bins: none asks for psql python3, any other provider
#      for gcloud psql python3
#   2. provider none: the query fn's rc comes back (4), the query sees $dsn
#      and the caller's locals, no gcloud call, $dsn unset afterwards;
#      no runtime login -> rc 1 and the query never runs
#   3. no key readable: rc 1, the same FATAL text, no gcloud call
#   4. cloud: the query's rc comes back (5), it ran under a CLOUDSDK_CONFIG
#      dir that is gone afterwards, as the isolated SA account; the caller's
#      CLOUDSDK_CONFIG is untouched
#   5. a failing activate: rc 1, the same FATAL text, TMPDIR left empty
#   6. an interrupted run (INT to the process group, as Ctrl-C): bash dies
#      without returning, yet TMPDIR is empty. CONTROL: the query was reached
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 0 gcloud
export T
mkdir -p "$T/tmpd"
echo '{}' >"$T/sa.json"

# stubs the snippets share: the runtime login, the isolated account and a
# query fn that records what it saw and returns $Q_RC.
STUBS='spl_db_runtime_local() { [[ "${NO_LOGIN:-0}" == 1 ]] && return 1; dsn=postgres://stub; }
do_gcp_isolated_active_account() { echo sa@example.test; }
q() { echo "QUERY dsn=${dsn:-} who=${who:-} cfg=${CLOUDSDK_CONFIG:-} acct=${GCP_ACCOUNT:-}"
  [[ -n "${CLOUDSDK_CONFIG:-}" && -d "$CLOUDSDK_CONFIG" ]] && echo "CFG-DIR-EXISTS"
  [[ "${Q_INT:-0}" == 1 ]] && kill -INT 0
  return "${Q_RC:-0}"; }
caller() { local who=caller-local; spl_db_query_rc "$1" q; }'

# run_q <provider> [VAR=value]... -> prints the output, then "RC=<rc>" and
# "DSN-AFTER=<dsn>"
run_q() {
  local p="$1"; shift
  : >"$T/calls.log"; rm -rf "$T/tmpd"; mkdir -p "$T/tmpd"
  SNIPPET="$STUBS"'
caller '"$p"'; echo "RC=$?"; echo "DSN-AFTER=${dsn:-}"' \
    in_orc SPL_PROJECT=csi-spl-dev SPL_ORG_APP=csi-spl TMPDIR="$T/tmpd" CLOUDSDK_CONFIG=/caller/cfg "$@" 2>&1
}

# --- 1. require bins ---------------------------------------------------------------
out=$(SNIPPET='do_require_bin() { echo "BINS $*"; }; spl_db_require_bins none; spl_db_require_bins gcp' in_orc 2>&1)
grep -qx 'BINS psql python3' <<<"$out" && grep -qx 'BINS gcloud psql python3' <<<"$out" \
  && pass "require bins: none -> psql python3, gcp -> gcloud psql python3" || fail "require bins: $out"
out=$(SNIPPET='do_require_bin() { return 7; }; spl_db_require_bins none' in_orc 2>&1); rc=$?
[[ $rc == 7 ]] && pass "require bins: a missing bin's rc comes back" || fail "require bins rc=$rc: $out"

# --- 2. provider none --------------------------------------------------------------
out=$(run_q none Q_RC=4)
grep -q '^RC=4$' <<<"$out" && pass "none: the query's rc 4 comes back" || fail "none rc: $out"
grep -q '^QUERY dsn=postgres://stub who=caller-local ' <<<"$out" \
  && pass "none: the query sees \$dsn and the caller's locals" || fail "none query: $out"
grep -q '^DSN-AFTER=$' <<<"$out" && pass "none: \$dsn is not left behind" || fail "none dsn: $out"
[[ ! -s "$T/calls.log" ]] && pass "none: no gcloud call" || fail "none gcloud: $(cat "$T/calls.log")"
out=$(run_q none NO_LOGIN=1 Q_RC=4)
grep -q '^RC=1$' <<<"$out" && ! grep -q '^QUERY' <<<"$out" \
  && pass "none, no login: rc 1, the query never runs" || fail "none no login: $out"

# --- 3. no key -----------------------------------------------------------------------
out=$(run_q gcp SPL_SA_KEY="$T/none.json")
grep -q '^RC=1$' <<<"$out" \
  && grep -qF "FATAL no service-account key for csi-spl-dev at $T/none.json (set SPL_SA_KEY)" <<<"$out" \
  && [[ ! -s "$T/calls.log" ]] && ! grep -q '^QUERY' <<<"$out" \
  && pass "no key: rc 1, same message, no gcloud call" || fail "no key: calls=$(cat "$T/calls.log") out=$out"

# --- 4. cloud ------------------------------------------------------------------------
out=$(run_q gcp SPL_SA_KEY="$T/sa.json" Q_RC=5)
grep -q '^RC=5$' <<<"$out" && pass "cloud: the query's rc 5 comes back" || fail "cloud rc: $out"
grep -q "^QUERY dsn=postgres://stub who=caller-local cfg=$T/tmpd/.* acct=sa@example.test$" <<<"$out" \
  && grep -qx 'CFG-DIR-EXISTS' <<<"$out" \
  && pass "cloud: the query ran under a throwaway CLOUDSDK_CONFIG as the SA" || fail "cloud query: $out"
grep -q "^gcloud auth activate-service-account --key-file=$T/sa.json$" "$T/calls.log" \
  && pass "cloud: the key was activated in it" || fail "cloud activate: $(cat "$T/calls.log")"
[[ -z "$(ls -A "$T/tmpd")" ]] && pass "cloud: TMPDIR left empty" || fail "cloud: left $(ls -A "$T/tmpd")"
out=$(SNIPPET="$STUBS"'
caller gcp >/dev/null; echo "CALLER-CFG=$CLOUDSDK_CONFIG"' \
  in_orc SPL_PROJECT=csi-spl-dev SPL_ORG_APP=csi-spl TMPDIR="$T/tmpd" CLOUDSDK_CONFIG=/caller/cfg SPL_SA_KEY="$T/sa.json" 2>&1)
grep -qx 'CALLER-CFG=/caller/cfg' <<<"$out" && pass "cloud: the caller's CLOUDSDK_CONFIG is untouched" || fail "caller cfg: $out"

# --- 5. a failing activate -------------------------------------------------------------
orc_stub 1 gcloud
out=$(run_q gcp SPL_SA_KEY="$T/sa.json" Q_RC=5)
grep -q '^RC=1$' <<<"$out" && grep -qF "FATAL cannot activate the csi-spl-dev key $T/sa.json" <<<"$out" \
  && ! grep -q '^QUERY' <<<"$out" && pass "failing activate: rc 1, same message, no query" || fail "activate fails: $out"
[[ -z "$(ls -A "$T/tmpd")" ]] && pass "failing activate: TMPDIR left empty" || fail "activate fails: left $(ls -A "$T/tmpd")"

# --- 6. an interrupted run --------------------------------------------------------------
orc_stub 0 gcloud
export -f in_orc
export PROJ_ROOT APP_ROOT
rm -rf "$T/tmpd"; mkdir -p "$T/tmpd"
SNIPPET="$STUBS"'
caller gcp; echo "RC=$?"' setsid --wait bash -c 'in_orc "$@"' _ \
  SPL_PROJECT=csi-spl-dev SPL_ORG_APP=csi-spl TMPDIR="$T/tmpd" SPL_SA_KEY="$T/sa.json" Q_INT=1 >"$T/out" 2>&1
grep -qx 'CFG-DIR-EXISTS' "$T/out" && pass "CONTROL interrupt: the query ran inside the temp dir" \
  || fail "CONTROL interrupt: query not reached: $(head -c 300 "$T/out")"
grep -q '^RC=' "$T/out" && fail "interrupt: the caller returned: $(cat "$T/out")" || pass "interrupt: bash died without returning"
[[ -z "$(ls -A "$T/tmpd")" ]] && pass "interrupt: TMPDIR left empty" || fail "interrupt: left $(ls -A "$T/tmpd")"

(( fails == 0 )) && echo "OK spl-db-connect: all checks passed" || { echo "FAIL spl-db-connect: $fails check(s)"; exit 1; }
