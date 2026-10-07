#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the takeover of spec 093 section 8 (T005): do_spl_wd_takeover in a
#          sandbox, through the 060 seams (ROTATE_SPAWN, ROTATE_TMUX,
#          ROTATE_KILL, ROTATE_AI, ROTATE_RUN). Nothing real is touched:
#          processes are a ps stub + a fake /proc (LEASE_PROC_ROOT), tmux is a
#          stub keeping panes in a file, spawn-window.sh, ./run, spool-send.sh,
#          kill and the identity map are stubs that log, the clock is
#          LEASE_NOW. The action runs under ./run's `set -E` + an ERR trap.
#   1. S1, S3, S4, S5 each end in a fresh session under the same id (FR-012):
#      the old pid gone (TERM, no /exit-clean), the old window closed, the
#      handoff with its `## watchdog` section, the seed with the old brief,
#      rotate.log WD- phases ending DONE, ONE blocker on task wd-<id>-<ts>
#   2. a seat: its poll loop stopped, then started again
#   3. a role id writes rotate.hold while it runs, and removes it after
#   1b. S7 on the default-mode offer (modal=2) ends in a fresh session too
#   4. a request with no hit -> exit 3, quoting the heartbeat; an S2 login
#      screen is no takeover either (exit 3), nor an S7 trust screen (modal=0)
#   5. guards: a human hold -> refused (exit 4), control: lifted -> runs; a
#      takeover of itself and a lane's request are refused
#   6. limits: a third in an hour -> held out + ONE owner DM (ask + DM),
#      exit 4; control: the second runs
#   7. a failed start: the old session and its window name kept, held out,
#      ask + owner DM, DONE FAIL
#   8. a dry run touches nothing; an id on another box is relayed as a task
#      to that box's role id
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T0=1800000000   # 2027-01-15T08:00:00Z
TS=20270115T0800Z
iso() { date -u -d "@$1" +%FT%TZ; }
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$T/hold" "$T/mem" "$T/wt"
echo "100000.00 0.00" > "$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"

# --- stubs --------------------------------------------------------------------
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
# tmux: panes "$T/tmux/panes" as "<pane>\t<pane_pid>\t<session>\t<window>\t<fg>"
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; L="$T/tmux/log"; cmd="$1"; shift; tgt="" esc=0 fmt="" a=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -e) esc=1; shift ;; -F) fmt="$2"; shift 2 ;; -a|-p|-J|-l) shift ;; -S) shift 2 ;; *) a="$1"; shift ;; esac; done
field() { awk -F'\t' -v p="$tgt" -v f="$1" '$1 == p {print $f}' "$P"; }
case "$cmd" in
  list-panes) if [ "$fmt" = '#{pane_pid} #{pane_id}' ]; then awk -F'\t' '{print $2" "$1}' "$P"; else cat "$P"; fi ;;
  list-clients) cat "$T/tmux/clients" 2>/dev/null ;;
  display-message) grep -q "^$tgt	" "$P" || exit 1
    case "$a" in *window_name*) field 4 ;; *session_id*) field 3 ;; esac ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'working on the brief\n'; fi
    if [ "$esc" = 1 ]; then printf '────────\n❯ \n────────\n'; fi ;;
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="$a" '$1 == p {$4 = n} {print}' "$P" > "$P.new" && mv "$P.new" "$P"
    echo "rename $tgt $a" >> "$L" ;;
  send-keys) echo "keys $tgt $a" >> "$L" ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" > "$P.new" && mv "$P.new" "$P"; echo "kill $tgt" >> "$L" ;;
esac
EOF
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"
cat > "$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; pid=$(( 3000 + 10#$n )); pane="%3$n"
echo "spawn $1 $2 $5 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-} seed=$4" >> "$T/spawn.log"
cat "$S/dispatch/rotate.hold" > "$T/hold.at-spawn" 2>/dev/null || echo none > "$T/hold.at-spawn"
mode="$(cat "$T/spawn.mode.$id" 2>/dev/null || echo ok)"
printf '%s\t%s\t$1\t%s@box1\tclaude\n' "$pane" "$pid" "$id" >> "$T/tmux/panes"
if [ "$mode" != nostart ]; then mkdir -p "$T/proc/$pid"; echo "$1" > "$T/proc/$pid/comm"
  printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$pid/environ"; printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" > "$T/proc/$pid/status"; fi
