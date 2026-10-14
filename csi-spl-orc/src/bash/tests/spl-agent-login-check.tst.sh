#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_login_check (the agent login self-heal) on a temp root:
# fixture agents, panes, transcripts and two credential files ("here" and one
# peer), with claude -p, kill, the restore and the send all
# stubbed; every call lands in $T/calls.
#   1. a healthy box: 0 actions (only the probe runs), one summary line
#   2. control: one pane on "Login expired" with an API-error transcript ->
#      its pane (the wrapper) and its own pid stopped, ONE restore of that
#      id, one alert
#   3. the words on a pane whose transcript is fine: not stuck
#   4. a dead login here with a newer one on the peer: reported, never pulled
#      (one refresher, g-839), no stop, no restore, an alert
#   5. the peer's newer login does not work either -> the same: alert only
#   6. both boxes limited -> no copy, no stop, one alert; the same state on the
#      next tick sends nothing (deduplicated)
#   7. this box newer and working: pushed TO the peer (temp + mv,
#      .bak-login-<UTC> kept, mode 600); no credential content in any
#      output, call or state
#   8. DRY_RUN=1 plans and changes nothing; the live spool root is refused
#   9. the cred script refuses an input that is no Claude login
#  10. the peers come from box.env (SPOOL_LOGIN_PEERS, a comma list); none
#      named there = no peer is asked
#  11. this box works but the peer's credential is newer: the peer's is
#      never overwritten, it is reported
#  12. two stuck seats: stop + restore per seat, in order, one id each
#  13. two ticks on a healthy box = 0 stops
#  14. a second call inside the cool-down = 0 stops (control: cool-down 0
#      stops again); the cool-down is read from cnf
#  15. concurrent calls: one runs (a held lock skips; two at once = one stop)
#  16. a stuck seat the restore cannot bring back (worktree gone) is never
#      stopped; reported
#  17. the pane re-read right before the stop: recovered = left alone; claude
#      gone and a bare shell = restored without a stop
#  18. early warning (spec 132 section 3): expiry in 59 min warns and alerts
#      once, the same state on the next tick sends nothing, 61 min is quiet,
#      a renewal clears it; the sample log (cred.log) gets one line per
#      change, sha prefix and expiresAt only
#  19. a peer with no credential to read (unreachable): one alert per state
#  20. a seat parked on the usage-limit choice dialog (banner 9 non-blank
#      lines up, above the dialog) with an API-error transcript is stuck;
#      controls: the same pane with an ok transcript, and a banner 9 lines up
#      with no dialog under it, are not
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CRED="$PROJ_ROOT/src/bash/scripts/agent-login-cred.sh"
mkdir -p "$T/bin" "$T/panes" "$T/turn" "$T/gone" "$T/panecmd"
# The pane text; from a pane's second read on (the re-read right before the
# stop) its ".later" file when there is one.
cat >"$T/bin/capture" <<EOF
#!/bin/sh
n=\$(cat "$T/panes/\$1.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$T/panes/\$1.n"
if [ "\$n" -ge 2 ] && [ -f "$T/panes/\$1.later" ]; then cat "$T/panes/\$1.later"; else cat "$T/panes/\$1" 2>/dev/null; fi
EOF
cat >"$T/bin/gone" <<EOF
#!/bin/sh
[ -f "$T/gone/\$1" ]
EOF
cat >"$T/bin/panecmd" <<EOF
#!/bin/sh
cat "$T/panecmd/\$1" 2>/dev/null || echo claude
EOF
cat >"$T/bin/turn" <<EOF
#!/bin/sh
cat "$T/turn/\$1" 2>/dev/null || echo ok
EOF
printf '#!/bin/sh\necho "kill $*" >>"%s/calls"\n' "$T" >"$T/bin/kill"
cat >"$T/bin/restore" <<EOF
#!/bin/sh
echo "restore ids=\$IDENTITY_RESTORE_IDS dry=\$DRY_RUN" >>"$T/calls"
# RESTORE_GATE=FILE: the restore waits (at most 20 s) until FILE exists, so a
# test decides when the tick holding the lock may finish.
if [ -n "\${RESTORE_GATE:-}" ]; then i=0; while [ ! -f "\$RESTORE_GATE" ] && [ \$i -lt 200 ]; do sleep 0.1; i=\$((i + 1)); done; fi
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

# rec ID: an identity record the restore can resume (session, worktree, and
# the transcript in the agent user's home, $T/home).
rec() {
  local wt="$T/wt/$1" slug
  mkdir -p "$wt" "$T/spool/agents"
  slug="$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$T/home/.claude/projects/$slug"; touch "$T/home/.claude/projects/$slug/s-$1.jsonl"
  printf '{\n "id": "%s",\n "kind": "claude",\n "session_id": "s-%s",\n "worktree": "%s"\n}\n' "$1" "$1" "$wt" >"$T/spool/agents/$1.json"
}
reset() {
  rm -rf "$T/spool" "$T/state" "$T/here" "$T/peer" "$T/calls" "$T/panes/"* "$T/turn/"* "$T/gone/"* "$T/panecmd/"* "${T:?}/wt" "${T:?}/home"
  mkdir -p "$T/spool/dispatch" "$T/here" "$T/peer"; touch "$T/calls"
  rec c-701; rec c-702
  echo "c-002@box1 1791742397" >"$T/spool/dispatch/lease"
  echo "LEASE_ORCH=c-001" >"$T/spool/dispatch/lease.conf"
  printf 'c-701 999999701 %%11\nc-702 999999702 %%12\n' >"$T/agents"
  printf 'working on it\n  ✻ Thinking… (3s)\n' >"$T/panes/%11"; cp "$T/panes/%11" "$T/panes/%12"
  echo "Failed to authenticate: OAuth session expired and could not be refreshed" >"$T/here/probe-dead"
  cred "$T/here/cred.json" GOOD 2000; cred "$T/peer/cred.json" GOOD 2000; echo ok >"$T/peer/probe"
}
stuck_login() { printf 'old text\nLogin expired · Please run /login\n' >"$T/panes/$1"; echo error >"$T/turn/$2"; }

tick() {
  local pa=(LOGIN_PEERS="sat=satellite")
  [ -z "${NOPEERS:-}" ] || pa=()
  SNIPPET='do_spl_agent_login_check' in_orc SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" "${pa[@]}" SPOOL_BOX_TAG=box1 LOGIN_STATE_DIR="$T/state" \
    LOGIN_AGENTS_CMD="cat '$T/agents'" LOGIN_CAPTURE_CMD="$T/bin/capture" LOGIN_TURN_CMD="$T/bin/turn" \
    LOGIN_KILL_CMD="$T/bin/kill" LOGIN_RESTORE_CMD="$T/bin/restore" LOGIN_SEND="$T/bin/send" \
    LOGIN_CRED_CMD="env LOGIN_CRED_FILE=$T/here/cred.json LOGIN_SUDO= bash $CRED" LOGIN_PROBE_CMD="$PROBE_HERE" \
    LOGIN_PEER_CMD="$T/bin/peer" LOGIN_GONE_CMD="$T/bin/gone" LOGIN_PANECMD_CMD="$T/bin/panecmd" LOGIN_AGENT_HOME="$T/home" \
    LOGIN_PROBE_EVERY=0 LOGIN_EXPIRY_WARN_MIN="${WARN_MIN:-0}" LOGIN_NOW="${NOW:-}" DRY_RUN="${DRY:-0}" 2>&1
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
[ "$rc" = 0 ] && grep -qx 'kill pane %12' "$T/calls" && grep -qx 'kill TERM 999999702' "$T/calls" && [ "$(grep -c '^kill' "$T/calls")" = 2 ] \
  && [ "$(grep -n '' "$T/calls" | grep -E 'kill pane|kill TERM' | cut -d: -f2 | tr '\n' ' ')" = "kill pane %12 kill TERM 999999702 " ] \
  && pass "2. the stuck agent's pane, then its own pid, are stopped, and only its" || fail "2. stop (rc $rc: $out; $(cat "$T/calls"))"
grep -qx 'restore ids=c-702 dry=0' "$T/calls" && [ "$(grep -c '^restore' "$T/calls")" = 1 ] \
  && [ "$(grep -n '' "$T/calls" | grep -E '^[0-9]+:(kill TERM|restore)' | cut -d: -f2 | cut -c1-9 | tr '\n' ' ')" = "kill TERM restore i " ] \
  && pass "2. ONE restore of c-702, after the stop" || fail "2. restore ($(cat "$T/calls"))"
grep -q '^send .*--to c-002 --kind note .*stuck panes before: 1 login, 0 limit.*stopped 1, restored 1' "$T/calls" \
  && grep -q 'stopped=1 restored=1 failed=0 alerted=1' <<<"$out" \
  && pass "2. one alert to the dispatch holder with the counts" || fail "2. alert ($out; $(cat "$T/calls"))"

# 3. the words on a pane, transcript fine
reset; printf 'we discussed: Login expired · Please run /login\n' >"$T/panes/%11"
out="$(tick)"
[ "$(acts)" = 0 ] && grep -q 'stuck_login=0' <<<"$out" && pass "3. the words alone are not a stuck pane" || fail "3. ($out; $(cat "$T/calls"))"

# 4. dead here, newer working on the peer: reported, never pulled
reset; cred "$T/here/cred.json" DEAD 1000; stuck_login %11 999999701
out="$(tick)"; rc=$?
grep -q rt-DEAD-secret "$T/here/cred.json" && ! grep -qE '^(kill|restore)|peer [^ ]+ (get|put)' "$T/calls" \
  && grep -q 'probe=expired stuck_login=1 stuck_limit=0 copied=0 stopped=0 restored=0 failed=0 alerted=1' <<<"$out" \
  && pass "4. a newer peer login is not pulled; no stop, no restore on a dead login" || fail "4. (rc $rc: $out; $(cat "$T/calls"))"
grep -q '^- peer sat holds a NEWER credential' "$T/calls" && grep -q '^- 1 stuck agent(s) left as they are' "$T/calls" \
  && pass "4. the alert reports the newer peer and the stuck agent" || fail "4. alert ($(cat "$T/calls"))"

# 5. the peer is dead too
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
  && grep -q '^- pushed the credential here -> sat' "$T/calls" \
  && pass "7. the newer working login here is pushed to the peer" || fail "7. ($out; $(cat "$T/calls"))"
b="$(find "$T/peer" -maxdepth 1 -name 'cred.json.bak-login-*' | wc -l)"
[ "$b" = 1 ] && grep -q rt-OLD "$T/peer/"cred.json.bak-login-* && [ "$(stat -c %a "$T/peer/cred.json")" = 600 ] \
  && [ -z "$(find "$T/peer" -maxdepth 1 -name '.cred-in*')" ] \
  && pass "7. the old one kept as .bak-login-<UTC>, mode 600, no temp file left" || fail "7. backup ($(ls -la "$T/peer"))"
printf '%s\n' "$out" >"$T/out7"
[ "$(leaks "$T/out7" "$T/calls" "$T/state")" = 0 ] && pass "7. no credential content in any output, call or state" || fail "7. leak: $(grep -rlE 'rt-|at-' "$T/out7" "$T/calls" "$T/state")"
cp "$T/calls" "$T/calls7"; out="$(tick)"
[ "$(grep -c 'put' "$T/calls")" = 1 ] && grep -q 'copied=0' <<<"$out" && pass "7. in sync: the next tick pushes nothing" || fail "7. resync ($out)"

# 8. DRY_RUN=1 and the guard
reset; cred "$T/here/cred.json" GOOD 5000; cred "$T/peer/cred.json" OLD 2000; stuck_login %11 999999701
out="$(DRY=1 tick)"
grep -q rt-OLD-secret "$T/peer/cred.json" && [ "$(acts)" = 0 ] && grep -q 'PLAN push the credential here -> sat' <<<"$out" \
  && grep -q 'PLAN stop c-701 (pane %11' <<<"$out" && grep -q '^PLAN alert to c-002' <<<"$out" \
  && pass "8. DRY_RUN=1 plans and changes nothing" || fail "8. dry ($out; $(cat "$T/calls"))"
out="$(SNIPPET='do_spl_agent_login_check' in_orc SPOOL_LIVE_ROOT="$T/live" SPOOL_ROOT="$T/live" SPOOL_TEST_GUARD_LOG= LOGIN_STATE_DIR="$T/state" 2>&1)"; rc=$?
[ "$rc" = 96 ] && grep -q REFUSED <<<"$out" && pass "8. the live spool root (a stand-in) is refused under SPOOL_TEST" || fail "8. guard (rc $rc: $out)"

# 9. put refuses a non-login
reset
out="$(echo '{"x":1}' | LOGIN_CRED_FILE="$T/here/cred.json" LOGIN_SUDO='' bash "$CRED" put 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no Claude login' <<<"$out" && grep -q rt-GOOD "$T/here/cred.json" \
  && pass "9. put refuses an input that is no Claude login" || fail "9. (rc $rc: $out)"

# 10. peers from box.env
reset; cred "$T/here/cred.json" GOOD 5000; cred "$T/peer/cred.json" OLD 2000
out="$(NOPEERS=1 tick)"
! grep -q '^peer ' "$T/calls" && grep -q 'copied=0' <<<"$out" && pass "10. control: no peer in box.env, none asked" || fail "10. control ($out; $(cat "$T/calls"))"
echo "SPOOL_LOGIN_PEERS=sat=satellite,bad" >"$T/spool/box.env"
out="$(NOPEERS=1 tick)"
cmp -s "$T/here/cred.json" "$T/peer/cred.json" && grep -q 'copied=1' <<<"$out" \
  && pass "10. SPOOL_LOGIN_PEERS in box.env names the peer" || fail "10. box.env ($out; $(cat "$T/calls"))"

# 11. a newer peer is never overwritten, even by a working one
reset; cred "$T/here/cred.json" GOOD 1000; cred "$T/peer/cred.json" NEWER 5000
out="$(tick)"
grep -q rt-NEWER-secret "$T/peer/cred.json" && ! grep -q put "$T/calls" && grep -q 'copied=0 stopped=0 restored=0 failed=0 alerted=1' <<<"$out" \
  && grep -q '^- peer sat holds a NEWER credential' "$T/calls" \
  && pass "11. a newer peer credential is reported, never overwritten" || fail "11. ($out; $(cat "$T/calls"))"

# 12. two stuck seats, one at a time
reset; stuck_login %11 999999701; stuck_login %12 999999702
out="$(tick)"
seq="$(grep -E '^(kill|restore)' "$T/calls" | tr '\n' '|')"
[ "$seq" = "kill pane %11|kill TERM 999999701|restore ids=c-701 dry=0|kill pane %12|kill TERM 999999702|restore ids=c-702 dry=0|" ] \
  && grep -q 'stopped=2 restored=2 failed=0' <<<"$out" \
  && pass "12. stop + restore per seat, in order, one id per restore" || fail "12. ($seq; $out)"

# 13. two healthy ticks
reset; tick >/dev/null; tick >/dev/null
[ "$(grep -cE '^(kill|restore)' "$T/calls")" = 0 ] && pass "13. two ticks on a healthy box = 0 stops" || fail "13. ($(cat "$T/calls"))"

# 14. cool-down
reset; stuck_login %12 999999702
tick >/dev/null; rm -f "$T/panes/%12.n"; out="$(tick)"
[ "$(grep -c '^kill TERM' "$T/calls")" = 1 ] && [ "$(grep -c '^restore' "$T/calls")" = 1 ] && grep -q 'stopped=0' <<<"$out" \
  && pass "14. a second call inside the cool-down = 0 stops" || fail "14. ($out; $(cat "$T/calls"))"
printf 'env:\n  box:\n    login_check:\n      cooldown_min: 0\n' >"$T/cnf0.yaml"
out="$(LOGIN_CNF="$T/cnf0.yaml" tick)"
[ "$(grep -c '^kill TERM' "$T/calls")" = 2 ] && grep -q 'stopped=1' <<<"$out" \
  && pass "14. control: cnf cool-down 0 stops it again" || fail "14. control ($out; $(cat "$T/calls"))"

# 15. concurrency
reset; stuck_login %12 999999702; mkdir -p "$T/state"
# Wait for a condition, never a fixed sleep: a loaded runner can take seconds
# to start a background flock (wf10 run 38227682514). until_ok SECS CMD...
until_ok() { local n=$(($1 * 10)); shift; until "$@"; do n=$((n - 1)); [ "$n" -gt 0 ] || return 1; sleep 0.1; done; }
flock "$T/state/tick.lock" sh -c "touch '$T/held'; while [ ! -f '$T/unlock' ]; do sleep 0.1; done" & lk=$!
if until_ok 10 test -f "$T/held"; then
  out="$(tick)"
  grep -q 'another tick holds' <<<"$out" && [ "$(grep -cE '^(kill|restore|probe)' "$T/calls")" = 0 ] \
    && pass "15. a held lock: the call is skipped, nothing done" || fail "15. lock ($out)"
else fail "15. lock: the background flock was not held within 10 s"; fi
touch "$T/unlock"; wait "$lk"; rm -f "$T/held" "$T/unlock"
reset; stuck_login %12 999999702
# The tick that wins the lock waits in its restore until the other has been
# turned away, so the two calls always overlap.
( RESTORE_GATE="$T/unlock" tick >"$T/o1" ) & a=$!; ( RESTORE_GATE="$T/unlock" tick >"$T/o2" ) & b=$!
until_ok 20 grep -q 'another tick holds' "$T/o1" "$T/o2" || echo "15. race: no call was turned away within 20 s" >>"$T/o1"
touch "$T/unlock"; wait "$a" "$b"; rm -f "$T/unlock"
[ "$(grep -c '^kill TERM' "$T/calls")" = 1 ] && [ "$(grep -c '^restore' "$T/calls")" = 1 ] && grep -q 'another tick holds' "$T/o1" "$T/o2" \
  && pass "15. two calls at once: one runs, one stop + restore" || fail "15. race ($(cat "$T/o1" "$T/o2" "$T/calls"))"

# 16. not restorable
reset; stuck_login %12 999999702; rm -rf "$T/wt/c-702"
out="$(tick)"
! grep -qE '^(kill|restore)' "$T/calls" && grep -q 'c-702 is stuck (login) but cannot be restored: its worktree' "$T/calls" \
  && pass "16. a seat the restore cannot bring back is never stopped; reported" || fail "16. ($out; $(cat "$T/calls"))"

# 17. the re-read right before the stop
reset; stuck_login %12 999999702; printf 'back at work\n  ✻ Thinking… (2s)\n' >"$T/panes/%12.later"
out="$(tick)"
! grep -qE '^(kill|restore)' "$T/calls" && grep -q 'stopped=0 restored=0' <<<"$out" \
  && pass "17. recovered between the scan and the stop: left alone" || fail "17. ($out; $(cat "$T/calls"))"
reset; stuck_login %12 999999702; printf 'Restored claude session ended.\n$ \n' >"$T/panes/%12.later"
touch "$T/gone/999999702"; echo bash >"$T/panecmd/%12"
out="$(tick)"
! grep -q '^kill' "$T/calls" && grep -qx 'restore ids=c-702 dry=0' "$T/calls" && grep -q 'stopped=0 restored=1' <<<"$out" \
  && pass "17. claude gone, bare shell: restored without a stop" || fail "17. bare ($out; $(cat "$T/calls"))"

# 18. early warning
NOW=1791800000
reset; cred "$T/here/cred.json" GOOD $(( (NOW + 59 * 60) * 1000 ))
out="$(NOPEERS=1 WARN_MIN=60 NOW=$NOW tick)"
grep -qE '^WARN login-check@box1: credential [0-9a-f]{12} expires in 59 min, not renewed$' <<<"$out" && grep -q 'alerted=1' <<<"$out" \
  && [ "$(grep -c '^send ' "$T/calls")" = 1 ] && grep -q '^send .*--to c-002 ' "$T/calls" && grep -q '^- early warning: .*expires in 59 min.*claude /login' "$T/calls" \
  && pass "18. 59 min to expiry: a warning line and one alert to the dispatch holder" || fail "18. 59 min ($out; $(cat "$T/calls"))"
out="$(NOPEERS=1 WARN_MIN=60 NOW=$((NOW + 60)) tick)"
grep -q '^WARN .*expires in 58 min' <<<"$out" && grep -q 'alerted=0' <<<"$out" && [ "$(grep -c '^send ' "$T/calls")" = 1 ] \
  && pass "18. the same state on the next tick: no second alert" || fail "18. repeat ($out; $(cat "$T/calls"))"
cred "$T/here/cred.json" GOOD2 $(( (NOW + 480 * 60) * 1000 ))
out="$(NOPEERS=1 WARN_MIN=60 NOW=$((NOW + 120)) tick)"
! grep -q '^WARN' <<<"$out" && [ "$(wc -l <"$T/state/cred.log")" = 2 ] \
  && grep -qE '^2026-[0-9-]{5}T[0-9:]{8}Z [0-9a-f]{12} [0-9]+ peers=0$' "$T/state/cred.log" && [ "$(leaks "$T/state" "$T/calls")" = 0 ] \
  && pass "18. renewed: the warning clears; cred.log holds one line per change, no credential content" || fail "18. renewed ($out; $(cat "$T/state/cred.log"))"
reset; cred "$T/here/cred.json" GOOD $(( (NOW + 61 * 60) * 1000 ))
out="$(NOPEERS=1 WARN_MIN=60 NOW=$NOW tick)"
! grep -q '^WARN' <<<"$out" && [ "$(grep -c '^send ' "$T/calls")" = 0 ] && grep -q 'alerted=0$' <<<"$out" \
  && pass "18. control: 61 min to expiry warns nothing" || fail "18. 61 min ($out; $(cat "$T/calls"))"

# 19. peer unreachable
reset; rm -f "$T/peer/cred.json"
out="$(tick)"; out2="$(tick)"
[ "$(grep -c '^send ' "$T/calls")" = 1 ] && grep -q '^- peer sat: no credential to compare' "$T/calls" \
  && grep -q 'alerted=1' <<<"$out" && grep -q 'alerted=0' <<<"$out2" \
  && pass "19. a peer with no credential to read: one alert, none on the same state again" || fail "19. ($out / $out2; $(cat "$T/calls"))"

# 20. the usage-limit choice dialog (pane text of c-001@sat, 2026-10-14)
limit_dialog() {
  cat <<'PANE'
❯ : 'SPOOL c-001: note from c-001 task dispatch-lease msg b96351ef :: FLEET LEASE dispatch: c-002 -> c-003. ::
  run: spool recv --as c-001'
  ⎿  You've hit your weekly limit · resets Oct 17, 11am (Europe/Helsinki)
     Use your limit reset to reset it now: clau.de/reset

✻ Churned for 1s · done 1:35 PM

▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   What do you want to do?

   ❯ 1. Stop and wait for limit to reset
     2. Wait here, then continue automatically at Oct 17, 11am
     3. Add funds to continue with usage credits

   Enter to confirm · Esc to cancel

PANE
}
reset; limit_dialog >"$T/panes/%12"; echo error >"$T/turn/999999702"
out="$(DRY=1 tick)"
grep -q 'stuck_login=0 stuck_limit=1 ' <<<"$out" && grep -q 'PLAN stop c-702 (pane %12, pid 999999702, limit)' <<<"$out" \
  && pass "20. a seat parked on the limit choice dialog is stuck (limit)" || fail "20. dialog ($out)"
reset; limit_dialog >"$T/panes/%12"
out="$(DRY=1 tick)"
grep -q 'stuck_login=0 stuck_limit=0 ' <<<"$out" && pass "20. control: the dialog with an ok last turn is not stuck" || fail "20. ok turn ($out)"
reset; { limit_dialog | sed -n '1,4p'; printf 'line %s\n' 1 2 3 4 5 6 7 8; } >"$T/panes/%12"; echo error >"$T/turn/999999702"
out="$(DRY=1 tick)"
grep -q 'stuck_login=0 stuck_limit=0 ' <<<"$out" && pass "20. control: a banner 9 lines up with no dialog under it is not read" || fail "20. no dialog ($out)"

echo "spl-agent-login-check: $fails failed"
exit $(( fails > 0 ))
