#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y12 - the Mistral Vibe push guard.
#   1. the step installs the guard + matcher into a sandbox vibe home whose
#      hooks.toml has the launcher's entries (mirror + heartbeat); those are
#      kept, ONE strict pre_tool "spool-push-guard" entry is added; a re-run
#      says current; a dry run writes nothing; no vibe home = skipped
#   2. THE REAL BLOCK PATH: vibe's own load_hooks_file + HooksManager run the
#      installed hooks.toml on a pre_tool invocation of the bash tool. Every
#      forbidden form yields a HookToolDenial; a plain push does not
#      (needs vibe's python: VIBE_PYTHON, else the vibe on PATH, else the
#      pipx venv; without one this part SKIPs and 3 still runs)
#   3. the hook itself on vibe's payload shape (no vibe needed): deny JSON for
#      a forced push, empty for a plain push, bash_stdin's text field checked
#   4. fail closed: with the matcher removed, strict = true denies even a
#      plain push through the real path (and the hook exits non-zero)
#   5. install.sh calls the step exactly once
# Control: the OLD hooks.toml (before the install) lets every forced form
# through the same real path - no denial.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
STEP="$FEAT/steps/y12-vibe-push-guard.sh"
fails=0 n=0 skips=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { skips=$((skips + 1)); echo "SKIP: $1"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
H="$T/vibe"
mkdir -p "$H"
# the launcher's shape (spool-mirror-hooks.inc.sh smh_vibe_merge), on a path
# that does not exist so nothing real runs
cat >"$H/hooks.toml" <<'EOF'
[[hooks]]
name = "spool-mirror"
type = "post_agent"
command = "[ -r /nonexistent/spool-mirror.py ] && exec python3 /nonexistent/spool-mirror.py hook --vibe; exit 0"
timeout = 10.0

[[hooks]]
name = "spool-heartbeat-pre-tool"
type = "pre_tool"
command = "[ -r /nonexistent/spool-agent-hook.sh ] && SPOOL_HARNESS=vibe exec bash /nonexistent/spool-agent-hook.sh PreToolUse; exit 0"
timeout = 5.0
EOF
cp "$H/hooks.toml" "$T/old-hooks.toml"
inst() { bash -c '. "$1"; spool_install_vibe_push_guard "$2" "$3"' _ "$STEP" "$@" 2>&1; }

FORBID=(
  'git push --force origin HEAD:master'
  'git push -f origin master'
  'git push --force-with-lease origin HEAD:master'
  'git push --force-if-includes origin HEAD:master'
  'git push origin +HEAD:master'
  'git push --mirror origin'
  'git push --delete origin master'
  'git push origin :master'
  'SPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master'
  'bash -c "git push --force origin HEAD:master"'
  "sh -c 'git push -f origin master'"
  'env GIT_TRACE=1 git push --force origin master'
  'git -c user.name=x push --force-with-lease origin HEAD:master'
  'sudo -u agentusr git -C /opt/x push -f origin master'
  'cd /opt/x && git push origin HEAD:master --force'
)
ALLOW=('git push origin HEAD:master' 'git status' 'git push origin c-766-branch')

# 1. install
out="$(inst "$H" 1)"
if [ ! -e "$H/spool-push-guard" ] && cmp -s "$H/hooks.toml" "$T/old-hooks.toml" && [[ "$out" == *"would: write the spool-push-guard"* ]]
then pass "dry run: plans, writes nothing"; else fail "dry run: $out"; fi
out="$(inst "$H" 0)"; rc=$?
if [ "$rc" = 0 ] && [ -x "$H/spool-push-guard/vibe-push-guard.py" ] && [ -r "$H/spool-push-guard/force-push-guard.inc.sh" ]
then pass "installs the guard and the matcher"; else fail "install rc=$rc: $out"; fi
if [ "$(grep -c '^name = "spool-push-guard"$' "$H/hooks.toml")" = 1 ] && grep -q '^strict = true$' "$H/hooks.toml" &&
   grep -q '^match = "\*"$' "$H/hooks.toml" && grep -q '^name = "spool-heartbeat-pre-tool"$' "$H/hooks.toml" &&
   grep -q '^name = "spool-mirror"$' "$H/hooks.toml"
then pass "hooks.toml: one strict pre_tool guard entry, the launcher's entries kept"; else fail "hooks.toml: $(cat "$H/hooks.toml")"; fi
out="$(inst "$H" 0)"
if [[ "$out" == *"already current"* ]] && [ "$(grep -c '^name = "spool-push-guard"$' "$H/hooks.toml")" = 1 ]
then pass "re-run: already current"; else fail "re-run: $out"; fi
out="$(inst "$T/none" 0)"
if [[ "$out" == *"skipped (no $T/none)"* ]] && [ ! -e "$T/none" ]; then pass "no vibe home: skipped"; else fail "no home: $out"; fi

# 2. the real block path
VPY="${VIBE_PYTHON:-}"
if [ -z "$VPY" ] && command -v vibe >/dev/null 2>&1; then
  VPY="$(head -1 "$(readlink -f "$(command -v vibe)")" | sed -n 's/^#!//p')"
fi
for c in "$VPY" "$HOME"/.local/share/pipx/venvs/mistral-vibe/bin/python /home/*/.local/share/pipx/venvs/mistral-vibe/bin/python; do
  [ -n "$c" ] && [ -x "$c" ] && "$c" -c 'import vibe.core.hooks.manager' 2>/dev/null && { VPY="$c"; break; }
  VPY=""
done
cat >"$T/drive.py" <<'EOF'
import asyncio, json, sys
from pathlib import Path
from vibe.core.hooks.config import load_hooks_file
from vibe.core.hooks.manager import HooksManager
from vibe.core.hooks.models import HookToolDenial, PreToolInvocation

res = load_hooks_file(Path(sys.argv[1]))
if res.issues:
    print("ISSUES %s" % res.issues)
    sys.exit(5)
mgr = HooksManager(res.hooks, cwd=Path(sys.argv[2]))

async def one(tool, tool_input):
    inv = PreToolInvocation(session_id="t", transcript_path="/dev/null", cwd=sys.argv[2],
                            tool_name=tool, tool_call_id="call_1", tool_input=tool_input)
    async for ev in mgr.run(inv):
        if isinstance(ev, HookToolDenial):
            return "DENY"
    return "ALLOW"

for line in sys.stdin:
    d = json.loads(line)
    print(asyncio.run(one(d["tool"], d["input"])))
EOF
jl() { python3 -c 'import json,sys; [print(json.dumps({"tool": "bash", "input": {"command": c}})) for c in sys.argv[1:]]' "$@"; }
drive() { jl "${@:2}" | "$VPY" "$T/drive.py" "$1" "$T" 2>"$T/drive.err"; }
if [ -n "$VPY" ]; then
  echo "INFO: vibe python $VPY ($("$VPY" -c 'import importlib.metadata as m; print(m.version("mistral-vibe"))' 2>/dev/null))"
  mapfile -t got < <(drive "$H/hooks.toml" "${FORBID[@]}")
  for i in "${!FORBID[@]}"; do
    if [ "${got[$i]:-}" = DENY ]; then pass "vibe denies: ${FORBID[$i]}"; else fail "vibe let through (${got[$i]:-none}): ${FORBID[$i]} $(cat "$T/drive.err")"; fi
  done
  mapfile -t got < <(drive "$H/hooks.toml" "${ALLOW[@]}")
  for i in "${!ALLOW[@]}"; do
    if [ "${got[$i]:-}" = ALLOW ]; then pass "vibe allows: ${ALLOW[$i]}"; else fail "vibe denied (${got[$i]:-none}): ${ALLOW[$i]}"; fi
  done
  # control: the old hooks.toml lets every forced form through
  mapfile -t got < <(drive "$T/old-hooks.toml" "${FORBID[@]}")
  through=0
  for g in "${got[@]}"; do [ "$g" = ALLOW ] && through=$((through + 1)); done
  if [ "$through" = "${#FORBID[@]}" ]; then pass "control: the old hooks.toml lets all ${#FORBID[@]} forced forms through"
  else fail "control: old config let $through of ${#FORBID[@]} through"; fi
else
  skip "no vibe python (mistral-vibe) here: the real-path part 2 and 4 did not run"
fi

# 3. the hook on vibe's payload shape
pl() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name": "pre_tool", "session_id": "s", "parent_session_id": None, "transcript_path": "/dev/null", "cwd": "/tmp", "tool_name": sys.argv[1], "tool_call_id": "call_42", "tool_input": {sys.argv[2]: sys.argv[3]}}))' "$@"; }
G="$H/spool-push-guard/vibe-push-guard.py"
out="$(pl bash command 'git push --force origin HEAD:master' | python3 "$G")"; rc=$?
if [ "$rc" = 0 ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["decision"]=="deny" and "force-push-guard: refused" in d["reason"]' "$out" 2>/dev/null
then pass "hook: deny JSON for a forced push"; else fail "hook forced: rc=$rc out=$out"; fi
out="$(pl bash command 'git push origin HEAD:master' | python3 "$G")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "hook: a plain push prints nothing, rc 0"; else fail "hook plain: rc=$rc out=$out"; fi
out="$(pl bash_stdin text $'git push -f origin master\n' | python3 "$G")"
if [[ "$out" == *'"deny"'* ]]; then pass "hook: bash_stdin text is checked too"; else fail "hook stdin: $out"; fi
out="$(pl read_file path '/x' | python3 "$G")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "hook: a non-shell tool passes"; else fail "hook read_file: rc=$rc out=$out"; fi

# 4. fail closed
rm -f "$H/spool-push-guard/force-push-guard.inc.sh"
pl bash command 'git push origin HEAD:master' | python3 "$G" >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then pass "no matcher: the hook exits non-zero ($rc)"; else fail "no matcher: hook rc 0"; fi
if [ -n "$VPY" ]; then
  one="$(drive "$H/hooks.toml" 'git push origin HEAD:master')"
  if [ "$one" = DENY ]; then pass "no matcher: strict = true denies even a plain push (fail closed)"; else fail "no matcher, vibe said $one"; fi
fi

# 5. install.sh calls the step once
c="$(grep -c 'steps/y12-vibe-push-guard.sh" && spool_install_vibe_push_guard' "$FEAT/install.sh")"
if [ "$c" = 1 ]; then pass "install.sh calls the step once"; else fail "install.sh calls it $c times"; fi

echo "y12-vibe-push-guard: $((n - fails))/$n passed, $skips skipped"
[ "$fails" = 0 ]
