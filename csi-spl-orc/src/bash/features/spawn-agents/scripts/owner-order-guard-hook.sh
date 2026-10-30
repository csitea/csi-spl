#!/usr/bin/env bash
# owner-order-guard-hook.sh — the pre-tool hook of claude, grok, agy and qwen
# for the owner-order gate (spec 168 part c, B3, SPL-4372): an agent's
# `git commit` / `git push` in a checkout whose repository has an owner-order
# ledger is denied when it changes a path an active go / content order covers
# without the owner's go (`Owner-go: <msg uuid>`, its message naming the
# order's id8). It is the gate for a repository outside csi-spl, where the
# fleet installs no git hook and never edits .git/config, and the backstop of
# csi-spl's own pre-push part against `git push --no-verify`.
#
#   owner-order-guard-hook.sh <claude|grok|agy|qwen>   payload JSON on stdin
#
# The decision is ../lib/owner-order-guard.inc.sh (owner_order_guard_check:
# rc 0 allow, 2 refuse); this file reads the harness payload (the command,
# and the call's cwd when the harness sends one) and answers in the block
# contract of force-push-guard-hook.sh: claude / qwen exit 2, reason on
# stderr; grok exit 2 + {"decision":"deny"}; agy exit 0 + the decision JSON
# on stdout ({"decision":"allow"} on a pass: agy reads {} as a deny).
# Fails CLOSED: no matcher next to this file, no python3, or a shell call
# whose payload cannot be read is a refusal.
# INSTALLING IT IS THE OWNER'S STEP (spec 168 section 5, risk R5): nothing in
# the fleet adds it to a harness's settings.
set -u
harness="${1:-claude}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="${OWNER_ORDER_GUARD_LIB:-}"
if [ -z "$lib" ]; then
  for f in "$here/owner-order-guard.inc.sh" "$here/../lib/owner-order-guard.inc.sh"; do
    [ -r "$f" ] && { lib="$f"; break; }
  done
fi

refuse() {  # REASON
  local r="owner-order-guard: refused: $1"
  printf '%s\n' "$r" >&2
  python3 -c 'import json,sys; r=sys.argv[1]; d={"decision":"deny","reason":r}
if sys.argv[2] != "agy": d["hookSpecificOutput"]={"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":r}
print(json.dumps(d))' "$r" "$harness" 2>/dev/null || printf '{"decision":"deny","reason":"owner-order-guard: refused"}\n'
  [ "$harness" = agy ] && exit 0
  exit 2
}
allow() { [ "$harness" = agy ] && printf '{"decision":"allow"}\n'; exit 0; }

if [ -z "$lib" ] || [ ! -r "$lib" ]; then refuse "the matcher owner-order-guard.inc.sh is missing next to $0 (fail closed)"; fi
command -v python3 >/dev/null 2>&1 || refuse "python3 is missing, the guard cannot read the payload (fail closed)"
payload="$(cat)"
# "CMD<US>cwd<US>command", or NONE when it is not a shell call
parsed="$(printf '%s' "$payload" | python3 -c '
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
    if name.lower() in SHELL:
        raise SystemExit(4)
    print("NONE", end="")
else:
    cwd = d.get("cwd") or (args or {}).get("cwd") or (args or {}).get("Cwd") or ""
    print("CMD\x1f%s\x1f%s" % (cwd if isinstance(cwd, str) else "", cmd), end="")
' 2>/dev/null)" || refuse "cannot read the $harness hook payload (fail closed)"
[ "$parsed" = NONE ] && allow
parsed="${parsed#CMD$'\x1f'}"
cwd="${parsed%%$'\x1f'*}" cmd="${parsed#*$'\x1f'}"
# shellcheck source=../lib/owner-order-guard.inc.sh
. "$lib" || refuse "cannot load $lib (fail closed)"
why="$(owner_order_guard_check "$cmd" "${cwd:-$PWD}" 2>&1)" && allow
why="${why#owner-order-guard: refused: }"
refuse "${why:-the guard refused (fail closed)}"
