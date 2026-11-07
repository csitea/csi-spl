#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_release_notes_lag_alarm (SPL-4988) on a real git fixture
# (bare origin + clone, committer dates set), a stub row reader and a stub
# #alerts post:
#   1. GREEN: every old commit has its row -> nothing
#   2. GREEN: the normal lag: no row at 1 min and at 94 min (inside the
#      measured land gap, max 101.2 + 1) -> nothing
#   3. RED: no row at 121 min -> one post naming the env, count and sha
#   4. the same again -> nothing; RED CONTROL: with the state gone -> a second
#      post, so "nothing" is the state's doing
#   5. the row arrives -> one recovery, which the #alerts fold skips, and two
#      episodes on different shas fold to one fingerprint
#   6. per env: only the env that lacks the row posts
#   7. a failed read: silent inside the limit, rc 1; past it ONE post; recovery
#   8. a read blip inside a lag episode posts nothing and keeps the episode
#   9. origin gone: the same no-verdict path, and no false lag
#  10. DRY_RUN=1 prints the post, posts nothing, writes no state
#  11. only the dispatch holder's box acts
#  11b. the lease leaves and returns: the verdict and .since are dropped, so a
#      new outage posts and no stale recovery does; a lease gap keeps them;
#      a good read clears .since
#  12. a post that fails moves no state: the next tick posts it
#  13. the default reader asks do_spl_db_query for ENV and parses psql's table
#  14. a bad limit is refused; the manifest row, the cron script, and wf 12
#      listing wf 26's name verbatim (c-917 N6)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/spool/dispatch"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

printf '#!/bin/sh\ncat >>%q\necho >>%q\n' "$T/posts" "$T/posts" >"$T/post-ok"; chmod +x "$T/post-ok"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$T/post-fail"; chmod +x "$T/post-fail"
# the row reader: <env> <file of asked shas>; prints what $T/rows-<env> holds, or fails on $T/rows-fail
cat >"$T/rows" <<EOF
#!/bin/sh
[ -e "$T/rows-fail" ] && exit 1
cat "$T/rows-\$1" 2>/dev/null
exit 0
EOF
chmod +x "$T/rows"

git init -q --bare "$T/origin.git"
git -C "$T/origin.git" symbolic-ref HEAD refs/heads/master
git init -q -b master "$T/repo"
git -C "$T/repo" remote add origin "$T/origin.git"
# commit_at MINUTES_OLD: one commit on origin's master, prints its sha
commit_at() {
  local at; at="$(date -u -d "@$(( $(date +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
  GIT_AUTHOR_DATE="$at" GIT_COMMITTER_DATE="$at" git -C "$T/repo" commit -q --allow-empty -m "c $1" || return 1
  git -C "$T/repo" push -q origin master || return 1
  git -C "$T/repo" rev-parse HEAD
}

tick() {
  SNIPPET='do_spl_release_notes_lag_alarm' in_orc SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a LANE_BOX=box-a \
    RELEASE_LAG_REPO="$T/repo" RELEASE_LAG_ROWS_CMD="$T/rows" RELEASE_LAG_POST_CMD="$T/post-ok" \
    RELEASE_LAG_STATE="$T/st" RELEASE_LAG_ENVS=prd DRY_RUN=0 "$@" 2>&1
}
n() { [ -s "$T/posts" ] && grep -c . "$T/posts" || echo 0; }
reset() { : >"$T/posts"; : >"$T/st"; rm -f "$T/rows-fail"; }
echo "box-a@box-a 1" >"$T/spool/dispatch/lease"

OLD1="$(commit_at 300)"; OLD2="$(commit_at 200)"
printf '%s\n%s\n' "$OLD1" "$OLD2" >"$T/rows-prd"
reset; out="$(tick)"; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 0 ] && pass "1. GREEN: every old commit has its row -> nothing" || fail "1. (rc $rc, $(n): $out)"

commit_at 94 >/dev/null; commit_at 1 >/dev/null
reset; out="$(tick)"; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 0 ] && pass "2. GREEN: no row at 94 and at 1 min, inside the limit -> nothing" || fail "2. (rc $rc, $(n): $(cat "$T/posts"))"

# a 121 min old commit on top of the 94 and 1 min ones: the reader filters by
# age, not by position
OLD3="$(commit_at 121)"
reset; tick >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 1 ] && grep -qF "prd: master commits older than the limit" "$T/posts" \
  && grep -qF "1 commit(s), newest ${OLD3:0:8}" "$T/posts" \
  && pass "3. RED: no row at 121 min -> one post naming the env, the count and the sha" || fail "3. (rc $rc, $(n): $(cat "$T/posts"))"
