#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_login_proof and do_spl_agent_login_proof_start (spec
# 132 section 3, the 48 h login proof) on a temp root: planted cron logs and
# credential samples, the clock pinned.
#   1. a clean 48 h log (2880 ticks, 6 renewals every 479 min) -> PASS, the
#      renewal interval measured; read-only (the state dir unchanged)
#   2. red controls, each FAIL naming the first failing sample's time:
#      a probe=expired tick, a stuck_login tick, 4 renewals (< 5), 30 h (< 48 h),
#      a peer named in the window; two failures -> the earlier one
#   3. no proof start -> FAIL
#   4. the start: a dry run changes nothing; DRY_RUN=0 empties
#      SPOOL_LOGIN_PEERS and records the start and a sample in one step, and
#      prints the proof command per box; it never gets or puts a credential
#   5. the start is refused while a peer holds this box's credential (no
#      /login there) or cannot be read, and when no peer is named
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CRED="$PROJ_ROOT/src/bash/scripts/agent-login-cred.sh"
S=1791799980   # the proof start, epoch, on a minute
utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ticks FROM MINUTES: one summary line per minute from epoch FROM
ticks() {
  seq "$1" 60 $(( $1 + ($2 - 1) * 60 )) | sed 's/^/@/' | date -u -f - +%Y-%m-%dT%H:%M:01Z |
    sed 's/$/ login-check@box1: probe=ok stuck_login=0 stuck_limit=0 copied=0 stopped=0 restored=0 failed=0 alerted=0/'
}
# samples N: the start sample, then N renewals every 479 min
samples() {
  local i t exp=$(( (S + 400 * 60) * 1000 ))
  echo "$(utc $S) $(printf '%012x' 1) $exp peers=0"
  for ((i = 1; i <= $1; i++)); do
    t=$(( S + (400 - 60 + (i - 1) * 479) * 60 )); exp=$(( exp + 479 * 60000 ))
    echo "$(utc $t) $(printf '%012x' $((i + 1))) $exp peers=0"
  done
}
reset() {
  rm -rf "$T/state"; mkdir -p "$T/state"
  ticks $S 2880 >"$T/state/cron.log"; samples 6 >"$T/state/cred.log"
  echo "$(utc $S) peers-before=sat=satellite" >"$T/state/proof.start"
}
plant() {  # plant MINUTE TEXT: the tick at that minute after the start reads TEXT
  local at; at="$(utc $(( S + $1 * 60 )) | sed 's/00Z$/01Z/')"
  sed -i "s|^$at login-check@box1: probe=ok stuck_login=0|$at login-check@box1: $2|" "$T/state/cron.log"
}
proof() {
  SNIPPET='do_spl_agent_login_proof' in_orc SPOOL_BOX_TAG=box1 LOGIN_STATE_DIR="$T/state" \
    LOGIN_NOW="${NOW:-$(( S + 48 * 3600 + 60 ))}" "$@" 2>&1
}

# 1. clean
reset; before="$(cd "$T/state" && md5sum ./* | md5sum)"
out="$(proof)"; rc=$?
[ "$rc" = 0 ] && grep -q '^login-proof: PASS$' <<<"$out" && [ "$(grep -c ' PASS ' <<<"$out")" = 6 ] \
  && grep -q 'renew   PASS 6 renewals' <<<"$out" && grep -q 'interval .*: 479 479 479 479 479 479$' <<<"$out" \
  && grep -q 'ticks   PASS 2880 ticks in 2880 min' <<<"$out" \
  && pass "1. a clean 48 h log: PASS on every mark, the renewal interval 479 min" || fail "1. clean (rc $rc: $out)"
[ "$(cd "$T/state" && md5sum ./* | md5sum)" = "$before" ] && [ "$(find "$T/state" -type f | wc -l)" = 3 ] \
  && pass "1. read-only: the state dir is unchanged" || fail "1. wrote ($(ls "$T/state"))"

