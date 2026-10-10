#!/usr/bin/env bash
# test-tmux-close-window.sh — the agent-teardown helper (specs/048, ported).
# The bug it pins: an unresolvable owner used to fall back to the ACTIVE pane,
# so a teardown closed the window the human was looking at. A private tmux
# server, fake agent windows; the live server is never touched.
#
#   1. no ownership source at all -> exit 3, the active window survives
#   2. --agent resolves the window by its (tagged) name; --dry-run kills nothing
#   3. --agent closes exactly that window, a sibling survives
#   4. a registry pane whose window names ANOTHER id -> exit 4, nothing closed
#   5. --defer on a pane with no agent CLI closes it after the grace, and logs
#      the target to CLOSE_LOG_DIR
#   6. T-EXITCLEAN-RETIRING (spec 060 FR-016): --agent CLE-001 --defer from a
#      retiring window closes THAT window, never the new CLE-001 (control: from
#      outside it resolves to the new one); from another window it is refused
#   7. spec 061 ids (c-097 / g-113 / a-091 / q-004) resolve EXACTLY: lower-case
#      kind, 3 digits, never re-padded, in both the <ID>@<box> and the tagged
#      "<tag>: <ID>" window shape, never a look-alike ("C-97"). Control: the
#      pre-c0ec0735 norm_id (10#n, %02d) turns c-097 into C-97 and misses it
#   8. the --defer closer outlives the caller's session: agy runs each command
#      in its own session and kills it on return (a-420/a-424/a-474 kept their
#      windows). Control: the old in-session closer (TCW_NO_SETSID=1) dies
#   9. an agy pane: the closer types /exit once agy is idle at an empty `>`,
#      agy exits by itself, then the window closes - long before the timeout,
#      though the pane's launcher shell, whose args name the agy path, lives on
#      (a-479 waited the full 180 s, a-480 2 min after agy had left)
#  10. controls: an idle agy with NO closer scheduled is never typed into nor
#      closed; a busy agy (screen still changing) never gets /exit; nor does
#      one paused mid-turn on a STATIC screen (footer `esc to cancel`) - the
#      live a-479 got three /exit tries in that state on screen stability alone
#  11. specs/102 4.3 (T005): --defer writes lifetime/done BEFORE it returns, while
#      the claude / grok / agy process still runs (a-479, a-480: S3 took over an
#      agent that had exited on purpose); --rebirth writes lifetime/rebirth,
#      drops a stale done, closes and retires nothing. Control: a role id
#      (c-001) writes no done
#  12. 2026-10-07 09:22:21Z: --agent c-002 --defer with the pane vars stripped
#      (an outer sudo) while a NEWER c-002 window exists is refused and closes
#      nothing, nor does a stale caller pane; --pane still works. Control: the
#      script with that guard spliced out kills the fresh c-002
#  13. specs/102 4.3 (T008 gap): --rebirth from the caller's own pane forks a
#      detached closer that types /exit ONCE into a harness idle at an empty
#      prompt (a claude-like `❯` screen here), then leaves: the window and the
#      registry row stay. Controls: a busy pane gets nothing; the script with
#      the fork spliced out (the old marker-only --rebirth) types nothing.
#      A human client active in THAT window: nothing typed; one active in
#      ANOTHER window of the same session: /exit typed once
#  14. 2026-10-08/09 (c-585 / c-602 / c-623): a lane that ran /exit-clean
#      itself sat idle at an empty prompt and never left. The --defer closer
#      types /exit into an idle claude, which leaves; the window closes and the
#      id is retired well before the timeout. Control: the agy-only closer
#      types nothing and the window stays. A CLI that never leaves (a running
#      turn) is closed and retired by the timeout, with one log line. --retire
#      without --agent is refused (2), closing nothing; control: the old code
#      killed the window and retired nothing.
#      2026-10-09 (c-638): claude's faint prompt suggestion read `❯ /exit`;
#      the closer took the ghost text for typed input and never typed (no
#      `typing /exit` line in its log). Now faint text is dropped, /exit is
#      typed and the lane leaves; control: plain capture-pane types nothing.
#      A lane that left a shell running gets claude's "Background work is
#      running" dialog after /exit, and one whose /exit stays unsubmitted
#      keeps `❯ /exit`: both get Enter and leave; control: the verify step
#      spliced out leaves both to the timeout
#  15. spec 115 ORC-4: /exit-clean (--defer --agent) closes the lane's tries
#      journal row with source exit-clean: a red CI job the lane caused on its
#      last landed sha writes fail:F3, a green lane ok, a lane with nothing
#      landed (no commit of its own, or an unpushed one) fail:F3, a job
#      already red on the parent ok. The row keeps the spawn row's task, kind,
#      vendor and start. gh is a stub, origin a local bare repo: no network.
#      Control: the writer with the `source` field spliced out turns it red
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SUT="$T_SCRIPTS/tmux-close-window.sh"
unset TMUX TMUX_PANE CLE_TMUX_PANE GRK_TMUX_PANE AGY_TMUX_PANE QWN_TMUX_PANE MCP_BOT_AGENT_ID \
      CLE_TMUX_SOCK GRK_TMUX_SOCK AGY_TMUX_SOCK QWN_TMUX_SOCK
export CLOSE_LOG_DIR="$T_TMP/logs" SPOOL_BOX_TAG=tbox; mkdir -p "$CLOSE_LOG_DIR"
t_tmux
alive() { tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -x "$1" >/dev/null; }

