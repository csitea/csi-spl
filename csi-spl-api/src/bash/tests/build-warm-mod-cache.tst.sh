#!/usr/bin/env bash
# build.sh warms THIS user's module cache before its offline build (SPL-1866).
# After a go.sum bump the box that did not build it lacks the new modules; the
# spawn build failed there with "module lookup disabled by GOPROXY=off". The
# second box is played by a throwaway GOMODCACHE; the "network" is this box's
# own warm cache served as file://, so the test needs none.
#   1. cold cache + a proxy: the build warms the cache and passes
#      (red before the fix: the offline build refused the module lookup)
#   2. warm cache, the proxy gone: still passes (the no-op path is offline)
#   3. a go.sum module missing from the cache, no proxy reachable: ONE FATAL
#      line naming the box, the user and the go.sum; no binary
#   4. CONTROL: a caller that exported GOPROXY=off asked for no network: the
#      same missing module refuses, naming GOPROXY=off, and downloads nothing
# BUILD_SH overrides the script under test (to show the red on the old one).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
BUILD="${BUILD_SH:-$HERE/../build.sh}"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
export GOTOOLCHAIN=local

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

warm="$(go env GOMODCACHE)/cache/download"
if ! (cd "$MOD" && GOPROXY=off GOFLAGS=-mod=mod go mod download) >/dev/null 2>&1; then
  echo "SKIP: this box's module cache is cold too (run-all-tests.sh warms it first)"
  exit 0
fi

T=$(mktemp -d)
# the module cache is read-only by design
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
# The build cache stays shared: only the module cache plays the second box.
export GOMODCACHE="$T/mod"
unset GOFLAGS GOSUMDB

# 1. cold cache, a reachable proxy
if GOPROXY="file://$warm" bash "$BUILD" "$T/spool1" >"$T/1.out" 2>&1 && [ -x "$T/spool1" ]; then
  pass "1. cold cache: build.sh warmed it and built"
else
  fail "1. cold cache + proxy: no build: $(grep -m2 -E 'FATAL|disabled|error' "$T/1.out" || tail -2 "$T/1.out")"
fi

# 2. warm cache, nothing online
if GOPROXY="file://$T/none" bash "$BUILD" "$T/spool2" >"$T/2.out" 2>&1 && [ -x "$T/spool2" ] && ! grep -q 'cache cold' "$T/2.out"; then
  pass "2. warm cache: built offline, no download"
else
  fail "2. warm cache: $(tail -2 "$T/2.out")"
fi

# 3. go.sum names a module the cache lacks (the bump), and no network
victim="$(cd "$MOD" && go list -m -f '{{.Path}}@{{.Version}}' golang.org/x/text 2>/dev/null)"
chmod -R u+w "$GOMODCACHE"
rm -rf "$GOMODCACHE/${victim%@*}@${victim#*@}" "$GOMODCACHE/cache/download/${victim%@*}/@v/${victim#*@}".*
rc=0; GOPROXY="file://$T/none" bash "$BUILD" "$T/spool3" >"$T/3.out" 2>&1 || rc=$?
n="$(grep -c '^FATAL ' "$T/3.out" || true)"
line="$(grep '^FATAL ' "$T/3.out" || true)"
sum="$(sha256sum "$MOD/go.sum" | cut -c1-12)"
if [ "$rc" -ne 0 ] && [ "$n" = 1 ] && [ ! -e "$T/spool3" ] &&
  [[ "$line" == *"box "* && "$line" == *"user $(id -un)"* && "$line" == *"go.sum $sum"* ]]; then
  pass "3. missing $victim, no network: one FATAL naming box, user and go.sum ($line)"
else
  fail "3. rc=$rc FATAL lines=$n: $(tail -3 "$T/3.out")"
fi

# 4. CONTROL: the caller's GOPROXY=off is honoured, nothing goes online
rc=0; GOPROXY=off bash "$BUILD" "$T/spool4" >"$T/4.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$T/spool4" ] && grep -q 'GOPROXY=off' "$T/4.out"; then
  pass "4. CONTROL: caller GOPROXY=off + missing module refuses, no download"
else
  fail "4. CONTROL: caller GOPROXY=off: rc=$rc $(tail -2 "$T/4.out")"
fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "ALL build-warm-mod-cache checks passed"
