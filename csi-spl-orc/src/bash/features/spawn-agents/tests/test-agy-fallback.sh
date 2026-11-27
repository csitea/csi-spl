#!/usr/bin/env bash
# Spec 184 section 10 (SPL-6661): an agy seat starts on one of agy's own
# alternative models when its Gemini quota is low (lib/agy-fallback.inc.sh,
# wired into spawn-agy.sh and restore-agy.sh). Every agy call is a stub: no
# real quota is read or spent.
#   1  switch off: nothing read, nothing added, nothing written
#   2  Gemini above both marks: stays on Gemini
#   3  weekly below its mark -> the first listed alternative; record says claude
#   4  5h below its mark -> switches too
#   5  an alternative agy does not list is skipped (agy does not refuse one)
#   6  the alternative pool short of alt_min -> stays
#   7  HARD RULE: a review seat of a claude author (a review by its heading,
#      its Kind a coding kind) never falls back (and its
#      quota is not even read); 7b any review seat; 7c a kind not in the list
#   8  quota unread -> stays; 9 a reading is reused for cache_s
#   10 spawn-agy.sh plan line carries the flag; off -> byte-identical extra
#   11 restore-agy.sh decides again from the seat's own brief
#   12 HARD RULE on a watchdog-restart seed (the review brief nested under
#      section A, a doc Kind:) and on an Author:-only brief (R7 a-766 W1)
#   13 a rotation seed with no Kind: decides by lifetime/brief.md; a seed
#      naming lifetime/brief.md resolves it (W3)
#   14 a stalled `agy acp` ends at --timeout, rc 4; an absent agy leaves no
#      temp dir (W2, N1); 15 SPAWN_DRY_RUN=1 starts no agy, writes nothing (N2)
#   16 a restart seed with NO Author: line whose review heading is not the
#      first is still a review seat: the all-headings scan (R7 c-795 N2)
#   17 Author: as a list item (- **Author:**) and a table row marks a review
#      seat and names its claude author (N3)
#   18 both agy reads share one budget below WD_START_WAIT: the second read
#      gets what is left, none under 10 s (N4)
# Red control: drop the review branch of spool_agy_fallback_barred (a copy)
# -> case 7 fails (run with AGY_FB_RED=1).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
LIB="$T_SCRIPTS/../lib/agy-fallback.inc.sh"
if [ "${AGY_FB_RED:-0}" = 1 ]; then
  sed 's/^  if _spool_agy_fb_is_review "\$@"; then$/  if false; then/' "$LIB" >"$T_TMP/red.inc.sh"
  grep -q '^  if false; then$' "$T_TMP/red.inc.sh" || { echo "red control: the review branch was not found" >&2; exit 2; }
  LIB="$T_TMP/red.inc.sh"
fi
export SPOOL_AGY_PROBE_DIR="$T_TMP/probe" SPOOL_AGY_FALLBACK_CNF="$T_TMP/cnf.yaml"
export SPOOL_AGY_QUOTA_CMD="echo q >>'$T_TMP/qcalls'; cat '$T_TMP/quota.tsv'"
export SPOOL_AGY_MODELS_CMD="echo m >>'$T_TMP/mcalls'; cat '$T_TMP/models.tsv'"
cnf() {  # ENABLED [CACHE_S]
  printf 'env:\n  box:\n    agent_split:\n      agy_fallback:\n        enabled: %s\n        weekly_min: 0.05\n        five_hour_min: 0.05\n        alt_min: 0.10\n        models: [claude-sonnet-5-5-high, claude-opus-5-5-high]\n        kinds: [specs_and_docs, complex_coding]\n        cache_s: %s\n' "$1" "${2:-0}" >"$SPOOL_AGY_FALLBACK_CNF"
}
quota() {  # GEM_WEEKLY GEM_5H 3P_WEEKLY 3P_5H
  printf 'gemini-weekly\t%s\t2026-12-03T07:01:52Z\ngemini-5h\t%s\t-\n3p-weekly\t%s\t-\n3p-5h\t%s\t-\n' "$@" >"$T_TMP/quota.tsv"
}
printf 'gemini-4-neon-high\tGemini 4 Neon (High)\nclaude-sonnet-5-5-high\tClaude Sonnet 5.5 (High)\nclaude-opus-5-5-high\tClaude Opus 5.5 (High)\n' >"$T_TMP/models.tsv"
mkdir -p "$T_TMP/briefs"
printf '# Lane brief: write the doc\n\nKind: specs_and_docs\n' >"$T_TMP/briefs/doc.md"
printf '# Lane brief: the cross-vendor R7 reviewer\n\nKind: complex_coding\nAuthor: c-123\n' >"$T_TMP/briefs/r7.md"
printf '# Lane brief: the R7 reviewer of an agy lane\n\nKind: review\nAuthor: a-321\n' >"$T_TMP/briefs/r7a.md"
printf '# Lane brief: translate\n\nKind: i18n\n' >"$T_TMP/briefs/i18n.md"
fb() {  # SEAT BRIEF -> the words, and AGY_FB_* in files
  # shellcheck source=/dev/null
  ( . "$T_SCRIPTS/../lib/spool-env.inc.sh"; . "$LIB"; w="$(spool_agy_fallback_flags "$1" "$2" 2>"$T_TMP/fb.err")"; printf '%s' "$w" )
}
calls() { wc -l <"$T_TMP/$1" 2>/dev/null | tr -d ' ' || echo 0; }
reset() { rm -rf "$T_TMP/probe" "$T_TMP/qcalls" "$T_TMP/mcalls"; }
mkdir -p "$SPOOL_ROOT/a-501/lifetime"

