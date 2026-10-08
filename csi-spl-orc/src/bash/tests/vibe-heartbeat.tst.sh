#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: an m- (mistral, vibe 2.26.0) lane is visible to the watchdog.
#   1. smh_install mistral writes vibe's hooks.toml: the spool-mirror entry
#      plus one spool-heartbeat-* entry per hook point (pre_tool, post_tool,
#      post_agent), idempotent, another hook kept
#   2. the entries run as vibe runs them (`sh -c <command>`, the invocation
#      JSON on stdin, vibe's env): <id>/heartbeat.json in the claude format,
#      harness vibe, nothing on stdout (vibe wants nothing or a JSON object);
#      post_agent is progress (control: a grok Stop is not)
#   3. the watchdog's S1 reads it: a fresh heartbeat is alive, a stale one is
#      stalled; control: the old hooks.toml (the mirror alone) writes no
#      heartbeat, S1 reads "prog=unknown"
#   4. spl_peer_harness_comm matches vibe's comm "Vibe CLI" for a mistral
#      seat and spl_peer_pids finds it; control: the old regex misses it
# Sandbox only: a throwaway spool root, a fake /proc, the clock HOOK_NOW.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
SA="$PROJ_ROOT/src/bash/features/spawn-agents"
SIT="$PROJ_ROOT/src/bash/features/watchdog/situations"
T0=1800000000
ID=m-901
export SPOOL_ROOT="$T/spool"
mkdir -p "$SPOOL_ROOT/$ID/inbox"
iso() { date -u -d "@$1" +%FT%TZ; }

# ---- 1. the hooks.toml entries -------------------------------------------------
HT="$T/vibe/hooks.toml"; mkdir -p "${HT%/*}"
printf '[[hooks]]\nname = "hook-ping"\ntype = "post_tool"\ncommand = "true"\n' >"$HT"
# The mirror script is absent on purpose: its entry is a no-op here.
for _ in 1 2; do
  env SPOOL_AGENT_VIBE_HOOKS="$HT" bash -c 'source "$1"; smh_install mistral m-901 "$2"' _ \
    "$SA/lib/spool-mirror-hooks.inc.sh" "$SA/scripts/no-such-mirror.py" || fail "1. smh_install rc $?"
done
names="$(python3 -c 'import sys, tomllib; print(" ".join(h["name"] + ":" + h["type"] for h in tomllib.load(open(sys.argv[1], "rb"))["hooks"]))' "$HT")"
[[ "$names" == "hook-ping:post_tool spool-mirror:post_agent spool-heartbeat-pre-tool:pre_tool spool-heartbeat-post-tool:post_tool spool-heartbeat-post-agent:post_agent" ]] &&
  pass "1. hooks.toml: the mirror + 3 heartbeat entries once (merged twice), hook-ping kept" || fail "1. hooks.toml: $names"
grep -q "SPOOL_HARNESS=vibe exec bash $SA/scripts/spool-agent-hook.sh Stop" "$HT" &&
  pass "1. the post_agent heartbeat runs the claude hook script as Stop" || fail "1. command: $(cat "$HT")"

# vibe_run <hooks.toml> <type> <epoch> [json extra]: every entry of <type>, as
# vibe's HookExecutor runs it; stdout collected in $T/out.
vibe_run() {
  local cmd
  python3 -c 'import sys, tomllib
for h in tomllib.load(open(sys.argv[1], "rb"))["hooks"]:
    if h["type"] == sys.argv[2] and h["name"] != "hook-ping": print(h["command"])' "$1" "$2" |
  while IFS= read -r cmd; do
    printf '{"hook_event_name":"%s","session_id":"s-v1","transcript_path":"","cwd":"/"%s}' "$2" "${4:-}" |
      env -u SPOOL_HARNESS HANDOFF_COMPOSE_CMD=: SPOOL_AGENT_ID="$ID" HOOK_NOW="$3" HOOK_PID=4242 sh -c "$cmd" >>"$T/out"
  done
}
tool='"tool_name":"bash","tool_call_id":"c1","tool_input":{"command":"make"}'
turn() {  # <hooks.toml> <epoch of the post_agent>: one tool call then the turn's end
  vibe_run "$1" pre_tool $(($2 - 20)) ",$tool"
  vibe_run "$1" post_tool $(($2 - 10)) ",$tool,\"tool_status\":\"success\",\"tool_output\":{\"r\":\"$2\"},\"tool_output_text\":\"ok\",\"duration_ms\":1.0"
  vibe_run "$1" post_agent "$2"
}

# ---- 2. the heartbeat ------------------------------------------------------------
HB="$SPOOL_ROOT/$ID/heartbeat.json"
: >"$T/out"
vibe_run "$HT" pre_tool $((T0 - 30)) ",$tool"
jq -e --arg ts "$(iso $((T0 - 30)))" '.v == 1 and .id == "m-901" and .harness == "vibe" and .pid == 4242
  and .state == "in-tool" and .tool == "bash" and .tool_since == $ts and .progress_ts == $ts' "$HB" >/dev/null 2>&1 &&
  pass "2. pre_tool: heartbeat.json in-tool, harness vibe, the claude fields" || fail "2. pre_tool: $(cat "$HB" 2>&1)"
