#!/usr/bin/env bash
# test-live-ack-shown.sh — scripts/spool-live-ack.sh, the agent hook's shown
# ack sender (spec 053 S1 and 4.5, SPL-6517, latency action 7). Throwaway
# SPOOL_ROOT, a stub spool binary that records its argv; no hub, no sidecar.
# The hub side (one row per shown message, none new on a second surfacing,
# no sidecar = dropped at once) is internal/hub/live_ack_shown_test.go.
# Sections 1-4 pin SPOOL_SUBMIT_SOCKET (the single-socket path); 5 is the
# fleet layout.
#   1. one run = one `spool live-ack --as <id> -- <ids...>`; a qualified
#      <id>@<box> is acked as <id>; the log line names rc (control: the stub
#      saw exactly those args)
#   2. no ids, or no agent: the binary is never started (control: 1 starts it)
#   3. a failing or hanging spool still exits 0, bounded by
#      SPOOL_LIVE_ACK_TIMEOUT (control: the log line carries rc=124 / rc=3)
#   4. spool-agent-hook.sh: a surfacing starts one sender with the shown ids;
#      a second Stop / hook with nothing new starts none; a hanging sender
#      does not delay the hook (control: it was started). Red control: the
#      parent commit hook fails the start checks of 4.
#   5. R7 a-826 W1, the fleet layout: SPOOL_ROOT is the fleet root with no
#      socket; the desks sit under the desk root that desk-root.inc.sh names
#      ($HOME/.local/share/csi-spl/cloud here). Every live desk socket whose
#      spool has the agent's dir (or link) gets one run, with SPOOL_SUBMIT_SOCKET
#      on it and <root>/<env>/bin/spool as the binary; a desk without the
#      agent, or without a socket, gets none; no desk = one "dropped" log
#      line, no run. Red control: the parent commit's sender dials nothing
#      there (5's run checks fail).
#   6. the log keeps its last 200 lines once it passes 400
#   7. c-001 b88ecb74 (a dry run on sat reached the live desks): an explicit
#      SPOOL_BIN wins over a desk's <env>/bin/spool; SPOOL_LIVE_ACK_DRY_RUN=1
#      starts no binary, so a listening desk socket counts 0 connects (control:
#      the same run without it counts 1). PATH starts with a recording spool,
#      so no run here can reach a real binary. Red control: the parent
#      commit's sender runs the desk binary under SPOOL_BIN and dials in a
#      dry run (7's checks fail).
#   8. R7 a-826 W2: under SPOOL_TEST=1 (t_sandbox sets it) the sender has no
#      default desk root, so desks under HOME are never walked: 0 runs and a
#      "<no desk root>" dropped line (control: SPOOL_FLEET_STATE_ROOT still
#      names them, 2 runs). Then the box user's real HOME and box.env, an id
#      seated in a real desk when one is readable, as a dry run (so nothing
#      can dial even if the guard broke): 0 would-be runs. Sections 5 and 7
#      unset SPOOL_TEST for their sandbox HOME. Red control: the parent
#      sender walks the sandbox HOME desks under SPOOL_TEST=1 (8's sandbox
#      checks fail); the real-HOME check is left out of the red run, because
#      the parent has no dry run and would dial.
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
# AF_UNIX paths stop at 107 bytes: the CI runner's T_TMP
# (/home/runner/work/_temp/tmp.X) plus the desk layout made 112, every bind
# failed and sections 5, 7 and 8 went red only in CI. The sandbox HOMEs
# live under a short /tmp dir instead.
T_SH="$(mktemp -d /tmp/la.XXXXXX)"
trap 'rm -rf "$T_SH"; t_cleanup' EXIT
SENDER="$T_SCRIPTS/spool-live-ack.sh"
STUB="$T_TMP/spool-stub"
ARGS="$T_TMP/args"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGS"
case "${STUB_MODE:-ok}" in
  ok) echo '{"acked":'"$(($# - 4))"'}' ;;
  fail) echo "spool: live-ack: sidecar: no hub session" >&2; exit 3 ;;
  hang) exec sleep 30 ;;
