#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no private key MATERIAL is tracked anywhere in the repo (owner
#          direction 2026-09-19: the project SA keys live in ~/.gcp/.<org>/
#          only). A bare `git grep private_key` cannot be 0 -- docs, this
#          suite and the tenant JSON field root_private_key name it -- so this
#          looks for the two shapes real key material has: a PEM private-key
#          header, and a GCP SA key's private_key JSON field with a value.
#          CONTROL: a planted file of each shape in a scratch repo is found.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

PEM='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
SAKEY='"private_key"[[:space:]]*:[[:space:]]*"'
# material <repo> -> tracked files holding either shape (the patterns are
# assembled here, so this file itself never matches)
material() { git -C "$1" grep -lE -e "$PEM" -e "$SAKEY" 2>/dev/null || true; }

n=$(git -C "$APP_ROOT" ls-files | wc -l)
[[ "$n" -gt 100 ]] && pass "scanning $n tracked files" || fail "only $n tracked files under $APP_ROOT"
hits=$(material "$APP_ROOT")
[[ -z "$hits" ]] && pass "no PEM private key and no SA-key private_key field in the tree" || fail "key material tracked in: $hits"

# --- control -------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
printf '{"type":"service_account","%s": "x"}\n' "private_key" >"$T/sa.json"
printf -- '-----BEGIN %s-----\nx\n' "PRIVATE KEY" >"$T/k.pem"
printf 'root_private_key is a field name\n' >"$T/doc.md"
git -C "$T" add -A
c=$(material "$T" | sort | tr '\n' ' ')
[[ "$c" == "k.pem sa.json " ]] && pass "control: both planted shapes found, a field-name mention is not" || fail "control found: '$c'"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
