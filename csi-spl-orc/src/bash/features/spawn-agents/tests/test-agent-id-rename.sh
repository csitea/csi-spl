#!/usr/bin/env bash
# agent-id-rename.sh (specs/061 FR-011, T061): a live legacy agent takes the
# new id the map gave it - spool dir (+ old -> new link), registry row,
# identity record, tmux window, the desks it is seated on - and the identity
# map then reads its process (whose env still says the old id) as the new id,
# so the per-minute reconcile does not rename the window back.
# A private tmux server and a fake /proc; the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
MAP="$T_SCRIPTS/agent-id-map.sh"
REN="$T_SCRIPTS/agent-id-rename.sh"
export SPOOL_DESK_BOX=box-t SPOOL_NOW=2026-10-02T12:00:00Z DESK_STATE_ROOT="$T_TMP/cloud"
R="$SPOOL_ROOT"
t_tmux

# Fixture: CLE-77 (flat dir, unread mail, registry row, record, seated on the
# dev desk of t1 and the prd desk of t2); AGY-12 in the qualified layout.
mkdir -p "$R/agents" "$R/CLE-77/inbox" "$R/CLE-77/outbox" "$R/CLE-77/archive" "$R/AGY-12@box-t/inbox"
ln -s AGY-12@box-t "$R/AGY-12"
printf '{"v":1}\n' >"$R/CLE-77/inbox/unread.json"
printf '{"id":"CLE-77","alive":true,"pane_id":"%%9","kind":"claude"}\n' >"$R/agents/CLE-77.json"
printf '{"id":"AGY-12","alive":true,"kind":"agy"}\n' >"$R/agents/AGY-12.json"
printf 'CLE-77\tclaude\t%%1\t/x\t20261001T090000Z\nAGY-12@box-t\tagy\t%%2\t/y\t20261001T080000Z\nc-099\tclaude\t%%3\t/z\t20261001T070000Z\n' >"$R/registry.tsv"
D1="$DESK_STATE_ROOT/dev/desk/t1/box-t/spool"; D2="$DESK_STATE_ROOT/prd/desk/t2/box-t/spool"
mkdir -p "$D1/CLE-77/inbox" "$D2/CLE-77/inbox"; : >"$D1/CLE-77/.no-poke"
t_window 'CLE-77@tg > lane' 'sleep 600' >/dev/null
t_window 'AGY-12 lane' 'sleep 600' >/dev/null
t_window 'CLE-777 other' 'sleep 600' >/dev/null

bash "$REN" >/dev/null 2>&1; eq "with no alias table the rename refuses (4)" 4 "$?"
bash "$MAP" --apply >/dev/null 2>&1
eq "the map gave the older spawn AGY-12 a-004" a-004 "$(awk -F'\t' '$1 == "AGY-12" { print $2 }' "$R/agent-id-aliases.tsv")"
eq "...and CLE-77 c-005" c-005 "$(awk -F'\t' '$1 == "CLE-77" { print $2 }' "$R/agent-id-aliases.tsv")"

# --- the dry run --------------------------------------------------------------
out="$(RENAME_NOTE=1 bash "$REN" --desk-envs dev --note-from c-001 2>&1)"; eq "the dry run exits 0" 0 "$?"
has "it plans the spool dir" "PLAN spool     CLE-77     $R/CLE-77 -> $R/c-005" "$out"
has "it plans the window, the box tag kept" "'CLE-77@tg > lane' -> 'c-005@tg > lane'" "$out"
has "it plans the dev desk" "PLAN desk      CLE-77     dev/t1" "$out"
hasnt "...and only the envs asked for" "prd/t2" "$out"
has "it plans the ONE note" "c-001 -> c-005: your id is now c-005; use --from c-005" "$out"
check "the dry run moves nothing" test -d "$R/CLE-77/inbox" -a ! -L "$R/CLE-77" -a -e "$R/agents/CLE-77.json"

