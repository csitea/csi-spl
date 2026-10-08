#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_standby_bench (spec 070 L1) drives stub agents only, no model
#          call: a claude stub speaking stream-json and a grok stub speaking ACP.
#   1. dry run: no agent is started
#   2. refusals: ENV=prd, BENCH_N < 20, a bad effort / model / DRY_RUN, the
#      wrong user
#   3. both vendors: n=20 rows each, p50 / p95 per model, verdict yes, the
#      headless flags (no tools, replaced system prompt), every agent stopped
#   4. a slow first token against a tight budget: verdict no, Q11 raised
#   5. grok not logged in: skipped, claude alone
#   6. a tool request in the call response: refused, counted, verdict no
#   7. a hung agent: the turn times out, FAIL, the agent is stopped; a
#      SIGTERM to the bench mid-turn stops its agent too
#   8. CONTROL: a live stub IS seen by the liveness check
#   9. mistral (spec 110 T013b): a vibe CLI on PATH is named as mistral and
#      skipped (no headless adapter), never started; BENCH_MODELS=mistral:x
#      is refused; control: no vibe, no such line
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/stub"

# claude stub: print mode, one stream-json user message per stdin line
cat >"$T/stub/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]
if "--version" in a: print("9.9.9 (stub claude)"); sys.exit(0)
open(os.environ["STUB_LOG"], "a").write("claude " + " ".join(repr(x) for x in a) + "\n")
open(os.environ["STUB_PIDS"], "a").write(f"{os.getpid()}\n")
model = a[a.index("--model") + 1]
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
turn = 0
for line in sys.stdin:
    turn += 1
    if os.environ.get("STUB_HANG") == "1" and turn > 1: time.sleep(600)
    out({"type": "system", "subtype": "init"})
    out({"type": "stream_event", "event": {"type": "message_start", "message": {"model": "stub-" + model}}})
    time.sleep(float(os.environ.get("STUB_DELAY", "0")))
    for w in ("The ", "export ", "failed."):
        out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": w}}})
    out({"type": "stream_event", "event": {"type": "message_delta", "usage": {"output_tokens": 42}}})
    out({"type": "result", "subtype": "success", "usage": {"output_tokens": 42}})
EOF

# grok stub: `grok models`, `grok --version`, and `grok agent ... stdio` (ACP)
cat >"$T/stub/grok" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]
if "--version" in a: print("grok 9.9.9 (stub)"); sys.exit(0)
if a[:1] == ["models"]:
    if os.environ.get("STUB_GROK_LOGIN", "1") == "1":  # the listing comes later, as the real CLI's
        print("You are logged in with stub.", flush=True); time.sleep(0.3); print("Available models:\n  - grok-fast"); sys.exit(0)
    print("You are logged in with stub." if os.environ.get("STUB_GROK_LOGIN", "1") == "1" else "Not signed in."); sys.exit(0)
