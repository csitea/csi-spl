#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_fleet_stopped_alarm (SPL-4964) on a stub hub, a stub master and
# a stub post (FLEET_STOPPED_CMD appends the text to a file).
#   1. REPLAY of 2026-11-06: fixtures/fleet-stopped-20261106/box-stats.tsv holds
#      the real load5 samples of that day (hub box_stats, boxes renamed), the
#      head the last commit before the gap, 124 asks queued (consensus 3.2) and
#      the real hold text. With the cnf's own limits: EXACTLY one post, by
#      12:00Z, naming the hold. Load crosses the mark several times that day, so
#      "one" is the episode rule's doing. The bound is 12:00Z and not one minute
#      because tick alignment alone moves the first fire by 5 min (seen
#      11:35Z and 11:40Z on the same samples).
#   2. The same replay at the consensus's 25%: no post at all. It is why the cnf
#      says 40 (holder c-003, msg 11e3b858).
#   RED CONTROL: the same replay with the state file removed after every tick
#   posts many times, so case 1's "exactly one" is the state's doing.
#   3. An empty queue: no post through the whole replay.
#   4. A landing ends the episode: no post inside quiet_min, a second post after.
#   5. An emptied queue re-arms; a load bounce alone does not (case 1).
#   6. One box at or over the mark holds the alarm; a box with a stale sample
#      does not count.
#   7. No fresh sample on any box: no verdict, no post (an empty set must not
#      read as "every box idle").
#   8. The hub or master not answering: no verdict, no post.
#   9. Another machine's post newer than the landing: no second post, recorded;
#      one older than the landing does not count; an unreadable channel waits.
#  10. Not the orch holder's machine: no post, the head still tracked. Nobody
#      holding the role: the post says so.
#  11. DRY_RUN=1 (the default) prints the post, posts nothing, writes no state.
#  12. A failed post is not recorded: the next tick posts it.
#  13. A commit that waited in the gate: its old committer time does not read as
#      "nothing landed", the first sight of the head counts.
#  14. Limits missing from the cnf: a FATAL, nothing posted.
#  15. The manifest row runs the cron script every 5 min; the real cnf channel.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FIX="$TEST_DIR/fixtures/fleet-stopped-20261106/box-stats.tsv"
HOLD_TEXT='waiting: claude weekly >= 90% on box-a, box-b'
epoch() { date -u -d "$1" +%s; }
HEAD_SHA=67d283262aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_CT=$(epoch 2026-11-06T09:30:08Z)

mkdir -p "$T/spool/asks" "$T/spool/dispatch"
printf '#!/bin/sh\ncat >>%q\n' "$T/posts" >"$T/post-ok"; chmod +x "$T/post-ok"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$T/post-fail"; chmod +x "$T/post-fail"
# The hub: the queue from $T/queue.json, samples from $T/samples.tsv up to the
# clock in $T/now, the channel from $T/topics.json; $T/down fails every call.
cat >"$T/hub" <<E
#!/bin/bash
[ -e "$T/down" ] && exit 1
case "\$1" in
  ask) cat "$T/queue.json" ;;
  box-stats)
    awk -F'\t' -v now="\$(date -u -d "@\$(cat "$T/now")" +%FT%TZ)" 'BEGIN { printf "{\"rows\":["; s="" }
      \$1 <= now { printf "%s{\"at\":\"%s\",\"box\":\"%s\",\"cpus\":%s,\"load5\":%s}", s, \$1, \$2, \$3, \$4; s="," }
      END { print "]}" }' "$T/samples.tsv" ;;
  topics) if [ -e "$T/topics-down" ]; then exit 1; else cat "$T/topics.json"; fi ;;
  *) exit 2 ;;
