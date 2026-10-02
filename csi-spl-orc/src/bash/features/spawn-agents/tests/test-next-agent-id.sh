#!/usr/bin/env bash
# next-agent-id.sh: specs/061 §3.5 allocation - the per-machine cursor over
# 004-999, rollover, the 5 skip rules, the quarantine, a full line, races;
# plus the claim semantics and the qualified layout of specs/058 6.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
NAI="$T_SCRIPTS/next-agent-id.sh"
# A fresh spool root per case.
r() { export SPOOL_ROOT="$T_TMP/$1"; mkdir -p "$SPOOL_ROOT"; }

r a
eq "empty root -> c-004 (001-003 are the role ids)" c-004 "$(bash "$NAI" --kind claude)"
check "claim created inbox/outbox/archive" test -d "$SPOOL_ROOT/c-004/inbox" -a -d "$SPOOL_ROOT/c-004/outbox" -a -d "$SPOOL_ROOT/c-004/archive"
eq "the cursor holds the last number" 004 "$(cat "$SPOOL_ROOT/agent-id.cursor")"
eq "next claim -> c-005" c-005 "$(bash "$NAI" --kind claude)"
eq "Q2 one counter per machine: grok gets the next number" g-006 "$(bash "$NAI" --kind grok)"
eq "--prefix a -> a-007" a-007 "$(bash "$NAI" --prefix a)"
eq "--prefix QWN (legacy spelling) -> q-008" q-008 "$(bash "$NAI" --prefix QWN)"
eq "--no-reserve computes c-009" c-009 "$(bash "$NAI" --kind claude --no-reserve)"
check "...claims nothing" test ! -e "$SPOOL_ROOT/c-009"
eq "...and leaves the cursor" 008 "$(cat "$SPOOL_ROOT/agent-id.cursor")"

# The cursor, not a floor: a low number freed below it is not reused before
# the line wraps.
rm -rf "$SPOOL_ROOT/c-005"
eq "a freed number below the cursor waits for the wrap" c-009 "$(bash "$NAI" --kind claude)"

# Rollover 999 -> 004 (004 is free again, 005 is held).
r roll
printf '998\n' >"$SPOOL_ROOT/agent-id.cursor"
eq "999 is handed out" c-999 "$(bash "$NAI" --kind claude)"
mkdir "$SPOOL_ROOT/q-005"
eq "rollover 999 -> 004" c-004 "$(bash "$NAI" --kind claude)"
eq "...then past a held 005 (any kind holds the number)" c-006 "$(bash "$NAI" --kind claude)"
printf 'garbage\n' >"$SPOOL_ROOT/agent-id.cursor"
eq "an unreadable cursor restarts at the bottom of the line" c-007 "$(bash "$NAI" --kind claude)"

