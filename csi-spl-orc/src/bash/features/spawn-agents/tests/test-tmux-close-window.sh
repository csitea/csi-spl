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
#      nor one whose turn waits on a task (`● [..] Task completion wait running`)
#      under an idle `? for shortcuts` footer (a-899, 2026-10-10); one idle with
#      only a timer row left still gets /exit
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
#  16. SPL-2095 (m-595, 2026-10-16): a lane's SELF-close (its own pane in the
#      window, or its own id) is refused, exit 5, while its push-master status
#      reads RUNNING, and without an ACCEPTED; after the ACCEPTED with the push
#      ended it closes; the orchestrator's close of a lane in that state is not
#      gated. Control: m-595's exact sequence on the script with the gate
#      spliced out closes the window
#  17. SPL-2459 (a-520, 2026-10-17): one `--agent <ID> --retire` run closes
#      EVERY window that carries the id (an old shell window too) and retires
#      it once, with all its registry rows (12 after a day of restarts); a
#      window of another id stays. A --defer self-teardown also closes an old
#      shell window of its id, but never one whose pane still runs an agent
#      CLI (a rotation's new seat): that stays and the id is not retired
#
# The sections run as parallel jobs (r01-03, SPL-2084: 166 s serial, ~94% of
# it idle on the closer's timeouts and the controls' fixed waits). Each job
# gets its OWN sandbox: SPOOL_ROOT, registry, CLOSE_LOG_DIR and private tmux
# server, so a log or a registry row of one job can never satisfy another's
# assertion. A job that does not finish within TCW_JOB_MAX seconds (default
# 150) is killed and counted as a failure; one that dies before its end too.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
TCW_TEST_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
t_sandbox
SUT="$T_SCRIPTS/tmux-close-window.sh"
unset TMUX TMUX_PANE CLE_TMUX_PANE GRK_TMUX_PANE AGY_TMUX_PANE QWN_TMUX_PANE MCP_BOT_AGENT_ID \
      CLE_TMUX_SOCK GRK_TMUX_SOCK AGY_TMUX_SOCK QWN_TMUX_SOCK
J_DIR="$T_TMP/jobs" FAKES="$T_TMP/fakes"; mkdir -p "$J_DIR" "$FAKES"

# --- the fake CLIs, written once and copied into every job's sandbox -----------------------
cat >"$FAKES/agy" <<'FAKEAGY'
#!/usr/bin/env bash
# fake agy: an input box, reads lines into $1, leaves on /exit; $2=busy keeps the
# screen moving, $2=paused holds a static mid-turn screen (real agy's footers)
if [ "${2:-}" = busy ]; then n=0; while :; do n=$((n + 1)); printf 'working %s\n>\nesc to cancel\n' "$n"; sleep 0.2; done; fi
# $2=taskwait: the turn blocks on a task under an idle-looking footer (agy 1.3.3,
# a-899 2026-10-10); $2=timer: a finished turn that left a timer running
if [ "${2:-}" = paused ]; then printf '%s\n' 'Generating...' '-----' '>' '-----' 'esc to cancel'
elif [ "${2:-}" = taskwait ]; then printf '%s\n' '-----' '>' '-----' '  ● [22:52:56] Task completion wait running' \
  '  ● [22:52:52] sleep 25; echo done-sleeping running' '-----' '? for shortcuts      Gemini 3.1 Pro · high · 2 task(s) · /tasks'
elif [ "${2:-}" = timer ]; then printf '%s\n' '  scheduled.' '-----' '>' '-----' '  ● [22:59:50] 300s timer running' '-----' \
  '? for shortcuts      Gemini 3.1 Pro · high · 1 task(s) · /tasks'
else printf '%s\n' '-----' '>' '-----' '? for shortcuts'; fi
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$1"
  [ "$line" = /exit ] && { echo AGY-EXITED >>"$1"; exit 0; }
done
sleep 600
FAKEAGY
chmod +x "$FAKES/agy"
# The pane as spawn-agy.sh leaves it: a launcher shell whose command line names
# the agy path outlives agy (argv[0] of agy itself is `agy`).
cat >"$FAKES/agy-pane" <<'FAKEPANE'
#!/bin/sh
bash -c 'exec -a agy bash "$0" "$1" "$2"' "$1" "$2" "${3:-}"
sleep 600
FAKEPANE
cat >"$FAKES/claude-fake" <<'FAKECLAUDE'
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
chmod +x "$FAKES/claude-fake"
cat >"$FAKES/claude-pane" <<'FAKEPANE'
#!/bin/sh
bash -c 'exec -a claude bash "$0" "$1" "$2"' "$1" "$2" "${3:-}"
sleep 600
FAKEPANE

