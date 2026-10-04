#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the spool CLI release assets (spec 072 A4a, lane L3), with a fake
# build script and a fake gh (no Go, no network, no GitHub release):
#   1. DRY_RUN=1 builds the 4 targets as spool-<os>-<arch>, each built with
#      its own GOOS/GOARCH, CGO_ENABLED=0 and the v-tag on HEAD as version;
#      spool-SHA256SUMS verifies with sha256sum -c; gh is never called
#   2. DRY_RUN=0 without CLI_ASSETS_TAG = FATAL, gh never called
#   3. DRY_RUN=0 uploads the 4 builds + spool-SHA256SUMS to the tag, --clobber
#   4. CONTROL: one target's build fails = FATAL, nothing uploaded
#   5. a malformed CLI_ASSETS_TARGETS entry is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q "$T/w" && echo 1 >"$T/w/f" && git -C "$T/w" add f && git -C "$T/w" commit -q -m init
git -C "$T/w" tag v1.2.3

# the fake build: records what it was asked to build, as build.sh's argv/env
cat >"$T/build.sh" <<'B'
#!/usr/bin/env bash
[[ "$GOOS/$GOARCH" == "${FAIL_TARGET:-none}" ]] && { echo "boom $GOOS/$GOARCH" >&2; exit 1; }
echo "os=$GOOS arch=$GOARCH cgo=$CGO_ENABLED version=$SPOOL_BUILD_VERSION" >"$1"
B
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'G'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
G
chmod +x "$T/bin/gh"

act() {  # env... -> stdout; rc kept
  env PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/w" \
    CLI_ASSETS_BUILD="$T/build.sh" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_cli_assets' 2>>"$T/act.err"
}
want="spool-darwin-amd64 spool-darwin-arm64 spool-linux-amd64 spool-linux-arm64"

# --- 1. dry run --------------------------------------------------------------------
: >"$T/gh.log"
out=$(act CLI_ASSETS_DIR="$T/d1"); rc=$?
got=$(cd "$T/d1" 2>/dev/null && ls spool-*-* | tr '\n' ' ' | sed 's/ $//')
[[ $rc == 0 && "$got" == "$want" ]] && pass "dry run: the 4 targets as spool-<os>-<arch>" || fail "dry run: rc $rc, files '$got'"
grep -qx 'os=darwin arch=arm64 cgo=0 version=1.2.3' "$T/d1/spool-darwin-arm64" 2>/dev/null &&
  grep -qx 'os=linux arch=amd64 cgo=0 version=1.2.3' "$T/d1/spool-linux-amd64" 2>/dev/null &&
  pass "each build: its own GOOS/GOARCH, CGO_ENABLED=0, the v-tag on HEAD" || fail "build env: $(cat "$T/d1"/spool-* 2>/dev/null)"
[[ -x "$T/d1/spool-linux-amd64" ]] && pass "the builds are executable" || fail "spool-linux-amd64 is not executable"
(cd "$T/d1" && sha256sum -c --quiet spool-SHA256SUMS) && [[ $(grep -c . "$T/d1/spool-SHA256SUMS") == 4 ]] &&
  pass "spool-SHA256SUMS: 4 rows, sha256sum -c passes" || fail "spool-SHA256SUMS: $(cat "$T/d1/spool-SHA256SUMS" 2>/dev/null)"
[[ ! -s "$T/gh.log" ]] && grep -q 'OK DRY_RUN built 4' <<<"$out" && pass "dry run: gh never called" || fail "dry run called gh: $(cat "$T/gh.log")"

# --- 2. DRY_RUN=0 without a tag ----------------------------------------------------
out=$(act DRY_RUN=0 CLI_ASSETS_DIR="$T/d2"); rc=$?
((rc != 0)) && grep -q 'needs CLI_ASSETS_TAG' <<<"$out" && [[ ! -s "$T/gh.log" ]] &&
  pass "DRY_RUN=0 without CLI_ASSETS_TAG: FATAL, no upload" || fail "no tag: rc $rc, $out"

# --- 3. upload ---------------------------------------------------------------------
: >"$T/gh.out"
out=$(act DRY_RUN=0 CLI_ASSETS_TAG=stable-2026-10-05 CLI_ASSETS_DIR="$T/d3" GITHUB_OUTPUT="$T/gh.out"); rc=$?
line=$(cat "$T/gh.log")
if ((rc == 0)) && [[ $(grep -c . "$T/gh.log") == 1 ]] && grep -q '^release upload stable-2026-10-05 --clobber ' <<<"$line" \
   && [[ $(tr ' ' '\n' <<<"$line" | grep -c "^$T/d3/spool-") == 5 ]] && grep -q "$T/d3/spool-SHA256SUMS" <<<"$line"; then
  pass "DRY_RUN=0: one gh release upload of 4 builds + spool-SHA256SUMS, --clobber"
else
  fail "upload: rc $rc, gh: $line"
fi
grep -qx 'assets=spool-linux-amd64 spool-linux-arm64 spool-darwin-amd64 spool-darwin-arm64 spool-SHA256SUMS' "$T/gh.out" &&
  pass "GITHUB_OUTPUT assets=" || fail "GITHUB_OUTPUT: $(cat "$T/gh.out")"

# --- 4. CONTROL: a failed build ----------------------------------------------------
: >"$T/gh.log"
out=$(act DRY_RUN=0 CLI_ASSETS_TAG=stable-2026-10-05 CLI_ASSETS_DIR="$T/d4" FAIL_TARGET=darwin/amd64); rc=$?
((rc != 0)) && grep -q 'darwin/amd64 build failed' <<<"$out" && [[ ! -s "$T/gh.log" ]] &&
  pass "CONTROL: a failed build is FATAL and uploads nothing" || fail "failed build: rc $rc, gh: $(cat "$T/gh.log")"

# --- 5. malformed target -----------------------------------------------------------
out=$(act CLI_ASSETS_TARGETS="linux-amd64" CLI_ASSETS_DIR="$T/d5"); rc=$?
((rc != 0)) && grep -q 'are <os>/<arch>' <<<"$out" && pass "a malformed target is refused" || fail "bad target: rc $rc, $out"

[[ $fails -eq 0 ]] && echo "PASS: all release-cli-assets.tst.sh assertions" || { echo "FAIL: $fails"; cat "$T/act.err"; exit 1; }