VICTIM="$(t_window 'tbox: CLE-09 someone else' 'sleep 600')"
tmux -S "$SPOOL_TMUX_SOCKET" select-window -t "$VICTIM"

# --- 1. no source -------------------------------------------------------------
bash "$SUT" >"$T_TMP/o" 2>&1; eq "1. no ownership source is refused (3)" 3 "$?"
check "1. the ACTIVE window survives" alive "$VICTIM"

# --- 2. --agent + --dry-run -----------------------------------------------------
P7="$(t_window 'tbox: CLE-07 wip' 'sleep 600')"
out="$(bash "$SUT" --agent cle-7 --dry-run 2>&1)"; eq "2. --agent --dry-run exits 0" 0 "$?"
has "2. it resolves the tagged window of CLE-07" "CLE-07" "$out"
check "2. --dry-run kills nothing" alive "$P7"

# --- 3. --agent closes that window only ------------------------------------------
bash "$SUT" --agent CLE-07 >"$T_TMP/o" 2>&1; eq "3. --agent CLE-07 exits 0" 0 "$?"
check "3. CLE-07's window is gone" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P7'"
check "3. the sibling survives" alive "$VICTIM"

# --- 4. registry mismatch -----------------------------------------------------------
printf 'GRK-05\tgrok\t%s\t/x\t20260101T000000Z\n' "$VICTIM" >"$SPOOL_ROOT/registry.tsv"
bash "$SUT" --agent GRK-05 >"$T_TMP/o" 2>&1; rc=$?
[ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; eq "4. a pane whose window names another id is refused" 0 "$?"
check "4. ... and nothing was closed" alive "$VICTIM"

# --- 5. --defer --------------------------------------------------------------------------
P8="$(t_window 'tbox: QWN-08 done' 'sleep 600')"
QWN_TMUX_PANE="$P8" bash "$SUT" --agent QWN-08 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "5. --defer returns 0 at once" 0 "$?"
has "5. it names the scheduled target" "scheduled defer-close" "$(cat "$T_TMP/o")"
for _ in $(seq 1 20); do alive "$P8" || break; sleep 0.5; done
check "5. the deferred close lands" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P8'"
has "5. the log records the target" "closing window" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"
check "5. the victim survives the whole run" alive "$VICTIM"

# --- 6. T-EXITCLEAN-RETIRING (spec 060 FR-016) ------------------------------------------
NEWP="$(t_window 'CLE-001@tbox' 'sleep 600')"
OLDP="$(t_window 'CLE-001-0405Z-retiring' 'sleep 600')"
out="$(bash "$SUT" --agent CLE-001 --dry-run 2>&1)"
has "6. control: --agent CLE-001 from outside resolves to the NEW window" "$NEWP" "$out"
out="$(CLE_TMUX_PANE="$OLDP" bash "$SUT" --agent CLE-001 --dry-run 2>&1)"
has "6. from the retiring pane it resolves to the retiring window" "$OLDP" "$out"
hasnt "6. ... not the new one" "$NEWP" "$out"
CLE_TMUX_PANE="$OLDP" bash "$SUT" --agent CLE-001 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "6. --defer from the retiring pane returns 0" 0 "$?"
for _ in $(seq 1 20); do alive "$OLDP" || break; sleep 0.5; done
check "6. the retiring window is closed" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$OLDP'"
check "6. the NEW window survives" alive "$NEWP"
CLE_TMUX_PANE="$VICTIM" bash "$SUT" --agent CLE-001 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "6. --defer from another window's pane is refused (4)" 4 "$?"
check "6. ... and the new window survives" alive "$NEWP"
# --- 7. spec 061 ids resolve exactly (/exit-clean left c-097's window open) ---------------
NC="$(t_window 'c-097@tbox' 'sleep 600')"
NG="$(t_window 'tbox: g-113 wip' 'sleep 600')"
NA="$(t_window 'a-091@tbox' 'sleep 600')"
NQ="$(t_window 'tbox: q-004' 'sleep 600')"
DECOY="$(t_window 'C-97@tbox' 'sleep 600')"
for pair in "c-097:$NC" "G-113:$NG" "a-091:$NA" "q-004:$NQ"; do
  id="${pair%%:*}"; pane="${pair#*:}"
  out="$(bash "$SUT" --agent "$id" --dry-run 2>&1)"; eq "7. --agent $id --dry-run exits 0" 0 "$?"
  has "7. --agent $id resolves its own pane" "pane=$pane " "$out"
  has "7. ... as ${id,,}: lower case, never re-padded" "via --agent ${id,,}" "$out"
done
hasnt "7. c-097 never resolves the look-alike C-97" "$DECOY" "$(bash "$SUT" --agent c-097 --dry-run 2>&1)"
# Control: the same script with the pre-c0ec0735 norm_id spliced in (beside
# a lib/ link, which it loads relative to itself).
mkdir -p "$T_TMP/old/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/old/lib"
cat >"$T_TMP/old-norm.sh" <<'OLDNORM'
norm_id() {
  local t p n
  t="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  if printf '%s' "$t" | grep -qE '^[A-Z]+-?[0-9]+$'; then
    p="$(printf '%s' "$t" | grep -oE '^[A-Z]+')"
    n="$(printf '%s' "$t" | grep -oE '[0-9]+$')"
    printf '%s-%02d' "$p" "$((10#$n))"
    return 0
  fi
  return 1
}
OLDNORM
awk -v f="$T_TMP/old-norm.sh" '/^norm_id\(\) \{/ { while ((getline l < f) > 0) print l; skip = 1; next }
  skip { if (/^}/) skip = 0; next } { print }' "$SUT" >"$T_TMP/old/scripts/tmux-close-window.sh"
