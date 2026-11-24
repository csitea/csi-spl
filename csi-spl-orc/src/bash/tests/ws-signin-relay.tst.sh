#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 181 row B11, the VM side of the web-UI sign-in relay,
#          do_spl_ws_signin_relay, on fixtures under $T as the current user
#          standing in for W's OS user: tmux and the CLI are stubs, no real
#          login, no hub, a fake input built at run time.
#   1. (n=3) the switch is off by default: start and input refused rc 3 with
#      the report `state=failed reason=switch_off` and no tmux session made,
#      no input read into tmux; a switch naming another kind refuses too.
#      RED CONTROL of the row ("the switch off -> the relay refuses")
#   2. (n=2) switch on, DRY_RUN unset: start makes no session; DRY_RUN=0
#      starts the CLI's own `auth login --claudeai` in tmux session
#      signin-wsa and reports the https URL its pane shows
#   3. (n=4) input: the line goes to tmux on STDIN (load-buffer -), never in
#      an argv or the output; Enter is pressed; delivered with no sign-in
#      file, signed_in with one. RED CONTROL: the same line given by argv
#      (send-keys -l) is seen by the argv check
#   4. (n=2) a kind with no wired login -> no_login; end with the switch off
#      ends the session and reports ended
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ME=$(id -un)
RT=$(mktemp -d -p /dev/shm 2>/dev/null) || { echo "SKIP: no tmpfs /dev/shm"; exit 0; }
trap 'rm -rf "$T" "$RT"' EXIT
chmod 0700 "$RT"
[[ "$(stat -f -c %T "$RT")" == tmpfs ]] || { echo "SKIP: /dev/shm is not tmpfs"; exit 0; }
D="$RT/spool-claude" H="$T/home"
mkdir -p "$H" "$T/stub"
INPUT="relay-input-$RANDOM$RANDOM-fake"

# tmux: has-session answers $T/has (0/1); capture-pane shows a vendor URL;
# load-buffer keeps its stdin in $T/buffer; every argv is logged.
cat >"$T/stub/tmux" <<'EOF'
#!/bin/sh
echo "tmux $*" >>"$STUB_LOG"
case " $* " in
  *" has-session "*) exit "$(cat "$STUB_DIR/has" 2>/dev/null || echo 1)" ;;
  *" new-session "*) echo 0 >"$STUB_DIR/has" ;;
  *" capture-pane "*) printf 'Browser did not open? Use the url below\r\nhttps://example.com/oauth/authorize?code=true&state=s1\r\nPaste code here if prompted >\n' ;;
  *" load-buffer "*) cat >"$STUB_DIR/buffer" ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "claude $*" >>"$STUB_LOG"\n' >"$T/stub/claude"
chmod +x "$T/stub/tmux" "$T/stub/claude"

# wsr <VAR=value>...: the action as W (= this user), stdin from $T/in.
wsr() {
  : >"$T/calls.log"
  SNIPPET=do_spl_ws_signin_relay IN_ORC_RUN="spl-ws-claude-signin spl-ws-signin-relay" in_orc HOME="$H" \
    SPL_WS_USER="$ME" SPOOL_AGENT_USER=fleetusr TENANT_ID=wsa STUB_DIR="$T" SPL_CLAUDE_SIGNIN_RUNTIME="$RT" \
    SPL_SIGNIN_RELAY_WAIT=0 SIGNIN_RELAY_ID=r-1 "$@" <"$T/in" >"$T/o" 2>&1
}
report() { grep '^SIGNIN_RELAY ' "$T/o" | tail -n 1; }
printf '%s\n' "$INPUT" >"$T/in"

# ---- 1. the switch is off by default --------------------------------------
for op in start input; do
  echo 1 >"$T/has"; rm -f "$T/buffer"
  wsr SIGNIN_RELAY_OP=$op DRY_RUN=0; rc=$?
  if (( rc == 3 )) && [[ "$(report)" == "SIGNIN_RELAY state=failed reason=switch_off" ]] &&
     ! grep -qE 'new-session|load-buffer|send-keys' "$T/calls.log" && [[ ! -e "$T/buffer" ]]; then
    pass "1 switch off: $op refused rc 3, reported switch_off, nothing sent to tmux"
  else fail "1 switch off $op: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