# The 5 skip rules, one candidate each (004..008 held, 009 free).
r skip
mkdir -p "$SPOOL_ROOT/agents" "$SPOOL_ROOT/c-004"
printf 'g-005\tgrok\t%%9\t/x\t20261001T000000Z\n' >"$SPOOL_ROOT/registry.tsv"
printf '{}\n' >"$SPOOL_ROOT/agents/a-006.json"
t_tmux
t_window "tg: c-007 > busy" 'sleep 600' >/dev/null
printf 'q-008\tqwen\t%%1\t/x\t20261001T000000Z\t20261002T020000Z\n' >"$SPOOL_ROOT/registry.retired.tsv"
out="$(SPOOL_NOW=2026-10-02T12:00:00Z bash "$NAI" --kind claude --no-reserve --explain 2>&1 >/dev/null)"
has "rule 1 spool dir" "skip c-004: rule 1:spool-dir c-004" "$out"
has "rule 2 registry row" "skip c-005: rule 2:registry g-005" "$out"
has "rule 3 identity record" "skip c-006: rule 3:identity a-006" "$out"
has "rule 4 live (tagged) window" "skip c-007: rule 4:window c-007" "$out"
has "rule 5 quarantine (retired 10 h ago)" "skip c-008: rule 5:quarantine q-008" "$out"
eq "all 5 skipped -> c-009" c-009 "$(SPOOL_NOW=2026-10-02T12:00:00Z bash "$NAI" --kind claude --no-reserve)"
eq "past the 24 h quarantine the number is free again" c-008 "$(SPOOL_NOW=2026-10-03T03:00:00Z bash "$NAI" --kind claude --no-reserve)"
eq "SPOOL_ID_QUARANTINE_H shortens it" c-008 "$(SPOOL_NOW=2026-10-02T12:00:00Z SPOOL_ID_QUARANTINE_H=6 bash "$NAI" --kind claude --no-reserve)"
tmux -S "$SPOOL_TMUX_SOCKET" kill-server 2>/dev/null
eq "a qualified dir holds its number" c-005 "$(r q1; mkdir "$SPOOL_ROOT/a-004@sat"; bash "$NAI" --kind claude)"
eq "a registry row qualified <ID>@<box> holds it too" c-005 "$(r q2; printf 'c-004@sat\tclaude\t\t/x\t20261001T000000Z\n' >"$SPOOL_ROOT/registry.tsv"; bash "$NAI" --kind claude)"
eq "legacy ids never hold a new number" c-004 "$(r q3; mkdir "$SPOOL_ROOT/CLE-004" "$SPOOL_ROOT/CLE-77974"; bash "$NAI" --kind claude)"
eq "a box spawner's own registry (--also-registry)" c-006 "$(r q4; mkdir -p "$T_TMP/reg/c-004"; printf 'g-005\tgrok\n' >"$T_TMP/reg/registry.tsv"; bash "$NAI" --kind claude --also-registry "$T_TMP/reg")"

# A full line: every number held -> exit 1, nothing claimed.
r full
for i in $(seq 4 999); do printf 'c-%03d\tclaude\t\t/x\t20261001T000000Z\n' "$i"; done >"$SPOOL_ROOT/registry.tsv"
bash "$NAI" --kind grok >/dev/null 2>&1; eq "a full line exits 1" 1 "$?"
check "...and claimed nothing" test -z "$(find "$SPOOL_ROOT" -mindepth 1 -maxdepth 1 -type d)"
sed -i '/^c-517\t/d' "$SPOOL_ROOT/registry.tsv"
eq "one free number in a full line is found" g-517 "$(bash "$NAI" --kind grok)"

# The owner switches (Q1, Q2) are one variable each.
r sw
eq "Q2 per kind: each kind starts at 004" "c-004 g-004" "$(SPOOL_ID_COUNTER=kind bash "$NAI" --kind claude) $(SPOOL_ID_COUNTER=kind bash "$NAI" --kind grok)"
check "...with its own cursor" test -s "$SPOOL_ROOT/agent-id.g.cursor"
eq "Q1 only c- keeps 001-003: a- starts at 001" a-001 "$(SPOOL_ROOT="$T_TMP/sw1" SPOOL_ID_ROLE_LETTERS=c bash "$NAI" --kind agy)"
SPOOL_ID_COUNTER=bogus bash "$NAI" --kind claude >/dev/null 2>&1; eq "a bad counter switch is refused (exit 2)" 2 "$?"
eq "a stale band in the env is ignored" c-004 "$(SPOOL_ROOT="$T_TMP/sw2" SPOOL_AGENT_ID_RANGE=100000-199999 bash "$NAI" --kind claude)"

# Races: 12 concurrent allocations, 12 distinct ids, no gap, no double claim.
r race
for i in $(seq 1 12); do ( bash "$NAI" --kind claude >"$T_TMP/race.$i" 2>"$T_TMP/race-err.$i" ) & done
wait
eq "12 racing spawns get 12 distinct ids" 12 "$(cat "$T_TMP"/race.* | sort -u | grep -cE '^c-[0-9]{3}$')"
eq "...004..015 with no gap" "c-004 c-015" "$(cat "$T_TMP"/race.* | sort | sed -n '1p;$p' | tr '\n' ' ' | sed 's/ $//')"

