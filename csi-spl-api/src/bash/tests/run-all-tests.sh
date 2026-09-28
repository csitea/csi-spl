#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (specs 002 + 003): gofmt, go vet, go test -race,
# the reference-hygiene gate, the no-baked-hostname gate, the end-to-end smoke,
# the hub Postgres gate, and the hub GCS/fake-gcs blob gate.
# Usage: bash csi-spl-api/src/bash/tests/run-all-tests.sh
set -euo pipefail

export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path

echo "== go toolchain selector =="
bash "$HERE/use-go-toolchain.tst.sh"
bash "$HERE/build-stripped.tst.sh"

echo "== gofmt =="
unformatted="$(cd "$MOD" && gofmt -l .)"
[ -z "$unformatted" ] || { echo "gofmt needed on:"; echo "$unformatted"; exit 1; }
echo "ok   - gofmt clean"

echo "== go vet =="
( cd "$MOD" && go vet ./... )
echo "ok   - go vet clean"

# 016 T002 / FR-004: the gate runs under the race detector, so a data race
# fails it instead of landing green (-race needs cgo: CGO_ENABLED=1 + gcc).
echo "== go test -race =="
( cd "$MOD" && CGO_ENABLED=1 go test -race ./... )

echo "== reference-hygiene gate =="
bash "$HERE/no-ysg-box-ref.tst.sh"
bash "$HERE/no-baked-host.tst.sh"

echo "== payment-vendor WUI gate =="
bash "$HERE/no-payment-vendor-wui.tst.sh"

echo "== no-baked-hostname gate (spec 007 T017) =="
bash "$HERE/no-baked-hostname.tst.sh"

echo "== end-to-end smoke =="
bash "$HERE/spool-smoke.tst.sh"

echo "== hub Postgres gate: migrate, store/hub suites on Postgres, binary e2e (skips without Postgres) =="
bash "$HERE/hub-pg.tst.sh"

echo "== hub GCS gate: internal/blob against fake-gcs (skips without cached emulator image) =="
bash "$HERE/hub-gcs.tst.sh"

echo "ALL csi-spl-api TESTS PASSED"
