#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y13, the force-push block in claude, grok, qwen
# and agy, through each harness's OWN block path, hermetic (a fake home):
#   1. per harness: the entry step y13 wrote is found where that harness reads
#      it, its matcher selects that harness's shell tool, and its command - run
#      as the harness runs it, with the harness's payload shape - is a BLOCK
#      under that harness's contract for every forbidden form and a PASS for a
#      plain `git push origin HEAD:master` and a non-shell tool:
#        claude  tool_input.command; blocks only on exit 2
#        grok    toolInput.command (camelCase); exit 2 or decision deny
#        qwen    tool_input.command; any exit but 0/1, or decision deny
#        agy     toolCall.args.CommandLine; ONLY the stdout JSON decides, and
#                agy unmarshals strictly (decision / reason only); decision is
#                required: {} is a deny, a pass must say "allow"
#   2. fail closed: the hook file gone, every harness still refuses
#   3. deny globs in claude and qwen settings; other keys and hooks kept
#   4. idempotent: a re-run changes nothing; dry run writes nothing
#   5. install.sh calls the step; the named action plans by default
# Control: the same evaluation over the settings as they were BEFORE the step
# lets every forbidden form through (the red the step closes).
#------------------------------------------------------------------------------
# shellcheck disable=SC2015,SC2016  # pass/fail chains; the grep needles are literal
set -uo pipefail
FEAT="$(cd "$(dirname "$0")/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
STEP="$FEAT/steps/y13-force-push-guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

H="$T/home"
mkdir -p "$H/.claude" "$H/.grok" "$H/.qwen" "$H/.gemini/config"
# The settings as a fleet home has them today: a mirror hook, an allow list.
cat >"$H/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash"], "deny": [], "defaultMode": "bypassPermissions"},
 "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "exit 0", "timeout": 5}]}]},
 "theme": "dark"}
EOF
printf '{"$version": 4, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "exit 0"}]}]}}\n' >"$H/.qwen/settings.json"
printf '{"spool-mirror": {"Stop": [{"type": "command", "command": "echo {}"}]}}\n' >"$H/.gemini/config/hooks.json"
cp -a "$H" "$T/before"

