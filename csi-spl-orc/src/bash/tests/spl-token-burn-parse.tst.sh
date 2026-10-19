#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the token burn parse (spec 140 T020, T021) of do_spl_token_burn_collect
# on synthetic transcripts of the three metered vendors in a mktemp home; no
# live transcript, tmux or hub is touched.
#   1. claude: one message id on 3 rows (output 100 each) counts once, the MAX
#      of each field kept, summed with a second id into the agent's minute
#      bucket (from its -wt-<id> project dir); a row older than the window is
#      counted late, not summed. Control: the same code summing per row reads
#      output 307, not 107
#   2. mistral (vibe): the session's cumulative tokenUsage, input without the
#      cached part, the agent from meta.json's origin_directory, the model the
#      alias of config.toml's active_model names
#   3. grok: the session counters of usage.json, the agent from its
#      url-encoded session dir
#   4. a session older than the window seen for the first time is a baseline,
#      not burn; what it grows by after that is
#   5. agy and qwen lanes with a live pane: one unmetered sample, model null,
#      is_metered false, a claude lane none. Control: the assertion refuses an
#      agy sample reported metered with 0 tokens
#   6. no prompt or completion text reaches the state dir or the frame
#   7. grok, named apart (SPL-2461): a claude lane's grok session is
#      "c-101 (grok)", a cwd with no lane id "unattributed (cwd <dir>)" (every
#      /tmp dir as /tmp), never summed into the claude bucket of the same
#      minute; a g- session first seen with a turn that ended before the
#      window counts its new turn only. Controls: named by the claude rule
#      the grok tokens vanish into c-101's claude bucket; with the session
#      counters as the baseline the g- lane's new turn is missing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL: jq and python3 are required"; exit 1; }

NOW=1792080000 H="$T/home" S="$T/state" R="$T/spool" TXT=PROMPT-TEXT-MUST-NOT-LEAK
M0=$((NOW - NOW % 60 - 120))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
mkdir -p "$R/agents" "$H/.claude/projects/-opt-x-wt-c-101" "$H/.vibe/logs/session/unified/v1/journal" \
  "$H/.vibe/logs/session/unified/v2/journal" "$H/.grok/sessions/%2Fopt%2Fx-wt%2Fg-301/s1"
printf '#!/usr/bin/env bash\ncat >>"%s/pushed"; echo "{\\"inserted\\":1}"\n' "$T" >"$T/push"
printf '#!/usr/bin/env bash\nprintf "a-401\\nc-101\\nq-501@sat\\n"\n' >"$T/live"
chmod +x "$T/push" "$T/live"

# tick [VAR=val...]: one collector tick on the fixture home
tick() {
  env TOKEN_BURN_STATE_DIR="$S" TOKEN_BURN_HOMES="$H" TOKEN_BURN_NOW="$NOW" TOKEN_BURN_LIVE_CMD="$T/live" \
    TOKEN_BURN_PUSH_CMD="$T/push" SPOOL_ROOT="$R" COLLECT_FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" "$@" \
    bash -c 'source "$COLLECT_FUNC"; do_spl_token_burn_collect' 2>&1
}
# bucket <agent> -> "vendor model in out cache_read cache_write metered" summed over its minutes
bucket() {
  awk -F'\t' -v a="$1" '$1 == a { v = $2; m = $3; i += $5; o += $6; r += $7; w += $8; met = $9 }
    END { if (v != "") print v, (m == "" ? "-" : m), i, o, r, w, met }' "$S/buckets.tsv"
}
# claude row <ts> <id> <in> <out> <cache_read> <cache_creation>
crow() {
  printf '{"type":"assistant","timestamp":"%s","uuid":"u","message":{"id":"%s","model":"m-x","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$(iso "$1")" "$2" "$TXT" "$3" "$4" "$5" "$6"
}
# vibe row <sid> <created ms> <updated ms> <input> <cached> <output>
vrow() {
  printf '{"payload":{"delta":[{"entry":{"content":[{"text":"%s"}]},"op":"append_entry"},{"op":"set_envelope","state":{"session":{"id":"%s","createdAt":%s,"updatedAt":%s,"preview":"%s","tokenUsage":{"cachedInputTokens":%s,"inputTokens":%s,"outputTokens":%s,"totalTokens":0}}}}]},"type":"projection_delta"}\n' \
    "$TXT" "$1" "$2" "$3" "$TXT" "$5" "$4" "$6"
}

