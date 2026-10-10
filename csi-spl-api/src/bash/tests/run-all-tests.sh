#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (specs 002 + 003): gofmt, go vet, go test -race,
# the reference-hygiene gate, the no-baked-hostname gate, the end-to-end smoke,
# the hub Postgres gate, the hub GCS/fake-gcs blob gate, and the per-package
# coverage floor (go-coverage-floor.txt, r5-10).
# Usage: bash csi-spl-api/src/bash/tests/run-all-tests.sh
#
# SPL_API_TEST_TIER=fast (CLE-77824) is the pre-push hook's tier: it leaves out
# the four slow pieces -- build-stripped (two full builds), go test -race (the
# plain go test still runs), the hub Postgres gate (~384 s) and the hub GCS
# gate -- and names each one it leaves out. CI (workflow 10 and the workflow 20
# deploy gate) never sets it, so CI always runs the full suite.
set -euo pipefail

tier="${SPL_API_TEST_TIER:-full}"
case "$tier" in full|fast) ;; *) echo "SPL_API_TEST_TIER must be full or fast (got '$tier')" >&2; exit 2 ;; esac
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
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off

echo "== go toolchain selector =="
bash "$HERE/use-go-toolchain.tst.sh"
bash "$HERE/warm-go-mod-cache.tst.sh"
if [ "$tier" = full ]; then bash "$HERE/build-stripped.tst.sh"; else slow build-stripped.tst.sh; fi

echo "== gofmt =="
unformatted="$(cd "$MOD" && gofmt -l .)"
[ -z "$unformatted" ] || { echo "gofmt needed on:"; echo "$unformatted"; exit 1; }
echo "ok   - gofmt clean"

echo "== go vet =="
( cd "$MOD" && go vet ./... )
echo "ok   - go vet clean"

# 016 T002 / FR-004: the gate runs under the race detector, so a data race
# fails it instead of landing green (-race needs cgo: CGO_ENABLED=1 + gcc).
COVER_DIR="$(mktemp -d)"
trap 'rm -rf "$COVER_DIR"' EXIT
if [ "$tier" = full ]; then
  echo "== go test -race =="
  ( cd "$MOD" && CGO_ENABLED=1 go test -race -coverprofile="$COVER_DIR/cover.out" ./... )
else
  echo "== go test (no -race: fast tier) =="
  ( cd "$MOD" && go test -coverprofile="$COVER_DIR/cover.out" ./... )
  slow "go test -race"
fi

echo "== go coverage floor (r5-10, $HERE/go-coverage-floor.txt) =="
coverage_floor "$COVER_DIR/cover.out" -- "$HERE/go-coverage-floor.txt" "$MOD" plain
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

echo "== hub Postgres gate: migrate, store/hub suites on Postgres, binary e2e (skips without Postgres) =="
if [ "$tier" = full ]; then
  SPL_COVER_DIR="$COVER_DIR" bash "$HERE/hub-pg.tst.sh"
  if compgen -G "$COVER_DIR/pg-*.out" >/dev/null; then
    echo "== go coverage floor, pg packages (r5-10: the profiles hub-pg.tst.sh wrote) =="
    coverage_floor "$COVER_DIR"/pg-*.out -- "$HERE/go-coverage-floor.txt" "$MOD" pg
    echo "ok   - every pg package within 1.0 point of its floor"
  else echo "skip - no Postgres profiles (the hub Postgres gate skipped); pg floors not checked"; fi
else slow hub-pg.tst.sh; fi

echo "== hub GCS gate: internal/blob against fake-gcs (skips without cached emulator image) =="
if [ "$tier" = full ]; then bash "$HERE/hub-gcs.tst.sh"; else slow hub-gcs.tst.sh; fi

echo "ALL csi-spl-api TESTS PASSED (tier=$tier)"