first_post="$(cat "$T/posts")"

tick >/dev/null
[ "$(n)" = 1 ] && pass "4. the same lag again -> nothing" || fail "4. ($(n))"
tick RELEASE_LAG_STATE="$T/st-gone-$RANDOM" >/dev/null
[ "$(n)" = 2 ] && pass "4. RED CONTROL: with the state gone the same tick posts again" || fail "4. RED CONTROL ($(n))"

reset; tick >/dev/null; echo "$OLD3" >>"$T/rows-prd"; : >"$T/posts"; tick >/dev/null
[ "$(n)" = 1 ] && grep -qF "prd recovered: of the newest 500 master commits" "$T/posts" && pass "5. the row arrives -> one recovery, worded to what was read" || fail "5. ($(n): $(cat "$T/posts"))"
recovery="$(cat "$T/posts")"
tick >/dev/null
[ "$(n)" = 1 ] && pass "5. still ok -> nothing more" || fail "5. after ($(n))"
other_post="${first_post//${OLD3:0:8}/deadbee1}"
fold="$(FP_A="$first_post" FP_B="$other_post" FP_R="$recovery" FOLD="$APP_ROOT/csi-spl-orc/src/bash/scripts/alert-issue-fold.py" python3 - <<'PY'
import importlib.util, os, re
s = importlib.util.spec_from_file_location("fold", os.environ["FOLD"])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
same = m.norm(os.environ["FP_A"]) == m.norm(os.environ["FP_B"])
skip = re.search(m.RECOVERY, os.environ["FP_R"], re.I) is not None
alert = re.search(m.RECOVERY, os.environ["FP_A"], re.I) is None
print(same, skip, alert)
PY
)"
[ "$fold" = "True True True" ] && pass "5. two episodes fold to one fingerprint, the recovery is skipped, the alarm is not" || fail "5. fold ($fold)"

cp "$T/rows-prd" "$T/rows-dev"; sed -i '$d' "$T/rows-dev"
reset; tick RELEASE_LAG_ENVS="prd dev" >/dev/null
[ "$(n)" = 1 ] && grep -qF "dev: master commits" "$T/posts" && ! grep -qF "prd:" "$T/posts" \
  && pass "6. only the env that lacks the row posts" || fail "6. ($(n): $(cat "$T/posts"))"

reset; touch "$T/rows-fail"; out="$(tick)"; rc=$?
[ "$rc" = 1 ] && [ "$(n)" = 0 ] && grep -q "prd: no verdict" <<<"$out" && pass "7. a failed read inside the limit: silent, rc 1" || fail "7. first (rc $rc, $(n): $out)"
printf 'prd.since=%s\n' "$(( $(date +%s) - 121 * 60 ))" >"$T/st"
tick >/dev/null
[ "$(n)" = 1 ] && grep -qF "this alarm cannot read" "$T/posts" && pass "7. past the limit: one post" || fail "7. past ($(n): $(cat "$T/posts"))"
tick >/dev/null
[ "$(n)" = 1 ] && pass "7. still failing: nothing more" || fail "7. again ($(n))"
rm -f "$T/rows-fail"; : >"$T/posts"; tick >/dev/null
[ "$(n)" = 1 ] && grep -qF "prd recovered" "$T/posts" && pass "7. readable and current again: one recovery" || fail "7. back ($(n): $(cat "$T/posts"))"