# eval_harness HARNESS HOME: every forbidden / allowed form through the hooks
# HARNESS loads from HOME, decided by HARNESS's contract. Prints one line per
# form: "<BLOCK|PASS> <form>".
eval_harness() {
  python3 - "$1" "$2" <<'EOF_PY'
import json, os, re, subprocess, sys
harness, home = sys.argv[1], sys.argv[2]
FORBID = [
    "git push --force origin HEAD:master",
    "git push -f origin master",
    "git push --force-with-lease origin HEAD:master",
    "git push origin +HEAD:master",
    "git push origin :master",
    "git push --mirror origin",
    "SPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master",
    "bash -c 'git push -f origin master'",
    "cd /tmp && git -C repo push --force origin master",
]
ALLOW = ["git push origin HEAD:master"]
SHELL_TOOL = {"claude": "Bash", "grok": "run_terminal_command", "qwen": "run_shell_command", "agy": "run_command"}[harness]

def load(p):
    try:
        return json.load(open(p))
    except (FileNotFoundError, ValueError):
        return {}

def grouped(entries, tool):
    out = []
    for e in entries or []:
        m = e.get("matcher", "")
        if harness == "grok" and m == "Bash":
            m = "Bash|run_terminal_command"   # grok maps the claude name
        if harness == "qwen" and m in ("Bash", "Shell", "ShellTool"):
            m = "run_shell_command"           # qwen aliases
        if m in ("", "*") or re.fullmatch(m, tool):
            out += [h["command"] for h in e.get("hooks", []) if h.get("type") == "command"]
    return out

def commands(tool):
    if harness == "claude":
        return grouped(load(home + "/.claude/settings.json").get("hooks", {}).get("PreToolUse"), tool)
    if harness == "grok":
        cmds = grouped(load(home + "/.claude/settings.json").get("hooks", {}).get("PreToolUse"), tool)
        d = home + "/.grok/hooks"
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            cmds += grouped(load(os.path.join(d, f)).get("hooks", {}).get("PreToolUse"), tool)
        return cmds
    if harness == "qwen":
        return grouped(load(home + "/.qwen/settings.json").get("hooks", {}).get("PreToolUse"), tool)
    cmds = []
    for name, ev in load(home + "/.gemini/config/hooks.json").items():
        cmds += grouped(ev.get("PreToolUse"), tool)
    return cmds

def payload(tool, cmd):
    if harness == "grok":
        return {"hookEventName": "pre_tool_use", "hook_event_name": "PreToolUse", "permissionMode": "bypassPermissions",
                "toolName": tool, "toolInput": {"command": cmd} if cmd is not None else {"file_path": "/x"}}
    if harness == "agy":
        return {"toolCall": {"name": tool, "args": {"CommandLine": cmd} if cmd is not None else {"AbsolutePath": "/x"}},
                "stepIdx": 3, "conversationId": "c"}
    mode = "bypassPermissions" if harness == "claude" else "yolo"
    return {"hook_event_name": "PreToolUse", "permission_mode": mode, "tool_name": tool,
            "tool_input": {"command": cmd} if cmd is not None else {"file_path": "/x"}}

def blocked(tool, cmd):
    for c in commands(tool):
        r = subprocess.run(["sh", "-c", c], input=json.dumps(payload(tool, cmd)), capture_output=True, text=True, timeout=30)
        out = r.stdout.strip()
        try:
            d = json.loads(out) if out else {}
        except ValueError:
            d = None
        if harness == "claude" and r.returncode == 2:
            return True
        if harness == "grok" and (r.returncode == 2 or (d or {}).get("decision") == "deny"):
            return True
        if harness == "qwen" and (r.returncode not in (0, 1) or (d or {}).get("decision") in ("deny", "block")):
            return True
        if harness == "agy":
            if d is None or not isinstance(d, dict) or set(d) - {"decision", "reason", "permissionOverrides", "overwrite"}:
                return "BADJSON"   # agy: a hook error, not a decision
            # decision is REQUIRED (agy hooks.md:191): {} or no decision is a
            # deny (measured 1.3.3), only "allow" lets the call run.
            if d.get("decision") != "allow":
                return True
    return False

for f in FORBID + ALLOW:
    b = blocked(SHELL_TOOL, f)
    print("%s %s" % ("BADJSON" if b == "BADJSON" else ("BLOCK" if b else "PASS"), f))
b = blocked("Read" if harness != "agy" else "view_file", None)
print("%s <non-shell tool>" % ("BADJSON" if b == "BADJSON" else ("BLOCK" if b else "PASS")))
EOF_PY
}

# verdict LABEL OUT: forbidden forms all BLOCK, the plain push and the
# non-shell tool PASS.
verdict() {
  local label="$1" out="$2" bad
  bad="$(printf '%s\n' "$out" | grep -vE '^BLOCK ' | grep -vxE 'PASS (git push origin HEAD:master|<non-shell tool>)')"
  if [ -z "$bad" ] && [ "$(printf '%s\n' "$out" | grep -c '^PASS ')" = 2 ]; then
    pass "$label: $(printf '%s\n' "$out" | grep -c '^BLOCK ') forbidden forms blocked, plain push + other tool pass"
  else fail "$label: $(printf '%s\n' "$out" | grep -v '^BLOCK ' | tr '\n' '|')"; fi
}

# --- 0. control: before the step nothing blocks --------------------------------------------------
for h in claude grok qwen agy; do
  out="$(eval_harness "$h" "$T/before")"
  if [ "$(printf '%s\n' "$out" | grep -c '^BLOCK ')" = 0 ]; then pass "control $h: the old settings let all $(printf '%s\n' "$out" | grep -c '^PASS ') forms through"
  else fail "control $h: the old settings already block: $out"; fi
done

# --- 4a. dry run writes nothing -------------------------------------------------------------------
out="$(bash -c '. "$1"; spool_install_force_push_guard "$2" "$2/.local/share/spool-agent" 1 1' _ "$STEP" "$H" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && diff -r "$T/before" "$H" >/dev/null && [ "$(printf '%s\n' "$out" | grep -c '^would: ')" -ge 6 ]; then
  pass "dry run: $(printf '%s\n' "$out" | grep -c '^would: ') planned changes, nothing written"
else fail "dry run (rc=$rc): $out"; fi
# Not --fleet: nothing at all.
bash -c '. "$1"; spool_install_force_push_guard "$2" "$2/.local/share/spool-agent" 0 0' _ "$STEP" "$H" >/dev/null 2>&1
diff -r "$T/before" "$H" >/dev/null && pass "without --fleet the step writes nothing" || fail "the step wrote without --fleet"

