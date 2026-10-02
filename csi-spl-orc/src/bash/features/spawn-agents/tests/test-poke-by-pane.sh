#!/usr/bin/env bash
# Pokes land by PANE, even past unsent text (27f01e16 item 3).
#
#   1. the pane is found from the registry / identity record under ANY of the
#      agent's names (the alias table), never only from the window title
#   2. a stale one-line draft is set aside, the poke submitted, the draft typed
#      back unsent; a live, multi-line or ghost-only line is never swapped
#   3. refusals are counted and ONE deaf alert per streak goes to the
#      orchestrator (or, for the orchestrator itself, the dispatch holder)
#
# A private tmux server, a mktemp SPOOL_ROOT and a python stand-in TUI.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
. "$T_FEAT/lib/spool-poke-queue.inc.sh"
spool_env_resolve
export SPOOL_POKE_STYLE=line SPOOL_NOTIFY_ENTER_DELAY=0.1 SPOOL_POKE_RESTORE_DELAY=0.2
FAKE="$T_FEAT/tests/fixtures/fake-tui.py"
TM=(tmux -S "$SPOOL_TMUX_SOCKET")
t_tmux

# ---- 1. by pane, under every name ------------------------------------------
n=""
printf 'CLE-901\tc-901\tclaude\tbox-desk\t2026-10-02T16:35:05Z\n' >"$SPOOL_ROOT/agent-id-aliases.tsv"
spl_agent_id_names_var n c-901
eq "the new id answers to its legacy id"     " c-901 CLE-901 " "$n"
spl_agent_id_names_var n CLE-901
eq "the legacy id answers to its new id"     " CLE-901 c-901 " "$n"
spl_agent_id_names_var n c-777
eq "an unmapped id is only itself"           " c-777 " "$n"

LOG1="$T_TMP/tui1.log"
p1="$(t_window CLE-901 "python3 $FAKE $LOG1")"
printf 'CLE-901\tclaude\t%s\t/opt\t20261002T160551Z\n' "$p1" >>"$SPOOL_ROOT/registry.tsv"
sleep 0.3
eq "c-901 finds the pane titled and registered CLE-901" "$p1" "$(spool_pane_of c-901)"
eq "CLE-901 still finds it"                  "$p1" "$(spool_pane_of CLE-901)"
"${TM[@]}" rename-window -t "$p1" work
eq "a title with no id: the registry row decides" "$p1" "$(spool_pane_of c-901)"
"${TM[@]}" rename-window -t "$p1" CLE-902
eq "a title naming ANOTHER agent vetoes the row" "" "$(spool_pane_of c-901)"
"${TM[@]}" rename-window -t "$p1" c-901
printf 'CLE-903\tclaude\t%s\t/opt\t20261002T170000Z\n' "$p1" >>"$SPOOL_ROOT/registry.tsv"
"${TM[@]}" rename-window -t "$p1" work
eq "a later row giving the pane to another agent wins" "" "$(spool_pane_of c-901)"
"${TM[@]}" rename-window -t "$p1" c-901
eq "the title fallback matches the new id too" "$p1" "$(spool_pane_of CLE-901)"
: >"$SPOOL_ROOT/registry.tsv"
printf 'c-901\tclaude\t%s\t/opt\t20261002T171000Z\n' "$p1" >>"$SPOOL_ROOT/registry.tsv"

state="$SPOOL_ROOT/c-901/.pokes/unsent.state"
age_state() {  # SECONDS: pretend the current unsent text was first seen that long ago
  local c a t
  IFS=$'\t' read -r _ c a t <"$state"
  printf '%s\t%s\t%s\t%s\n' "$(( $(date +%s) - $1 ))" "$c" "$a" "$t" >"$state"
}
LINE=": 'SPOOL c-901: note from c-902 :: hello'"

# ---- 2a. a ghost-only composer is not unsent text --------------------------
spool_notify_poke c-901 "$LINE" >/dev/null; rc=$?
eq "an idle composer with autosuggest is poked" 0 "$rc"
sleep 0.3
eq "Enter submitted the poke, not the suggestion" "$LINE" "$(tail -1 "$LOG1")"
check "no refusal state after a clean poke" test ! -e "$state"

