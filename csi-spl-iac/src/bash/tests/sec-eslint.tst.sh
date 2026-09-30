#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_eslint fails closed, its negative control can fail, and a NEW
#          finding beyond the baseline reddens the gate. eslint here is a stub
#          emitting JSON. The real tool runs from 63_eslint-security.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-eslint.func.sh"
WF="$APP_ROOT/.github/workflows/63_eslint-security.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-eslint.func.sh
source "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ROOT="$T/root"; mkdir -p "$ROOT/csi-spl-wui/src/utils"
printf 'export const x=1;\n' >"$ROOT/csi-spl-wui/src/utils/a.mjs"
printf '// cfg\n' >"$ROOT/.eslint-security.config.mjs"
printf '# h\nsecurity/detect-bidi-characters|csi-spl-wui/src/utils/a.mjs|1\n' >"$ROOT/.eslint-security-baseline.txt"

stub() { mkdir -p "$T/bin"; printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

# --- missing tool fails closed (no bin, no dir) -----------------------------
set +e
out=$(SEC_ESLINT_ROOT="$ROOT" do_sec_eslint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'eslint not found' <<<"$out" \
  && pass "a missing eslint fails closed" || fail "missing eslint not closed (rc=$rc)"

# --- missing config fails ----------------------------------------------------
set +e
out=$(SEC_ESLINT_ROOT="$ROOT" SEC_ESLINT_BIN=true SEC_ESLINT_CONFIG="$T/none.mjs" do_sec_eslint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'security config' <<<"$out" \
  && pass "a missing config is refused" || fail "missing config not refused (rc=$rc)"

# --- CONTROL: a stub that flags nothing in control phase fails ---------------
stub eslint 'echo "[]"'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ESLINT_ROOT="$ROOT" SEC_ESLINT_BIN="$T/bin/eslint" do_sec_eslint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent eslint fails the action" || fail "CONTROL: silent eslint accepted (rc=$rc)"

# --- control flags, scan matches baseline -> passes -------------------------
stub eslint 'if [[ "${SEC_ESLINT_PHASE:-}" == control ]]; then echo "[{\"filePath\":\"/x/bad.mjs\",\"messages\":[{\"ruleId\":\"security/detect-eval-with-expression\"}]}]"; else echo "[{\"filePath\":\"'"$ROOT"'/csi-spl-wui/src/utils/a.mjs\",\"messages\":[{\"ruleId\":\"security/detect-bidi-characters\"}]}]"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ESLINT_ROOT="$ROOT" SEC_ESLINT_BIN="$T/bin/eslint" do_sec_eslint 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no new findings' <<<"$out" \
  && pass "control then a baselined-only scan passes" || { fail "baselined scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a NEW finding fails ----------------------------------------------------
stub eslint 'if [[ "${SEC_ESLINT_PHASE:-}" == control ]]; then echo "[{\"filePath\":\"/x/bad.mjs\",\"messages\":[{\"ruleId\":\"security/detect-eval-with-expression\"}]}]"; else echo "[{\"filePath\":\"'"$ROOT"'/csi-spl-wui/src/utils/a.mjs\",\"messages\":[{\"ruleId\":\"security/detect-child-process\"}]}]"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_ESLINT_ROOT="$ROOT" SEC_ESLINT_BIN="$T/bin/eslint" do_sec_eslint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'NEW finding' <<<"$out" \
  && pass "a new eslint finding fails the gate" || fail "new finding did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_eslint' 'eslint-plugin-security'; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "63_eslint-security.yml installs eslint + the plugin and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-eslint.tst.sh assertions"
exit "$fails"
