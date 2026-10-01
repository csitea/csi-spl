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
eq "--kind qwen -> QWN-01 (specs/048)" QWN-01 "$(bash "$NAI" --kind qwen)"
eq "--prefix QWN -> QWN-02" QWN-02 "$(bash "$NAI" --prefix qwn)"

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

# specs/058: two machines, two spool roots that never see each other. With no
# band both start from the same empty floor and hand out the SAME id (the
# one-machine assumption, kept as the control); with disjoint bands they can't.
M1="$T_TMP/m1" M2="$T_TMP/m2"
eq "control: no band, machine 1 -> QWN-01" QWN-01 "$(SPOOL_ROOT="$M1" bash "$NAI" --kind qwen)"
eq "control: no band, machine 2 -> QWN-01 too (collision)" QWN-01 "$(SPOOL_ROOT="$M2" bash "$NAI" --kind qwen)"
rm -rf "$M1" "$M2"
ids1="" ids2=""
for _ in 1 2 3; do
  ids1+="$(SPOOL_ROOT="$M1" SPOOL_AGENT_ID_RANGE=1-99999 bash "$NAI" --kind qwen) "
  ids2+="$(SPOOL_ROOT="$M2" SPOOL_AGENT_ID_RANGE=100000-199999 bash "$NAI" --kind qwen) "
done
eq "band 1-99999 allocates from the bottom" "QWN-01 QWN-02 QWN-03 " "$ids1"
eq "band 100000-199999 starts at its own floor" "QWN-100000 QWN-100001 QWN-100002 " "$ids2"
eq "two machines with bands: no id in common" "" "$(comm -12 <(tr ' ' '\n' <<<"$ids1" | sort -u | grep .) <(tr ' ' '\n' <<<"$ids2" | sort -u | grep .))"
mkdir -p "$M2/QWN-77913"
eq "an id below the band does not raise the floor" QWN-100003 "$(SPOOL_ROOT="$M2" SPOOL_AGENT_ID_RANGE=100000-199999 bash "$NAI" --kind qwen)"
printf 'QWN-150000\tqwen\t\t/x\t20261001T000000Z\n' >"$M2/registry.tsv"
eq "an id inside the band does" QWN-150001 "$(SPOOL_ROOT="$M2" SPOOL_AGENT_ID_RANGE=100000-199999 bash "$NAI" --kind qwen)"
SPOOL_ROOT="$T_TMP/m3" SPOOL_AGENT_ID_RANGE=5-6 bash "$NAI" --kind qwen >/dev/null
SPOOL_ROOT="$T_TMP/m3" SPOOL_AGENT_ID_RANGE=5-6 bash "$NAI" --kind qwen >/dev/null
SPOOL_ROOT="$T_TMP/m3" SPOOL_AGENT_ID_RANGE=5-6 bash "$NAI" --kind qwen >/dev/null 2>&1
eq "a full band exits 1, never spills over" 1 "$?"
check "...and claimed nothing past it" test ! -e "$T_TMP/m3/QWN-07"
SPOOL_AGENT_ID_RANGE=9-3 bash "$NAI" --kind qwen >/dev/null 2>&1; eq "lo > hi refused (exit 2)" 2 "$?"
SPOOL_AGENT_ID_RANGE=abc bash "$NAI" --kind qwen >/dev/null 2>&1; eq "malformed band refused (exit 2)" 2 "$?"
err="$(SPOOL_ROOT="$M2" SPOOL_AGENT_ID_RANGE=100000-199999 bash "$NAI" --claim CLE-101 2>&1 >/dev/null)"
eq "an explicit claim outside the band still claims" 0 "$?"
has "...and warns" "outside this machine's band" "$err"
printf 'SPOOL_AGENT_ID_RANGE=200000-299999\n' >"$T_TMP/m4.env"
eq "the band is read from box.env" QWN-200000 "$(SPOOL_ROOT="$T_TMP/m4" SPOOL_BOX_ENV="$T_TMP/m4.env" bash "$NAI" --kind qwen)"

# The box user defaults to the owner of the spool root, not $SUDO_USER.
got="$(env -u SPOOL_BOX_USER SUDO_USER=nobody bash -c '. "$1/lib/spool-env.inc.sh"; spool_env_resolve; printf %s "$SPOOL_BOX_USER"' _ "$T_FEAT")"
eq "SPOOL_BOX_USER defaults to the spool root's owner" "$(stat -c %U "$SPOOL_ROOT")" "$got"

t_done
