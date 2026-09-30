#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_shellcheck fails closed, and its negative control can fail.
#          The tool here is a stub. A green stub that reports nothing on a
#          broken script must NOT let the action pass: that is the control. The
#          real scanner runs from .github/workflows/67_shellcheck.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-shellcheck.func.sh"
WF="$APP_ROOT/.github/workflows/67_shellcheck.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-shellcheck.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A fake repo root with one bash file to scan.
ROOT="$T/root"
mkdir -p "$ROOT/csi-spl-iac/src/bash/run"
printf '#!/usr/bin/env bash\ntrue\n' >"$ROOT/csi-spl-iac/src/bash/run/ok.func.sh"

stub() { mkdir -p "$T/bin"; printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
reset_bin() { rm -rf "$T/bin"; mkdir -p "$T/bin"; }

# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_SHELLCHECK_ROOT="$ROOT" SEC_SHELLCHECK_BIN=not-a-shellcheck do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing shellcheck fails closed" || fail "missing shellcheck not closed (rc=$rc)"

# --- CONTROL: a stub that finds nothing on the broken script fails -----------
stub shellcheck 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent shellcheck fails the action" || fail "CONTROL: silent shellcheck accepted (rc=$rc)"

# --- control fires, scan clean -> passes ------------------------------------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "bad.sh:2: error: SC2144"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no error-level findings' <<<"$out" \
  && pass "control then a clean tree passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a real error-level finding fails ---------------------------------------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "c.sh:1: error: SC2144"; exit 1; fi; echo "x.func.sh:3: error: SC2148"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'error-level findings' <<<"$out" \
  && pass "a real error finding fails the gate" || fail "real finding did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_shellcheck' 'koalaman/shellcheck' "$_SEC_SHELLCHECK_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "67_shellcheck.yml installs the pinned shellcheck and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-shellcheck.tst.sh assertions"
exit "$fails"