# --- per-job fixtures ------------------------------------------------------------------------
box() {  # a fresh sandbox + private tmux server; VICTIM is the active window
  t_sandbox
  export CLOSE_LOG_DIR="$T_TMP/logs" SPOOL_BOX_TAG=tbox; mkdir -p "$CLOSE_LOG_DIR" "$T_TMP/bin"
  cp -a "$FAKES/." "$T_TMP/bin/"
  t_tmux
  VICTIM="$(t_window 'tbox: CLE-09 someone else' 'sleep 600')"
  tmux -S "$SPOOL_TMUX_SOCKET" select-window -t "$VICTIM"
  # Sections 1..15 close finished lanes: each id has its ACCEPTED (the
  # self-close gate, section 16). Section 16's own ids (m-59x) get none.
  local id
  for id in $(grep -oE '\b([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)\b' "$TCW_TEST_SELF" | sort -u); do t_accepted "$id"; done
}
alive() { tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -x "$1" >/dev/null; }
wait_gone() { for _ in $(seq 1 "$2"); do alive "$1" || return 0; sleep 0.5; done; return 1; }
# A fake CLI pane has drawn its first screen (its process runs under its own
# name by then): the event the old fixed `sleep 1` waited for.
drawn() {  # PANE NEEDLE
  for _ in $(seq 1 100); do tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$1" 2>/dev/null | grep -F "$2" >/dev/null && return 0; sleep 0.1; done
  return 1
}
in_agy_session() {  # run CMD... the way agy runs a command: own session, killed on return
  setsid -f -w bash -c '"$@"; kill -KILL -- -$$' _ "$@" >/dev/null 2>&1; return 0
}
got_exit() { for _ in $(seq 1 "$2"); do grep -q CLAUDE-EXITED "$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
spliced() {  # DIR: an empty copy dir beside a lib/ link (the SUT loads lib/ relative to itself)
  mkdir -p "$1/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$1/lib"
}

# --- 1..4. no source, --agent + --dry-run, --agent closes that window only, registry mismatch --
s01() {
  box
  bash "$SUT" >"$T_TMP/o" 2>&1; eq "1. no ownership source is refused (3)" 3 "$?"
  check "1. the ACTIVE window survives" alive "$VICTIM"
  P7="$(t_window 'tbox: CLE-07 wip' 'sleep 600')"
  out="$(bash "$SUT" --agent cle-7 --dry-run 2>&1)"; eq "2. --agent --dry-run exits 0" 0 "$?"
  has "2. it resolves the tagged window of CLE-07" "CLE-07" "$out"
  check "2. --dry-run kills nothing" alive "$P7"
  bash "$SUT" --agent CLE-07 >"$T_TMP/o" 2>&1; eq "3. --agent CLE-07 exits 0" 0 "$?"
  check "3. CLE-07's window is gone" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P7'"
  check "3. the sibling survives" alive "$VICTIM"
  printf 'GRK-05\tgrok\t%s\t/x\t20260101T000000Z\n' "$VICTIM" >"$SPOOL_ROOT/registry.tsv"
  bash "$SUT" --agent GRK-05 >"$T_TMP/o" 2>&1; rc=$?
  [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; eq "4. a pane whose window names another id is refused" 0 "$?"
  check "4. ... and nothing was closed" alive "$VICTIM"
}

# --- 5. --defer --------------------------------------------------------------------------
s05() {
  box
  P8="$(t_window 'tbox: QWN-08 done' 'sleep 600')"
  QWN_TMUX_PANE="$P8" bash "$SUT" --agent QWN-08 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "5. --defer returns 0 at once" 0 "$?"
  has "5. it names the scheduled target" "scheduled defer-close" "$(cat "$T_TMP/o")"
  wait_gone "$P8" 20
  check "5. the deferred close lands" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P8'"
  has "5. the log records the target" "closing window" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"
  check "5. the victim survives the whole run" alive "$VICTIM"
}

# --- 6. T-EXITCLEAN-RETIRING (spec 060 FR-016) ------------------------------------------
s06() {
  box
  NEWP="$(t_window 'CLE-001@tbox' 'sleep 600')"
  OLDP="$(t_window 'CLE-001-0405Z-retiring' 'sleep 600')"
  out="$(bash "$SUT" --agent CLE-001 --dry-run 2>&1)"
  has "6. control: --agent CLE-001 from outside resolves to the NEW window" "$NEWP" "$out"
  out="$(CLE_TMUX_PANE="$OLDP" bash "$SUT" --agent CLE-001 --dry-run 2>&1)"
  has "6. from the retiring pane it resolves to the retiring window" "$OLDP" "$out"
  hasnt "6. ... not the new one" "$NEWP" "$out"
  CLE_TMUX_PANE="$OLDP" bash "$SUT" --agent CLE-001 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "6. --defer from the retiring pane returns 0" 0 "$?"
  wait_gone "$OLDP" 20
  check "6. the retiring window is closed" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$OLDP'"
  check "6. the NEW window survives" alive "$NEWP"
  CLE_TMUX_PANE="$VICTIM" bash "$SUT" --agent CLE-001 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "6. --defer from another window's pane is refused (4)" 4 "$?"
  check "6. ... and the new window survives" alive "$NEWP"
}

# --- 7. spec 061 ids resolve exactly (/exit-clean left c-097's window open) ---------------
s07() {
  box
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
  # Control: the same script with the pre-c0ec0735 norm_id spliced in.
  spliced "$T_TMP/old"
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
}

# --- 8. the closer survives agy killing the command's session ----------------------------
# The control and the fix run side by side; the control's window is read
# 5 s after its closer started (its timeout is 4 s).
s08() {
  box
  P8B="$(t_window 'q-201@tbox' 'sleep 600')"
  t0=$SECONDS
  in_agy_session env TCW_NO_SETSID=1 QWN_TMUX_PANE="$P8B" bash "$SUT" --agent q-201 --defer --timeout 4
  P8C="$(t_window 'q-202@tbox' 'sleep 600')"
  in_agy_session env QWN_TMUX_PANE="$P8C" bash "$SUT" --agent q-202 --defer --timeout 4
  check "8. the detached closer survives the session kill and closes the window" wait_gone "$P8C" 20
  while (( SECONDS < t0 + 6 )); do sleep 0.5; done
  check "8. control: the in-session closer dies with agy's session (window stays)" alive "$P8B"
  check "8. ... the victim survives" alive "$VICTIM"
}

# --- 9. agy: the closer types /exit once agy is idle ---------------------------------------
# The pane as spawn-agy.sh leaves it: a launcher shell whose command line names
# the agy path outlives agy (argv[0] of agy itself is `agy`).
s09() {
  box
  P9="$(t_window 'a-301@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-301")"
  drawn "$P9" '? for shortcuts'
  in_agy_session env AGY_TMUX_PANE="$P9" bash "$SUT" --agent a-301 --defer --timeout 60
  check "9. the agy window closes well before the 60 s timeout" wait_gone "$P9" 30
  has "9. agy got /exit typed and left by itself" "AGY-EXITED" "$(cat "$T_TMP/got-301" 2>/dev/null)"
  has "9. the log names the /exit it typed" "typing /exit" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"
}

# --- 10. controls: no closer = no close; busy = no /exit ------------------------------------
# One sandbox: the idle agy without a closer shares its tmux server with the
# four closers, which run side by side, and must outlive them all.
s10_busy() {
  P10B="$(t_window 'a-303@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-303 busy")"
  drawn "$P10B" 'esc to cancel'
  in_agy_session env AGY_TMUX_PANE="$P10B" bash "$SUT" --agent a-303 --defer --timeout 5
  check "10. a busy agy is closed only by the timeout" wait_gone "$P10B" 30
  eq "10. control: ... and never got /exit while busy" "" "$(cat "$T_TMP/got-303" 2>/dev/null)"
}
s10_paused() {
  P10C="$(t_window 'a-304@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-304 paused")"
  drawn "$P10C" 'esc to cancel'
  in_agy_session env AGY_TMUX_PANE="$P10C" bash "$SUT" --agent a-304 --defer --timeout 6
  check "10. an agy paused mid-turn is closed only by the timeout" wait_gone "$P10C" 30
  eq "10. control: ... and never got /exit on a static mid-turn screen" "" "$(cat "$T_TMP/got-304" 2>/dev/null)"
}
s10_taskwait() {
  P10D="$(t_window 'a-305@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-305 taskwait")"
  drawn "$P10D" '? for shortcuts'
  in_agy_session env AGY_TMUX_PANE="$P10D" bash "$SUT" --agent a-305 --defer --timeout 6
  check "10. an agy waiting on its task (\`? for shortcuts\` footer) is closed only by the timeout" wait_gone "$P10D" 30
  eq "10. ... and never got /exit mid-turn (a-899, 2026-10-10)" "" "$(cat "$T_TMP/got-305" 2>/dev/null)"
}
s10_timer() {
  P10E="$(t_window 'a-306@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-306 timer")"
  drawn "$P10E" '? for shortcuts'
  in_agy_session env AGY_TMUX_PANE="$P10E" bash "$SUT" --agent a-306 --defer --timeout 120
  check "10. an agy idle with a timer left running closes well before the timeout" wait_gone "$P10E" 120
  has "10. ... it got /exit and left by itself (a timer row alone is not busy)" "AGY-EXITED" "$(cat "$T_TMP/got-306" 2>/dev/null)"
}
s10() {
  box
  P10="$(t_window 'a-302@tbox' "sh $T_TMP/bin/agy-pane $T_TMP/bin/agy $T_TMP/got-302")"
  sub "10.2" s10_busy; sub "10.3" s10_paused; sub "10.4" s10_taskwait; sub "10.5" s10_timer
  sleep 6
  check "10. control: an idle agy with no closer scheduled stays" alive "$P10"
  eq "10. control: ... and nothing was typed into it" "" "$(cat "$T_TMP/got-302" 2>/dev/null)"
  sub_wait
  check "10. the idle agy without a closer is still there" alive "$P10"
}