# ---- 2b. a fresh draft is refused and counted ------------------------------
"${TM[@]}" send-keys -t "$p1" -l p; sleep 0.3
out="$(spool_notify_poke c-901 "$LINE")"; rc=$?
eq "a fresh one-char draft: refused" 6 "$rc"
has "the refusal reports its count" "1 refusal(s)" "$out"
check "the refusal is recorded" test -s "$SPOOL_ROOT/c-901/.pokes/refused.log"
eq "the state holds the draft" "p" "$(cut -f4 "$state")"
spool_notify_poke c-901 "$LINE" >/dev/null
eq "a second refusal counts 2" 2 "$(cut -f2 "$state")"

# ---- 2c. a stale draft is swapped round the poke ---------------------------
lines_before="$(wc -l <"$LOG1")"
age_state 120
out="$(spool_notify_poke c-901 "$LINE")"; rc=$?
eq "a draft unchanged for 120 s: the poke goes in" 0 "$rc"
has "the swap is reported" "set aside" "$out"
sleep 0.4
eq "exactly one line was submitted" $((lines_before + 1)) "$(wc -l <"$LOG1")"
eq "and it is the poke, not the draft" "$LINE" "$(tail -1 "$LOG1")"
has "the draft is back in the composer, unsent" "❯ p" "$("${TM[@]}" capture-pane -p -t "$p1")"
check "the streak is cleared" test ! -e "$state"
has "the swap is in the refusal log" "swapped" "$(cat "$SPOOL_ROOT/c-901/.pokes/refused.log")"

# ---- 2d. a draft that keeps changing is never swapped -----------------------
spool_notify_poke c-901 "$LINE" >/dev/null
age_state 120
"${TM[@]}" send-keys -t "$p1" -l q; sleep 0.3
spool_notify_poke c-901 "$LINE" >/dev/null; rc=$?
eq "someone is typing (text changed): refused" 6 "$rc"
eq "the age restarts with the new text" 1 "$(cut -f2 "$state")"
has "the draft is untouched" "❯ pq" "$("${TM[@]}" capture-pane -p -t "$p1")"

# ---- 2e. SPOOL_POKE_RESTORE=0 and a long draft are never swapped -----------
age_state 120
SPOOL_POKE_RESTORE=0 SPOOL_POKE_DEAF_ALERT=0 spool_notify_poke c-901 "$LINE" >/dev/null; rc=$?
eq "SPOOL_POKE_RESTORE=0: refused" 6 "$rc"
age_state 120
SPOOL_POKE_STALE_MAX=1 SPOOL_POKE_DEAF_ALERT=0 spool_notify_poke c-901 "$LINE" >/dev/null; rc=$?
eq "a draft longer than SPOOL_POKE_STALE_MAX: refused" 6 "$rc"

# ---- 2f. a multi-line draft is never swapped -------------------------------
LOG2="$T_TMP/tui2.log"
p2="$(t_window c-904 "python3 $FAKE $LOG2 multi")"
printf 'c-904\tclaude\t%s\t/opt\t20261002T171000Z\n' "$p2" >>"$SPOOL_ROOT/registry.tsv"
sleep 0.3
"${TM[@]}" send-keys -t "$p2" -l draft; sleep 0.3
SPOOL_POKE_DEAF_ALERT=0 spool_notify_poke c-904 "$LINE" >/dev/null
st4="$SPOOL_ROOT/c-904/.pokes/unsent.state"
IFS=$'\t' read -r _ c a t <"$st4"; printf '%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 120 ))" "$c" "$a" "$t" >"$st4"
SPOOL_POKE_DEAF_ALERT=0 spool_notify_poke c-904 "$LINE" >/dev/null; rc=$?
eq "a stale MULTI-line draft: refused, never cleared" 6 "$rc"
check "nothing was submitted from it" test ! -s "$LOG2"

