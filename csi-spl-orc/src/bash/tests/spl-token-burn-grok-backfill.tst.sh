#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_burn_grok_backfill (SPL-2461) on synthetic grok
# sessions in a mktemp home; no live session, tmux or hub is touched.
#   1. one bucket per agent and UTC minute from the per-turn counters (input
#      less cache reads), the agents named as the live collector names them
#      (g-NNN, GRK-NNN, "<id> (grok)", "unattributed (cwd <dir>)")
#   2. a turn older than TOKEN_BURN_BACKFILL_DAYS and a session that moved
#      inside the live window are skipped and counted, never pushed
#   3. DRY_RUN=1 (default) writes the frames and pushes nothing
#   4. DRY_RUN=0 pushes every frame; a re-run sends the same frames (the hub
#      replaces on box, agent, minute); 2100 minutes go as two frames of at
#      most 2000 samples, none repeating (agent, minute)
#   5. a refused push stops the run with FATAL, exit 1
#   6. no prompt text reaches the frames or the output
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL: jq and python3 are required"; exit 1; }

NOW=1792080000 H="$T/home" S="$T/state" TXT=PROMPT-TEXT-MUST-NOT-LEAK
M=$((NOW - NOW % 60 - 86400))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S; }
cat >"$T/push" <<'EOF'
#!/usr/bin/env bash
cat >>"$PUSH_LOG"; echo >>"$PUSH_LOG"
[ "${PUSH_FAIL:-0}" = 1 ] && { echo 'bad_samples: sample 0: minute must be within the last 30 days' >&2; exit 1; }
echo '{"type":"ack","lane_op":"fleet_tokens_push","inserted":1}'
EOF
chmod +x "$T/push"

# gsess <encoded cwd> <sid> <updated epoch> <turn spec...>: a usage.json
# whose turns are "<ended epoch>:<in>:<cache_read>:<out>"
gsess() {
  local d="$H/.grok/sessions/$1/$2" sid="$2" up="$3" t turns="" e a b c
  mkdir -p "$d"; shift 3
  for t in "$@"; do
    IFS=: read -r e a b c <<<"$t"
    turns+="${turns:+,}{\"endedAt\":\"$(iso "$e").123456789+00:00\",\"inputTokens\":$a,\"cachedReadTokens\":$b,\"outputTokens\":$c,\"cacheCreationTokens\":0,\"primaryModelId\":\"grok-x\",\"note\":\"$TXT\"}"
  done
  printf '{"sessionId":"%s","updatedAt":"%s.5+00:00","session":{"inputTokens":1,"outputTokens":1,"cachedReadTokens":0,"cacheCreationTokens":0,"primaryModelId":"grok-x"},"turns":[%s]}\n' \
    "$sid" "$(iso "$up")" "$turns" >"$d/usage.json"
}
gsess "%2Fopt%2Fx-wt%2Fg-401" s1 $((M + 70)) "$((M + 5)):100:60:7" "$((M + 20)):50:10:3" "$((M + 70)):9:0:1"
gsess "%2Fopt%2Fx-wt%2Fg-401" s2 $((M + 30)) "$((M + 30)):1000:0:10"
gsess "%2Fopt%2Fx-rel-wt%2FCLE-2-wt%2FGRK-05" s3 $((M + 5)) "$((M + 5)):4:0:1"
gsess "%2Fopt%2Fx-wt%2Fc-101" s4 $((M + 5)) "$((M + 5)):3:0:1"
gsess "%2Fopt" s5 $((M + 5)) "$((M + 5)):2:0:1"
gsess "%2Ftmp%2Ftmp.Q1" s6 $((M + 5)) "$((M + 5)):2:0:1"
gsess "%2Fopt%2Fx-wt%2Fg-402" old $((M + 5)) "$((NOW - 40 * 86400)):500:0:5" "$((M + 5)):8:0:2"
gsess "%2Fopt%2Fx-wt%2Fg-403" live $((NOW - 120)) "$((NOW - 120)):700:0:7"

