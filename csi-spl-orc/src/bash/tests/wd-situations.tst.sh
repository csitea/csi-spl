#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box watchdog of spec 093 section 6 (T004): the situation
#          scripts s1..s9 (S9: spec 102 8), do_spl_watchdog and do_spl_wd_hold, in a sandbox.
#          Every fixture has a control that flips one input and DOES fire
#          (FR-011), so no case passes vacuously. Nothing real is touched:
#          processes are a ps stub + a fake /proc (LEASE_PROC_ROOT), tmux is a
#          stub keeping panes in files, spool-send.sh and the takeover are
#          stubs that log, the clock is LEASE_NOW. The action runs under
#          ./run's `set -E` + an ERR trap that ends the run.
#   1. S1..S8: one fixture that hits and one control that does not, per
#      situation of 6.1 (the scripts read only their context dir)
#   2. the false positives of 6.2, each with its control: a 14 min Bash call,
#      a 50 min Monitor, an idle agent with an empty inbox, a stale stub on a
#      seat, a long turn with a moving spinner, a stale login banner after
#      /login, a lane that finished (its workdir gone)
#   3. a tick: one verdict line per agent, wd.<id> written, windows of
#      another box and of a retiring session skipped; WD_ONLY + WD_STATE_DIR
#      (a drill on scratch ids beside the live loop)
#   4. debounce + actions: S3 pending on tick 1, takeover on tick 2; a dry run
#      only says "would"; S2 never takes over and sends ONE blocker; S1 rings
#      at 120 s and takes over at 240 s; S4 Escape, then takeover 60 s later;
#      the dry-run false positives of 2026-10-06: a note, an id's own
#      re-raise, and a wait with no progress signal (ring only); S7 on the
#      default-mode offer: the agent user's settings back to bypass, then a
#      takeover; "No, keep bypass permissions" (Down, the cursor read on No,
#      Enter) only when the takeover is refused or the dialog outlives it by
#      300 s; never Escape or Yes; no Enter while the cursor is not on No
#   5. the guards of 6.2 at tick level, each with its control: a human client
#      active, do_spl_wd_hold (and MIN=0 lifting it), an id under rotation,
#      a fresh session in its grace, a box back from a 2 h gap
#   6. the limits of 6.3: two takeovers per id per hour; the third is not done,
#      the id is held out and ONE blocker goes to the orchestrator
#   7. FR-014: a situation script that sleeps 60 s costs the tick at most its
#      timeout; the other scripts' verdicts are written
#   8. S9 stuck (spec 102 8.3): the hit fixture (an unknown dialog that
#      swallowed a poke) and controls 1-6 - today's S7 misses it, a
#      UserPromptSubmit after the poke, a pane that changed, an idle agent, an
#      unpoked inbox file (poked once), a ticking status row + a second poke
#      echo (still a hit); grok's 2 x stuck_min; spool-send.sh's input.log
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
SIT="$PROJ_ROOT/src/bash/features/watchdog/situations"
FX="$TEST_DIR/fixtures/wd-situations"
FL="$TEST_DIR/fixtures/fleet-lease"
T0=1800000000   # 2027-01-15T08:00:00Z
iso() { date -u -d "@$1" +%FT%TZ; }

# ---- 1 + 2: the scripts on context dirs ---------------------------------------
# ctx <name>: a fresh context dir at T0; then write its files
ctx() { C="$T/ctx/$1"; rm -rf "$C"; mkdir -p "$C"; echo "$T0" > "$C/now"; }
hb() {  # hb <state> <progress age> [jq extra]: a heartbeat.json in $C
  jq -n --arg st "$1" --arg p "$(iso $((T0 - $2)))" --arg ts "$(iso $((T0 - ${4:-0})))" \
    "{v: 1, id: \"c-900\", state: \$st, ts: \$ts, progress_ts: \$p, tool: null, tool_since: null, api_error: null, calls: []} ${3:-}" \
    > "$C/heartbeat"
}
run_s() { WD_CTX="$C" bash "$SIT/$1.sh" "${2:-c-900}" "${3:-4242}" "${4:-%9}"; }
hit() {  # hit <desc> <script> [args]: the script prints HIT
  local out; out="$(run_s "${@:2}")"
  if [[ "$out" == "HIT ${2^^} "* ]]; then pass "$1"; else fail "$1 (got: '$out')"; fi
}
nohit() {
  local out; out="$(run_s "${@:2}")"
  if [[ -z "$out" ]]; then pass "$1"; else fail "$1 (got: '$out')"; fi
}

# S1: lanes - an inbox file newer than the last progress, waiting > 120 s
ctx s1; hb idle 600; echo "$((T0 - 130)) m1.json" > "$C/inbox"
hit "S1 a lane's message waits 130 s past its last progress" s1
grep -q 'age=130' <<<"$(run_s s1)" && pass "S1 reports the wait (age=130)" || fail "S1 age"
ctx s1c; hb idle 600; echo "$((T0 - 90)) m1.json" > "$C/inbox"
nohit "S1 control: the message waits 90 s only" s1
# 6.2: an idle agent with an empty inbox; control: one message waits
ctx s1e; hb idle 7200
nohit "6.2 idle agent with an empty inbox: no S1 (2 h silent)" s1
echo "$((T0 - 300)) m2.json" > "$C/inbox"
hit "6.2 control: the same idle agent with a waiting message" s1
# 6.2: a message older than the last progress (read and handled) is not waiting
ctx s1r; hb idle 200; echo "$((T0 - 900)) old.json" > "$C/inbox"
nohit "S1: an inbox file older than the last progress is handled, not waiting" s1
# 6.2: a stale stub on an idle seat; control: the seat holds a job and is stale
ctx s1s; hb idle 3600; echo c-001 > "$C/seat"; echo "$((T0 - 900)) stub.json" > "$C/inbox"
nohit "6.2 stale stub in an idle seat's inbox: no S1 (seats read the held set)" s1 c-001
printf 'm9 3\n' > "$C/held"
hit "6.2 control: the seat holds a job while stale" s1 c-001
# 6.2: a long turn whose spinner moves; control: the spinner is frozen
ctx s1t; hb working 200; echo "$((T0 - 150)) m3.json" > "$C/inbox"; echo 3 > "$C/spin_age"
nohit "6.2 long turn, spinner moving, progress 200 s ago: fresh, no S1" s1
echo 300 > "$C/spin_age"
hit "6.2 control: the same turn with a spinner frozen 300 s" s1
# 6.2: the spinner extends fresh by ONE extra 120 s only
ctx s1u; hb working 260; echo "$((T0 - 150)) m3.json" > "$C/inbox"; echo 3 > "$C/spin_age"
hit "5.3: a moving spinner 260 s after the last progress is no longer fresh" s1
# dry-run triage 2026-10-06 (drill-20261006.md 1): what S1 must not count.
# A kind=note is FYI, not a job (g-343); control: the same message as a task
ctx s1n; hb idle 600; echo "$((T0 - 300)) n.json note c-002" > "$C/inbox"
nohit "S1 a note (FYI) waiting 300 s is not a job" s1
echo "$((T0 - 300)) n.json task c-002" > "$C/inbox"
hit "S1 control: the same message as a task is a job" s1
# a message the id sent itself (the asks journal re-raise, c-001); control: a peer's
ctx s1m; hb idle 600; echo "$((T0 - 300)) r.json blocker c-900" > "$C/inbox"
nohit "S1 a blocker the agent's own id sent itself is not a job" s1
echo "$((T0 - 300)) r.json blocker c-900@box1" > "$C/inbox"
out="$(WD_BOX=box1 run_s s1)"
[[ -z "$out" ]] && pass "S1 the same from <id>@<this box> is not a job" || fail "S1 self@box: $out"
echo "$((T0 - 300)) r.json blocker c-900@box2" > "$C/inbox"
out="$(WD_BOX=box1 run_s s1)"
[[ "$out" == "HIT S1 "* ]] && pass "S1 control: the same id on ANOTHER box is a peer, a job" || fail "S1 other box: $out"
echo "$((T0 - 300)) r.json blocker c-002" > "$C/inbox"
hit "S1 control: the same blocker from a peer is a job" s1
# no heartbeat and no transcript progress (grok today, g-366): prog=unknown
ctx s1x; echo "$((T0 - 300)) s.json task c-002" > "$C/inbox"
grep -q '^HIT S1 age=300 prog=unknown ' <<<"$(run_s s1)" && pass "S1 with no progress signal says prog=unknown" || fail "S1 unknown: $(run_s s1)"
hb idle 600
grep -q 'prog=unknown' <<<"$(run_s s1)" && fail "S1 control: a known progress still says prog=unknown" || pass "S1 control: a known progress is not prog=unknown"

