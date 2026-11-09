#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_alert_issue_tick (SPL-4828) on the 11-02 replay shape, every
# source and every write stubbed (ALERT_ISSUE_*_CMD, ALERT_ISSUE_RUN):
#   1. 8 alerts (3 lane-map #alerts posts, 1 deploy-lag post, the WARN and the
#      CRITICAL disk note of one mount, 2 GCP incidents of one policy) make 4
#      fingerprints; the WARN + CRITICAL pair is one of them (n=2)
#   1b. the bracketed detail of an alert is not its fingerprint, and a
#      recovery notice ("back after", "recovered") files nothing
#   2. the dry run (default) prints 4 PLAN lines and files, comments and
#      enqueues nothing; the live state file is not written
#   3. live, the cap of 3 lanes a day: 4 issues prio 1, and 3 asks + 3
#      enqueues with a read-only brief each; the 4th fingerprint issue only
#   5. a repeat of an open issue's alert: 1 comment, 0 issues, 0 enqueues;
#      the same alert read again (its ref seen): nothing
#   4. one lane per fingerprint per 24 h: a dismissed issue's fingerprint
#      fires again 10 min later: a new issue, no lane, the reason named
#   5b. an empty state (a holder on another box): the hub's open issue with
#      the "[fp:<hash>]" title gets the comment, no second issue
#   5c. an empty state: the hub's DONE issue of the fingerprint and an alert
#      before its fix: held, never filed twice; the lanes recorded in the
#      hub's issues ("alert-lane-at:") count toward the 3 a day
#   6. a done issue: an alert before the fix commit landed is held (no
#      reopen, no lane); one after it reopens it (todo) with a lane
#   7. a create that fails leaves the fingerprint out of the state, so the
#      next tick files it
#   7b. a reopen with a lane whose update fails: the lane is taken back out
#      of the day count and the fingerprint's last_lane_at (N1)
#   3b. no action the tick runs, and no source read, inherits its lock
#       fd 6 (round-2 N2, round-3 N3)
#   10. the orch role moves during the reads: nothing filed, no state
#      written; it moves between two writes: the first stays, the rest are
#      rolled back (round-2 W1)
#   10c. it moves after a create and before a reopen: the reopen is held
#      (round-3 N2)
#   10d. it moves after a comment: the next comment is held (round-4 N2)
#   8. ALERT_ISSUE=0 does nothing; the orch role on another box does nothing;
#      a live run without ALERT_ISSUE_DISCUSSION is refused
#   9. do_spl_asks_tick starts the alert tick only on the holder's machine
#      and never under SPOOL_TEST=1 unless ALERT_ISSUE_IN_TESTS=1
#   11. the disk source finds an absolute spool with none on PATH (SPL-5164)
#   12. the GCP source drops the one-project pins the lease loop exports, and
#       still asks for every env of ALERT_ISSUE_GCP_ENVS (SPL-5164)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" S="$T/src"
mkdir -p "$SP/dispatch/briefs" "$S"
printf 'LEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$SP/dispatch/lease.conf"
NOW=1793620800 # 2026-11-02T12:00:00Z
DISC=6c9aa54b-f876-4ff5-951a-a74f17166904

