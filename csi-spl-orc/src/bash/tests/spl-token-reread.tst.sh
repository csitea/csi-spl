#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_reread (SPL-2216) on synthetic lane sessions in a
# mktemp home; no live transcript is read.
#   1. grok: the same read_file input again is a repeat; its tokens are its
#      result bytes / 4 (50 lines of "xxx" = 199 bytes = 50 tokens)
#   2. grok: lines 1-50 then 41-90 of one file overlap by 10 of 50 lines; a
#      read of lines 101-150 overlaps nothing. Control: counting every read of
#      a path already read (any range) gives 2, not 1
#   3. an edit of the file or a compaction resets both: the read after it is
#      neither a repeat nor an overlap (c6, c7); the same read after c7 is (c9)
#   4. carried tokens: a result weighs its tokens x the model calls after it
#      up to the compaction: the c2 repeat in call 1 of 3 weighs 50 x 2, c9 in
#      the last call 0
#   5. claude: a Read repeat and a "cd X; cat F" repeat are counted, classed
#      file and cat; a compound "cat a; cat b" reads no one path
#   6. the per-vendor summary, and an empty home says so
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

H="$T/home" NOW_ISO="$(date -u +%Y-%m-%dT%H:%M)"
G="$H/.grok/sessions/%2Fopt%2Fx-wt%2Fg-301"
mkdir -p "$G/s1" "$H/.claude/projects/-opt-x-wt-c-101"
echo sys >"$G/s1/system_prompt.txt"
echo '{"session":{"inputTokens":100000}}' >"$G/s1/usage.json"
L50="$(printf 'xxx\n%.0s' $(seq 50))"
# gcall <stream> <id> <tool> <rawInput json> <rawOutput json>
gcall() {
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"%s","title":"%s","rawInput":%s},"_meta":{"streamStartMs":%s}}}\n' "$2" "$3" "$4" "$1"
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"%s","status":"completed","rawOutput":%s},"_meta":{"streamStartMs":%s}}}\n' "$2" "$5" "$1"
}
RF="$(jq -cn --arg c "$L50" '{type: "ReadFile", FileContent: {content: $c}}')"   # 50 lines, 199 bytes
GF='"/w/a.mjs"'
{
  gcall 1 c1 read_file "{\"target_file\":$GF,\"offset\":1,\"limit\":50}" "$RF"
  gcall 1 c2 read_file "{\"target_file\":$GF,\"offset\":1,\"limit\":50}" "$RF"
  gcall 2 c3 read_file "{\"target_file\":$GF,\"offset\":41,\"limit\":50}" "$RF"
  gcall 2 c4 read_file "{\"target_file\":$GF,\"offset\":101,\"limit\":50}" "$RF"
  gcall 3 c5 search_replace "{\"file_path\":$GF,\"old_string\":\"a\",\"new_string\":\"b\"}" '{"type":"SearchReplace"}'
  gcall 3 c6 read_file "{\"target_file\":$GF,\"offset\":1,\"limit\":50}" "$RF"
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"auto_compact_completed"}}}\n'
  gcall 4 c7 read_file "{\"target_file\":$GF,\"offset\":1,\"limit\":50}" "$RF"
  gcall 4 c8 run_terminal_command '{"command":"echo hi"}' '{"type":"Bash","output_for_prompt":"hi"}'
  gcall 5 c9 read_file "{\"target_file\":$GF,\"offset\":1,\"limit\":50}" "$RF"
} >"$G/s1/updates.jsonl"