run() {
  env TOKEN_BURN_STATE_DIR="$S" TOKEN_BURN_HOMES="$H" TOKEN_BURN_NOW="$NOW" TOKEN_BURN_PUSH_CMD="$T/push" PUSH_LOG="$T/pushed" \
    SPOOL_ROOT="$T/spool" FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-grok-backfill.func.sh" "$@" \
    bash -c 'source "$FUNC"; do_spl_token_burn_grok_backfill' 2>&1
}
# b <agent> -> "<minute offset from M> in out cache_read cache_write" per bucket, ';'-joined
b() { jq -r --arg a "$1" --argjson m "$M" '.samples[] | select(.agent_id == $a) |
  "\((.minute | fromdate) - $m) \(.tokens_in) \(.tokens_out) \(.cache_read) \(.cache_write)"' "$S"/backfill/frame-*.json | paste -sd';'; }

out="$(run)"; rc=$?
# g-401: the turns at M+5 and M+20 share minute M, s2's at M+30 too: one bucket
[[ "$rc" == 0 && "$(b g-401)" == "0 1080 20 70 0;60 9 1 0 0" ]] &&
  pass "1. per agent and minute: g-401's three minute-M turns of two sessions are one bucket, input less cache reads" || fail "1. g-401: $(b g-401) | $out"
[[ "$(b GRK-05)" == "0 4 1 0 0" && "$(b 'c-101 (grok)')" == "0 3 1 0 0" && "$(b 'unattributed (cwd /opt)')" == "0 2 1 0 0" &&
   "$(b 'unattributed (cwd /tmp)')" == "0 2 1 0 0" ]] &&
  pass "1. named as the live collector names them (GRK-05, c-101 (grok), unattributed (cwd /opt|/tmp))" || fail "1. names: $(jq -r '.samples[].agent_id' "$S"/backfill/frame-*.json | sort -u | paste -sd,)"
[[ "$(jq -r '[.samples[] | .vendor == "grok" and .is_metered and .model == "grok-x"] | all' "$S"/backfill/frame-*.json)" == true ]] &&
  pass "1. every sample is vendor grok, metered, its model" || fail "1. vendor/model"
[[ "$(b g-402)" == "0 8 2 0 0" && -z "$(b g-403)" && "$out" == *"skipped_old=1 skipped_live=1"* ]] &&
  pass "2. a turn older than the days is skipped, a session in the live window too, both counted" || fail "2. g-402=$(b g-402) g-403=$(b g-403) | $out"
[[ ! -e "$T/pushed" && "$out" == *"DRY_RUN=1"* && "$out" == *"frames=1"* ]] &&
  pass "3. DRY_RUN=1 writes the frame, pushes nothing" || fail "3. dry run: $out"

out="$(run DRY_RUN=0)"; rc=$?
cp "$S"/backfill/frame-000.json "$T/first.json"
out2="$(run DRY_RUN=0)"; rc2=$?
[[ "$rc" == 0 && "$rc2" == 0 && "$(grep -c . "$T/pushed")" == 2 && "$out" == *"OK grok backfill pushed 1 frame(s)"* ]] &&
  cmp -s "$T/first.json" "$S/backfill/frame-000.json" &&
  pass "4. DRY_RUN=0 pushes the frame; a re-run sends the same frame" || fail "4. push: rc=$rc/$rc2 $(grep -c . "$T/pushed") | $out"

H2="$T/home2"
python3 - "$H2/.grok/sessions/%2Fopt%2Fx-wt%2Fg-500/big" "$M" <<'EOF_PY'
import json, os, sys, datetime
d, m = sys.argv[1], int(sys.argv[2])
os.makedirs(d)
iso = lambda e: datetime.datetime.fromtimestamp(e, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.1+00:00")
t = [{"endedAt": iso(m - i * 60), "inputTokens": 2, "cachedReadTokens": 0, "outputTokens": 1, "cacheCreationTokens": 0} for i in range(2100)]
json.dump({"sessionId": "big", "updatedAt": iso(m), "session": {"primaryModelId": "grok-x"}, "turns": t}, open(d + "/usage.json", "w"))
EOF_PY
rm -f "$T/pushed"
out="$(run DRY_RUN=0 TOKEN_BURN_HOMES="$H2")"; rc=$?
sizes="$(for f in "$S"/backfill/frame-*.json; do jq '.samples | length' "$f"; done | paste -sd,)"
dups="$(jq -r '.samples[] | .agent_id + " " + .minute' "$S"/backfill/frame-*.json | sort | uniq -d | wc -l)"
[[ "$rc" == 0 && "$sizes" == "2000,100" && "$dups" == 0 && "$(grep -c . "$T/pushed")" == 2 ]] &&
  pass "4. 2100 minutes go as two frames (2000, 100), no (agent, minute) twice" || fail "4. chunks: rc=$rc sizes=$sizes dups=$dups | $out"

out="$(run DRY_RUN=0 PUSH_FAIL=1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"FATAL push of frame-000.json"* ]] &&
  pass "5. a refused push stops the run: FATAL, exit 1" || fail "5. rc=$rc | $out"

leak="$(grep -rlF "$TXT" "$S" 2>/dev/null; grep -lF "$TXT" "$T/pushed" 2>/dev/null)"
[[ -z "$leak" && "$out$out2" != *"$TXT"* ]] && pass "6. no prompt text in the frames, the state or the output" || fail "6. leaked into: $leak"

echo "spl-token-burn-grok-backfill: $fails failure(s)"
exit "$fails"