# S2: the login screen of 2026-10-05 (T001's fixture)
ctx s2; cp "$FL/login-expired-2026-10-05.pane" "$C/pane"; cp "$FL/login-expired.jsonl" "$C/transcript"
hit "S2 the 2026-10-05 login screen (transcript's last entry an API error)" s2
grep -q 'kind=login' <<<"$(run_s s2)" && pass "S2 names it a login (owner DM path)" || fail "S2 kind"
# 6.2 stale banner after /login: the transcript's last entry is a good turn
ctx s2c; cp "$FL/login-expired-2026-10-05.pane" "$C/pane"; cp "$FL/good-turn.jsonl" "$C/transcript"
nohit "6.2 stale Login banner after a good turn: no S2" s2
ctx s2h; hb idle 900 '| .api_error = "Login expired · Please run /login"'
hit "S2 from the heartbeat's api_error (no pane)" s2
ctx s2l; cp "$FX/limit-reset.pane" "$C/pane"
hit "S2 a usage-limit banner, no spinner, no transcript" s2
grep -q 'kind=limit.*resets' <<<"$(run_s s2)" && pass "S2 names a limit with its reset (no DM)" || fail "S2 limit kind"
ctx s2w; cp "$FX/limit-reset.pane" "$C/pane"; echo 2 > "$C/spin_age"
nohit "S2 control: the same banner under a moving spinner (working)" s2
ctx s2o; echo '{"type":"assistant","timestamp":"2027-01-15T07:59:00Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 529 overloaded"}]}}' > "$C/transcript"
nohit "S2 control: an API error that is not a login or a limit" s2

# S3: a bare shell in the agent's window
ctx s3; cp "$FX/idle.pane" "$C/pane"; echo bash > "$C/fg"; printf 'bash\n' > "$C/tree"
hit "S3 the window runs only bash, no harness process" s3 c-900 -
ctx s3c; cp "$FX/idle.pane" "$C/pane"; echo sh > "$C/fg"; printf 'sh\nsudo\nclaude\n' > "$C/tree"
nohit "S3 control: a claude runs under the pane (its environ unreadable)" s3 c-900 -
nohit "S3 control: a live pid carries the id" s3 c-900 4242
ctx s3f; cp "$FX/idle.pane" "$C/pane"; echo bash > "$C/fg"; echo /opt/x/c-900 > "$C/rundir_gone"
nohit "S3 control: a lane that tore down its workdir and exited (finished)" s3 c-900 -

# S4: one tool call over its cap; 6.2 the 14 min Bash call and the 50 min Monitor
ctx s4; hb in-tool 0 "| .tool = \"Bash\" | .tool_since = \"$(iso $((T0 - 960)))\""
hit "S4 a Bash call 16 min long (cap 15)" s4
ctx s4b; hb in-tool 0 "| .tool = \"Bash\" | .tool_since = \"$(iso $((T0 - 840)))\""
nohit "6.2 a 14 min Bash call is not stuck" s4
WD_CTX="$C" WD_NOW="$T0" bash -c ". '$SIT/lib.inc.sh' c-900 1 -; WD_NOW=$T0; wd_fresh" && pass "5.3 the 14 min Bash call is fresh (in-tool within its cap)" || fail "14 min Bash fresh"
ctx s4m; hb in-tool 0 "| .tool = \"Monitor\" | .tool_since = \"$(iso $((T0 - 3000)))\""
nohit "6.2 a 50 min Monitor is not stuck" s4
ctx s4n; hb in-tool 0 "| .tool = \"Monitor\" | .tool_since = \"$(iso $((T0 - 3700)))\""
hit "6.2 control: a Monitor past its 60 min cap" s4
ctx s4w; hb in-tool 0 "| .tool = \"WebFetch\" | .tool_since = \"$(iso $((T0 - 400)))\""
hit "S4 a WebFetch over its 5 min cap" s4

# S5: the same call with the same result 5 times in the last 8
calls() { jq -nc --argjson n "$1" --argjson m "$2" '[range(0; $m) | {sig: "aa11", res: "x1", ts: "2027-01-15T07:5\(.)"}] + [range(0; $n) | {sig: "bb22", res: "y2", ts: "2027-01-15T07:59:0\(.)"}]'; }
ctx s5; hb working 10 "| .calls = $(calls 5 3)"
hit "S5 five repeats of the newest call in the last 8" s5
ctx s5c; hb working 10 "| .calls = $(calls 4 4)"
nohit "S5 control: four repeats" s5

# S6: unsent text in the input box
ctx s6; hb idle 900; echo ": 'SPOOL c-900: 1 new message (task 9b3e7d10)'" > "$C/input"; echo 150 > "$C/input_age"
hit "S6 a poke line sat 150 s in an idle agent's box" s6
grep -q 'poke=1' <<<"$(run_s s6)" && pass "S6 names it poke-shaped" || fail "S6 poke=1"
echo 30 > "$C/client_age"
nohit "6.2 a human client active 30 s ago: no S6" s6
ctx s6h; hb idle 900; echo "please also check the wui" > "$C/input"; echo 400 > "$C/input_age"
grep -q 'poke=0' <<<"$(run_s s6)" && pass "S6 other text is poke=0 (never cleared)" || fail "S6 poke=0"
ctx s6c; hb idle 900; echo "x" > "$C/input"; echo 60 > "$C/input_age"
nohit "S6 control: text held 60 s" s6
# agy's empty prompt reads back as ">" (a-323/a-324: 34000 s of noise); control: text after it
ctx s6g; hb idle 900; echo ">" > "$C/input"; echo 34000 > "$C/input_age"
nohit "S6 a bare prompt glyph '>' is an empty box" s6
echo "> fix the wui" > "$C/input"
hit "S6 control: text after the glyph is text" s6

