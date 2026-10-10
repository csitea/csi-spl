#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the reply probes' shared preamble (lib/bash/funcs/
#          spl-probe-preamble.func.sh, refactor r6-08) keeps each probe's
#          refusals and its dry run, and hands the key + pw paths back.
#   1. spl_probe_preamble: t1 refused with the caller's reason (rc 1, the
#      FATAL line byte for byte), t1 accepted when no reason is given, dry
#      out-param 1 by default and 0 with DRY_RUN=0, DRY_RUN=2 refused
#   2. spl_probe_box_ok: box-wui / box-desk / a non box-* id refused
#   3. spl_probe_dry_report: prints one "would" line per argument plus the
#      "nothing was sent" line and returns 0, with no external call
#   4. spl_probe_secrets: a non-0600 key and a missing pw file refused before
#      any call; a 0600 key + readable pw file come back in the out-params
#   5. CONTROL: a spool call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool psql

# --- 1. spl_probe_preamble ---------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET='spl_probe_preamble dry t1 "run the probe in a test tenant (e2e)"; echo "rc=$?"' in_orc 2>&1)
grep -qx "FATAL TENANT_ID=t1 is a real tenant: run the probe in a test tenant (e2e)" <<<"$out" && grep -qx "rc=1" <<<"$out" &&
  [[ ! -s "$T/calls.log" ]] && pass "t1 refused with the caller's reason, rc 1, no call" || fail "t1 refusal: $out"
out=$(SNIPPET='spl_probe_preamble dry t1 && echo "dry=$dry"' in_orc 2>&1)
grep -qx "dry=1" <<<"$out" && pass "t1 accepted with no reason; dry defaults to 1" || fail "t1 no reason: $out"
out=$(SNIPPET='spl_probe_preamble dry e2e && echo "dry=$dry"' in_orc DRY_RUN=0 2>&1)
grep -qx "dry=0" <<<"$out" && pass "DRY_RUN=0 sets dry to 0" || fail "DRY_RUN=0: $out"
for bad in "DRY_RUN=2" "TENANT_ID=E2E"; do
  out=$(SNIPPET='spl_probe_preamble dry "${TENANT_ID:-e2e}"; echo "rc=$?"' in_orc "$bad" 2>&1)
  grep -qx "rc=1" <<<"$out" && grep -q "^FATAL" <<<"$out" && pass "preamble refuses $bad" || fail "preamble $bad: $out"
done

# --- 2. spl_probe_box_ok -----------------------------------------------------------------
for bad in box-wui box-desk srv-1 box-; do
  out=$(SNIPPET="spl_probe_box_ok '$bad'; echo \"rc=\$?\"" in_orc 2>&1)
  grep -qx "FATAL PROBE_BOX must be a throwaway box-\* id (not box-wui / box-desk), got: '$bad'" <<<"$out" &&
    grep -qx "rc=1" <<<"$out" && pass "box_ok refuses $bad" || fail "box_ok $bad: $out"
done
SNIPPET="spl_probe_box_ok box-rpp-20261010" in_orc >/dev/null 2>&1 && pass "box_ok accepts box-rpp-20261010" || fail "box_ok refused a throwaway box"

# --- 3. spl_probe_dry_report -------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET='spl_probe_dry_report "pin a" "post b"; echo "rc=$?"' in_orc 2>&1)
[[ "$out" == $'INFO DRY_RUN would: pin a\nINFO DRY_RUN would: post b\nOK DRY_RUN nothing was sent. Re-run with DRY_RUN=0.\nrc=0' ]] &&
  [[ ! -s "$T/calls.log" ]] && pass "DRY_RUN report prints its lines and returns 0, no call" || fail "dry report: $out"

# --- 4. spl_probe_secrets ----------------------------------------------------------------
echo k >"$T/root.key"; echo pw >"$T/pw"
chmod 0644 "$T/root.key"
: >"$T/calls.log"
out=$(SNIPPET='key=unset; spl_probe_secrets e2e key pw curl; echo "rc=$? key=$key"' in_orc ROOT_KEY="$T/root.key" MEMBER_PW_FILE="$T/pw" 2>&1)
grep -qx "FATAL ROOT_KEY $T/root.key must be a non-empty 0600 file" <<<"$out" && grep -qx "rc=1 key=unset" <<<"$out" &&
  [[ ! -s "$T/calls.log" ]] && pass "a 0644 root key is refused, rc 1, no out-param, no call" || fail "0644 key: $out"
chmod 0600 "$T/root.key"
out=$(SNIPPET='spl_probe_secrets e2e key pw curl; echo "rc=$?"' in_orc ROOT_KEY="$T/root.key" MEMBER_PW_FILE="$T/none" 2>&1)
grep -qx "FATAL no readable password file $T/none (set MEMBER_PW_FILE)" <<<"$out" && grep -qx "rc=1" <<<"$out" &&
  pass "a missing pw file is refused" || fail "missing pw: $out"
out=$(SNIPPET='spl_host_spool() { return 0; }; spl_probe_secrets e2e key pw curl setsid; echo "rc=$? key=$key pw=$pw"' \
  in_orc ROOT_KEY="$T/root.key" MEMBER_PW_FILE="$T/pw" 2>&1)
grep -qx "rc=0 key=$T/root.key pw=$T/pw" <<<"$out" && pass "a 0600 key + readable pw come back in the out-params" || fail "secrets ok: $out"
out=$(SNIPPET='spl_host_spool() { return 0; }; spl_probe_secrets e2e key pw curl; echo "rc=$?"' in_orc 2>&1)
grep -qx "FATAL ROOT_KEY $T/state/dev/m3-e2e/e2e/root.key must be a non-empty 0600 file" <<<"$out" &&
  pass "the key defaults to the tenant's m3-e2e state" || fail "default key path: $out"

# --- 5. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all probe-preamble.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
