#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_login_check (the agent login self-heal) on a temp root:
# fixture agents, panes, transcripts and two credential files ("here" and one
# peer), with claude -p, kill, the restore, the pane close and the send all
# stubbed; every call lands in $T/calls.
#   1. a healthy box: 0 actions (only the probe runs), one summary line
#   2. control: one pane on "Login expired" with an API-error transcript ->
#      its pid stopped, ONE restore of that id, its old pane closed, one alert
#   3. the words on a pane whose transcript is fine: not stuck
#   4. a dead login here with a working newer one on the peer: copied here
#      (temp + mv, .bak-login-<UTC> kept, mode 600), then stop + restore +
#      alert; no credential content in any output or call
#   5. control: the peer's login does not work either -> no copy, no stop,
#      no restore, an alert only
#   6. both boxes limited -> no copy, no stop, one alert; the same state on the
#      next tick sends nothing (deduplicated)
#   7. this box newer and working: copied TO the peer (the one refresher)
#   8. DRY_RUN=1 plans and changes nothing; the live spool root is refused
#   9. the cred script refuses an input that is no Claude login
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CRED="$PROJ_ROOT/src/bash/scripts/agent-login-cred.sh"
mkdir -p "$T/bin" "$T/panes" "$T/turn"
cat >"$T/bin/capture" <<EOF
#!/bin/sh
cat "$T/panes/\$1" 2>/dev/null
EOF
cat >"$T/bin/turn" <<EOF
#!/bin/sh
cat "$T/turn/\$1" 2>/dev/null || echo ok
EOF
for b in kill close; do printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$b" "$T" >"$T/bin/$b"; done
cat >"$T/bin/restore" <<EOF
#!/bin/sh
echo "restore ids=\$IDENTITY_RESTORE_IDS dry=\$DRY_RUN" >>"$T/calls"
for i in \$IDENTITY_RESTORE_IDS; do echo "STARTED \$i: claude session s in /w [%9]"; done
EOF
cat >"$T/bin/send" <<EOF
#!/bin/sh
echo "send \$*" >>"$T/calls"
EOF
# The peer: the same cred script against the peer's file and probe.
cat >"$T/bin/peer" <<EOF
#!/bin/sh
echo "peer \$1 \$2" >>"$T/calls"
LOGIN_CRED_FILE="$T/peer/cred.json" LOGIN_PROBE_CMD="cat '$T/peer/probe'" exec bash "$CRED" "\$2"
EOF
chmod +x "$T/bin/"*

