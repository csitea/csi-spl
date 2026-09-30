#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_checkov fails closed, its negative control can fail, and a NEW
#          terraform misconfig beyond the baseline reddens the gate. Checkov here
#          is a stub. The real tool runs from .github/workflows/65_iac-checkov.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-checkov.func.sh"
WF="$APP_ROOT/.github/workflows/65_iac-checkov.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-checkov.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TFDIR="$T/tf"; mkdir -p "$TFDIR"; printf 'x\n' >"$TFDIR/.checkov.baseline"

stub() { mkdir -p "$T/bin"; printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_CHECKOV_DIR="$TFDIR" SEC_CHECKOV_ROOT="$T" SEC_CHECKOV_BIN=not-a-checkov do_sec_checkov 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing checkov fails closed" || fail "missing checkov not closed (rc=$rc)"

# --- missing terraform dir fails --------------------------------------------
set +e
out=$(SEC_CHECKOV_DIR="$T/none" SEC_CHECKOV_ROOT="$T" SEC_CHECKOV_BIN=true do_sec_checkov 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'no terraform dir' <<<"$out" \
  && pass "a missing terraform dir is refused" || fail "missing tf dir not refused (rc=$rc)"

# --- missing baseline fails --------------------------------------------------
mkdir -p "$T/tf2"
set +e
out=$(SEC_CHECKOV_DIR="$T/tf2" SEC_CHECKOV_ROOT="$T" SEC_CHECKOV_BIN=true do_sec_checkov 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'no .*checkov.baseline' <<<"$out" \
  && pass "a missing baseline is refused" || fail "missing baseline not refused (rc=$rc)"

# --- CONTROL: a stub that finds nothing on the insecure bucket fails ---------
stub checkov 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_CHECKOV_DIR="$TFDIR" SEC_CHECKOV_ROOT="$T" do_sec_checkov 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent checkov fails the action" || fail "CONTROL: silent checkov accepted (rc=$rc)"

# --- control flags, scan clean vs baseline -> passes ------------------------
stub checkov 'if [[ "${SEC_CHECKOV_PHASE:-}" == control ]]; then exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_CHECKOV_DIR="$TFDIR" SEC_CHECKOV_ROOT="$T" do_sec_checkov 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no new terraform misconfig' <<<"$out" \
  && pass "control then a baselined-clean scan passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a NEW misconfig fails --------------------------------------------------
stub checkov 'if [[ "${SEC_CHECKOV_PHASE:-}" == control ]]; then exit 1; fi; echo "Check: CKV_GCP_1: FAILED"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_CHECKOV_DIR="$TFDIR" SEC_CHECKOV_ROOT="$T" do_sec_checkov 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'NEW terraform misconfig' <<<"$out" \
  && pass "a new checkov finding fails the gate" || fail "new finding did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_checkov' "checkov==$_SEC_CHECKOV_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "65_iac-checkov.yml installs the pinned checkov and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-checkov.tst.sh assertions"
exit "$fails"