esac
STUB
chmod +x "$STUB"
export SPOOL_BIN="$STUB" STUB_ARGS="$ARGS" SPOOL_SUBMIT_SOCKET="$T_TMP/single.sock"
M1=11111111-2222-4333-8444-555555555555
M2=66666666-7777-4888-9999-aaaaaaaaaaaa
mkdir -p "$SPOOL_ROOT/c-901/lifetime" "$SPOOL_ROOT/c-902@box-t/lifetime"

echo "# 1. one run, one live-ack call"
bash "$SENDER" c-901 "$M1" "$M2"; rc=$?
eq "exit 0" 0 "$rc"
eq "the verb's argv" "live-ack --as c-901 -- $M1 $M2" "$(cat "$ARGS")"
has "the log line" "c-901 rc=0 $T_TMP/single.sock {\"acked\":2}" "$(cat "$SPOOL_ROOT/c-901/lifetime/live-ack.log")"
: > "$ARGS"
bash "$SENDER" "c-902@box-t" "$M1"
eq "a qualified dir is acked as its id" "live-ack --as c-902 -- $M1" "$(cat "$ARGS")"
check "its log is in the qualified dir" test -s "$SPOOL_ROOT/c-902@box-t/lifetime/live-ack.log"

echo "# 2. nothing to ack: no start"
: > "$ARGS"
bash "$SENDER" c-901; rc=$?
eq "no ids: exit 0" 0 "$rc"
bash "$SENDER" "" "$M1"
eq "no ids / no agent: spool never started" "" "$(cat "$ARGS")"

echo "# 3. a failing or hanging spool"
STUB_MODE=fail bash "$SENDER" c-901 "$M1"; rc=$?
eq "a failing verb: exit 0" 0 "$rc"
has "its rc is logged" "rc=3 $T_TMP/single.sock spool: live-ack: sidecar: no hub session" "$(tail -n1 "$SPOOL_ROOT/c-901/lifetime/live-ack.log")"
start=$(date +%s)
STUB_MODE=hang SPOOL_LIVE_ACK_TIMEOUT=1 bash "$SENDER" c-901 "$M1"; rc=$?
took=$(( $(date +%s) - start ))
eq "a hanging verb: exit 0" 0 "$rc"
check "bounded by the timeout (took ${took}s, cap 5)" test "$took" -le 5
has "the timeout is logged" "rc=124" "$(tail -n1 "$SPOOL_ROOT/c-901/lifetime/live-ack.log")"

echo "# 4. the agent hook starts the sender, detached"
HOOK="$T_SCRIPTS/spool-agent-hook.sh"
HD="$SPOOL_ROOT/c-903"
mkdir -p "$HD/inbox" "$HD/archive" "$HD/lifetime"
hmsg() {  # NAME MSG_ID
  printf '{"v":1,"msg_id":"%s","task_id":"t-1","from":"c-902","to":"c-903","kind":"note","body":"b"}' "$2" > "$HD/inbox/$1.json"
}
hk() {  # EVENT — the hook as c-903, a claude seat
  env SPOOL_AGENT_ID=c-903 SPOOL_HARNESS=claude SPOOL_BOX_ID=box-t HOOK_PID=4242 bash "$HOOK" "$1" <<<'{"tool_name":"Bash"}'
}
waitargs() {  # LINES — the detached sender's argv rows, up to 5 s
  local _; for _ in $(seq 50); do [ "$(grep -c . "$ARGS")" -ge "$1" ] && return 0; sleep 0.1; done; return 1
}
: > "$ARGS"
hmsg a1 "$M1"; hmsg a2 "$M2"
out="$(hk PreToolUse)"
has "4. the hook shows the messages" "msg_id: $M1" "$out"
check "4. a surfacing starts the sender" waitargs 1
eq "4. one call, the shown ids" "live-ack --as c-903 -- $M1 $M2" "$(cat "$ARGS")"
: > "$ARGS"
hk Stop >/dev/null; hk PreToolUse >/dev/null; sleep 1
eq "4. a second Stop / hook with nothing new starts none" "" "$(cat "$ARGS")"
M3=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
hmsg a3 "$M3"
start=$(date +%s%N)
out="$(STUB_MODE=hang SPOOL_LIVE_ACK_TIMEOUT=10 hk PreToolUse)"
ms=$(( ($(date +%s%N) - start) / 1000000 ))
has "4. a hanging sender: the hook still shows the message" "msg_id: $M3" "$out"
check "4. ... and returns at once (${ms} ms, cap 2000)" test "$ms" -le 2000
check "4. CONTROL: the hanging sender was started" waitargs 1

