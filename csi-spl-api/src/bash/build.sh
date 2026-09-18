#!/usr/bin/env bash
# Build the spool binary (spec 002). Offline-friendly: uses the module cache.
# Usage: bash csi-spl-api/src/bash/build.sh [output-path]
set -euo pipefail

export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../go/spool-hub-api"
OUT="${1:-$MOD/bin/spool}"

VERSION="$(cat "$HERE/../../../.version" 2>/dev/null || echo 0.1.0-dev)"
mkdir -p "$(dirname "$OUT")"
( cd "$MOD" && go build -ldflags "-X main.version=$VERSION" -o "$OUT" ./cmd/spool )
echo "built $OUT ($VERSION)"