# 2. red controls
reset; plant 600 'probe=expired stuck_login=0'
out="$(proof)"; rc=$?
[ "$rc" = 1 ] && grep -q "expired FAIL the first tick with probe=expired at $(utc $((S + 36000)) | sed 's/00Z$/01Z/')" <<<"$out" \
  && grep -q "^login-proof: FAIL first failing sample $(utc $((S + 36000)) | sed 's/00Z$/01Z/') (expired)$" <<<"$out" \
  && pass "2. a probe=expired tick: FAIL at its time" || fail "2. expired (rc $rc: $out)"
reset; plant 1200 'probe=ok stuck_login=2'
out="$(proof)"; rc=$?
[ "$rc" = 1 ] && grep -q "^login-proof: FAIL first failing sample $(utc $((S + 72000)) | sed 's/00Z$/01Z/') (stuck)$" <<<"$out" \
  && pass "2. a stuck_login tick: FAIL at its time" || fail "2. stuck (rc $rc: $out)"
reset; samples 4 >"$T/state/cred.log"
out="$(proof)"; rc=$?
[ "$rc" = 1 ] && grep -q 'renew   FAIL 4 of 5 renewals' <<<"$out" && grep -q "^login-proof: FAIL first failing sample $(utc $((S + 48 * 3600))) (renew)$" <<<"$out" \
  && pass "2. 4 renewals: FAIL at the window's end" || fail "2. renew (rc $rc: $out)"
reset; ticks $S 1800 >"$T/state/cron.log"
out="$(NOW=$((S + 30 * 3600)) proof)"; rc=$?
[ "$rc" = 1 ] && grep -q 'wall    FAIL 1800 of 2880 min so far' <<<"$out" \
  && grep -q "^login-proof: FAIL first failing sample $(utc $((S + 1799 * 60)) | sed 's/00Z$/01Z/') (wall)$" <<<"$out" \
  && pass "2. 30 h of 48: FAIL at the last tick" || fail "2. wall (rc $rc: $out)"
reset; echo "$(utc $((S + 5 * 3600))) $(printf '%012x' 2) 1 peers=1" >"$T/state/cred.log.x"
sort "$T/state/cred.log" "$T/state/cred.log.x" >"$T/state/cred.log.y"; mv "$T/state/cred.log.y" "$T/state/cred.log"; rm "$T/state/cred.log.x"
out="$(proof)"; rc=$?
[ "$rc" = 1 ] && grep -q "^login-proof: FAIL first failing sample $(utc $((S + 5 * 3600))) (peers)$" <<<"$out" \
  && pass "2. a peer named in the window: FAIL at that sample" || fail "2. peers (rc $rc: $out)"
reset; plant 1200 'probe=expired stuck_login=0'; plant 300 'probe=ok stuck_login=1'
out="$(proof)"; rc=$?
[ "$rc" = 1 ] && grep -q "first failing sample $(utc $((S + 18000)) | sed 's/00Z$/01Z/') (stuck)$" <<<"$out" \
  && pass "2. two failures: the earlier one is named" || fail "2. two (rc $rc: $out)"

# 3. no start
reset; rm "$T/state/proof.start"
out="$(proof)"; rc=$?
[ "$rc" = 1 ] && grep -q '^login-proof: FAIL no proof start' <<<"$out" && pass "3. no proof start: FAIL" || fail "3. ($out)"
out="$(proof LOGIN_PROOF_START="$(utc $S)")"; rc=$?
[ "$rc" = 0 ] && pass "3. LOGIN_PROOF_START names it instead (the peer's command)" || fail "3. override ($out)"

