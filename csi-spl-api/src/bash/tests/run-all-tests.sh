#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (specs 002 + 003): gofmt, go vet, go test,
# the reference-hygiene gate, the end-to-end smoke, the hub Postgres gate,
# and the hub GCS/fake-gcs blob gate.
# Usage: bash csi-spl-api/src/bash/tests/run-all-tests.sh
set -euo pipefail

export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"

echo "== gofmt =="
unformatted="$(cd "$MOD" && gofmt -l .)"
[ -z "$unformatted" ] || { echo "gofmt needed on:"; echo "$unformatted"; exit 1; }
echo "ok   - gofmt clean"

echo "== go vet =="
( cd "$MOD" && go vet ./... )
echo "ok   - go vet clean"

echo "== go test =="
( cd "$MOD" && go test ./... )

echo "== reference-hygiene gate =="
bash "$HERE/no-ysg-box-ref.tst.sh"

echo "== payment-vendor WUI gate =="
bash "$HERE/no-payment-vendor-wui.tst.sh"

echo "== end-to-end smoke =="
bash "$HERE/spool-smoke.tst.sh"

echo "== hub Postgres gate: migrate, store/hub suites on Postgres, binary e2e (skips without Postgres) =="
bash "$HERE/hub-pg.tst.sh"

echo "== hub GCS gate: internal/blob against fake-gcs (skips without cached emulator image) =="
bash "$HERE/hub-gcs.tst.sh"

echo "ALL csi-spl-api TESTS PASSED"