# --- 11. the lifetime markers (specs/102 4.3) --------------------------------------------------
s11() {
  box
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
}

# --- 12. a rotation's deferred close never kills the fresh seat (2026-10-07 09:22:21Z) ----
# The old c-002 ran `sudo -u <owner> bash tmux-close-window.sh --agent c-002
# --defer`: sudo strips the pane vars (the suite unset them at the top), so
# --agent resolved to the NEW c-002 and the closer killed it at its timeout.
seat12() {  # RETIRING-NAME: the fresh c-002 seat with its spawn row -> NEW12, and a retiring window -> OLD12
  box
  NEW12="$(t_window 'c-002@tbox' 'sleep 600')"
  printf 'c-002\tclaude\t%s\t/x\t20261007T092100Z\n' "$NEW12" >>"$SPOOL_ROOT/registry.tsv"  # the fresh seat's spawn row
  OLD12="$(t_window "$1" 'sleep 600')"
}
s12() {
  seat12 'c-002-0921Z-retiring'
  bash "$SUT" --agent c-002 --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. --defer by id with no caller pane is refused (3)" 3 "$?"
  has "12. ... and says why" "without the caller's own live pane" "$(cat "$T_TMP/o")"
  hasnt "12. ... and schedules nothing" "scheduled defer-close" "$(cat "$T_TMP/o")"
  CLE_TMUX_PANE=%99999 bash "$SUT" --agent c-002 --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. a stale caller pane proves nothing either (3)" 3 "$?"
  sleep 5
  check "12. the fresh c-002 survives past the timeout" alive "$NEW12"
  check "12. ... and so does the retiring one (closed nothing)" alive "$OLD12"
}
s12b() {
  seat12 'c-002-0921Z-retiring'
  bash "$SUT" --pane "$OLD12" --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. --pane is the sudo-proof --defer (0)" 0 "$?"
  check "12. ... it closes the retiring window" wait_gone "$OLD12" 20
  check "12. ... and the fresh c-002 survives" alive "$NEW12"
}
s12c() {  # Control: the same script with the guard spliced out kills the fresh seat.
  seat12 'c-002-1021Z-retiring'
  spliced "$T_TMP/pre"
  awk '/^# A --defer is a self-teardown/ { skip = 1 } skip { if (/^fi$/) skip = 0; next } { print }' "$SUT" >"$T_TMP/pre/scripts/tmux-close-window.sh"
  hasnt "12. control: the guard is spliced out" "without the caller's own live pane" "$(cat "$T_TMP/pre/scripts/tmux-close-window.sh")"
  has "12. control: the old code resolves --agent c-002 to the fresh seat" "pane=$NEW12 " "$(bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent c-002 --defer --dry-run 2>&1)"
  bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent c-002 --defer --timeout 2 >"$T_TMP/o" 2>&1; eq "12. control: the old code schedules the close (0)" 0 "$?"
  check "12. control: the old code kills the FRESH c-002" wait_gone "$NEW12" 20
  check "12. control: ... and leaves the retiring window open" alive "$OLD12"
}