# Explicit claims.
r cl
eq "--claim an explicit free id" c-041 "$(bash "$NAI" --claim c-041)"
bash "$NAI" --claim c-041 >/dev/null 2>&1;   eq "--claim a taken id exits 3" 3 "$?"
eq "a role id is claimable explicitly" c-002 "$(bash "$NAI" --claim c-002)"
eq "...and never handed out" c-004 "$(bash "$NAI" --kind claude)"
eq "--claim a legacy id still works until the cutoff" CLE-4441 "$(bash "$NAI" --claim CLE-4441)"
bash "$NAI" --claim BOX-1 >/dev/null 2>&1;   eq "BOX is a forbidden prefix (exit 2)" 2 "$?"
bash "$NAI" --claim c-4 >/dev/null 2>&1;     eq "an unpadded id refused (exit 2)" 2 "$?"
bash "$NAI" --claim x-004 >/dev/null 2>&1;   eq "an unknown letter refused (exit 2)" 2 "$?"
bash "$NAI" --claim AGY-01.1 >/dev/null 2>&1; eq "dotted sub-id refused (exit 2)" 2 "$?"
bash "$NAI" --kind hum >/dev/null 2>&1;      eq "unknown kind refused (exit 2)" 2 "$?"
( bash "$NAI" --claim g-500 >/dev/null 2>&1; echo $? > "$T_TMP/r1" ) &
( bash "$NAI" --claim g-500 >/dev/null 2>&1; echo $? > "$T_TMP/r2" ) &
wait
eq "racing claims: one 0 and one 3" "0 3" "$(sort -n "$T_TMP/r1" "$T_TMP/r2" | tr '\n' ' ' | sed 's/ $//')"

# specs/058 6: the qualified mailbox layout. A claim is the dir <ID>@<box> plus
# the compat link <ID>; an id held in either shape (or by a half-migrated
# self-loop link) is taken.
r q
eq "qualified: claim -> a-004" a-004 "$(SPOOL_DIR_LAYOUT=qualified SPOOL_DESK_BOX=sat bash "$NAI" --kind agy)"
check "...the dir is a-004@sat with inbox/outbox/archive" test -d "$SPOOL_ROOT/a-004@sat/inbox" -a -d "$SPOOL_ROOT/a-004@sat/outbox" -a -d "$SPOOL_ROOT/a-004@sat/archive" -a ! -L "$SPOOL_ROOT/a-004@sat"
eq "...and a-004 is the compat link to it" "a-004@sat" "$(readlink "$SPOOL_ROOT/a-004")"
mkdir -p "$SPOOL_ROOT/a-030@hom"
SPOOL_DIR_LAYOUT=qualified SPOOL_DESK_BOX=sat bash "$NAI" --claim a-030 >/dev/null 2>&1
eq "a claim of an id held as <ID>@<other box> exits 3" 3 "$?"
bash "$NAI" --claim a-030 >/dev/null 2>&1
eq "...in the bare layout too" 3 "$?"
ln -s a-040@sat "$SPOOL_ROOT/a-040@sat"
SPOOL_DIR_LAYOUT=qualified SPOOL_DESK_BOX=sat bash "$NAI" --claim a-040 >/dev/null 2>&1
eq "a half-migrated self-loop owns its id" 3 "$?"
SPOOL_DIR_LAYOUT=qualified SPOOL_DESK_BOX=Bad_Box bash "$NAI" --kind agy >/dev/null 2>&1
eq "qualified with no valid box refused (exit 2)" 2 "$?"
printf 'SPOOL_DIR_LAYOUT=qualified\nSPOOL_DESK_BOX=sat\n' >"$T_TMP/q.env"
eq "the layout is read from box.env" a-005 "$(SPOOL_BOX_ENV="$T_TMP/q.env" bash "$NAI" --kind agy)"
check "...as <ID>@<box>" test -d "$SPOOL_ROOT/a-005@sat" -a -L "$SPOOL_ROOT/a-005"

# The box user defaults to the owner of the spool root, not $SUDO_USER.
got="$(env -u SPOOL_BOX_USER SUDO_USER=nobody bash -c '. "$1/lib/spool-env.inc.sh"; spool_env_resolve; printf %s "$SPOOL_BOX_USER"' _ "$T_FEAT")"
eq "SPOOL_BOX_USER defaults to the spool root's owner" "$(stat -c %U "$SPOOL_ROOT")" "$got"

t_done
