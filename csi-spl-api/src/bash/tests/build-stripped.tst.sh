#!/usr/bin/env bash
# build.sh ships a stripped spool (CLE-35076): -s -w and main.commit in its
# build info (spl_host_spool_bin_rev reads the commit there, so -trimpath,
# which drops -ldflags from it, must never come back), still the injected
# version, and smaller than an unstripped build of the same tree (the CONTROL).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

SPOOL_BUILD_VERSION=9.8.7 SPOOL_BUILD_COMMIT=0123abcd CGO_ENABLED=0 bash "$HERE/../build.sh" "$T/spool" >/dev/null
info=$(go version -m "$T/spool")
grep -qE -- '-ldflags=.*-s -w ' <<<"$info" && pass "build info: -ldflags -s -w" || fail "build info lacks -ldflags -s -w"
grep -q 'main.commit=0123abcd' <<<"$info" && pass "build info keeps main.commit (host spool verdict)" || fail "build info lost main.commit"
grep -q -- '-trimpath=true' <<<"$info" && fail "-trimpath is back: it hides main.commit" || pass "no -trimpath"
"$T/spool" version 2>&1 | grep '9.8.7' >/dev/null && pass "spool version still reports the injected version" || fail "spool version lost the injected version"

( cd "$HERE/../../go/spool-hub-api" && CGO_ENABLED=0 go build -o "$T/spool.full" ./cmd/spool )
s=$(stat -c %s "$T/spool"); f=$(stat -c %s "$T/spool.full")
(( s < f * 8 / 10 )) && pass "stripped $s B < 80% of unstripped $f B" || fail "stripped $s B is not < 80% of unstripped $f B"

[[ $fails -eq 0 ]] && echo "PASS: all build-stripped.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
