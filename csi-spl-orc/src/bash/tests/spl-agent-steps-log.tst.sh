#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spl-agent-steps-log.tst.sh - do_spl_agent_steps_log (spec 160 section 3.9,
# SPL-4693) on a fixture claude session jsonl:
#   1. one line per step: prompt, tool + short arg, result ok|error, text;
#      thinking, sidechain and meta records give none; the log is 0644
#   2. a re-run appends only the new steps (the byte offset); a half-written
#      last jsonl line waits for its newline; a newer session starts over
#      after one `session` line
#   3. redaction: a token in a prompt or a command is masked; a tool
#      result's content never reaches the log
#   4. refusals: no session file (rc 3), an unreadable one (rc 4), a bad or
#      missing AGENT_ID (rc 1)
#   5. the session is the newest top-level jsonl of the agent's worktree
#      slug (-wt-<id>); a subagent's jsonl and another id's slug are not
#   6. the id list: box.env AGENT_STEPS_LOG_AGENTS wins over the cnf; the
#      shipped cnf names none
#   7. the cron wrapper: refuses a worktree; no id = exit 0, nothing logged;
#      the manifest row runs it every minute
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v python3 >/dev/null && command -v yq >/dev/null || { echo "FAIL: python3 and yq are required"; exit 1; }

FUNC="$PROJ_ROOT/src/bash/run/spl-agent-steps-log.func.sh"
[[ -f "$FUNC" ]] || { echo "FAIL: no action at $FUNC"; echo "FAIL spl-agent-steps-log: 1 failed"; exit 1; }
# a token assembled so the secret scanners read no literal one
TOK="ghp_""$(printf 'a%.0s' {1..36})"

# rec <type> <ts> <content json> [extra json]: one jsonl record
rec() {
  jq -cn --arg t "$1" --arg ts "$2" --argjson c "$3" --argjson x "${4:-{\}}" \
    '{type: $t, timestamp: $ts, message: {role: $t, content: $c}} + $x'
}

fixture() {
  rec user 2026-11-03T09:00:00.100Z '"fix the export, my key is '"$TOK"'"'
  rec user 2026-11-03T09:00:00.200Z '"<command-name>/meta</command-name>"' '{"isMeta":true}'
  rec assistant 2026-11-03T09:00:01.000Z '[{"type":"thinking","thinking":"THOUGHT-NEVER-SHOWN"}]'
  rec assistant 2026-11-03T09:00:02.000Z '[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"/srv/data/report.xlsx"}}]'
  rec user 2026-11-03T09:00:02.500Z '[{"type":"tool_result","tool_use_id":"tu1","content":"FILE-CONTENT-NEVER-SHOWN"}]'
  rec assistant 2026-11-03T09:00:03.000Z '[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"curl -H \"Authorization: Bearer '"$TOK"'\" x\nsecond line"}}]'
  rec user 2026-11-03T09:00:04.000Z '[{"type":"tool_result","tool_use_id":"tu2","is_error":true,"content":"boom"}]'
  rec assistant 2026-11-03T09:00:05.000Z '[{"type":"text","text":"Done: the export has 12 rows."}]'
  rec assistant 2026-11-03T09:00:06.000Z '[{"type":"text","text":"SIDECHAIN-NEVER-SHOWN"}]' '{"isSidechain":true}'
  echo 'not json at all'
}

act() { env SPOOL_TEST=1 AGENT_STEPS_LOG_USER="$(id -un)" "$@" bash -c 'source "$1"; do_spl_agent_steps_log' _ "$FUNC"; }

# --- 1. the lines --------------------------------------------------------------
P="$T/projects"; L="$T/logs"
mkdir -p "$P/-opt-x-wt-c-141" "$P/-opt-x-wt-c-1410"
S="$P/-opt-x-wt-c-141/s1.jsonl"
fixture >"$S"
out="$(act AGENT_ID=c-141 AGENT_STEPS_LOG_PROJECTS="$P" AGENT_STEPS_LOG_DIR="$L" 2>&1)"; rc=$?
got="$(cut -d' ' -f2- "$L/c-141.steps.log" 2>/dev/null | sed 's/  */ /g')"
want="session s1.jsonl
prompt fix the export, my key is <redacted:github-token>
tool Read: /srv/data/report.xlsx
result ok Read
tool Bash: curl -H \"Authorization: [redacted]\" x
result error Bash
text Done: the export has 12 rows."
want="${want//\\\"/\"}"
[[ "$rc" == 0 && "$got" == "$want" ]] && pass "1. one line per step, kinds and short args" ||
  fail "1. lines (rc $rc: $out)"$'\n'"got:"$'\n'"$got"$'\n'"want:"$'\n'"$want"
