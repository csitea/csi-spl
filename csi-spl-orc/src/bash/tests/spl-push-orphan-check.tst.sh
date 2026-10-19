#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_push_orphan_check (SPL-2264, owner t1 b61851fb row D1) on a
# temp spool root; the live agent list and spool-send.sh stubbed, every send
# lands in $T/sends.
#   1. the m-595 sequence: the lane is live when its push is refused -> no
#      alert (its lane sees it); the lane's pane goes -> ONE blocker to the
#      dispatch lease holder: agent, sha, the log's last line, the brief's
#      topic and task; the next tick -> none; the dir is then retired (moved
#      to .retired/, marker and all) -> still none
#   2. a retired dir whose status still reads RUNNING (the pre-fix m-595
#      shape) and whose log ends END REFUSED -> ONE alert; control: the same
#      shape ending END PUSHED -> none
#   3. a landed push (PUSHED) of a retired lane -> never alerts
#   4. a live lane's own refused push -> no alert, no marker (1's alert is
#      the control: the same push once the pane is gone)
#   5. a dead worker (RUNNING, no END, lock free) of a retired lane -> DIED,
#      ONE alert; the same with a worker holding the lock -> none
#   6. a push older than PUSH_ORPHAN_MAX_AGE_MIN -> none; control: a wider
#      window -> alerts
#   7. a new push in an already alerted dir -> alerts again (once per push)
#   8. DRY_RUN=1 plans: a PLAN line, no send, no marker; the live spool root
#      is refused under SPOOL_TEST (96)
#   9. a rotated lane (SPL-2621, c-692 + a-615 on 2026-10-19): the identity
#      map's pane is stale (no id from the map) but a live pane or process
#      carries the id -> no alert: by window name, by pane title, by process
#      args (--name, the seed path, SPOOL_AGENT_ID); controls: the pane is
#      dead, a retiring window name, an id only mid-title -> each alerts
#  10. a newer run the lane started (status RUNNING since just now, lock not
#      yet taken, the log still the old END REFUSED) -> no alert
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"
mkdir -p "$R/dispatch" "$R/.retired" "$T/bin"
echo "c-002@sat 1792183913" >"$R/dispatch/lease"
echo "LEASE_ORCH=c-001" >"$R/dispatch/lease.conf"
: >"$T/live"
: >"$T/panes"
: >"$T/ps"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>%q\n' "$T/sends" >"$T/bin/send"
chmod +x "$T/bin/send"

SHA=e9fbcc642693884491a960215924153879b396f0
# lane <agent dir> <status first line> <END word or ""> [sha] - a push-master
# state dir as do_spl_push_master leaves it, plus the lane's brief and issue.
lane() {
  local d="$1/lifetime/push-master" sha="${4:-$SHA}"
  mkdir -p "$d"
  printf 'Report to the dispatch lease holder on task dispatch-b61851fb.\nOwner thread https://example.com/t/b61851fb-6c41-4145-8a53-ed4cd3574475\n' >"$1/lifetime/brief.md"
  echo SPL-2264 >"$1/lifetime/issue"
  : >"$d/lock"
  printf '01:27:48Z try 1/4: fetch\n01:27:50Z try 1/4: push %s -> origin master\n' "$sha" >"$d/log"
  [[ -n "$3" ]] && printf '01:34:50Z END %s push of %s (the hook or a rule said no)\n' "$3" "$sha" >>"$d/log"
  case "$2" in
    RUNNING) printf 'RUNNING\nsince=2026-10-16T01:27:48Z\n' >"$d/status" ;;
    *) printf '%s\nfinished=2026-10-16T01:34:50Z\n' "$2" >"$d/status" ;;
  esac
}
check() {
  SNIPPET='do_spl_push_orphan_check' in_orc SPOOL_TEST=1 SPOOL_ROOT="$R" SPOOL_BOX_TAG=box1 \
    PUSH_ORPHAN_LIVE_CMD="cat $T/live" \
    PUSH_ORPHAN_PANES_CMD="cat $T/panes" PUSH_ORPHAN_PS_CMD="cat $T/ps" PUSH_ORPHAN_SEND="$T/bin/send" DRY_RUN=0 "$@" 2>&1
}
sends() { if [ -f "$T/sends" ]; then grep -c -- "^--from " "$T/sends"; else echo 0; fi; }