# 4. the start
mkdir -p "$T/bin" "$T/here" "$T/peer"
cred() { printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-%s-secret","expiresAt":%s}}\n' "$2" "$2" "$3" >"$1"; }
cat >"$T/bin/peer" <<EOS
#!/bin/sh
echo "peer \$1 \$2" >>"$T/calls"
LOGIN_CRED_FILE="$T/peer/cred.json" LOGIN_SUDO= exec bash "$CRED" "\$2"
EOS
chmod +x "$T/bin/peer"
start() {
  SNIPPET='do_spl_agent_login_proof_start' in_orc SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_BOX_TAG=box1 \
    LOGIN_STATE_DIR="$T/st" LOGIN_NOW=$S LOGIN_PEERS="sat=ignored" LOGIN_PEER_CMD="$T/bin/peer" \
    LOGIN_CRED_CMD="env LOGIN_CRED_FILE=$T/here/cred.json LOGIN_SUDO= bash $CRED" DRY_RUN="${DRY:-1}" 2>&1
}
sreset() {
  rm -rf "$T/spool" "$T/st" "$T/calls"; mkdir -p "$T/spool"; touch "$T/calls"
  printf 'SPOOL_AGENT_USER=%s\nSPOOL_LOGIN_PEERS=sat=satellite\n' "$(id -un)" >"$T/spool/box.env"
  cred "$T/here/cred.json" HERE 1791828000000; cred "$T/peer/cred.json" PEER 1791829000000
}
sreset
out="$(start)"; rc=$?
[ "$rc" = 0 ] && grep -q '^PLAN ' <<<"$out" && grep -q 'SPOOL_LOGIN_PEERS=sat=satellite' "$T/spool/box.env" && [ ! -e "$T/st" ] \
  && pass "4. the start's dry run changes nothing" || fail "4. dry (rc $rc: $out)"
out="$(DRY=0 start)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'SPOOL_LOGIN_PEERS=.' "$T/spool/box.env" && grep -q "^SPOOL_AGENT_USER=" "$T/spool/box.env" \
  && grep -qx "$(utc $S) peers-before=sat=satellite" "$T/st/proof.start" \
  && grep -qE "^$(utc $S) [0-9a-f]{12} 1791828000000 peers=0$" "$T/st/cred.log" \
  && grep -q "proof on sat: cd csi-spl-orc && LOGIN_PROOF_START=$(utc $S) ./run -a do_spl_agent_login_proof" <<<"$out" \
  && pass "4. DRY_RUN=0: peers emptied, the start and a sample recorded, the proof commands printed" || fail "4. start (rc $rc: $out; $(cat "$T/spool/box.env"))"
! grep -qE 'peer [^ ]+ (get|put)' "$T/calls" && ! grep -rqE 'rt-[A-Z]+-secret|at-[A-Z]+' "$T/st" && ! grep -qE 'rt-[A-Z]+-secret|at-[A-Z]+' <<<"$out" \
  && pass "4. no credential got, put or printed" || fail "4. copied ($(cat "$T/calls"))"
out="$(DRY=0 start)"; rc=$?
[ "$rc" = 2 ] && grep -q 'REFUSED SPOOL_LOGIN_PEERS is already empty' <<<"$out" && pass "5. a second start is refused: no peer named" || fail "5. again (rc $rc: $out)"

# 5. refusals
sreset; cp "$T/here/cred.json" "$T/peer/cred.json"
out="$(DRY=0 start)"; rc=$?
[ "$rc" = 2 ] && grep -q 'no /login on sat yet' <<<"$out" && grep -q 'SPOOL_LOGIN_PEERS=sat=satellite' "$T/spool/box.env" && [ ! -e "$T/st/proof.start" ] \
  && pass "5. the peer still holds this box's credential: refused, nothing changed" || fail "5. same (rc $rc: $out)"
sreset; rm "$T/peer/cred.json"
out="$(DRY=0 start)"; rc=$?
[ "$rc" = 2 ] && grep -q 'sat: no credential to read' <<<"$out" && grep -q 'SPOOL_LOGIN_PEERS=sat=satellite' "$T/spool/box.env" \
  && pass "5. a peer that cannot be read: refused" || fail "5. unreachable (rc $rc: $out)"

echo "spl-agent-login-proof: $fails failed"
exit $(( fails > 0 ))
