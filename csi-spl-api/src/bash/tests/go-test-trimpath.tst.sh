#!/usr/bin/env bash
# The api test scripts run go with -trimpath, so lane worktrees share the
# user's build cache (SPL-3171). Without it a compile action id holds the
# package dir: each worktree wrote its own copy of every package it tested.
# sat, 2026-10-24, hub-pg's compile (-race -cover, internal/hub + store), one
# throwaway GOCACHE, n=1: a second worktree of the same sha added 262269306
# bytes, 447451 with -trimpath; the box's cache had 5.72 GB born in one hour.
#   1. every tests/*.tst.sh and run-all-tests.sh that runs go test/vet
#      exports GOFLAGS with -trimpath (listed by path when not)
#   2. no _test.go finds a file through runtime.Caller: under -trimpath its
#      file is module-relative (go test runs in the package dir; use that)
#   3. a package built in two dirs with run-all-tests.sh's GOFLAGS is written
#      to the cache once
#   4. CONTROL: the same two builds without -trimpath write it twice
#   5. CONTROL: checks 1 and 2 report a planted offender
# GO_TRIMPATH_SCAN_ROOT overrides the tree scanned (to show the red on an old one).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${GO_TRIMPATH_SCAN_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# no_trimpath <tests-dir>: the go test/vet scripts that never export -trimpath
no_trimpath() {
  local f
  for f in "$1"/*.tst.sh "$1"/run-all-tests.sh; do
    [ "${f##*/}" = go-test-trimpath.tst.sh ] && continue # its planted control
    [ -f "$f" ] && grep -vE '^[[:space:]]*#' "$f" | grep -E '\bgo (test|vet) +(-|\./)' >/dev/null || continue
    grep -qE '^export GOFLAGS="[^"]*-trimpath' "$f" || echo "$f"
  done
}
# caller_paths <go-dir>: test files that call runtime.Caller
caller_paths() { grep -rlE --include='*_test.go' 'runtime\.Caller\(' "$1" 2>/dev/null || true; }

bad="$(no_trimpath "$ROOT/csi-spl-api/src/bash/tests")"
[ -z "$bad" ] && pass "1. every api go test/vet script exports GOFLAGS with -trimpath" \
  || fail "1. go test/vet without -trimpath: $(tr '\n' ' ' <<<"$bad")"
bad="$(caller_paths "$ROOT/csi-spl-api/src/go")"
[ -z "$bad" ] && pass "2. no _test.go locates a file through runtime.Caller" \
  || fail "2. runtime.Caller in tests (breaks under -trimpath): $(tr '\n' ' ' <<<"$bad")"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
flags="$(sed -nE 's/^export GOFLAGS="([^"]*)".*/\1/p; s/^export GOFLAGS=([^ ]+).*/\1/p' "$ROOT/csi-spl-api/src/bash/tests/run-all-tests.sh")"
for w in w1 w2; do
  mkdir -p "$T/$w/p"
  printf 'module example.com/m\n\ngo 1.21\n' >"$T/$w/go.mod"
  printf 'package p\n\nfunc Add(a, b int) int { return a + b }\n' >"$T/$w/p/p.go"
done
# written <GOFLAGS>: compile outputs in a fresh GOCACHE after a build in w1 and w2
written() {
  rm -rf "$T/cache"; mkdir -p "$T/cache"
  for w in w1 w2; do
    ( cd "$T/$w" && GOCACHE="$T/cache" GOFLAGS="$1" GOTOOLCHAIN=local GOPROXY=off go build ./p )
  done
  grep -rl --include='*-d' -a 'go object' "$T/cache" | wc -l
}
n="$(written "$flags")"
[ "$n" -eq 1 ] && pass "3. GOFLAGS=\"$flags\": two worktrees, one cache entry" \
  || fail "3. GOFLAGS=\"$flags\": two worktrees wrote $n entries, want 1"
n="$(written "-mod=mod")"
[ "$n" -eq 2 ] && pass "4. CONTROL: without -trimpath the two worktrees write 2 entries" \
  || fail "4. CONTROL: without -trimpath want 2 entries, got $n"

mkdir -p "$T/plant/tests" "$T/plant/go/x"
printf '%s\n' 'export GOFLAGS=-mod=mod' 'go test ./...' >"$T/plant/tests/a.tst.sh"
printf '%s\n' 'package x' '' 'import "runtime"' '' 'func f() { _, _, _, _ = runtime.Caller(0) }' >"$T/plant/go/x/x_test.go"
if [ "$(no_trimpath "$T/plant/tests")" = "$T/plant/tests/a.tst.sh" ] \
  && [ "$(caller_paths "$T/plant/go")" = "$T/plant/go/x/x_test.go" ]; then
  pass "5. CONTROL: a planted script without -trimpath and a planted runtime.Caller are reported"
else
  fail "5. CONTROL: the scans miss a planted offender"
fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "ALL go-test-trimpath checks passed"
