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

# The release version is minted by CI at deploy time (do_release_version) and
# handed in as SPOOL_BUILD_VERSION; .version (the floor) is the local default.
VERSION="${SPOOL_BUILD_VERSION:-$(cat "$HERE/../../../.version" 2>/dev/null || echo 0.1.0-dev)}"
# GET /version reports commit + built_at (003 T037); overridable for reproducible builds.
COMMIT="${SPOOL_BUILD_COMMIT:-$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)}"
BUILT_AT="${SPOOL_BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
mkdir -p "$(dirname "$OUT")"
# -s -w drop the symbol table and DWARF: 60.8 MB -> 42.2 MB (CLE-35076), a
# smaller hub image to pull on every cold start and deploy. Panics still print
# function names and lines (pclntab). NOT -trimpath: it keeps -ldflags out of
# the build info, where spl_host_spool_bin_rev reads main.commit to decide
# whether a host binary is current.
( cd "$MOD" && go build -ldflags "-s -w -X main.version=$VERSION -X main.commit=$COMMIT -X main.builtAt=$BUILT_AT" -o "$OUT" ./cmd/spool )
echo "built $OUT ($VERSION, $COMMIT, $BUILT_AT)"