# --- 13. --rebirth ends the session: /exit typed once when idle, window kept --------------
claude13() {  # ID [MODE] -> pane of a fake claude, drawn
  local p
  p="$(t_window "$1@tbox" "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-${1#c-} ${2:-}")"
  drawn "$p" "$(printf '\342\235\257')" >/dev/null
  printf '%s\n' "$p"
}
s13() {
  box
  P13="$(claude13 c-415)"
  printf 'c-415\tclaude\t%s\t/x\t20261007T130000Z\n' "$P13" >>"$SPOOL_ROOT/registry.tsv"
  in_agy_session env CLE_TMUX_PANE="$P13" bash "$SUT" --agent c-415 --rebirth --timeout 60
  check "13. --rebirth writes lifetime/rebirth" test -s "$SPOOL_ROOT/c-415/lifetime/rebirth"
  check "13. the idle harness gets /exit typed and leaves" got_exit "$T_TMP/got-415" 120
  sleep 3
  eq "13. ... /exit was typed exactly once" 1 "$(grep -cx /exit "$T_TMP/got-415" 2>/dev/null)"
  check "13. the window stays (the watchdog restarts the id in it)" alive "$P13"
  check "13. the registry row stays (nothing retired)" grep -q "^c-415	claude	$P13	" "$SPOOL_ROOT/registry.tsv"
  has "13. the log names the /exit it typed" "typing /exit (try 1)" "$(cat "$CLOSE_LOG_DIR"/rebirth-exit-*.log 2>/dev/null)"
}
s13b() {
  box
  P13B="$(claude13 c-416 busy)"
  in_agy_session env CLE_TMUX_PANE="$P13B" bash "$SUT" --agent c-416 --rebirth --timeout 6
  sleep 8
  eq "13. control: a busy pane never gets /exit" "" "$(cat "$T_TMP/got-416" 2>/dev/null)"
  check "13. control: ... and its window stays" alive "$P13B"
}
s13c() {  # Control: the old marker-only --rebirth (the fork spliced out) types nothing.
  box
  spliced "$T_TMP/pre13"
  sed 's/^if \[\[ "\$REBIRTH" -eq 1 \]\]; then rebirth_closer; exit 0; fi$/if [[ "$REBIRTH" -eq 1 ]]; then exit 0; fi/' "$SUT" >"$T_TMP/pre13/scripts/tmux-close-window.sh"
  hasnt "13. control: the fork is spliced out" "then rebirth_closer;" "$(cat "$T_TMP/pre13/scripts/tmux-close-window.sh")"
  P13C="$(claude13 c-417)"
  in_agy_session env CLE_TMUX_PANE="$P13C" bash "$T_TMP/pre13/scripts/tmux-close-window.sh" --agent c-417 --rebirth --timeout 20
  sleep 8
  eq "13. control: without the fork the idle session is never ended" "" "$(cat "$T_TMP/got-417" 2>/dev/null)"
}
# A human looking at the window: an attached client whose current window it is.
attach_human() {  # WINDOW-TARGET -> a client on it (script gives tmux a tty; CI has no TERM, and tmux refuses to attach without one)
  setsid -f script -qfc "TERM=xterm tmux -S '$SPOOL_TMUX_SOCKET' attach -t '$1'" /dev/null </dev/null >/dev/null 2>&1
  for _ in $(seq 1 20); do [ -n "$(tmux -S "$SPOOL_TMUX_SOCKET" list-clients -F x 2>/dev/null)" ] && return 0; sleep 0.25; done
  return 1
}
detach_humans() { tmux -S "$SPOOL_TMUX_SOCKET" list-clients -F '#{client_tty}' | while read -r c; do tmux -S "$SPOOL_TMUX_SOCKET" detach-client -t "$c"; done; }
s13d() {
  box
  P13D="$(claude13 c-418)"
  W13D="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P13D" '#{session_name}:#{window_index}')"
  check "13. a human client is attached to c-418's window" attach_human "$W13D"
  sleep 1
  in_agy_session env CLE_TMUX_PANE="$P13D" WD_HUMAN_IDLE=120 bash "$SUT" --agent c-418 --rebirth --timeout 40
  # Poll for the line, never a fixed sleep: on a loaded CI runner the closer took
  # longer than 8 s to read the idle screen 3 polls running (wf 10, 2 of 4 reds).
  got_wait() { for _ in $(seq 1 60); do grep -q 'a human is active in this window' "$CLOSE_LOG_DIR"/rebirth-exit-*.log 2>/dev/null && return 0; sleep 0.5; done; return 1; }
  check "13. ... and the log says /exit waits" got_wait
  eq "13. a human active in THAT window: nothing typed" "" "$(cat "$T_TMP/got-418" 2>/dev/null)"
  detach_humans
}
s13e() {
  box
  P13E="$(claude13 c-419)"
  check "13. a human client is attached to ANOTHER window of the session" attach_human "$VICTIM"
  sleep 1
  in_agy_session env CLE_TMUX_PANE="$P13E" WD_HUMAN_IDLE=120 bash "$SUT" --agent c-419 --rebirth --timeout 60
  check "13. a human in another window: the idle harness gets /exit and leaves" got_exit "$T_TMP/got-419" 120
  sleep 3
  eq "13. ... /exit was typed exactly once" 1 "$(grep -cx /exit "$T_TMP/got-419" 2>/dev/null)"
  detach_humans
}