cat >"$S/alerts.json" <<'EOF'
{"topics":[
{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000001","subject":"**ALERT** lane map on sat: the hub did not answer 3 tries in a row (fleet f1), so the lane map sees that machine only. At most one such alert per box per 15 min.","last_ts":"2026-11-02T09:01:02Z"},
{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000002","subject":"**ALERT** lane map on sat: the hub did not answer 5 tries in a row (fleet f1), so the lane map sees that machine only. At most one such alert per box per 15 min.","last_ts":"2026-11-02T09:31:40Z"},
{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000003","subject":"**ALERT** lane map on sat: the hub did not answer 4 tries in a row (fleet f1), so the lane map sees that machine only. At most one such alert per box per 15 min.","last_ts":"2026-11-02T10:12:09Z"},
{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000004","subject":"**ALERT** deploy lag prd: v1.4.312 is 47 min behind master 3f2a9c1d","last_ts":"2026-11-02T10:40:00Z"}
]}
EOF
cat >"$S/disk.ndjson" <<'EOF'
{"body":"DISK HEADROOM sat (u): /mnt/data (ext4, /dev/sdb) blocks 88% >= 85%; top growers 7d: var-tmp +326.3MB/d","from":"c-001","kind":"note","msg_id":"47b6bfdc-ab92-43bf-b737-98bda0e0cb59","task_id":"disk-headroom","ts":"2026-11-02T04:37:03Z","v":1}
{"body":"DISK HEADROOM sat (u): CRITICAL /mnt/data (ext4, /dev/sdb) blocks 92% >= 92%: the disk is about to fill; top growers 7d: var-tmp +326.3MB/d","from":"c-001","kind":"note","msg_id":"9273a247-f956-49a3-b4b3-3fbe5df85337","task_id":"disk-headroom","ts":"2026-11-02T10:07:23Z","v":1}
EOF
cat >"$S/gcp.txt" <<'EOF'
== prd (csi-spl-prd)
== alert incidents 2026-11-01T12:00Z .. 2026-11-02T12:00Z (rebuilt from each policy's own condition)
TYPE                                       COUNT FIRST             LAST              SERIES RESOURCE
hub 5xx rate                                   2 2026-11-02T03:10Z 2026-11-02T08:20Z      1 spool-hub
== incidents (open .. last violating point, peak value)
2026-11-02T03:10Z .. 2026-11-02T03:25Z  hub 5xx rate                               peak=0.12  spool-hub
2026-11-02T08:05Z .. 2026-11-02T08:20Z  hub 5xx rate                               peak=0.3  spool-hub
EOF

# The run stub: every action logged with the vars a test asserts on.
cat >"$T/run" <<EOF
#!/bin/bash
a="\$2"
[ -e /proc/self/fd/6 ] && echo "\$a" >>"$T/fd6.log"
echo "\$a ref=\${ISSUE_REF:-} st=\${ISSUE_STATUS:-} prio=\${ISSUE_PRIORITY:-} epic=\${ISSUE_EPIC:-} disc=\${ISSUE_DISCUSSIONS:-} class=\${SPAWN_CLASS:-} place=\${SPAWN_PLACE:-} topic=\${ASK_TOPIC:-} by=\${ASK_BY:-}\${ASK_FROM:-} dry=\${DRY_RUN:-}" >>"$T/calls.log"
case "\$a" in
  do_spl_issue_status) printf 'issue-status\t%s\t%s\n' "\$ISSUE_REF" "\$(cat "$T/status.\$ISSUE_REF" 2>/dev/null || echo wip)" ;;
  do_spl_issue_list)
    # ISSUE_STATUS unset = the open statuses only, as do_spl_issue_list does
    f="\${ISSUE_STATUS-unset}"
    { cat "$T/hub-open.json" 2>/dev/null || echo '{"result":{"issues":[]}}'; } |
      if [ "\$f" = unset ]; then jq -c '.result.issues |= map(select(.status != "done" and .status != "diss"))'; else cat; fi ;;
  do_spl_issue_create)
    [ -f "$T/create.fail" ] && { echo "FATAL hub down"; exit 1; }
    cat "\$ISSUE_DESCRIPTION_FILE" >>"$T/desc.log" 2>/dev/null
    n=\$(cat "$T/n" 2>/dev/null || echo 100); n=\$((n + 1)); echo \$n >"$T/n"
    echo "{\"result\":{\"issue\":{\"key\":\"SPL-\$n\"}}}"
    [ -f "$T/move.after.create" ] && echo "c-001@box-b 1" >"$SP/dispatch/lease.orch"
    true ;;
  do_spl_issue_update) [ -f "$T/update.fail" ] && { echo "FATAL hub down"; exit 1; }; echo ok ;;
  do_spl_issue_comment) [ -f "$T/move.after.comment" ] && echo "c-001@box-b 1" >"$SP/dispatch/lease.orch"; echo ok ;;
  *) echo ok ;;
esac
EOF
chmod +x "$T/run"