vibe_run "$HT" post_tool $((T0 - 20)) ",$tool,\"tool_status\":\"success\",\"tool_output\":{\"r\":1},\"tool_output_text\":\"ok\",\"duration_ms\":1.0"
r1="$(jq -r '.calls[-1].res' "$HB" 2>/dev/null)"
vibe_run "$HT" post_tool $((T0 - 15)) ",$tool,\"tool_status\":\"success\",\"tool_output\":{\"r\":2},\"tool_output_text\":\"ok\",\"duration_ms\":1.0"
jq -e '.state == "working" and .tool == null and (.calls | length) == 2' "$HB" >/dev/null 2>&1 &&
  [[ -n "$r1" && "$r1" != "$(jq -r '.calls[-1].res' "$HB")" ]] &&
  pass "2. post_tool: working, the call recorded, res hashes vibe's tool_output" || fail "2. post_tool: $(cat "$HB" 2>&1)"
vibe_run "$HT" post_agent $((T0 - 10))
jq -e --arg ts "$(iso $((T0 - 10)))" '.state == "idle" and .progress_ts == $ts and .event == "Stop"' "$HB" >/dev/null 2>&1 &&
  pass "2. post_agent: idle, and progress (vibe fires it after a completed turn only)" || fail "2. post_agent: $(cat "$HB" 2>&1)"
[[ ! -s "$T/out" ]] && pass "2. no hook printed anything (vibe: nothing or a JSON object)" || fail "2. stdout: $(cat "$T/out")"
printf '{}' | env SPOOL_AGENT_ID="$ID" SPOOL_HARNESS=grok HOOK_NOW=$((T0 - 5)) bash "$SA/scripts/spool-agent-hook.sh" Stop
[[ "$(jq -r .progress_ts "$HB")" == "$(iso $((T0 - 10)))" ]] &&
  pass "2. control: a grok Stop at T0-5 does not move progress_ts" || fail "2. grok Stop moved it: $(cat "$HB")"

# ---- 3. the watchdog reads it ----------------------------------------------------
# s1 <name>: S1 on a context dir holding the heartbeat (if any) and one job
# that arrived at T0-300 (what the watchdog copies there each tick).
s1() {
  local C="$T/ctx/$1"; rm -rf "$C"; mkdir -p "$C"; echo "$T0" >"$C/now"
  [[ -f "$HB" ]] && cp "$HB" "$C/heartbeat"
  echo "$((T0 - 300)) j1.json task c-001" >"$C/inbox"
  WD_CTX="$C" bash "$SIT/s1.sh" "$ID" 4242 - 2>&1
}
rm -f "$HB"; turn "$HT" $((T0 - 10))
out="$(s1 fresh)"
[[ -z "$out" ]] && pass "3. fresh m- heartbeat (progress 10 s ago): alive, no S1 hit" || fail "3. fresh: '$out'"
rm -f "$HB"; turn "$HT" $((T0 - 600))
out="$(s1 stale)"
[[ "$out" == "HIT S1 age=300 inbox j1.json task c-001 unread 300s, last progress 600s ago" ]] &&
  pass "3. stale m- heartbeat (progress 600 s ago): S1 stalled, progress known" || fail "3. stale: '$out'"
# The old hooks.toml: the mirror alone (what the merge wrote before).
OLD="$T/vibe/old.toml"
python3 -c 'import re, sys
t = open(sys.argv[1]).read()
print("".join(b for b in re.split(r"(?m)^(?=\[)", t) if "spool-heartbeat-" not in b))' "$HT" >"$OLD"
rm -f "$HB"; turn "$OLD" $((T0 - 10))
out="$(s1 old)"
[[ ! -e "$HB" && "$out" == "HIT S1 age=300 prog=unknown inbox j1.json task c-001 unread 300s, last progress unknown" ]] &&
  pass "3. control: the old hooks.toml writes no heartbeat, S1 reads prog=unknown" || fail "3. old: '$out' $(ls "$SPOOL_ROOT/$ID")"

# ---- 4. spl_peer_harness_comm ----------------------------------------------------
P="$T/proc"; mkdir -p "$P/2700" "$P/2800"
echo "Vibe CLI" >"$P/2700/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=m-901\0' >"$P/2700/environ"
echo "python3" >"$P/2800/comm"; printf 'SPOOL_AGENT_ID=m-901\0' >"$P/2800/environ"
peer() {  # <snippet>: spl-peer-restart.func.sh sourced, PEER_HARNESS=mistral
  env LEASE_PROC_ROOT="$P" PEER_HARNESS=mistral PROJ_PATH="$PROJ_ROOT" bash -c '
    do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-peer-restart.func.sh"; '"$1"
}
[[ "$(peer 'spl_peer_harness_comm "Vibe CLI" && echo y')" == y ]] &&
  pass "4. spl_peer_harness_comm: 'Vibe CLI' is a mistral seat's harness" || fail "4. Vibe CLI not matched"
[[ "$(peer 'PEER_HARNESS=grok; spl_peer_harness_comm "Vibe CLI" || echo n')" == n ]] &&
  pass "4. control: 'Vibe CLI' is not a grok seat's harness" || fail "4. grok matched Vibe CLI"
[[ "$(peer 'spl_peer_pids m-901' | tr '\n' ' ')" == "2700 " ]] &&
  pass "4. spl_peer_pids m-901 finds the Vibe CLI process (not the python3 one)" || fail "4. pids: $(peer 'spl_peer_pids m-901')"
old='spl_peer_harness_comm() { [[ "$1" == claude || "$1" == node || "$1" == bun || ( -n "${PEER_HARNESS:-}" && "$1" == "$PEER_HARNESS" ) ]]; }'
[[ -z "$(peer "$old; spl_peer_pids m-901")" ]] &&
  pass "4. control: the old regex misses 'Vibe CLI' (no pid)" || fail "4. old regex found it"

echo "vibe-heartbeat: $fails failure(s)"
[[ $fails -eq 0 ]]