esac
E
chmod +x "$T/hub"
cat >"$T/land" <<E
#!/bin/sh
[ -e "$T/land-down" ] && exit 1
cat "$T/head"
E
chmod +x "$T/land"
queue() {  # N
  jq -n --argjson n "$1" '{asks: [range($n) | {ask_id: "a\(.)", state: "queued", position: (. + 1), enqueued_at: "2026-11-06T08:00:00Z"}]}' >"$T/queue.json"
}
reset_case() {
  : >"$T/posts"; rm -f "$T/st" "$T/down" "$T/topics-down" "$T/land-down"
  echo '{"topics":[]}' >"$T/topics.json"
  printf '%s %s\n' "$HEAD_SHA" "$HEAD_CT" >"$T/head"
  cp "$FIX" "$T/samples.tsv"; queue 124
  printf 'a0\t%s\t%s\na1\t%s\t%s\n' "$(epoch 2026-11-06T16:00:00Z)" "$HOLD_TEXT" "$(epoch 2026-11-06T16:00:00Z)" "$HOLD_TEXT" >"$T/spool/asks/.place.wait"
}
n() { [ -s "$T/posts" ] && grep -c . "$T/posts" || echo 0; }

COMMON=(SPOOL_ROOT="$T/spool" ASKS_HUB_CMD="$T/hub" ASKS_FLEET=main ASKS_ENV=dev ASKS_TENANT=t1 ASKS_DESK_BOX=box-a
  LANE_BOX=box-a ASKS_HOLDER=c-901@box-a FLEET_STOPPED_LAND_CMD="$T/land" FLEET_STOPPED_CMD="$T/post-ok"
  FLEET_STOPPED_STATE="$T/st" DRY_RUN=0 T_DIR="$T")

# tick "<UTC time>" [VAR=VALUE ...]: one run at that clock.
tick() {
  local at; at="$(epoch "$1")"; shift
  echo "$at" >"$T/now"
  SNIPPET='do_spl_fleet_stopped_alarm' in_orc "${COMMON[@]}" FLEET_STOPPED_NOW="$at" "$@" 2>&1
}
# replay [VAR=VALUE ...]: every 5 min of 11-06 09:00..16:15Z in ONE shell, and
# the clock of each post in $T/fires. REPLAY_RM_STATE=1 removes the state each tick.
replay() {
  : >"$T/fires"
  SNIPPET='
    for ((t = '"$(epoch 2026-11-06T09:00:00Z)"'; t <= '"$(epoch 2026-11-06T16:15:00Z)"'; t += 300)); do
      echo "$t" >"$T_DIR/now"; before=$(grep -c . "$T_DIR/posts")
      FLEET_STOPPED_NOW=$t do_spl_fleet_stopped_alarm >/dev/null 2>&1
      [[ $(grep -c . "$T_DIR/posts") == "$before" ]] || date -u -d "@$t" +%H:%M >>"$T_DIR/fires"
      [[ "${REPLAY_RM_STATE:-0}" == 1 ]] && rm -f "$T_DIR/st"
    done' in_orc "${COMMON[@]}" "$@" 2>&1
}

# 1. the replay, on the cnf's own limits
reset_case; replay
first="$(head -1 "$T/fires")"
[ "$(n)" = 1 ] && [[ -n "$first" && ! "$first" > "12:00" ]] \
  && pass "1. replay of 11-06: exactly one post, by 12:00Z (at ${first}Z)" || fail "1. replay ($(n) posts at: $(tr '\n' ' ' <"$T/fires"))"
grep -qF "The hold: $HOLD_TEXT" "$T/posts" && grep -q '^\*\*FLEET STOPPED\*\* 124 asks queued' "$T/posts" \
  && pass "1. the post names the hold and the queue" || fail "1. text: $(cat "$T/posts")"
[[ ! "$first" < "10:00" ]] && pass "1. no post before the gap's 30 min passed" || fail "1. early fire $first"

# 2. the consensus's 25%
reset_case; replay FLEET_STOPPED_LOAD_PCT=25
[ "$(n)" = 0 ] && pass "2. the replay at 25% never posts: why the cnf is not 25" || fail "2. 25% posted $(n): $(tr '\n' ' ' <"$T/fires")"

# RED CONTROL: the state is what keeps it to one post
reset_case; replay REPLAY_RM_STATE=1
[ "$(n)" -gt 1 ] && pass "RED CONTROL: state removed each tick -> $(n) posts" || fail "RED CONTROL ($(n))"

# 3. an empty queue
reset_case; queue 0; replay
[ "$(n)" = 0 ] && pass "3. an empty queue: no post through the replay" || fail "3. ($(n))"