tick() {
  SNIPPET='do_spl_alert_issue_tick' in_orc SPOOL_ROOT="$SP" ALERT_ISSUE_NOW="${AT:-$NOW}" ALERT_ISSUE_BOX=sat \
    ALERT_ISSUE_HOLDER=c-001@sat ALERT_ISSUE_RUN="$T/run" DESK_AGENT=c-001 ALERT_ISSUE_FIRST_SINCE_S=43200 ALERT_ISSUE_GIT_DIR="${GITD:-$T/nogit}" \
    ALERT_ISSUE_ALERTS_CMD="cat $S/alerts.json" ALERT_ISSUE_DISK_CMD="cat $S/disk.ndjson" \
    ALERT_ISSUE_GCP_CMD="cat $S/gcp.txt" ALERT_ISSUE_DISCUSSION="$DISC" "$@" 2>&1
}
reset() { rm -rf "$SP/dispatch/alert-issue" "$T/calls.log" "$T/desc.log" "$T/n" "$T/create.fail" "$T"/status.* "$SP/dispatch/briefs"/*; }
count() { grep -c "^$1 " "$T/calls.log" 2>/dev/null; }
ST="$SP/dispatch/alert-issue/state.json"

# 1 + 2: the dry run
reset; out="$(tick)"
plans="$(grep -c '^PLAN file ' <<<"$out")"
[[ "$plans" == 4 ]] && pass "1. 8 alerts -> 4 fingerprints (4 PLAN file lines)" || fail "1. want 4 PLAN file lines, got $plans: $out"
grep -q '^PLAN file .* n=2 .*/mnt/data' <<<"$out" && pass "1. the WARN and the CRITICAL of /mnt/data are one fingerprint (n=2)" ||
  fail "1. the disk pair is not one n=2 fingerprint: $(grep mnt <<<"$out")"
grep -q '^PLAN file .* n=3 .*lane map on sat' <<<"$out" && pass "1. the 3 lane-map alerts are one fingerprint" ||
  fail "1. lane-map alerts not folded: $(grep 'lane map' <<<"$out")"
w="$(grep -cE '^do_spl_(issue_(create|comment|update)|ask_put|spawn_enqueue) ' "$T/calls.log" 2>/dev/null)"
[[ "${w:-0}" == 0 && ! -e "$ST" && -s "$SP/dispatch/alert-issue/state.dry.json" ]] &&
  pass "2. dry run: no write, the live state untouched (dry state kept apart)" || fail "2. dry run wrote: $w writes, state $(ls "$SP/dispatch/alert-issue")"

# 1b: the fold alone on the 11-04 #alerts shapes: one alert's bracketed
# detail (other seats each time) is not its fingerprint; a recovery is no alert
F="$T/fold"; mkdir -p "$F"
cat >"$F/alerts.json" <<'EOJ'
{"topics":[
{"task_id":"0b9e4c1a-2222-4aaa-8bbb-000000000001","subject":"NO-LOCAL-AGENT dispatch on sat: it holds dispatch (c-002@sat) with no seat able to act (c-002: wd S2: HIT 5s ago; c-003: stalled pid=2761343","last_ts":"2026-11-04T07:00:00Z"},
{"task_id":"0b9e4c1a-2222-4aaa-8bbb-000000000002","subject":"NO-LOCAL-AGENT dispatch on sat: it holds dispatch (g-002@sat) with no seat able to act (g-002: stalled pid=3416351: You hit your weekly limi","last_ts":"2026-11-04T08:00:00Z"},
{"task_id":"0b9e4c1a-2222-4aaa-8bbb-000000000003","subject":"Box box-b back after 30 healthy min","last_ts":"2026-11-04T09:00:00Z"}
]}
EOJ
echo '{}' >"$F/issues.json"
fo="$(python3 "$PROJ_ROOT/src/bash/scripts/alert-issue-fold.py" plan "$F" "$F/none.json" 1793800000 "$F/issues.json")"
[[ "$(jq '.actions | length' <<<"$fo")" == 1 && "$(jq '.actions[0].n' <<<"$fo")" == 2 ]] &&
  pass "1b. two NO-LOCAL-AGENT alerts with other (detail): one fingerprint, n=2; the 'back after' notice files nothing" ||
  fail "1b. fold: $(jq -c '[.actions[] | {fp, n}]' <<<"$fo")"

# 3: live, the default cap of 3 lanes a day
reset; out="$(tick DRY_RUN=0)"
c="$(count do_spl_issue_create)" q="$(count do_spl_spawn_enqueue)" k="$(count do_spl_ask_put)"
[[ "$c" == 4 && "$q" == 3 && "$k" == 3 ]] && grep -q 'INFO alert issue tick: 4 fingerprint(s): 4 new, .* 3 lane(s)' <<<"$out" &&
  pass "3. live: 4 issues, 3 asks, 3 enqueues: the 4th fingerprint on a 3-lane day is issue only" ||
  fail "3. want 4 issues 3 asks 3 enqueues, got create $c ask $k enqueue $q: $out"
grep -q "^do_spl_issue_create .* prio=1 epic=SPL-2364 disc=0b9e4c1a-1111-4aaa-8bbb-000000000001 " "$T/calls.log" &&
  grep -q "^do_spl_issue_create .* prio=1 .* disc=$DISC " "$T/calls.log" &&
  pass "3. prio 1, the epic, an #alerts issue links its topic, a disk/GCP one the discussion" || fail "3. issue fields: $(grep create "$T/calls.log")"
grep -q '^do_spl_spawn_enqueue .* class=bug place=claude:alert-[0-9a-f]\{8\}-202611021200 topic= by=c-001@sat' "$T/calls.log" &&
  pass "3. enqueue: SPAWN_CLASS=bug, SPAWN_PLACE=claude:<slug>, ASK_BY the holder" || fail "3. enqueue: $(grep enqueue "$T/calls.log")"
b="$(find "$SP/dispatch/briefs" -name "*.md" -printf "%f\n" | sort | sed -n 1p)"
if [[ "$(ls "$SP/dispatch/briefs" | wc -l)" == 3 ]] && grep -q '^Origin-Issue: SPL-10[1-4]$' "$SP/dispatch/briefs/$b" &&
   ! grep -q '^Issue:' "$SP/dispatch/briefs/$b" && grep -qE '^Discussion: topic [0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' "$SP/dispatch/briefs/$b" &&
   grep -q '^Epic: SPL-2364$' "$SP/dispatch/briefs/$b" && grep -q '^Spec: csi-spl-doc/specs/146' "$SP/dispatch/briefs/$b" &&
   grep -q 'Edit any file, commit or push' "$SP/dispatch/briefs/$b" && grep -q 'fingerprint: `fp:' "$SP/dispatch/briefs/$b"; then
  pass "3. 3 briefs: Origin-Issue (never Issue:, so the lane files its own and the alert issue stays open), discussion, epic, spec, fingerprint, read-only"
else fail "3. briefs: $(ls "$SP/dispatch/briefs"); $(head -12 "$SP/dispatch/briefs/$b" 2>/dev/null)"; fi
u='[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}'
[[ "$(grep -c '^do_spl_ask_put ' "$T/calls.log")" == 3 && "$(grep -cE "^do_spl_ask_put .* topic=$u " "$T/calls.log")" == 3 ]] &&
  grep -qE "^do_spl_ask_put .* topic=0b9e4c1a-1111-4aaa-8bbb-000000000001 " "$T/calls.log" &&
  pass "3. every ask topic is a full uuid (the lane row's discussion): an #alerts lane its topic" || fail "3. ask topics: $(grep ask_put "$T/calls.log")"
[[ "$(grep -c "^alert-lane-at: $NOW\$" "$T/desc.log")" == 3 ]] && pass "3. the 3 lane issues record alert-lane-at in their description, the 4th none" ||
  fail "3. lane markers: $(grep -c alert-lane-at "$T/desc.log")"
[[ "$(jq '[.fps[] | select(.key | test("^SPL-"))] | length' "$ST")" == 4 ]] && pass "3. the state maps 4 fingerprints to their keys" ||
  fail "3. state: $(jq -c .fps "$ST")"

[[ ! -e "$T/fd6.log" ]] && pass "3b. no issue, ask or enqueue action inherits the tick's lock fd 6" || fail "3b. fd 6 leaked into: $(sort -u "$T/fd6.log" | tr '\n' ' ')"
# ... nor a source read (spl_ai_src's 6>&-, round-3 N3): a dry tick, a disk source that logs fd 6
printf '#!/bin/sh\n[ -e /proc/self/fd/6 ] && echo disk >>"%s"\ncat "%s"\n' "$T/fd6src.log" "$S/disk.ndjson" >"$T/fd6-src"; chmod +x "$T/fd6-src"
rm -f "$SP/dispatch/alert-issue/state.dry.json"; out="$(tick ALERT_ISSUE_DISK_CMD="$T/fd6-src")"
[[ ! -e "$T/fd6src.log" ]] && grep -q 'PLAN ' <<<"$out" && pass "3b. no source read inherits the tick's lock fd 6" ||
  fail "3b. fd 6 leaked into a source read: $(cat "$T/fd6src.log" 2>/dev/null) $out"

# 5: a repeat folds into the open issue
cp "$S/alerts.json" "$T/alerts.keep"
jq '.topics = [{task_id: "0b9e4c1a-1111-4aaa-8bbb-000000000009", subject: "**ALERT** lane map on sat: the hub did not answer 7 tries in a row (fleet f1), so the lane map sees that machine only. At most one such alert per box per 15 min.", last_ts: "2026-11-02T12:05:00Z"}]' \
  "$T/alerts.keep" >"$S/alerts.json"
: >"$T/calls.log"; out="$(AT=$((NOW + 600)) tick DRY_RUN=0)"
c="$(count do_spl_issue_create)" m="$(count do_spl_issue_comment)" q="$(count do_spl_spawn_enqueue)"
[[ "$c" == 0 && "$m" == 1 && "$q" == 0 ]] && pass "5. a repeat: 1 comment, 0 issues, 0 enqueues" || fail "5. repeat: create $c comment $m enqueue $q: $out"
: >"$T/calls.log"; out="$(AT=$((NOW + 1200)) tick DRY_RUN=0)"
[[ "$(count do_spl_issue_comment)" == 0 ]] && grep -q '0 fingerprint(s)' <<<"$out" && pass "5. the same alert read again: nothing" ||
  fail "5. re-read acted: $out"
: >"$T/calls.log"; out="$(AT=$((NOW + 1300)) tick DRY_RUN=0)"
[[ ! -s "$T/calls.log" ]] && pass "5. a tick before ALERT_ISSUE_EVERY_S does nothing" || fail "5. early tick acted: $(cat "$T/calls.log")"
cp "$T/alerts.keep" "$S/alerts.json"

# 4 (W3): one lane per fingerprint per 24 h. The lane-map issue is dismissed;
# the same alert fires 10 min later on a day with lanes to spare: a new
# issue, no lane, the reason named
lmk="$(jq -r '[.fps[] | select(.fp | contains("lane map"))][0].key' "$ST")"
echo diss >"$T/status.$lmk"
jq '.topics = [{task_id: "0b9e4c1a-1111-4aaa-8bbb-00000000000a", subject: "**ALERT** lane map on sat: the hub did not answer 9 tries in a row (fleet f1), so the lane map sees that machine only. At most one such alert per box per 15 min.", last_ts: "2026-11-02T12:30:00Z"}]' \
  "$T/alerts.keep" >"$S/alerts.json"
mv "$S/disk.ndjson" "$T/disk.hold"; : >"$S/disk.ndjson"; mv "$S/gcp.txt" "$T/gcp.hold"; : >"$S/gcp.txt"
: >"$T/calls.log"; out="$(AT=$((NOW + 2400)) tick DRY_RUN=0 ALERT_ISSUE_LANES_PER_DAY=9)"
[[ "$(count do_spl_issue_create)" == 1 && "$(count do_spl_spawn_enqueue)" == 0 && "$(count do_spl_ask_put)" == 0 ]] &&
  pass "4. the dismissed lane-map fingerprint again 10 min later: a new issue, no lane (one lane per fingerprint per 24 h)" ||
  fail "4. 24 h gap: create $(count do_spl_issue_create) enqueue $(count do_spl_spawn_enqueue): $out"
mv "$T/disk.hold" "$S/disk.ndjson"; mv "$T/gcp.hold" "$S/gcp.txt"; cp "$T/alerts.keep" "$S/alerts.json"; rm -f "$T/status.$lmk"

# 5b: a holder on another box (an empty state) finds the open issue by its fp title
reset; cp "$T/alerts.keep" "$S/alerts.json"; cp "$S/disk.ndjson" "$T/disk.keep"; : >"$S/alerts.json"; : >"$S/gcp.txt"
h="$(python3 -c 'import hashlib; print(hashlib.sha1(b"disk|sat|/mnt/data|blocks").hexdigest()[:8])')"
printf '{"result":{"issues":[{"key":"SPL-77","title":"Alert: disk [fp:%s]"}]}}\n' "$h" >"$T/hub-open.json"
out="$(tick DRY_RUN=0)"
[[ "$(count do_spl_issue_create)" == 0 ]] && grep -q '^do_spl_issue_comment ref=SPL-77 ' "$T/calls.log" &&
  pass "5b. an empty state: the hub's open [fp:$h] issue gets the comment, no second issue" || fail "5b. backstop: $out $(cat "$T/calls.log")"
grep -q '^do_spl_issue_list ' "$T/calls.log" && pass "5b. the hub list reads every status (ISSUE_STATUS empty)" || fail "5b. no hub list"

# 5c (W4): a lease move. An empty state; the hub holds the disk fingerprint's
# DONE issue (its fix landed after the alerts) and a dismissed older one: the
# alerts are held, nothing filed. Three lanes recorded in other issues'
# descriptions in the last 24 h: the deploy-lag alert files with no lane
GW="$T/repo5c"; git -c init.defaultBranch=master init -q "$GW"
GIT_COMMITTER_DATE="@$NOW" GIT_AUTHOR_DATE="@$NOW" git -C "$GW" -c user.name=t -c user.email=t@example.com \
  commit -q --allow-empty -m "fix(orc, SPL-88): the disk" && git -C "$GW" update-ref refs/remotes/origin/master HEAD
jq -n --arg h "$h" --argjson t1 $((NOW - 3600)) --argjson t2 $((NOW - 7200)) --argjson t3 $((NOW - 90000)) '{result: {issues: [
  {key: "SPL-88", title: "Alert: disk [fp:\($h)]", status: "done", created_at: "2026-11-02T05:00:00Z", description: "x"},
  {key: "SPL-80", title: "Alert: disk [fp:\($h)]", status: "diss", created_at: "2026-11-01T05:00:00Z", description: "x"},
  {key: "SPL-91", title: "Alert: a [fp:aaaaaaa1]", status: "wip", created_at: "2026-11-02T09:00:00Z", description: "y\nalert-lane-at: \($t1)\n"},
  {key: "SPL-92", title: "Alert: b [fp:aaaaaaa2]", status: "wip", created_at: "2026-11-02T09:00:00Z", description: "y\nalert-lane-at: \($t2)\n"},
  {key: "SPL-93", title: "Alert: c [fp:aaaaaaa3]", status: "done", created_at: "2026-11-02T09:00:00Z", description: "y\nalert-lane-at: \($t2)\n"},
  {key: "SPL-94", title: "Alert: d [fp:aaaaaaa4]", status: "wip", created_at: "2026-11-01T09:00:00Z", description: "y\nalert-lane-at: \($t3)\n"}]}}' >"$T/hub-open.json"
