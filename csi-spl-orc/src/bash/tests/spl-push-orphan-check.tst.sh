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
    PUSH_ORPHAN_LIVE_CMD="cat $T/live" PUSH_ORPHAN_SEND="$T/bin/send" DRY_RUN=0 "$@" 2>&1
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

echo "spl-push-orphan-check: $fails failure(s)"
[ "$fails" -eq 0 ]