# --- 14. a lane that ran /exit-clean itself is closed and retired (2026-10-08/09) --------
# c-585 / c-602 / c-623 sent their result, scheduled the close and sat idle at
# an empty prompt: nobody typed /exit, so the CLI never left and the window
# waited out the timeout (or a human closed it). The closer now types /exit
# into ANY harness idle at an empty prompt; the timeout still kills a CLI
# that never leaves, and retires the id with one log line.
retired() { ! grep -q "^$1	" "$SPOOL_ROOT/registry.tsv" && compgen -G "$SPOOL_ROOT/.retired/$1.*" >/dev/null; }
gone_and_retired() { for _ in $(seq 1 "$3"); do ! alive "$1" && retired "$2" && return 0; sleep 0.5; done; return 1; }
lane14() {  # ID [MODE] -> pane of a fake claude lane with its registry row
  local p
  p="$(claude13 "$@")"
  printf '%s\tclaude\t%s\t/x\t20261009T040000Z\tc-001\n' "$1" "$p" >>"$SPOOL_ROOT/registry.tsv"
  printf '%s\n' "$p"
}
log14() { cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null; }
s14() {
  box
  P14="$(lane14 c-421)"
  CLE_TMUX_PANE="$P14" bash "$SUT" --agent c-421 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1; eq "14. --defer --retire returns 0 at once" 0 "$?"
  check "14. the idle claude gets /exit typed and leaves by itself" got_exit "$T_TMP/got-421" 40
  check "14. ... then its window is closed and c-421 retired, well before the 60 s timeout" gone_and_retired "$P14" c-421 20
  has "14. the log names the /exit it typed" "idle at an empty prompt: typing /exit (try 1)" "$(log14)"
}
s14b() {  # Control: the closer as it was (/exit typed into agy only) leaves the idle lane open.
  box
  spliced "$T_TMP/pre14"
  awk '{ print } /^type_exit_when_idle\(\) \{$/ { print "  (( ${#AGY_PIDS[@]} > 0 )) || return 0" }' "$SUT" >"$T_TMP/pre14/scripts/tmux-close-window.sh"
  has "14. control: the old agy-only guard is spliced in" '(( ${#AGY_PIDS[@]} > 0 )) || return 0' "$(cat "$T_TMP/pre14/scripts/tmux-close-window.sh")"
  P14B="$(lane14 c-422)"
  CLE_TMUX_PANE="$P14B" bash "$T_TMP/pre14/scripts/tmux-close-window.sh" --agent c-422 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
  sleep 15
  eq "14. control: the old closer types nothing into the idle claude" "" "$(cat "$T_TMP/got-422" 2>/dev/null)"
  check "14. control: ... its window is still open" alive "$P14B"
  check "14. control: ... and c-422 is not retired" grep -q "^c-422	" "$SPOOL_ROOT/registry.tsv"
}
s14c() {  # A CLI that never leaves (a running turn: no /exit is typed) is closed by the timeout.
  box
  P14C="$(lane14 c-423 busy)"
  CLE_TMUX_PANE="$P14C" bash "$SUT" --agent c-423 --defer --retire --timeout 4 >"$T_TMP/o" 2>&1
  check "14. a CLI that never leaves: the timeout closes the window and retires c-423" gone_and_retired "$P14C" c-423 30
  eq "14. ... nothing was typed into the running turn" "" "$(cat "$T_TMP/got-423" 2>/dev/null)"
  eq "14. ... with ONE log line naming it" 1 "$(log14 | grep -c 'timeout 4s: c-423 never left pane .* and retiring c-423$')"
}
s14d() {  # --retire with no id to retire: refused before anything is closed (the orchestrator's side note).
  box
  P14D="$(lane14 c-424)"
  bash "$SUT" --pane "$P14D" --retire >"$T_TMP/o" 2>&1; eq "14. --retire without --agent is refused (2)" 2 "$?"
  check "14. ... and closes nothing" alive "$P14D"
  spliced "$T_TMP/pre14r"
  awk '/^# --retire needs the id to retire/ { skip = 1 } skip { if (/^fi$/) skip = 0; next } { print }' "$SUT" >"$T_TMP/pre14r/scripts/tmux-close-window.sh"
  bash "$T_TMP/pre14r/scripts/tmux-close-window.sh" --pane "$P14D" --retire >"$T_TMP/o" 2>&1
  check "14. control: the old code kills the window ..." bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P14D'"
  check "14. control: ... and leaves c-424 unretired" grep -q "^c-424	" "$SPOOL_ROOT/registry.tsv"
}
# c-638 (2026-10-09): a faint prompt suggestion `❯ /exit` read as typed input.
# Background work dialog / unsubmitted /exit: Enter after our own /exit.
s14e() {
  box
  P14E="$(lane14 c-425 ghost)"; P14F="$(lane14 c-426 bgwork)"; P14G="$(lane14 c-427 deaf)"
  CLE_TMUX_PANE="$P14E" bash "$SUT" --agent c-425 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
  CLE_TMUX_PANE="$P14F" bash "$SUT" --agent c-426 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
  CLE_TMUX_PANE="$P14G" bash "$SUT" --agent c-427 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
  check "14. a ghost /exit suggestion: /exit is typed and the claude leaves" got_exit "$T_TMP/got-425" 40
  check "14. ... its window is closed and c-425 retired before the timeout" gone_and_retired "$P14E" c-425 20
  has "14. ... and the log says the typed /exit took" "the typed /exit took" "$(log14)"
  check "14. the background-work dialog: Enter on 'Exit and stop tasks', the claude leaves" got_exit "$T_TMP/got-426" 40
  check "14. ... its window is closed and c-426 retired before the timeout" gone_and_retired "$P14F" c-426 20
  has "14. ... the log names the dialog" "the exit asks about background work: Exit and stop tasks: Enter (1)" "$(log14)"
  check "14. an unsubmitted /exit: Enter again, the claude leaves" got_exit "$T_TMP/got-427" 40
  check "14. ... its window is closed and c-427 retired before the timeout" gone_and_retired "$P14G" c-427 20
  has "14. ... the log names the unsubmitted /exit" "the typed /exit sits unsubmitted: Enter (1)" "$(log14)"
  eq "14. ... /exit was typed exactly once into each" "1 1 1" "$(for g in 425 426 427; do grep -cx /exit "$T_TMP/got-$g"; done | paste -sd " ")"
}
# Controls: the ghost under plain capture-pane, the two others with the verify
# step spliced out (EXIT_ENTERS < 0: never an Enter after /exit).
s14f() {
  box
  spliced "$T_TMP/pre14g"
  sed 's/capture-pane -p -e -t "\$1" 2>\/dev\/null | screen_drop_faint |/capture-pane -p -t "$1" 2>\/dev\/null |/' "$SUT" >"$T_TMP/pre14g/scripts/tmux-close-window.sh"
  hasnt "14. control: plain capture-pane is spliced back" "| screen_drop_faint |" "$(cat "$T_TMP/pre14g/scripts/tmux-close-window.sh")"
  spliced "$T_TMP/pre14v"
  sed 's/EXIT_ENTERS < 3 \&\& SECONDS/EXIT_ENTERS < 0 \&\& SECONDS/' "$SUT" >"$T_TMP/pre14v/scripts/tmux-close-window.sh"
  has "14. control: the verify step is spliced out" "EXIT_ENTERS < 0 && SECONDS" "$(cat "$T_TMP/pre14v/scripts/tmux-close-window.sh")"
  P14H="$(lane14 c-428 ghost)"; P14I="$(lane14 c-429 bgwork)"; P14J="$(lane14 c-430 deaf)"
  CLE_TMUX_PANE="$P14H" bash "$T_TMP/pre14g/scripts/tmux-close-window.sh" --agent c-428 --defer --retire --timeout 15 >"$T_TMP/o" 2>&1
  CLE_TMUX_PANE="$P14I" bash "$T_TMP/pre14v/scripts/tmux-close-window.sh" --agent c-429 --defer --retire --timeout 15 >"$T_TMP/o" 2>&1
  CLE_TMUX_PANE="$P14J" bash "$T_TMP/pre14v/scripts/tmux-close-window.sh" --agent c-430 --defer --retire --timeout 15 >"$T_TMP/o" 2>&1
  # All three, each polled up to 60 s: one 20 s wait on c-430 alone went red 3 of
  # 30 runs on a box capped at 4 CPUs (spec 133 round 7).
  all3_timed_out() { gone_and_retired "$P14H" c-428 120 && gone_and_retired "$P14I" c-429 120 && gone_and_retired "$P14J" c-430 120; }
  check "14. controls: all three reach the 15 s timeout" all3_timed_out
  eq "14. control: plain capture-pane types nothing into the ghost screen (c-638)" "" "$(cat "$T_TMP/got-428" 2>/dev/null)"
  eq "14. control: no verify = the dialog holds the claude to the timeout" 0 "$(grep -c CLAUDE-EXITED "$T_TMP/got-429" 2>/dev/null)"
  eq "14. control: no verify = the unsubmitted /exit holds the claude to the timeout" 0 "$(grep -c CLAUDE-EXITED "$T_TMP/got-430" 2>/dev/null)"
  eq "14. controls: ... each named by its timeout line" 3 "$(log14 | grep -cE 'timeout 15s: c-4(28|29|30) never left pane')"
}