printf 'done\n' >"$T/status.SPL-88"
jq '.topics = [.topics[3]]' "$T/alerts.keep" >"$S/alerts.json"; : >"$S/gcp.txt"
reset; printf 'done\n' >"$T/status.SPL-88"; out="$(GITD="$GW" tick DRY_RUN=0)"
[[ "$(count do_spl_issue_create)" == 1 && "$(count do_spl_spawn_enqueue)" == 0 ]] && ! grep -q '^do_spl_issue_comment ref=SPL-88' "$T/calls.log" &&
  grep -q "INFO held fp:$h SPL-88" <<<"$out" && ! grep -q '^alert-lane-at:' "$T/desc.log" &&
  pass "5c. a lease move: the hub's done SPL-88 holds the pre-fix disk alerts (no second issue); 3 hub lanes in 24 h: deploy lag files issue only" ||
  fail "5c. lease move: $out $(cat "$T/calls.log")"
[[ "$(jq '.lanes | length' "$ST")" == 3 ]] && pass "5c. the state's day count holds the 3 hub lanes (two of one tick at the same time both count; the 25 h old one not)" || fail "5c. lanes: $(jq -c .lanes "$ST")"
rm -f "$T/hub-open.json"; cp "$T/alerts.keep" "$S/alerts.json"; cp "$T/disk.keep" "$S/disk.ndjson"
cp "$S/gcp.txt" "$T/gcp.none"; cat >"$S/gcp.txt" <<'EOG'
== prd (csi-spl-prd)
2026-11-02T03:10Z .. 2026-11-02T03:25Z  hub 5xx rate                               peak=0.12  spool-hub
2026-11-02T08:05Z .. 2026-11-02T08:20Z  hub 5xx rate                               peak=0.3  spool-hub
EOG
reset; out="$(tick DRY_RUN=0)"

