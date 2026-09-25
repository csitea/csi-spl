#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_scan fails closed, and each scanner's control can fail.
#          The tools here are stubs. A green stub that never reports a
#          finding must NOT let the action pass: that is the control.
#          The real govulncheck / pnpm / gitleaks / trivy run from
#          .github/workflows/15_sec-deps-secrets.yml, which calls this action.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-scan.func.sh"
WF="$APP_ROOT/.github/workflows/15_sec-deps-secrets.yml"

fails=0
# CI tidies the control module. The stub must not download one.
export SEC_SCAN_GO_TIDY=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-scan.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mk_root() {
  local d="$1"
  mkdir -p "$d/csi-spl-api/src/go/spool-hub-api" "$d/csi-spl-wui"
  printf 'module example.com/hub\n\ngo 1.25.0\n' >"$d/csi-spl-api/src/go/spool-hub-api/go.mod"
  printf 'lockfileVersion: '\''9.0'\''\n' >"$d/csi-spl-wui/pnpm-lock.yaml"
  printf 'title = "t"\n[extend]\nuseDefault = true\n' >"$d/.gitleaks.toml"
  git -C "$d" init -q
  git -C "$d" -c user.email=sec-scan@example.com -c user.name="Sec Scan" add .
  git -C "$d" -c user.email=sec-scan@example.com -c user.name="Sec Scan" commit -qm init
}

# stub <name> <body>
stub() {
  local name="$1" body="$2"
  mkdir -p "$T/bin"
  printf '#!/bin/bash\n%s\n' "$body" >"$T/bin/$name"
  chmod +x "$T/bin/$name"
}

reset_bin() { rm -rf "$T/bin"; mkdir -p "$T/bin"; }

run_scan() {
  local which="$1"
  reset_bin
  shift
  # remaining args are name=body pairs? we pass a setup function name
  PATH="$T/bin:$PATH" SEC_SCAN="$which" SEC_SCAN_ROOT="$ROOT" \
    SEC_SCAN_IMAGES="example.invalid/none:test" \
    "$@"
}

ROOT=$(mktemp -d)
mk_root "$ROOT"