echo "# 5. the fleet layout: the desk sidecars"
unset SPOOL_SUBMIT_SOCKET SPOOL_FLEET_STATE_ROOT SPOOL_DESK_USER SPOOL_BOX_ENV
mkdir -p "$T_TMP/pathbin"
cat > "$T_TMP/pathbin/spool" <<'STUB'
#!/usr/bin/env bash
printf 'path-bin %s %s\n' "${SPOOL_SUBMIT_SOCKET:-}" "$*" >> "$STUB_ARGS"
echo '{"acked":1}'
STUB
chmod +x "$T_TMP/pathbin/spool"
export PATH="$T_TMP/pathbin:$PATH"
check "5. CONTROL: the spool on PATH is the recording stub" test "$(command -v spool)" = "$T_TMP/pathbin/spool"
: > "$SPOOL_ROOT/box.env"
H5="$T_SH/h5"
DR="$H5/.local/share/csi-spl/cloud"
sock() { mkdir -p "$(dirname "$1")" && python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
desk() { printf '%s/%s/desk/%s/box-t/spool' "$DR" "$1" "$2"; }
S5="$(desk prd t1)/.hub/submit.sock"
check "5. CONTROL: a desk socket path fits AF_UNIX (${#S5} < 108 bytes)" test "${#S5}" -lt 108
sock "$(desk prd t1)/.hub/submit.sock"; mkdir -p "$(desk prd t1)/c-905"
sock "$(desk prd w2)/.hub/submit.sock"; mkdir -p "$(desk prd w2)/c-001"; ln -s c-001 "$(desk prd w2)/c-905"
sock "$(desk dev t1)/.hub/submit.sock"; mkdir -p "$(desk dev t1)/c-001"
mkdir -p "$(desk prd w3)/.hub" "$(desk prd w3)/c-905"
mkdir -p "$DR/prd/bin"
cat > "$DR/prd/bin/spool" <<'STUB'
#!/usr/bin/env bash
printf 'prd-bin %s %s\n' "$SPOOL_SUBMIT_SOCKET" "$*" >> "$STUB_ARGS"
echo '{"acked":1}'
STUB
chmod +x "$DR/prd/bin/spool"
mkdir -p "$SPOOL_ROOT/c-905/lifetime"
check "5. CONTROL: the fleet root has no socket" test ! -e "$SPOOL_ROOT/.hub/submit.sock"
: > "$ARGS"
HOME="$H5" env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-905 "$M1"; rc=$?
eq "5. exit 0" 0 "$rc"
eq "5. one run per desk that announces c-905, its env's binary, its socket" \
  "prd-bin $(desk prd t1)/.hub/submit.sock live-ack --as c-905 -- $M1|prd-bin $(desk prd w2)/.hub/submit.sock live-ack --as c-905 -- $M1" \
  "$(sort "$ARGS" | paste -sd'|')"
hasnt "5. a desk without c-905 is not dialed" "$(desk dev t1)" "$(cat "$ARGS")"
hasnt "5. a desk without a socket is not dialed" "$(desk prd w3)" "$(cat "$ARGS")"
eq "5. one log line per run" 2 "$(grep -c " rc=0 $DR/prd/desk/" "$SPOOL_ROOT/c-905/lifetime/live-ack.log")"
: > "$ARGS"
HOME="$H5" env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-906 "$M1"
eq "5. no desk announces c-906: nothing runs" "" "$(cat "$ARGS")"
mkdir -p "$SPOOL_ROOT/c-906/lifetime"
HOME="$H5" env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-906 "$M1"
has "5. ... and one dropped line is logged" "no desk sidecar announces c-906 under $DR; ack dropped" "$(cat "$SPOOL_ROOT/c-906/lifetime/live-ack.log")"
: > "$ARGS"
HOME="$H5" SPOOL_FLEET_STATE_ROOT="$T_TMP/none" env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-905 "$M1"
eq "5. SPOOL_FLEET_STATE_ROOT wins over the default root (an empty one: no run)" "" "$(cat "$ARGS")"

echo "# 6. the log is capped"
L6="$SPOOL_ROOT/c-901/lifetime/live-ack.log"
seq 1 450 | sed 's/^/old /' > "$L6"
SPOOL_SUBMIT_SOCKET="$T_TMP/single.sock" bash "$SENDER" c-901 "$M1"
eq "6. past 400 lines: the last 200 are kept" 200 "$(wc -l < "$L6")"
has "6. ... the newest among them" "c-901 rc=0" "$(tail -n1 "$L6")"
SPOOL_SUBMIT_SOCKET="$T_TMP/single.sock" bash "$SENDER" c-901 "$M1"
eq "6. CONTROL: under 400 lines nothing is cut" 201 "$(wc -l < "$L6")"

echo "# 7. an explicit binary wins; a dry run dials nothing"
: > "$ARGS"
HOME="$H5" env -u SPOOL_TEST bash "$SENDER" c-905 "$M1"
eq "7. SPOOL_BIN set: the stub runs once per announcing desk" 2 "$(grep -c "^live-ack --as c-905 -- $M1\$" "$ARGS")"
hasnt "7. ... and the desk's prd/bin/spool runs 0 times" "prd-bin" "$(cat "$ARGS")"
: > "$ARGS"
out7="$(HOME="$H5" SPOOL_LIVE_ACK_DRY_RUN=1 env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-905 "$M1")"; rc=$?
eq "7. dry run: exit 0" 0 "$rc"
eq "7. dry run: no binary starts (desk, PATH or stub)" "" "$(cat "$ARGS")"
eq "7. dry run: it prints the 2 runs it would make" 2 "$(printf '%s\n' "$out7" | grep -c "^dry-run $DR/prd/desk/.*/submit.sock $DR/prd/bin/spool live-ack --as c-905 -- $M1\$")"
eq "7. dry run: 2 dry-run log lines" 2 "$(grep -c "rc=- .*dry-run $DR/prd/bin/spool: not started" "$SPOOL_ROOT/c-905/lifetime/live-ack.log")"
HOME="$H5" SPOOL_LIVE_ACK_DRY_RUN=1 SPOOL_SUBMIT_SOCKET="$T_TMP/single.sock" bash "$SENDER" c-901 "$M1" >/dev/null
eq "7. dry run on the single-socket path: the stub runs 0 times" "" "$(cat "$ARGS")"
# a listening desk socket that counts connects; its binary dials it
DR7="$T_SH/h7/.local/share/csi-spl/cloud"
S7="$DR7/prd/desk/t1/box-t/spool"
mkdir -p "$S7/.hub" "$S7/c-907" "$DR7/prd/bin" "$SPOOL_ROOT/c-907/lifetime"
cat > "$DR7/prd/bin/spool" <<'STUB'
#!/usr/bin/env bash
python3 -c 'import socket,sys; c=socket.socket(socket.AF_UNIX); c.connect(sys.argv[1]); c.close()' "$SPOOL_SUBMIT_SOCKET"
echo '{"acked":1}'
STUB
chmod +x "$DR7/prd/bin/spool"
N7="$T_TMP/connects7"
: > "$N7"
python3 -c '
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); s.settimeout(15)
try:
    while True:
        c,_=s.accept(); c.close()
        open(sys.argv[2],"a").write("1\n")
