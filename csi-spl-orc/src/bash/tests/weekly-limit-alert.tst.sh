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
#   9. the claude CLI's cached usage is read below the banner (93 -> a line);
#      another login's cache, a 6 h old one or a passed reset is no reading
#  10. (SPL-4965) a kept reading at or over the threshold that a newer reading
#      under it contradicts posts ONE alarm naming both, until they agree
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

# 9. the claude CLI's cached usage (~/.claude.json cachedUsageUtilization):
# a reading below the banner's 90+ (the send-back: "no reading" every tick)
cj() {  # FILE PCT FETCHED_AGO_S RESET_ISO [CACHE_ACCOUNT]
  jq -n --argjson p "$2" --argjson f "$(( ($(date +%s) - $3) * 1000 ))" --arg r "$4" --arg a "${5:-acc-1}" \
    '{oauthAccount: {accountUuid: "acc-1"}, cachedUsageUtilization: {accountUuid: $a, fetchedAtMs: $f,
      utilization: {seven_day: {utilization: $p, resets_at: $r}}}}' >"$1"
}
RISO="2099-12-31T08:59:59.714017+00:00"; REP="$(date -d 2099-12-31T08:59:59Z +%s)"
cj "$T/cj-ok.json" 93 600 "$RISO"
a="$(LANE_PANES_CMD=x LANE_QUOTA_LOG_DIR="$T/none" LANE_QUOTA_CLAUDE_JSON="$T/cj-ok.json" BOX_QUOTA_RESET=1 spl_box_quota_here)"
b="$(LANE_PANES_CMD=x LANE_QUOTA_LOG_DIR="$T/none" LANE_QUOTA_CLAUDE_JSON="$T/cj-ok.json" spl_box_quota_here)"
[ "$a" = "claude:93@$REP" ] && [ "$b" = "claude:93" ] && pass "9. cached usage 93% -> claude:93@<reset>; the box pick reads claude:93" || fail "9. cache ($a / $b)"
cj "$T/cj-acc.json" 93 600 "$RISO" acc-2
cj "$T/cj-old.json" 93 30000 "$RISO"
cj "$T/cj-past.json" 93 600 "2001-01-01T00:00:00+00:00"
for f in acc old past; do
  c="$(LANE_PANES_CMD=x LANE_QUOTA_LOG_DIR="$T/none" LANE_QUOTA_CLAUDE_JSON="$T/cj-$f.json" spl_box_quota_here)"
  [ -z "$c" ] && pass "9. cache of another login / older than 6 h / reset passed ($f) -> no reading" || fail "9. $f ($c)"
done
printf '{"type":"assistant","timestamp":"%s","message":{"model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your weekly limit · resets Dec 31 2099, 11am (UTC)"}]}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >"$T/hit.jsonl"; mkdir -p "$T/proj"; mv "$T/hit.jsonl" "$T/proj/"
c="$(LANE_PANES_CMD=x LANE_QUOTA_LOG_DIR="$T/proj" LANE_QUOTA_CLAUDE_JSON="$T/cj-ok.json" spl_box_quota_here)"
[ "$c" = "claude:100" ] && pass "9. the transcript's hit (100) beats a lower cache (93)" || fail "9. max ($c)"
: >"$T/posts"; rm -f "$T/st.tsv"
out="$(SNIPPET='do_spl_weekly_limit_alert' in_orc SPOOL_ROOT="$T/spool" LANE_BOX=box-a LANE_PANES_CMD=x LANE_QUOTA_LOG_DIR="$T/none" \
  LANE_QUOTA_CLAUDE_JSON="$T/cj-ok.json" WEEKLY_ALERT_CMD="$T/post-ok" WEEKLY_ALERT_STATE="$T/st.tsv" DRY_RUN=0 2>&1)"
[ "$(n)" = 1 ] && grep -qF "claude on box-a: 93% of its weekly limit used (crossed 90%), resets 2099-12-31T08:59Z" "$T/posts" \
  && pass "9. the alert posts from the cached usage" || fail "9. alert ($(n): $out)"