C="$H/.claude/projects/-opt-x-wt-c-101"
# cuse <msg id> <tool id> <tool> <input json>; cres <tool id> <content>
cuse() { printf '{"type":"assistant","timestamp":"%s:00.000Z","message":{"id":"%s","usage":{"input_tokens":10,"cache_read_input_tokens":990},"content":[{"type":"tool_use","id":"%s","name":"%s","input":%s}]}}\n' "$NOW_ISO" "$1" "$2" "$3" "$4"; }
cres() { printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":%s}]}}\n' "$1" "$(jq -cn --arg c "$2" '$c')"; }
{
  cuse m1 t1 Read '{"file_path":"/w/b.go"}'; cres t1 "$(printf '%0400d' 0)"
  cuse m2 t2 Read '{"file_path":"/w/b.go"}'; cres t2 "$(printf '%0400d' 0)"
  cuse m3 t3 Bash '{"command":"cd /w; cat /w/c.md","description":"x"}'; cres t3 "$(printf '%080d' 0)"
  cuse m4 t4 Bash '{"command":"cd /w; cat /w/c.md","description":"y"}'; cres t4 "$(printf '%080d' 0)"
  cuse m5 t5 Bash '{"command":"cat /w/c.md; cat /w/d.md"}'; cres t5 "abc"
} >"$C/a.jsonl"

run() { TOKEN_REREAD_HOMES="$1" TOKEN_REREAD_SINCE="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M)" \
  bash -c 'source "$1/src/bash/run/spl-token-reread.func.sh"; do_spl_token_reread' _ "$PROJ_ROOT" 2>&1; }
out="$(run "$H")"
grow="$(grep -P '^grok\t' <<<"$out")" crow="$(grep -P '^claude\t' <<<"$out")"
IFS=$'\t' read -r _ glane _ _ ginput greads _ grep_ grtok govl gotok _ _ gby gcalls gwr gwo _ <<<"$grow"

[ "$glane" = g-301 ] && [ "$ginput" = 100000 ] && [ "$greads" = 7 ] && [ "$grep_" = 2 ] && [ "$grtok" = 100 ] \
  && pass "1. grok: 2 exact repeats of 7 reads, 50 tokens each" || fail "1. grok repeat ($grow)"
[ "$govl" = 3 ] && [ "$gotok" = 110 ] \
  && pass "2. grok: c2 and c9 overlap fully (50 + 50), the 41-90 read by 10 of 50 lines (10); 101-150 not" || fail "2. overlap ($grow)"
ctl="$(jq -rn 'inputs | .params.update | select(.sessionUpdate == "tool_call" and .title == "read_file") | .rawInput.target_file' \
  <(head -8 "$G/s1/updates.jsonl") | awk 'seen[$0]++' | wc -l)"
[ "$ctl" = 3 ] && pass "2. control: a same-path count of the first 4 reads gives 3, the line overlap 2 (c2, c3)" || fail "2. control ($ctl)"
[ "$gby" = "file=2,grep=0,tree=0,cat=0,git=0" ] \
  && pass "3. the reads after the edit and after the compaction are not repeats (c6, c7); c2 and c9 are" || fail "3. resets ($gby)"
[ "$gcalls" = 5 ] && [ "$gwr" = 100 ] && [ "$gwo" = 110 ] \
  && pass "4. carried: repeats 50 x 2 + 50 x 0, overlaps 100 + 10 x 1 + 0" || fail "4. carried ($grow)"
IFS=$'\t' read -r _ clane _ _ cinput creads _ crep _ _ _ _ _ cby _ <<<"$crow"
[ "$clane" = c-101 ] && [ "$cinput" = 5000 ] && [ "$creads" = 5 ] && [ "$crep" = 2 ] && [ "$cby" = "file=1,grep=0,tree=0,cat=1,git=0" ] \
  && pass "5. claude: Read and 'cd X; cat F' repeats counted, the description ignored" || fail "5. claude ($crow)"
grep -q '^grok sessions=1 reads=7 repeats=2 repeat_tok=100 ' <<<"$out" && grep -q '^claude sessions=1 reads=5 repeats=2 ' <<<"$out" \
  && grep -q '^grok input_tok=100000 carried: repeats=100 (0.10% of input) overlaps=110 (0.11% of input)' <<<"$out" \
  && pass "6. the per-vendor summary" || fail "6. summary ($out)"
grep -q 'no lane session in the window' <<<"$(run "$H/none")" && pass "6. an empty home says so" || fail "6. empty home"

echo "spl-token-reread: $fails failure(s)"
[ "$fails" -eq 0 ]