out="$(bash "$T_TMP/old/scripts/tmux-close-window.sh" --agent c-097 --dry-run 2>&1)"
has "7. control: the old norm_id turns c-097 into C-97" "'C-97'" "$out"
hasnt "7. control: ... and misses c-097's window" "pane=$NC " "$out"
bash "$SUT" --agent c-097 >"$T_TMP/o" 2>&1; eq "7. --agent c-097 closes its window (exit 0)" 0 "$?"
check "7. c-097's window is gone" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$NC'"
check "7. the look-alike C-97 window survives" alive "$DECOY"

# --- 8. the closer survives agy killing the command's session ----------------------------
wait_gone() { for _ in $(seq 1 "$2"); do alive "$1" || return 0; sleep 0.5; done; return 1; }
in_agy_session() {  # run CMD... the way agy runs a command: own session, killed on return
  setsid -f -w bash -c '"$@"; kill -KILL -- -$$' _ "$@" >/dev/null 2>&1; return 0
}
P8B="$(t_window 'q-201@tbox' 'sleep 600')"
in_agy_session env TCW_NO_SETSID=1 QWN_TMUX_PANE="$P8B" bash "$SUT" --agent q-201 --defer --timeout 4
sleep 5
check "8. control: the in-session closer dies with agy's session (window stays)" alive "$P8B"
P8C="$(t_window 'q-202@tbox' 'sleep 600')"
in_agy_session env QWN_TMUX_PANE="$P8C" bash "$SUT" --agent q-202 --defer --timeout 4
check "8. the detached closer survives the session kill and closes the window" wait_gone "$P8C" 20
check "8. ... the victim survives" alive "$VICTIM"
tmux -S "$SPOOL_TMUX_SOCKET" kill-pane -t "$P8B" 2>/dev/null

# --- 9. agy: the closer types /exit once agy is idle ---------------------------------------
mkdir -p "$T_TMP/bin"
cat >"$T_TMP/bin/agy" <<'FAKEAGY'
#!/usr/bin/env bash
# fake agy: an input box, reads lines into $1, leaves on /exit; $2=busy keeps the
# screen moving, $2=paused holds a static mid-turn screen (real agy's footers)
if [ "${2:-}" = busy ]; then n=0; while :; do n=$((n + 1)); printf 'working %s\n>\nesc to cancel\n' "$n"; sleep 0.2; done; fi
if [ "${2:-}" = paused ]; then printf '%s\n' 'Generating...' '-----' '>' '-----' 'esc to cancel'
else printf '%s\n' '-----' '>' '-----' '? for shortcuts'; fi
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$1"
  [ "$line" = /exit ] && { echo AGY-EXITED >>"$1"; exit 0; }
done
sleep 600
FAKEAGY
chmod +x "$T_TMP/bin/agy"
# The pane as spawn-agy.sh leaves it: a launcher shell whose command line names
# the agy path outlives agy (argv[0] of agy itself is `agy`).
cat >"$T_TMP/bin/agy-pane" <<'FAKEPANE'
#!/bin/sh
bash -c 'exec -a agy bash "$0" "$1" "$2"' "$1" "$2" "${3:-}"
sleep 600
FAKEPANE
P9="$(t_window 'a-301@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-301")"
sleep 1
in_agy_session env AGY_TMUX_PANE="$P9" bash "$SUT" --agent a-301 --defer --timeout 60
check "9. the agy window closes well before the 60 s timeout" wait_gone "$P9" 30
has "9. agy got /exit typed and left by itself" "AGY-EXITED" "$(cat "$T_TMP/got-301" 2>/dev/null)"
has "9. the log names the /exit it typed" "typing /exit" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"

# --- 10. controls: no closer = no close; busy = no /exit ------------------------------------
P10="$(t_window 'a-302@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-302")"
sleep 6
check "10. control: an idle agy with no closer scheduled stays" alive "$P10"
eq "10. control: ... and nothing was typed into it" "" "$(cat "$T_TMP/got-302" 2>/dev/null)"
P10B="$(t_window 'a-303@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-303 busy")"
sleep 1
in_agy_session env AGY_TMUX_PANE="$P10B" bash "$SUT" --agent a-303 --defer --timeout 5
check "10. a busy agy is closed only by the timeout" wait_gone "$P10B" 30
eq "10. control: ... and never got /exit while busy" "" "$(cat "$T_TMP/got-303" 2>/dev/null)"
P10C="$(t_window 'a-304@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-304 paused")"
sleep 1
in_agy_session env AGY_TMUX_PANE="$P10C" bash "$SUT" --agent a-304 --defer --timeout 6
check "10. an agy paused mid-turn is closed only by the timeout" wait_gone "$P10C" 30
eq "10. control: ... and never got /exit on a static mid-turn screen" "" "$(cat "$T_TMP/got-304" 2>/dev/null)"
check "10. the idle agy without a closer is still there" alive "$P10"