# 1 the m-595 sequence
echo m-595 >"$T/live"
lane "$R/m-595" "REFUSED push of $SHA (the hook or a rule said no)" REFUSED
out="$(check)"
[ "$(sends)" = 0 ] && pass "1. the lane is live when its push is refused -> no alert" || fail "1. live lane alerted ($out)"
: >"$T/live"
out="$(check)"; rc=$?
s="$(cat "$T/sends" 2>/dev/null)"
[ "$rc" = 0 ] && [ "$(sends)" = 1 ] && grep -q -- "--to c-002@sat" <<<"$s" && grep -q -- "--kind blocker" <<<"$s" \
  && grep -q -- "--task dispatch-b61851fb" <<<"$s" && grep -q -- "--from c-001" <<<"$s" && grep -q "by m-595 ended REFUSED" <<<"$s" \
  && grep -q "sha: $SHA" <<<"$s" && grep -q "log, last line: 01:34:50Z END REFUSED push of $SHA" <<<"$s" \
  && grep -q "topic: /t/b61851fb-6c41-4145-8a53-ed4cd3574475" <<<"$s" && grep -q "ALERT m-595 REFUSED $SHA -> c-002@sat" <<<"$out" \
  && pass "1. its pane goes -> ONE blocker to the lease holder: agent, sha, last log line, topic, task" || fail "1. alert (rc $rc: $out | $s)"
check >/dev/null
[ "$(sends)" = 1 ] && pass "1. the next tick -> no second alert" || fail "1. repeated ($(cat "$T/sends"))"
mv "$R/m-595" "$R/.retired/m-595.20261016T011208Z"
check >/dev/null
[ "$(sends)" = 1 ] && pass "1. retired afterwards (the marker moved with the dir) -> still one alert" || fail "1. repeated after retire ($(cat "$T/sends"))"

# 2 the pre-fix shape: status RUNNING, log END ...
rm -f "$T/sends"
lane "$R/.retired/m-701.20261016T011208Z" RUNNING PUSHED
out="$(check)"
[ "$(sends)" = 0 ] && pass "2. control: status RUNNING, log END PUSHED, retired -> none" || fail "2. control ($out)"
lane "$R/.retired/m-702.20261016T011208Z" RUNNING REFUSED
out="$(check)"
[ "$(sends)" = 1 ] && grep -q "ALERT m-702 REFUSED $SHA" <<<"$out" \
  && pass "2. status RUNNING but log END REFUSED, retired -> ONE alert" || fail "2. pre-fix shape ($out)"

# 3 landed
rm -f "$T/sends"
lane "$R/.retired/m-703.20261016T011208Z" "PUSHED $SHA" ""
out="$(check)"
[ "$(sends)" = 0 ] && pass "3. a landed push of a retired lane -> never alerts" || fail "3. landed ($out)"

# 4 a live lane's own refusal
echo m-704 >"$T/live"
lane "$R/m-704" "REFUSED push of $SHA (the hook or a rule said no)" REFUSED
out="$(check)"
[ "$(sends)" = 0 ] && [ ! -e "$R/m-704/lifetime/push-master/orphan-alerted" ] \
  && pass "4. a live lane's refused push -> no alert, no marker" || fail "4. live lane ($out)"

# 5 a dead worker vs a running one
lane "$R/.retired/m-705.20261016T011208Z" RUNNING ""
d6="$R/.retired/m-706.20261016T011208Z"
lane "$d6" RUNNING ""
flock "$d6/lifetime/push-master/lock" sleep 30 & holder=$!
sleep 0.3
out="$(check)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$(sends)" = 1 ] && grep -q "ALERT m-705 DIED $SHA" <<<"$out" && ! grep -q "m-706" <<<"$out" \
  && pass "5. RUNNING, no END, lock free, retired -> DIED, ONE alert; a worker holding the lock -> none" || fail "5. died ($out)"

# 6 too old
rm -f "$T/sends"
d7="$R/.retired/m-707.20261016T011208Z"
lane "$d7" "REFUSED push of $SHA (x)" REFUSED
touch -d '7 hours ago' "$d7/lifetime/push-master/log"
rm -f "$d6/lifetime/push-master/status"
out="$(check)"
[ "$(sends)" = 0 ] && pass "6. a push older than PUSH_ORPHAN_MAX_AGE_MIN (360) -> none" || fail "6. old ($out)"
out="$(check PUSH_ORPHAN_MAX_AGE_MIN=600)"
[ "$(sends)" = 1 ] && grep -q "ALERT m-707" <<<"$out" && pass "6. control: the same push within 600 min -> alerts" || fail "6. control ($out)"

# 7 a new push in an alerted dir
rm -f "$T/sends"
SHA2=0123456789abcdef0123456789abcdef01234567
lane "$R/.retired/m-595.20261016T011208Z" "REFUSED push of $SHA2 (x)" REFUSED "$SHA2"
out="$(check)"
[ "$(sends)" = 1 ] && grep -q "ALERT m-595 REFUSED $SHA2" <<<"$out" && pass "7. a new push in an alerted dir -> alerts once more" || fail "7. new push ($out)"

