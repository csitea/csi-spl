#!/usr/bin/env bash
# Build the spool binary (spec 002). Offline-friendly: uses the module cache.
# Usage: bash csi-spl-api/src/bash/build.sh [output-path]
set -euo pipefail

export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=use-go-toolchain.sh
source "$HERE/use-go-toolchain.sh"
spl_export_go_path
MOD="$HERE/../go/spool-hub-api"
OUT="${1:-$MOD/bin/spool}"

VERSION="$(cat "$HERE/../../../.version" 2>/dev/null || echo 0.1.0-dev)"
# GET /version reports commit + built_at (003 T037); overridable for reproducible builds.
COMMIT="${SPOOL_BUILD_COMMIT:-$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)}"
BUILT_AT="${SPOOL_BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
mkdir -p "$(dirname "$OUT")"
( cd "$MOD" && go build -ldflags "-X main.version=$VERSION -X main.commit=$COMMIT -X main.builtAt=$BUILT_AT" -o "$OUT" ./cmd/spool )
echo "built $OUT ($VERSION, $COMMIT, $BUILT_AT)"
