#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_weekly_limit_alert (SPL-3849) on a fake banner feed
# (LANE_QUOTA_CMD prints what spl_box_quota_here would) and a stub #alerts post
# (WEEKLY_ALERT_CMD appends the line to a file):
#   1. 89 -> nothing; 90 -> one line (box, kind, %, reset); 90 again ->
#      nothing; 95 -> one line; 96 -> nothing; 99 -> one line
#   2. a new week re-arms: a reading below 90 (grok, no reset time), or the
#      stored reset time passed with no reading (claude)
#   3. a jump 89 -> 99 posts ONE line, for 99
#   4. a kind with no reading is "no reading" in the summary, never 0
#   5. DRY_RUN=1 (the default) prints the line, posts nothing, writes no state
#   6. a post that fails is not recorded: the next tick posts it
#   7. the reader: BOX_QUOTA_RESET=1 appends the banner's reset "@<epoch>",
#      unset prints the % alone (what the box pick reads)
#   8. the manifest row weekly-limit-alert runs the cron script every 5 min
#   RED CONTROL: the same "90 again" tick with the state file gone posts a
#   second line, so case 1's "nothing" is the state's doing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/spool"
printf '#!/bin/sh\ncat >>%q\necho >>%q\n' "$T/posts" "$T/posts" >"$T/post-ok"; chmod +x "$T/post-ok"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$T/post-fail"; chmod +x "$T/post-fail"
FUT=$(( $(date +%s) + 3 * 86400 )); PAST=$(( $(date +%s) - 60 ))

# tick READING [VAR=VALUE ...]: one run; READING as spl_box_quota_here prints it
tick() {
  local r="$1"; shift
  printf '#!/bin/sh\necho %q\n' "$r" >"$T/quota"; chmod +x "$T/quota"
  SNIPPET='do_spl_weekly_limit_alert' in_orc SPOOL_ROOT="$T/spool" LANE_BOX=box-a LANE_QUOTA_CMD="$T/quota" \
    WEEKLY_ALERT_CMD="$T/post-ok" WEEKLY_ALERT_STATE="$T/st.tsv" DRY_RUN=0 BOX_QUOTA_WEEKLY_MAX_PCT=90 "$@" 2>&1
}
n() { [ -s "$T/posts" ] && grep -c . "$T/posts" || echo 0; }

out="$(tick "claude:89@$FUT")"
[ "$(n)" = 0 ] && grep -q "weekly limit on box-a: claude 89%;" <<<"$out" && pass "1. 89 -> nothing" || fail "1. 89 ($(n): $out)"
out="$(tick "claude:90@$FUT")"
want="**WEEKLY LIMIT** claude on box-a: 90% of its weekly limit used (crossed 90%), resets $(date -u -d "@$FUT" +%Y-%m-%dT%H:%MZ)."
[ "$(n)" = 1 ] && grep -qF "$want" "$T/posts" && pass "1. 90 -> one line naming box, kind, % and reset" || fail "1. 90 ($(n): $(cat "$T/posts"); $out)"
out="$(tick "claude:90@$FUT")"
[ "$(n)" = 1 ] && grep -q "claude 90% (posted 90%)" <<<"$out" && pass "1. 90 again -> nothing" || fail "1. 90 again ($(n): $out)"
cp "$T/st.tsv" "$T/st.after90"
tick "claude:95@$FUT" >/dev/null
[ "$(n)" = 2 ] && [[ "$(grep . "$T/posts" | tail -1)" == *"95% of its weekly limit used (crossed 95%)"* ]] && pass "1. 95 -> one line" || fail "1. 95 ($(n): $(cat "$T/posts"))"
tick "claude:96@$FUT" >/dev/null
[ "$(n)" = 2 ] && pass "1. 96 -> nothing" || fail "1. 96 ($(n))"
tick "claude:99@$FUT" >/dev/null
[ "$(n)" = 3 ] && [[ "$(grep . "$T/posts" | tail -1)" == *"crossed 99%"* ]] && pass "1. 99 -> one line" || fail "1. 99 ($(n))"

# RED CONTROL: the "90 again" tick without its state posts again
: >"$T/posts"; rm -f "$T/st.tsv"
tick "claude:90@$FUT" >/dev/null; tick "claude:90@$FUT" WEEKLY_ALERT_STATE="$T/st-gone-$RANDOM.tsv" >/dev/null
[ "$(n)" = 2 ] && pass "RED CONTROL: with the state file gone, 90 again posts a second line" || fail "RED CONTROL ($(n))"

# 2. new week: grok has no reset time, a reading below 90 re-arms it
: >"$T/posts"; rm -f "$T/st.tsv"
tick "grok:91" >/dev/null; tick "grok:93" >/dev/null
out="$(tick "grok:4")"
[ "$(n)" = 1 ] && grep -q "grok: 4% is below 90%, a new week" <<<"$out" && [ ! -s "$T/st.tsv" ] \
  && pass "2. grok 91, 93, then 4 -> one line, then re-armed" || fail "2. grok re-arm ($(n): $out)"