# S7: a modal dialog
ctx s7; cp "$FX/modal-auto-mode.pane" "$C/pane"
hit "S7 the auto-mode offer as a dialog" s7
grep -q 'modal=1' <<<"$(run_s s7)" && pass "S7 the offer is dismissable (modal=1)" || fail "S7 modal=1"
ctx s7c; cp "$FX/modal-mention.pane" "$C/pane"
nohit "S7 control: the same words quoted in the transcript above the prompt" s7
ctx s7t; cp "$FX/trust.pane" "$C/pane"
grep -q '^HIT S7 modal=0' <<<"$(run_s s7)" && pass "S7 the trust screen blocks (modal=0: no Escape)" || fail "S7 trust"
# the default-mode offer of 2026-10-06/07 (five seats frozen for hours)
ctx s7d; cp "$FX/modal-default-mode.pane" "$C/pane"
grep -q '^HIT S7 modal=2 cursor=yes ' <<<"$(run_s s7)" && pass "S7 the default-mode offer: modal=2, cursor on Yes" || fail "S7 offer: $(run_s s7)"
cp "$FX/modal-default-mode-no.pane" "$C/pane"
grep -q '^HIT S7 modal=2 cursor=no ' <<<"$(run_s s7)" && pass "S7 the offer with the cursor on No: cursor=no" || fail "S7 offer no: $(run_s s7)"
sed 's/^\( *\)❯ 2\. No, keep bypass permissions/\1❯ No, keep bypass permissions/; s/^\( *\)1\. Yes/\1Yes/' "$FX/modal-default-mode-no.pane" > "$C/pane"
grep -q '^HIT S7 modal=2 cursor=no ' <<<"$(run_s s7)" && pass "S7 unnumbered options: the No cursor is not a composer" || fail "S7 unnumbered: $(run_s s7)"
ctx s7q; cp "$FX/modal-default-quote.pane" "$C/pane"
nohit "S7 control: the offer quoted in a reply above the prompt" s7
{ cat "$FX/modal-default-quote.pane"; printf '\n%.0s' 1 2 3; tail -n 9 "$FX/modal-default-mode.pane"; } > "$C/pane"
grep -q '^HIT S7 modal=2 ' <<<"$(run_s s7)" && pass "S7 control: the same screen with the live dialog at the bottom hits" || fail "S7 quote control: $(run_s s7)"

# S8: the hook is silent
tr_ok() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"ok"}]}}\n' "$(iso $((T0 - $1)))"; }
ctx s8; tr_ok 60 > "$C/transcript"
hit "S8 transcript progress 60 s ago, no heartbeat.json" s8
ctx s8c; tr_ok 60 > "$C/transcript"; hb working 60
nohit "S8 control: the heartbeat moved with it" s8
ctx s8o; tr_ok 60 > "$C/transcript"; hb working 900 "" 900
hit "S8 a heartbeat 900 s old while the transcript progresses" s8
ctx s8i; tr_ok 3600 > "$C/transcript"
nohit "S8 control: an idle agent (no progress for an hour) is not a gap" s8

# ---- 3..7: the watchdog -----------------------------------------------------------
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$S/peer"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"
# ps: "$T/ps" lines "pid ppid etimes comm"
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
# tmux: panes "$T/tmux/panes" as "<pane>\t<pane_pid>\t<session>\t<window>\t<fg>";
# screens "$T/tmux/screen.<pane>"; input "$T/tmux/input.<pane>"; keys logged
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; cmd="$1"; shift; tgt="" esc=0
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -e) esc=1; shift ;; -F) shift 2 ;; -a|-p) shift ;; *) a="$1"; shift ;; esac; done
case "$cmd" in
  list-panes) cat "$P" ;;
  list-clients) cat "$T/tmux/clients" 2>/dev/null ;;
  capture-pane) [ -f "$T/tmux/screen.$tgt" ] || exit 1; cat "$T/tmux/screen.$tgt"
    if [ "$esc" = 1 ]; then printf '────────\n❯ %s\n────────\n' "$(cat "$T/tmux/input.$tgt" 2>/dev/null)"; fi ;;
  send-keys) echo "keys $tgt $a" >> "$T/tmux/log"
    if [ -f "$T/tmux/screen.$tgt.$a" ]; then cp "$T/tmux/screen.$tgt.$a" "$T/tmux/screen.$tgt"; fi ;;
