#!/usr/bin/env bash
# force-push-guard-hook.sh — the pre-tool hook of claude, grok, agy and qwen
# that refuses a forbidden push form (owner order, t1 4e373f5d: nobody
# force-pushes master without the owner's explicit approval; no approval
# switch here - the owner does that one by hand).
#
#   force-push-guard-hook.sh <claude|grok|agy|qwen>   payload JSON on stdin
#
# The decision is the ONE shared matcher, ../lib/force-push-guard.inc.sh
# (force_push_guard_check: rc 0 allow, rc 2 refuse); this file only reads the
# harness's payload and answers in the harness's own block contract:
#   claude  tool_input.command;   exit 2, reason on stderr
#   grok    toolInput.command (camelCase); exit 2 + {"decision":"deny"}
#   qwen    tool_input.command;   exit 2 (any rc but 0/1 blocks), reason stderr
#   agy     toolCall.args.CommandLine; exit 0 + {"decision":"deny"} on
#           stdout; a pass prints {}, never "allow" (that auto-approves)
# On a refusal stdout carries the deny JSON as well (grok, qwen and agy read
# it; claude ignores stdout on exit 2).
# Fails CLOSED: no matcher next to this file, no python3, or a payload that
# cannot be read is a refusal, never a pass. Installed as a copy, next to its
# matcher, by spool-install step y13 (do_install_force_push_guard).
set -u
harness="${1:-claude}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="${FORCE_PUSH_GUARD_LIB:-}"
if [ -z "$lib" ]; then
  for f in "$here/force-push-guard.inc.sh" "$here/../lib/force-push-guard.inc.sh"; do
    [ -r "$f" ] && { lib="$f"; break; }
  done
fi

refuse() {  # REASON
  local r="force-push-guard: refused: $1"
  printf '%s\n' "$r" >&2
  # agy unmarshals strictly (an unknown field is a hook error): decision and
  # reason only. grok and qwen read either form.
  python3 -c 'import json,sys; r=sys.argv[1]; d={"decision":"deny","reason":r}
if sys.argv[2] != "agy": d["hookSpecificOutput"]={"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":r}
print(json.dumps(d))' "$r" "$harness" 2>/dev/null ||
    printf '{"decision":"deny","reason":"force-push-guard: refused"}\n'
  # agy reads the decision from the JSON (a non-zero exit is a hook failure,
  # which blocks too: measured 1.3.3); every other harness blocks on exit 2.
  [ "$harness" = agy ] && exit 0
  exit 2
}

[ -n "$lib" ] || lib=/nonexistent
[ -r "$lib" ] || refuse "the shared matcher force-push-guard.inc.sh is missing next to $0 (fail closed)"
command -v python3 >/dev/null 2>&1 || refuse "python3 is missing, the guard cannot read the payload (fail closed)"
payload="$(cat)"
# CMD:<the shell command of the call>, or NONE when it is not a shell call.
cmd="$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict):
    raise SystemExit(3)
SHELL = {"bash", "run_terminal_command", "run_shell_command", "shell", "shelltool", "run_command"}
call = d.get("toolCall") if isinstance(d.get("toolCall"), dict) else {}
name = str(d.get("tool_name") or d.get("toolName") or call.get("name") or call.get("toolName") or "")
args = None
for src, k in ((d, "tool_input"), (d, "toolInput"), (call, "args"), (call, "arguments"), (call, "input")):
    v = src.get(k)
    if isinstance(v, str):
        try:
            v = json.loads(v)
        except ValueError:
            v = {"command": v}
    if isinstance(v, dict):
        args = v
        break
cmd = None
for k in ("command", "CommandLine", "commandLine", "cmd"):
    if args is not None and isinstance(args.get(k), str):
        cmd = args[k]
        break
if cmd is None:
    # A shell call whose command cannot be read is not waved through; any
    # other tool is not ours.
    if name.lower() in SHELL:
        raise SystemExit(4)
    print("NONE", end="")
else:
    print("CMD:" + cmd, end="")
' 2>/dev/null)" || refuse "cannot read the $harness hook payload (fail closed)"
allow() { [ "$harness" = agy ] && printf '{}\n'; exit 0; }
[ "$cmd" = NONE ] && allow
cmd="${cmd#CMD:}"
# shellcheck source=../lib/force-push-guard.inc.sh
. "$lib" || refuse "cannot load $lib (fail closed)"
why="$(force_push_guard_check "$cmd" 2>&1)"; rc=$?
[ "$rc" = 0 ] && allow
why="${why#force-push-guard: refused: }"
refuse "${why:-the guard returned $rc (fail closed)}"