open(os.environ["STUB_LOG"], "a").write("grok " + " ".join(a) + "\n")
open(os.environ["STUB_PIDS"], "a").write(f"{os.getpid()}\n")
model = a[a.index("-m") + 1]
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def upd(u): out({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": u}})
for line in sys.stdin:
    o = json.loads(line)
    if "method" not in o:
        open(os.environ["STUB_LOG"], "a").write("grok-permission-answer " + json.dumps(o["result"]) + "\n"); continue
    m, rid = o["method"], o["id"]
    if m == "initialize": out({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1}})
    elif m == "session/new": out({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s1"}})
    elif m == "session/set_config_option":
        if o["params"]["configId"] == "model": model = o["params"]["value"]
        out({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif m == "session/prompt":
        out({"jsonrpc": "2.0", "id": "skills-reload", "result": {}})
        if os.environ.get("STUB_GROK_TOOL") == "1" and "Warm-up" not in json.dumps(o):
            upd({"sessionUpdate": "tool_call", "toolCallId": "t1"})
            out({"jsonrpc": "2.0", "id": 900 + rid, "method": "session/request_permission", "params": {}})
        time.sleep(float(os.environ.get("STUB_DELAY", "0")))
        upd({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hmm"}})
        for w in ("Disk ", "full."):
            upd({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": w}})
        out({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn", "_meta": {"modelId": model, "outputTokens": 30, "reasoningTokens": 5}}})
EOF
chmod +x "$T/stub/claude" "$T/stub/grok"

me=$(id -un)
bench() {  # bench <VAR=value>... - the action on a PATH that holds only the stubs + the system bins
  SNIPPET=do_spl_standby_bench in_orc PATH="$T/stub:/usr/bin:/bin" STUB_PIDS="$T/pids" SPOOL_AGENT_USER="$me" \
    BENCH_REPORT="$T/report.md" BENCH_MODELS="claude:haiku grok:grok-fast" "$@" 2>&1
}
alive() {  # prints the stub pids still running
  local p
  [[ -s "$T/pids" ]] || return 0
  while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done <"$T/pids"
}
fresh() { : >"$T/calls.log"; : >"$T/pids"; rm -f "$T/report.md"; rm -rf "$T/state"; }

# --- 1. dry run --------------------------------------------------------------------------
fresh
out=$(bench); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was started" <<<"$out" && [[ ! -s "$T/calls.log" ]] && [[ ! -e "$T/report.md" ]] \
  && pass "dry run: no agent started, no report" || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "claude:haiku grok:grok-fast" <<<"$out" && pass "dry run names the plan" || fail "dry run plan: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "ENV=prd" "BENCH_THINKING=maybe" "BENCH_N=19" "BENCH_N=x" "BENCH_EFFORT=max" "BENCH_MODELS=qwen:x" "BENCH_MODELS=mistral:x" "BENCH_MODELS=claude:" \
  "DRY_RUN=2" "BENCH_BUDGET_S=fast" "BENCH_CALL_TIMEOUT=0" "SPOOL_AGENT_USER=someone-else"; do
  fresh
  if bench "$bad" >"$T/o"; then fail "accepts $bad"; else
    [[ ! -s "$T/calls.log" ]] && pass "refuses $bad, no agent started" || fail "refuses $bad but started: $(cat "$T/calls.log")"
  fi
done

# --- 3. both vendors, live on the stubs -------------------------------------------------
fresh
out=$(bench DRY_RUN=0); rc=$?
[[ $rc -eq 0 ]] && grep -q "OK the bench ran" <<<"$out" && pass "live run: rc 0" || fail "live run: rc=$rc out=$out"
rows=$(cat "$T"/state/dev/standby-bench/*.jsonl 2>/dev/null | wc -l)
[[ $rows -eq 40 ]] && pass "40 rows: 20 per model" || fail "rows=$rows"
grep -qE '^\| claude \| haiku \(stub-haiku\) \| 20 \| 0 \|' "$T/report.md" && grep -qE '^\| grok \| grok-fast \(grok-fast\) \| 20 \| 0 \|' "$T/report.md" \
  && pass "report: one row per model, n=20, no errors, the reported model" || fail "report rows: $(cat "$T/report.md")"
grep -qE '^\| claude \| haiku \| [0-9.]+ \| \*\*yes\*\*' "$T/report.md" && grep -qE '^\| grok \| grok-fast \| [0-9.]+ \| \*\*yes\*\*' "$T/report.md" \
  && pass "verdict per vendor: yes" || fail "verdict: $(grep -A6 'Verdict' "$T/report.md")"
grep -q 'Q11\*\*: not raised' "$T/report.md" && grep -q '| claude CLI | 9.9.9 (stub claude) |' "$T/report.md" && grep -q '| grok CLI | grok 9.9.9 (stub) |' "$T/report.md" \
  && pass "report: Q11 not raised, CLI versions" || fail "report Q11/versions: $(cat "$T/report.md")"
grep -qE '^\| tree \| `([0-9a-f]{40}|unknown)' "$T/report.md" && pass "report names the tree" || fail "tree: $(grep tree "$T/report.md")"
grep -q "claude '-p' '--input-format' 'stream-json'" "$T/calls.log" && grep -q "'--tools' ''" "$T/calls.log" \
  && grep -q "'--system-prompt'" "$T/calls.log" && grep -q "'--setting-sources' ''" "$T/calls.log" \
  && grep -q "'--settings' '{\"alwaysThinkingEnabled\": false}'" "$T/calls.log" \
  && pass "claude: headless, no tools, no settings, thinking off, replaced system prompt" || fail "claude argv: $(cat "$T/calls.log")"
grep -q "grok agent --no-leader -m grok-fast --reasoning-effort low stdio" "$T/calls.log" && pass "grok: ACP stdio, effort low" \
  || fail "grok argv: $(cat "$T/calls.log")"
[[ $(wc -l <"$T/pids") -eq 2 && -z "$(alive)" ]] && pass "both agents started, both stopped" || fail "pids=$(cat "$T/pids") alive=$(alive)"

# --- 4. slow first token, tight budget -> no ---------------------------------------------
fresh
out=$(bench DRY_RUN=0 STUB_DELAY=0.03 BENCH_BUDGET_S=0.01 BENCH_MODELS="claude:haiku"); rc=$?
[[ $rc -eq 0 ]] && grep -qE '^\| claude \| haiku \| 0\.0[3-9]|^\| claude \| haiku \| 0\.[1-9]' "$T/report.md" && grep -q '\*\*no\*\*' "$T/report.md" \
  && grep -q 'Q11\*\*: raised for claude' "$T/report.md" && pass "slow: verdict no, Q11 raised" || fail "slow: rc=$rc $(cat "$T/report.md" 2>/dev/null) $out"

# --- 5. grok not logged in ---------------------------------------------------------------
fresh
out=$(bench DRY_RUN=0 STUB_GROK_LOGIN=0); rc=$?
[[ $rc -eq 0 ]] && grep -q "skip grok: CLI present, not logged in" <<<"$out" && ! grep -q '^| grok |' "$T/report.md" \
  && ! grep -q '^grok ' "$T/calls.log" && pass "grok not logged in: skipped, claude alone" || fail "no login: rc=$rc $out"

# --- 6. a tool request is refused and counted ---------------------------------------------
fresh
out=$(bench DRY_RUN=0 STUB_GROK_TOOL=1 BENCH_MODELS="grok:grok-fast"); rc=$?
grep -q 'grok-permission-answer {"outcome": {"outcome": "cancelled"}}' "$T/calls.log" && grep -qE '^\| grok \| grok-fast \(grok-fast\) \| 20 \| 0 \|.*\| 40 \|' "$T/report.md" \
  && grep -qE '^\| grok \| grok-fast \| [0-9.]+ \| \*\*no\*\*' "$T/report.md" && pass "tool request: cancelled, counted (40), verdict no" \
  || fail "tool: rc=$rc $(cat "$T/report.md" 2>/dev/null) $(cat "$T/calls.log")"

# --- 7. a hung agent ---------------------------------------------------------------------
fresh
out=$(bench DRY_RUN=0 STUB_HANG=1 BENCH_CALL_TIMEOUT=1 BENCH_MODELS="claude:haiku"); rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL a model has fewer than 20 good calls" <<<"$out" && [[ -s "$T/pids" && -z "$(alive)" ]] \
  && pass "hung agent: FAIL, the agent is stopped" || fail "hang: rc=$rc alive=$(alive) out=$out"

# --- 7b. the bench is stopped (SIGTERM) mid-turn: it still stops its agent -----------------
fresh
bench DRY_RUN=0 STUB_HANG=1 BENCH_CALL_TIMEOUT=60 BENCH_MODELS="claude:haiku" >"$T/o" &
bg=$!
for _ in $(seq 1 50); do [[ -s "$T/pids" ]] && break; sleep 0.2; done
sleep 0.5
drv=$(ps -o ppid= -p "$(head -1 "$T/pids")" | tr -d ' ')
[[ -n "$drv" ]] && kill -TERM "$drv"
wait "$bg" 2>/dev/null
[[ -n "$drv" && -s "$T/pids" && -z "$(alive)" ]] && pass "SIGTERM to the bench: its agent is stopped too" \
  || fail "SIGTERM: drv=$drv alive=$(alive) out=$(cat "$T/o")"

# --- 8. CONTROL: the liveness check sees a live stub -------------------------------------
fresh
sleep 30 | STUB_LOG="$T/calls.log" STUB_PIDS="$T/pids" "$T/stub/claude" --model x >/dev/null 2>&1 &
ctl=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/pids" ]] && break; sleep 0.2; done
[[ -n "$(alive)" ]] && pass "CONTROL: a live stub is seen" || fail "CONTROL: liveness check blind"
kill "$ctl" 2>/dev/null; wait "$ctl" 2>/dev/null

# --- 9. mistral: vibe on PATH is skipped by its kind, never started -------------------
fresh
out=$(bench BENCH_MODELS="claude:haiku"); rc=$?
grep -q "mistral" <<<"$out" && fail "CONTROL no vibe on PATH: mistral named: $out" || pass "CONTROL no vibe on PATH: no mistral line"
printf '%s\n' '#!/bin/sh' 'echo "vibe $*" >>"$STUB_LOG"' >"$T/stub/vibe"; chmod +x "$T/stub/vibe"
fresh
out=$(bench BENCH_MODELS="claude:haiku" STUB_LOG="$T/calls.log"); rc=$?
[[ $rc -eq 0 ]] && grep -q "skip mistral (vibe): CLI present, no headless adapter in L1" <<<"$out" && ! grep -q '^vibe' "$T/calls.log" \
  && pass "mistral: vibe on PATH is skipped by its kind, never started" || fail "mistral skip: rc=$rc $out $(cat "$T/calls.log")"
rm -f "$T/stub/vibe"

echo "=== $([[ $fails -eq 0 ]] && echo 'all spl-standby-bench.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
