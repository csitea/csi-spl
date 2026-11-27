#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 181 row B11 + spec 192 row L3, the box side of the web-UI
#          sign-in relay, do_spl_ws_signin_relay, on fixtures under $T as the
#          current user standing in for each OS user: tmux and the CLI are
#          stubs, no real login, no hub, a fake input, token and email built
#          at run time. Box binding: SPL_WS_BASE/<tenant> + claim (a workspace
#          box), or no claim (an operator box).
#   1. (n=3) the switch is off by default: start and input refused rc 3 with
#      `state=failed reason=switch_off`, nothing sent to tmux; a switch
#      naming another kind refuses too
#   2. (n=2) start: DRY_RUN unset makes no session; DRY_RUN=0 starts the
#      CLI's own `auth login --claudeai` with W's CLAUDE_CONFIG_DIR and
#      reports the https URL its pane shows
#   3. (n=4) input: the line goes to tmux on STDIN (load-buffer -), Enter is
#      pressed; delivered with no new login file, signed_in + label once the
#      login file changed. In-test check: an input in an argv IS seen
#   4. (n=3) kinds: no wired login -> no_login; a kind handler file (seam 1)
#      is called with the bound user; end runs with the switch off
#   5. (n=3) out: the CLI's logout under W's config dir, the dir gone,
#      signed_out; the after-switch seam (2) runs; a dry run touches nothing
#   6. (n=3) renew: same account -> signed_in; another -> other_account,
#      also when it meets a start's open session (reopened, R7 N1)
#   7. (n=2) status: signed in, label, plan, expiry, weekly % and reset; an
#      expired login reads expired. R1: no token, email or input in it
#   8. (n=2) copy (seam 3): no_copy, else do_spl_ws_login_copy for W's user
#   9. (n=6) R7: another workspace on a claimed box, a customer W bound to
#      the fleet agent user, a caller that is not W's user; on an operator
#      box another tenant, a hosted customer, a caller that is not the agent
#      user are all refused with no tmux call; the operator itself signs in
#      as the agent user's main login (no CLAUDE_CONFIG_DIR)
#  10. (n=2) R10: two workspaces on one box: W1 start, input, out leaves W2's
#      login file byte-identical; W1's desk aimed at W2 is refused
#  11. (n=1) R1: the input, token and email are in no output, log or argv
#  12. (n=5) do_spl_desk_up's relay command: none while cnf
#      env.box.signin_relay_kinds is empty; W's own user on a claimed box;
#      the agent user on an operator box, through sudo -n when the desk is
#      another user, with SPL_CLAUDE_BIN = that user's own CLI (sudo resets
#      PATH, R7 W1); no CLI there -> the relay stays off
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ME=$(id -un)
RT=$(mktemp -d -p /dev/shm 2>/dev/null) || { echo "SKIP: no tmpfs /dev/shm"; exit 0; }
RT2=$(mktemp -d -p /dev/shm)
trap 'rm -rf "$T" "$RT" "$RT2"' EXIT
chmod 0700 "$RT" "$RT2"
[[ "$(stat -f -c %T "$RT")" == tmpfs ]] || { echo "SKIP: /dev/shm is not tmpfs"; exit 0; }
D="$RT/spool-claude" D2="$RT2/spool-claude" H="$T/home"
# $T/ws/wsb: a second home on the claimed base, so a missing claim check
# would let a wsb op start (R7 red control), not only fail on no binding.
mkdir -p "$H/.claude" "$T/stub" "$T/ws/wsa" "$T/ws/wsb" "$T/ws2/wsb" "$T/fleet"
echo wsa >"$T/ws/claim"; echo wsb >"$T/ws2/claim"
INPUT="relay-input-$RANDOM$RANDOM-fake" TOKEN="tok-$RANDOM$RANDOM-fake" EMAIL="person$RANDOM@example.com"
export TOKEN EMAIL

