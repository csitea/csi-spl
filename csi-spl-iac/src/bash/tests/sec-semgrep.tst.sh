#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_semgrep fails closed, its negative control can fail, and a NEW
#          finding beyond the baseline reddens the gate. Semgrep here is a stub
#          emitting JSON. The real tool runs from .github/workflows/61_semgrep.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-semgrep.func.sh"
WF="$APP_ROOT/.github/workflows/61_semgrep.yml"

fails=0

require_action "$FUNC"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-semgrep.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ROOT="$T/root"; mkdir -p "$ROOT"
printf '# h\nrule.a|csi-spl-api/x.go|1\n' >"$ROOT/.semgrep-baseline.txt"


# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_SEMGREP_ROOT="$ROOT" SEC_SEMGREP_BIN=not-a-semgrep do_sec_semgrep 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing semgrep fails closed" || fail "missing semgrep not closed (rc=$rc)"

# --- missing baseline fails --------------------------------------------------
set +e
out=$(SEC_SEMGREP_ROOT="$ROOT" SEC_SEMGREP_BIN=true SEC_SEMGREP_BASELINE="$T/absent.semgrep-baseline.txt" do_sec_semgrep 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'no .*semgrep-baseline' <<<"$out" \
  && pass "a missing baseline is refused" || fail "missing baseline not refused (rc=$rc)"

# --- CONTROL: a stub that flags nothing in control phase fails ---------------
stub semgrep 'echo "{\"results\":[]}"'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SEMGREP_ROOT="$ROOT" do_sec_semgrep 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent semgrep fails the action" || fail "CONTROL: silent semgrep accepted (rc=$rc)"

# --- control flags, scan matches baseline -> passes -------------------------
stub semgrep 'if [[ "${SEC_SEMGREP_PHASE:-}" == control ]]; then echo "{\"results\":[{\"check_id\":\"control-eval\",\"path\":\"bad.js\"}]}"; else echo "{\"results\":[{\"check_id\":\"rule.a\",\"path\":\"csi-spl-api/x.go\"}]}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SEMGREP_ROOT="$ROOT" do_sec_semgrep 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no new findings' <<<"$out" \
  && pass "control then a baselined-only scan passes" || { fail "baselined scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a NEW finding fails ----------------------------------------------------
stub semgrep 'if [[ "${SEC_SEMGREP_PHASE:-}" == control ]]; then echo "{\"results\":[{\"check_id\":\"control-eval\",\"path\":\"bad.js\"}]}"; else echo "{\"results\":[{\"check_id\":\"rule.a\",\"path\":\"csi-spl-api/x.go\"},{\"check_id\":\"rule.b\",\"path\":\"csi-spl-wui/y.ts\"}]}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SEMGREP_ROOT="$ROOT" do_sec_semgrep 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'NEW finding' <<<"$out" \
  && pass "a new semgrep finding fails the gate" || fail "new finding did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_semgrep' "semgrep==$_SEC_SEMGREP_VER" 'p/owasp-top-ten'; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "61_semgrep.yml installs the pinned semgrep and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-semgrep.tst.sh assertions"
exit "$fails"