# --- 15. /exit-clean writes F3 or ok into the tries journal (spec 115 ORC-4) ----------------
s15() {
  box
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
  spliced "$T_TMP/pre15"
  ln -s "$(dirname "$SUT")/git-fetch-fresh.sh" "$T_TMP/pre15/scripts/git-fetch-fresh.sh"
  sed 's/"\$js" "\$outcome" exit-clean >&9/"$js" "$outcome" >\&9/' "$SUT" >"$T_TMP/pre15/scripts/tmux-close-window.sh"
  hasnt "15. control: the source field is spliced out" '"$outcome" exit-clean >&9' "$(cat "$T_TMP/pre15/scripts/tmux-close-window.sh")"
  P15C="$(lane15 c-446 1)"; echo 9006 >"$T_TMP/gh15/runs.$(sha15 c-446)"
  close15 c-446 "$P15C" "$T_TMP/pre15/scripts/tmux-close-window.sh"
  eq "15. control: a row with no source field turns the check red" red "$(row15 c-446 ok && echo green || echo red)"
  eq "15. control: ... red for the empty source alone (outcome ok)" "ok []" "$(awk -F'\t' '$4 == "c-446" { r = $6 " [" $7 "]" } END { print r }' "$J15")"
}

# --- 16. a lane cannot close itself while its push runs or before ACCEPTED (SPL-2095) ------
# m-595 (2026-10-16 01:27:48Z): started do_spl_push_master, sent "push in
# progress", ran its own /kill-your-self -> `--agent m-595 --defer --retire`
# with NO ACCEPTED; closed and retired at 01:29:11Z, its push RUNNING, refused
# at 01:34:50Z, unseen for 2.5 h. Its state here: lifetime/push-master/status
# RUNNING, no ACCEPTED in inbox/archive.
lane16() {  # ID PUSH-FIRST-LINE -> pane; the lane has no ACCEPTED
  local p
  rm -rf "${SPOOL_ROOT:?}/$1"; mkdir -p "$SPOOL_ROOT/$1/lifetime/push-master" "$SPOOL_ROOT/$1/inbox"
  printf '%s\nsince=2026-10-16T01:27:48Z\n' "$2" >"$SPOOL_ROOT/$1/lifetime/push-master/status"
  p="$(t_window "$1@tbox" 'sleep 600')"
  printf '%s\tmistral\t%s\t/x\t20261016T010000Z\tc-001\n' "$1" "$p" >>"$SPOOL_ROOT/registry.tsv"
  printf '%s\n' "$p"
}
# The push worker holds push-master/lock for its whole life (spl-push-master.func.sh):
# a live worker is a process holding it, here a sleep that took the lock.
hold16() {  # ID -> pid of the holder, once it holds the lock
  local l="$SPOOL_ROOT/$1/lifetime/push-master/lock" pid
  ( exec 9>"$l"; flock 9; exec sleep 600 ) >/dev/null 2>&1 &
  pid="$!"
  for _ in $(seq 1 50); do flock -n "$l" true 2>/dev/null || break; sleep 0.1; done
  printf '%s\n' "$pid"
}
s16() {
  box
  P16="$(lane16 m-595 RUNNING)"
  H16="$(hold16 m-595)"
  MISTRAL_TMUX_PANE="$P16" bash "$SUT" --agent m-595 --defer --retire --timeout 3 >"$T_TMP/o" 2>&1
  eq "16. self-close with its push RUNNING is refused (5)" 5 "$?"
  has "16. ... the one line names the running push" "REFUSED self-close of m-595: its push is RUNNING since 2026-10-16T01:27:48Z" "$(cat "$T_TMP/o")"
  eq "16. ... it is one line" 1 "$(wc -l <"$T_TMP/o")"
  hasnt "16. ... and schedules no close" "scheduled defer-close" "$(cat "$T_TMP/o")"
  check "16. ... writes no lifetime/done" test ! -e "$SPOOL_ROOT/m-595/lifetime/done"
  kill "$H16" 2>/dev/null
  printf 'PUSHED abc1234\nfinished=2026-10-16T01:40:00Z\n' >"$SPOOL_ROOT/m-595/lifetime/push-master/status"
  MISTRAL_TMUX_PANE="$P16" bash "$SUT" --agent m-595 --defer --retire --timeout 3 >"$T_TMP/o" 2>&1
  eq "16. self-close with no ACCEPTED is refused (5)" 5 "$?"
  has "16. ... the line names the missing ACCEPTED" "REFUSED self-close of m-595: exit-clean refused: no ACCEPTED" "$(cat "$T_TMP/o")"
  SPOOL_AGENT_ID=m-595 bash "$SUT" --agent m-595 >"$T_TMP/o" 2>&1
  eq "16. an immediate self-close by the caller's own id (no pane var) is refused too (5)" 5 "$?"
  sleep 1
  check "16. ... the lane's window is still open" alive "$P16"
  check "16. ... and m-595 is not retired" grep -q "^m-595	" "$SPOOL_ROOT/registry.tsv"
  # The orchestrator closes a lane in the same state (push RUNNING, no ACCEPTED).
  P16O="$(lane16 m-596 RUNNING)"
  PORCH="$(t_window 'c-001@tbox' 'sleep 600')"
  CLE_TMUX_PANE="$PORCH" SPOOL_AGENT_ID=c-001 bash "$SUT" --agent m-596 --retire >"$T_TMP/o" 2>&1
  eq "16. the orchestrator's close of another lane is not gated (0)" 0 "$?"
  check "16. ... that lane's window is gone" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P16O'"
  check "16. ... the orchestrator's own window stays" alive "$PORCH"
  # After its ACCEPTED, with the push ended, the lane closes itself.
  t_accepted m-595
  MISTRAL_TMUX_PANE="$P16" bash "$SUT" --agent m-595 --defer --retire --timeout 3 >"$T_TMP/o" 2>&1
  eq "16. self-close after ACCEPTED and the push ended returns 0" 0 "$?"
  has "16. ... and schedules the close" "scheduled defer-close" "$(cat "$T_TMP/o")"
  check "16. ... the window closes" wait_gone "$P16" 30
}
# c-158 (msg 28e8f71c, SPL-3372): its push worker died (a reboot, or a stop
# by pid) and left RUNNING in its status file; PUSH_CMD=status read DIED, but
# the closer read line 1 only and refused the self-close "since 02:18:53Z"
# forever. RUNNING counts only while a worker holds push-master/lock.
s16c() {
  box
  P16D="$(lane16 m-598 RUNNING)"
  t_accepted m-598
  MISTRAL_TMUX_PANE="$P16D" bash "$SUT" --agent m-598 --defer --retire --timeout 3 >"$T_TMP/o" 2>&1
  eq "16c. self-close with RUNNING left by a dead push worker (no lock holder) returns 0" 0 "$?"
  hasnt "16c. ... and is not refused as a running push" "its push is RUNNING" "$(cat "$T_TMP/o")"
  has "16c. ... it schedules the close" "scheduled defer-close" "$(cat "$T_TMP/o")"
  check "16c. ... the window closes" wait_gone "$P16D" 30
  # Control: the same lane with a live worker holding the lock is still refused.
  P16L="$(lane16 m-599 RUNNING)"
  t_accepted m-599
  H16L="$(hold16 m-599)"
  MISTRAL_TMUX_PANE="$P16L" bash "$SUT" --agent m-599 --defer --retire --timeout 3 >"$T_TMP/o" 2>&1
  eq "16c. control: RUNNING with the lock held is refused (5)" 5 "$?"
  has "16c. control: ... as a running push" "REFUSED self-close of m-599: its push is RUNNING since 2026-10-16T01:27:48Z" "$(cat "$T_TMP/o")"
  check "16c. control: ... the window is still open" alive "$P16L"
  kill "$H16L" 2>/dev/null
}
s16b() {  # Red control: m-595's exact sequence on the script with the gate spliced out closes and retires.
  box
  spliced "$T_TMP/pre16"
  awk '/^# --- the self-close gate/ { skip = 1 } skip && /^if \[\[ "\$DEFER" -eq 1 && -n "\$AGENT_ID"/ { skip = 0 } !skip { print }' "$SUT" >"$T_TMP/pre16/scripts/tmux-close-window.sh"
  hasnt "16. control: the gate is spliced out" "REFUSED self-close" "$(cat "$T_TMP/pre16/scripts/tmux-close-window.sh")"
  P16C="$(lane16 m-597 RUNNING)"
  MISTRAL_TMUX_PANE="$P16C" bash "$T_TMP/pre16/scripts/tmux-close-window.sh" --agent m-597 --defer --retire --timeout 3 >"$T_TMP/o" 2>&1
  eq "16. control: today's code accepts the self-close with push RUNNING and no ACCEPTED (0)" 0 "$?"
  check "16. control: ... and closes the lane's window" wait_gone "$P16C" 30
}