# --- SEC_SCAN is required ----------------------------------------------------
out=$(SEC_SCAN= SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1) || rc=$?
rc=${rc:-0}
# the command substitution resets rc if we are not careful. Re-run:
set +e
out=$(SEC_SCAN= SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
set +e
[[ "$rc" -ne 0 ]] && grep -q 'SEC_SCAN must be one of' <<<"$out" \
  && pass "a missing SEC_SCAN is refused" \
  || fail "a missing SEC_SCAN was not refused (rc=$rc)"
set -e

# --- go: control that exits 0 fails the action (proved nothing) -------------
stub govulncheck 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=go SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: govulncheck that finds nothing fails the action" \
  || fail "CONTROL: a silent govulncheck was accepted (rc=$rc)"

# --- go: control exit 3 and a clean scan passes -----------------------------
stub govulncheck 'if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then exit 3; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=go SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no reachable vulnerabilities' <<<"$out" \
  && pass "govulncheck control exit 3 then a clean scan passes" \
  || { fail "clean govulncheck did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- go: reachable findings fail --------------------------------------------
stub govulncheck 'if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then exit 3; fi; echo "Vulnerability #1"; exit 3'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=go SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'reachable vulnerabilities' <<<"$out" \
  && pass "reachable govulncheck findings fail the gate" \
  || fail "reachable findings did not fail (rc=$rc)"

# --- go: missing binary fails ------------------------------------------------
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=go SEC_SCAN_ROOT="$ROOT" SEC_SCAN_GO_BIN=not-a-govulncheck do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing govulncheck fails closed" \
  || fail "a missing govulncheck did not fail closed (rc=$rc)"

# --- wui: control audit that exits 0 fails ----------------------------------
stub pnpm 'if [[ "$1" == install ]]; then printf "lock\n" > pnpm-lock.yaml; exit 0; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=wui SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: pnpm audit that finds nothing fails the action" \
  || fail "CONTROL: a silent pnpm audit was accepted (rc=$rc)"

# --- wui: control reports a vuln, the tree is clean -------------------------
stub pnpm 'if [[ "$1" == install ]]; then printf "lock\n" > pnpm-lock.yaml; exit 0; fi
if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then echo "1 vulnerabilities found"; echo "Severity: 1 critical"; exit 1; fi
echo "No known vulnerabilities found"; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=wui SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no moderate' <<<"$out" \
  && pass "pnpm audit control then a clean tree passes" \
  || { fail "clean pnpm audit did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- wui: a real advisory fails ---------------------------------------------
stub pnpm 'if [[ "$1" == install ]]; then printf "lock\n" > pnpm-lock.yaml; exit 0; fi
if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then echo "1 vulnerabilities found"; echo "critical"; exit 1; fi
echo "1 vulnerabilities found"; echo "high"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=wui SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'pnpm audit failed' <<<"$out" \
  && pass "a pnpm advisory fails the gate" \
  || fail "a pnpm advisory did not fail (rc=$rc)"

# --- secrets: control that finds nothing fails ------------------------------
stub gitleaks 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=secrets SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: gitleaks that finds nothing fails the action" \
  || fail "CONTROL: a silent gitleaks was accepted (rc=$rc)"

# --- secrets: control finds a leak, the tree is clean -----------------------
stub gitleaks 'if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then echo "WRN leaks found: 1"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=secrets SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no leaks' <<<"$out" \
  && pass "gitleaks control then a clean history passes" \
  || { fail "clean gitleaks did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- secrets: a leak fails ---------------------------------------------------
stub gitleaks 'echo "WRN leaks found: 1"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=secrets SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'leaks found' <<<"$out" \
  && pass "a gitleaks leak fails the gate" \
  || fail "a gitleaks leak did not fail (rc=$rc)"

# --- secrets: missing config fails (not the default rules alone) ------------
rm -f "$ROOT/.gitleaks.toml"
stub gitleaks 'if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then echo "WRN leaks found: 1"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=secrets SEC_SCAN_ROOT="$ROOT" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'no .*\.gitleaks.toml' <<<"$out" \
  && pass "a repo with no .gitleaks.toml is refused" \
  || fail "a missing .gitleaks.toml was not refused (rc=$rc)"
printf 'title = "t"\n[extend]\nuseDefault = true\n' >"$ROOT/.gitleaks.toml"

# --- images: control that prints no id fails --------------------------------
stub trivy 'exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=images SEC_SCAN_ROOT="$ROOT" SEC_SCAN_IMAGES="example.invalid/none:test" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: trivy that names no vulnerability fails the action" \
  || fail "CONTROL: a trivy exit with no id was accepted (rc=$rc)"

# --- images: control CVE then a clean image passes --------------------------
stub trivy 'if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then echo "GO-2021-0113"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=images SEC_SCAN_ROOT="$ROOT" SEC_SCAN_IMAGES="example.invalid/none:test" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no fixed HIGH' <<<"$out" \
  && pass "trivy control then a clean image passes" \
  || { fail "clean trivy image did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- images: a finding fails -------------------------------------------------
stub trivy 'if [[ "${SEC_SCAN_PHASE:-}" == control ]]; then echo "CVE-2014-0160"; exit 1; fi; echo "CVE-2024-0001"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SCAN=images SEC_SCAN_ROOT="$ROOT" SEC_SCAN_IMAGES="example.invalid/none:test" do_sec_scan 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'trivy image' <<<"$out" \
  && pass "a trivy image finding fails the gate" \
  || fail "a trivy image finding did not fail (rc=$rc)"

# --- the workflow actually invokes every scan --------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'SEC_SCAN=go' 'SEC_SCAN=wui' 'SEC_SCAN=secrets' 'SEC_SCAN=images' \
                'govulncheck@v1.7.0' 'gitleaks_8.30.1' 'trivy_0.74.0' 'fetch-depth: 0'; do
    if ! grep -qF "$needle" "$WF"; then
      fail "workflow is missing $needle"
      miss=1
    fi
  done
  (( miss )) || pass "15_sec-deps-secrets.yml runs all four scans at the pinned tools, with full git history"
else
  fail "no workflow at $WF"
fi

# --- the checked-in allowlist does not swallow the planted AKIA control -----
key="AK""IA""J7K2M9P4Q8R1""T5VW"
if [[ -f "$APP_ROOT/.gitleaks.toml" ]] && ! grep -qF "$key" "$APP_ROOT/.gitleaks.toml"; then
  pass "the planted access-key id is not written into .gitleaks.toml"
else
  fail "the planted access-key id is in .gitleaks.toml or the file is missing"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-scan.tst.sh assertions"
exit "$fails"