# 8 dry run, guard
rm -f "$T/sends"
d8="$R/.retired/m-708.20261016T011208Z"
lane "$d8" "GAVE-UP origin/master moved during each of 4 pushes" ""
out="$(check DRY_RUN=1)"
[ "$(sends)" = 0 ] && grep -q '^PLAN blocker to c-002@sat:' <<<"$out" && grep -q 'by m-708 ended GAVE-UP' <<<"$out" \
  && [ ! -e "$d8/lifetime/push-master/orphan-alerted" ] && grep -q '(DRY_RUN)' <<<"$out" \
  && pass "8. DRY_RUN=1 -> PLAN, no send, no marker" || fail "8. dry run ($out)"
mkdir -p "$T/live-root"
out="$(SNIPPET='do_spl_push_orphan_check' in_orc SPOOL_TEST=1 SPOOL_LIVE_ROOT="$T/live-root" SPOOL_ROOT="$T/live-root" SPOOL_TEST_GUARD_LOG= 2>&1)"; rc=$?
[ "$rc" = 96 ] && grep -q REFUSED <<<"$out" && pass "8. the live spool root (a stand-in) is refused under SPOOL_TEST" || fail "8. guard (rc $rc: $out)"

# 9 a rotated lane: the map proves nothing, a live pane or process carries the id
# the earlier cases' leftovers (m-704 once its lane is gone, m-708) alert here, uncounted
: >"$T/live"; check >/dev/null
REF="REFUSED push of $SHA (the hook or a rule said no)"
# alive <case> <agent> <panes line or ""> <ps line or ""> <want: none|alert>
alive() {
  rm -f "$T/sends"; : >"$T/live"
  printf '%s' "$3" >"$T/panes"; printf '%s' "$4" >"$T/ps"
  lane "$R/$2" "$REF" REFUSED
  out="$(check)"
  if [ "$5" = none ]; then
    [ "$(sends)" = 0 ] && [ ! -e "$R/$2/lifetime/push-master/orphan-alerted" ] && pass "$1 -> no alert" || fail "$1 ($out)"
  else
    [ "$(sends)" = 1 ] && grep -q "ALERT $2 REFUSED" <<<"$out" && pass "$1 -> alerts" || fail "$1 ($out)"
  fi
  rm -rf "${R:?}/$2"
}
P=$'\t'
alive "9. rotated lane, window 'a-615@box2 rotate', live pane" a-615 "0${P}a-615@box2 rotate${P}box2"$'\n' "" none
alive "9. tagged window 'sat: c-692@sat'" c-692 "0${P}sat: c-692@sat${P}sat"$'\n' "" none
alive "9. pane title '◑ c-693@sat' in a 'bash' window" c-693 "0${P}bash${P}◑ c-693@sat"$'\n' "" none
alive "9. process args --name c-694@sat" c-694 "" "/usr/bin/claude --name c-694@sat --dangerously-skip-permissions"$'\n' none
alive "9. process args, the seed path" g-695 "" "grok Read and follow your seed: $R/g-695/lifetime/prompt.txt"$'\n' none
alive "9. process args SPOOL_AGENT_ID='m-696'" m-696 "" "su - ai -c export SPOOL_AGENT_ID='m-696' X=1"$'\n' none
alive "9. control: the same window, pane dead" a-697 "1${P}a-697@box2 rotate${P}box2"$'\n' "" alert
alive "9. control: a retiring window 'm-698-2111Z-retiring'" m-698 "0${P}m-698-2111Z-retiring${P}sat"$'\n' "" alert
alive "9. control: the id only mid-title, a longer id in the args" c-699 "0${P}g-002@sat dispatcher${P}relay c-699 result"$'\n' "--name c-6990@sat"$'\n' alert
: >"$T/panes"; : >"$T/ps"

# 10 a newer run the lane just started
rm -f "$T/sends"
lane "$R/c-700" RUNNING REFUSED
printf 'RUNNING\nsince=%s\n' "$(date -u +%FT%TZ)" >"$R/c-700/lifetime/push-master/status"
out="$(check)"
[ "$(sends)" = 0 ] && pass "10. status RUNNING since just now, lock free, old END REFUSED in the log -> no alert" || fail "10. new run ($out)"
printf 'RUNNING\nsince=%s\n' "$(date -u -d '10 minutes ago' +%FT%TZ)" >"$R/c-700/lifetime/push-master/status"
out="$(check)"
[ "$(sends)" = 1 ] && grep -q "ALERT c-700 REFUSED" <<<"$out" && pass "10. control: the same, since 10 min ago -> alerts" || fail "10. control ($out)"

echo "spl-push-orphan-check: $fails failure(s)"
[ "$fails" -eq 0 ]