# 6: a done issue reopens only after its fix
GITD="$T/repo"
git -c init.defaultBranch=master init -q "$GITD"
key="$(jq -r '[.fps[] | select(.fp | startswith("gcp|"))][0].key' "$ST")"
fixed=$((NOW + 3000))
GIT_COMMITTER_DATE="@$fixed" GIT_AUTHOR_DATE="@$fixed" git -C "$GITD" -c user.name=t -c user.email=t@example.com \
  commit -q --allow-empty -m "fix(orc, $key): the 5xx" && git -C "$GITD" update-ref refs/remotes/origin/master HEAD
echo 'done' >"$T/status.$key"
gcp_at() { printf '== prd (csi-spl-prd)\n%s .. %s  hub 5xx rate  peak=0.5  spool-hub\n' "$1" "$1" >"$S/gcp.txt"; }
: >"$S/alerts.json"; : >"$S/disk.ndjson"
gcp_at 2026-11-02T12:40Z; : >"$T/calls.log"
out="$(AT=$((NOW + 3600)) GITD="$GITD" tick DRY_RUN=0)"
[[ "$(count do_spl_issue_update)" == 0 && "$(count do_spl_spawn_enqueue)" == 0 ]] && grep -q "INFO held fp:.* $key" <<<"$out" &&
  pass "6. a done issue, the alert before the fix landed: held, no reopen" || fail "6. before-fix: $out $(cat "$T/calls.log")"