echo "$id $pane"
EOF
cat > "$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "$2 PEER_SEAT=${PEER_SEAT:-} ASK_KIND=${ASK_KIND:-} DESK_TO=${DESK_TO:-}" >> "$T/run.log"
case "$2" in
  do_spl_asks_open) echo '{"asks":[]}' ;;
  do_spl_lane_map) echo '{"lanes":[]}' ;;
  do_spl_ask_put|do_spl_desk_reply|do_spl_peer_poll) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >> "$T/kill.log"; rm -rf "$T/proc/$2"
EOF
cat > "$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "adopt $2 $3" >> "$T/ai.log"; echo "$3" > "$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\ncat "%s/tr.$1" 2>/dev/null\n' "$T" > "$T/bin/tr"
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat > "$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-wd-takeover.func.sh"
do_spl_wd_takeover || exit $?
EOF
chmod +x "$T/bin/"*

export T S PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" \
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" LEASE_TRANSCRIPT_CMD="$T/bin/tr" \
  ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" ROTATE_KILL="$T/bin/kill" ROTATE_AI="$T/bin/ai" PEER_RUN="$T/bin/run" \
  ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_TERM_WAIT=2 \
  ROTATE_NEW_EXIT_WAIT=2 WD_START_WAIT=3 LEASE_NOW="$T0" ROTATE_TRANSCRIPT="$T/old.jsonl"
unset SPOOL_AGENT_ID REQ_FROM WD_EVIDENCE CLAUDE_BIN DRY_RUN