# ---- 2g. no cursor cell (unfocused pane): swapped; cursor mid-text: never --
stale_poke() {  # ID: refuse once, age the streak, offer again; prints the rc
  local st="$SPOOL_ROOT/$1/.pokes/unsent.state" c a t
  SPOOL_POKE_DEAF_ALERT=0 spool_notify_poke "$1" "$LINE" >/dev/null
  IFS=$'\t' read -r _ c a t <"$st"; printf '%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 120 ))" "$c" "$a" "$t" >"$st"
  SPOOL_POKE_DEAF_ALERT=0 spool_notify_poke "$1" "$LINE" >/dev/null
  echo "$?"
}
LOG5="$T_TMP/tui5.log"
p5="$(t_window c-905 "python3 $FAKE $LOG5 nocursor")"
printf 'c-905\tclaude\t%s\t/opt\t20261002T171000Z\n' "$p5" >>"$SPOOL_ROOT/registry.tsv"
sleep 0.3; "${TM[@]}" send-keys -t "$p5" -l 'two words'; sleep 0.3
eq "no cursor cell, stale: the poke goes in" 0 "$(stale_poke c-905)"
sleep 0.4
eq "the poke was submitted, the draft was not" "$LINE" "$(cat "$LOG5")"
has "the whole draft is typed back" "❯ two words" "$("${TM[@]}" capture-pane -p -t "$p5")"
LOG6="$T_TMP/tui6.log"
p6="$(t_window c-906 "python3 $FAKE $LOG6 mid")"
printf 'c-906\tclaude\t%s\t/opt\t20261002T171000Z\n' "$p6" >>"$SPOOL_ROOT/registry.tsv"
sleep 0.3; "${TM[@]}" send-keys -t "$p6" -l 'abc'; sleep 0.3
eq "a cursor ON a character, stale: refused" 6 "$(stale_poke c-906)"
has "that draft is untouched" "❯ abc" "$("${TM[@]}" capture-pane -p -t "$p6")"

spool_notify_swap_shape_ok '❯ [Pasted text #1 +20 lines]' '' && nok "a paste placeholder is never swapped" || ok "a paste placeholder is never swapped"
spool_notify_swap_shape_ok '❯ look at [Image #1]' '' && nok "an image placeholder is never swapped" || ok "an image placeholder is never swapped"
spool_notify_swap_shape_ok '❯ p' '────' && ok "a one-line draft over a rule is swappable" || nok "a one-line draft over a rule is swappable"

# ---- 3. the deaf alert -----------------------------------------------------
ALERTS="$T_TMP/alerts"
cat >"$T_TMP/alert.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$ALERTS"
EOF
chmod +x "$T_TMP/alert.sh"
export ALERTS SPOOL_POKE_DEAF_CMD="$T_TMP/alert.sh" SPOOL_POKE_RESTORE=0
mkdir -p "$SPOOL_ROOT/dispatch"
printf 'LEASE_ORCH=c-950\n' >"$SPOOL_ROOT/dispatch/lease.conf"
rm -f "$state"
spool_notify_poke c-901 "$LINE" >/dev/null
spool_notify_poke c-901 "$LINE" >/dev/null
age_state 200
check "no alert before the minimum count is reached" test ! -s "$ALERTS"
out="$(spool_notify_poke c-901 "$LINE")"
has "the third stale refusal raises the alert" "ALERT" "$out"
eq "one alert, to the orchestrator" 1 "$(grep -c '^c-950|c-901|' "$ALERTS" 2>/dev/null)"
has "the alert names the pane" "$p1" "$(cat "$ALERTS")"
has "the alert says where the messages wait" "/c-901/inbox/" "$(cat "$ALERTS")"
spool_notify_poke c-901 "$LINE" >/dev/null
eq "one alert per streak" 1 "$(wc -l <"$ALERTS")"

# the orchestrator itself is deaf: the dispatch holder hears of it
printf 'c-951@box-desk 1790965939\n' >"$SPOOL_ROOT/dispatch/lease"
printf 'LEASE_ORCH=c-901\n' >"$SPOOL_ROOT/dispatch/lease.conf"
rm -f "$state"
for _ in 1 2; do spool_notify_poke c-901 "$LINE" >/dev/null; done
age_state 200
spool_notify_poke c-901 "$LINE" >/dev/null
eq "a deaf orchestrator: the dispatch holder is told" 1 "$(grep -c '^c-951@box-desk|c-901|' "$ALERTS")"
printf 'LEASE_ORCH=CLE-901\n' >"$SPOOL_ROOT/dispatch/lease.conf"
eq "the orchestrator under its legacy id is still itself" "c-951@box-desk" "$(spool_poke_deaf_target c-901)"

# a poke that lands ends the streak
unset SPOOL_POKE_RESTORE
"${TM[@]}" send-keys -t "$p1" C-u; sleep 0.3
spool_notify_poke c-901 "$LINE" >/dev/null; rc=$?
eq "a clear prompt is poked again" 0 "$rc"
check "the streak state is gone" test ! -e "$state"
has "the recovery is logged" "delivered" "$(tail -1 "$SPOOL_ROOT/c-901/.pokes/refused.log")"

t_done