# 4. a landing ends the episode
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T12:05:00Z >/dev/null
[ "$(n)" = 1 ] || fail "4. setup ($(n))"
printf 'bbbbbbbbbb %s\n' "$(epoch 2026-11-06T12:06:00Z)" >"$T/head"
tick 2026-11-06T12:10:00Z >/dev/null
[ "$(n)" = 1 ] && pass "4. a landing, under quiet_min: no post" || fail "4. inside quiet ($(n))"
printf '2026-11-06T12:40:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T12:45:00Z >/dev/null
[ "$(n)" = 2 ] && pass "4. the next stop after the landing: a second post" || fail "4. new episode ($(n))"

# 5. an emptied queue re-arms
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T12:05:00Z >/dev/null
tick 2026-11-06T12:06:00Z >/dev/null
[ "$(n)" = 1 ] && pass "5. stays stopped: still one post" || fail "5. repeat ($(n))"
queue 0; tick 2026-11-06T12:07:00Z >/dev/null; queue 3; tick 2026-11-06T12:08:00Z >/dev/null
[ "$(n)" = 2 ] && pass "5. the queue emptied and refilled: a new episode" || fail "5. re-arm ($(n))"

# 6. one busy box holds it; a stale box does not count
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n2026-11-06T12:00:00Z\tbox-b\t16\t6.4\n' >"$T/samples.tsv"
out="$(tick 2026-11-06T12:05:00Z)"
[ "$(n)" = 0 ] && grep -q 'at or over 40%' <<<"$out" && pass "6. a box at exactly 40% holds the alarm" || fail "6. busy ($(n): $out)"
printf '2026-11-06T11:00:00Z\tbox-b\t16\t16\n2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T12:05:00Z >/dev/null
[ "$(n)" = 1 ] && pass "6. a box with a stale sample (away) does not hold it" || fail "6. stale ($(n))"

# 7. no fresh sample anywhere
reset_case; printf '2026-11-06T11:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
out="$(tick 2026-11-06T12:05:00Z)"
[ "$(n)" = 0 ] && grep -q 'no fresh box sample' <<<"$out" && pass "7. no fresh sample: no verdict, no post" || fail "7. ($(n): $out)"
: >"$T/samples.tsv"; out="$(tick 2026-11-06T12:05:00Z)"
[ "$(n)" = 0 ] && grep -q 'no fresh box sample' <<<"$out" && pass "7. no sample at all: no verdict, no post" || fail "7. empty ($(n): $out)"

# 8. the hub or master down
reset_case; touch "$T/down"; out="$(tick 2026-11-06T12:05:00Z)"
[ "$(n)" = 0 ] && grep -q 'hub did not answer' <<<"$out" && pass "8. the hub down: no post" || fail "8. hub ($(n): $out)"
reset_case; touch "$T/land-down"; out="$(tick 2026-11-06T12:05:00Z)"
[ "$(n)" = 0 ] && grep -q 'master could not be read' <<<"$out" && pass "8. master unreadable: no post" || fail "8. land ($(n): $out)"

# 9. another machine's post
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
echo '{"topics":[{"task_id":"x","subject":"**FLEET STOPPED** 9 asks","last_ts":"2026-11-06T11:00:00.123Z"}]}' >"$T/topics.json"
tick 2026-11-06T12:05:00Z >/dev/null
[ "$(n)" = 0 ] && [ "$(cut -f3 "$T/st")" = 1 ] && pass "9. a post newer than the landing: none here, recorded" || fail "9. told ($(n): $(cat "$T/st"))"
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
echo '{"topics":[{"task_id":"x","subject":"**FLEET STOPPED** 9 asks","last_ts":"2026-11-06T09:00:00Z"}]}' >"$T/topics.json"
tick 2026-11-06T12:05:00Z >/dev/null
[ "$(n)" = 1 ] && pass "9. a post older than the landing is another episode" || fail "9. older ($(n))"
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"; touch "$T/topics-down"
tick 2026-11-06T12:05:00Z >/dev/null
[ "$(n)" = 0 ] && [ "$(cut -f3 "$T/st")" = 0 ] && pass "9. an unreadable channel: no post, retried" || fail "9. unreadable ($(n))"

