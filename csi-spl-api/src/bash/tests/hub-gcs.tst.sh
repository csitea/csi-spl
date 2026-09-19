#!/usr/bin/env bash
# Hub GCS blob gate (specs/003 T022): start a throwaway fake-gcs-server (the
# lde emulator), create one files bucket, and run internal/blob against
# STORAGE_EMULATOR_HOST. The image is locally CACHED (never pulled); without
# docker + image this skips (exit 0).
# Usage: bash csi-spl-api/src/bash/tests/hub-gcs.tst.sh
set -euo pipefail

export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
GCS_IMAGE="${SPOOL_TEST_GCS_IMAGE:-fsouza/fake-gcs-server:1.52.2}"
BUCKET="${SPOOL_HUB_FILES_BUCKET:-csi-spl-test-files}"

CTR=""
cleanup() {
  [ -n "$CTR" ] && docker rm -f "$CTR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v docker >/dev/null || ! docker image inspect "$GCS_IMAGE" >/dev/null 2>&1; then
  echo "skip - no cached $GCS_IMAGE image; hub GCS gate not run"
  exit 0
fi

PORT="$(( 20000 + RANDOM % 20000 ))"
CTR="spool-hub-gcs-test-$$"
docker run -d --rm --pull never --name "$CTR" -p "127.0.0.1:${PORT}:4443" \
  "$GCS_IMAGE" \
  -scheme http -port 4443 -external-url "http://127.0.0.1:${PORT}" -backend memory >/dev/null

base="http://127.0.0.1:${PORT}/storage/v1"
code=""
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/b?project=test") || code=000
  [ "$code" = 200 ] && break
  sleep 0.2
done
[ "$code" = 200 ] || { echo "FAIL - fake-gcs did not come up (list buckets -> $code)"; exit 1; }

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"$BUCKET\"}" "$base/b?project=test")
[ "$code" = 200 ] || [ "$code" = 409 ] || { echo "FAIL - create $BUCKET -> $code"; exit 1; }
echo "ok   - temp fake-gcs up ($GCS_IMAGE) bucket $BUCKET on 127.0.0.1:$PORT"

( cd "$MOD" && STORAGE_EMULATOR_HOST="127.0.0.1:${PORT}" SPOOL_HUB_FILES_BUCKET="$BUCKET" \
  CGO_ENABLED=1 go test -race -count=1 ./internal/blob/ )
echo "ok   - internal/blob suite green against GCS emulator"
# 027 T020: the hub's streamed POST /v1/files on GCS, and objects.list per upload.
( cd "$MOD" && STORAGE_EMULATOR_HOST="127.0.0.1:${PORT}" SPOOL_HUB_FILES_BUCKET="$BUCKET" \
  CGO_ENABLED=1 go test -race -count=1 -v -run 'TestUploadGCSListCalls' ./internal/hub/ ) | grep -E 'UPLOADGCS|^(--- |ok|FAIL)'
echo "ok   - hub streamed upload green against GCS emulator"
echo "ALL HUB GCS CHECKS PASSED"
