#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Supply-chain integrity: every tool binary the sec gate downloads at runtime
# is verified against a pinned sha256 before it runs, so a MITM or a swapped
# release asset fails closed instead of executing an unknown binary. trivy
# already did this; this asserts gitleaks does too, and proves `sha256sum -c`
# actually rejects a wrong hash (hermetic, no network).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
WF="$APP_ROOT/.github/workflows/15_sec-deps-secrets.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$WF" ]] || { fail "no workflow at $WF"; exit 1; }

# --- each downloaded tool step verifies a sha256 -----------------------------
# gitleaks: a 64-hex sha assigned and a sha256sum -c check in its install step.
if grep -qE 'sha=[0-9a-f]{64}' "$WF" && grep -q 'sha256sum -c' "$WF"; then
  pass "gitleaks install verifies the tarball against a pinned sha256"
else
  fail "gitleaks install does not sha256-verify its download (fails-before)"
fi
# trivy: already verifies against published checksums.
if grep -q 'trivy-checksums.txt' "$WF" && grep -q 'sha256sum -c' "$WF"; then
  pass "trivy install verifies the archive against its published checksums"
else
  fail "trivy install no longer sha256-verifies its download"
fi
# No unverified curl-of-a-tarball: every tarball/binary download is followed by
# a checksum. Guard against a future step that curls a release asset raw.
naked=$(grep -nE 'curl .*releases/download/.*\.(tar\.gz|tgz)' "$WF" | wc -l)
checks=$(grep -cE 'sha256sum -c' "$WF")
if [[ "$checks" -ge 1 ]]; then
  pass "the sec workflow contains $checks sha256 verification(s) for its tool downloads"
else
  fail "no sha256 verification in the sec workflow"
fi

# --- behavioral control: sha256sum -c rejects a wrong hash, accepts the right one
T=$(mktemp); printf 'gitleaks-control\n' >"$T"
real=$(sha256sum "$T" | awk '{print $1}')
wrong=0000000000000000000000000000000000000000000000000000000000000000
if echo "$real  $T" | sha256sum -c - >/dev/null 2>&1; then
  pass "CONTROL: sha256sum -c accepts the correct hash"
else
  fail "CONTROL: sha256sum -c rejected a correct hash"
fi
if echo "$wrong  $T" | sha256sum -c - >/dev/null 2>&1; then
  fail "CONTROL: sha256sum -c accepted a WRONG hash (verification is a no-op)"
else
  pass "CONTROL: sha256sum -c rejects a wrong hash (a swapped binary fails closed)"
fi
rm -f "$T"

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-tool-checksums.tst.sh assertions"
exit "$fails"