# 10. not the placing machine; nobody placing
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
out="$(tick 2026-11-06T12:05:00Z ASKS_HOLDER=c-901@box-b)"
[ "$(n)" = 0 ] && grep -q 'held on box-b' <<<"$out" && [ "$(cut -f1 "$T/st")" = "$HEAD_SHA" ] \
  && pass "10. another machine's role: no post, the head tracked" || fail "10. remote ($(n): $out)"
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T12:05:00Z ASKS_HOLDER=none@box-a FLEET_STOPPED_AGENT=c-901 >/dev/null
grep -q 'The hold: nobody holds the orch role' "$T/posts" && pass "10. nobody holds the role: the post says so" || fail "10. none: $(cat "$T/posts")"
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
echo 'LEASE_ORCH=c-001' >"$T/spool/dispatch/lease.conf"
out="$(tick 2026-11-06T12:05:00Z ASKS_HOLDER=none@box-a)"
rm -f "$T/spool/dispatch/lease.conf"
[ "$(n)" = 1 ] && pass "10. nobody holds the role, no author given: the role seat of lease.conf posts" || fail "10. no author ($(n): $out)"
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
out="$(tick 2026-11-06T12:05:00Z ASKS_HOLDER=none@box-a)"
[ "$(n)" = 0 ] && grep -q 'channel could not be read' <<<"$out" && pass "10. ...and with no lease.conf either: no author, no post, retried" || fail "10. no conf ($(n): $out)"

# 11. the dry run
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
out="$(tick 2026-11-06T12:05:00Z DRY_RUN=1)"
[ "$(n)" = 0 ] && [ ! -e "$T/st" ] && grep -q '^PLAN post: \*\*FLEET STOPPED' <<<"$out" \
  && pass "11. DRY_RUN=1: the post printed, nothing sent or written" || fail "11. ($(n): $out)"

# 12. a failed post
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T12:05:00Z FLEET_STOPPED_CMD="$T/post-fail" >/dev/null
[ "$(cut -f3 "$T/st")" = 0 ] || fail "12. recorded a failed post"
tick 2026-11-06T12:06:00Z >/dev/null
[ "$(n)" = 1 ] && pass "12. a failed post is retried on the next tick" || fail "12. ($(n))"

# 13. a commit that waited in the gate
reset_case; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
tick 2026-11-06T09:40:00Z >/dev/null
printf 'cccccccccc %s\n' "$(epoch 2026-11-06T11:00:00Z)" >"$T/head"
tick 2026-11-06T12:05:00Z >/dev/null
[ "$(n)" = 0 ] && pass "13. a head first seen now, committed 65 min ago: it just landed" || fail "13. ($(n))"

# 14. no limits in the cnf
reset_case; echo 'env: {}' >"$T/empty.yaml"; printf '2026-11-06T12:00:00Z\tbox-a\t16\t1\n' >"$T/samples.tsv"
out="$(tick 2026-11-06T12:05:00Z OPS_ALARM_CNF="$T/empty.yaml")"; rc=$?
[ "$rc" != 0 ] && [ "$(n)" = 0 ] && grep -q 'FATAL env.ops_alarms.fleet_stopped' <<<"$out" \
  && pass "14. no limits in the cnf: FATAL, nothing posted" || fail "14. (rc=$rc $(n): $out)"

# 15. the wiring
grep -qE '^fleet-stopped-alarm +\| \*/5 \* \* \* \* +\| src/bash/scripts/fleet-stopped-alarm-cron.sh +\| fleet-stopped-alarm/cron.log +\| +\| desk$' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/fleet-stopped-alarm-cron.sh" ] && pass "15. the manifest row runs the cron script every 5 min" || fail "15. manifest"
[ "$(yq -r '.env.ops_alarms.channel' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")" = alerts ] && pass "15. the real cnf posts in #alerts" || fail "15. channel"

[ "$fails" -eq 0 ] && { echo "OK fleet-stopped-alarm"; exit 0; }
echo "FAILED: $fails"; exit 1