[[ "$(sed -n 2p "$L/c-141.steps.log" | cut -d' ' -f1)" == 2026-11-03T09:00:00Z ]] &&
  pass "1. ...each stamped with its UTC second" || fail "1. stamp: $(sed -n 2p "$L/c-141.steps.log")"
[[ "$(stat -c %a "$L/c-141.steps.log")" == 644 ]] && pass "1. ...and the log is 0644" ||
  fail "1. mode $(stat -c %a "$L/c-141.steps.log")"

# --- 3. redaction --------------------------------------------------------------
bad="$(grep -oE "${TOK}|FILE-CONTENT|THOUGHT-NEVER|SIDECHAIN-NEVER|meta</command|not json|second line" "$L/c-141.steps.log" | sort -u | tr '\n' ' ')"
[[ -z "$bad" ]] && pass "3. no token, no tool result content, no thinking or sidechain text" || fail "3. leaked: $bad"

# --- 2. offset resume ------------------------------------------------------------
n1="$(wc -l <"$L/c-141.steps.log")"
act AGENT_ID=c-141 AGENT_STEPS_LOG_PROJECTS="$P" AGENT_STEPS_LOG_DIR="$L" >/dev/null 2>&1
[[ "$(wc -l <"$L/c-141.steps.log")" == "$n1" ]] && pass "2. a re-run with nothing new appends nothing" ||
  fail "2. re-run grew to $(wc -l <"$L/c-141.steps.log") from $n1"
rec assistant 2026-11-03T09:01:00.000Z '[{"type":"tool_use","id":"tu3","name":"Grep","input":{"pattern":"total"}}]' >>"$S"
half="$(rec assistant 2026-11-03T09:02:00.000Z '[{"type":"text","text":"HALF-LINE"}]')"
printf '%s' "${half:0:40}" >>"$S"
act AGENT_ID=c-141 AGENT_STEPS_LOG_PROJECTS="$P" AGENT_STEPS_LOG_DIR="$L" >/dev/null 2>&1
new="$(tail -n +$((n1 + 1)) "$L/c-141.steps.log" | cut -d' ' -f2- | sed 's/  */ /g')"
[[ "$new" == "tool Grep: total" ]] && pass "2. ...a new step appends one line; a half-written jsonl line waits" ||
  fail "2. new: '$new'"
printf '%s\n' "${half:40}" >>"$S"
act AGENT_ID=c-141 AGENT_STEPS_LOG_PROJECTS="$P" AGENT_STEPS_LOG_DIR="$L" >/dev/null 2>&1
[[ "$(tail -n 1 "$L/c-141.steps.log" | cut -d' ' -f2- | sed 's/  */ /g')" == "text HALF-LINE" ]] &&
  pass "2. ...and is read once its newline is there" || fail "2. completed: $(tail -n 1 "$L/c-141.steps.log")"
sleep 1.1
rec user 2026-11-03T10:00:00.000Z '"second session"' >"$P/-opt-x-wt-c-141/s2.jsonl"
act AGENT_ID=c-141 AGENT_STEPS_LOG_PROJECTS="$P" AGENT_STEPS_LOG_DIR="$L" >/dev/null 2>&1
[[ "$(tail -n 2 "$L/c-141.steps.log" | cut -d' ' -f2- | sed 's/  */ /g' | tr '\n' '|')" == "session s2.jsonl|prompt second session|" ]] &&
  pass "2. a newer session starts over after one session line" || fail "2. new session: $(tail -n 2 "$L/c-141.steps.log")"

# --- 5. the session lookup -------------------------------------------------------
mkdir -p "$P/-opt-x-wt-c-141/s2/subagents"
sleep 1.1
rec user 2026-11-03T10:00:00.000Z '"sub"' >"$P/-opt-x-wt-c-141/s2/subagents/a.jsonl"
rec user 2026-11-03T10:00:00.000Z '"other id"' >"$P/-opt-x-wt-c-1410/o.jsonl"
s="$(env SPOOL_TEST=1 AGENT_STEPS_LOG_PROJECTS="$P" bash -c 'source "$1"; spl_agent_steps_log_session "$(id -un)" c-141' _ "$FUNC")"
[[ "$s" == "$P/-opt-x-wt-c-141/s2.jsonl" ]] && pass "5. the newest top-level jsonl of -wt-c-141; not a subagent's, not c-1410's" ||
  fail "5. session: '$s'"

# --- 4. refusals -----------------------------------------------------------------
out="$(act AGENT_ID=c-142 AGENT_STEPS_LOG_PROJECTS="$P" AGENT_STEPS_LOG_DIR="$L" 2>&1)"; rc=$?
[[ "$rc" == 3 && "$out" == *"no claude session jsonl"* && ! -e "$L/c-142.steps.log" ]] &&
  pass "4. an agent with no session: rc 3, no log" || fail "4. no session (rc $rc: $out)"
