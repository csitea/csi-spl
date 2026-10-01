#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_actionlint fails closed, and its negative control can fail.
#          actionlint here is a stub. A green stub that reports nothing on a
#          broken workflow must NOT let the action pass: that is the control.
#          The real actionlint runs from .github/workflows/85_actionlint.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-actionlint.func.sh"
WF="$APP_ROOT/.github/workflows/85_actionlint.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-actionlint.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ROOT="$T/root"
mkdir -p "$ROOT/.github/workflows"
printf 'name: ok\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"$ROOT/.github/workflows/ok.yml"

stub() { mkdir -p "$T/bin"; printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_ACTIONLINT_ROOT="$ROOT" SEC_ACTIONLINT_BIN=not-a-actionlint do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing actionlint fails closed" || fail "missing actionlint not closed (rc=$rc)"

# --- no workflows dir is refused --------------------------------------------
set +e
out=$(SEC_ACTIONLINT_ROOT="$T/empty" SEC_ACTIONLINT_BIN=true do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'nothing to lint' <<<"$out" \
  && pass "a root with no .github/workflows is refused" || fail "missing workflows dir not refused (rc=$rc)"

# --- CONTROL: a stub that finds nothing on the broken control fails ----------
stub actionlint 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ACTIONLINT_ROOT="$ROOT" do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent actionlint fails the action" || fail "CONTROL: silent actionlint accepted (rc=$rc)"

# --- CONTROL: a tool error on the control (non-zero but no finding) fails -----
# Regression: actionlint's bare auto-discovery exits 3 "no project was found" in
# a non-git dir -- a tool error, not a finding. That must fail closed, not pass.
stub actionlint 'echo "no project was found in any parent directories"; exit 3'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ACTIONLINT_ROOT="$ROOT" do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a tool error (exit 3, no finding) fails the action" \
  || fail "CONTROL: an actionlint tool error was accepted as a finding (rc=$rc)"

# --- control fires, scan clean -> passes ------------------------------------
stub actionlint '[[ "${SEC_ACTIONLINT_PHASE:-}" == control-shellcheck ]] && { echo "sc.yml:7:9: shellcheck reported issue in this script: SC2144:error"; exit 1; }; if [[ "${SEC_ACTIONLINT_PHASE:-}" == control ]]; then echo "bad.yml:6:5: error: needs does-not-exist"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ACTIONLINT_ROOT="$ROOT" do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no findings' <<<"$out" \
  && pass "control then a clean tree passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- CONTROL: the shellcheck leg skipped (no shellcheck on PATH) fails --------
# actionlint without shellcheck exits 0 on a run: block bug; that must not pass.
stub actionlint 'if [[ "${SEC_ACTIONLINT_PHASE:-}" == control ]]; then echo "bad.yml:6:5: error: needs does-not-exist"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ACTIONLINT_ROOT="$ROOT" do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'did not run shellcheck' <<<"$out" \
  && pass "CONTROL: a skipped shellcheck leg fails the action" \
  || fail "CONTROL: actionlint without its shellcheck leg was accepted (rc=$rc)"

# --- a real finding fails ----------------------------------------------------
stub actionlint '[[ "${SEC_ACTIONLINT_PHASE:-}" == control-shellcheck ]] && { echo "sc.yml:7:9: shellcheck reported issue in this script: SC2144:error"; exit 1; }; if [[ "${SEC_ACTIONLINT_PHASE:-}" == control ]]; then echo "error: needs does-not-exist"; exit 1; fi; echo "wf.yml:3:1: error: bad"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ACTIONLINT_ROOT="$ROOT" do_sec_actionlint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'findings' <<<"$out" \
  && pass "a real actionlint finding fails the gate" || fail "a finding did not fail (rc=$rc)"

# --- the workflow wires the action ------------------------------------------
if [[ -f "$WF" ]]; then
  grep -q 'do_sec_actionlint' "$WF" && pass "85_actionlint.yml runs do_sec_actionlint" \
    || fail "85_actionlint.yml does not run do_sec_actionlint"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-actionlint.tst.sh assertions"
exit "$fails"
