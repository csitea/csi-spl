#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (specs 002 + 003): gofmt, go vet, go test -race,
# the reference-hygiene gate, the no-baked-hostname gate, the end-to-end smoke,
# the hub Postgres gate, the hub GCS/fake-gcs blob gate, and the per-package
# coverage floor (go-coverage-floor.txt, r5-10).
# Usage: bash csi-spl-api/src/bash/tests/run-all-tests.sh
#
# SPL_API_TEST_TIER=fast (CLE-77824) is the pre-push hook's tier: it leaves out
# the slow pieces -- build-stripped (two full builds), build-warm-mod-cache
# (four builds, ~26 s), cli-cross-build (the four release targets, ~17 s),
# go test -race (the plain go test still runs), the hub Postgres gate
# (~384 s) and the hub GCS gate -- and names each one it leaves out.
# CI (workflow 10 and the workflow 20
# deploy gate) never sets it, so CI always runs the full suite.
#
# HUB_SUITE_PART (spec 133 r28) splits the suite over two wf 10 jobs that run
# side by side: `pg` runs only the hub Postgres gate and its coverage floor
# (~443 s, the longest part), `plain` runs everything else. The default `all`
# runs both in the old order with the old output (pre-push, wf 20, local).
set -euo pipefail

tier="${SPL_API_TEST_TIER:-full}"
case "$tier" in full|fast) ;; *) echo "SPL_API_TEST_TIER must be full or fast (got '$tier')" >&2; exit 2 ;; esac
part="${HUB_SUITE_PART:-all}"
case "$part" in all|plain|pg) ;; *) echo "HUB_SUITE_PART must be all, plain or pg (got '$part')" >&2; exit 2 ;; esac
want() { [ "$part" = all ] || [ "$part" = "$1" ]; }
slow() { echo "SKIP-TIER (fast tier; CI workflow 10/20 runs it): $1"; }