# 1
cnf false; quota 0.01 0.01 1 1; reset
eq "1. off: no words" "" "$(fb a-501 "$T_TMP/briefs/doc.md")"
check "1. off: the quota was not read" test ! -e "$T_TMP/qcalls"
check "1. off: no record written" test ! -e "$SPOOL_ROOT/a-501/lifetime/agy-fallback.json"
# 2
cnf true; quota 0.5 0.5 1 1; reset
eq "2. Gemini above the marks: no words" "" "$(fb a-501 "$T_TMP/briefs/doc.md")"
has "2. ... and says why" "stays on Gemini" "$(cat "$T_TMP/fb.err")"
# 3
quota 0.02 0.9 1 1; reset
eq "3. weekly low: the first alternative" "--model 'claude-sonnet-5-5-high'" "$(fb a-501 "$T_TMP/briefs/doc.md")"
eq "3. the record names the model" claude-sonnet-5-5-high "$(jq -r .model "$SPOOL_ROOT/a-501/lifetime/agy-fallback.json")"
eq "3. ... and counts the seat as claude" claude "$(jq -r .effective_vendor "$SPOOL_ROOT/a-501/lifetime/agy-fallback.json")"
# 4
quota 0.9 0.01 1 1; reset
eq "4. 5h low: switches too" "--model 'claude-sonnet-5-5-high'" "$(fb a-501 "$T_TMP/briefs/doc.md")"
# 5
printf 'gemini-4-neon-high\tx\nclaude-opus-5-5-high\ty\n' >"$T_TMP/models.tsv"
quota 0.01 0.01 1 1; reset
eq "5. an unlisted alternative is skipped" "--model 'claude-opus-5-5-high'" "$(fb a-501 "$T_TMP/briefs/doc.md")"
printf 'gemini-4-neon-high\tGemini 4 Neon (High)\nclaude-sonnet-5-5-high\tClaude Sonnet 5.5 (High)\nclaude-opus-5-5-high\tClaude Opus 5.5 (High)\n' >"$T_TMP/models.tsv"
# 6
quota 0.01 0.01 0.05 1; reset
eq "6. the 3p pool short of alt_min: no words" "" "$(fb a-501 "$T_TMP/briefs/doc.md")"
has "6. ... and says so" "no alternative is listed with room" "$(cat "$T_TMP/fb.err")"
# 7
quota 0.0 0.0 1 1; reset
eq "7. HARD RULE: a claude author's review seat never falls back" "" "$(fb a-501 "$T_TMP/briefs/r7.md")"
has "7. ... names the claude author" "claude author (c-123)" "$(cat "$T_TMP/fb.err")"
check "7. ... and its quota was not read" test ! -e "$T_TMP/qcalls"
eq "7b. any review seat waits (until the owner rules)" "" "$(fb a-501 "$T_TMP/briefs/r7a.md")"
has "7b. ... says so" "a review seat: no fallback" "$(cat "$T_TMP/fb.err")"
eq "7c. a kind not in the list stays" "" "$(fb a-501 "$T_TMP/briefs/i18n.md")"
eq "7d. no brief: stays" "" "$(fb a-501 "")"
# 8
export SPOOL_AGY_QUOTA_CMD="false"; reset
eq "8. quota unread: no words" "" "$(fb a-501 "$T_TMP/briefs/doc.md")"
has "8. ... says so" "agy quota unread" "$(cat "$T_TMP/fb.err")"
export SPOOL_AGY_QUOTA_CMD="echo q >>'$T_TMP/qcalls'; cat '$T_TMP/quota.tsv'"
# 9
cnf true 300; quota 0.01 0.9 1 1; reset
fb a-501 "$T_TMP/briefs/doc.md" >/dev/null; fb a-501 "$T_TMP/briefs/doc.md" >/dev/null
eq "9. a reading is reused within cache_s" 1 "$(calls qcalls)"
cnf true 0; reset
fb a-501 "$T_TMP/briefs/doc.md" >/dev/null; fb a-501 "$T_TMP/briefs/doc.md" >/dev/null
eq "9. ... and read again with cache_s 0" 2 "$(calls qcalls)"
# 10 (a dry run reads only a fresh cached reading: one live read fills it)
WD="$T_TMP/plain"; mkdir -p "$WD" "$T_TMP/plan"
cnf true 300; quota 0.01 0.9 1 1; reset; fb a-501 "$T_TMP/briefs/doc.md" >/dev/null
out="$(SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool SPAWN_PLAN_DIR="$T_TMP/plan" bash "$T_SCRIPTS/spawn-agy.sh" a-502 "$WD" "$T_TMP/briefs/doc.md" "write the doc" 2>&1)"
has "10. spawn-agy plans the alternative model" "extra=--model 'claude-sonnet-5-5-high'" "$out"
has "10. ... and the launch carries it" "--model 'claude-sonnet-5-5-high'" "$(cat "$T_TMP/plan/launch.cmd")"
eq "10. ... from the cached reading (no new read)" 1 "$(calls qcalls)"
cnf false; reset; rm -rf "$T_TMP/plan"; mkdir -p "$T_TMP/plan"
out="$(SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool SPAWN_PLAN_DIR="$T_TMP/plan" bash "$T_SCRIPTS/spawn-agy.sh" a-502 "$WD" "$T_TMP/briefs/doc.md" "write the doc" 2>&1)"
hasnt "10. off: no extra flags in the plan" "extra=" "$out"
hasnt "10. off: no --model in the launch" "--model" "$(cat "$T_TMP/plan/launch.cmd")"
# 11
cnf true; quota 0.01 0.9 1 1; reset
mkdir -p "$SPOOL_ROOT/a-503/lifetime"
printf 'Then read your full task brief at %s and do it.\n' "$T_TMP/briefs/doc.md" >"$SPOOL_ROOT/a-503/lifetime/prompt.txt"
has "11. restore-agy decides again from the seat's brief" "--model 'claude-sonnet-5-5-high' --conversation c-9" "$(RESTORE_PRINT=1 AGY_BIN=agy bash "$T_SCRIPTS/restore-agy.sh" a-503 "$WD" c-9 hi 2>&1)"
quota 0.5 0.5 1 1; reset
hasnt "11. ... and resumes on Gemini once the quota is back" "--model" "$(RESTORE_PRINT=1 AGY_BIN=agy bash "$T_SCRIPTS/restore-agy.sh" a-503 "$WD" c-9 hi 2>&1)"

