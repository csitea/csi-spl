#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_hadolint fails closed, and its negative control can fail.
#          hadolint here is a stub. A green stub that reports nothing on a bad
#          Dockerfile must NOT let the action pass: that is the control. The
#          real hadolint runs from .github/workflows/66_hadolint.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-hadolint.func.sh"
WF="$APP_ROOT/.github/workflows/66_hadolint.yml"

fails=0

require_action "$FUNC"

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-hadolint.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A fake repo root: a .hadolint.yaml and one Dockerfile to scan.
ROOT="$T/root"
mkdir -p "$ROOT/csi-spl-api/src/docker"
printf 'failure-threshold: error\nignored:\n  - DL3004\n' >"$ROOT/.hadolint.yaml"
printf 'FROM alpine:3.20\nCMD ["true"]\n' >"$ROOT/csi-spl-api/src/docker/hub.Dockerfile"


# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_HADOLINT_ROOT="$ROOT" SEC_HADOLINT_BIN=not-a-hadolint do_sec_hadolint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing hadolint fails closed" || fail "missing hadolint not closed (rc=$rc)"

# --- missing config fails ----------------------------------------------------
set +e
out=$(SEC_HADOLINT_ROOT="$ROOT" SEC_HADOLINT_BIN=true SEC_HADOLINT_CONFIG="$T/absent.hadolint.yaml" do_sec_hadolint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'no .*hadolint.yaml' <<<"$out" \
  && pass "a missing .hadolint.yaml is refused" || fail "missing config not refused (rc=$rc)"

# --- CONTROL: a stub that finds nothing on the bad Dockerfile fails ----------
stub hadolint 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_HADOLINT_ROOT="$ROOT" do_sec_hadolint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent hadolint fails the action" || fail "CONTROL: silent hadolint accepted (rc=$rc)"

# --- control fires, scan clean -> passes ------------------------------------
stub hadolint 'if [[ "${SEC_HADOLINT_PHASE:-}" == control ]]; then echo "f/Dockerfile:1 DL3020 error: use COPY"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_HADOLINT_ROOT="$ROOT" do_sec_hadolint 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no error-level findings' <<<"$out" \
  && pass "control then a clean tree passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a real error-level finding fails ---------------------------------------
stub hadolint 'if [[ "${SEC_HADOLINT_PHASE:-}" == control ]]; then echo "c/Dockerfile:1 DL3020 error"; exit 1; fi; echo "hub.Dockerfile:9 DL3020 error: use COPY"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_HADOLINT_ROOT="$ROOT" do_sec_hadolint 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'error-level findings' <<<"$out" \
  && pass "a real error finding fails the gate" || fail "real finding did not fail (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_hadolint' 'hadolint-Linux-x86_64' "$_SEC_HADOLINT_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "66_hadolint.yml installs the pinned hadolint and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-hadolint.tst.sh assertions"
exit "$fails"