# --- 11. the lifetime markers (specs/102 4.3) --------------------------------------------------
for h in claude grok agy; do ln -sf "$(command -v sleep)" "$T_TMP/bin/$h"; done
for hid in claude:c-411:CLE grok:g-412:GRK agy:a-413:AGY; do
  h="${hid%%:*}" id="${hid#*:}" pfx="${hid##*:}"; id="${id%:*}"
  P="$(t_window "$id@tbox" "$T_TMP/bin/$h 600")"
  sleep 0.5
  env "${pfx}_TMUX_PANE=$P" bash "$SUT" --agent "$id" --defer --timeout 3 >"$T_TMP/o" 2>&1; eq "11. $h: --defer returns 0" 0 "$?"
  check "11. $h: lifetime/done is written before the $h process ends (it still runs)" bash -c "test -s '$SPOOL_ROOT/$id/lifetime/done' && tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id} #{pane_current_command}' | grep -qx '$P $h'"
done
P11="$(t_window 'c-414@tbox' 'sleep 600')"
mkdir -p "$SPOOL_ROOT/c-414/lifetime"; echo old > "$SPOOL_ROOT/c-414/lifetime/done"
bash "$SUT" --agent c-414 --rebirth >"$T_TMP/o" 2>&1; eq "11. --rebirth returns 0" 0 "$?"
check "11. --rebirth writes lifetime/rebirth" test -s "$SPOOL_ROOT/c-414/lifetime/rebirth"
check "11. --rebirth drops a stale done" test ! -e "$SPOOL_ROOT/c-414/lifetime/done"
sleep 2
check "11. --rebirth closes nothing: the window stays" alive "$P11"
hasnt "11. --rebirth schedules no close" "scheduled defer-close" "$(cat "$T_TMP/o")"
P11R="$(t_window 'c-001@tbox' 'sleep 600')"
CLE_TMUX_PANE="$P11R" bash "$SUT" --agent c-001 --defer --timeout 3 >"$T_TMP/o" 2>&1; eq "11. control: a role id's --defer returns 0" 0 "$?"
check "11. control: a role id writes no done (its successor keeps the id)" test ! -e "$SPOOL_ROOT/c-001/lifetime/done"

# --- 12. a rotation's deferred close never kills the fresh seat (2026-10-07 09:22:21Z) ----
# The old c-002 ran `sudo -u <owner> bash tmux-close-window.sh --agent c-002
# --defer`: sudo strips the pane vars (the suite unset them at the top), so
# --agent resolved to the NEW c-002 and the closer killed it at its timeout.
NEW12="$(t_window 'c-002@tbox' 'sleep 600')"
printf 'c-002\tclaude\t%s\t/x\t20261007T092100Z\n' "$NEW12" >>"$SPOOL_ROOT/registry.tsv"  # the fresh seat's spawn row
OLD12="$(t_window 'c-002-0921Z-retiring' 'sleep 600')"
bash "$SUT" --agent c-002 --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. --defer by id with no caller pane is refused (3)" 3 "$?"
has "12. ... and says why" "without the caller's own live pane" "$(cat "$T_TMP/o")"
hasnt "12. ... and schedules nothing" "scheduled defer-close" "$(cat "$T_TMP/o")"
CLE_TMUX_PANE=%99999 bash "$SUT" --agent c-002 --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. a stale caller pane proves nothing either (3)" 3 "$?"
sleep 5
check "12. the fresh c-002 survives past the timeout" alive "$NEW12"
check "12. ... and so does the retiring one (closed nothing)" alive "$OLD12"
bash "$SUT" --pane "$OLD12" --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. --pane is the sudo-proof --defer (0)" 0 "$?"
check "12. ... it closes the retiring window" wait_gone "$OLD12" 20
check "12. ... and the fresh c-002 survives" alive "$NEW12"
# Control: the same script with the guard spliced out kills the fresh seat.
mkdir -p "$T_TMP/pre/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre/lib"
awk '/^# A --defer is a self-teardown/ { skip = 1 } skip { if (/^fi$/) skip = 0; next } { print }' "$SUT" >"$T_TMP/pre/scripts/tmux-close-window.sh"
hasnt "12. control: the guard is spliced out" "without the caller's own live pane" "$(cat "$T_TMP/pre/scripts/tmux-close-window.sh")"
OLD12B="$(t_window 'c-002-1021Z-retiring' 'sleep 600')"
has "12. control: the old code resolves --agent c-002 to the fresh seat" "pane=$NEW12 " "$(bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent c-002 --defer --dry-run 2>&1)"
bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent c-002 --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. control: the old code schedules the close (0)" 0 "$?"
check "12. control: the old code kills the FRESH c-002" wait_gone "$NEW12" 20
check "12. control: ... and leaves the retiring window open" alive "$OLD12B"

# --- 13. --rebirth ends the session: /exit typed once when idle, window kept --------------
cat >"$T_TMP/bin/claude-fake" <<'FAKECLAUDE'
#!/usr/bin/env bash
# fake claude: an idle screen with an empty `❯` prompt (NBSP after it, as the
# real one), reads lines into $1, leaves on /exit; $2=busy keeps a running turn
if [ "${2:-}" = busy ]; then n=0; while :; do n=$((n + 1)); printf '✶ Working… (%ss · ↓ 9 tokens)\n────\n❯ \n────\n  esc to interrupt\n' "$n"; sleep 0.2; done; fi
# $2=ghost: the faint prompt suggestion `/exit` after the `❯` (c-638's screen);
# $2=bgwork: the first /exit opens the "Background work is running" dialog,
# Enter on it exits; $2=deaf: the first /exit stays unsubmitted in the prompt.
if [ "${2:-}" = ghost ]; then
  printf '%s\n' '✻ Cooked for 11m 36s · done 9.25 · 1 shell still running' '────' $'❯ \e[2m/exit\e[0m' '────' '  ⏵⏵ bypass permissions on · 1 shell'