# 12
cnf true; quota 0.0 0.0 1 1; reset
{ printf '# Brief: you are a-504@box, restarted by the watchdog (r-1)\n\nSame id.\n\n## A. Your brief (/x/briefs/hand-x.md)\n\n'
  printf '# Lane brief: the cross-vendor R7 reader of a claude lane\n\nKind: specs_and_docs\nAuthor: c-738@box (claude)\n\n## B. The handoff\n'; } >"$T_TMP/restart.seed.md"
eq "12. HARD RULE: a restart seed of a claude author's review seat stays" "" "$(fb a-501 "$T_TMP/restart.seed.md")"
has "12. ... names the claude author" "claude author (c-738)" "$(cat "$T_TMP/fb.err")"
check "12. ... and its quota was not read" test ! -e "$T_TMP/qcalls"
printf '# Lane brief: check the change\n\nKind: complex_coding\nAuthor: a-321\n' >"$T_TMP/briefs/check.md"
eq "12b. an Author: line alone marks a review seat" "" "$(fb a-501 "$T_TMP/briefs/check.md")"
has "12b. ... says so" "a review seat" "$(cat "$T_TMP/fb.err")"
mkdir -p "$SPOOL_ROOT/a-505/lifetime"
printf '# Lane brief: the R7 code review\n\nKind: complex_coding\nAuthor: c-123\n' >"$SPOOL_ROOT/a-505/lifetime/brief.md"
printf '# Brief: you are a-505 again (hourly rotation)\n\nYour task brief, unchanged.\n' >"$T_TMP/rot.seed.md"
eq "12c. a rotation seed of a review seat stays (by lifetime/brief.md)" "" "$(fb a-505 "$T_TMP/rot.seed.md")"
# 13
quota 0.01 0.9 1 1; reset
mkdir -p "$SPOOL_ROOT/a-506/lifetime"; cp "$T_TMP/briefs/doc.md" "$SPOOL_ROOT/a-506/lifetime/brief.md"
eq "13. a rotation seed with no Kind: decides by lifetime/brief.md" "--model 'claude-sonnet-5-5-high'" "$(fb a-506 "$T_TMP/rot.seed.md")"
mkdir -p "$SPOOL_ROOT/a-507/lifetime"; cp "$T_TMP/briefs/doc.md" "$T_TMP/a507-brief.md"
printf 'Then read your full task brief at %s and do it.\n' "$SPOOL_ROOT/a-506/lifetime/brief.md" >"$SPOOL_ROOT/a-507/lifetime/prompt.txt"
# shellcheck source=/dev/null
eq "13b. a seed naming a lifetime/brief.md resolves it" "$SPOOL_ROOT/a-506/lifetime/brief.md" "$( . "$LIB"; spool_agy_fallback_seat_brief a-507)"
has "13c. restore-agy finds the brief by lifetime/brief.md alone" "--model 'claude-sonnet-5-5-high' --conversation c-9" "$(RESTORE_PRINT=1 AGY_BIN=agy bash "$T_SCRIPTS/restore-agy.sh" a-506 "$WD" c-9 hi 2>&1)"
# 14
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$T_TMP/agy-stall"; chmod +x "$T_TMP/agy-stall"
mkdir -p "$T_TMP/tq"; s0=$(date +%s)
TMPDIR="$T_TMP/tq" timeout 20 python3 -I "$T_SCRIPTS/agy-quota-read.py" --agy "$T_TMP/agy-stall" --timeout 1 >/dev/null 2>&1; rc=$?
eq "14. a stalled agy acp: the reader ends itself, rc 4" 4 "$rc"
check "14. ... within the timeout (not the outer 20 s)" test $(( $(date +%s) - s0 )) -lt 15
TMPDIR="$T_TMP/tq" python3 -I "$T_SCRIPTS/agy-quota-read.py" --agy "$T_TMP/no-such-agy" --timeout 1 >/dev/null 2>&1; rc=$?
eq "14b. an absent agy: rc 4" 4 "$rc"
eq "14b. ... and no temp dir left" "" "$(ls -A "$T_TMP/tq")"
# 15
cnf true 0; quota 0.01 0.9 1 1; reset; rm -f "$SPOOL_ROOT/a-501/lifetime/agy-fallback.json"
eq "15. dry run, no cached reading: no words" "" "$(SPAWN_DRY_RUN=1 fb a-501 "$T_TMP/briefs/doc.md")"
check "15. ... no agy read" test ! -e "$T_TMP/qcalls"
check "15. ... no record written" test ! -e "$SPOOL_ROOT/a-501/lifetime/agy-fallback.json"