# tmux: has-session answers $T/has (0/1); capture-pane shows a vendor URL;
# load-buffer keeps its stdin in $T/buffer; set/show-options keep session
# options in $T/opt-<name>; Enter runs $T/on-enter. Every argv is logged.
cat >"$T/stub/tmux" <<'EOF'
#!/bin/sh
echo "tmux $*" >>"$STUB_LOG"
case " $* " in
  *" has-session "*) exit "$(cat "$STUB_DIR/has" 2>/dev/null || echo 1)" ;;
  *" new-session "*) echo 0 >"$STUB_DIR/has"; rm -f "$STUB_DIR"/opt-* ;;
  *" kill-session "*) echo 1 >"$STUB_DIR/has" ;;
  *" capture-pane "*) printf 'Browser did not open? Use the url below\r\nhttps://example.com/oauth/authorize?code=true&state=s1\r\nPaste code here if prompted >\n' ;;
  *" load-buffer "*) cat >"$STUB_DIR/buffer" ;;
  *" set-option "*) eval "k=\${$(($# - 1))} v=\${$#}"; printf '%s\n' "$v" >"$STUB_DIR/opt-$k" ;;
  *" show-options "*) eval "k=\${$#}"; cat "$STUB_DIR/opt-$k" 2>/dev/null ;;
  *" send-keys "*Enter*) [ -x "$STUB_DIR/on-enter" ] && "$STUB_DIR/on-enter" ;;
esac
exit 0
EOF
cat >"$T/stub/claude" <<'EOF'
#!/bin/sh
echo "claude cfg=${CLAUDE_CONFIG_DIR:-} $*" >>"$STUB_LOG"
case "$*" in
  "auth status --json") printf '{"loggedIn":true,"email":"%s","subscriptionType":"max","orgName":"x"}\n' "$EMAIL" ;;
  "auth logout") rm -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ;;
esac
EOF
chmod +x "$T/stub/tmux" "$T/stub/claude"