# r5-10: per-package coverage ratchet. Reads a go test -coverprofile, prints
# each package's statement coverage, and fails when a package is more than 1.0
# point under its line in the floor file, or when a floored package is missing
# from the profile. A package with no floor line is printed as NEW and passes.
# A floor tagged `pg` was measured with Postgres, so the plain go test (no
# DSN) cannot reach it: scope `plain` prints those as SKIP-PG, and scope `pg`
# checks ONLY them, against the profiles hub-pg.tst.sh writes into
# $SPL_COVER_DIR (several profiles of one package are unioned). The gate
# never raises a floor; a lane that adds tests raises its line by hand.
# A floor tagged `coverpkg=<pkg>[,<pkg>...]` (r02-04) is measured with
# -coverpkg: the named packages' tests count toward it too (fakeidp is run by
# internal/auth's flow tests, not by its own). cover_cross_pkg writes those
# profiles; coverage_floor unions them with the plain one.
# Usage: coverage_floor <profile>... -- <floor-file> <go-module-dir> <plain|pg>
coverage_floor() {
  local profiles=() mod
  while [ "$1" != -- ]; do profiles+=("$1"); shift; done
  mod="$(sed -n 's/^module //p' "$3/go.mod")"
  awk -v mod="$mod/" -v scope="$4" '
    FNR == NR { if ($0 !~ /^#/ && NF >= 2 && (scope == "plain" || $3 == "pg")) { floor[$1] = $2; tag[$1] = $3 } next }
    $1 != "mode:" {
      if (!($1 in stmts)) { f = $1; sub(/:.*/, "", f); sub(/\/[^\/]*$/, "", f); sub("^" mod, "", f); pkg[$1] = f; stmts[$1] = $2 }
      if ($3 > 0) hit[$1] = 1
    }
    END {
      for (b in stmts) { p = pkg[b]; tot[p] += stmts[b]; if (b in hit) cov[p] += stmts[b] }
      for (p in tot) {
        c = sprintf("%.1f", 100 * cov[p] / tot[p])
        if (!(p in floor)) { print "NEW  - " p " " c "% (no floor line)"; continue }
        if (tag[p] == "pg" && scope == "plain") { print "SKIP-PG - " p " " c "% (floor " floor[p] ": the hub Postgres gate checks it)"; continue }
        if (c + 1.0 < floor[p]) { print "FAIL - " p " " c "% is under its floor " floor[p] " - 1.0"; bad++ }
        else print "ok   - " p " " c "% (floor " floor[p] ")"
      }
      for (p in floor) if (!(p in tot)) { print "FAIL - " p " has floor " floor[p] " but is not in the profile (package removed? drop its line)"; bad++ }
      exit (bad > 0)
    }' "$2" "${profiles[@]}" | sort -k3
  return "${PIPESTATUS[0]}"
}
# Usage: cover_cross_pkg <floor-file> <go-module-dir> <out-dir>
cover_cross_pkg() {
  local pkg tag t args
  while read -r pkg tag; do
    args=("./$pkg")
    for t in ${tag//,/ }; do args+=("./$t"); done
    echo "-coverpkg=./$pkg: ${args[*]}"
    ( cd "$2" && go test -coverpkg="./$pkg" -coverprofile="$3/xpkg-${pkg//\//_}.out" "${args[@]}" )
  done < <(awk '$0 !~ /^#/ && $3 ~ /^coverpkg=/ { sub(/^coverpkg=/, "", $3); print $1, $3 }' "$1")
}
if [ "${1:-}" = --coverage-floor ]; then # the check alone: run-all-tests.sh --coverage-floor <plain|pg> <floor-file> <profile>...
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  coverage_floor "${@:4}" -- "$3" "$here/../../go/spool-hub-api" "$2"
  exit
fi

export GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path

# spec 072 A66: a fresh clone's module cache is cold; fill it once, then
# everything below runs offline as before.
# shellcheck source=../warm-go-mod-cache.sh
source "$HERE/../warm-go-mod-cache.sh"
spl_warm_go_mod_cache "$MOD"
# -trimpath (SPL-3171): without it a compile action id holds the package dir,
# so every lane worktree wrote its own copy of each package into the shared
# build cache (sat 2026-10-24: 262 MB per hub-pg compile, 0.45 MB with it,
# n=1); go-test-trimpath.tst.sh holds it. Never for build.sh (main.commit).
export GOFLAGS="-mod=mod -trimpath" GOPROXY=off GOSUMDB=off

COVER_DIR="$(mktemp -d)"
trap 'rm -rf "$COVER_DIR"' EXIT

if want plain; then
echo "== go toolchain selector =="
bash "$HERE/use-go-toolchain.tst.sh"
bash "$HERE/warm-go-mod-cache.tst.sh"
bash "$HERE/go-cache-throwaway.tst.sh"
bash "$HERE/go-test-trimpath.tst.sh"
if [ "$tier" = full ]; then bash "$HERE/build-stripped.tst.sh"; else slow build-stripped.tst.sh; fi
if [ "$tier" = full ]; then bash "$HERE/build-warm-mod-cache.tst.sh"; else slow build-warm-mod-cache.tst.sh; fi
if [ "$tier" = full ]; then bash "$HERE/cli-cross-build.tst.sh"; else slow cli-cross-build.tst.sh; fi

echo "== gofmt =="
unformatted="$(cd "$MOD" && gofmt -l .)"
[ -z "$unformatted" ] || { echo "gofmt needed on:"; echo "$unformatted"; exit 1; }
echo "ok   - gofmt clean"

echo "== go vet =="
( cd "$MOD" && go vet ./... )
echo "ok   - go vet clean"

# 016 T002 / FR-004: the gate runs under the race detector, so a data race
# fails it instead of landing green (-race needs cgo: CGO_ENABLED=1 + gcc).
if [ "$tier" = full ]; then
  echo "== go test -race =="
  ( cd "$MOD" && CGO_ENABLED=1 go test -race -coverprofile="$COVER_DIR/cover.out" ./... )
else
  echo "== go test (no -race: fast tier) =="
  ( cd "$MOD" && go test -coverprofile="$COVER_DIR/cover.out" ./... )
  slow "go test -race"
fi

echo "== go coverage, cross-package floors (r02-04: -coverpkg for floors tagged coverpkg=) =="
cover_cross_pkg "$HERE/go-coverage-floor.txt" "$MOD" "$COVER_DIR"
xpkg=("$COVER_DIR"/xpkg-*.out); [ -e "${xpkg[0]}" ] || xpkg=()

echo "== go coverage floor (r5-10, $HERE/go-coverage-floor.txt) =="
coverage_floor "$COVER_DIR/cover.out" "${xpkg[@]}" -- "$HERE/go-coverage-floor.txt" "$MOD" plain
echo "ok   - every package within 1.0 point of its floor (pg floors: after the hub Postgres gate)"

echo "== standalone hub-init rules (047 W9, W18) =="
bash "$HERE/hub-entrypoint.tst.sh"

echo "== reference-hygiene gate =="
bash "$HERE/no-ysg-box-ref.tst.sh"
bash "$HERE/no-baked-host.tst.sh"

echo "== payment-vendor WUI gate =="
bash "$HERE/no-payment-vendor-wui.tst.sh"

echo "== no-baked-hostname gate (spec 007 T017) =="
bash "$HERE/no-baked-hostname.tst.sh"

echo "== cookie Secure cnf gate (SPL-1285: dev+prd must run Secure cookies) =="
bash "$HERE/cookie-secure-cnf.tst.sh"

echo "== end-to-end smoke =="
bash "$HERE/spool-smoke.tst.sh"

echo "== store Postgres groups: every store test in exactly one process (both tiers, no Postgres) =="
bash "$HERE/store-pg-groups.tst.sh"

echo "== hub Postgres groups: every internal/hub test in exactly one process (both tiers, no Postgres) =="
bash "$HERE/hub-pg-groups.tst.sh"

echo "== throwaway live hub stack: no hub is a failure, never a skip (SPL-2167; the full stack is wf 10 hub-live) =="
bash "$HERE/hub-live-stack.tst.sh"
fi

if want pg; then
echo "== hub Postgres gate: migrate, store/hub suites on Postgres, binary e2e (skips without Postgres) =="
if [ "$tier" = full ]; then
  SPL_COVER_DIR="$COVER_DIR" bash "$HERE/hub-pg.tst.sh"
  if compgen -G "$COVER_DIR/pg-*.out" >/dev/null; then
    echo "== go coverage floor, pg packages (r5-10: the profiles hub-pg.tst.sh wrote) =="
    coverage_floor "$COVER_DIR"/pg-*.out -- "$HERE/go-coverage-floor.txt" "$MOD" pg
    echo "ok   - every pg package within 1.0 point of its floor"
  else echo "skip - no Postgres profiles (the hub Postgres gate skipped); pg floors not checked"; fi
else slow hub-pg.tst.sh; fi
fi

if want plain; then
echo "== hub GCS gate: internal/blob against fake-gcs (skips without cached emulator image) =="
if [ "$tier" = full ]; then bash "$HERE/hub-gcs.tst.sh"; else slow hub-gcs.tst.sh; fi
fi

if [ "$part" = all ]; then echo "ALL csi-spl-api TESTS PASSED (tier=$tier)"
else echo "ALL csi-spl-api TESTS PASSED (tier=$tier, part=$part)"; fi
