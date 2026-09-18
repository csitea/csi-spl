#!/usr/bin/env bash
# next-agent-id.sh: allocation floor, claim semantics, identity-routing §2 ids.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
NAI="$T_SCRIPTS/next-agent-id.sh"

eq "empty root -> CLE-01" CLE-01 "$(bash "$NAI" --kind claude)"
check "claim created inbox/outbox/archive" test -d "$SPOOL_ROOT/CLE-01/inbox" -a -d "$SPOOL_ROOT/CLE-01/outbox" -a -d "$SPOOL_ROOT/CLE-01/archive"
eq "next claim -> CLE-02" CLE-02 "$(bash "$NAI" --kind claude)"
eq "kinds are independent -> GRK-01" GRK-01 "$(bash "$NAI" --kind grok)"
eq "--prefix AGY -> AGY-01" AGY-01 "$(bash "$NAI" --prefix agy)"

mkdir -p "$SPOOL_ROOT/CLE-07"
eq "an existing dir raises the floor" CLE-08 "$(bash "$NAI" --kind claude)"

printf 'CLE-20\tclaude\t%%9\t/x\t20260101T000000Z\nXCLE-99\tclaude\t\t/CLE-99\t20260101T000000Z\n' > "$SPOOL_ROOT/registry.tsv"
eq "registry column 1 raises the floor, other columns do not" CLE-21 "$(bash "$NAI" --kind claude)"

eq "--no-reserve computes" CLE-22 "$(bash "$NAI" --kind claude --no-reserve)"
check "--no-reserve claims nothing" test ! -e "$SPOOL_ROOT/CLE-22"

t_tmux
t_window "tg: CLE-40 > busy" 'sleep 600' >/dev/null
eq "a live (tagged) window raises the floor" CLE-41 "$(bash "$NAI" --kind claude)"

eq "--claim an explicit free id" CLE-4441 "$(bash "$NAI" --claim CLE-4441)"
bash "$NAI" --claim CLE-4441 >/dev/null 2>&1; eq "--claim a taken id exits 3" 3 "$?"
bash "$NAI" --claim BOX-1 >/dev/null 2>&1;    eq "BOX is a forbidden prefix (exit 2)" 2 "$?"
bash "$NAI" --claim cle-1 >/dev/null 2>&1;    eq "lower-case id refused (exit 2)" 2 "$?"
bash "$NAI" --claim AGY-01.1 >/dev/null 2>&1; eq "dotted sub-id refused (exit 2)" 2 "$?"
bash "$NAI" --claim ABCDE-1 >/dev/null 2>&1;  eq "5-letter prefix refused (exit 2)" 2 "$?"
bash "$NAI" --kind hum >/dev/null 2>&1;       eq "unknown kind refused (exit 2)" 2 "$?"

# Two claims racing for the same explicit id: exactly one wins.
( bash "$NAI" --claim GRK-500 >/dev/null 2>&1; echo $? > "$T_TMP/r1" ) &
( bash "$NAI" --claim GRK-500 >/dev/null 2>&1; echo $? > "$T_TMP/r2" ) &
wait
eq "racing claims: one 0 and one 3" "0 3" "$(sort -n "$T_TMP/r1" "$T_TMP/r2" | tr '\n' ' ' | sed 's/ $//')"

t_done
