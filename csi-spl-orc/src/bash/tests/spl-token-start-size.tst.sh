#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_start_size (SPL-2214) on synthetic lane sessions in a
# mktemp home; no live transcript is read.
#   1. grok: the first tool_call's _meta.totalTokens (31845), not the first
#      streamed chunk's partial count (1937). Control: reading the first
#      totalTokens of the file gives 1937
#   2. claude: the first assistant row's input + cache_creation + cache_read
#      (2 + 31914 + 27191 = 59107); a later row does not count
#   3. a session outside the window, a session of the main checkout (no
#      -wt-<id>) and a first row with no tokens are left out
#   4. the summary: n, min, p50, max per vendor
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

H="$T/home" NOW_ISO="$(date -u +%Y-%m-%dT%H:%M)"
G="$H/.grok/sessions/%2Fopt%2Fx-wt%2Fg-301"
mkdir -p "$G/s1" "$G/s2" "$H/.grok/sessions/%2Fopt%2Fx/s3" "$H/.claude/projects/-opt-x-wt-c-101" "$H/.claude/projects/-opt-x"
# gupdate <tokens of the streamed chunk> <tokens at the first tool_call>
gupdate() {
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"hook_execution"}}}\n'
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"totalTokens":%s}}}\n' "$1"
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call"},"_meta":{"totalTokens":%s}}}\n' "$2"
  printf '{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call"},"_meta":{"totalTokens":99999}}}\n'
}
gupdate 1937 31845 >"$G/s1/updates.jsonl"
gupdate 2000 32100 >"$G/s2/updates.jsonl"
gupdate 2000 70000 >"$H/.grok/sessions/%2Fopt%2Fx/s3/updates.jsonl"
for s in s1 s2; do echo sys >"$G/$s/system_prompt.txt"; done
echo sys >"$H/.grok/sessions/%2Fopt%2Fx/s3/system_prompt.txt"
# crow <timestamp> <input> <cache_creation> <cache_read>
crow() {
  printf '{"type":"assistant","timestamp":"%s:00.000Z","message":{"usage":{"input_tokens":%s,"output_tokens":5,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$@"
}
C="$H/.claude/projects/-opt-x-wt-c-101"
{ printf '{"type":"user","message":{"content":"seed"}}\n'; crow "$NOW_ISO" 2 31914 27191; crow "$NOW_ISO" 2 900 90000; } >"$C/a.jsonl"
crow "$NOW_ISO" 2 31000 30000 >"$C/b.jsonl"
crow "$NOW_ISO" 0 0 0 >"$C/zero.jsonl"
crow 2026-01-01T00:00 2 31001 30000 >"$C/old.jsonl"
crow "$NOW_ISO" 2 80000 80000 >"$H/.claude/projects/-opt-x/main.jsonl"

out="$(TOKEN_START_HOMES="$H" TOKEN_START_SINCE="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M)" \
  bash -c 'source "$1/src/bash/run/spl-token-start-size.func.sh"; do_spl_token_start_size' _ "$PROJ_ROOT" 2>&1)"

grep -qP '^grok\tg-301\t\S+\t31845$' <<<"$out" && ! grep -q 1937 <<<"$out" \
  && pass "1. grok: the first tool_call's totalTokens, 31845, not the streamed chunk's 1937" || fail "1. grok first call ($out)"
ctl="$(grep -m1 -o '"totalTokens":[0-9]*' "$G/s1/updates.jsonl")"
[ "$ctl" = '"totalTokens":1937' ] && pass "1. control: the first totalTokens of the file is the partial 1937" || fail "1. control ($ctl)"
grep -qP '^claude\tc-101\t\S+\t59107$' <<<"$out" && ! grep -q 90902 <<<"$out" \
  && pass "2. claude: the first assistant row, 2 + 31914 + 27191 = 59107" || fail "2. claude first call ($out)"
! grep -qE '70000|160002|61003' <<<"$out" || fail "3. an old or main-checkout session reached the rows ($out)"
[ "$(grep -cP '^claude\t' <<<"$out")" = 2 ] && [ "$(grep -cP '^grok\t' <<<"$out")" = 2 ] \
  && pass "3. the old, main-checkout and zero sessions are left out" || fail "3. rows ($out)"
grep -qx 'grok n=2 min=31845 p50=31845 max=32100' <<<"$out" && grep -qx 'claude n=2 min=59107 p50=59107 max=61002' <<<"$out" \
  && pass "4. the summary per vendor" || fail "4. summary ($out)"
out0="$(TOKEN_START_HOMES="$H/none" bash -c 'source "$1/src/bash/run/spl-token-start-size.func.sh"; do_spl_token_start_size' _ "$PROJ_ROOT" 2>&1)"
grep -q 'no lane session in the window' <<<"$out0" && pass "4. an empty home says so" || fail "4. empty home ($out0)"

echo "spl-token-start-size: $fails failure(s)"
[ "$fails" -eq 0 ]
