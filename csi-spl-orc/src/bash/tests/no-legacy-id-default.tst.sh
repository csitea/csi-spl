#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no shell default in csi-spl-orc falls back to a retired legacy id
#          (specs/061: CLE-/RSP-/OPS-NN ended 2026-10-03). Such a default is
#          refused by spool-env on every write path: on a fleet box, 2026-10-10, every
#          responder run failed on one (`spool-env: CLE-001 is retired`).
#   1. the orc tree carries no `${X:-CLE-NN}` / `:-RSP-NN` / `:-OPS-NN` default
#   2. control: a planted default of each kind is found
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC="$(cd "$TEST_DIR/../../.." && pwd)"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

RX=':-(CLE|RSP|OPS)-[0-9]+\}'
scan() { grep -rnE --include='*.sh' -- "$RX" "$1"; }  # DIR -> one hit per line

hits="$(scan "$ORC")"
[ -z "$hits" ] && pass "1. no legacy-id default in csi-spl-orc" || fail "1. legacy-id defaults (use c-001 or orchestrator):"$'\n'"$hits"

for k in CLE-00 RSP-01 OPS-001; do
  mkdir -p "$T/$k"
  printf 'x="${SPOOL_ORCHESTRATOR_ID:-%s}"\n' "$k" >"$T/$k/plant.func.sh"
  [ -n "$(scan "$T/$k")" ] && pass "2. control: a planted :-$k default is found" || fail "2. control: :-$k not found"
done

[[ $fails -eq 0 ]] && echo "OK no-legacy-id-default: $n passed" || { echo "FAILED no-legacy-id-default: $fails of $n"; exit 1; }