tick >/dev/null # the first tick only starts every file at its end
P="$H/.claude/projects/-opt-x-wt-c-101/11111111-1111-1111-1111-111111111111.jsonl"
{
  crow $((M0 + 1)) msg_A 2 100 0 50
  crow $((M0 + 2)) msg_A 2 100 500 50
  crow $((M0 + 3)) msg_A 2 100 1000 50
  crow $((M0 + 4)) msg_B 5 7 11 13
  crow $((NOW - 7200)) msg_OLD 9 9 9 9
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$TXT"
} >"$P"
V="$H/.vibe/logs/session/unified"
printf '{"origin_directory":"/opt/x-wt/m-201","title":"%s"}\n' "$TXT" >"$V/v1/meta.json"
printf 'active_model = "large"\n[[models]]\nname = "vendor-large-latest"\nalias = "large"\n' >"$H/.vibe/config.toml"
{ vrow v1 $(((NOW - 600) * 1000)) $(((M0 + 5) * 1000)) 1000 600 50; vrow v1 $(((NOW - 600) * 1000)) $(((M0 + 9) * 1000)) 3000 2000 120; } >"$V/v1/journal/0001.jsonl"
printf '{"origin_directory":"/opt/x-wt/m-202"}\n' >"$V/v2/meta.json"
vrow v2 $(((NOW - 86400) * 1000)) $(((M0 + 5) * 1000)) 50000 40000 900 >"$V/v2/journal/0001.jsonl"
cat >"$H/.grok/sessions/%2Fopt%2Fx-wt%2Fg-301/s1/usage.json" <<EOF
{"sessionId":"s1","updatedAt":"$(date -u -d "@$((M0 + 7))" +%Y-%m-%dT%H:%M:%S).578559802+00:00",
 "session":{"inputTokens":900,"outputTokens":30,"cachedReadTokens":400,"cacheCreationTokens":0,"primaryModelId":"grok-x"},
 "turns":[{"turnNumber":1,"endedAt":"$(date -u -d "@$((NOW - 300))" +%Y-%m-%dT%H:%M:%S).1+00:00","note":"$TXT"}]}
EOF
# gusage <encoded cwd> <sid> <turn spec...>: a usage.json whose turns are
# "<ended epoch>:<in>:<cache_read>:<out>", the session the sum of its turns
gusage() {
  local d="$H/.grok/sessions/$1/$2" t turns="" i=0 r=0 o=0 last=0 e a b c
  mkdir -p "$d"; shift 2
  for t in "$@"; do
    IFS=: read -r e a b c <<<"$t"
    turns+="${turns:+,}{\"turnNumber\":1,\"endedAt\":\"$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%S).5+00:00\",\"inputTokens\":$a,\"cachedReadTokens\":$b,\"outputTokens\":$c,\"cacheCreationTokens\":0,\"primaryModelId\":\"grok-x\"}"
    i=$((i + a)) r=$((r + b)) o=$((o + c)) last="$e"
  done
  printf '{"sessionId":"%s","updatedAt":"%s.5+00:00","session":{"inputTokens":%s,"outputTokens":%s,"cachedReadTokens":%s,"cacheCreationTokens":0,"primaryModelId":"grok-x"},"turns":[%s]}\n' \
    "${d##*/}" "$(date -u -d "@$last" +%Y-%m-%dT%H:%M:%S)" "$i" "$o" "$r" "$turns" >"$d/usage.json"
}
gusage "%2Fopt%2Fx-wt%2Fc-101" g7a "$((M0 + 8)):70:20:5"
gusage "%2Fopt" g7b "$((M0 + 9)):11:0:1"
gusage "%2Ftmp%2Ftmp.Ab12" g7c "$((M0 + 9)):3:0:1"
gusage "%2Fopt%2Fx-wt%2Fg-302" g7d "$((NOW - 7200)):5000:4000:300" "$((M0 + 10)):900:600:40"
cp -a "$S" "$T/s7" # the state before this tick, for the controls of 7
out="$(tick)"

