#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_gosec fails closed, its negative control can fail, and a NEW
#          high-severity finding beyond the baseline reddens the gate while the
#          baselined ones pass; a count below its baseline line fails too
#          (r5-05 red control: baseline+1 fails, equal passes, found+1 fails). gosec here is a stub emitting JSON. The real
#          gosec runs from .github/workflows/62_gosec.yml. With go missing from
#          PATH (sudo's secure_path) the action falls back to SEC_GOSEC_GO_FALLBACK
#          and to $(go env GOPATH)/bin for gosec, or refuses.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-gosec.func.sh"
WF="$APP_ROOT/.github/workflows/62_gosec.yml"

fails=0

require_action "$FUNC"
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

# A stub go in the fallback dir, so the cases below never depend on the box's go.
GOFB="$T/gofb"
mkdir -p "$GOFB" "$T/gopath/bin"
printf '#!/bin/bash\n[[ "$1 $2" == "env GOPATH" ]] && echo %q\nexit 0\n' "$T/gopath" >"$GOFB/go"
chmod +x "$GOFB/go"
export SEC_GOSEC_GO_FALLBACK="$GOFB"

# A PATH with the tools the action needs and no go at all.
SYS="$T/sys"
mkdir -p "$SYS"
for t in python3 mktemp rm sed cat; do ln -s "$(command -v "$t")" "$SYS/$t"; done

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
[[ "$rc" -eq 0 ]] && grep -q 'no new findings' <<<"$out" \
  && pass "control then a baselined-only scan passes" || { fail "baselined scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a NEW finding beyond baseline fails ------------------------------------
stub gosec 'if [[ "${SEC_GOSEC_PHASE:-}" == control ]]; then echo "{\"Issues\":[{\"rule_id\":\"G404\",\"file\":\"/x/spool-hub-api/main.go\"}]}"; else echo "{\"Issues\":[{\"rule_id\":\"G101\",\"file\":\"/x/spool-hub-api/internal/auth/idp.go\"},{\"rule_id\":\"G201\",\"file\":\"/x/spool-hub-api/internal/db/q.go\"}]}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'NEW finding' <<<"$out" \
  && pass "a new gosec finding fails the gate" || fail "new finding did not fail (rc=$rc)"

# --- red control (r5-05): one G101 found against its baseline line ------------
stub gosec 'if [[ "${SEC_GOSEC_PHASE:-}" == control ]]; then echo "{\"Issues\":[{\"rule_id\":\"G404\",\"file\":\"/x/spool-hub-api/main.go\"}]}"; else echo "{\"Issues\":[{\"rule_id\":\"G101\",\"file\":\"/x/spool-hub-api/internal/auth/idp.go\"}]}"; fi'
printf '# header\nG101|internal/auth/idp.go|2\n' >"$ROOT/.gosec-baseline.txt"
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'lower this line' <<<"$out" && grep -q 'LOWER G101 internal/auth/idp.go: 2 baselined, 1 found' <<<"$out" \
  && pass "RED CONTROL: a baseline of found+1 fails with 'lower this line'" || { fail "baseline above the count passed (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }
printf '# header\nG101|internal/auth/idp.go|1\n' >"$ROOT/.gosec-baseline.txt"
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "RED CONTROL: a baseline equal to the count passes" || fail "equal baseline failed (rc=$rc): $out"
stub gosec 'if [[ "${SEC_GOSEC_PHASE:-}" == control ]]; then echo "{\"Issues\":[{\"rule_id\":\"G404\",\"file\":\"/x/spool-hub-api/main.go\"}]}"; else echo "{\"Issues\":[{\"rule_id\":\"G101\",\"file\":\"/x/spool-hub-api/internal/auth/idp.go\"},{\"rule_id\":\"G101\",\"file\":\"/x/spool-hub-api/internal/auth/idp.go\"}]}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'NEW G101 internal/auth/idp.go: 2 found, 1 baselined' <<<"$out" \
  && pass "RED CONTROL: one finding more than the baseline fails" || fail "found+1 passed (rc=$rc)"

# --- SEC_GOSEC_WRITE_BASELINE rewrites the counts under the header ------------
set +e
out=$(PATH="$T/bin:$PATH" SEC_GOSEC_ROOT="$ROOT" SEC_GOSEC_WRITE_BASELINE=1 do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && [[ "$(cat "$ROOT/.gosec-baseline.txt")" == $'# header\nG101|internal/auth/idp.go|2' ]] \
  && pass "the baseline writer keeps the header and writes the counts" || fail "writer: rc=$rc $(cat "$ROOT/.gosec-baseline.txt")"
printf '# header\nG101|internal/auth/idp.go|1\n' >"$ROOT/.gosec-baseline.txt"

# --- go not on PATH: the fallback dir puts it there --------------------------
# gosec without go cannot load packages: the stub then prints no JSON, as the
# real one gives the control issues=-1. The pre-fallback action failed here.
printf '# header\n' >"$ROOT/.gosec-baseline.txt"   # the stub scan below finds nothing
reset_bin
stub gosec 'command -v go >/dev/null || { echo "go: not found"; exit 1; }; if [[ "${SEC_GOSEC_PHASE:-}" == control ]]; then echo "{\"Issues\":[{\"rule_id\":\"G404\",\"file\":\"/x/spool-hub-api/main.go\"}]}"; else echo "{\"Issues\":[]}"; fi'
set +e
out=$(PATH="$T/bin:$SYS" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -qF "using $GOFB/go" <<<"$out" \
  && pass "PATH without go: falls back to SEC_GOSEC_GO_FALLBACK and the gate passes" \
  || { fail "PATH without go did not fall back (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- go nowhere: fails fast, naming the fix ---------------------------------
set +e
out=$(PATH="$T/bin:$SYS" SEC_GOSEC_GO_FALLBACK="$T/no-go" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'go is not on PATH and not at' <<<"$out" \
  && pass "no go anywhere fails fast with a clear message" || fail "missing go not refused (rc=$rc)"

# --- gosec not on PATH: found in $(go env GOPATH)/bin -----------------------
cp "$T/bin/gosec" "$T/gopath/bin/gosec"
reset_bin
set +e
out=$(PATH="$SYS" SEC_GOSEC_ROOT="$ROOT" do_sec_gosec 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no new findings' <<<"$out" \
  && pass "gosec off PATH resolves from \$(go env GOPATH)/bin" \
  || { fail "gosec in GOPATH/bin not found (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

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
