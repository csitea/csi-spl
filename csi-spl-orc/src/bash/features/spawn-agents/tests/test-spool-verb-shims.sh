#!/usr/bin/env bash
# test-spool-verb-shims.sh — specs/012 FR-006 / T012: the hyphenated
# `spool-<verb>` shims.
#   1. the five verbs get a shim each; a shim runs `spool <verb> <args>`
#   2. idempotent: a second run writes nothing ("same")
#   3. a foreign file of the same name is never overwritten (exit 3)
#   4. --dry-run writes nothing. CONTROL: the real run did write
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
S="$T_SCRIPTS/spool-verb-shims.sh"
B="$T_TMP/bin"; mkdir -p "$T_TMP/fake"
printf '#!/bin/sh\necho "SPOOL $*"\n' >"$T_TMP/fake/spool"; chmod +x "$T_TMP/fake/spool"

# --- 4 first: a dry run writes nothing ------------------------------------------------
bash "$S" --bin "$B" --spool "$T_TMP/fake/spool" --dry-run >/dev/null
check "4. --dry-run writes no shim" test ! -e "$B/spool-send"

# --- 1. the five shims ---------------------------------------------------------------------
out="$(bash "$S" --bin "$B" --spool "$T_TMP/fake/spool")"; rc=$?
eq "1. the run exits 0" 0 "$rc"
for v in put-file get-file send recv tail; do
  check "1. spool-$v exists and is executable" test -x "$B/spool-$v"
done
eq "1. spool-send runs 'spool send <args>'" "SPOOL send --from CLE-1 --body 'a b'" "$("$B/spool-send" --from CLE-1 --body "'a b'")"
eq "1. spool-tail runs 'spool tail'" "SPOOL tail --task x" "$("$B/spool-tail" --task x)"
check "4. CONTROL: the real run wrote the shims" test -s "$B/spool-recv"

# --- 2. idempotent ------------------------------------------------------------------------------
out="$(bash "$S" --bin "$B" --spool "$T_TMP/fake/spool")"
eq "2. a second run rewrites nothing" 5 "$(printf '%s\n' "$out" | grep -c '^same ')"

# --- 3. a foreign file ----------------------------------------------------------------------------
printf '#!/bin/sh\necho mine\n' >"$B/spool-recv"
bash "$S" --bin "$B" --spool "$T_TMP/fake/spool" >/dev/null 2>&1; eq "3. a foreign spool-recv: exit 3" 3 "$?"
eq "3. ... and it is left as it was" "mine" "$("$B/spool-recv")"

t_done