done
wsr SIGNIN_RELAY_OP=start DRY_RUN=0 SPL_SIGNIN_RELAY_KINDS="grok mistral"; rc=$?
if (( rc == 3 )) && ! grep -q new-session "$T/calls.log"; then pass "1 a switch naming other kinds -> refused rc 3"
else fail "1 other kinds: rc=$rc $(cat "$T/o")"; fi

ON=(SPL_SIGNIN_RELAY_KINDS="grok,claude")
# ---- 2. start ----------------------------------------------------------------
echo 1 >"$T/has"
wsr "${ON[@]}" SIGNIN_RELAY_OP=start; rc=$?
if (( rc == 0 )) && ! grep -q new-session "$T/calls.log" && [[ "$(report)" == *"reason=dry_run"* ]]; then
  pass "2 DRY_RUN unset: no login session started"
else fail "2 dry run: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
wsr "${ON[@]}" SIGNIN_RELAY_OP=start DRY_RUN=0; rc=$?
call="$(grep new-session "$T/calls.log")"
if (( rc == 0 )) && [[ "$call" == *"-s signin-wsa "* && "$call" == *"CLAUDE_CONFIG_DIR=$D "* && "$call" == *"/claude auth login --claudeai" ]] &&
   [[ "$(report)" == "SIGNIN_RELAY state=url url=https://example.com/oauth/authorize?code=true&state=s1" ]]; then
  pass "2 DRY_RUN=0: the CLI's own login in tmux, its vendor URL reported"
else fail "2 start: rc=$rc $(cat "$T/o") call: $call"; fi

# ---- 3. input --------------------------------------------------------------
echo 0 >"$T/has"; rm -f "$T/buffer"
wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0; rc=$?
if (( rc == 0 )) && [[ "$(cat "$T/buffer" 2>/dev/null)" == "$INPUT" ]] && grep -q 'paste-buffer -d -b spool-signin-wsa -t =signin-wsa' "$T/calls.log" &&
   grep -q 'send-keys -t =signin-wsa Enter' "$T/calls.log" && [[ "$(report)" == "SIGNIN_RELAY state=delivered" ]]; then
  pass "3 the input reached tmux on stdin, pasted, Enter pressed; delivered"
else fail "3 input: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log") buffer: $(cat "$T/buffer" 2>&1)"; fi
if grep -qF "$INPUT" "$T/calls.log" "$T/o"; then fail "3 the input is in an argv or the output"
else pass "3 the input is in no argv and no output line"; fi
mkdir -p "$D" && : >"$D/.credentials.json"
wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0; rc=$?
if (( rc == 0 )) && [[ "$(report)" == "SIGNIN_RELAY state=signed_in" ]]; then pass "3 a sign-in file -> signed_in"
else fail "3 signed_in: rc=$rc $(cat "$T/o")"; fi
rm -f "$D/.credentials.json"
# RED CONTROL: the argv check sees an input passed the way it must not be.
: >"$T/calls.log"
STUB_LOG="$T/calls.log" STUB_DIR="$T" "$T/stub/tmux" send-keys -l "$INPUT"
if grep -qF "$INPUT" "$T/calls.log"; then pass "3 RED CONTROL: an input in send-keys' argv is seen by the check"
else fail "3 RED CONTROL: the argv check is blind"; fi

# ---- 4. no wired login; end -------------------------------------------------
wsr SPL_SIGNIN_RELAY_KINDS=grok SIGNIN_RELAY_KIND=grok SIGNIN_RELAY_OP=start DRY_RUN=0; rc=$?
if (( rc == 1 )) && [[ "$(report)" == *"reason=no_login" ]] && ! grep -q new-session "$T/calls.log"; then pass "4 grok: no terminal login wired -> no_login"
else fail "4 grok: rc=$rc $(cat "$T/o")"; fi
wsr SIGNIN_RELAY_OP=end DRY_RUN=0; rc=$?
if (( rc == 0 )) && grep -q 'kill-session -t =signin-wsa' "$T/calls.log" && [[ "$(report)" == "SIGNIN_RELAY state=ended" ]]; then
  pass "4 end with the switch off: session ended, reported ended"
else fail "4 end: rc=$rc $(cat "$T/o")"; fi

echo "-- ws-signin-relay.tst.sh: $fails failed"
(( fails == 0 ))