gcp_at 2026-11-02T13:10Z; : >"$T/calls.log"
out="$(AT=$((NOW + 4200)) GITD="$GITD" tick DRY_RUN=0 ALERT_ISSUE_LANE_GAP_S=600 ALERT_ISSUE_LANES_PER_DAY=9)"
grep -q "^do_spl_issue_update ref=$key st=todo" "$T/calls.log" && [[ "$(count do_spl_spawn_enqueue)" == 1 ]] &&
  pass "6. the alert after the fix landed: $key reopened (todo) with a lane" || fail "6. after-fix: $out $(cat "$T/calls.log")"

# 7b (N1): a reopen with a lane whose update fails rolls the lane back
GIT_COMMITTER_DATE="@$((NOW + 4500))" GIT_AUTHOR_DATE="@$((NOW + 4500))" git -C "$GITD" -c user.name=t -c user.email=t@example.com \
  commit -q --allow-empty -m "fix(orc, $key): the 5xx again" && git -C "$GITD" update-ref refs/remotes/origin/master HEAD
kh="$(jq -r --arg k "$key" '[.fps | to_entries[] | select(.value.key == $k)][0].key' "$ST")"
lanes0="$(jq '.lanes | length' "$ST")"
gcp_at 2026-11-02T13:40Z; : >"$T/calls.log"; touch "$T/update.fail"
out="$(AT=$((NOW + 6600)) GITD="$GITD" tick DRY_RUN=0 ALERT_ISSUE_LANE_GAP_S=600 ALERT_ISSUE_LANES_PER_DAY=9)"
rm -f "$T/update.fail"
[[ "$(count do_spl_issue_update)" == 1 && "$(count do_spl_spawn_enqueue)" == 0 && "$(jq '.lanes | length' "$ST")" == "$lanes0" ]] &&
  [[ "$(jq --arg h "$kh" '.fps[$h] | has("last_lane_at")' "$ST")" == false ]] &&
  pass "7b. a failed reopen with a lane: no enqueue, the day count keeps its $lanes0 lane(s), the fingerprint's last_lane_at is taken back" ||
  fail "7b. rollback: lanes $lanes0 -> $(jq '.lanes | length' "$ST"), fp $(jq -c --arg h "$kh" '.fps[$h]' "$ST"); $out"

