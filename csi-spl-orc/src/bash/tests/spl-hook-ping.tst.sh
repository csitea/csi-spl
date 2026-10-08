#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hook_ping with a stub harness (spec 093 T003, FR-011).
#   Each harness has a pass (the stub echoes the injected token) and a
#   control that flips one input so the check fires:
#     - the stub does not echo -> fail no-echo
#     - the tool-call event is skipped -> fail no-injection
#   A direct call also checks the hook JSON, a non-tool event, a broken
#   payload (exit 0, {}), and the SPOOL_TEST refusal of the live spool root.
#   mistral (vibe, spec 110 T013b): a stubbed `post_tool` call records a
#   token and replies hook_specific_output.additional_context; the control,
#   a non-tool event (`post_agent`, and claude's PostToolUse name), prints {}.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

ROOT="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/hook-ping"
export PROJ_PATH="$PROJ_ROOT"
# shellcheck source=../run/spl-hook-ping.func.sh
source "$PROJ_ROOT/src/bash/run/spl-hook-ping.func.sh"

printf '%s\n' '#!/bin/sh' 'cat' >"$T/echo.sh"
printf '%s\n' '#!/bin/sh' 'echo silence' >"$T/mute.sh"
chmod +x "$T/echo.sh" "$T/mute.sh"

run_ping() {
  local rc state="$T/state-$RANDOM" kv
  (
    export HOOK_PING_STATE="$state"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        *=*) kv="$1"; export "${kv%%=*}=${kv#*=}" ;;
        *) break ;;
      esac
      shift
    done
    do_spl_hook_ping
  ) >"$T/out" 2>"$T/err"
  rc=$?
  rm -rf "$state"
  return "$rc"
}

# hook <script> [args] -- stdin is the payload, HOOK_PING_DIR is $1 of the caller via env
hook_out() {
  local dir="$1" script="$2"
  shift 2
  HOOK_PING_DIR="$dir" bash "$ROOT/$script" "$@" >"$dir/out" 2>"$dir/err"
  echo $?
}

# --- grok hook shape, and the control that a non-tool event injects nothing
d="$T/g-post"; mkdir -p "$d"
rc="$(hook_out "$d" grok.sh <<<"$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"run_shell_command"}')")"
tok="$(cat "$d/token")"
[[ "$rc" == 0 ]] && jq -e --arg t "$tok" '.hookSpecificOutput.hookEventName=="PostToolUse" and (.hookSpecificOutput.additionalContext|contains($t))' "$d/out" >/dev/null \
  && pass "grok PostToolUse injects additionalContext" || fail "grok PostToolUse injects additionalContext"
[[ "$tok" =~ ^ping-[0-9a-f]{16}$ ]] && pass "grok token shape" || fail "grok token shape ($tok)"

