#!/usr/bin/env bash
# The spool CLI cross-builds for every release target (SPL-2694). Release
# stable-2026-10-19 shipped no binaries: internal/keyd used Linux-only calls,
# so the darwin builds of do_release_cli_assets failed and it uploaded nothing.
# The targets are read from that action's CLI_ASSETS_TARGETS default, so a new
# target is guarded the day it is added there.
# Usage: bash csi-spl-api/src/bash/tests/cli-cross-build.tst.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

MOD="$HERE/../../go/spool-hub-api"
ACTION="$HERE/../../../../csi-spl-orc/src/bash/run/release-cli-assets.func.sh"
targets="$(sed -n 's/.*CLI_ASSETS_TARGETS:-\([^}]*\)}.*/\1/p' "$ACTION")"
[ -n "$targets" ] || { echo "FAIL: no CLI_ASSETS_TARGETS default in $ACTION"; exit 1; }

fails=0
for t in $targets; do
  if out=$(cd "$MOD" && CGO_ENABLED=0 GOOS="${t%/*}" GOARCH="${t#*/}" go build -o /dev/null ./cmd/spool 2>&1); then
    echo "PASS: spool builds for $t"
  else
    echo "FAIL: spool does not build for $t:"; sed 's/^/  /' <<<"$out"; fails=$((fails + 1))
  fi
done
[ "$fails" -eq 0 ] && echo "PASS: all cli-cross-build.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