# cred FILE MARK EXPIRES-MS: a fake login; MARK goes into the refresh token.
cred() { mkdir -p "${1%/*}"; printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-%s-secret","expiresAt":%s}}\n' "$2" "$2" "$3" >"$1"; chmod 600 "$1"; }
# The probe here answers from the credential it finds: GOOD works.
PROBE_HERE="echo probe >>'$T/calls'; grep -q rt-GOOD '$T/here/cred.json' && echo ok || cat '$T/here/probe-dead'"

reset() {
  rm -rf "$T/spool" "$T/state" "$T/here" "$T/peer" "$T/calls" "$T/panes/"* "$T/turn/"*
  mkdir -p "$T/spool/dispatch" "$T/here" "$T/peer"; touch "$T/calls"
  echo "c-002@box1 1791742397" >"$T/spool/dispatch/lease"
  echo "LEASE_ORCH=c-001" >"$T/spool/dispatch/lease.conf"
  printf 'c-701 999999701 %%11\nc-702 999999702 %%12\n' >"$T/agents"
  printf 'working on it\n  ✻ Thinking… (3s)\n' >"$T/panes/%11"; cp "$T/panes/%11" "$T/panes/%12"
  echo "Failed to authenticate: OAuth session expired and could not be refreshed" >"$T/here/probe-dead"
  cred "$T/here/cred.json" GOOD 2000; cred "$T/peer/cred.json" GOOD 2000; echo ok >"$T/peer/probe"
}
stuck_login() { printf 'old text\nLogin expired · Please run /login\n' >"$T/panes/$1"; echo error >"$T/turn/$2"; }

tick() {
  SNIPPET='do_spl_agent_login_check' in_orc SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box1 LOGIN_STATE_DIR="$T/state" \
    LOGIN_AGENTS_CMD="cat '$T/agents'" LOGIN_CAPTURE_CMD="$T/bin/capture" LOGIN_TURN_CMD="$T/bin/turn" \
    LOGIN_KILL_CMD="$T/bin/kill" LOGIN_RESTORE_CMD="$T/bin/restore" LOGIN_CLOSE_CMD="$T/bin/close" LOGIN_SEND="$T/bin/send" \
    LOGIN_CRED_CMD="env LOGIN_CRED_FILE=$T/here/cred.json LOGIN_SUDO= bash $CRED" LOGIN_PROBE_CMD="$PROBE_HERE" \
    LOGIN_PEER_CMD="$T/bin/peer" LOGIN_PEERS="sat=satellite" LOGIN_PROBE_EVERY=0 DRY_RUN="${DRY:-0}" 2>&1
}
acts() { grep -vcE '^(probe|peer [^ ]+ (stat|probe))$' "$T/calls"; }
leaks() { grep -rlE 'rt-[A-Z]+-secret|at-[A-Z]+' "$@" 2>/dev/null | grep -v '/cred.json' | grep -vc 'bak-login'; }

# 1. healthy
reset
out="$(tick)"; rc=$?
[ "$rc" = 0 ] && [ "$(acts)" = 0 ] && grep -q 'probe=ok stuck_login=0 stuck_limit=0 copied=0 stopped=0 restored=0 failed=0 alerted=0$' <<<"$out" \
  && pass "1. a healthy box: 0 actions, one summary line" || fail "1. healthy (rc $rc: $out; calls: $(cat "$T/calls"))"
[ "$(grep -c '^probe$' "$T/calls")" = 1 ] && pass "1. ...the probe ran once" || fail "1. probes: $(cat "$T/calls")"

# 2. control: one stuck pane
reset; stuck_login %12 999999702
out="$(tick)"; rc=$?
[ "$rc" = 0 ] && grep -qx 'kill TERM 999999702' "$T/calls" && [ "$(grep -c '^kill' "$T/calls")" = 1 ] \
  && pass "2. the stuck agent's own pid is stopped, and only it" || fail "2. stop (rc $rc: $out; $(cat "$T/calls"))"
grep -qx 'restore ids=c-702 dry=0' "$T/calls" && [ "$(grep -c '^restore' "$T/calls")" = 1 ] && grep -qx 'close c-702 %12' "$T/calls" \
  && pass "2. ONE restore of c-702, its old pane closed" || fail "2. restore ($(cat "$T/calls"))"
grep -q '^send .*--to c-002 --kind note .*stuck panes before: 1 login, 0 limit.*stopped 1, restored 1' "$T/calls" \
  && grep -q 'stopped=1 restored=1 failed=0 alerted=1' <<<"$out" \
  && pass "2. one alert to the dispatch holder with the counts" || fail "2. alert ($out; $(cat "$T/calls"))"

# 3. the words on a pane, transcript fine
reset; printf 'we discussed: Login expired · Please run /login\n' >"$T/panes/%11"
out="$(tick)"
[ "$(acts)" = 0 ] && grep -q 'stuck_login=0' <<<"$out" && pass "3. the words alone are not a stuck pane" || fail "3. ($out; $(cat "$T/calls"))"

# 4. dead here, newer working on the peer
reset; cred "$T/here/cred.json" DEAD 1000; stuck_login %11 999999701
out="$(tick)"; rc=$?
cmp -s "$T/here/cred.json" "$T/peer/cred.json" && grep -q 'copied=1 stopped=1 restored=1 failed=0 alerted=1' <<<"$out" \
  && pass "4. the peer's working login is copied here, then stop + restore" || fail "4. copy (rc $rc: $out; $(cat "$T/calls"))"
b="$(find "$T/here" -maxdepth 1 -name 'cred.json.bak-login-*' | wc -l)"
[ "$b" = 1 ] && grep -q rt-DEAD "$T/here/"cred.json.bak-login-* && [ "$(stat -c %a "$T/here/cred.json")" = 600 ] \
  && [ -z "$(find "$T/here" -maxdepth 1 -name '.cred-in*')" ] \
  && pass "4. the old one kept as .bak-login-<UTC>, mode 600, no temp file left" || fail "4. backup ($(ls -la "$T/here"))"
grep -q '^send ' "$T/calls" && grep -q '^- copied the credential sat -> here' "$T/calls" && pass "4. the alert says what was copied" || fail "4. alert ($(cat "$T/calls"))"
printf '%s\n' "$out" >"$T/out4"
[ "$(leaks "$T/out4" "$T/calls" "$T/state")" = 0 ] && pass "4. no credential content in any output, call or state" || fail "4. leak: $(grep -rlE 'rt-|at-' "$T/out4" "$T/calls" "$T/state")"

# 5. control: the peer is dead too
reset; cred "$T/here/cred.json" DEAD 1000; cred "$T/peer/cred.json" DEAD2 3000
echo "OAuth session expired and could not be refreshed" >"$T/peer/probe"; stuck_login %11 999999701
out="$(tick)"
grep -q rt-DEAD-secret "$T/here/cred.json" && ! grep -qE '^(kill|restore|close)' "$T/calls" && grep -q '^send ' "$T/calls" \
  && grep -q 'copied=0 stopped=0 restored=0 failed=0 alerted=1' <<<"$out" \
  && pass "5. no working login anywhere: no copy, no stop, an alert only" || fail "5. ($out; $(cat "$T/calls"))"

# 6. both limited: alert once, then nothing
reset; cred "$T/here/cred.json" LIM 1000; cred "$T/peer/cred.json" LIM2 3000
echo "You've hit your weekly limit · resets Oct 14, 8pm" >"$T/here/probe-dead"; cp "$T/here/probe-dead" "$T/peer/probe"
printf "You've hit your weekly limit · resets Oct 14\n 1. Stop and wait for limit to reset\n" >"$T/panes/%11"; echo error >"$T/turn/999999701"
out="$(tick)"
grep -q 'probe=limited stuck_login=0 stuck_limit=1 copied=0 stopped=0' <<<"$out" && [ "$(grep -c '^send ' "$T/calls")" = 1 ] \
  && ! grep -qE '^(kill|restore)|put' "$T/calls" && pass "6. both limited: no copy loop, no stop, one alert" || fail "6. ($out; $(cat "$T/calls"))"
out="$(tick)"
[ "$(grep -c '^send ' "$T/calls")" = 1 ] && grep -q 'alerted=0' <<<"$out" && pass "6. the same state next tick sends nothing" || fail "6. dedup ($out; $(cat "$T/calls"))"

# 7. here newer and working: pushed to the peer
reset; cred "$T/here/cred.json" GOOD 5000; cred "$T/peer/cred.json" OLD 2000
out="$(tick)"
cmp -s "$T/here/cred.json" "$T/peer/cred.json" && grep -q 'peer satellite put' "$T/calls" && grep -q 'copied=1 stopped=0' <<<"$out" \
  && pass "7. the newer working login here goes to the peer" || fail "7. ($out; $(cat "$T/calls"))"

# 8. DRY_RUN=1 and the guard
reset; cred "$T/here/cred.json" DEAD 1000; stuck_login %11 999999701
out="$(DRY=1 tick)"
grep -q rt-DEAD-secret "$T/here/cred.json" && [ "$(acts)" = 0 ] && grep -q 'PLAN copy the credential sat -> here' <<<"$out" && grep -q '^PLAN alert to c-002' <<<"$out" \
  && pass "8. DRY_RUN=1 plans and changes nothing" || fail "8. dry ($out; $(cat "$T/calls"))"
out="$(SNIPPET='do_spl_agent_login_check' in_orc SPOOL_LIVE_ROOT="$T/live" SPOOL_ROOT="$T/live" SPOOL_TEST_GUARD_LOG= LOGIN_STATE_DIR="$T/state" 2>&1)"; rc=$?
[ "$rc" = 96 ] && grep -q REFUSED <<<"$out" && pass "8. the live spool root (a stand-in) is refused under SPOOL_TEST" || fail "8. guard (rc $rc: $out)"

# 9. put refuses a non-login
reset
out="$(echo '{"x":1}' | LOGIN_CRED_FILE="$T/here/cred.json" LOGIN_SUDO='' bash "$CRED" put 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no Claude login' <<<"$out" && grep -q rt-GOOD "$T/here/cred.json" \
  && pass "9. put refuses an input that is no Claude login" || fail "9. (rc $rc: $out)"

echo "spl-agent-login-check: $fails failed"
exit $(( fails > 0 ))
