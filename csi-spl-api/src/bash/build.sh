#!/usr/bin/env bash
# Build the spool binary (spec 002). Offline-friendly: uses the module cache.
# Usage: bash csi-spl-api/src/bash/build.sh [output-path]
set -euo pipefail

# The caller's proxy settings, for the warm-up below only (unset stays unset).
CALLER_GOPROXY="${GOPROXY-__unset__}" CALLER_GOSUMDB="${GOSUMDB-__unset__}"
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=use-go-toolchain.sh
source "$HERE/use-go-toolchain.sh"
spl_export_go_path
MOD="$HERE/../go/spool-hub-api"
OUT="${1:-$MOD/bin/spool}"

# SPL-1866: after a go.mod / go.sum bump, the box that did not build it has a
# cache without the new modules, and the offline build below failed with
# "module lookup disabled by GOPROXY=off" (sat 2026-10-13, the PC 2026-10-14
# on a spawn). So warm THIS user's module cache first. A warm cache costs one
# offline `go mod download` (~20 ms, n=3) and no network; only a cache that
# lacks a module goes online, with the caller's GOPROXY / GOSUMDB (go's
# defaults when unset). The build itself stays GOPROXY=off.
# shellcheck source=warm-go-mod-cache.sh
source "$HERE/warm-go-mod-cache.sh"
if ! (
  if [ "$CALLER_GOPROXY" = __unset__ ]; then unset GOPROXY; else GOPROXY="$CALLER_GOPROXY"; fi
  if [ "$CALLER_GOSUMDB" = __unset__ ]; then unset GOSUMDB; else GOSUMDB="$CALLER_GOSUMDB"; fi
  spl_warm_go_mod_cache "$MOD"
) >&2; then
  sum="$(sha256sum "$MOD/go.sum" 2>/dev/null | cut -c1-12)"
  chg="$(git -C "$MOD" log -1 --format=%h -- go.sum 2>/dev/null)"
  echo "FATAL build.sh: box ${BOX_TAG:-$(hostname -s)} user $(id -un): the go module cache ($(go env GOMODCACHE)) lacks modules of go.sum ${sum:-?} (last changed in ${chg:-an uncommitted edit}) and the warm-up could not download them (GOPROXY=${CALLER_GOPROXY/__unset__/<go default>}); give this box the network once and rerun, the build itself stays offline" >&2
  exit 1
fi

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