else printf '%s\n' '✻ Cogitated for 3s · done 1.00' '────' $'❯ ' '────' '  ⏵⏵ bypass permissions on (shift+tab to cycle)'; fi
held=""
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$1"
  if [ "$line" = /exit ] && [ -z "$held" ] && [ "${2:-}" = bgwork ]; then
    held=1; printf '\033[2J\033[H'; printf '%s\n' '   Background work is running' '   The following will stop when you exit:' '   shell · sleep 400' $'   ❯ 1. Exit and stop tasks' '     2. Move to background and exit' '     3. Stay' '   Enter to confirm · Esc to cancel'; continue
  fi
  if [ "$line" = /exit ] && [ -z "$held" ] && [ "${2:-}" = deaf ]; then
    held=1; printf '\033[2J\033[H'; printf '%s\n' '────' $'❯ /exit' '────'; continue
  fi
  [ -n "$held" ] && [ -z "$line" ] && { echo CLAUDE-EXITED >>"$1"; exit 0; }
  [ "$line" = /exit ] && { echo CLAUDE-EXITED >>"$1"; exit 0; }
done
sleep 600
FAKECLAUDE
chmod +x "$T_TMP/bin/claude-fake"
cat >"$T_TMP/bin/claude-pane" <<'FAKEPANE'
#!/bin/sh
bash -c 'exec -a claude bash "$0" "$1" "$2"' "$1" "$2" "${3:-}"
sleep 600
FAKEPANE
P13="$(t_window 'c-415@tbox' "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-415")"
printf 'c-415\tclaude\t%s\t/x\t20261007T130000Z\n' "$P13" >>"$SPOOL_ROOT/registry.tsv"
sleep 1
in_agy_session env CLE_TMUX_PANE="$P13" bash "$SUT" --agent c-415 --rebirth --timeout 60
check "13. --rebirth writes lifetime/rebirth" test -s "$SPOOL_ROOT/c-415/lifetime/rebirth"
got_exit() { for _ in $(seq 1 "$2"); do grep -q CLAUDE-EXITED "$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
check "13. the idle harness gets /exit typed and leaves" got_exit "$T_TMP/got-415" 40
sleep 3
eq "13. ... /exit was typed exactly once" 1 "$(grep -cx /exit "$T_TMP/got-415" 2>/dev/null)"
check "13. the window stays (the watchdog restarts the id in it)" alive "$P13"
check "13. the registry row stays (nothing retired)" grep -q "^c-415	claude	$P13	" "$SPOOL_ROOT/registry.tsv"
has "13. the log names the /exit it typed" "typing /exit (try 1)" "$(cat "$CLOSE_LOG_DIR"/rebirth-exit-*.log 2>/dev/null)"
P13B="$(t_window 'c-416@tbox' "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-416 busy")"
sleep 1
in_agy_session env CLE_TMUX_PANE="$P13B" bash "$SUT" --agent c-416 --rebirth --timeout 6
sleep 8
eq "13. control: a busy pane never gets /exit" "" "$(cat "$T_TMP/got-416" 2>/dev/null)"
check "13. control: ... and its window stays" alive "$P13B"
# Control: the old marker-only --rebirth (the fork spliced out) types nothing.
mkdir -p "$T_TMP/pre13/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre13/lib"
sed 's/^if \[\[ "\$REBIRTH" -eq 1 \]\]; then rebirth_closer; exit 0; fi$/if [[ "$REBIRTH" -eq 1 ]]; then exit 0; fi/' "$SUT" >"$T_TMP/pre13/scripts/tmux-close-window.sh"
hasnt "13. control: the fork is spliced out" "then rebirth_closer;" "$(cat "$T_TMP/pre13/scripts/tmux-close-window.sh")"
P13C="$(t_window 'c-417@tbox' "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-417")"
sleep 1
in_agy_session env CLE_TMUX_PANE="$P13C" bash "$T_TMP/pre13/scripts/tmux-close-window.sh" --agent c-417 --rebirth --timeout 20
sleep 8
eq "13. control: without the fork the idle session is never ended" "" "$(cat "$T_TMP/got-417" 2>/dev/null)"
# A human looking at the window: an attached client whose current window it is.
attach_human() {  # WINDOW-TARGET -> a client on it (script gives tmux a tty; CI has no TERM, and tmux refuses to attach without one)
  setsid -f script -qfc "TERM=xterm tmux -S '$SPOOL_TMUX_SOCKET' attach -t '$1'" /dev/null </dev/null >/dev/null 2>&1
  for _ in $(seq 1 20); do [ -n "$(tmux -S "$SPOOL_TMUX_SOCKET" list-clients -F x 2>/dev/null)" ] && return 0; sleep 0.25; done
  return 1
}
detach_humans() { tmux -S "$SPOOL_TMUX_SOCKET" list-clients -F '#{client_tty}' | while read -r c; do tmux -S "$SPOOL_TMUX_SOCKET" detach-client -t "$c"; done; }
P13D="$(t_window 'c-418@tbox' "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-418")"
W13D="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P13D" '#{session_name}:#{window_index}')"
check "13. a human client is attached to c-418's window" attach_human "$W13D"
sleep 1
in_agy_session env CLE_TMUX_PANE="$P13D" WD_HUMAN_IDLE=120 bash "$SUT" --agent c-418 --rebirth --timeout 8
sleep 10
eq "13. a human active in THAT window: nothing typed" "" "$(cat "$T_TMP/got-418" 2>/dev/null)"
has "13. ... and the log says /exit waits" "a human is active in this window" "$(cat "$CLOSE_LOG_DIR"/rebirth-exit-*.log 2>/dev/null)"
detach_humans
P13E="$(t_window 'c-419@tbox' "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-419")"
check "13. a human client is attached to ANOTHER window of the session" attach_human "$VICTIM"
sleep 1
in_agy_session env CLE_TMUX_PANE="$P13E" WD_HUMAN_IDLE=120 bash "$SUT" --agent c-419 --rebirth --timeout 60
check "13. a human in another window: the idle harness gets /exit and leaves" got_exit "$T_TMP/got-419" 40
sleep 3
eq "13. ... /exit was typed exactly once" 1 "$(grep -cx /exit "$T_TMP/got-419" 2>/dev/null)"
detach_humans