mv "$T/rows-prd" "$T/rows-prd.full"; grep -v "$OLD3" "$T/rows-prd.full" >"$T/rows-prd"
reset; tick >/dev/null; touch "$T/rows-fail"; tick >/dev/null; rm -f "$T/rows-fail"; tick >/dev/null
[ "$(n)" = 1 ] && grep -q '^prd=lag$' "$T/st" && pass "8. a read blip inside a lag episode posts nothing and keeps it" || fail "8. ($(n): $(cat "$T/st"))"
mv "$T/rows-prd.full" "$T/rows-prd"

git -C "$T/repo" remote set-url origin "$T/gone.git"
reset; out="$(tick)"; rc=$?
[ "$rc" = 1 ] && [ "$(n)" = 0 ] && grep -q "cannot read origin/master" <<<"$out" && pass "9. origin gone: no verdict, no false lag, rc 1" || fail "9. (rc $rc, $(n): $out)"
git -C "$T/repo" remote set-url origin "$T/origin.git"

sed -i '$d' "$T/rows-prd"
reset; out="$(tick DRY_RUN=1)"; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 0 ] && [ ! -s "$T/st" ] && grep -q "PLAN post in #alerts: \*\*RELEASE NOTES LAG\*\* prd:" <<<"$out" \
  && pass "10. DRY_RUN=1 prints the post, posts nothing, writes no state" || fail "10. (rc $rc, $(n): $out)"

echo "box-b@box-b 1" >"$T/spool/dispatch/lease"
reset; out="$(tick)"; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 0 ] && grep -q "is not on this box" <<<"$out" && pass "11. another box holds the lease: nothing here" || fail "11. (rc $rc, $(n): $out)"
out="$(tick DRY_RUN=1)"
grep -q "PLAN post" <<<"$out" && pass "11. a dry run still reads from any box" || fail "11. dry ($out)"
echo "box-a@box-a 1" >"$T/spool/dispatch/lease"

# 11b. R7 c-248 W1: the lease leaves and comes back; no verdict survives the trip
lease_away() { echo "box-b@box-b 1" >"$T/spool/dispatch/lease"; tick >/dev/null; echo "box-a@box-a 1" >"$T/spool/dispatch/lease"; }
reset; tick >/dev/null; lease_away; [ ! -e "$T/st" ] && pass "11b. a tick with the lease on another box drops the state" || fail "11b. state kept ($(cat "$T/st"))"
tick >/dev/null
[ "$(n)" = 2 ] && grep -q '^prd=lag$' "$T/st" && pass "11b. the lease returns during an outage: it posts, never silent" || fail "11b. return ($(n): $(cat "$T/st"))"
cp "$T/rows-prd" "$T/rows-prd.lag"; git -C "$T/repo" log --format=%H origin/master >>"$T/rows-prd"
reset; printf 'prd=lag\n' >"$T/st"; lease_away; tick >/dev/null
[ "$(n)" = 0 ] && pass "11b. the lease returns while current: no stale recovery" || fail "11b. stale recovery ($(n): $(cat "$T/posts"))"
cp "$T/rows-prd.lag" "$T/rows-prd"
reset; printf 'prd.since=%s\n' "$(( $(date +%s) - 3 * 86400 ))" >"$T/st"; lease_away; touch "$T/rows-fail"; tick >/dev/null; rm -f "$T/rows-fail"
[ "$(n)" = 0 ] && pass "11b. a 3 day old .since does not post on the first failed read after the return" || fail "11b. since ($(n): $(cat "$T/posts"))"
reset; printf 'prd=lag\n' >"$T/st"; : >"$T/spool/dispatch/lease"; out="$(tick)"; echo "box-a@box-a 1" >"$T/spool/dispatch/lease"
grep -q '^prd=lag$' "$T/st" && grep -q "no dispatch lease holder" <<<"$out" && pass "11b. no holder at all keeps the state: a lease gap is not a move" || fail "11b. gap ($(cat "$T/st"): $out)"
# R7 c-248 N4 (M14): a good read clears .since, so a later blip starts its own clock
reset; printf 'prd.since=%s\n' "$(( $(date +%s) - 121 * 60 ))" >"$T/st"; tick >/dev/null; touch "$T/rows-fail"; tick >/dev/null; rm -f "$T/rows-fail"
[ "$(n)" = 1 ] && ! grep -qF "this alarm cannot read" "$T/posts" && pass "11b. a good read clears .since: the next failed read does not post" || fail "11b. since kept ($(n): $(cat "$T/posts"))"