# login <dir> <json> <uuid> [expiresAt ms]: a fake sign-in in dir.
login() {
  mkdir -p "$1"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s-r","expiresAt":%s,"subscriptionType":"max"}}\n' \
    "$TOKEN" "$TOKEN" "${4:-4102444800000}" >"$1/.credentials.json"
  printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"%s"},"cachedUsageUtilization":{"accountUuid":"%s","fetchedAtMs":%s,"utilization":{"seven_day":{"utilization":42.7,"resets_at":"2099-01-01T00:00:00+00:00"}}}}\n' \
    "$3" "$EMAIL" "$3" "$(( $(date +%s) * 1000 ))" >"$2"
}
label() { printf 'acct-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"; }
# on_enter <uuid>: the stub's Enter signs W in to that account.
on_enter() { printf '#!/bin/sh\n. "%s/login.sh"; login "%s" "%s" "%s"\n' "$T" "$D" "$D/.claude.json" "$1" >"$T/on-enter"; chmod +x "$T/on-enter"; }
declare -f login >"$T/login.sh"

# wsr <VAR=value>...: the action as W (= this user) on a box claimed by wsa,
# stdin from $T/in; stdout and stderr in $T/o (all of it kept in $T/all).
wsr() {
  : >"$T/calls.log"
  SNIPPET=do_spl_ws_signin_relay IN_ORC_RUN="spl-ws-claude-signin spl-ws-signin-relay" in_orc HOME="$H" \
    SPL_WS_BASE="$T/ws" SPL_WS_USER="$ME" SPOOL_AGENT_USER=fleetusr TENANT_ID=wsa STUB_DIR="$T" \
    SPL_CLAUDE_SIGNIN_RUNTIME="$RT" SPL_SIGNIN_RELAY_WAIT=0 SIGNIN_RELAY_ID=r-1 TOKEN="$TOKEN" EMAIL="$EMAIL" \
    "$@" <"$T/in" >"$T/o" 2>&1
  local rc=$?
  cat "$T/o" "$T/calls.log" >>"$T/all"
  return "$rc"
}
report() { grep '^SIGNIN_RELAY ' "$T/o" | tail -n 1; }
notmux() { ! grep -qE 'new-session|load-buffer|send-keys' "$T/calls.log"; }
printf '%s\n' "$INPUT" >"$T/in"
ON=(SPL_SIGNIN_RELAY_KINDS="grok,claude")

# ---- 1. the switch is off by default --------------------------------------
for op in start input; do
  echo 1 >"$T/has"; rm -f "$T/buffer"
  wsr SIGNIN_RELAY_OP=$op DRY_RUN=0; rc=$?
  if (( rc == 3 )) && [[ "$(report)" == "SIGNIN_RELAY state=failed reason=switch_off" ]] && notmux && [[ ! -e "$T/buffer" ]]; then
    pass "1 switch off: $op refused rc 3, reported switch_off, nothing sent to tmux"
  else fail "1 switch off $op: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
done
wsr SIGNIN_RELAY_OP=start DRY_RUN=0 SPL_SIGNIN_RELAY_KINDS="grok mistral"; rc=$?
if (( rc == 3 )) && notmux; then pass "1 a switch naming other kinds -> refused rc 3"
else fail "1 other kinds: rc=$rc $(cat "$T/o")"; fi

# ---- 2. start ----------------------------------------------------------------
echo 1 >"$T/has"
wsr "${ON[@]}" SIGNIN_RELAY_OP=start; rc=$?
if (( rc == 0 )) && notmux && [[ "$(report)" == *"reason=dry_run"* ]]; then pass "2 DRY_RUN unset: no login session started"
else fail "2 dry run: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
wsr "${ON[@]}" SIGNIN_RELAY_OP=start DRY_RUN=0; rc=$?
call="$(grep new-session "$T/calls.log")"
if (( rc == 0 )) && [[ "$call" == *"-s signin-wsa "* && "$call" == *"CLAUDE_CONFIG_DIR=$D "* && "$call" == *"/claude auth login --claudeai" ]] &&
   [[ "$(report)" == "SIGNIN_RELAY state=url url=https://example.com/oauth/authorize?code=true&state=s1" ]]; then
  pass "2 DRY_RUN=0: the CLI's own login in tmux under W's config dir, its vendor URL reported"
else fail "2 start: rc=$rc $(cat "$T/o") call: $call"; fi

# ---- 3. input --------------------------------------------------------------
echo 0 >"$T/has"; rm -f "$T/buffer" "$T/on-enter"
wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0; rc=$?
if (( rc == 0 )) && [[ "$(cat "$T/buffer" 2>/dev/null)" == "$INPUT" ]] && grep -q 'paste-buffer -d -b spool-signin-wsa -t =signin-wsa' "$T/calls.log" &&
   grep -q 'send-keys -t =signin-wsa Enter' "$T/calls.log" && [[ "$(report)" == "SIGNIN_RELAY state=delivered" ]]; then
  pass "3 the input reached tmux on stdin, pasted, Enter pressed; delivered"
else fail "3 input: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log") buffer: $(cat "$T/buffer" 2>&1)"; fi
if grep -qF "$INPUT" "$T/calls.log" "$T/o"; then fail "3 the input is in an argv or the output"
else pass "3 the input is in no argv and no output line"; fi
on_enter u-one
wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0; rc=$?
if (( rc == 0 )) && [[ "$(report)" == "SIGNIN_RELAY state=signed_in account=$(label u-one)" ]]; then pass "3 a new login file -> signed_in with its label"
else fail "3 signed_in: rc=$rc $(cat "$T/o")"; fi
: >"$T/calls.log"
STUB_LOG="$T/calls.log" STUB_DIR="$T" "$T/stub/tmux" send-keys -l "$INPUT"
if grep -qF "$INPUT" "$T/calls.log"; then pass "3 in-test check: an input in send-keys' argv is seen by the check"
else fail "3 in-test check: the argv check is blind"; fi
rm -f "$T/on-enter"

# ---- 4. kinds; end -----------------------------------------------------------
wsr SPL_SIGNIN_RELAY_KINDS=grok SIGNIN_RELAY_KIND=grok SIGNIN_RELAY_OP=start DRY_RUN=0 SPL_WSR_KINDS_FILE="$T/none"; rc=$?
if (( rc == 1 )) && [[ "$(report)" == *"reason=no_login" ]] && notmux; then pass "4 grok with no handler: no_login"
else fail "4 grok: rc=$rc $(cat "$T/o")"; fi
printf 'spl_wsk_grok() { echo "grok-handler $1 $2 $3 $4"; spl_wsr_report url "" https://example.com/g; }\n' >"$T/kinds.sh"
wsr SPL_SIGNIN_RELAY_KINDS=grok SIGNIN_RELAY_KIND=grok SIGNIN_RELAY_OP=start DRY_RUN=0 SPL_WSR_KINDS_FILE="$T/kinds.sh"; rc=$?
if (( rc == 0 )) && grep -qx "grok-handler start wsa $ME 0" "$T/o" && [[ "$(report)" == *"url=https://example.com/g" ]]; then
  pass "4 seam 1: the kind file's handler runs with the bound user"