# 16
cnf true; quota 0.0 0.0 1 1; reset
{ printf '# Brief: you are a-508@box, restarted by the watchdog (r-2)\n\nSame id.\n\n## A. Your brief (/x/briefs/hand-y.md)\n\n'
  printf '# Lane brief: the R7 reader of an agy lane\n\nKind: specs_and_docs\n\n## B. The handoff\n'; } >"$T_TMP/restart2.seed.md"
eq "16. a restart seed, no Author:, review heading not first: stays" "" "$(fb a-501 "$T_TMP/restart2.seed.md")"
has "16. ... as a review seat" "a review seat: no fallback" "$(cat "$T_TMP/fb.err")"
check "16. ... and its quota was not read" test ! -e "$T_TMP/qcalls"
# 17
printf '# Lane brief: check the change\n\nKind: specs_and_docs\n\n- **Author:** c-124@box (claude)\n' >"$T_TMP/briefs/bullet.md"
eq "17. a - **Author:** bullet marks a review seat" "" "$(fb a-501 "$T_TMP/briefs/bullet.md")"
has "17. ... names its claude author" "claude author (c-124)" "$(cat "$T_TMP/fb.err")"
printf '# Lane brief: check the change\n\nKind: specs_and_docs\n\n| field | value |\n|---|---|\n| Author | c-125 |\n' >"$T_TMP/briefs/table.md"
eq "17b. an Author table row marks a review seat" "" "$(fb a-501 "$T_TMP/briefs/table.md")"
has "17b. ... names its claude author" "claude author (c-125)" "$(cat "$T_TMP/fb.err")"
printf '# Lane brief: write the doc\n\nKind: specs_and_docs\n\nAuthority: the spec owner\n' >"$T_TMP/briefs/authority.md"
quota 0.02 0.9 1 1; reset
eq "17c. control: an Authority: line is no Author: line" "--model 'claude-sonnet-5-5-high'" "$(fb a-501 "$T_TMP/briefs/authority.md")"
# 18
# (a deadline LEFT seconds from now; a clock tick between the two date
# calls may take 1 s, so the cut values are checked as a range)
# shellcheck source=/dev/null
tmo() { ( . "$LIB"; _AGY_FB_DEADLINE=$(( $(date +%s) + $1 )); _spool_agy_fb_tmo ); }
inr() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 )); }
# shellcheck source=/dev/null
eq "18. no budget set: the per-read bound" 60 "$(unset _AGY_FB_DEADLINE; . "$LIB"; _spool_agy_fb_tmo)"
eq "18. the first read of a fresh 80 s budget: 60" 60 "$(tmo 80)"
check "18. the second read after a stalled first (65 s): 10" inr "$(tmo 16)" 10 11
eq "18. under 10 s left: no read" "" "$(tmo 14)"
# shellcheck source=/dev/null
budget="$( . "$LIB"; _spool_agy_fb_budget)"
wd="$(grep -m1 -oE 'WD_START_WAIT:=[0-9]+' "$T_SCRIPTS/../../../run/spl-agent-restart.func.sh" | cut -d= -f2)"
check "18. the budget ($budget s) is below WD_START_WAIT (${wd:-?} s)" test "$budget" -lt "${wd:-0}"
t1="$(tmo "$budget")"; t2="$(tmo $(( budget - t1 - 5 )))"
check "18. worst case: two stalled reads ($t1+5, ${t2:-none}) fit the budget" test $(( t1 + 5 + ${t2:-0} + (${t2:-0} > 0 ? 5 : 0) )) -le "$budget"
# shellcheck source=/dev/null
out="$( unset SPOOL_AGY_QUOTA_CMD SPOOL_AGY_MODELS_CMD; . "$LIB"; reset
  spool_agent_exec() { printf '%s\n' "$1" >>"$T_TMP/exec"; return 1; }
  _AGY_FB_DEADLINE=$(( $(date +%s) + 40 )); spool_agy_quota >/dev/null
  _AGY_FB_DEADLINE=$(( $(date +%s) + 12 )); spool_agy_model_ids >/dev/null; echo "rc=$?"; cat "$T_TMP/exec")"
check "18. the quota read is cut to the budget left" grep -qE 'timeout -k 5 3[45] python3' <<<"$out"
check "18. ... and its reader's own --timeout too" grep -qE -- '--timeout (29|30)\b' <<<"$out"
hasnt "18. the models read is not started with 7 s left" "models" "$out"

t_done
