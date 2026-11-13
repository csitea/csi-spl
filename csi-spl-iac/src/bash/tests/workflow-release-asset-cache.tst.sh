#!/usr/bin/env bash
#------------------------------------------------------------------------------
# SPL-5050: a scanner install survives a release-asset outage (504 on the
# pinned tarball, wf 10 runs 42464280436 and 42465097352). Every workflow
# "Install <tool>" step is preceded by a cache step keyed on tool + version +
# its own sha256. Each step's own script, run with a stubbed curl:
#   - warm cache: installs, never calls curl
#   - warm cache, wrong pin: fails (the sha256 is checked on every use)
#   - cold cache, release down: fails with a line naming the asset
#   - cold cache, release up: installs and fills the cache
#   - cold cache, wrong pin: fails and caches nothing
# Control: WF_DIR=<the pre-fix .github/workflows> turns this test red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="${WF_DIR:-$APP_ROOT/.github/workflows}"
fails=0
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/bin" "$T/src"

# curl -o <out> <url>: logs the call; serves $FAKE, a checksums file naming its
# hash, or fails when CURL_DOWN is set
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
echo "$url" >>"$CURL_LOG"
[[ -n "${CURL_DOWN:-}" ]] && exit 22
case "$url" in
  *checksums.txt) echo "$(sha256sum "$FAKE" | awk '{print $1}')  $(basename "$ASSET_NAME")" >"$out" ;;
  *) cp "$FAKE" "$out" ;;
esac
STUB
chmod +x "$T/bin/curl"

# step <wf> <name> - the run: block of the first step named <name>, dedented
step() {
  awk -v n="$2" '
    $0 ~ "- name: " n { on = 1; next }
    on && /^      - name:/ { exit }
    on && /^        run: \|/ { body = 1; next }
    on && body { sub(/^          /, ""); print }' "$1"
}

# fake <tool> <file> - an asset holding a stub <tool>, in that tool's packing
fake() {
  local tool="$1" out="$2" d="${T:?}/src/$1"
  rm -rf "${d:?}"; mkdir -p "$d"
  case "$out" in
    *.tar.xz) mkdir -p "$d/shellcheck-v0.10.0"; printf '#!/bin/sh\necho 0\n' >"$d/shellcheck-v0.10.0/shellcheck"; chmod +x "$d/shellcheck-v0.10.0/shellcheck"; tar -cJf "$out" -C "$d" shellcheck-v0.10.0 ;;
    *.tgz) printf '#!/bin/sh\necho 0\n' >"$d/$tool"; chmod +x "$d/$tool"; tar -czf "$out" -C "$d" "$tool" ;;
    *) printf '#!/bin/sh\necho 0\n' >"$out"; chmod +x "$out" ;;
  esac
}

# run_step <script> <fake> <asset-name> <pin|-> <down> - prints rc, keeps $T/out
run_step() {
  local s="$T/run.sh" rc=0
  cp "$1" "$s"
  [[ "$4" != - ]] && sed -i -E "s/^sha=[0-9a-f]{64}$/sha=$4/" "$s"
  rm -rf "${T:?}/cache" "${T:?}/tmp"; mkdir -p "$T/cache" "$T/tmp"; : >"$T/curl.log"
  ( export PATH="$T/bin:$PATH" FAKE="$2" ASSET_NAME="$3" RUNNER_TOOL_CACHE="$T/cache" RUNNER_TEMP="$T/tmp" \
      GITHUB_PATH="$T/ghpath" GITHUB_ENV="$T/ghenv" ASSET_CACHE="$T/asset" CURL_LOG="$T/curl.log" CURL_DOWN="$5"
    bash "$s" ) >"$T/out" 2>&1 || rc=$?
  echo "$rc"
}