# --- 14. a lane that ran /exit-clean itself is closed and retired (2026-10-08/09) --------
# c-585 / c-602 / c-623 sent their result, scheduled the close and sat idle at
# an empty prompt: nobody typed /exit, so the CLI never left and the window
# waited out the timeout (or a human closed it). The closer now types /exit
# into ANY harness idle at an empty prompt; the timeout still kills a CLI
# that never leaves, and retires the id with one log line.
retired() { ! grep -q "^$1	" "$SPOOL_ROOT/registry.tsv" && compgen -G "$SPOOL_ROOT/.retired/$1.*" >/dev/null; }
gone_and_retired() { for _ in $(seq 1 "$3"); do ! alive "$1" && retired "$2" && return 0; sleep 0.5; done; return 1; }
lane14() {  # ID [busy] -> pane of a fake claude lane with its registry row
  local p
  p="$(t_window "$1@tbox" "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-${1#c-} ${2:-}")"
  printf '%s\tclaude\t%s\t/x\t20261009T040000Z\tc-001\n' "$1" "$p" >>"$SPOOL_ROOT/registry.tsv"
  printf '%s\n' "$p"
}
rm -f "$CLOSE_LOG_DIR"/kill-your-self-close-*.log
P14="$(lane14 c-421)"
sleep 1
CLE_TMUX_PANE="$P14" bash "$SUT" --agent c-421 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1; eq "14. --defer --retire returns 0 at once" 0 "$?"
check "14. the idle claude gets /exit typed and leaves by itself" got_exit "$T_TMP/got-421" 40
check "14. ... then its window is closed and c-421 retired, well before the 60 s timeout" gone_and_retired "$P14" c-421 20
has "14. the log names the /exit it typed" "idle at an empty prompt: typing /exit (try 1)" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"
# Control: the closer as it was (/exit typed into agy only) leaves the idle lane open.
mkdir -p "$T_TMP/pre14/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre14/lib"
awk '{ print } /^type_exit_when_idle\(\) \{$/ { print "  (( ${#AGY_PIDS[@]} > 0 )) || return 0" }' "$SUT" >"$T_TMP/pre14/scripts/tmux-close-window.sh"
has "14. control: the old agy-only guard is spliced in" '(( ${#AGY_PIDS[@]} > 0 )) || return 0' "$(cat "$T_TMP/pre14/scripts/tmux-close-window.sh")"
P14B="$(lane14 c-422)"
sleep 1
CLE_TMUX_PANE="$P14B" bash "$T_TMP/pre14/scripts/tmux-close-window.sh" --agent c-422 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
sleep 15
eq "14. control: the old closer types nothing into the idle claude" "" "$(cat "$T_TMP/got-422" 2>/dev/null)"
check "14. control: ... its window is still open" alive "$P14B"
check "14. control: ... and c-422 is not retired" grep -q "^c-422	" "$SPOOL_ROOT/registry.tsv"
# A CLI that never leaves (a running turn: no /exit is typed) is closed by the timeout.
P14C="$(lane14 c-423 busy)"
sleep 1
CLE_TMUX_PANE="$P14C" bash "$SUT" --agent c-423 --defer --retire --timeout 4 >"$T_TMP/o" 2>&1
check "14. a CLI that never leaves: the timeout closes the window and retires c-423" gone_and_retired "$P14C" c-423 30
eq "14. ... nothing was typed into the running turn" "" "$(cat "$T_TMP/got-423" 2>/dev/null)"
eq "14. ... with ONE log line naming it" 1 "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null | grep -c 'timeout 4s: c-423 never left pane .* and retiring c-423$')"
# --retire with no id to retire: refused before anything is closed (the orchestrator's side note).
P14D="$(lane14 c-424)"
bash "$SUT" --pane "$P14D" --retire >"$T_TMP/o" 2>&1; eq "14. --retire without --agent is refused (2)" 2 "$?"
check "14. ... and closes nothing" alive "$P14D"
mkdir -p "$T_TMP/pre14r/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre14r/lib"
awk '/^# --retire needs the id to retire/ { skip = 1 } skip { if (/^fi$/) skip = 0; next } { print }' "$SUT" >"$T_TMP/pre14r/scripts/tmux-close-window.sh"
bash "$T_TMP/pre14r/scripts/tmux-close-window.sh" --pane "$P14D" --retire >"$T_TMP/o" 2>&1
check "14. control: the old code kills the window ..." bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P14D'"
check "14. control: ... and leaves c-424 unretired" grep -q "^c-424	" "$SPOOL_ROOT/registry.tsv"
# c-638 (2026-10-09): a faint prompt suggestion `❯ /exit` read as typed input.
log14() { cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null; }
rm -f "$CLOSE_LOG_DIR"/kill-your-self-close-*.log
P14E="$(lane14 c-425 ghost)"
sleep 1
CLE_TMUX_PANE="$P14E" bash "$SUT" --agent c-425 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
check "14. a ghost /exit suggestion: /exit is typed and the claude leaves" got_exit "$T_TMP/got-425" 40
check "14. ... its window is closed and c-425 retired before the timeout" gone_and_retired "$P14E" c-425 20
has "14. ... and the log says the typed /exit took" "the typed /exit took" "$(log14)"
mkdir -p "$T_TMP/pre14g/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre14g/lib"
sed 's/capture-pane -p -e -t "\$1" 2>\/dev\/null | screen_drop_faint |/capture-pane -p -t "$1" 2>\/dev\/null |/' "$SUT" >"$T_TMP/pre14g/scripts/tmux-close-window.sh"
hasnt "14. control: plain capture-pane is spliced back" "| screen_drop_faint |" "$(cat "$T_TMP/pre14g/scripts/tmux-close-window.sh")"
# Background work dialog / unsubmitted /exit: Enter after our own /exit.
P14F="$(lane14 c-426 bgwork)"; P14G="$(lane14 c-427 deaf)"
sleep 1
CLE_TMUX_PANE="$P14F" bash "$SUT" --agent c-426 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
CLE_TMUX_PANE="$P14G" bash "$SUT" --agent c-427 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
# Controls, run alongside: the ghost under plain capture-pane, the two others
# with the verify step spliced out (EXIT_ENTERS < 0: never an Enter after /exit).
mkdir -p "$T_TMP/pre14v/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre14v/lib"
sed 's/EXIT_ENTERS < 3 \&\& SECONDS/EXIT_ENTERS < 0 \&\& SECONDS/' "$SUT" >"$T_TMP/pre14v/scripts/tmux-close-window.sh"
has "14. control: the verify step is spliced out" "EXIT_ENTERS < 0 && SECONDS" "$(cat "$T_TMP/pre14v/scripts/tmux-close-window.sh")"
P14H="$(lane14 c-428 ghost)"; P14I="$(lane14 c-429 bgwork)"; P14J="$(lane14 c-430 deaf)"
sleep 1
CLE_TMUX_PANE="$P14H" bash "$T_TMP/pre14g/scripts/tmux-close-window.sh" --agent c-428 --defer --retire --timeout 15 >"$T_TMP/o" 2>&1
CLE_TMUX_PANE="$P14I" bash "$T_TMP/pre14v/scripts/tmux-close-window.sh" --agent c-429 --defer --retire --timeout 15 >"$T_TMP/o" 2>&1
CLE_TMUX_PANE="$P14J" bash "$T_TMP/pre14v/scripts/tmux-close-window.sh" --agent c-430 --defer --retire --timeout 15 >"$T_TMP/o" 2>&1
check "14. the background-work dialog: Enter on 'Exit and stop tasks', the claude leaves" got_exit "$T_TMP/got-426" 40
check "14. ... its window is closed and c-426 retired before the timeout" gone_and_retired "$P14F" c-426 20
has "14. ... the log names the dialog" "the exit asks about background work: Exit and stop tasks: Enter (1)" "$(log14)"
check "14. an unsubmitted /exit: Enter again, the claude leaves" got_exit "$T_TMP/got-427" 40
check "14. ... its window is closed and c-427 retired before the timeout" gone_and_retired "$P14G" c-427 20
has "14. ... the log names the unsubmitted /exit" "the typed /exit sits unsubmitted: Enter (1)" "$(log14)"
eq "14. ... /exit was typed exactly once into each" "1 1 1" "$(for g in 425 426 427; do grep -cx /exit "$T_TMP/got-$g"; done | paste -sd " ")"
check "14. controls: all three reach the 15 s timeout" gone_and_retired "$P14J" c-430 40
eq "14. control: plain capture-pane types nothing into the ghost screen (c-638)" "" "$(cat "$T_TMP/got-428" 2>/dev/null)"
eq "14. control: no verify = the dialog holds the claude to the timeout" 0 "$(grep -c CLAUDE-EXITED "$T_TMP/got-429" 2>/dev/null)"
eq "14. control: no verify = the unsubmitted /exit holds the claude to the timeout" 0 "$(grep -c CLAUDE-EXITED "$T_TMP/got-430" 2>/dev/null)"
eq "14. controls: ... each named by its timeout line" 3 "$(log14 | grep -cE 'timeout 15s: c-4(28|29|30) never left pane')"

# --- 15. /exit-clean writes F3 or ok into the tries journal (spec 115 ORC-4) ----------------
G15=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master)
J15="$SPOOL_ROOT/dispatch/attempts.tsv"; mkdir -p "$T_TMP/gh15" "$SPOOL_ROOT/agents" "${J15%/*}"
"${G15[@]}" init -q --bare "$T_TMP/o15.git"
"${G15[@]}" clone -q "$T_TMP/o15.git" "$T_TMP/seed15" 2>/dev/null
"${G15[@]}" -C "$T_TMP/seed15" commit -q --allow-empty -m base && "${G15[@]}" -C "$T_TMP/seed15" push -q origin HEAD:master
cat >"$T_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub: `run list --commit <sha>` -> runs.<sha>, `api .../runs/<id>/jobs` -> jobs.<id>
echo "gh $*" >>"$GH15/calls"
case "$1 $2" in
  "run list") while [ $# -gt 0 ]; do [ "$1" = --commit ] && { cat "$GH15/runs.$2" 2>/dev/null; exit 0; }; shift; done ;;
  api\ *) r="${2#*/runs/}"; cat "$GH15/jobs.${r%%/*}" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$T_TMP/bin/gh"
