#!/usr/bin/env bash
# spl_warm_go_mod_cache (spec 072 A66): a fresh clone's cold module cache is
# filled once, then the module resolves offline.
# The "online" proxy is this box's own warm cache served as file://, so the
# test needs no network. CONTROLS: an empty cache does not resolve offline
# before the warm-up; GOPROXY=off from the caller refuses instead of
# downloading.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
# shellcheck source=../warm-go-mod-cache.sh
source "$HERE/../warm-go-mod-cache.sh"
spl_export_go_path
export GOTOOLCHAIN=local GOSUMDB=off

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
export GOMODCACHE="$T/mod" GOCACHE="$T/build" GOFLAGS=-mod=mod

offline_list() { (cd "$MOD" && GOPROXY=off go list -deps -test ./... >/dev/null 2>&1); }

if offline_list; then
  fail "CONTROL: an empty cache resolves offline (the test proves nothing)"
else
  pass "CONTROL: an empty cache does not resolve offline"
fi

if (GOPROXY=off spl_warm_go_mod_cache "$MOD") >"$T/off.out" 2>&1; then
  fail "CONTROL: GOPROXY=off on a cold cache returned 0"
elif grep -q 'GOPROXY=off' "$T/off.out"; then
  pass "CONTROL: GOPROXY=off on a cold cache refuses and names the cause"
else
  fail "CONTROL: the GOPROXY=off refusal does not name the cause: $(cat "$T/off.out")"
fi

if (GOPROXY="file://$warm" spl_warm_go_mod_cache "$MOD") >"$T/warm.out" 2>&1 && grep -q 'cache cold' "$T/warm.out"; then
  pass "cold cache: downloaded once"
else
  fail "cold cache warm-up: $(cat "$T/warm.out")"
fi

if offline_list; then
  pass "after the warm-up every package and test dependency resolves offline"
else
  fail "after the warm-up the module still does not resolve offline"
fi

if (GOPROXY="file://$T/none" spl_warm_go_mod_cache "$MOD") >"$T/again.out" 2>&1 && ! grep -q 'cache cold' "$T/again.out"; then
  pass "warm cache: no second download"
else
  fail "warm cache downloaded again: $(cat "$T/again.out")"
fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "ALL warm-go-mod-cache checks passed"
