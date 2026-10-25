#!/usr/bin/env bash
# Static grep of the partner solution label. No partner API call.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
MOD="$ROOT/csi-spl-iac/src/terraform/marketplace-spool-vm"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

check_labels() {
  local ver varf
  ver="$1"
  varf="$2"
  if ! grep -qE '^[[:space:]]*"?goog-partner-solution"?[[:space:]]*=' "$ver"; then
    printf 'FAIL missing goog-partner-solution key\n' >&2
    return 1
  fi
  if ! grep -qF 'var.partner_solution_urn' "$ver"; then
    printf 'FAIL missing var.partner_solution_urn\n' >&2
    return 1
  fi
  if ! grep -qE 'default[[:space:]]*=[[:space:]]*"SOLUTION_URN"' "$varf"; then
    printf 'FAIL missing SOLUTION_URN default\n' >&2
    return 1
  fi
  return 0
}

if check_labels "$MOD/versions.tf" "$MOD/variables.tf"; then
  pass "partner solution label is a variable default"
else
  fail "real versions.tf"
fi

grep -v 'goog-partner-solution' "$MOD/versions.tf" >"$T/versions.tf" || true
cp "$MOD/variables.tf" "$T/variables.tf"
if check_labels "$T/versions.tf" "$T/variables.tf"; then
  fail "RED stripped key should fail"
else
  pass "RED stripped goog-partner-solution key"
fi

[[ "$fails" -eq 0 ]] && printf 'PASS: all %s assertions\n' "$(basename "$0")"
exit "$fails"