else fail "4 seam 1: rc=$rc $(cat "$T/o")"; fi
wsr SIGNIN_RELAY_OP=end DRY_RUN=0; rc=$?
if (( rc == 0 )) && grep -q 'kill-session -t =signin-wsa' "$T/calls.log" && [[ "$(report)" == "SIGNIN_RELAY state=ended" ]]; then
  pass "4 end with the switch off: session ended, reported ended"
else fail "4 end: rc=$rc $(cat "$T/o")"; fi

# ---- 5. out ------------------------------------------------------------------
login "$D" "$D/.claude.json" u-one
wsr SIGNIN_RELAY_OP=out; rc=$?
if (( rc == 0 )) && [[ -e "$D/.credentials.json" ]] && ! grep -q 'auth logout' "$T/calls.log"; then pass "5 out DRY_RUN unset: nothing touched"
else fail "5 out dry: rc=$rc $(cat "$T/o")"; fi
RESTART='do_spl_ws_vendor_restart() { echo "restart $TENANT_ID $VENDOR_KIND $DRY_RUN" >>"$STUB_LOG"; }; do_spl_ws_signin_relay'
wsr SNIPPET="$RESTART" SIGNIN_RELAY_OP=out DRY_RUN=0; rc=$?
if (( rc == 0 )) && grep -qx "claude cfg=$D auth logout" "$T/calls.log" && [[ ! -e "$D" ]] && [[ "$(report)" == "SIGNIN_RELAY state=signed_out" ]]; then
  pass "5 out: the CLI's logout under W's config dir, the dir removed, signed_out (switch off)"
else fail "5 out: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
if grep -qx "restart wsa claude 0" "$T/calls.log"; then pass "5 seam 2: the after-switch hook ran"
else fail "5 seam 2: $(cat "$T/calls.log")"; fi

# ---- 6. renew ----------------------------------------------------------------
for acct in u-one u-two; do
  login "$D" "$D/.claude.json" u-one 1000
  echo 1 >"$T/has"
  wsr "${ON[@]}" SIGNIN_RELAY_OP=renew DRY_RUN=0 >/dev/null
  on_enter "$acct"
  wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0; rc=$?
  if [[ "$acct" == u-one ]] && (( rc == 0 )) && [[ "$(report)" == "SIGNIN_RELAY state=signed_in account=$(label u-one)" ]]; then
    pass "6 renew, same account -> signed_in"
  elif [[ "$acct" == u-two ]] && (( rc == 1 )) && [[ "$(report)" == "SIGNIN_RELAY state=failed reason=other_account account=$(label u-two)" ]]; then
    pass "6 renew, another account -> failed other_account"
  else fail "6 renew $acct: rc=$rc $(cat "$T/o") opts: $(cat "$T"/opt-* 2>&1)"; fi
done
# N1: a renew that meets a start's session (no @spl_prior) reopens it, so the
# other_account check still holds.
login "$D" "$D/.claude.json" u-one 1000
echo 0 >"$T/has"; rm -f "$T"/opt-*
wsr "${ON[@]}" SIGNIN_RELAY_OP=renew DRY_RUN=0 >/dev/null
reopened=0; grep -q ' kill-session ' "$T/calls.log" && grep -q ' new-session ' "$T/calls.log" && reopened=1
on_enter u-two
wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0; rc=$?
if (( rc == 1 && reopened )) && [[ "$(report)" == "SIGNIN_RELAY state=failed reason=other_account account=$(label u-two)" ]]; then
  pass "6 renew over a start's open session reopens it: another account -> failed other_account"
else fail "6 renew over an open session: rc=$rc $(cat "$T/o")"; fi
rm -f "$T/on-enter"