tick "grok:90" >/dev/null
[ "$(n)" = 2 ] && grep -q "grok on box-a: 90% .*reset time unknown" "$T/posts" && pass "2. grok 90 in the new week -> one line again" || fail "2. grok new week ($(n): $(cat "$T/posts"))"
# claude: the stored reset passed, no reading (the parse drops a passed reset)
: >"$T/posts"; printf 'claude\t95\t%s\n' "$PAST" >"$T/st.tsv"
out="$(tick "")"
grep -q "claude: the weekly reset passed" <<<"$out" && grep -q "claude no reading" <<<"$out" && [ ! -s "$T/st.tsv" ] \
  && pass "2. claude reset time passed, no reading -> re-armed" || fail "2. claude reset ($out; $(cat "$T/st.tsv"))"
tick "claude:90@$FUT" >/dev/null
[ "$(n)" = 1 ] && pass "2. claude 90 after the reset -> one line" || fail "2. claude after reset ($(n))"
# no reading and no passed reset never re-arms (absent is not 0)
printf 'claude\t95\t%s\n' "$FUT" >"$T/st.tsv"; tick "" >/dev/null
grep -q "^claude	95	$FUT$" "$T/st.tsv" && pass "2. no reading before the reset keeps the posted 95" || fail "2. absent re-armed ($(cat "$T/st.tsv"))"

# 3. a jump posts one line, for the higher threshold
: >"$T/posts"; rm -f "$T/st.tsv"
tick "claude:89@$FUT" >/dev/null; tick "claude:100@$FUT" >/dev/null
[ "$(n)" = 1 ] && grep -q "100% of its weekly limit used (crossed 99%)" "$T/posts" && pass "3. 89 -> 100 posts one line, crossed 99" || fail "3. jump ($(n): $(cat "$T/posts"))"

# 4. every kind named; no reading is never 0
out="$(tick "grok:12")"
grep -q "weekly limit on box-a: claude no reading; grok 12%; mistral no reading; agy no reading; qwen no reading (0 posted)" <<<"$out" \
  && pass "4. the summary names every kind, no reading is 'no reading'" || fail "4. summary ($out)"

# 5. dry run
: >"$T/posts"; rm -f "$T/st.tsv"
out="$(tick "claude:97@$FUT" DRY_RUN=1)"
[ "$(n)" = 0 ] && [ ! -e "$T/st.tsv" ] && grep -q "^PLAN post in #alerts: \*\*WEEKLY LIMIT\*\* claude on box-a: 97% .*crossed 95%" <<<"$out" \
  && pass "5. DRY_RUN=1 prints the line, posts nothing, writes no state" || fail "5. dry run ($(n): $out)"

# 6. a failed post is retried
out="$(tick "claude:91@$FUT" WEEKLY_ALERT_CMD="$T/post-fail")"
grep -q "WARN the claude 90% alert did not post" <<<"$out" && [ ! -s "$T/st.tsv" ] && pass "6. a failed post is not recorded" || fail "6. failed post ($out)"
tick "claude:91@$FUT" >/dev/null
[ "$(n)" = 1 ] && pass "6. ...and the next tick posts it" || fail "6. retry ($(n))"

# 7. the reader keeps the box pick's format unless asked for the reset
source "$PROJ_ROOT/lib/bash/funcs/spl-box-quota.func.sh"
banner="You've used 96% of your weekly limit · resets Dec 31 2099, 11am (UTC)"
a="$(spl_box_quota_parse claude <<<"$banner")"; b="$(BOX_QUOTA_RESET=1 spl_box_quota_parse claude <<<"$banner")"
[ "$a" = 96 ] && [ "$b" = "96@$(TZ=UTC date -d 'Dec 31 2099 11am' +%s)" ] && pass "7. the parse: 96 alone, 96@<epoch> with BOX_QUOTA_RESET=1" || fail "7. parse ($a / $b)"
c="$(BOX_QUOTA_RESET=1 spl_box_quota_parse grok <<<"Weekly limit left: 4%")"
[ "$c" = 96 ] && pass "7. grok names no reset: 96 alone" || fail "7. grok ($c)"
d="$(LANE_PANES_CMD=x LANE_QUOTA_LOG_DIR="$T/none" BOX_QUOTA_RESET=1 spl_box_quota_here)"
[ -z "$d" ] && pass "7. no transcript, no pane -> no reading" || fail "7. here ($d)"

# 8. the cron row
grep -qE "^weekly-limit-alert +\| \*/5 \* \* \* \* +\| src/bash/scripts/weekly-limit-alert-cron.sh +\| weekly-limit-alert/cron.log" "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh" ] \
  && pass "8. the manifest row runs weekly-limit-alert-cron.sh every 5 min" || fail "8. manifest row"
out="$(bash "$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh" 2>&1)"; rc=$?
case "$PROJ_ROOT" in
  *-wt/*) [ "$rc" = 2 ] && grep -q "FATAL .* is in an agent worktree" <<<"$out" && pass "8. the cron script refuses an agent worktree" || fail "8. worktree refusal (rc $rc: $out)" ;;
  *) pass "8. (not a worktree: the refusal is not exercised)" ;;
esac

echo "weekly-limit-alert: $fails failure(s)"
[ "$fails" -eq 0 ]