reset; out="$(tick RELEASE_LAG_POST_CMD="$T/post-fail")"; rc=$?
[ "$rc" = 1 ] && ! grep -q '^prd=' "$T/st" && pass "12. a failed post moves no state, rc 1" || fail "12. (rc $rc: $(cat "$T/st"))"
tick >/dev/null
[ "$(n)" = 1 ] && pass "12. the next tick posts it" || fail "12. next ($(n))"

# 13. the default reader, do_spl_db_query stubbed in its psql table shape
cat >"$T/dbq.inc" <<EOF
do_spl_db_query() {
  printf '%s %s\n' "\$ENV" "\$SQL" >"$T/dbq.asked"
  [ -e "$T/dbq-fail" ] && return 1
  echo 'INFO Cloud SQL proxy up: 127.0.0.1:1'
  printf ' sha\n------\n'
  sed 's/^/ /' "$T/rows-\$ENV"
  echo '(2 rows)'
}
EOF
: >"$T/posts"; : >"$T/st"
SNIPPET="source '$T/dbq.inc'; do_spl_release_notes_lag_alarm" in_orc SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a LANE_BOX=box-a \
  RELEASE_LAG_REPO="$T/repo" RELEASE_LAG_POST_CMD="$T/post-ok" RELEASE_LAG_STATE="$T/st" RELEASE_LAG_ENVS=prd DRY_RUN=0 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(n)" = 1 ] && grep -qF "1 commit(s), newest ${OLD3:0:8}" "$T/posts" && grep -q "^prd select sha from release_notes where sha in ('" "$T/dbq.asked" \
  && pass "13. the default reader asks the env's DB and parses psql's table" || fail "13. (rc $rc, $(n): $(cat "$T/posts" "$T/dbq.asked" 2>&1))"
touch "$T/dbq-fail"; : >"$T/posts"; : >"$T/st"
SNIPPET="source '$T/dbq.inc'; do_spl_release_notes_lag_alarm" in_orc SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a LANE_BOX=box-a \
  RELEASE_LAG_REPO="$T/repo" RELEASE_LAG_POST_CMD="$T/post-ok" RELEASE_LAG_STATE="$T/st" RELEASE_LAG_ENVS=prd DRY_RUN=0 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(n)" = 0 ] && pass "13. a failed DB read is no verdict, never all commits missing" || fail "13. fail (rc $rc, $(n))"

out="$(tick RELEASE_LAG_LIMIT_MIN=0)"; rc=$?
[ "$rc" = 1 ] && grep -q "FATAL RELEASE_LAG_LIMIT_MIN" <<<"$out" && pass "14. a limit of 0 is refused" || fail "14. limit (rc $rc: $out)"
row="$(grep '^release-notes-lag-alarm ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest")"
grep -qE '\| \*/15 \* \* \* \* +\| src/bash/scripts/release-notes-lag-alarm-cron.sh +\| release-notes-lag-alarm/cron.log \| \| desk$' <<<"$row" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/release-notes-lag-alarm-cron.sh" ] \
  && pass "14. the manifest row runs the executable cron script every 15 min" || fail "14. row ($row)"
out="$(bash "$PROJ_ROOT/src/bash/scripts/release-notes-lag-alarm-cron.sh" --bad 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "14. the cron script refuses an unknown argument" || fail "14. cron (rc $rc: $out)"
wf26="$(sed -n 's/^name: "\(.*\)"$/\1/p' "$APP_ROOT/.github/workflows/26_release-notes-ingest.yml")"
[ -n "$wf26" ] && grep -qF "      - \"$wf26\"" "$APP_ROOT/.github/workflows/12_ci-rerun-setup-flake.yml" \
  && pass "14. wf 12 lists wf 26 by its name, verbatim" || fail "14. wf 12 lacks '$wf26'"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
