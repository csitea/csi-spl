#!/usr/bin/env bash
# spl_export_go_path picks the newest toolchain under a root.
# A missing toolchain is a failure rather than a quiet empty PATH.
# CONTROLS: a planted newer sibling wins; with the sibling removed the older
# one wins; a root with no go returns 1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fake() { # <dir> <version>
  mkdir -p "$1/bin"
  printf '#!/bin/sh\nif [ "$1" = env ] && [ "$2" = GOVERSION ]; then echo "%s"; exit 0; fi\nexit 1\n' "$2" >"$1/bin/go"
  chmod +x "$1/bin/go"
}

fake "$T/go" go1.25.1
fake "$T/go1.25.14" go1.25.14

old_path=$PATH
spl_export_go_path "$T" || { echo "FAIL: selector returned non-zero on a root that has go"; exit 1; }
first=${PATH%%:*}
[[ "$first" == "$T/go1.25.14/bin" ]] && pass "a newer sibling toolchain wins" \
  || fail "wanted the 1.25.14 sibling first, got $first"
PATH=$old_path

rm -rf "$T/go1.25.14"
if spl_export_go_path "$T"; then
  first=${PATH%%:*}
  [[ "$first" == "$T/go/bin" ]] && pass "with no sibling, the default tree wins" \
    || fail "wanted the default tree first, got $first"
else
  fail "selector failed when only the default tree exists"
fi
PATH=$old_path

empty=$(mktemp -d)
# a GitHub-hosted runner: no toolchain under the root, but setup-go put a go
# on PATH - accepted, and PATH is left as it was (run 36177121067 died here)
fake "$T/onpath" go1.25.0
PATH="$T/onpath/bin:$old_path"
before=$PATH
if spl_export_go_path "$empty" && [[ "$PATH" == "$before" ]]; then
  pass "no toolchain under the root: the go on PATH is kept"
else
  fail "no toolchain under the root but go on PATH: refused, or PATH changed"
fi
PATH=$old_path
# CONTROL: nothing under the root AND no go on PATH -> refused
if PATH="$empty" spl_export_go_path "$empty"; then
  fail "CONTROL: an empty root with no go on PATH was accepted"
else
  pass "CONTROL: a root with no go and no go on PATH is refused"
fi
rm -rf "$empty"

[[ "$fails" -eq 0 ]]