[[ "$(bucket c-101)" == "claude m-x 7 107 1011 63 1" ]] &&
  pass "1. claude: 3 rows of one id count once (MAX), summed with a second id" || fail "1. claude bucket: $(bucket c-101) | $out"
[[ "$out" == *"late=1"* ]] && pass "1. a row older than the window is counted late, not summed" || fail "1. late: $out"
cp "$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" "$T/naive.func.sh"
cp "$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh" "$T/"
python3 - "$T/naive.func.sh" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
old = 'x[j] = f[j + 5] - im[id, j]'
assert old in s; open(p, 'w').write(s.replace(old, 'x[j] = f[j + 5] + 0 * im[id, j]'))
EOF
rm -rf "$T/s2"; tick TOKEN_BURN_STATE_DIR="$T/s2" COLLECT_FUNC="$T/naive.func.sh" >/dev/null
mv "$P" "$P.x"; cp "$P.x" "$P"; rm -f "$P.x"
tick TOKEN_BURN_STATE_DIR="$T/s2" COLLECT_FUNC="$T/naive.func.sh" >/dev/null
naive="$(awk -F'\t' '$1 == "c-101" { o += $6 } END { print o }' "$T/s2/buckets.tsv")"
[[ "$naive" == 307 ]] && pass "1. control: a per-row sum reads 307 (the MAX is what makes it 107)" || fail "1. control: $naive"

[[ "$(bucket m-201)" == "mistral vendor-large-latest 1000 120 2000 0 1" ]] &&
  pass "2. vibe: the cumulative tokenUsage, input less cached, agent and model resolved" || fail "2. vibe: $(bucket m-201)"
[[ "$(bucket g-301)" == "grok grok-x 500 30 400 0 1" ]] &&
  pass "3. grok: the usage.json session counters, agent from the session dir" || fail "3. grok: $(bucket g-301)"

[[ -z "$(bucket m-202)" ]] && pass "4. a session older than the window, first seen: a baseline, no burn" || fail "4. baseline: $(bucket m-202)"
vrow v2 $(((NOW - 86400) * 1000)) $(((M0 + 20) * 1000)) 50600 40400 950 >>"$V/v2/journal/0001.jsonl"
tick >/dev/null
[[ "$(bucket m-202)" == "mistral vendor-large-latest 200 50 400 0 1" ]] &&
  pass "4. what it grows by afterwards is burn" || fail "4. growth: $(bucket m-202)"

# agy_ok <frame>: every agy sample unmetered with a null model and 0 counts
agy_ok() { jq -e '[.samples[] | select(.vendor == "agy")] | length > 0 and all(.is_metered == false and .model == null and .tokens_in == 0)' >/dev/null <<<"$1"; }
frame="$(jq -s -c '{samples: map(.samples[])}' "$T/pushed" 2>/dev/null)"
agy="$(jq -c '[.samples[] | select(.is_metered == false) | [.agent_id, .vendor]] | unique' <<<"$frame" 2>/dev/null)"
[[ "$agy" == '[["a-401","agy"],["q-501","qwen"]]' ]] && agy_ok "$frame" &&
  pass "5. live agy and qwen lanes: one unmetered sample each, model null, never a metered 0" || fail "5. unmetered: $agy | $frame"