# ---- 7. status ---------------------------------------------------------------
login "$D" "$D/.claude.json" u-one
wsr SIGNIN_RELAY_OP=status; rc=$?
want="SIGNIN_RELAY state=status signed_in=yes account=$(label u-one) plan=max expires=4102444800 weekly=42 reset=4070908800"
if (( rc == 0 )) && [[ "$(report)" == "$want" ]]; then pass "7 status: signed in, label, plan, expiry, weekly % and reset"
else fail "7 status: rc=$rc got '$(report)' want '$want'"; fi
login "$D" "$D/.claude.json" u-one 1000
wsr SIGNIN_RELAY_OP=status; rc=$?
if (( rc == 0 )) && [[ "$(report)" == *" signed_in=expired "*" expires=1 "* ]]; then pass "7 status: an old login reads expired"
else fail "7 expired: rc=$rc $(report)"; fi

# ---- 8. copy -----------------------------------------------------------------
wsr SIGNIN_RELAY_OP=copy DRY_RUN=0; rc=$?
if (( rc == 1 )) && [[ "$(report)" == "SIGNIN_RELAY state=failed reason=no_copy" ]]; then pass "8 copy, no L8 action: no_copy"
else fail "8 no_copy: rc=$rc $(cat "$T/o")"; fi
wsr SNIPPET='do_spl_ws_login_copy() { echo "copy $TENANT_ID $VENDOR_KIND $WS_LOGIN_USER $DRY_RUN"; }; do_spl_ws_signin_relay' SIGNIN_RELAY_OP=copy; rc=$?
if (( rc == 0 )) && grep -qx "copy wsa claude $ME 1" "$T/o"; then pass "8 seam 3: do_spl_ws_login_copy for W's user, dry run kept"
else fail "8 copy: rc=$rc $(cat "$T/o")"; fi

# ---- 9. R7: the bound user only ---------------------------------------------
# r7 <want reason> <label> <VAR=value>...: refused, nothing sent to tmux.
r7() {
  local why="$1" what="$2"; shift 2
  echo 1 >"$T/has"
  wsr "${ON[@]}" SIGNIN_RELAY_OP=start DRY_RUN=0 "$@"; local rc=$?
  if (( rc == 1 )) && [[ "$(report)" == "SIGNIN_RELAY state=failed reason=$why" ]] && notmux; then pass "9 R7: $what -> $why"
  else fail "9 R7 $what: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
}
rm -rf "$D"
r7 other_workspace "another workspace on a box claimed by wsa" TENANT_ID=wsb
r7 wrong_user "a customer W bound to the fleet's agent user" SPOOL_AGENT_USER="$ME"
r7 bad_user "W's binding owned by another user than W's" SPL_WS_USER=spl-other
OP=(SPL_WS_BASE="$T/none" SPOOL_TENANT=t1 SPOOL_AGENT_USER="$ME" SPL_FLEET_WS_BASE="$T/fleet" TENANT_ID=t1)
r7 other_workspace "operator box, a tenant that is not its desk's" "${OP[@]}" TENANT_ID=wsb SPOOL_TENANT=t1
mkdir -p "$T/fleet/t1"
r7 customer_user "operator box, a customer hosted on it" "${OP[@]}"
rmdir "$T/fleet/t1"
r7 wrong_user "operator box, a caller that is not the agent user" "${OP[@]}" SPOOL_AGENT_USER=fleetusr
echo 1 >"$T/has"
wsr "${ON[@]}" SIGNIN_RELAY_OP=start DRY_RUN=0 "${OP[@]}"; rc=$?
call="$(grep new-session "$T/calls.log")"
if (( rc == 0 )) && [[ -n "$call" && "$call" != *CLAUDE_CONFIG_DIR* ]] && [[ -d "$H/.claude" ]]; then
  pass "9 operator box: the operator signs in as the agent user's main login"
else fail "9 operator: rc=$rc $(cat "$T/o") call: $call"; fi

# ---- 10. R10: two workspaces on one box ------------------------------------
login "$D2" "$D2/.claude.json" u-two
before="$(sha256sum "$D2/.credentials.json" "$D2/.claude.json")"
echo 1 >"$T/has"; on_enter u-one
wsr "${ON[@]}" SIGNIN_RELAY_OP=start DRY_RUN=0 >/dev/null
wsr "${ON[@]}" SIGNIN_RELAY_OP=input DRY_RUN=0 >/dev/null
wsr SIGNIN_RELAY_OP=out DRY_RUN=0 >/dev/null
if [[ "$(sha256sum "$D2/.credentials.json" "$D2/.claude.json" 2>&1)" == "$before" && ! -e "$D" ]]; then
  pass "10 R10: W1 start, input, out left W2's login untouched"