lane15() {  # ID LANDED(1|0|unpushed) -> pane; the lane's worktree is $T_TMP/w15-<ID>
  local w="$T_TMP/w15-$1" p
  "${G15[@]}" clone -q "$T_TMP/o15.git" "$w" 2>/dev/null
  if [ "$2" != 0 ]; then
    "${G15[@]}" -C "$w" commit -q --allow-empty -m "work of $1"
    [ "$2" = unpushed ] || "${G15[@]}" -C "$w" push -q origin HEAD:master
  fi
  printf '{"id":"%s","worktree":"%s"}\n' "$1" "$w" >"$SPOOL_ROOT/agents/$1.json"
  printf 'T15-%s\tcomplex_coding\tclaude\t%s\t1791600000\trun\tspawn-window\n' "$1" "$1" >>"$J15"
  p="$(t_window "$1@tbox" 'sleep 600')"
  printf '%s\tclaude\t%s\t%s\t20261010T170000Z\n' "$1" "$p" "$w" >>"$SPOOL_ROOT/registry.tsv"
  printf '%s\n' "$p"
}
sha15() { git -C "$T_TMP/w15-$1" rev-parse "HEAD${2:-}"; }
# row15 ID OUTCOME: the id's LAST row closes the spawn row, all 7 fields, source exit-clean
row15() { awk -F'\t' -v id="$1" '$4 == id { r = $0 } END { print r }' "$J15" |
          awk -F'\t' -v id="$1" -v o="$2" 'NF == 7 && $1 == "T15-" id && $2 == "complex_coding" && $3 == "claude" && $5 == 1791600000 && $6 == o && $7 == "exit-clean" { ok = 1 } END { exit !ok }'; }
