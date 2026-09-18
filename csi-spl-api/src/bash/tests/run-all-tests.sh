#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (spec 002): gofmt, go vet, go test, the
# reference-hygiene gate, and the end-to-end smoke.
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

echo "== end-to-end smoke =="
bash "$HERE/spool-smoke.tst.sh"

echo "ALL csi-spl-api TESTS PASSED"