else fail "10 R10: W2's login changed or W1's remains"; fi
echo 1 >"$T/has"
wsr "${ON[@]}" SIGNIN_RELAY_OP=start DRY_RUN=0 TENANT_ID=wsb SPL_CLAUDE_SIGNIN_RUNTIME="$RT2"; rc=$?
if (( rc == 1 )) && [[ "$(report)" == *"reason=other_workspace" ]] && notmux; then pass "10 R10: W1's desk aimed at W2 is refused"
else fail "10 R10 aimed: rc=$rc $(cat "$T/o")"; fi
rm -f "$T/on-enter"

# ---- 11. R1 ----------------------------------------------------------------
if grep -qF -e "$INPUT" -e "$TOKEN" -e "$EMAIL" "$T/all"; then fail "11 R1: the input, a token or an email is in an output, a log or an argv"
else pass "11 R1: no input, token or email in any output, log or argv ($(wc -l <"$T/all") lines)"; fi

# ---- 12. do_spl_desk_up wires SPOOL_SIGNIN_RELAY_CMD (owner Q1 A) -----------
# cmd <kinds> <VAR=value>...: spl_desk_signin_relay_cmd's answer for tenant wsa.
cmd() {
  printf 'env:\n  box:\n    signin_relay_kinds: "%s"\n' "$1" >"$T/cnf.yaml"; shift
  SNIPPET='spl_desk_signin_relay_cmd wsa' IN_ORC_RUN=spl-desk-up in_orc SPL_CNF="$T/cnf.yaml" SPL_ORG_APP=csi-spl \
    SPL_WS_BASE="$T/ws" "$@" 2>/dev/null
}
RUN="$APP_ROOT/csi-spl-orc/run -a do_spl_ws_signin_relay"
got="$(cmd "")"
if [[ -z "$got" ]]; then pass "12 cnf signin_relay_kinds empty: no relay command, the relay stays off"
else fail "12 off: '$got'"; fi
got="$(cmd claude)"
if [[ "$got" == "env ENV=dev TENANT_ID=wsa SPOOL_TENANT=wsa $RUN" ]]; then pass "12 a claimed box: the relay as the desk's own (W's) user"
else fail "12 claimed: '$got'"; fi
got="$(cmd claude SPL_WS_BASE="$T/none" SPOOL_AGENT_USER="$ME")"
if [[ "$got" == "env ENV=dev TENANT_ID=wsa SPOOL_TENANT=wsa SPOOL_AGENT_USER=$ME $RUN" ]]; then pass "12 an operator box, desk = agent user: no sudo"
else fail "12 operator same user: '$got'"; fi
# sudo: the agent user's login shell finds its CLI (fleetusr); nocli has none.
cat >"$T/stub/sudo" <<'EOF2'
#!/bin/sh
echo "sudo $*" >>"$STUB_LOG"
[ "$*" = "-n -u fleetusr bash -lc command -v claude" ] && echo /opt/fleet-cli/bin/claude
exit 0
EOF2
chmod +x "$T/stub/sudo"
got="$(cmd claude SPL_WS_BASE="$T/none" SPOOL_AGENT_USER=fleetusr)"
if [[ "$got" == "sudo -n --preserve-env=SIGNIN_RELAY_OP,SIGNIN_RELAY_KIND,SIGNIN_RELAY_ID,DRY_RUN -u fleetusr env ENV=dev TENANT_ID=wsa SPOOL_TENANT=wsa SPOOL_AGENT_USER=fleetusr SPL_CLAUDE_BIN=/opt/fleet-cli/bin/claude $RUN" ]]; then
  pass "12 an operator box, desk = another user: sudo -n to the agent user, its CLI by absolute path (sudo drops ~/.local/bin)"
else fail "12 operator sudo: '$got'"; fi
got="$(cmd claude SPL_WS_BASE="$T/none" SPOOL_AGENT_USER=nocli)"
if [[ -z "$got" ]]; then pass "12 an operator box, the agent user has no claude CLI: the relay stays off"
else fail "12 operator no CLI: '$got'"; fi
rm -f "$T/stub/sudo"

echo "-- ws-signin-relay.tst.sh: $fails failed"
(( fails == 0 ))