# --- 1. the install, then each harness's own block path ------------------------------------------
out="$(bash -c '. "$1"; spool_install_force_push_guard "$2" "$2/.local/share/spool-agent" 0 1' _ "$STEP" "$H" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "install rc 0: $(printf '%s\n' "$out" | tail -1)" || fail "install rc=$rc: $out"
G="$H/.local/share/spool-agent/force-push-guard"
cmp -s "$G/force-push-guard.inc.sh" "$ORC/src/bash/features/spawn-agents/lib/force-push-guard.inc.sh" &&
  [ -x "$G/force-push-guard-hook.sh" ] && pass "the hook and the ONE shared matcher copied into $G (no second matcher)" ||
  fail "guard copy: $(ls -l "$G" 2>&1)"
for h in claude grok qwen agy; do verdict "$h" "$(eval_harness "$h" "$H")"; done

# --- 2. fail closed --------------------------------------------------------------------------------
mv "$G/force-push-guard-hook.sh" "$T/hook.away"
for h in claude grok qwen agy; do
  out="$(eval_harness "$h" "$H")"
  printf '%s\n' "$out" | grep '^BLOCK git push origin HEAD:master$' >/dev/null && [ "$(printf '%s\n' "$out" | grep -c '^BLOCK ')" -ge 10 ] &&
    pass "fail closed $h: hook file gone -> every shell call refused" || fail "fail closed $h: $(printf '%s\n' "$out" | tr '\n' '|')"
done
mv "$T/hook.away" "$G/force-push-guard-hook.sh"

# --- 3. deny globs, other keys kept ----------------------------------------------------------------
python3 - "$H" <<'EOF_PY' && pass "deny globs in claude + qwen; allow list, theme, mirror hooks and \$version kept" || fail "settings keys"
import json, sys
h = sys.argv[1]
c = json.load(open(h + "/.claude/settings.json"))
q = json.load(open(h + "/.qwen/settings.json"))
a = json.load(open(h + "/.gemini/config/hooks.json"))
assert "Bash(git push --force*)" in c["permissions"]["deny"] and "Bash(git push * +*)" in q["permissions"]["deny"]
assert c["permissions"]["allow"] == ["Bash"] and c["theme"] == "dark" and c["permissions"]["defaultMode"] == "bypassPermissions"
assert len(c["hooks"]["PreToolUse"]) == 2 and q["$version"] == 4 and "Stop" in q["hooks"] and "spool-mirror" in a
# no deny glob may refuse the plain push
import fnmatch
for r in c["permissions"]["deny"]:
    assert not fnmatch.fnmatchcase("git push origin HEAD:master", r[5:-1]), r
EOF_PY

# --- 4b. idempotent ---------------------------------------------------------------------------------
cp -a "$H" "$T/after1"
out="$(bash -c '. "$1"; spool_install_force_push_guard "$2" "$2/.local/share/spool-agent" 0 1' _ "$STEP" "$H" 2>&1)"
diff -r "$T/after1" "$H" >/dev/null && ! printf '%s\n' "$out" | grep 'force-push-guard: \(copy\|claude\|grok\|qwen\|agy\):' >/dev/null &&
  pass "re-run: nothing changed, nothing reported" || fail "re-run changed: $out"
# A JSON file that is not an object is named and left alone (7).
printf '[1]\n' >"$H/.qwen/settings.json"
bash -c '. "$1"; spool_install_force_push_guard "$2" "$2/.local/share/spool-agent" 0 1' _ "$STEP" "$H" >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && [ "$(cat "$H/.qwen/settings.json")" = "[1]" ] && pass "a non-object settings.json: left alone, rc 7" || fail "bad json rc=$rc"

# --- 5. wiring -----------------------------------------------------------------------------------
c="$(grep -c 'spool_install_force_push_guard "$HOME" "$DATA" "$DRY" "$FLEET"' "$FEAT/install.sh")"
[ "$c" = 1 ] && pass "install.sh calls the step once" || fail "install.sh calls it $c times"
grep -q '^do_install_force_push_guard()' "$ORC/src/bash/run/install-force-push-guard.func.sh" &&
  grep -q 'DRY_RUN:-1' "$ORC/src/bash/run/install-force-push-guard.func.sh" &&
  pass "named action do_install_force_push_guard, dry run by default" || fail "named action"

echo "test-y13-force-push-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