out="$(act AGENT_ID=c-141 AGENT_STEPS_LOG_SESSION="$T/nope.jsonl" AGENT_STEPS_LOG_DIR="$L" 2>&1)"; rc=$?
[[ "$rc" == 3 && "$out" == *"no session file"* ]] && pass "4. a missing session file: rc 3" || fail "4. missing (rc $rc: $out)"
if [[ "$(id -u)" != 0 ]]; then
  cp "$S" "$T/locked.jsonl"; chmod 000 "$T/locked.jsonl"
  out="$(act AGENT_ID=c-143 AGENT_STEPS_LOG_SESSION="$T/locked.jsonl" AGENT_STEPS_LOG_DIR="$L" 2>&1)"; rc=$?
  [[ "$rc" == 4 && "$out" == *"not readable"* && ! -s "$L/c-143.steps.log" ]] &&
    pass "4. an unreadable session file: rc 4, nothing written" || fail "4. unreadable (rc $rc: $out)"
else
  echo "SKIP 4. unreadable: root reads a 000 file"
fi
for id in "" "c-14" "x-141" "c-141;id"; do
  out="$(act AGENT_ID="$id" AGENT_STEPS_LOG_DIR="$L" 2>&1)"; rc=$?
  [[ "$rc" == 1 && "$out" == FATAL* ]] || { fail "4. AGENT_ID='$id' (rc $rc: $out)"; continue; }
done
pass "4. a missing or malformed AGENT_ID: rc 1"

# --- 6. the id list --------------------------------------------------------------
printf 'env:\n  box:\n    agent_steps_log:\n      agents: [c-001, c-002]\n' >"$T/cnf.yaml"
ids() { env SPOOL_TEST=1 "$@" bash -c 'source "$1"; spl_agent_steps_log_ids "$2"' _ "$FUNC" "$T/cnf.yaml"; }
printf 'SPOOL_AGENT_USER=x\nAGENT_STEPS_LOG_AGENTS="c-141"\n' >"$T/box.env"
[[ "$(ids SPOOL_BOX_ENV="$T/box.env")" == c-141 && "$(ids SPOOL_BOX_ENV=)" == "c-001 c-002" ]] &&
  pass "6. box.env AGENT_STEPS_LOG_AGENTS wins over the cnf list" ||
  fail "6. ids: box='$(ids SPOOL_BOX_ENV="$T/box.env")' cnf='$(ids SPOOL_BOX_ENV=)'"
v="$(yq -r '.env.box.agent_steps_log.agents | length' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
[[ "$v" == 0 ]] && pass "6. the shipped cnf names no agent (a box opts in by its box.env)" || fail "6. shipped agents: '$v'"

# --- 7. the cron wrapper ---------------------------------------------------------
W="$T/x-wt/c-1/csi-spl-orc"
mkdir -p "$W/src/bash/scripts" "$W/src/bash/run"
cp "$PROJ_ROOT/src/bash/scripts/agent-steps-log-cron.sh" "$W/src/bash/scripts/"
cp "$FUNC" "$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh" "$W/src/bash/run/"
printf '#!/bin/sh\nexit 0\n' >"$W/run"; chmod +x "$W/run"
out="$(bash "$W/src/bash/scripts/agent-steps-log-cron.sh" 2>&1)"; rc=$?
[[ "$rc" == 2 && "$out" == *"agent worktree"* ]] && pass "7. cron: an agent worktree is refused" || fail "7. worktree (rc $rc: $out)"
out="$(SPOOL_TEST=1 SPOOL_BOX_ENV="" AGENT_STEPS_LOG_ALLOW_WORKTREE=1 bash "$W/src/bash/scripts/agent-steps-log-cron.sh" 2>&1)"; rc=$?
[[ "$rc" == 0 && -z "$out" ]] && pass "7. cron: no id = exit 0, nothing logged" || fail "7. no id (rc $rc: '$out')"
grep -qE '^agent-steps-log +\| \* \* \* \* \* +\| src/bash/scripts/agent-steps-log-cron.sh +\| agent-steps-log/cron.log' \
  "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" && [[ -x "$PROJ_ROOT/src/bash/scripts/agent-steps-log-cron.sh" ]] &&
  pass "7. the manifest row agent-steps-log runs the wrapper every minute" || fail "7. no manifest row or wrapper"

[[ "$fails" == 0 ]] && echo "OK spl-agent-steps-log: all passed" || echo "FAIL spl-agent-steps-log: $fails failed"
((fails == 0))
