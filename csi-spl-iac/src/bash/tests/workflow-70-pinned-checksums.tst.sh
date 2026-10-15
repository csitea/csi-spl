#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Security round 1 row 12: 70_supply-chain.yml verifies trivy and osv-scanner
# against a sha256 PINNED in the workflow, never against a checksum file from
# the same release (a replaced release brings its own matching file).
#   - each install step pins sha=<64 hex> and downloads no checksum file
#   - behaviour: the step's own script, run with a stubbed curl that serves a
#     replaced release (a fake binary AND a checksum file that matches it),
#     fails; with the pin set to the fake's hash the same script passes
#     (so the check is the pin, not a no-op)
# Control: WF70=<the pre-fix workflow> turns this test red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF="${WF70:-$APP_ROOT/.github/workflows/70_supply-chain.yml}"
fails=0
[[ -f "$WF" ]] || { fail "no workflow at $WF"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# curl -o <out> <url>: the fake release asset, or a checksum file naming every
# asset with the fake's own hash (what a replaced release would publish)
cat >"$T/bin/curl" <<'EOS'
#!/usr/bin/env bash
out=""; url=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
h=$(sha256sum "$FAKE" | awk '{print $1}')
case "$url" in
  *checksums.txt|*SHA256SUMS) for a in trivy_0.74.0_Linux-64bit.tar.gz osv-scanner_linux_amd64; do echo "$h  $a"; done >"$out" ;;
  *) cp "$FAKE" "$out" ;;
esac
EOS
chmod +x "$T/bin/curl"
# a fake trivy tarball and osv binary that print a version
mkdir -p "$T/src"; printf '#!/bin/sh\necho fake 0\n' >"$T/src/trivy"; chmod +x "$T/src/trivy"
tar -czf "$T/trivy.tgz" -C "$T/src" trivy
cp "$T/src/trivy" "$T/osv"

# step <name> - the run: block of the workflow step named <name>, dedented
step() {
  awk -v n="$1" '
    $0 ~ "- name: " n { on = 1; next }
    on && /^      - name:/ { exit }
    on && /^        run: \|/ { body = 1; next }
    on && body { sub(/^          /, ""); print }' "$WF"
}

# run_step <name> <fake> [pin] - run the step's script offline; prints rc
run_step() {
  local s="$T/step.sh" rc
  step "$1" >"$s"
  [[ -n "${3:-}" ]] && sed -i -E "s/^sha=[0-9a-f]{64}$/sha=$3/" "$s"
  rm -rf "$T/cache" "$T/tmp"; mkdir -p "$T/cache" "$T/tmp"
  ( export PATH="$T/bin:$PATH" FAKE="$2" RUNNER_TOOL_CACHE="$T/cache" RUNNER_TEMP="$T/tmp" GITHUB_PATH="$T/ghpath"
    bash "$s" ) >/dev/null 2>&1; rc=$?
  echo "$rc"
}

for tool in "trivy|Install trivy|$T/trivy.tgz" "osv-scanner|Install osv-scanner|$T/osv"; do
  IFS='|' read -r name stepname fake <<<"$tool"
  body="$(step "$stepname")"
  [[ -n "$body" ]] || { fail "$name: no '$stepname' step in $WF"; continue; }
  grep -qE '^sha=[0-9a-f]{64}$' <<<"$body" && pass "$name: pins sha=<64 hex>" || fail "$name: no pinned sha=<64 hex> in its install step"
  grep -qiE 'checksums\.txt|SHA256SUMS' <<<"$body" && fail "$name: still downloads the release's own checksum file" || pass "$name: downloads no checksum file"
  [[ "$(run_step "$stepname" "$fake")" != 0 ]] && pass "$name: a replaced release (with its own matching checksum file) fails the install" \
    || fail "$name: a replaced release passed the install"
  h=$(sha256sum "$fake" | awk '{print $1}')
  [[ "$(run_step "$stepname" "$fake" "$h")" == 0 ]] && pass "$name: the same script passes when the pin is the asset's hash (the check is the pin)" \
    || fail "$name: the script fails even with the right pin"
done

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-70-pinned-checksums.tst.sh assertions"
exit "$fails"