d="$T/g-pre"; mkdir -p "$d"
rc="$(hook_out "$d" grok.sh <<<"$(printf '%s' '{"hook_event_name":"UserPromptSubmit"}')")"
[[ "$rc" == 0 && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "CONTROL grok UserPromptSubmit injects nothing" || fail "CONTROL grok UserPromptSubmit injects nothing"

d="$T/g-bad"; mkdir -p "$d"
rc="$(hook_out "$d" grok.sh <<<"not-json")"
[[ "$rc" == 0 && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "grok broken payload exits 0 and prints {}" || fail "grok broken payload exits 0 and prints {}"

# --- qwen shape
d="$T/q-post"; mkdir -p "$d"
rc="$(hook_out "$d" qwen.sh <<<"$(printf '%s' '{"hook_event_name":"PostToolUse"}')")"
tok="$(cat "$d/token")"
[[ "$rc" == 0 ]] && jq -e --arg t "$tok" '.decision=="allow" and .hookSpecificOutput.hookEventName=="PostToolUse" and (.hookSpecificOutput.additionalContext|contains($t))' "$d/out" >/dev/null \
  && pass "qwen PostToolUse injects additionalContext" || fail "qwen PostToolUse injects additionalContext"

# --- mistral (vibe): its own event names and a snake-case reply
VIBE_POST='{"hook_event_name":"post_tool","session_id":"s1","transcript_path":"/t","cwd":"/","tool_name":"bash","tool_call_id":"c1","tool_input":{"command":"echo hook-ping-tool"},"tool_status":"success","tool_output":null,"tool_output_text":"hook-ping-tool","tool_error":null,"duration_ms":3.5}'
d="$T/m-post"; mkdir -p "$d"
rc="$(hook_out "$d" mistral.sh <<<"$VIBE_POST")"
tok="$(cat "$d/token" 2>/dev/null)"
[[ "$rc" == 0 && "$tok" =~ ^ping-[0-9a-f]{16}$ ]] && jq -e --arg t "$tok" '.decision=="allow" and (.hook_specific_output.additional_context|contains($t))' "$d/out" >/dev/null \
  && pass "mistral post_tool records a token and injects additional_context" || fail "mistral post_tool records a token ($(cat "$d/out"))"
d="$T/m-agent"; mkdir -p "$d"
rc="$(hook_out "$d" mistral.sh <<<'{"hook_event_name":"post_agent","session_id":"s1","transcript_path":"/t","cwd":"/"}')"
[[ "$rc" == 0 && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "CONTROL mistral post_agent (no tool) prints {}" || fail "CONTROL mistral post_agent prints {}"
d="$T/m-claude"; mkdir -p "$d"
rc="$(hook_out "$d" mistral.sh <<<'{"hook_event_name":"PostToolUse"}')"
[[ "$rc" == 0 && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "CONTROL mistral ignores claude's PostToolUse name" || fail "CONTROL mistral ignores claude's PostToolUse name"
d="$T/m-bad"; mkdir -p "$d"
rc="$(hook_out "$d" mistral.sh <<<"not-json")"
[[ "$rc" == 0 && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "mistral broken payload exits 0 and prints {}" || fail "mistral broken payload exits 0 and prints {}"

# --- agy: marker on PostToolUse, token only on the following PreInvocation
d="$T/a-seq"; mkdir -p "$d"
rc="$(hook_out "$d" agy.sh PostToolUse <<<'{"stepIdx":4}')"
[[ "$rc" == 0 && -f "$d/after-tool" && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "agy PostToolUse marks the tool and prints {}" || fail "agy PostToolUse marks the tool and prints {}"
rc="$(hook_out "$d" agy.sh PreInvocation <<<'{"invocationNum":2,"initialNumSteps":1}')"
tok="$(cat "$d/token")"
[[ "$rc" == 0 && ! -e "$d/after-tool" ]] && jq -e --arg t "$tok" '.injectSteps[0].ephemeralMessage|contains($t)' "$d/out" >/dev/null \
  && pass "agy PreInvocation injects injectSteps" || fail "agy PreInvocation injects injectSteps"

d="$T/a-early"; mkdir -p "$d"
rc="$(hook_out "$d" agy.sh PreInvocation <<<'{"invocationNum":1,"initialNumSteps":0}')"
[[ "$rc" == 0 && ! -e "$d/token" ]] && jq -e '. == {}' "$d/out" >/dev/null \
  && pass "CONTROL agy PreInvocation before a tool injects nothing" || fail "CONTROL agy PreInvocation before a tool injects nothing"

# --- SPOOL_TEST refuses a write into the live spool root
d="$T/live"; mkdir -p "$d"
SPOOL_LIVE_ROOT="$d" HOOK_PING_DIR="$d" bash "$ROOT/grok.sh" <<<"$(printf '%s' '{"hook_event_name":"PostToolUse"}')" >"$T/live.out"
rc=$?
[[ "$rc" == 0 && ! -e "$d/token" ]] && pass "SPOOL_TEST does not write the live spool root" || fail "SPOOL_TEST does not write the live spool root"

# --- the action, stub harness
if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=grok N=1; then
  grep -q 'hook-ping grok 1 pass' "$T/out" && grep -q 'hook-ping grok n=1 pass=1 fail=0' "$T/out" \
    && pass "action grok stub echoes -> pass" || fail "action grok stub echoes -> pass"
else
  fail "action grok stub echoes -> pass (rc)"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/mute.sh" HARNESS=grok N=1; then
  fail "CONTROL grok mute stub should fail"
else
  grep -q 'hook-ping grok 1 fail no-echo' "$T/out" && grep -q 'hook-ping grok n=1 pass=0 fail=1' "$T/out" \
    && pass "CONTROL grok mute stub fires no-echo" || fail "CONTROL grok mute stub fires no-echo"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HOOK_PING_SKIP_TOOL=1 HARNESS=grok N=1; then
  fail "CONTROL grok skip-tool should fail"
else
  grep -q 'hook-ping grok 1 fail no-injection' "$T/out" \
    && pass "CONTROL grok skip-tool fires no-injection" || fail "CONTROL grok skip-tool fires no-injection"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=qwen N=1; then
  grep -q 'hook-ping qwen 1 pass' "$T/out" && pass "action qwen stub echoes -> pass" || fail "action qwen stub echoes -> pass"
else
  fail "action qwen stub echoes -> pass (rc)"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/mute.sh" HARNESS=qwen N=1; then
  fail "CONTROL qwen mute stub should fail"
else
  grep -q 'hook-ping qwen 1 fail no-echo' "$T/out" && pass "CONTROL qwen mute stub fires no-echo" || fail "CONTROL qwen mute stub fires no-echo"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=agy N=1; then
  grep -q 'hook-ping agy 1 pass' "$T/out" && pass "action agy stub echoes -> pass" || fail "action agy stub echoes -> pass"
else
  fail "action agy stub echoes -> pass (rc $(cat "$T/err"))"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HOOK_PING_SKIP_TOOL=1 HARNESS=agy N=1; then
  fail "CONTROL agy skip-tool should fail"
else
  grep -q 'hook-ping agy 1 fail no-injection' "$T/out" \
    && pass "CONTROL agy skip-tool fires no-injection" || fail "CONTROL agy skip-tool fires no-injection"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=mistral N=1; then
  grep -q 'hook-ping mistral 1 pass' "$T/out" && pass "action mistral stub echoes -> pass" || fail "action mistral stub echoes -> pass"
else
  fail "action mistral stub echoes -> pass (rc $(cat "$T/out"))"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/mute.sh" HARNESS=mistral N=1; then
  fail "CONTROL mistral mute stub should fail"
else
  grep -q 'hook-ping mistral 1 fail no-echo' "$T/out" && pass "CONTROL mistral mute stub fires no-echo" || fail "CONTROL mistral mute stub fires no-echo"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HOOK_PING_SKIP_TOOL=1 HARNESS=mistral N=1; then
  fail "CONTROL mistral skip-tool should fail"
else
  grep -q 'hook-ping mistral 1 fail no-injection' "$T/out" \
    && pass "CONTROL mistral skip-tool (post_agent) fires no-injection" || fail "CONTROL mistral skip-tool fires no-injection"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=all N=1; then
  grep -q 'hook-ping mistral n=1 pass=1 fail=0' "$T/out" && pass "HARNESS=all includes mistral" || fail "HARNESS=all includes mistral"
else
  fail "HARNESS=all (rc $(cat "$T/out"))"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=grok N=3; then
  [[ "$(grep -c 'hook-ping grok [123] pass' "$T/out")" == 3 ]] && grep -q 'n=3 pass=3 fail=0' "$T/out" \
    && pass "action grok n=3 all pass" || fail "action grok n=3 all pass"
else
  fail "action grok n=3 all pass (rc)"
fi

if run_ping HARNESS=grok N=1; then
  fail "SPOOL_TEST live should be refused"
else
  grep -q 'REFUSED: SPOOL_TEST=1' "$T/out" && pass "SPOOL_TEST refuses a live ping" || fail "SPOOL_TEST refuses a live ping"
fi

if run_ping HOOK_PING_HARNESS_CMD="$T/echo.sh" HARNESS=nope N=1; then
  fail "bad harness should fail"
else
  grep -q 'bad-harness' "$T/err" && pass "bad harness is refused" || fail "bad harness is refused"
fi

# not-installed is a live trial with no binary on PATH
out="$(PATH=/usr/bin:/bin HOOK_PING_STATE="$T/ni" bash -c 'source "$1"; spl_hook_ping_live_trial grok 1' _ "$PROJ_ROOT/src/bash/run/spl-hook-ping.func.sh")"
rm -rf "$T/ni"
grep -q 'hook-ping grok 1 fail not-installed' <<<"$out" \
  && pass "missing binary is not-installed" || fail "missing binary is not-installed ($out)"
# the mistral kind's binary is vibe: a PATH without vibe is not-installed
out="$(PATH=/usr/bin:/bin HOOK_PING_STATE="$T/ni" bash -c 'source "$1"; spl_hook_ping_live_trial mistral 1' _ "$PROJ_ROOT/src/bash/run/spl-hook-ping.func.sh")"
rm -rf "$T/ni"
grep -q 'hook-ping mistral 1 fail not-installed' <<<"$out" \
  && pass "mistral without vibe on PATH is not-installed" || fail "mistral not-installed ($out)"

# agy PostToolUse is grouped. A flat handler is loaded and never called.
d="$T/agy-doc"
# shellcheck source=../features/spawn-agents/scripts/hook-ping/live-one.sh
source "$ROOT/live-one.sh"
spl_hp_agy_hooks_file "POSTCMD" "PRECMD" "$d/hooks.json"
jq -e '.ping.PostToolUse[0].matcher=="*" and .ping.PostToolUse[0].hooks[0].command=="POSTCMD" and .ping.PreInvocation[0].command=="PRECMD" and (.ping.PreInvocation[0]|has("matcher")|not)' "$d/hooks.json" >/dev/null \
  && pass "agy hooks.json groups PostToolUse" || fail "agy hooks.json groups PostToolUse"

# vibe's hooks.toml: ONE post_tool entry; a quote or backslash in the command
# stays a valid TOML basic string (read back with python's tomllib)
spl_hp_mistral_hooks_file 'env HOOK_PING_DIR=/a\ b /x/mistral.sh "q"' "$d/hooks.toml"
if python3 -c 'import tomllib' 2>/dev/null; then
  got="$(python3 -c 'import sys,tomllib; h=tomllib.load(open(sys.argv[1],"rb"))["hooks"]; print(len(h), h[0]["type"], h[0]["command"])' "$d/hooks.toml" 2>&1)"
  [[ "$got" == '1 post_tool env HOOK_PING_DIR=/a\ b /x/mistral.sh "q"' ]] \
    && pass "mistral hooks.toml is one post_tool entry, command intact" || fail "mistral hooks.toml ($got)"
else
  grep -q '^type = "post_tool"$' "$d/hooks.toml" && pass "mistral hooks.toml has a post_tool entry (no tomllib)" || fail "mistral hooks.toml"
fi
printf '%s\n' 'ping-0123456789abcdef' >"$d/raw.out"
spl_hook_ping_echoed mistral ping-0123456789abcdef "$d/raw.out" \
  && pass "mistral reply is the -p text" || fail "mistral reply is the -p text"
printf '%s\n' 'no token here' >"$d/raw.out"
spl_hook_ping_echoed mistral ping-0123456789abcdef "$d/raw.out" \
  && fail "CONTROL mistral reply without the token must not match" || pass "CONTROL mistral reply without the token does not match"

printf '%s\n' '{"response":"ping-0123456789abcdef"}' >"$d/raw.out"
spl_hook_ping_echoed agy ping-0123456789abcdef "$d/raw.out" \
  && pass "agy reply is the response field" || fail "agy reply is the response field"
printf '%s\n' '{"response":"","usage":"ping-0123456789abcdef"}' >"$d/raw.out"
if spl_hook_ping_echoed agy ping-0123456789abcdef "$d/raw.out"; then
  fail "agy must not match a token outside response"
else
  pass "agy must not match a token outside response"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
