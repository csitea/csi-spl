#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (specs 002 + 003): gofmt, go vet, go test -race,
# the reference-hygiene gate, the no-baked-hostname gate, the end-to-end smoke,
# the hub Postgres gate, and the hub GCS/fake-gcs blob gate.
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
if [ "$tier" = full ]; then
  echo "== go test -race =="
  ( cd "$MOD" && CGO_ENABLED=1 go test -race ./... )
else
  echo "== go test (no -race: fast tier) =="
  ( cd "$MOD" && go test ./... )
  slow "go test -race"
fi

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
if [ "$tier" = full ]; then bash "$HERE/hub-pg.tst.sh"; else slow hub-pg.tst.sh; fi

echo "== hub GCS gate: internal/blob against fake-gcs (skips without cached emulator image) =="
if [ "$tier" = full ]; then bash "$HERE/hub-gcs.tst.sh"; else slow hub-gcs.tst.sh; fi

echo "ALL csi-spl-api TESTS PASSED (tier=$tier)"