except socket.timeout:
    pass
' "$S7/.hub/submit.sock" "$N7" &
lpid=$!
for _ in $(seq 1 50); do [ -S "$S7/.hub/submit.sock" ] && break; sleep 0.1; done
check "7. CONTROL: the desk socket listens" test -S "$S7/.hub/submit.sock"
HOME="$T_SH/h7" SPOOL_LIVE_ACK_DRY_RUN=1 env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-907 "$M1" >/dev/null
sleep 0.3
eq "7. dry run: the live desk socket is dialed 0 times" 0 "$(wc -l < "$N7")"
HOME="$T_SH/h7" env -u SPOOL_BIN -u SPOOL_TEST bash "$SENDER" c-907 "$M1"
for _ in $(seq 1 30); do [ "$(wc -l < "$N7")" -ge 1 ] && break; sleep 0.1; done
eq "7. CONTROL: the same run without the dry run dials it once" 1 "$(wc -l < "$N7")"
kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null

echo "# 8. SPOOL_TEST=1: no default desk root"
check "8. CONTROL: the sandbox sets SPOOL_TEST=1" test "${SPOOL_TEST:-}" = 1
: > "$ARGS"
HOME="$H5" env -u SPOOL_BIN bash "$SENDER" c-905 "$M1"
eq "8. SPOOL_TEST=1: the HOME desks are not walked (0 runs)" "" "$(cat "$ARGS")"
has "8. ... and one dropped line names no desk root" "no desk sidecar announces c-905 under <no desk root>; ack dropped" "$(tail -n1 "$SPOOL_ROOT/c-905/lifetime/live-ack.log")"
HOME="$H5" SPOOL_FLEET_STATE_ROOT="$DR" env -u SPOOL_BIN bash "$SENDER" c-905 "$M1"
eq "8. CONTROL: SPOOL_FLEET_STATE_ROOT still names the desks under SPOOL_TEST=1 (2 runs)" 2 "$(grep -c '^prd-bin ' "$ARGS")"
# REAL-HOME-BEGIN
: > "$ARGS"
RH="$(getent passwd "$(id -un)" | cut -d: -f6)"
RBOX=/var/spool-hub/box.env; [ -f "$RBOX" ] || RBOX="$SPOOL_ROOT/box.env"
RDR="$(bash "$T_SCRIPTS/../lib/desk-root.inc.sh" "$RH" "$RBOX" 2>/dev/null)"
RID=c-001
for d in "$RDR"/*/desk/*/*/spool/c-[0-9]*; do [ -e "$d" ] && [ -S "${d%/*}/.hub/submit.sock" ] && { RID="${d##*/}"; break; }; done 2>/dev/null
mkdir -p "$SPOOL_ROOT/$RID/lifetime"
out8="$(HOME="$RH" SPOOL_BOX_ENV="$RBOX" SPOOL_LIVE_ACK_DRY_RUN=1 env -u SPOOL_BIN -u SPOOL_FLEET_STATE_ROOT -u SPOOL_SUBMIT_SOCKET bash "$SENDER" "$RID" "$M1")"
eq "8. real HOME ($RH, desk root ${RDR:-none}, id $RID), SPOOL_TEST=1, dry run: 0 would-be runs" "" "$out8"
eq "8. ... and nothing started" "" "$(cat "$ARGS")"
# REAL-HOME-END

t_done
