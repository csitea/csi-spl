#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_newest_tenant_key returns the lexically last <dir>/<tenant>.*.json.
#          t1.20260101.json, t1.20260301.json and a neighbour t1x.20270101.json
#          yield the 20260301 file. An empty directory is rc 1. A name that
#          contains a newline comes back whole. The caller's nullglob is
#          restored either way.
#------------------------------------------------------------------------------
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$HERE/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck source=../../../lib/bash/funcs/spl-newest-tenant-key.func.sh
source "$PROJ_ROOT/lib/bash/funcs/spl-newest-tenant-key.func.sh"

mkdir -p "$T/keys" "$T/empty" "$T/odd"
: >"$T/keys/t1.20260101.json"
: >"$T/keys/t1.20260301.json"
: >"$T/keys/t1x.20270101.json"

rc=0
got="$(spl_newest_tenant_key "$T/keys" t1)" || rc=$?
[[ $rc -eq 0 && "$got" == "$T/keys/t1.20260301.json" ]] &&
  pass "t1.20260301.json wins; t1x.20270101.json is not a t1 key" ||
  fail "newest: rc=$rc got=${got:-<empty>}"

rc=0
got="$(spl_newest_tenant_key "$T/empty" t1)" || rc=$?
[[ $rc -eq 1 && -z "$got" ]] && pass "an empty directory is rc 1" ||
  fail "empty: rc=$rc got=${got:-<empty>}"

odd="$T/odd/t1.20260201"$'\n'"x.json"
printf 'b' >"$odd"
: >"$T/odd/t1.20260101.json"
rc=0
got="$(spl_newest_tenant_key "$T/odd" t1)" || rc=$?
[[ $rc -eq 0 && "$got" == "$odd" ]] &&
  pass "a newline inside the newest name is preserved" ||
  fail "newline name: rc=$rc got=$(printf %q "${got:-}")"

shopt -u nullglob
spl_newest_tenant_key "$T/keys" t1 >/dev/null || true
if shopt -q nullglob; then fail "nullglob leaked on"; else pass "nullglob stays off when the caller had it off"; fi
shopt -s nullglob
spl_newest_tenant_key "$T/empty" t1 >/dev/null || true
if shopt -q nullglob; then pass "nullglob stays on when the caller had it on"; else fail "nullglob was cleared"; fi
shopt -u nullglob

[[ $fails -eq 0 ]] && echo "newest-tenant-key.tst.sh: all passed" || echo "newest-tenant-key.tst.sh: $fails failed"
exit $((fails > 0))