# --- 17. --retire closes every window of the id, then retires it once (SPL-2459) -------
# a-520 2026-10-17: two windows named a-520 (an old shell and main:4); run 1
# killed main:4 and the retire refused (the other window still named the id).
win_count() { tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a -F '#{window_name}' | grep -cE "(^|[^A-Za-z0-9])$1([^0-9]|\$)"; }
s17() {
  box
  local i
  P17A="$(t_window 'a-520@tbox' 'sleep 600')"
  P17B="$(t_window 'tbox: a-520' 'sleep 600')"
  P17N="$(t_window 'a-521@tbox' 'sleep 600')"
  for i in $(seq 10 21); do printf 'a-520\tagy\t%s\t/x\t20261017T%s0000Z\tc-001\n' "$P17A" "$i" >>"$SPOOL_ROOT/registry.tsv"; done
  printf 'a-521\tagy\t%s\t/x\t20261017T100000Z\tc-001\n' "$P17N" >>"$SPOOL_ROOT/registry.tsv"
  eq "17. two windows carry a-520 before the close" 2 "$(win_count a-520)"
  bash "$SUT" --agent a-520 --retire >"$T_TMP/o" 2>&1; eq "17. one --agent a-520 --retire run returns 0" 0 "$?"
  eq "17. ... no window carries a-520 after that ONE run" 0 "$(win_count a-520)"
  check "17. ... and a-520 is retired" retired a-520
  eq "17. ... all 12 registry rows of a-520 are quarantined" 12 "$(grep -c '^a-520	' "$SPOOL_ROOT/registry.retired.tsv" 2>/dev/null)"
  hasnt "17. ... the retire did not refuse" "still carries a-520" "$(cat "$T_TMP/o")"
  check "17. ... the old shell window of a-520 is gone too" wait_gone "$P17B" 2
  check "17. the window of another id (a-521) stays" alive "$P17N"
  check "17. ... and its registry row too" grep -q "^a-521	" "$SPOOL_ROOT/registry.tsv"
  check "17. the active bystander window stays" alive "$VICTIM"
}
s17b() {  # --defer: the lane's own window + an old shell window of its id: both go, retired once.
  box
  P17C="$(lane14 c-433)"
  P17S="$(t_window 'tbox: c-433 old shell' 'sleep 600')"
  CLE_TMUX_PANE="$P17C" bash "$SUT" --agent c-433 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1; eq "17. --defer --retire returns 0 at once" 0 "$?"
  check "17. --defer: the lane's window closes and c-433 is retired" gone_and_retired "$P17C" c-433 40
  check "17. --defer: ... its old shell window is closed too" wait_gone "$P17S" 10
  eq "17. --defer: ... no window carries c-433" 0 "$(win_count c-433)"
}
s17c() {  # --defer never closes another window of its id that still runs an agent CLI.
  box
  P17D="$(lane14 c-434)"
  P17L="$(t_window 'tbox: c-434' "sh $T_TMP/bin/claude-pane $T_TMP/bin/claude-fake $T_TMP/got-434b busy")"
  drawn "$P17L" 'esc to interrupt' >/dev/null
  CLE_TMUX_PANE="$P17D" bash "$SUT" --agent c-434 --defer --retire --timeout 60 >"$T_TMP/o" 2>&1
  check "17. --defer: the lane's own window closes" wait_gone "$P17D" 60
  sleep 2
  check "17. --defer: ... a window of c-434 that runs an agent CLI stays" alive "$P17L"
  check "17. --defer: ... and c-434 is not retired" grep -q "^c-434	" "$SPOOL_ROOT/registry.tsv"
  has "17. --defer: ... the log names the window it left open" "still runs an agent CLI; left open" "$(log14)"
}