close15() { CLE_TMUX_PANE="$2" PATH="$T_TMP/bin:$PATH" GH15="$T_TMP/gh15" bash "${3:-$SUT}" --agent "$1" --defer --timeout 5 >"$T_TMP/o15-$1" 2>&1; }
P15R="$(lane15 c-441 1)"; echo 9001 >"$T_TMP/gh15/runs.$(sha15 c-441)"; echo 9000 >"$T_TMP/gh15/runs.$(sha15 c-441 '^')"
echo csi-spl-orc >"$T_TMP/gh15/jobs.9001"
close15 c-441 "$P15R"; eq "15. --defer of a lane whose red job it caused returns 0" 0 "$?"
check "15. a red CI job the lane caused writes fail:F3, source exit-clean" row15 c-441 fail:F3
has "15. ... the output names the red job" "csi-spl-orc" "$(cat "$T_TMP/o15-c-441")"
P15G="$(lane15 c-442 1)"; echo 9002 >"$T_TMP/gh15/runs.$(sha15 c-442)"
close15 c-442 "$P15G"; check "15. a green lane writes ok" row15 c-442 ok
has "15. ... gh was asked for the jobs of its run" "runs/9002/jobs" "$(cat "$T_TMP/gh15/calls")"
P15N="$(lane15 c-443 0)"; close15 c-443 "$P15N"; check "15. a lane with no commit of its own writes fail:F3" row15 c-443 fail:F3
P15U="$(lane15 c-444 unpushed)"; close15 c-444 "$P15U"; check "15. a lane whose work is unpushed (--landed non-zero) writes fail:F3" row15 c-444 fail:F3
P15P="$(lane15 c-445 1)"; echo 9005 >"$T_TMP/gh15/runs.$(sha15 c-445)"; echo 9004 >"$T_TMP/gh15/runs.$(sha15 c-445 '^')"
echo csi-spl-wui >"$T_TMP/gh15/jobs.9005"; echo csi-spl-wui >"$T_TMP/gh15/jobs.9004"
close15 c-445 "$P15P"; check "15. a job already red on the parent (another lane's red) writes ok" row15 c-445 ok
mkdir -p "$T_TMP/pre15/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre15/lib"
ln -s "$(dirname "$SUT")/git-fetch-fresh.sh" "$T_TMP/pre15/scripts/git-fetch-fresh.sh"
sed 's/"\$js" "\$outcome" exit-clean >&9/"$js" "$outcome" >\&9/' "$SUT" >"$T_TMP/pre15/scripts/tmux-close-window.sh"
hasnt "15. control: the source field is spliced out" '"$outcome" exit-clean >&9' "$(cat "$T_TMP/pre15/scripts/tmux-close-window.sh")"
P15C="$(lane15 c-446 1)"; echo 9006 >"$T_TMP/gh15/runs.$(sha15 c-446)"
close15 c-446 "$P15C" "$T_TMP/pre15/scripts/tmux-close-window.sh"
eq "15. control: a row with no source field turns the check red" red "$(row15 c-446 ok && echo green || echo red)"
eq "15. control: ... red for the empty source alone (outcome ok)" "ok []" "$(awk -F'\t' '$4 == "c-446" { r = $6 " [" $7 "]" } END { print r }' "$J15")"
t_done
