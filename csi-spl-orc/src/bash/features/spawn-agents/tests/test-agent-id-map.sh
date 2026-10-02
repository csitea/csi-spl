#!/usr/bin/env bash
# agent-id-map.sh (specs/061 §5, T060) and agent-id-legacy-report.sh (FR-013):
# the table is written once, roles first, then the live legacy agents oldest
# spawn first on the machine's next numbers; dead and skipped ids get no row.
# A private tmux server; the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
MAP="$T_SCRIPTS/agent-id-map.sh"
REP="$T_SCRIPTS/agent-id-legacy-report.sh"
export SPOOL_DESK_BOX=box-t SPOOL_NOW=2026-10-02T12:00:00Z
R="$SPOOL_ROOT"
t_tmux

# Fixture: four legacy agents with windows; CLE-50 has a dead record, GRK-9 is
# skipped; a role window and a dead id with only a dir.
mkdir -p "$R/agents" "$R/CLE-001" "$R/CLE-77" "$R/GRK-9" "$R/AGY-12" "$R/CLE-50" "$R/CLE-31"
for i in CLE-77 GRK-9 AGY-12 CLE-001; do printf '{"id":"%s","alive":true}\n' "$i" >"$R/agents/$i.json"; done
printf '{"id":"CLE-50","alive":false}\n' >"$R/agents/CLE-50.json"
printf 'CLE-77\tclaude\t%%1\t/x\t20261001T090000Z\nAGY-12\tagy\t%%2\t/y\t20261001T080000Z\nGRK-9\tgrok\t%%3\t/z\t20261001T070000Z\n' >"$R/registry.tsv"
printf '004\n' >"$R/agent-id.cursor"; mkdir -p "$R/c-005"
t_window 'CLE-001 orch' 'sleep 600' >/dev/null
t_window 'CLE-77 > lane' 'sleep 600' >/dev/null
t_window 'AGY-12 lane' 'sleep 600' >/dev/null
t_window 'GRK-9 busy' 'sleep 600' >/dev/null
t_window 'CLE-50 ghost' 'sleep 600' >/dev/null

# --- the dry run --------------------------------------------------------------
out="$(bash "$MAP" --skip GRK-9 2>&1)"; eq "the dry run exits 0" 0 "$?"
has "roles come first" "CLE-001	c-001	claude	box-t	2026-10-02T12:00:00Z" "$out"
has "the oldest live spawn gets the cursor's next free number (005 is held)" "AGY-12	a-006	agy	box-t" "$out"
has "...the next one the number after it, same counter for every kind" "CLE-77	c-007	claude	box-t" "$out"
hasnt "a skipped lane gets no row" "GRK-9	" "$out"
has "...and says so" "SKIP     GRK-9: --skip" "$out"
hasnt "a dead record gets no row" "CLE-50	" "$out"
hasnt "a dir with no window gets no row" "CLE-31	" "$out"
check "the dry run writes no table" test ! -e "$R/agent-id-aliases.tsv"
check "...and claims no number" test ! -e "$R/a-006" -a ! -e "$R/c-007"
eq "...and leaves the cursor" 004 "$(cat "$R/agent-id.cursor")"

# --- apply ---------------------------------------------------------------------
out="$(bash "$MAP" --apply --skip GRK-9 2>&1)"; eq "--apply exits 0" 0 "$?"
eq "the table has 3 roles + 2 agents" 5 "$(grep -c . "$R/agent-id-aliases.tsv")"
eq "rows are old new kind box mapped-utc" "AGY-12	a-006	agy	box-t	2026-10-02T12:00:00Z" "$(sed -n 4p "$R/agent-id-aliases.tsv")"
check "each new number is claimed (its spool dir exists)" test -d "$R/a-006/inbox" -a -d "$R/c-007/inbox"
eq "the cursor moved past them" 007 "$(cat "$R/agent-id.cursor")"
. "$T_FEAT/lib/spool-env.inc.sh"
eq "spl_agent_id_resolve reads the table" c-007 "$(spl_agent_id_resolve CLE-77)"
eq "...by box too" a-006 "$(spl_agent_id_resolve AGY-12@box-t)"

# --- written once ----------------------------------------------------------------
before="$(cat "$R/agent-id-aliases.tsv")"
out="$(bash "$MAP" --apply 2>&1)"; eq "a second --apply exits 0" 0 "$?"
has "...says the table is written once" "is written once" "$out"
eq "...and changes nothing (GRK-9 still has no row)" "$before" "$(cat "$R/agent-id-aliases.tsv")"
check "...and claims nothing more" test ! -e "$R/g-008"

# --- the legacy report -------------------------------------------------------------
out="$(bash "$REP" 2>&1)"; eq "the report exits 0" 0 "$?"
has "windows: 5 legacy ids, 1 role" "LEGACY windows    5 roles 1 AGY-12 CLE-001 CLE-50 CLE-77 GRK-9" "$out"
has "spool dirs: 6, the role apart" "LEGACY spool_dirs 6 roles 1 AGY-12 CLE-001 CLE-31 CLE-50 CLE-77 GRK-9" "$out"
has "live dirs = dirs a window carries" "LEGACY live_dirs  5 roles 1 AGY-12 CLE-001 CLE-50 CLE-77 GRK-9" "$out"
has "registry rows" "LEGACY registry   3 AGY-12 CLE-77 GRK-9" "$out"
has "alive records only" "LEGACY records    4 roles 1 AGY-12 CLE-001 CLE-77 GRK-9" "$out"
rm -rf "$R/CLE-77"; ln -s c-007 "$R/CLE-77"
has "a rename's old -> new link is not a legacy dir" "LEGACY spool_dirs 5 roles 1 AGY-12 CLE-001 CLE-31 CLE-50 GRK-9" "$(bash "$REP" 2>&1)"

# --- a box with no identity map at all: the window alone decides -----------------
R2="$T_TMP/spool2"; mkdir -p "$R2/CLE-100004@sat"
out="$(SPOOL_ROOT="$R2" bash "$MAP" 2>&1)"; eq "with no agents/ dir the dry run exits 0" 0 "$?"
has "...warns that windows decide" "no identity map" "$out"
has "...and maps a live window's agent" "CLE-77	c-" "$out"

t_done