# --- apply ----------------------------------------------------------------------
out="$(bash "$REN" --apply --desk-envs "dev prd" 2>&1)"; eq "--apply exits 0 ($out)" 0 "$?"
check "the dir moved, unread mail with it" test -s "$R/c-005/inbox/unread.json"
eq "CLE-77 is a link to c-005" c-005 "$(readlink "$R/CLE-77")"
check "a path built from the old id still lands" test -s "$R/CLE-77/inbox/unread.json"
eq "the registry row carries the new id, others untouched" "c-005 a-004@box-t c-099" "$(cut -f1 "$R/registry.tsv" | tr '\n' ' ' | sed 's/ $//')"
check "the record moved" test -s "$R/agents/c-005.json" -a ! -e "$R/agents/CLE-77.json"
eq "...with id = c-005" c-005 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$R/agents/c-005.json")"
wn="$(tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a -F '#{window_name}')"
has "the window carries the new id" "c-005@tg > lane" "$wn"
has "...the qualified agent's too" "a-004 lane" "$wn"
has "...and a longer id that merely starts the same is left alone" "CLE-777 other" "$wn"
check "qualified: the <ID>@<box> dir moved, both names are links" test -d "$R/a-004@box-t/inbox" -a "$(readlink "$R/a-004")" = a-004@box-t -a "$(readlink "$R/AGY-12")" = a-004
check "the dev desk dir moved with its mute marker, old -> new link" test -e "$D1/c-005/.no-poke" -a "$(readlink "$D1/CLE-77")" = c-005
check "the prd desk dir moved too" test -d "$D2/c-005/inbox" -a -L "$D2/CLE-77"

out="$(bash "$REN" --apply 2>&1)"; eq "a second run exits 0" 0 "$?"
has "...and skips what is renamed" "SKIP     CLE-77: already renamed to c-005" "$out"

# --- a held new id is refused ----------------------------------------------------
mkdir -p "$R/CLE-88/inbox" "$R/c-006/inbox"; : >"$R/c-006/inbox/x.json"
printf 'CLE-88\tc-006\tclaude\tbox-t\t2026-10-02T12:00:00Z\n' >>"$R/agent-id-aliases.tsv"
t_window 'CLE-88 x' 'sleep 600' >/dev/null
out="$(bash "$REN" --apply CLE-88 2>&1)"; eq "a new id that holds mail is refused (1)" 1 "$?"
has "...naming it" "$R/c-006 is held" "$out"
check "...and CLE-88 stays as it was" test -d "$R/CLE-88/inbox" -a ! -L "$R/CLE-88"

# --- the identity map reads the renamed process as its new id ----------------------
P="$T_TMP/proc"; export AI_PROC_ROOT="$P" AI_PANES_FILE="$T_TMP/panes.tsv"
mkdir -p "$P/100" "$P/102"
printf '/bin/bash\0' >"$P/100/cmdline"; printf '/usr/bin/claude\0' >"$P/102/cmdline"
printf 'SPOOL_AGENT_ID=CLE-77\0' >"$P/102/environ"; : >"$P/100/environ"
printf '100 (bash) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 500 0\n' >"$P/100/stat"
printf '102 (claude) S 100 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 502 0\n' >"$P/102/stat"
for p in 100 102; do printf 'Uid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$P/$p/status"; ln -sfn "$T_TMP" "$P/$p/cwd"; done
printf 't\t@1\t%%9\t100\tc-005@tg > lane\n' >"$AI_PANES_FILE"
. "$T_FEAT/lib/agent-identity.inc.sh"
has "facts: the env says CLE-77, the record reads c-005" '"id": "c-005"' "$(ai_panes | ai_py facts)"
out="$(ai_panes | ai_py reconcile --tag tg)"
hasnt "reconcile renames no window back to CLE-77" "RENAME" "$out"
check "...and writes no CLE-77 record" test ! -e "$R/agents/CLE-77.json"
rm "$R/CLE-77"
has "an id the table maps but that is NOT renamed yet keeps its old id" '"id": "CLE-77"' "$(ai_panes | ai_py facts)"

t_done