# 10c (round-3 N2): the role moves after a create and before a reopen: the
# reopen's own re-check holds it (a new alert at 14:00 files first, the
# done issue's post-fix alert at 14:10 would reopen it)
cat >"$S/alerts.json" <<'EOF'
{"topics":[{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000005","subject":"**ALERT** spool queue on sat: 40 asks wait longer than 30 min","last_ts":"2026-11-02T14:00:00Z"}]}
EOF
gcp_at 2026-11-02T14:10Z; : >"$T/calls.log"; echo "c-001@sat 1" >"$SP/dispatch/lease.orch"; touch "$T/move.after.create"
out="$(AT=$((NOW + 8400)) GITD="$GITD" tick DRY_RUN=0 ALERT_ISSUE_LANE_GAP_S=600 ALERT_ISSUE_LANES_PER_DAY=9)"
rm -f "$SP/dispatch/lease.orch" "$T/move.after.create"; : >"$S/alerts.json"
[[ "$(count do_spl_issue_create)" == 1 && "$(count do_spl_issue_update)" == 0 ]] && grep -q 'held on box-b' <<<"$out" &&
  pass "10c. the role moves after a create: the reopen that follows re-reads lease.orch and is held (no update)" ||
  fail "10c. move before reopen: create $(count do_spl_issue_create) update $(count do_spl_issue_update) $out"

# 10d (round-4 N2): the role moves after a comment: the next repeat's
# comment re-reads lease.orch and is held. Tick 1 files the lane-map and
# deploy-lag issues; tick 2 repeats both
reset; cp "$T/alerts.keep" "$S/alerts.json"; : >"$S/gcp.txt"; mv "$S/disk.ndjson" "$T/disk.hold"; : >"$S/disk.ndjson"
out="$(tick DRY_RUN=0 ALERT_ISSUE_LANES_PER_DAY=9)"
jq '.topics = [.topics[0] + {task_id: "0b9e4c1a-1111-4aaa-8bbb-00000000000d", last_ts: "2026-11-02T12:10:00Z"},
  .topics[3] + {task_id: "0b9e4c1a-1111-4aaa-8bbb-00000000000e", last_ts: "2026-11-02T12:11:00Z"}]' "$T/alerts.keep" >"$S/alerts.json"
: >"$T/calls.log"; echo "c-001@sat 1" >"$SP/dispatch/lease.orch"; touch "$T/move.after.comment"
out="$(AT=$((NOW + 600)) tick DRY_RUN=0 ALERT_ISSUE_LANES_PER_DAY=9)"
rm -f "$SP/dispatch/lease.orch" "$T/move.after.comment"; mv "$T/disk.hold" "$S/disk.ndjson"
[[ "$(count do_spl_issue_comment)" == 1 && "$(count do_spl_issue_create)" == 0 ]] && grep -q 'held on box-b' <<<"$out" &&
  pass "10d. the role moves after a comment: the next comment re-reads lease.orch and is held (1 comment, not 2)" ||
  fail "10d. move after comment: comment $(count do_spl_issue_comment) create $(count do_spl_issue_create) $out"

# 7: a failed create is filed on the next tick
reset; cp "$T/alerts.keep" "$S/alerts.json"; : >"$S/gcp.txt"; : >"$S/disk.ndjson"
touch "$T/create.fail"; out="$(tick DRY_RUN=0)"
[[ "$(jq '.fps | length' "$ST")" == 0 ]] && pass "7. a failed create leaves no fingerprint in the state" || fail "7. state after fail: $(jq -c . "$ST")"
rm -f "$T/create.fail"; : >"$T/calls.log"; out="$(AT=$((NOW + 600)) tick DRY_RUN=0)"
[[ "$(count do_spl_issue_create)" == 2 ]] && pass "7. the next tick files them" || fail "7. retry: $out"

# 10 (round-2 W1): the orch role moves to box-b during the reads
reset; cp "$T/alerts.keep" "$S/alerts.json"; : >"$S/gcp.txt"; : >"$S/disk.ndjson"
printf '#!/bin/sh\necho "c-001@box-b 1" >"%s"\ncat "%s"\n' "$SP/dispatch/lease.orch" "$S/alerts.json" >"$T/move-alerts"; chmod +x "$T/move-alerts"
out="$(tick DRY_RUN=0 ALERT_ISSUE_ALERTS_CMD="$T/move-alerts")"
[[ "$(count do_spl_issue_create)" == 0 && "$(count do_spl_spawn_enqueue)" == 0 && ! -e "$ST" ]] &&
  grep -q 'the orch role moved during this tick' <<<"$out" &&
  pass "10. the orch role moves during the reads: 0 issues, 0 lanes, the state not written (its alerts stay for the new holder)" ||
  fail "10. move during reads: state $(cat "$ST" 2>/dev/null) $out $(cat "$T/calls.log" 2>/dev/null)"
# ... and between two writes: the first issue stays, the second is rolled back
reset; echo "c-001@sat 1" >"$SP/dispatch/lease.orch"; touch "$T/move.after.create"
out="$(tick DRY_RUN=0)"
[[ "$(count do_spl_issue_create)" == 1 && "$(jq '.fps | length' "$ST")" == 1 && "$(jq '.window_from // 0' "$ST")" -gt 0 ]] &&
  grep -q 'held on box-b' <<<"$out" &&
  pass "10. the role moves after the first create: 1 issue, the second fingerprint rolled back (unseen), the window held" ||
  fail "10. move between writes: create $(count do_spl_issue_create) fps $(jq -c .fps "$ST") $out"
rm -f "$SP/dispatch/lease.orch" "$T/move.after.create"

# 8: off, other box, no discussion
reset; out="$(tick DRY_RUN=0 ALERT_ISSUE=0)"
[[ ! -e "$T/calls.log" ]] && grep -q 'off (ALERT_ISSUE=0)' <<<"$out" && pass "8. ALERT_ISSUE=0: nothing" || fail "8. off: $out"
out="$(tick DRY_RUN=0 ALERT_ISSUE_HOLDER=c-001@box-b)"
[[ ! -e "$T/calls.log" ]] && grep -q 'held on box-b' <<<"$out" && pass "8. the orch role on another box: nothing" || fail "8. other box: $out"
printf 'LEASE_ENV=dev\nLEASE_TENANT=t1\nALERT_ISSUE=0\n' >"$SP/dispatch/lease.conf"
out="$(tick DRY_RUN=0)"
[[ ! -e "$T/calls.log" ]] && pass "8. ALERT_ISSUE=0 in lease.conf: nothing" || fail "8. lease.conf off: $out"
printf 'LEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$SP/dispatch/lease.conf"
out="$(tick DRY_RUN=0 ALERT_ISSUE_DISCUSSION=)"; rc=$?
[[ $rc != 0 && ! -e "$T/calls.log" ]] && grep -q 'FATAL ALERT_ISSUE_DISCUSSION' <<<"$out" && pass "8. live without ALERT_ISSUE_DISCUSSION: refused" ||
  fail "8. no discussion: rc $rc $out"

# 9: the asks tick hook
hook() {
  SNIPPET='spl_asks_alert_issue c-001@sat; wait' in_orc SPOOL_ROOT="$SP" ASKS_BOX=sat \
    ALERT_ISSUE_TICK_RUN="$T/hookrun" "$@" 2>&1
}
printf '#!/bin/sh\necho "hook $* holder=$ALERT_ISSUE_HOLDER dry=$DRY_RUN" >>"%s"\n' "$T/hook.log" >"$T/hookrun"; chmod +x "$T/hookrun"
hook >/dev/null; sleep 0.3
[[ ! -e "$T/hook.log" ]] && pass "9. under SPOOL_TEST=1 the asks tick starts no alert tick" || fail "9. started in a test: $(cat "$T/hook.log")"
hook ALERT_ISSUE_IN_TESTS=1 DRY_RUN=0 >/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/hook.log" ]] && break; sleep 0.2; done
grep -q 'hook -a do_spl_alert_issue_tick holder=c-001@sat dry=1' "$T/hook.log" 2>/dev/null &&
  pass "9. the asks tick starts it with the holder, as a dry run unless ALERT_ISSUE_DRY_RUN=0 (never the caller's DRY_RUN)" ||
  fail "9. hook: $(cat "$T/hook.log" 2>/dev/null)"

# 11: the disk source with no spool on PATH: the cron's and sudo's secure_path
mkdir -p "$T/nospool" "$T/dhome/.local/bin"
for b in timeout jq dirname basename readlink stat id cat git python3 mkdir date sed grep awk tr cut head tail ls uname hostname; do
  p="$(command -v "$b")" && ln -sf "$p" "$T/nospool/$b"
done
printf '#!/bin/sh\necho "fake-spool $SPOOL_ROOT $*"\n' >"$T/fakespool"; chmod +x "$T/fakespool"
cp "$T/fakespool" "$T/dhome/.local/bin/spool"
disk() {
  SNIPPET='root="$SP_ROOT"; PATH="$NOSPOOL"; PROJ_PATH="${RESOLVE_ORC:-$PROJ_PATH}"; spl_ai_read_disk' in_orc SP_ROOT="$SP" NOSPOOL="$T/nospool" "$@"
}
out="$(disk SPOOL_BIN="$T/fakespool" 2>&1)"
[[ "$out" == "fake-spool $SP tail --task disk-headroom --json" ]] && pass "11. no spool on PATH: SPOOL_BIN answers the disk read" ||
  fail "11. SPOOL_BIN: $out"
out="$(disk SPL_SPOOL="$T/fakespool" SPOOL_BIN="$T/nowhere" 2>&1)"
[[ "$out" == "fake-spool $SP tail --task disk-headroom --json" ]] && pass "11. an executable SPL_SPOOL wins" || fail "11. SPL_SPOOL: $out"
# spool-env alone in a tree with no build: a build of this tree would answer first
mkdir -p "$T/nobuild/csi-spl-orc/src/bash/features/spawn-agents"
cp -r "$PROJ_ROOT/src/bash/features/spawn-agents/lib" "$T/nobuild/csi-spl-orc/src/bash/features/spawn-agents/"
out="$(disk RESOLVE_ORC="$T/nobuild/csi-spl-orc" HOME="$T/dhome" SPOOL_BIN= 2>&1)"
[[ "$out" == "fake-spool $SP tail --task disk-headroom --json" ]] &&
  pass "11. the running user's own HOME spool answers (the desk user after a hop)" || fail "11. HOME: $out"
out="$(disk RESOLVE_ORC="$T/nobuild/csi-spl-orc" HOME="$T/nohome" SPOOL_BIN= 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"no absolute spool binary (got 'spool')"* ]] &&
  pass "11. no spool anywhere: refused, never a bare name" || fail "11. no binary: rc $rc $out"

# 12: the GCP source under the pins the lease loop's do_spl_cloud_cnf exports
mkdir -p "$T/gapp/csi-spl-iac"
cat >"$T/gapp/csi-spl-iac/run" <<'EOF'
#!/bin/bash
pin="${GCP_SA_KEY_FILE:-}${PROJ_ID:-}${SPL_PROJECT:-}${GCP_PROJECT:-}"
[[ -z "$pin" ]] || { echo "FATAL name one project: $pin" >&2; exit 1; }
echo "$2 env=[${ENV:-}] envs=[${GCP_LIST_ENVS:-}] since=[${SINCE:-}]"
EOF
chmod +x "$T/gapp/csi-spl-iac/run"
gcp() {
  SNIPPET='AI_SINCE=90m; spl_ai_read_gcp' in_orc APP_PATH="$T/gapp" SPL_PROJECT=csi-spl-dev PROJ_ID=csi-spl-dev \
    GCP_PROJECT=csi-spl-dev GCP_SA_KEY_FILE=/nonexistent/key.json "$@"
}
out="$(gcp 2>&1)"
[[ "$out" == "do_gcp_list_alert_incidents env=[] envs=[dev prd] since=[90m]" ]] &&
  pass "12. the inherited pins are dropped: every env, each by its own key" || fail "12. pins: $out"
out="$(gcp ALERT_ISSUE_GCP_ENVS=prd 2>&1)"
[[ "$out" == *"envs=[prd]"* ]] && pass "12. ALERT_ISSUE_GCP_ENVS still names the envs" || fail "12. envs: $out"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