world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/sent" "$T/spawn.mode."* "$T/ai."* "$T/hold.at-spawn" "$D" "$S/peer" "$S"/[cg]-[0-9]*
  mkdir -p "$D" "$S/peer"
  printf 'LEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10\n' > "$D/lease.conf"
  : > "$T/ps"; : > "$T/tmux/panes"; : > "$T/tmux/clients"
  printf '%s\n' '{"type":"user","timestamp":"2027-01-15T06:00:00Z","message":{"content":"Read your full task brief at /briefs/T999.md and implement it."}}' \
    '{"type":"assistant","timestamp":"2027-01-15T07:00:00Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 500 overloaded"}]}}' > "$T/old.jsonl"
}
# agent <id> <pane> <pid|-> [comm]: its window and, with a pid, its process
agent() {
  local id="$1" pane="$2" pid="$3" comm="${4:-claude}" shellpid
  shellpid=$(( ${pane#%} + 5000 ))
  mkdir -p "$S/$id/inbox" "$S/$id/outbox"
  printf '%s\t%s\t%s\t%s\t20270115T0600Z\n' "$id" "$comm" "$pane" "$T/wt" >> "$S/registry.tsv"
  if [[ "$pid" == - ]]; then
    printf '%s\t%s\t$1\t%s@box1\tbash\n' "$pane" "$shellpid" "$id" >> "$T/tmux/panes"
    echo "$shellpid 1 3600 bash" >> "$T/ps"
  else
    printf '%s\t%s\t$1\t%s@box1\t%s\n' "$pane" "$pid" "$id" "$comm" >> "$T/tmux/panes"
    echo "$pid 1 3600 $comm" >> "$T/ps"
    mkdir -p "$T/proc/$pid"; echo "$comm" > "$T/proc/$pid/comm"
    printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$pid/environ"
    printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" > "$T/proc/$pid/status"
  fi
}
hb() {  # hb <id> <state> <progress age> [jq extra]
  jq -n --arg st "$2" --arg p "$(iso $((T0 - $3)))" \
    "{v: 1, id: \"$1\", state: \$st, event: \"Stop\", ts: \$p, progress_ts: \$p, tool: null, tool_since: null, api_error: null, calls: []} ${4:-}" \
    > "$S/$1/heartbeat.json"
}
loop() {  # loop <id>: a running poll loop of <id>
  local d="$S/peer/$1"; mkdir -p "$d"
  setsid bash -c 'exec 7> "$1"; flock 7; echo $$ > "$2"; exec sleep 300' _ "$d/poll.run" "$d/poll.pid" &
  for _ in $(seq 1 30); do [[ -s "$d/poll.pid" ]] && break; sleep 0.1; done
}
take() { env "$@" "$T/bin/act" > "$T/o" 2>&1; echo $?; }
alive() { [[ -d "$T/proc/$1" ]]; }
win() { awk -F'\t' -v p="$1" '$1 == p {print $4}' "$T/tmux/panes"; }
waitfor() { for _ in $(seq 1 50); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# proof of a done takeover: proof <desc> <id> <old pid|-> <old pane> <code>
proof() {
  local desc="$1" id="$2" old="$3" pane="$4" code="$5" n new hand seed
  n="${id##*-}"; new=$(( 3000 + 10#$n ))
  hand="$S/$id/handoff/$TS-wd-$id.md"; seed="$S/$id/handoff/$TS-wd-$id.seed.md"
  local bad=""
  [[ "$rc" == 0 ]] || bad+=" rc=$rc"
  alive "$new" || bad+=" new-pid-$new-not-alive"
  [[ "$old" == - ]] || ! alive "$old" || bad+=" old-pid-$old-alive"
  [[ "$old" == - ]] || grep -q "^kill -TERM $old" "$T/kill.log" 2>/dev/null || bad+=" no-TERM"
  grep -q "keys $pane /exit" "$T/tmux/log" 2>/dev/null && bad+=" exit-clean-typed"
  grep -q "^kill $pane$" "$T/tmux/log" || bad+=" old-window-open"
  [[ "$(win "%3$n")" == "$id@box1" ]] || bad+=" new-window=$(win "%3$n")"
  grep -q "^spawn [a-z]* $id peer-restart SPAWN_REUSE_ID=1 seed=$seed" "$T/spawn.log" || bad+=" spawn:$(cat "$T/spawn.log")"
  grep -q '^## watchdog' "$hand" && grep -q "^- situation: $code" "$hand" && grep -q '^## 2. In flight' "$hand" &&
    grep -q 'API ERROR: API Error: 500 overloaded' "$hand" || bad+=" handoff"
  grep -q 'brief at /briefs/T999.md' "$seed" && grep -q '^## B. The mechanical handoff' "$seed" || bad+=" seed"
  grep -q " $TS-wd-$id WD-SPAWN OK " "$D/rotate.log" && [[ "$(tail -1 "$D/rotate.log" | cut -d' ' -f3,4)" == "DONE OK" ]] || bad+=" rotate.log"
  [[ "$(grep -c -- "--to orchestrator --kind blocker --task wd-$id-$TS " "$T/sent" 2>/dev/null)" == 1 ]] || bad+=" blocker:$(cat "$T/sent" 2>/dev/null)"
  grep -q ERRTRAP "$T/o" && bad+=" errtrap"
  [[ -z "$bad" ]] && pass "$desc" || fail "$desc:$bad -- $(tail -5 "$T/o")"
}

# --- 1. S1, S3, S4, S5 end in a fresh session -------------------------------------
world; agent c-905 %5 -
rc="$(take ID=c-905 REASON=S3 DRY_RUN=0)"
proof "1. S3 (bare shell): a fresh session under c-905, the shell window closed" c-905 - %5 S3
world; agent c-906 %6 4006; hb c-906 in-tool 1000 '| .tool = "Bash" | .tool_since = .progress_ts'
rc="$(take ID=c-906 REASON=S4 DRY_RUN=0 WD_EVIDENCE="tool=Bash")"
proof "1. S4 (a Bash call 16 min): the old pid TERMed, a fresh session" c-906 4006 %6 S4
world; agent c-907 %7 4007
hb c-907 working 60 "| .calls = [range(6) | {sig: \"a1\", res: \"r1\", ts: \"$(iso $((T0 - 60)))\"}]"
rc="$(take ID=c-907 REASON=S5 DRY_RUN=0 WD_EVIDENCE="sig=a1")"
proof "1. S5 (the same call 6 times): a fresh session" c-907 4007 %7 S5
world; agent c-908 %8 4008; hb c-908 idle 600; touch -d "@$((T0 - 300))" "$S/c-908/inbox/m1.json"
rc="$(take ID=c-908 REASON=S1 DRY_RUN=0 WD_EVIDENCE="age=300")"
proof "1. S1 (a message waits 300 s): a fresh session" c-908 4008 %8 S1
grep -q -- '"state": "idle"' "$S/c-908/handoff/$TS-wd-c-908.md" && pass "1. the ## watchdog section holds heartbeat.json" || fail "1. heartbeat in the handoff"

FX="$TEST_DIR/fixtures/wd-situations"
world; agent c-912 %12 4012; hb c-912 idle 60; cp "$FX/modal-default-mode.pane" "$T/tmux/screen.%12"
rc="$(take ID=c-912 REASON=S7 DRY_RUN=0 WD_EVIDENCE="modal=2 cursor=yes")"
proof "1b. S7 (the default-mode offer, modal=2): a fresh session" c-912 4012 %12 S7

# --- 2. a seat: the loop stopped and started again ------------------------------------
world; echo "c-004 claude" > "$S/peer/seats"; agent c-004 %4 4004; hb c-004 in-tool 1000 '| .tool = "Bash" | .tool_since = .progress_ts'
loop c-004; lpid="$(cat "$S/peer/c-004/poll.pid")"
rc="$(take ID=c-004 REASON=S4 DRY_RUN=0 REQ_FROM=c-002)"
proof "2. a seat (c-004, S4, requested by seat c-002): a fresh session" c-004 4004 %4 S4
! kill -0 "$lpid" 2>/dev/null && grep -q 'WD-LOOP OK the c-004 poll loop is stopped' "$T/o" && waitfor "$T/run.log" '^do_spl_peer_poll PEER_SEAT=c-004 ' &&
  pass "2. its poll loop stopped first, started again after" || fail "2. loop: $(cat "$T/o")"
grep -qx "$T0" "$D/wd/c-004.takeovers" && pass "2. a seat's request is counted in the hourly limit" || fail "2. count: $(cat "$D/wd/c-004.takeovers" 2>/dev/null)"

# --- 3. a role id writes rotate.hold while it runs --------------------------------------
world; agent c-003 %3 -
rc="$(take ID=c-003 REASON=S3 DRY_RUN=0)"
proof "3. a role id (c-003, S3): a fresh session" c-003 - %3 S3
[[ "$(cut -d' ' -f1,2 "$T/hold.at-spawn")" == "c-003 $T0" && ! -e "$D/rotate.hold" ]] &&
  pass "3. rotate.hold named c-003 during the spawn and is gone after" || fail "3. hold: $(cat "$T/hold.at-spawn") / $(cat "$D/rotate.hold" 2>/dev/null)"
world; agent c-905 %5 -; take ID=c-905 REASON=S3 DRY_RUN=0 >/dev/null
[[ "$(cat "$T/hold.at-spawn")" == none ]] && pass "3. control: a lane writes no rotate.hold" || fail "3. lane hold: $(cat "$T/hold.at-spawn")"

# --- 4. no hit -> exit 3 ----------------------------------------------------------------------
world; agent c-909 %9 4009; hb c-909 working 10
rc="$(take ID=c-909 REASON="looks stuck" DRY_RUN=0 REQ_FROM=c-002)"
[[ "$rc" == 3 ]] && grep -q 'REFUSED c-909: no takeover situation hits' "$T/o" && grep -q 'heartbeat: {"ts"' "$T/o" &&
  [[ ! -e "$T/spawn.log" ]] && alive 4009 && pass "4. a fresh agent: exit 3, the heartbeat quoted, nothing touched" || fail "4. no hit rc=$rc: $(cat "$T/o")"
grep -q 'WD-TAKEOVER REFUSED c-909' "$D/wd.log" && pass "4. the refusal is in wd.log" || fail "4. wd.log"
rc="$(take ID=c-909 REASON=S3 DRY_RUN=0 REQ_FROM=c-002)"
[[ "$rc" == 3 ]] && pass "4. REASON=S3 on a live session: exit 3" || fail "4. S3 on live rc=$rc"
world; agent c-910 %10 4010; hb c-910 idle 60 '| .api_error = "Login expired · Please run /login"'
rc="$(take ID=c-910 REASON=S2 DRY_RUN=0)"
[[ "$rc" == 3 && ! -e "$T/spawn.log" ]] && pass "4. S2 (login screen): no takeover, exit 3" || fail "4. S2 rc=$rc: $(cat "$T/o")"
world; agent c-913 %13 4013; hb c-913 idle 60; cp "$FX/trust.pane" "$T/tmux/screen.%13"
rc="$(take ID=c-913 REASON=S7 DRY_RUN=0)"
[[ "$rc" == 3 && ! -e "$T/spawn.log" ]] && alive 4013 && pass "4. S7 trust screen (modal=0): no takeover, exit 3" || fail "4. S7 modal=0 rc=$rc: $(cat "$T/o")"
rc="$(take ID=c-999 REASON=S3 DRY_RUN=0)"
[[ "$rc" == 3 ]] && grep -q 'not an agent of this box' "$T/o" && pass "4. an id with no window and no process: exit 3" || fail "4. unknown rc=$rc"

# --- 5. guards --------------------------------------------------------------------------------
world; agent c-911 %11 -; echo "$((T0 + 600))" > "$S/c-911/.human-hold"
rc="$(take ID=c-911 REASON=S3 DRY_RUN=0)"
[[ "$rc" == 4 && ! -e "$T/spawn.log" ]] && grep -q 'REFUSED c-911: human hold for 10 min' "$T/o" && pass "5. a human hold: refused (exit 4)" || fail "5. hold rc=$rc: $(cat "$T/o")"
rm -f "$S/c-911/.human-hold"
rc="$(take ID=c-911 REASON=S3 DRY_RUN=0)"
[[ "$rc" == 0 ]] && alive 3911 && pass "5. control: the hold lifted, the takeover runs" || fail "5. lifted rc=$rc: $(cat "$T/o")"
world; agent c-912 %12 -; echo "\$1 $((T0 - 20))" > "$T/tmux/clients"
rc="$(take ID=c-912 REASON=S3 DRY_RUN=0)"
[[ "$rc" == 4 ]] && grep -q 'a human client was active 20s ago' "$T/o" && pass "5. a human client active: refused" || fail "5. client rc=$rc: $(cat "$T/o")"
world; agent c-002 %2 -
rc="$(take ID=c-002 REASON=S3 DRY_RUN=0 REQ_FROM=c-002)"
[[ "$rc" == 4 ]] && grep -q 'may not request a takeover of itself' "$T/o" && pass "5. a takeover of itself: refused" || fail "5. self rc=$rc"
rc="$(take ID=c-002 REASON=S3 DRY_RUN=0 SPOOL_AGENT_ID=c-356)"
[[ "$rc" == 4 && ! -e "$T/spawn.log" ]] && grep -q 'c-356 is a lane' "$T/o" && pass "5. a lane's request: refused" || fail "5. lane rc=$rc"
world; agent c-913 %13 -; echo "c-001 $T0 r1" > "$D/rotate.hold"
rc="$(take ID=c-913 REASON=S3 DRY_RUN=0)"
[[ "$rc" == 4 ]] && grep -q 'rotate.hold names c-001' "$T/o" && pass "5. another id's rotation holds rotate.hold: refused" || fail "5. rotate.hold rc=$rc: $(cat "$T/o")"

# --- 6. limits ------------------------------------------------------------------------------
world; agent c-914 %14 -; mkdir -p "$D/wd"; echo "$((T0 - 1200))" > "$D/wd/c-914.takeovers"
rc="$(take ID=c-914 REASON=S3 DRY_RUN=0 REQ_FROM=c-001)"
[[ "$rc" == 0 ]] && pass "6. control: the second takeover in an hour runs" || fail "6. second rc=$rc: $(cat "$T/o")"
world; agent c-914 %14 -; mkdir -p "$D/wd"; printf '%s\n%s\n' "$((T0 - 1200))" "$((T0 - 600))" > "$D/wd/c-914.takeovers"
rc="$(take ID=c-914 REASON=S3 DRY_RUN=0 REQ_FROM=c-001)"
[[ "$rc" == 4 && ! -e "$T/spawn.log" && -s "$D/wd/c-914.heldout" ]] && grep -q 'held out: 2 takeovers' "$T/o" &&
  pass "6. a third in an hour: not done, held out (exit 4)" || fail "6. third rc=$rc: $(cat "$T/o")"
[[ "$(grep -c '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log")" == 1 && "$(grep -c '^do_spl_ask_put .*ASK_KIND=blocker' "$T/run.log")" == 1 ]] &&
  pass "6. ONE owner DM (and one ask)" || fail "6. DM: $(cat "$T/run.log")"
rc="$(take ID=c-914 REASON=S3 DRY_RUN=0 REQ_FROM=c-001)"
[[ "$rc" == 4 && "$(grep -c '^do_spl_desk_reply' "$T/run.log")" == 1 ]] && grep -q 'held out after' "$T/o" &&
  pass "6. a held-out id: refused again, no second DM" || fail "6. heldout again rc=$rc: $(cat "$T/o")"
world; agent c-915 %15 -; mkdir -p "$D/wd"; printf '%s\n%s\n' "$((T0 - 1200))" "$T0" > "$D/wd/c-915.takeovers"
rc="$(take ID=c-915 REASON=S3 DRY_RUN=0 WD_EVIDENCE="pane %15")"
[[ "$rc" == 0 ]] && pass "6. the watchdog's own call (already counted, 2 of 2) runs" || fail "6. watchdog count rc=$rc: $(cat "$T/o")"

# --- 7. a failed start ---------------------------------------------------------------------------
world; agent c-916 %16 4016; hb c-916 in-tool 1000 '| .tool = "Bash" | .tool_since = .progress_ts'; echo nostart > "$T/spawn.mode.c-916"
rc="$(take ID=c-916 REASON=S4 DRY_RUN=0)"
[[ "$rc" == 1 ]] && alive 4016 && [[ "$(win %16)" == c-916@box1 && -z "$(win %3916)" ]] && [[ ! -e "$T/kill.log" ]] &&
  pass "7. a fresh session that does not start: the old pid 4016 and its window name kept, the new window closed" ||
  fail "7. failed start rc=$rc win=$(win %16)/$(win %3916): $(cat "$T/o")"
[[ -s "$D/wd/c-916.heldout" ]] && grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log" && grep -q 'WD-SPAWN FAIL' "$D/rotate.log" &&
  [[ "$(tail -1 "$D/rotate.log" | cut -d' ' -f3,4)" == "DONE FAIL" ]] && ! grep -q -- '--kind blocker' "$T/sent" 2>/dev/null &&
  pass "7. held out, ask + owner DM, DONE FAIL, no investigation blocker" || fail "7. alert: $(cat "$D/rotate.log")"

# --- 8. dry run, relay ----------------------------------------------------------------------------
world; agent c-917 %17 -
rc="$(take ID=c-917 REASON=S3)"
[[ "$rc" == 0 && ! -e "$T/spawn.log" && ! -e "$D/rotate.log" && ! -e "$T/sent" ]] && grep -q "WD-GATE PLAN c-917" "$T/o" && grep -q 'WD-BLOCKER PLAN' "$T/o" &&
  pass "8. a dry run: PLAN lines, nothing spawned, logged or sent" || fail "8. dry rc=$rc: $(cat "$T/o")"
world
rc="$(take ID=c-917@box2 REASON=S3 DRY_RUN=0 REQ_FROM=c-002)"
[[ "$rc" == 0 ]] && grep -q -- "--from c-002 --to c-001@box2 --kind task --task wd-c-917-req-$TS " "$T/sent" &&
  grep -q 'REQ_FROM=c-002 DRY_RUN=0 ./run -a do_spl_wd_takeover' "$T/sent" && [[ ! -e "$T/spawn.log" ]] &&
  pass "8. an id on another box: relayed as one task to that box's c-001" || fail "8. relay rc=$rc: $(cat "$T/sent" 2>/dev/null) $(cat "$T/o")"
rm -f "$T/sent"; rc="$(take ID=c-917@box1 REASON=S3 DRY_RUN=0)"
[[ "$rc" == 3 && ! -s "$T/sent" ]] && pass "8. control: @<this box> is local, not relayed" || fail "8. local box rc=$rc"

echo "wd-takeover: $fails failure(s)"
exit $(( fails > 0 ))
