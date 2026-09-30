#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_gosec fails closed, its negative control can fail, and a NEW
#          high-severity finding beyond the baseline reddens the gate while the
#          baselined ones pass. gosec here is a stub emitting JSON. The real
#          gosec runs from .github/workflows/62_gosec.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-gosec.func.sh"
WF="$APP_ROOT/.github/workflows/62_gosec.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-gosec.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ROOT="$T/root"
mkdir -p "$ROOT/csi-spl-api/src/go/spool-hub-api"
printf 'module example.com/hub\n\ngo 1.25.0\n' >"$ROOT/csi-spl-api/src/go/spool-hub-api/go.mod"
printf '# header\nG101|internal/auth/idp.go|1\n' >"$ROOT/.gosec-baseline.txt"

F="$ROOT/csi-spl-api/src/go/spool-hub-api"   # path fragment for "spool-hub-api/"
stub() { mkdir -p "$T/bin"; printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
reset_bin() { rm -rf "$T/bin"; mkdir -p "$T/bin"; }

# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_GOSEC_ROOT="$ROOT" SEC_GOSEC_BIN=not-a-gosec do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing gosec fails closed" || fail "missing gosec not closed (rc=$rc)"

# --- missing baseline fails --------------------------------------------------
set +e
out=$(SEC_GOSEC_ROOT="$ROOT" SEC_GOSEC_BIN=true SEC_GOSEC_BASELINE="$T/absent.gosec-baseline.txt" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'no .*gosec-baseline' <<<"$out" \
  && pass "a missing baseline is refused" || fail "missing baseline not refused (rc=$rc)"

# --- CONTROL: a stub that reports nothing in control phase fails -------------
stub gosec 'echo "{\"Issues\":[]}"'
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent gosec fails the action" || fail "CONTROL: silent gosec accepted (rc=$rc)"

# --- control fires, scan matches baseline -> passes -------------------------
stub gosec 'if [[ "${SEC_GOSEC_PHASE:-}" == control ]]; then echo "{\"Issues\":[{\"rule_id\":\"G404\",\"file\":\"/x/spool-hub-api/main.go\"}]}"; else echo "{\"Issues\":[{\"rule_id\":\"G101\",\"file\":\"/x/spool-hub-api/internal/auth/idp.go\"}]}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no new high-severity' <<<"$out" \
  && pass "control then a baselined-only scan passes" || { fail "baselined scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a NEW finding beyond baseline fails ------------------------------------
stub gosec 'if [[ "${SEC_GOSEC_PHASE:-}" == control ]]; then echo "{\"Issues\":[{\"rule_id\":\"G404\",\"file\":\"/x/spool-hub-api/main.go\"}]}"; else echo "{\"Issues\":[{\"rule_id\":\"G101\",\"file\":\"/x/spool-hub-api/internal/auth/idp.go\"},{\"rule_id\":\"G201\",\"file\":\"/x/spool-hub-api/internal/db/q.go\"}]}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'NEW high-severity' <<<"$out" \
  && pass "a new gosec finding fails the gate" || fail "new finding did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_gosec' 'securego/gosec' "$_SEC_GOSEC_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "62_gosec.yml installs the pinned gosec and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-gosec.tst.sh assertions"
exit "$fails"
