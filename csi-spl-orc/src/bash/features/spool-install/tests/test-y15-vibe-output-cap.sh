#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y15 - the Mistral Vibe output cap (SPL-2217).
#   1. the step installs the hook into a sandbox vibe home whose hooks.toml
#      has the launcher's entries; those are kept, ONE post_tool
#      "spool-output-cap" entry is added; a re-run says current; a dry run
#      writes nothing; no vibe home = skipped
#   2. THE REAL PATH: vibe's own load_hooks_file + the local harness's
#      compile_foreign_hooks run the installed hooks.toml on a bash result.
#      A 50 KB test log reaches the model as <= 4500 chars that still carry
#      the return code, the FAIL line at its tail and the full-log path, and
#      the log file holds every byte; a short result and a read_file pass
#      unchanged (needs vibe's python: VIBE_PYTHON, else the vibe on PATH;
#      without one this part SKIPs and 3..5 still run)
#   3. the hook itself on vibe's payload shape (no vibe needed)
#   4. fail open: a hook that crashes prints nothing, rc 0 (vibe keeps the
#      result); VIBE_OUTPUT_CAP_CHARS=0 turns it off
#   5. the counter vibe-loop-cost.py on a synthetic journal: re-fed tokens
#      and the error loop counted; --cap removes the long result's share
#   6. install.sh calls the step exactly once
# Control: the OLD hooks.toml (before the install) feeds the whole 50 KB log
# to the model through the same real path.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
STEP="$FEAT/steps/y15-vibe-output-cap.sh"
COUNTER="$FEAT/../spawn-agents/scripts/vibe-loop-cost.py"
fails=0 n=0 skips=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { skips=$((skips + 1)); echo "SKIP: $1"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
H="$T/vibe"
mkdir -p "$H"
cat >"$H/hooks.toml" <<'EOF'
[[hooks]]
name = "spool-heartbeat-post-tool"
type = "post_tool"
command = "[ -r /nonexistent/spool-agent-hook.sh ] && SPOOL_HARNESS=vibe exec bash /nonexistent/spool-agent-hook.sh PostToolUse; exit 0"
timeout = 5.0
EOF
cp "$H/hooks.toml" "$T/old-hooks.toml"
inst() { bash -c '. "$1"; spool_install_vibe_output_cap "$2" "$3"' _ "$STEP" "$@" 2>&1; }
export VIBE_OUTPUT_CAP_DIR="$T/logs"

# 1. install
out="$(inst "$H" 1)"
if [ ! -e "$H/spool-output-cap" ] && cmp -s "$H/hooks.toml" "$T/old-hooks.toml" && [[ "$out" == *"would: write the spool-output-cap"* ]]
then pass "dry run: plans, writes nothing"; else fail "dry run: $out"; fi
out="$(inst "$H" 0)"; rc=$?
if [ "$rc" = 0 ] && [ -x "$H/spool-output-cap/vibe-output-cap.py" ]; then pass "installs the hook"; else fail "install rc=$rc: $out"; fi
if [ "$(grep -c '^name = "spool-output-cap"$' "$H/hooks.toml")" = 1 ] && grep -q '^type = "post_tool"$' "$H/hooks.toml" &&
   grep -q '^match = "\*bash"$' "$H/hooks.toml" && ! grep -q '^strict' "$H/hooks.toml" &&
   grep -q '^name = "spool-heartbeat-post-tool"$' "$H/hooks.toml"
then pass "hooks.toml: one non-strict post_tool entry on *bash, the launcher's entry kept"; else fail "hooks.toml: $(cat "$H/hooks.toml")"; fi
out="$(inst "$H" 0)"
if [[ "$out" == *"already current"* ]] && [ "$(grep -c '^name = "spool-output-cap"$' "$H/hooks.toml")" = 1 ]
then pass "re-run: already current"; else fail "re-run: $out"; fi
out="$(inst "$T/none" 0)"
if [[ "$out" == *"skipped (no $T/none)"* ]] && [ ! -e "$T/none" ]; then pass "no vibe home: skipped"; else fail "no home: $out"; fi

# the cases: a 50 KB failing test log, a short ls, a long read_file
python3 - "$T/cases.jsonl" <<'EOF'
import json, sys
big = "".join("line %d of the test log\n" % i for i in range(2000)) + "FAIL: 3/40 failed\n"
with open(sys.argv[1], "w") as f:
    for c in ({"tool": "file_system.bash", "call": "call_big",
               "out": {"command": "bash t.sh", "stdout": big, "stderr": "boom\n", "returncode": 1, "was_truncated": False}},
              {"tool": "file_system.bash", "call": "call_ls",
               "out": {"command": "ls", "stdout": "a\nb\n", "stderr": "", "returncode": 0, "was_truncated": False}},
              {"tool": "file_system.read_file", "call": "call_rf", "out": {"content": "x" * 9000}}):
        f.write(json.dumps(c) + "\n")
EOF

# 2. the real path
VPY="${VIBE_PYTHON:-}"
if [ -z "$VPY" ] && command -v vibe >/dev/null 2>&1; then
  VPY="$(head -1 "$(readlink -f "$(command -v vibe)")" | sed -n 's/^#!//p')"
fi
[ -n "$VPY" ] && [ -x "$VPY" ] && "$VPY" -c 'import mistralai_vibe_local_harness.vibe, vibe.core.hooks.config' 2>/dev/null || VPY=""
cat >"$T/drive.py" <<'EOF'
import asyncio, json, sys
from pathlib import Path
from types import SimpleNamespace
from vibe.core.hooks.config import load_hooks_file
from mistralai_vibe_local_harness.vibe import ForeignHookDefinition, compile_foreign_hooks
from mistralai_vibe_local_harness.protocol import (RustHookToolCall, RustPostToolCallHookInput,
    RustRuntimeBuiltinToolCall, RustToolSuccessResult)

res = load_hooks_file(Path(sys.argv[1]))
if res.issues:
    print("ISSUES %s" % res.issues)
    sys.exit(5)
# the mapping vibe/app_server/_runtime.py _foreign_hook_definitions makes
defs = [ForeignHookDefinition(name=h.name, point=h.type.value, command=h.command, match=h.match,
                              order=i, timeout_s=h.timeout or 60.0, strict=h.strict)
        for i, h in enumerate(res.hooks)]
handlers = compile_foreign_hooks(defs).handlers.post_tool_call
ctx = SimpleNamespace(config=SimpleNamespace(workspace=SimpleNamespace(cwd=Path(sys.argv[2]))),
                      session_id="sess-1", session_root=None, parent_session_id=None, emit_hook_notice=None)

async def run(c):
    result = RustToolSuccessResult(content=[], structured_content=c["out"])
    call = RustHookToolCall(action_id="a1", call_id=c["call"], call=RustRuntimeBuiltinToolCall(name=c["tool"]))
    for h in handlers.values():
        if h.selects(c["tool"]):
            r = await h.run(RustPostToolCallHookInput(tool_call=call, tool_result=result), ctx)
            result = r.output.tool_result
    # what the model sees: non-empty content wins over structured_content
    return "".join(b.text for b in result.content) if result.content else json.dumps(result.structured_content)

for line in open(sys.argv[3]):
    print(json.dumps(asyncio.run(run(json.loads(line)))))
EOF
seen() { "$VPY" "$T/drive.py" "$1" "$T" "$T/cases.jsonl" 2>"$T/drive.err"; }
if [ -n "$VPY" ]; then
  echo "INFO: vibe python $VPY ($("$VPY" -c 'import importlib.metadata as m; print(m.version("mistral-vibe"))' 2>/dev/null))"
  mapfile -t got < <(seen "$H/hooks.toml")
  big="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]))' "${got[0]:-\"\"}")"
  if [ "${#big}" -le 4500 ] && [[ "$big" == "returncode: 1"* ]] && [[ "$big" == *"FAIL: 3/40 failed"* ]] &&
     [[ "$big" == *"$T/logs/sess-1/call_big.log"* ]] && [[ "$big" == *boom* ]]
  then pass "vibe caps the 50 KB log to ${#big} chars: rc, the FAIL tail, stderr and the log path kept"
  else fail "capped result (${#big} chars): ${big:0:300} $(cat "$T/drive.err")"; fi
  if [ "$(grep -c 'line [0-9]* of the test log' "$T/logs/sess-1/call_big.log")" = 2000 ] && grep -q 'FAIL: 3/40' "$T/logs/sess-1/call_big.log"
  then pass "the log file holds the whole output"; else fail "log file: $(ls -la "$T/logs/sess-1" 2>&1)"; fi
  if [[ "${got[1]:-}" == *'\"stdout\": \"a\\nb\\n\"'* ]]; then pass "a short bash result passes unchanged"; else fail "short: ${got[1]:-}"; fi
  if [ "${#got[2]}" -gt 9000 ]; then pass "read_file is not capped"; else fail "read_file: ${#got[2]} chars"; fi
  mapfile -t got < <(seen "$T/old-hooks.toml")
  if [ "${#got[0]}" -gt 50000 ]; then pass "control: the old hooks.toml feeds all ${#got[0]} chars to the model"
  else fail "control: old config fed ${#got[0]} chars"; fi
else
  skip "no vibe python (mistral-vibe) here: the real-path part 2 did not run"
fi

# 3. the hook on vibe's payload shape
HOOK="$H/spool-output-cap/vibe-output-cap.py"
pl() { python3 -c 'import json,sys; c=json.loads(sys.argv[1]); print(json.dumps({"hook_event_name": "post_tool", "session_id": "s/2", "cwd": "/tmp", "tool_name": c["tool"], "tool_call_id": c["call"], "tool_status": "success", "tool_output": c["out"]}))' "$1"; }
mapfile -t cases <"$T/cases.jsonl"
out="$(pl "${cases[0]}" | python3 "$HOOK")"; rc=$?
if [ "$rc" = 0 ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["decision"]=="deny" and "FAIL: 3/40" in d["reason"] and len(d["reason"])<4500' "$out" 2>/dev/null &&
   [ -f "$T/logs/s_2/call_big.log" ]
then pass "hook: deny with the capped text; an unsafe session id becomes a safe dir name"; else fail "hook big: rc=$rc out=${out:0:200}"; fi
out="$(pl "${cases[1]}" | python3 "$HOOK")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "hook: a short result prints nothing, rc 0"; else fail "hook short: rc=$rc out=$out"; fi

# 4. fail open, off switch
out="$(echo 'not json' | python3 "$HOOK")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "fail open: bad input prints nothing, rc 0"; else fail "fail open: rc=$rc out=$out"; fi
out="$(pl "${cases[0]}" | VIBE_OUTPUT_CAP_CHARS=0 python3 "$HOOK")"
if [ -z "$out" ]; then pass "VIBE_OUTPUT_CAP_CHARS=0: off"; else fail "off switch: ${out:0:100}"; fi

# 5. the counter on a synthetic journal: one 30000-char failing result, then
# the same error twice more, 4 completions of one context
S="$T/sess/u1"
mkdir -p "$S/journal"
python3 - "$S" <<'EOF'
import json, sys
d = sys.argv[1]
json.dump({"start_time": "2026-10-16T00:00:00+00:00", "environment": {"working_directory": "/x/m-900"}}, open(d + "/meta.json", "w"))
def bash(stdout):
    return {"role": "tool", "name": "bash", "outcome": "success", "tool_call_id": "c",
            "content": [{"type": "text", "text": json.dumps({"command": "t", "returncode": 1, "stderr": "", "stdout": stdout})}]}
fed = [[], [bash("x" * 30000 + "\n3 failure(s)")], [bash("4 failure(s)")], [bash("5 failure(s)")]]
with open(d + "/journal/0000000000000001.jsonl", "w") as f:
    for i, msgs in enumerate(fed):
        f.write(json.dumps({"type": "action_intent", "payload": {"kind": "completion", "request": {"model_input": {"messages": {"messages": msgs}}}}}) + "\n")
        f.write(json.dumps({"type": "action_result", "payload": {"result": {"result": {"usage": {"input_tokens": 10000 * (i + 1), "cached_input_tokens": 0, "output_tokens": 10}}}}}) + "\n")
EOF
out="$(python3 "$COUNTER" --ratio 3 --cap 4000 "$S")"
row="$(grep '^| m-900 ' <<<"$out")"
# the 30000-char result rides completions 1..3 (3 x ~10 000 tokens); the cap
# keeps 4200 of its chars: (30000+~70-4200)/3*3 = ~25 870
if [[ "$row" == "| m-900 | 1 | 4 | 100,000 | 0 | 40 | 3 | 3 | 1 | 3 |"* ]] &&
   python3 -c 'import sys; c=[x.strip() for x in sys.argv[1].split("|")]; assert 30000<=int(c[13].replace(",",""))<=30200 and 25800<=int(c[15].replace(",",""))<=26000' "$row"
then pass "counter: 3 failed calls = 1 loop, the long result re-fed 3 times, the cap removes its share"
else fail "counter: $out"; fi

# 6. install.sh calls the step once
c="$(grep -c 'steps/y15-vibe-output-cap.sh" && spool_install_vibe_output_cap' "$FEAT/install.sh")"
if [ "$c" = 1 ]; then pass "install.sh calls the step once"; else fail "install.sh calls it $c times"; fi

echo "y15-vibe-output-cap: $((n - fails))/$n passed, $skips skipped"
[ "$fails" = 0 ]
