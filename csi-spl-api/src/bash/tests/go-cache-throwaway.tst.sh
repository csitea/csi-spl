#!/usr/bin/env bash
# A script that points GOMODCACHE at a throwaway dir also gives go a throwaway
# GOCACHE (SPL-3119). Without -trimpath every compile action id holds the
# package dir, so builds from a fresh $T/mod write new third-party entries
# into the user's shared build cache on every run: build-warm-mod-cache.tst.sh
# added 575089594 bytes per run (n=2), none reusable, while the */5 prune may
# trim only entries idle for 180 min.
#   1. every csi-spl-*/src/bash script that sets GOMODCACHE=$<var> also sets
#      GOCACHE= (listed by path when not)
#   2. CONTROL: a script with only GOMODCACHE="$T/mod" is reported
# GO_CACHE_SCAN_ROOT overrides the tree scanned (to show the red on an old one).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${GO_CACHE_SCAN_ROOT:-$(cd "$HERE/../../../.." && pwd)}"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# offenders <dir>...: the .sh files that set GOMODCACHE to a $-path and never set GOCACHE
offenders() {
  grep -rlE --include='*.sh' 'GOMODCACHE="?\$' "$@" 2>/dev/null | while IFS= read -r f; do
    grep -q 'GOCACHE=' "$f" || echo "$f"
  done
}

bad="$(offenders "$ROOT"/csi-spl-*/src/bash)"
if [ -z "$bad" ]; then
  pass "1. every script with a throwaway GOMODCACHE also sets GOCACHE"
else
  fail "1. a throwaway GOMODCACHE with the shared build cache: $(tr '\n' ' ' <<<"$bad")"
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-x/src/bash"
printf '%s\n' 'T=$(mktemp -d)' 'export GOMODCACHE="$T/mod"' >"$T/csi-spl-x/src/bash/shared.sh"
if [ "$(offenders "$T"/csi-spl-*/src/bash)" = "$T/csi-spl-x/src/bash/shared.sh" ]; then
  pass "2. CONTROL: GOMODCACHE=\"\$T/mod\" without GOCACHE is reported"
else
  fail "2. CONTROL: the check misses a throwaway GOMODCACHE without GOCACHE"
fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "ALL go-cache-throwaway checks passed"