bad="$(jq -c '.samples |= map(if .vendor == "agy" then .is_metered = true else . end)' <<<"$frame")"
agy_ok "$bad" && fail "5. control: an agy sample reported metered passed" || pass "5. control: an agy sample reported metered with 0 tokens is refused"

[[ "$(bucket 'c-101 (grok)')" == "grok grok-x 50 5 20 0 1" && "$(bucket 'unattributed (cwd /opt)')" == "grok grok-x 11 1 0 0 1" &&
   "$(bucket 'unattributed (cwd /tmp)')" == "grok grok-x 3 1 0 0 1" ]] &&
  pass "7. grok in a claude lane's cwd or none: its own bucket, never the claude one" || fail "7. named: $(cut -f1,2 "$S/buckets.tsv" | sort -u | tr '\n' ' ')"
[[ "$(bucket g-302)" == "grok grok-x 300 40 600 0 1" ]] &&
  pass "7. a g- session first seen: the turn before the window is the baseline, the new one burn" || fail "7. g-302: $(bucket g-302)"
python3 - "$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" "$T/ctl7.func.sh" <<'EOF_PY'
import sys; s = open(sys.argv[1]).read()
for old, new in (('agent_of(origin[f[11]]) : grok_agent(f[11])', 'agent_of(origin[f[11]]) : agent_of(f[11])'),
                 ('f[2] == "grok" && f[12] != "" ?', '0 ?')):
    assert old in s; s = s.replace(old, new)
open(sys.argv[2], 'w').write(s)
EOF_PY
tick TOKEN_BURN_STATE_DIR="$T/s7" COLLECT_FUNC="$T/ctl7.func.sh" >/dev/null
b7() { awk -F'\t' -v a="$1" '$1 == a { print $2; o += $6 } END { print o + 0 }' "$T/s7/buckets.tsv" | sort -u | tr '\n' ' '; }
[[ "$(b7 c-101)" == "112 claude " ]] && [[ "$(b7 g-302)" == "0 " ]] &&
  pass "7. control: by the claude rule the grok tokens merge into c-101 ($(b7 c-101)), and g-302 has no bucket" || fail "7. control: c-101=$(b7 c-101) g-302=$(b7 g-302)"

AGY_DIR="$H/.gemini/antigravity-cli/brain/conv_a402/.system_generated/logs"
mkdir -p "$AGY_DIR"
printf '{"model":"Gemini 3.8 Flash (High)"}\n' >"$H/.gemini/antigravity-cli/settings.json"
cat >"$AGY_DIR/transcript.jsonl" <<EOF
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"$(iso $((M0 - 10)))","content":"seed: /var/spool-hub/a-402/lifetime/prompt.txt"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"$(iso $((M0 + 6)))","input_tokens":500,"output_tokens":40,"cache_read_tokens":200}
EOF
printf "a-401\na-402\nc-101\nq-501@sat\n" >"$T/live"
tick >/dev/null
[[ "$(bucket a-402)" == "agy gemini-3.8-flash 500 40 200 0 1" ]] &&
  pass "8. agy: transcript PLANNER_RESPONSE turns emitted as metered bucket" || fail "8. agy: $(bucket a-402)"
[[ -z "$(awk -F'\t' '$1 == "a-402" && $9 == 0' "$S/buckets.tsv")" ]] &&
  pass "8. metered agy lane emits no unmetered bucket" || fail "8. a-402 unmetered bucket found"
[[ "$(bucket a-401)" == "agy - 0 0 0 0 0" ]] &&
  pass "8. control: agy lane with no transcript is unmetered, never metered 0" || fail "8. a-401: $(bucket a-401)"

leak="$(grep -rlF "$TXT" "$S" "$T/pushed" 2>/dev/null)"
[[ -z "$leak" && -s "$S/buckets.tsv" ]] && pass "6. no transcript text in the state dir or the pushed frames" || fail "6. text leaked into: $leak"

echo "spl-token-burn-parse: $fails failure(s)"
exit "$fails"
