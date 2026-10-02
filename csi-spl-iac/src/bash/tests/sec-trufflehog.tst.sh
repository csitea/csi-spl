#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_trufflehog fails closed, its negative control can fail, and a
#          VERIFIED secret reddens the gate. TruffleHog here is a stub emitting
#          JSON. The real tool runs from .github/workflows/64_trufflehog.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-trufflehog.func.sh"
WF="$APP_ROOT/.github/workflows/64_trufflehog.yml"

fails=0

require_action "$FUNC"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-trufflehog.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ROOT="$T/root"; mkdir -p "$ROOT"


# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_TRUFFLEHOG_ROOT="$ROOT" SEC_TRUFFLEHOG_BIN=not-a-th do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing trufflehog fails closed" || fail "missing trufflehog not closed (rc=$rc)"

# --- CONTROL: a stub that detects nothing in control phase fails -------------
stub trufflehog 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent trufflehog fails the action" || fail "CONTROL: silent trufflehog accepted (rc=$rc)"

# --- control detects, scan finds no verified -> passes ----------------------
stub trufflehog 'if [[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]]; then echo "{\"DetectorName\":\"AWS\"}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no verified' <<<"$out" \
  && pass "control then a clean tree passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a verified secret fails ------------------------------------------------
stub trufflehog 'if [[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]]; then echo "{\"DetectorName\":\"AWS\"}"; else echo "{\"DetectorName\":\"AWS\",\"SourceMetadata\":{\"Data\":{\"Filesystem\":{\"file\":\"x/leak.env\"}}}}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'VERIFIED' <<<"$out" \
  && pass "a verified secret fails the gate" || fail "verified secret did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_trufflehog' 'trufflesecurity/trufflehog' "$_SEC_TRUFFLEHOG_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "64_trufflehog.yml installs the pinned trufflehog and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-trufflehog.tst.sh assertions"
exit "$fails"