# 10. readings that disagree: the kept row of 2026-11-06, read 2 h 15 ago
KP="$T/kept.tsv"; NOW=$(date +%s); RD=$(( NOW - 8100 )); : >"$T/posts"; rm -f "$T/st.tsv" "$T/st.tsv.disagree"
kp() { printf 'claude\t97\t%s\t%s\t\tbanner\n' "$FUT" "$RD" >"$KP"; }
ndis() { grep -c 'WEEKLY READINGS DISAGREE' "$T/posts"; }
kp; out="$(tick "claude:0@$FUT~cache~$(( NOW - 120 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null)"
[ "$(n)" = 1 ] && grep -qF "**WEEKLY READINGS DISAGREE** claude on box-a: the hold reads 97% (banner read 2h15m ago), a newer reading says 0% (cache read 2m ago)." "$T/posts" \
  && pass "10. RED CONTROL the 11-06 case: hold on 97, a newer 0 -> one alarm with both sources and ages" || fail "10. alarm ($(n): $(cat "$T/posts"); $out)"
grep -qF "or it lapses at $(date -u -d "@$(( RD + 36000 ))" +%Y-%m-%dT%H:%MZ)" "$T/posts" && pass "10. the alarm says when the reading lapses" || fail "10. lapse: $(cat "$T/posts")"
tick "claude:0@$FUT~cache~$(( NOW - 60 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(n)" = 1 ] && pass "10. the same disagreement next tick -> nothing" || fail "10. again ($(n))"
tick "claude:97@$FUT~banner~$NOW" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(ndis)" = 1 ] && [ ! -s "$T/st.tsv.disagree" ] && pass "10. a fresh re-read of the 97: they agree, the alarm re-arms" || fail "10. agree ($(n): $(cat "$T/st.tsv.disagree"))"
kp; tick "claude:0@$FUT~cache~$(( NOW - 30 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(ndis)" = 2 ] && pass "10. a new disagreement after that posts again" || fail "10. re-arm ($(n))"
: >"$T/posts"; rm -f "$T/st.tsv.disagree"
kp; tick "claude:0@$FUT~cache~$(( RD - 60 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(n)" = 0 ] && pass "10. CONTROL the lower reading is older than the kept one: lag, no alarm" || fail "10. lag ($(n): $(cat "$T/posts"))"
kp; out="$(tick "claude:0@$FUT~cache~$(( NOW - 30 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null WEEKLY_ALERT_CMD="$T/post-fail")"
[ ! -s "$T/st.tsv.disagree" ] && grep -q "disagree alarm did not post" <<<"$out" && pass "10. a failed post is not recorded" || fail "10. fail: $out"
kp; out="$(tick "claude:0@$FUT~cache~$(( NOW - 30 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null DRY_RUN=1)"
[ "$(n)" = 0 ] && grep -q "PLAN post in #alerts: \*\*WEEKLY READINGS DISAGREE" <<<"$out" && pass "10. DRY_RUN prints it, posts nothing" || fail "10. dry ($(n): $out)"

# 11. a hold that lapses (R7 N2, c-992): one line, retried until it posts
: >"$T/posts"; rm -f "$T/st.tsv" "$T/st.tsv.disagree" "$KP.lapsed"
kp12() { printf 'claude\t97\t%s\t%s\t\tcache\n' "$FUT" "$(( NOW - $1 * 3600 ))" >"$KP"; }
nlap() { grep -c 'WEEKLY HOLD LAPSED' "$T/posts"; }
kp12 12; out="$(tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null WEEKLY_ALERT_CMD="$T/post-fail")"
[ "$(nlap)" = 0 ] && [ -s "$KP.lapsed" ] && grep -q "lapse alarm did not post" <<<"$out" && pass "11. a failed post stays for the next tick" || fail "11. fail ($(n): $out)"
out="$(tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null DRY_RUN=1)"
[ "$(nlap)" = 0 ] && [ -s "$KP.lapsed" ] && grep -q "PLAN post in #alerts: \*\*WEEKLY HOLD LAPSED" <<<"$out" && pass "11. DRY_RUN prints it, posts nothing, keeps it" || fail "11. dry ($(n): $out)"
out="$(tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null)"
[ "$(nlap)" = 1 ] && [ ! -s "$KP.lapsed" ] && grep -qF "**WEEKLY HOLD LAPSED** claude on box-a: the hold read 97% (cache read 12h" "$T/posts" \
  && pass "11. RED CONTROL a hold that lapsed -> one alarm with its %, source and age" || fail "11. alarm ($(n): $(cat "$T/posts"); $out)"
tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(nlap)" = 1 ] && pass "11. the next tick posts nothing" || fail "11. again ($(n))"
: >"$T/posts"; kp12 6; tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(nlap)" = 0 ] && pass "11. CONTROL a hold 6 h old has not lapsed: no alarm" || fail "11. 6 h ($(n): $(cat "$T/posts"))"
# R7 N6 (c-992): overlapping reads each note the lapse, the alarm is still one line
: >"$T/posts"; rm -f "$KP.lapsed"; kp12 12; printf 'claude\t97\tcache\t%s\n' "$(( NOW - 12 * 3600 ))"{,,} >"$KP.lapsed"
tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(nlap)" = 1 ] && pass "11. RED CONTROL N6: one lapse in rows that differ only in the current % -> one alarm" || fail "11. rows ($(nlap): $(cat "$T/posts"))"
: >"$T/posts"; rm -f "$KP.lapsed"; kp12 12; printf '#!/bin/sh\necho\n' >"$T/quota"
for _ in 1 2 3 4 5 6; do SNIPPET='spl_box_quota_known' in_orc LANE_QUOTA_CMD="$T/quota" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null BOX_QUOTA_WEEKLY_MAX_PCT=90 >/dev/null 2>&1 & done; wait
rows="$(grep -c . "$KP.lapsed")"; tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
[ "$(nlap)" = 1 ] && pass "11. N6: six overlapping reads ($rows rows) -> one alarm" || fail "11. overlap ($rows rows, $(nlap): $(cat "$T/posts"))"
# R7 N7 (c-992): a lower reading did re-read it, so the text says that one
: >"$T/posts"; rm -f "$KP.lapsed"; printf 'claude\t100\t%s\t%s\t\tlog\n' "$FUT" "$(( NOW - 11 * 3600 ))" >"$KP"
tick "claude:40@$FUT~cache~$(( NOW - 3600 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null WEEKLY_ALERT_CMD="$T/post-fail" >/dev/null; [ -s "$KP.lapsed" ] && pass "11. N7: a failed post keeps the reading" || fail "11. N7 kept: $(cat "$KP" 2>/dev/null)"
tick "claude:40@$FUT~cache~$(( NOW - 3600 ))" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
grep -qF "the hold read 100% (log read 11h" "$T/posts" && grep -qF "and this box now reads 40%, so it takes new claude lanes again" "$T/posts" && ! grep -q "nothing re-read" "$T/posts" \
  && pass "11. RED CONTROL N7: kept 100, a fetch 40 -> names the 40, never \"nothing re-read it\"" || fail "11. N7 text: $(cat "$T/posts")"
: >"$T/posts"; rm -f "$KP.lapsed"; kp12 12; tick "" LANE_QUOTA_STATE="$KP" LANE_QUOTA_CLAUDE_JSON=/dev/null >/dev/null
grep -qF "and nothing re-read it, so this box takes new claude lanes again" "$T/posts" && pass "11. CONTROL N7: no reading at all -> \"nothing re-read it\" stays" || fail "11. N7 none: $(cat "$T/posts")"

# 8. the cron row
grep -qE "^weekly-limit-alert +\| \*/5 \* \* \* \* +\| src/bash/scripts/weekly-limit-alert-cron.sh +\| weekly-limit-alert/cron.log" "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh" ] \
  && pass "8. the manifest row runs weekly-limit-alert-cron.sh every 5 min" || fail "8. manifest row"
# Outside a worktree (CI) the script would run the real action against the
# live spool root (the SPOOL_TEST guard refused it and reddened
# run-all-tests-changed on master, run 40534982985): there only --check-tools.
case "$PROJ_ROOT" in
  *-wt/*)
    out="$(bash "$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh" 2>&1)"; rc=$?
    [ "$rc" = 2 ] && grep -q "FATAL .* is in an agent worktree" <<<"$out" && pass "8. the cron script refuses an agent worktree" || fail "8. worktree refusal (rc $rc: $out)" ;;
  *)
    out="$(WEEKLY_ALERT_TOOLS=bash bash "$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh" --check-tools 2>&1)"; rc=$?
    [ "$rc" = 0 ] && grep -q "OK every tool" <<<"$out" && pass "8. the cron script's --check-tools (not a worktree: the action is never run here)" || fail "8. check-tools (rc $rc: $out)" ;;
esac

echo "weekly-limit-alert: $fails failure(s)"
[ "$fails" -eq 0 ]