# --- the runner ------------------------------------------------------------------------------
# job NAME FN: FN in a subshell (its own sandbox), its ok/FAIL lines to
# $J_DIR/NAME.out; NAME.end is written only when FN returned, so a job that
# died part-way (set -u, a crash) is a failure, not a silently shorter list.
# sub NAME FN: the same inside a job, sharing that job's sandbox; sub_wait.
job() {
  ( trap 'exit 143' TERM; "$2"; : >"$J_DIR/$1.end" ) >"$J_DIR/$1.out" 2>&1 &
  J_PIDS+=("$!"); J_NAMES+=("$1")
}
sub() {
  ( "$2"; : >"$J_DIR/$1.end" ) >"$J_DIR/$1.out" 2>&1 &
  S_PIDS+=("$!")
}
sub_wait() { local p; for p in "${S_PIDS[@]}"; do wait "$p"; done; }
J_PIDS=(); J_NAMES=(); S_PIDS=()
for j in s01 s05 s06 s07 s08 s09 s10 s11 s12 s12b s12c s13 s13b s13c s13d s13e s14 s14b s14c s14d s14e s14f s15 s16 s16b s16c s17 s17b s17c; do
  job "$j" "$j"
done
deadline=$((SECONDS + ${TCW_JOB_MAX:-150}))
for i in "${!J_PIDS[@]}"; do
  while kill -0 "${J_PIDS[$i]}" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.2; done
  if kill -0 "${J_PIDS[$i]}" 2>/dev/null; then
    kill -TERM "${J_PIDS[$i]}" 2>/dev/null
    echo "FAIL - job ${J_NAMES[$i]} did not finish within ${TCW_JOB_MAX:-150} s" >>"$J_DIR/${J_NAMES[$i]}.out"
  fi
  wait "${J_PIDS[$i]}" 2>/dev/null
done
for f in $(cd "$J_DIR" && ls ./*.out | sort -V); do
  n="${f#./}"; n="${n%.out}"
  [ -e "$J_DIR/$n.end" ] || echo "FAIL - job $n died before its end" >>"$J_DIR/$n.out"
  cat "$J_DIR/$n.out"
done
# shellcheck disable=SC2034  # both are read by t_done (lib.inc.sh)
T_PASS="$(cat "$J_DIR"/*.out | grep -c '^ok   - ')" T_FAIL="$(cat "$J_DIR"/*.out | grep -c '^FAIL - ')"
t_done