esac
EOF
cat > "$T/bin/send" <<'EOF'
#!/usr/bin/env bash
echo "send $*" >> "$T/sent"
EOF
cat > "$T/bin/takeover" <<'EOF'
#!/usr/bin/env bash
echo "takeover $ID $REASON" >> "$T/takeovers"
EOF
chmod +x "$T/bin/"*
export T
proc() {  # proc <pid> <id> [comm]: a live process carrying SPOOL_AGENT_ID=<id>
  mkdir -p "$T/proc/$1"; printf 'SPOOL_AGENT_ID=%s\0' "$2" > "$T/proc/$1/environ"
}
reset_box() {
  unset NOW
  rm -rf "$D" "$S"/c-* "$T/sent" "$T/takeovers" "$T/tmux/log" "$T/proc"; mkdir -p "$D" "$T/proc"; rm -f "$T/tmux/screen."*
  : > "$T/ps"; : > "$T/tmux/panes"; : > "$T/tmux/clients"
}
# agent <id> <pane> <pid|-> [comm] [age] [screen]: a window, maybe a process
agent() {
  local id="$1" pane="$2" pid="$3" comm="${4:-claude}" age="${5:-3600}" scr="${6:-$FX/idle.pane}" shellpid
  shellpid=$(( ${pane#%} + 5000 ))
  mkdir -p "$S/$id/inbox"
  printf '%s\t%s\t$1\t%s@box1 a lane\t%s\n' "$pane" "$shellpid" "$id" "sh" >> "$T/tmux/panes"
  echo "$shellpid 1 $age sh" >> "$T/ps"
  cp "$scr" "$T/tmux/screen.$pane"
  if [[ "$pid" != - ]]; then echo "$pid $shellpid $age $comm" >> "$T/ps"; proc "$pid" "$id"; fi
}
transcript_stub() { printf '#!/usr/bin/env bash\ncat "%s/tr.$1" 2>/dev/null\n' "$T" > "$T/bin/tr"; chmod +x "$T/bin/tr"; }
transcript_stub
# wd: one tick of do_spl_watchdog under ./run's set -E + ERR trap
wd() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" \
    WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover" \
    LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_NOW="${NOW:-$T0}" WD_TICKS=1 WD_TICK="${TICK:-100}" DRY_RUN="${DRY:-0}" bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-wd-hold.func.sh"
    do_spl_watchdog' 2>&1 | tee -a "$T/all.out"
}
settle() { for _ in $(seq 1 20); do [[ -s "$T/takeovers" ]] && return; sleep 0.1; done; }

# 3. a tick: one line per agent, wd.<id>, other boxes and retiring windows skipped
reset_box
agent c-901 %1 4001; agent c-902 %2 4002
printf '%%3\t6003\t$1\tc-903@box2 remote lane\tssh\n%%4\t6004\t$1\tc-901-2009Z-retiring\tsh\n' >> "$T/tmux/panes"
out="$(wd)"
[[ "$(grep -c '^c-90[12] OK' <<<"$out")" == 2 ]] && pass "3 one OK line per live agent" || fail "3 lines: $out"
grep -q 'c-903\|retiring' <<<"$out" && fail "3 a window of another box or a retiring one was checked: $out" || pass "3 another box's window and a retiring window are not checked"
[[ "$(cut -f1 "$D/wd/tick/agents" | tr '\n' ' ')" == "c-901 c-902 " ]] && pass "3 the agent list is exactly the two local agents" || fail "3 agents: $(cat "$D/wd/tick/agents")"
grep -q 'ERR-TRAP' <<<"$out" && fail "3 the ERR trap fired: $out" || pass "3 the tick runs clean under set -E + ERR trap"
[[ "$(cat "$D/wd.c-901")" == "OK $T0" ]] && pass "3 wd.c-901 reads 'OK <epoch>'" || fail "3 wd file: $(cat "$D/wd.c-901" 2>/dev/null)"
grep -q "c-901 OK" "$D/wd.log" && pass "3 the verdict line is in wd.log" || fail "3 wd.log"

# 3. an agent outside any agent window is found by its process, its pane by
# the process tree; the tick does not wait for ./run's tee process substitution
reset_box; agent c-905 %5 4005
printf '%%5\t5005\t$1\tbash\tsh\n' > "$T/tmux/panes"
out="$(wd)"
grep -qx "c-905	4005	%5" "$D/wd/tick/agents" && grep -q '^c-905 OK' <<<"$out" && pass "3 a process-only agent is checked in its pane (ppid chain)" || fail "3 proc-only: $(cat "$D/wd/tick/agents") / $out"
s0=$SECONDS
env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" WD_PS_CMD="$T/bin/ps" \
  ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_NOW="$T0" WD_TICKS=1 bash -c '
  do_log() { echo "$*"; }
  exec > >(cat) 2> >(sleep 60)
  source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"; do_spl_watchdog' >/dev/null 2>&1
(( SECONDS - s0 < 20 )) && pass "3 a tick under a long-lived process substitution ends ($((SECONDS - s0))s)" || fail "3 the tick waited for a process substitution ($((SECONDS - s0))s)"

# 3. a drill beside the live loop: WD_ONLY checks the named ids only, and
# WD_STATE_DIR keeps its own lock; control: without WD_ONLY every agent
reset_box; agent c-906 %1 4006; agent c-907 %2 4007
out="$(WD_ONLY="c-907" WD_STATE_DIR="$T/drill" wd)"
grep -q '^c-907 OK' <<<"$out" && ! grep -q 'c-906' <<<"$out" && [[ -e "$T/drill/run.lock" && ! -e "$D/wd/run.lock" ]] &&
  pass "3 WD_ONLY=c-907 checks c-907 only, in WD_STATE_DIR" || fail "3 WD_ONLY: $out"
exec 8>>"$D/wd/run.lock"; flock -n 8
out="$(WD_ONLY="c-906 c-907" WD_STATE_DIR="$T/drill" wd)"
exec 8>&-
grep -q '^c-906 OK' <<<"$out" && grep -q '^c-907 OK' <<<"$out" && pass "3 a drill runs while the live loop holds its lock" || fail "3 drill beside the loop: $out"
out="$(wd)"
grep -q '^c-906 OK' <<<"$out" && grep -q '^c-907 OK' <<<"$out" && pass "3 control: without WD_ONLY both are checked" || fail "3 WD_ONLY control: $out"

# 4. S3: pending on tick 1, takeover on tick 2; a dry run only says would
reset_box; agent c-911 %1 -
NOW=$T0 out1="$(wd)"; NOW=$((T0 + 30)) out2="$(DRY=1 wd)"
grep -q 'c-911 OK (pending S3 1/2' <<<"$out1" && pass "4 S3 is pending on its first tick (debounce 2)" || fail "4 pending: $out1"
grep -q 'c-911 HIT S3 .*would takeover (dry run)' <<<"$out2" && pass "4 tick 2: HIT S3, a dry run only says 'would takeover'" || fail "4 dry: $out2"
[[ ! -s "$T/takeovers" ]] && pass "4 the dry run took nobody over" || fail "4 dry run took over"
[[ "$(cat "$D/wd.c-911")" == "HIT S3 $((T0 + 30))" ]] && pass "4 wd.c-911 reads 'HIT S3 <epoch>'" || fail "4 wd: $(cat "$D/wd.c-911")"
NOW=$((T0 + 60)) out3="$(wd)"; settle
grep -q 'c-911 HIT S3 .*-> takeover$' <<<"$out3" && grep -qx 'takeover c-911 S3' "$T/takeovers" && pass "4 DRY_RUN=0: S3 takes over (ID + REASON)" || fail "4 takeover: $out3 / $(cat "$T/takeovers" 2>/dev/null)"
NOW=$((T0 + 90)) wd >/dev/null
[[ "$(grep -c . "$T/takeovers")" == 1 ]] && pass "4 one takeover per episode" || fail "4 twice: $(cat "$T/takeovers")"

# S2 never takes over; ONE blocker to the orchestrator
reset_box; agent c-912 %1 4012 claude 3600 "$FL/login-expired-2026-10-05.pane"; cp "$FL/login-expired.jsonl" "$T/tr.4012"
for k in 0 1 2 3; do NOW=$((T0 + 30 * k)) out="$(wd)"; done
grep -q 'c-912 HIT S2 kind=login' <<<"$out" && pass "4 S2 on the login screen" || fail "4 S2: $out"
[[ ! -s "$T/takeovers" ]] && pass "4 S2 never takes over (4 ticks)" || fail "4 S2 took over"
[[ "$(grep -c -- '--to orchestrator --kind blocker --task wd-c-912' "$T/sent")" == 1 ]] && pass "4 S2 sends ONE blocker to the orchestrator" || fail "4 S2 sends: $(cat "$T/sent" 2>/dev/null)"
grep -q 'box box1, pane %1' "$T/sent" && pass "4 the blocker names the box and the pane" || fail "4 blocker text"

# S1 rings at 120 s, takes over at 240 s (control: 90 s does nothing)
reset_box; agent c-913 %1 4013
echo '{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"content":[{"type":"text","text":"done"}]}}' > "$T/tr.4013"
touch -d "@$((T0 - 90))" "$S/c-913/inbox/m.json"
out="$(wd)"
grep -q 'c-913 OK' <<<"$out" && [[ ! -s "$T/sent" ]] && pass "4 S1 control: a message 90 s old, no ring" || fail "4 S1 90: $out"
NOW=$((T0 + 40)) out="$(wd)"
grep -q 'c-913 HIT S1 age=130 .*-> ring' <<<"$out" && grep -q -- '--poke-only --from .* --to c-913' "$T/sent" && pass "4 S1 rings at 130 s" || fail "4 S1 ring: $out"
NOW=$((T0 + 160)) out="$(wd)"; settle
grep -qx 'takeover c-913 S1' "$T/takeovers" && pass "4 S1 takes over at 250 s" || fail "4 S1 takeover: $out"
# the dry-run false positives at tick level, on real inbox JSON (spl_wd_inbox)
# g-343: a note waits 250 s: no ring, no takeover; control: the same as a task rings
reset_box; agent c-916 %1 4016
echo '{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"content":[{"type":"text","text":"done"}]}}' > "$T/tr.4016"
echo '{"v":1,"kind":"note","from":"c-002","to":"c-916","body":"fyi"}' > "$S/c-916/inbox/n.json"
touch -d "@$((T0 - 250))" "$S/c-916/inbox/n.json"
out="$(wd)"
grep -q 'c-916 OK' <<<"$out" && [[ ! -s "$T/sent" && ! -s "$T/takeovers" ]] && pass "4 a note 250 s unread: OK, no ring, no takeover" || fail "4 note: $out"
grep -q '^[0-9]* n.json note c-002$' "$D/wd/ctx/c-916/inbox" && pass "4 the ctx inbox carries kind and from" || fail "4 ctx inbox: $(cat "$D/wd/ctx/c-916/inbox")"
echo '{"v":1,"kind":"task","from":"c-002","to":"c-916","body":"do"}' > "$S/c-916/inbox/n.json"
touch -d "@$((T0 - 250))" "$S/c-916/inbox/n.json"
out="$(wd)"; settle
grep -qx 'takeover c-916 S1' "$T/takeovers" && pass "4 control: the same as a task 250 s unread is taken over" || fail "4 task control: $out"
# c-001: its own asks re-raise (from == to) waits 1400 s while idle: not a job
reset_box; agent c-917 %1 4017
echo '{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"content":[{"type":"text","text":"done"}]}}' > "$T/tr.4017"
echo '{"v":1,"kind":"blocker","from":"c-917","to":"c-917","body":"ASKS STILL OPEN"}' > "$S/c-917/inbox/r.json"
touch -d "@$((T0 - 1400))" "$S/c-917/inbox/r.json"
out="$(wd)"
grep -q 'c-917 OK' <<<"$out" && [[ ! -s "$T/takeovers" ]] && pass "4 an id's own re-raise 1400 s unread: OK, no takeover" || fail "4 self: $out"
# g-366: a task waits 375 s, no heartbeat, no transcript: ring only, never takeover
reset_box; agent c-918 %1 4018
echo '{"v":1,"kind":"task","from":"c-002","to":"c-918","body":"stop"}' > "$S/c-918/inbox/s.json"
touch -d "@$((T0 - 375))" "$S/c-918/inbox/s.json"
out="$(wd)"; NOW=$((T0 + 30)) out2="$(wd)"; sleep 0.5
grep -q 'c-918 HIT S1 age=375 prog=unknown .*-> ring$' <<<"$out" && grep -q -- '--poke-only --from .* --to c-918' "$T/sent" &&
  [[ ! -s "$T/takeovers" ]] && grep -q 'c-918 HIT S1 .*ring done' <<<"$out2" &&
  pass "4 progress unknown: S1 rings once, no takeover at 375 s and 405 s" || fail "4 unknown: $out / $out2 / $(cat "$T/takeovers" 2>/dev/null)"
echo '{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","message":{"content":[{"type":"text","text":"done"}]}}' > "$T/tr.4018"
NOW=$((T0 + 60)) out="$(wd)"; settle
grep -qx 'takeover c-918 S1' "$T/takeovers" && pass "4 control: with a known stale progress the same wait is taken over" || fail "4 unknown control: $out"

# S4: Escape, then takeover 60 s later
reset_box; agent c-914 %1 4014
jq -n --arg s "$(iso $((T0 - 1000)))" '{v: 1, state: "in-tool", ts: $s, progress_ts: $s, tool: "Bash", tool_since: $s, calls: []}' > "$S/c-914/heartbeat.json"
out="$(wd)"
grep -q 'c-914 HIT S4 .*-> esc$' <<<"$out" && grep -qx 'keys %1 Escape' "$T/tmux/log" && pass "4 S4 sends Escape once" || fail "4 S4 esc: $out"
NOW=$((T0 + 30)) out="$(wd)"
[[ "$(grep -c Escape "$T/tmux/log")" == 1 && ! -s "$T/takeovers" ]] && pass "4 S4 30 s later: no second Escape, no takeover yet" || fail "4 S4 30: $out"
NOW=$((T0 + 60)) out="$(wd)"; settle
grep -qx 'takeover c-914 S4' "$T/takeovers" && pass "4 S4 still in the call 60 s later: takeover" || fail "4 S4 takeover: $out"

# S7 the default-mode offer: settings back to bypass + takeover; No as the fallback
s7home() { rm -rf "${T:?}/home"; mkdir -p "$T/home/.claude"; echo '{"permissions":{"defaultMode":"auto","allow":["Bash"]},"model":"x"}' > "$T/home/.claude/settings.json"; }
export WD_SETTINGS_HOME="$T/home"
reset_box; s7home; agent c-915 %1 4015 claude 3600 "$FX/modal-default-mode.pane"
cp "$FX/modal-default-mode-no.pane" "$T/tmux/screen.%1.Down"
out="$(WD_KEY_WAIT=0 wd)"; settle
grep -q 'c-915 HIT S7 modal=2 cursor=yes .*-> settings;takeover$' <<<"$out" && grep -qx 'takeover c-915 S7' "$T/takeovers" && [[ ! -s "$T/tmux/log" ]] &&
  pass "4 S7 offer: a takeover, no key pressed" || fail "4 S7 takeover: $out / $(cat "$T/tmux/log" 2>/dev/null)"
jq -e '.permissions.defaultMode == "bypassPermissions" and .skipDangerousModePermissionPrompt == true and .model == "x" and .permissions.allow == ["Bash"]' "$T/home/.claude/settings.json" >/dev/null &&
  ls "$T/home/.claude/settings.json.bak-wd-"* >/dev/null 2>&1 && pass "4 S7 offer: settings.json back to bypass, other keys kept, a backup" || fail "4 S7 settings: $(cat "$T/home/.claude/settings.json")"
out="$(NOW=$((T0 + 60)) WD_KEY_WAIT=0 wd)"
[[ ! -s "$T/tmux/log" ]] && grep -q 'takeover started 60s ago' <<<"$out" && pass "4 S7 60 s into the takeover: no key" || fail "4 S7 60: $out"
out="$(NOW=$((T0 + 310)) WD_KEY_WAIT=0 wd)"
[[ "$(cat "$T/tmux/log")" == $'keys %1 Down\nkeys %1 Enter' ]] && pass "4 S7 the dialog outlives the takeover by 300 s: Down, the cursor on No, Enter" || fail "4 S7 310: $out / $(cat "$T/tmux/log" 2>/dev/null)"
# the takeover refused (held out: 2 takeovers this hour): No at once, never Escape
reset_box; s7home; agent c-916 %1 4016 claude 3600 "$FX/modal-default-mode.pane"
cp "$FX/modal-default-mode-no.pane" "$T/tmux/screen.%1.Down"
mkdir -p "$D/wd"; printf '%s\n%s\n' $((T0 - 20)) $((T0 - 10)) > "$D/wd/c-916.takeovers"
out="$(WD_KEY_WAIT=0 wd)"
grep -q 'c-916 HIT S7 .*takeover not done: held out.*;no$' <<<"$out" && [[ "$(cat "$T/tmux/log")" == $'keys %1 Down\nkeys %1 Enter' ]] &&
  pass "4 S7 takeover refused: Down, the cursor read on No, then Enter (no Escape)" || fail "4 S7 no: $out / $(cat "$T/tmux/log" 2>/dev/null)"
reset_box; s7home; agent c-920 %1 4020 claude 3600 "$FX/modal-default-mode.pane"
mkdir -p "$D/wd"; printf '%s\n%s\n' $((T0 - 20)) $((T0 - 10)) > "$D/wd/c-920.takeovers"
out="$(WD_KEY_WAIT=0 wd)"
! grep -qE 'Enter|Escape' "$T/tmux/log" && grep -q 'c-920 HIT S7 .*no not done: cursor never reached No' <<<"$out" &&
  pass "4 S7 control: the cursor stays on Yes, no Enter is pressed" || fail "4 S7 stuck: $out / $(cat "$T/tmux/log" 2>/dev/null)"
reset_box; s7home; agent c-919 %1 4019 claude 3600 "$FX/modal-default-quote.pane"
out="$(WD_KEY_WAIT=0 wd)"; settle
[[ ! -s "$T/tmux/log" && ! -s "$T/takeovers" ]] && ! grep -q 'c-919 HIT S7' <<<"$out" &&
  jq -e '.permissions.defaultMode == "auto"' "$T/home/.claude/settings.json" >/dev/null &&
  pass "4 S7 control: a quoted offer gets no key, no takeover, no settings write" || fail "4 S7 quote: $out"
unset WD_SETTINGS_HOME

# 5. guards, each with its control
reset_box; agent c-921 %1 -
echo "\$1 $((T0 - 20))" > "$T/tmux/clients"
NOW=$T0 wd >/dev/null; out="$(NOW=$((T0 + 30)) wd)"
grep -q 'c-921 HIT S3 .*would takeover (a human client was active' <<<"$out" && [[ ! -s "$T/takeovers" ]] && pass "5 a human client active: no takeover" || fail "5 human: $out"
: > "$T/tmux/clients"
out="$(NOW=$((T0 + 60)) WD_NOW=$((T0 + 60)) ID=c-921 MIN=10 bash -c "source '$PROJ_ROOT/src/bash/run/spl-wd-hold.func.sh'; do_log() { echo \"\$*\"; }; SPOOL_ROOT='$S' do_spl_wd_hold")"
[[ "$(cat "$S/c-921/.human-hold")" == "$((T0 + 660))" ]] && pass "5 do_spl_wd_hold writes the hold's end" || fail "5 hold file: $out"
out="$(NOW=$((T0 + 60)) wd)"
grep -q 'would takeover (human hold for 10 min)' <<<"$out" && [[ ! -s "$T/takeovers" ]] && pass "5 a human hold: no takeover" || fail "5 hold: $out"
ID=c-921 MIN=0 bash -c "source '$PROJ_ROOT/src/bash/run/spl-wd-hold.func.sh'; do_log() { :; }; SPOOL_ROOT='$S' do_spl_wd_hold"
out="$(NOW=$((T0 + 90)) wd)"; settle
[[ ! -e "$S/c-921/.human-hold" ]] && grep -qx 'takeover c-921 S3' "$T/takeovers" && pass "5 control: hold lifted (MIN=0), the takeover runs" || fail "5 lifted: $out"
# rotation: rotate.hold names the id; control: it names another id
reset_box; agent c-922 %1 -
echo "c-922 $((T0 - 60)) r1" > "$D/rotate.hold"
out="$(wd)"
grep -q 'c-922 SKIP rotation' <<<"$out" && pass "5 an id under rotation is skipped" || fail "5 rotation: $out"
echo "c-999 $((T0 - 60)) r1" > "$D/rotate.hold"
out="$(wd)"
grep -q 'c-922 OK (pending S3' <<<"$out" && pass "5 control: rotate.hold naming another id checks it" || fail "5 rotation control: $out"
echo "$(iso $((T0 - 120))) 20270115T0758Z-wd-c-922 SPAWN OK new pane" >> "$D/rotate.log"
out="$(wd)"
grep -q 'c-922 SKIP rotation: .*-wd-c-922 SPAWN' <<<"$out" && pass "5 a takeover in flight in rotate.log is skipped" || fail "5 rotate.log: $out"
echo "$(iso $((T0 - 100))) 20270115T0758Z-wd-c-922 DONE OK" >> "$D/rotate.log"; rm -f "$D/rotate.hold"
wd >/dev/null; out="$(wd)"
grep -q 'c-922 HIT S3' <<<"$out" && pass "5 control: its final DONE line ends the skip" || fail "5 done: $out"
# start grace: a session 60 s old; control: 200 s old
reset_box; agent c-923 %1 4023 claude 60 "$FX/trust.pane"
out="$(wd)"
grep -q 'c-923 SKIP start grace' <<<"$out" && pass "5 a session 60 s old is in its start grace" || fail "5 grace: $out"
reset_box; agent c-923 %1 4023 claude 200 "$FX/trust.pane"
out="$(wd)"
grep -q 'c-923 HIT S7 modal=0' <<<"$out" && pass "5 control: 200 s old, S7 fires" || fail "5 grace control: $out"
# a box back from a 2 h gap: debounces and graces reset; control: no gap
reset_box; agent c-924 %1 -
NOW=$T0 wd >/dev/null
out="$(NOW=$((T0 + 7200)) wd)"
grep -q 'c-924 SKIP resume grace' <<<"$out" && grep -q 'RESUME tick gap 7200s' "$D/wd.log" && pass "5 a 2 h tick gap: resume grace, logged" || fail "5 gap: $out"
NOW=$((T0 + 7290)) wd >/dev/null; NOW=$((T0 + 7380)) wd >/dev/null; out="$(NOW=$((T0 + 7410)) wd)"
grep -q 'c-924 HIT S3' <<<"$out" && pass "5 control: after the grace the debounce runs again (2 ticks)" || fail "5 gap control: $out"

# 6. limits: 2 takeovers per id per hour; the third is held out + ONE blocker
reset_box
lim() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" WD_SEND="$T/bin/send" \
    WD_TAKEOVER_CMD="$T/bin/takeover" LEASE_NOW="$1" bash -c '
    do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"; spl_wd_init >/dev/null
    spl_wd_takeover c-931 S3 "evidence"; echo "rc=$?"'
}
r1="$(lim "$T0")"; r2="$(lim $((T0 + 600)))"; r3="$(lim $((T0 + 1200)))"; settle; sleep 0.3
[[ "$r1" == rc=0 && "$r2" == rc=0 ]] && pass "6 two takeovers in an hour run" || fail "6 first two: $r1 / $r2"
[[ "$r3" == *"held out: 2 takeovers"*"rc=1" ]] && [[ "$(grep -c . "$T/takeovers")" == 2 ]] && pass "6 the third is not done: held out" || fail "6 third: $r3 / $(cat "$T/takeovers")"
[[ "$(grep -c -- '--kind blocker --task wd-c-931' "$T/sent")" -ge 1 ]] && [[ -s "$D/wd/c-931.heldout" ]] && pass "6 held out + a blocker to the orchestrator" || fail "6 blocker: $(cat "$T/sent" 2>/dev/null)"
reset_box; agent c-931 %1 -; mkdir -p "$D/wd"; echo "$T0" > "$D/wd/c-931.heldout"
TICK=2000 NOW=$T0 wd >/dev/null; out="$(TICK=2000 NOW=$((T0 + 30)) wd)"
grep -q 'would takeover (held out after 2 takeovers' <<<"$out" && pass "6 a held-out id gets no action for an hour" || fail "6 heldout gate: $out"
out="$(TICK=2000 NOW=$((T0 + 3630)) wd)"
grep -q 'c-931 HIT S3 .*-> takeover$' <<<"$out" && pass "6 control: an hour later it is acted on again" || fail "6 heldout control: $out"

# 7. FR-014: a script that sleeps 60 s costs the tick its timeout only
reset_box; agent c-941 %1 -; agent c-942 %2 -
cp -r "$SIT" "$T/sit"; printf '#!/usr/bin/env bash\nsleep 60\n' > "$T/sit/s9.sh"
s0=$SECONDS; out="$(export WD_SITUATIONS="$T/sit" WD_SCRIPT_TIMEOUT=2; wd)"; el=$((SECONDS - s0))
(( el < 30 )) && pass "7 FR-014: the tick ends in ${el}s with a 60 s script (< 30 s)" || fail "7 tick took ${el}s"
grep -q 'c-941 OK (pending S3' <<<"$out" && grep -q 'c-942 OK (pending S3' <<<"$out" && [[ -s "$D/wd.c-941" && -s "$D/wd.c-942" ]] &&
  pass "7 the other scripts' verdicts are written" || fail "7 verdicts: $out"

# 8. S9 stuck (spec 102 8.3): the 2026-10-06 frozen pane with words no list
# knows. Every case below is a control of the hit: one input flipped.
s9ctx() {  # s9ctx <name> [poke age] [progress age] [pane age]: the hit, flipped by its args
  ctx "$1"; cp "$FX/s9-unknown-dialog.pane" "$C/pane"
  hb idle "${3:-660}" "| .harness = \"claude\" | .turn_since = \"$(iso $((T0 - 3600)))\""
  echo "$(iso $((T0 - ${2:-600}))) note" > "$C/input_log"
  echo "${4:-600}" > "$C/pane_age"
}
s9ctx s9
hit "8 S9 hit: unknown dialog, progress 11 min old, a poke 10 min ago, no UserPromptSubmit after it" s9
grep -q '^HIT S9 input=600s prog=660s pane=600s rule=ups$' <<<"$(run_s s9)" && pass "8 S9 names its evidence" || fail "8 S9 evidence: $(run_s s9)"
nohit "8 control 1: today's S7 misses the same pane (the list-based guard)" s7
echo "$(iso $((T0 - 3600))) SessionStart starting" > "$C/hblog"
hit "8 S9 an old UserPromptSubmit before the poke does not answer it" s9
s9ctx s9c2; hb idle 660 "| .harness = \"claude\" | .turn_since = \"$(iso $((T0 - 500)))\""
nohit "8 control 2: a UserPromptSubmit after the poke (heartbeat turn_since)" s9
s9ctx s9c2l; echo "$(iso $((T0 - 590))) UserPromptSubmit working" > "$C/hblog"
nohit "8 control 2: a UserPromptSubmit after the poke (heartbeat.log)" s9
s9ctx s9c3 600 660 300
nohit "8 control 3: the pane body changed after the poke (pane_age 300 s)" s9
ctx s9c4; cp "$FX/idle.pane" "$C/pane"; hb idle 10800 '| .harness = "claude"'; echo 10800 > "$C/pane_age"
out="$(run_s s9)"
[[ -z "$out" ]] && pass "8 control 4: idle pane, empty inbox, nothing typed, progress 3 h old: nothing" || fail "8 control 4: '$out'"
echo "$((T0 - 300)) m5.json note c-002" > "$C/inbox"
out="$(run_s s9)"
[[ -z "$out" ]] && pass "8 control 5 rollout guard: no input.log yet (no sender of this tree poked it): no POKE" || fail "8 rollout guard: '$out'"
echo "$(iso $((T0 - 7200))) note" > "$C/input_log"; hb idle 10800 "| .harness = \"claude\" | .turn_since = \"$(iso $((T0 - 7190)))\""
out="$(run_s s9)"
[[ "$out" == "POKE m5.json" ]] && pass "8 control 5: an unread file nobody poked: no hit, one POKE line" || fail "8 control 5: '$out'"
echo "$(iso $((T0 - 200))) note" > "$C/input_log"
out="$(run_s s9)"
[[ "$out" != *POKE* && "$out" != HIT* ]] && pass "8 control 5: the same file poked after it arrived: no POKE" || fail "8 control 5 poked: '$out'"
s9ctx s9w 500 660 500
nohit "8 S9 control: the poke is 500 s old, inside stuck_min" s9
s9ctx s9p 600 300 600
nohit "8 S9 control: progress 300 s ago" s9
s9ctx s9t; hb in-tool 660 "| .harness = \"claude\" | .tool = \"Bash\" | .tool_since = \"$(iso $((T0 - 700)))\""
nohit "8 S9 control: in a Bash call within its cap" s9
hb in-tool 960 "| .harness = \"claude\" | .tool = \"Bash\" | .tool_since = \"$(iso $((T0 - 960)))\""
hit "8 S9 past the tool cap counts as not in a tool" s9
s9ctx s9n
nohit "8 S9 control: no harness process (S3's case)" s9 c-900 -
# a harness with no UserPromptSubmit (grok): conditions 1-4 at 2 x stuck_min
s9ctx s9g; hb idle 660 '| .harness = "grok"'
nohit "8 S9 grok: 10 min is not enough (2 x stuck_min)" s9
s9ctx s9g2 1260 1300 1260; hb idle 1300 '| .harness = "grok"'
grep -q '^HIT S9 .*rule=2x$' <<<"$(run_s s9)" && pass "8 S9 grok: a poke 21 min ago, progress 21 min old, pane frozen: hit (rule=2x)" || fail "8 S9 grok: $(run_s s9)"
hb idle 1000 '| .harness = "grok"'
nohit "8 S9 grok control: progress after the poke" s9
# --norm drops poke lines and the bottom status row; --scrub hides secrets
a="$(printf 'body\n\nstatus 08:00:01\n\n' | bash "$SIT/s9.sh" --norm)"
b="$(printf 'body\n%s\n\nstatus 08:00:31\n' ": 'SPOOL c-900: note from c-002'" | bash "$SIT/s9.sh" --norm)"
[[ "$a" == "$b" && "$a" == body* ]] && pass "8 --norm: a ticking status row and a poke echo hash the same" || fail "8 --norm: '$a' / '$b'"
b="$(printf 'body changed\n\nstatus 08:00:01\n' | bash "$SIT/s9.sh" --norm)"
[[ "$a" != "$b" ]] && pass "8 --norm control: a changed body hashes differently" || fail "8 --norm control"
# the planted values are built here, so no secret-shaped literal is in the tree
s9tok="$(printf '%s=%s' tok"en" "PLANTED$((40 + 2))x")"; s9gh="$(printf 'gh%s_%s' p PLANTEDabcdefgh12)"
out="$(printf '%s\n%s\nplain words\n' "$s9tok" "$s9gh" | bash "$SIT/s9.sh" --scrub)"
! grep -q PLANTED <<<"$out" && grep -q 'plain words' <<<"$out" && pass "8 --scrub hides a token and a key, keeps the rest" || fail "8 --scrub: $out"

# 8. S9 at tick level: hit + controls 3, 5 and 6
s9screen() {  # s9screen <pane> <clock> [extra line]
  { cat "$FX/s9-unknown-dialog.pane"; echo " log: $s9tok"; [[ -n "${3:-}" ]] && echo "$3"; echo "  ⏵⏵ bypass permissions on · $2"; } > "$T/tmux/screen.$1"
}
s9agent() {  # s9agent <id> <pid> <poke epoch>
  agent "$1" %1 "$2"
  jq -n --arg p "$(iso $(($3 - 60)))" --arg u "$(iso $(($3 - 3600)))" \
    '{v: 1, harness: "claude", state: "idle", ts: $p, progress_ts: $p, turn_since: $u, calls: []}' > "$S/$1/heartbeat.json"
  mkdir -p "$S/$1/lifetime"; echo "$(iso "$3") note" > "$S/$1/lifetime/input.log"
}
P=$((T0 - 630))
reset_box; s9agent c-951 4051 "$P"
s9screen %1 08:00:00
NOW=$((P + 30)) TICK=400 wd >/dev/null
s9screen %1 08:05:00 ": 'SPOOL c-951: note from c-002 (task 9b3e7d10)'"
NOW=$((P + 300)) TICK=400 wd >/dev/null
s9screen %1 08:10:30
echo "$(iso $((P + 300))) note" >> "$S/c-951/lifetime/input.log"
out="$(NOW=$((P + 630)) TICK=400 wd)"; settle
grep -q 'c-951 HIT S9 input=630s .*-> snapshot;takeover$' <<<"$out" && grep -qx 'takeover c-951 S9' "$T/takeovers" &&
  pass "8 control 6: a ticking status row and a second poke echo: still S9, snapshot + takeover" || fail "8 tick S9: $out / $(cat "$T/takeovers" 2>/dev/null)"
grep -q -- "--to orchestrator --kind note --task wd-c-951 .*$D/wd/c-951.s9.pane" "$T/sent" && grep -q wibbler "$D/wd/c-951.s9.pane" &&
  ! grep -q PLANTED "$D/wd/c-951.s9.pane" &&
  pass "8 S9 sends the orchestrator the path of a scrubbed snapshot" || fail "8 S9 note: $(cat "$T/sent" 2>/dev/null)"
[[ ! -s "$T/tmux/log" ]] && pass "8 S9 types nothing into the unknown dialog" || fail "8 S9 keys: $(cat "$T/tmux/log")"
NOW=$((P + 660)) TICK=400 wd >/dev/null; settle
[[ "$(grep -c . "$T/takeovers")" == 1 && "$(grep -c 'wd-c-951' "$T/sent")" == 1 ]] && pass "8 S9 one snapshot and one takeover per episode" || fail "8 S9 twice: $(cat "$T/takeovers") / $(cat "$T/sent")"
reset_box; s9agent c-953 4053 "$P"
s9screen %1 08:00:00
NOW=$((P + 30)) TICK=400 wd >/dev/null
sed 's/Recalibrate the flux wibbler/Recalibrating the flux wibbler/' "$FX/s9-unknown-dialog.pane" > "$T/tmux/screen.%1"
NOW=$((P + 300)) TICK=400 wd >/dev/null
out="$(NOW=$((P + 630)) TICK=400 wd)"
grep -q 'c-953 OK' <<<"$out" && [[ ! -s "$T/takeovers" ]] && pass "8 control 3 (tick): the pane body changed once after the poke: no S9" || fail "8 tick control 3: $out"
# control 5: an unread file nobody poked is poked ONCE, then the window runs
reset_box; agent c-952 %1 4052
jq -n --arg p "$(iso $((T0 - 3600)))" --arg u "$(iso $((T0 - 7190)))" '{v: 1, harness: "claude", state: "idle", ts: $p, progress_ts: $p, turn_since: $u, calls: []}' > "$S/c-952/heartbeat.json"
mkdir -p "$S/c-952/lifetime"; echo "$(iso $((T0 - 7200))) note" > "$S/c-952/lifetime/input.log"
echo '{"v":1,"kind":"note","from":"c-002","to":"c-952","body":"fyi"}' > "$S/c-952/inbox/h.json"
touch -d "@$((T0 - 300))" "$S/c-952/inbox/h.json"
out1="$(wd)"; out2="$(NOW=$((T0 + 30)) wd)"
grep -q 'c-952 OK (S9 poked once' <<<"$out1" && [[ "$(grep -c -- '--poke-only --from .* --to c-952' "$T/sent")" == 1 ]] && ! grep -q 'S9 poked' <<<"$out2" &&
  pass "8 control 5 (tick): no S9, the unread file poked once over two ticks" || fail "8 tick control 5: $out1 / $out2 / $(cat "$T/sent" 2>/dev/null)"
out="$(DRY=1 NOW=$((T0 + 60)) wd)"
rm -f "$D/wd/c-952.s9.poked"; out="$(DRY=1 NOW=$((T0 + 90)) wd)"
grep -q 'would poke an unpoked inbox file (dry run)' <<<"$out" && [[ "$(grep -c -- '--to c-952' "$T/sent")" == 1 ]] && pass "8 control 5: a dry run only says it would poke" || fail "8 dry poke: $out"

# 8. spool-send.sh logs a poke that reached the pane in <id>/lifetime/input.log
if command -v tmux >/dev/null; then
  SR="$T/ss"; SOCK="$T/ss.sock"; mkdir -p "$SR/c-961/inbox" "$SR/c-962/inbox"
  tmux -S "$SOCK" -f /dev/null new-session -d -s t -n home -x 200 -y 50 'sleep 600'
  p1="$(tmux -S "$SOCK" new-window -d -t t: -n c-961 -P -F '#{pane_id}' 'sleep 600')"
  p2="$(tmux -S "$SOCK" new-window -d -t t: -n c-962 -P -F '#{pane_id}' 'bash --norc')"
  printf 'c-961\tclaude\t%s\t/x\t20260101T000000Z\nc-962\tclaude\t%s\t/x\t20260101T000000Z\n' "$p1" "$p2" > "$SR/registry.tsv"
  sleep 0.3
  ssend() { env -u TMUX -u TMUX_PANE -u SPOOL_AGENT_ID -u SPOOL_BOX_ENV SPOOL_TEST=1 SPOOL_ROOT="$SR" SPOOL_TMUX_SOCKET="$SOCK" \
    SPOOL_BOX_USER="$(id -un)" SPOOL_AGENT_USER="$(id -un)" SPOOL_BOX_TAG="" \
    bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spool-send.sh" --poke-only --from c-900 --to "$1" >/dev/null 2>&1; }
  ssend c-961; r1=$?; ssend c-962; r2=$?
  [[ "$r1" == 0 ]] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z poke$' "$SR/c-961/lifetime/input.log" &&
    pass "8 spool-send.sh: a poke shown in the pane appends '<ts> poke' to input.log" || fail "8 input.log: rc=$r1 $(cat "$SR/c-961/lifetime/input.log" 2>&1)"
  [[ "$r2" != 0 && ! -e "$SR/c-962/lifetime/input.log" ]] && pass "8 spool-send.sh control: a poke refused (bare shell, rc=$r2) logs nothing" || fail "8 input.log control: rc=$r2"
  tmux -S "$SOCK" kill-server 2>/dev/null || true
else
  echo "SKIP 8 spool-send.sh input.log: no tmux on this box"
fi

grep -q ERR-TRAP "$T/all.out" && fail "no tick may fire ./run's ERR trap: $(grep -m3 ERR-TRAP "$T/all.out")" || pass "no tick fired ./run's ERR trap"

echo "wd-situations: $fails failure(s)"
exit $(( fails > 0 ))