check_tool() {  # <workflow> <tool> <asset-name in cache> <fake extension>
  local wf="$WF_DIR/$1" tool="$2" name="$3" body v sha f="$T/asset.$4" h s="$T/step.sh"
  body=$(step "$wf" "Install $tool") || true
  if [[ -z "$body" ]]; then fail "$1 $tool: no install step"; return; fi
  sha=$(sed -nE '/^sha=[0-9a-f]{64}$/{s/^sha=//p;q}' <<<"$body")
  v=$(grep -m1 -oE "name: Install $tool [0-9.]+" "$wf" | awk '{print $NF}')
  if [[ -n "$sha" ]] && grep -q "key: release-asset-$tool-$v-$sha" "$wf"; then
    pass "$1 $tool: a cache keyed on tool, version and the step's sha256"
  else
    fail "$1 $tool: no cache key release-asset-$tool-$v-<its sha256>"
  fi
  printf '%s\n' "$body" >"$s"
  fake "$tool" "$f"; h=$(sha256sum "$f" | awk '{print $1}')
  local c="$T/asset/$name"
  rm -rf "${T:?}/asset"; mkdir -p "$(dirname "$c")"; cp "$f" "$c"
  if [[ "$(run_step "$s" "$f" "$name" "$h" "")" == 0 && ! -s "$T/curl.log" ]]; then pass "$1 $tool: a warm cache installs without curl"; else fail "$1 $tool: warm cache: $(tail -2 "$T/out")"; fi
  if [[ "$(run_step "$s" "$f" "$name" "${h//?/0}" "")" != 0 ]]; then pass "$1 $tool: a wrong sha256 fails on a cache hit"; else fail "$1 $tool: wrong sha passed on a cache hit"; fi
  rm -rf "${T:?}/asset"
  if [[ "$(run_step "$s" "$f" "$name" "$h" 1)" != 0 ]] && grep -q "::error::http.*no cached copy" "$T/out"; then pass "$1 $tool: cold cache + outage fails, naming the asset"; else fail "$1 $tool: outage: $(tail -2 "$T/out")"; fi
  rm -rf "${T:?}/asset"
  if [[ "$(run_step "$s" "$f" "$name" "$h" "")" == 0 && -f "$c" ]]; then pass "$1 $tool: cold cache + release up fills the cache"; else fail "$1 $tool: cold: $(tail -2 "$T/out")"; fi
  rm -rf "${T:?}/asset"
  if [[ "$(run_step "$s" "$f" "$name" "${h//?/0}" "")" != 0 && ! -f "$c" ]]; then pass "$1 $tool: a wrong sha256 on download fails and caches nothing"; else fail "$1 $tool: wrong sha on download"; fi
}

check_tool 10_ci-quality.yml gitleaks gitleaks.tgz tgz
check_tool 10_ci-quality.yml trivy trivy_0.74.0_Linux-64bit.tar.gz tgz
check_tool 10_ci-quality.yml rustup-init rustup-init bin
check_tool 15_sec-deps-secrets.yml gitleaks gitleaks.tgz tgz
check_tool 15_sec-deps-secrets.yml trivy trivy_0.74.0_Linux-64bit.tar.gz tgz
check_tool 62_gosec.yml gosec gosec.tar.gz tgz
check_tool 64_trufflehog.yml trufflehog trufflehog.tar.gz tgz
check_tool 66_hadolint.yml hadolint hadolint bin
check_tool 67_shellcheck.yml shellcheck shellcheck.tar.xz tar.xz
check_tool 70_supply-chain.yml trivy trivy_0.74.0_Linux-64bit.tar.gz tgz
check_tool 70_supply-chain.yml osv-scanner osv-scanner bin
check_tool 85_actionlint.yml actionlint actionlint.tgz tgz

if [[ "$(grep -c 'name: Install gitleaks' "$WF_DIR/10_ci-quality.yml")" == "$(grep -c 'name: Cache gitleaks' "$WF_DIR/10_ci-quality.yml")" ]]; then
  pass "10_ci-quality.yml: both gitleaks installs carry a cache step"
else
  fail "10_ci-quality.yml: a gitleaks install has no cache step"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-release-asset-cache.tst.sh assertions"
exit "$fails"
