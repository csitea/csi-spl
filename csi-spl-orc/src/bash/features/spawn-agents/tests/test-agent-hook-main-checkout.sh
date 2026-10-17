#!/usr/bin/env bash
# test-agent-hook-main-checkout.sh — SPL-2321: spool-agent-hook.sh refuses a
# LANE's file edit in the MAIN checkout and warns on its shell call there
# (a lane wrote 3 tracked files in a box's main checkout while its worktree
# stayed clean, 2026-10-17). Temp repos only: a "main" checkout, a linked
# worktree <repo>-wt/<id> per agent, as spawn makes them; no real checkout.
#   1. a lane's Edit / Write / MultiEdit / NotebookEdit into the main checkout
#      -> deny, the reason naming its own worktree's same path (the RED
#      CONTROL: before SPL-2321 the hook allowed it); vibe edit / write_file
#      -> vibe's {"decision": "deny"}
#   2. the same lane, target in its own worktree (absolute and relative to
#      cwd), a new file there, and a file of another repo -> allowed
#   3. a role seat (c-001, g-002, each with a worktree of its own; control:
#      c-0011 is a lane), an id with no
#      worktree, a worktree gone from disk, no SPOOL_AGENT_ID -> allowed
#   4. Bash with cwd in the main checkout -> allowed, the warning in claude's
#      additionalContext at PreToolUse and in vibe's additional_context at
#      PostToolUse (control: cwd in its worktree -> no warning)
#   6. SPL-2329: a lane's git write aimed at the main checkout (-C <main>, a
#      cwd or a cd inside it, through sudo / bash -c) -> deny naming its
#      worktree; merge --ff-only, fetch with no src:dst refspec, branch -d
#      <id>-* and reads -> allowed; the same writes in its own worktree, a
#      role seat, an id with no worktree -> allowed (RED CONTROL: before
#      SPL-2329 every git call was allowed)
#   5. vibe's own HooksManager, on the launcher's heartbeat pre_tool entry,
#      turns the deny into a HookToolDenial (SKIP with no vibe python)
# Env: AGENT_HOOK (default: the tree's hook): point it at an older copy to run
# the red control (case 1 then FAILS).
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
HOOK="${AGENT_HOOK:-$T_SCRIPTS/spool-agent-hook.sh}"
R="$(realpath "$T_TMP")/repo"
W="$R-wt"
export SPOOL_BOX_ID=box-t HOOK_PID=4242 HOOK_NOW=1790000000
git init -q -b master "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
for id in c-901 c-001 g-002 c-0011 c-905; do
  git -C "$R" worktree add -q -b "$id-x" "$W/$id" && mkdir -p "$SPOOL_ROOT/$id"
done
mkdir -p "$SPOOL_ROOT/c-777" "$R/sub" "$W/c-901/sub"
rm -rf "$W/c-905"   # its worktree is gone, git's worktrees/c-905 stays
git init -q "$T_TMP/other"

hook() {  # ID HARNESS EVENT PAYLOAD — the hook's stdout
  env SPOOL_AGENT_ID="$1" SPOOL_HARNESS="$2" bash "$HOOK" "$3" <<<"$4"
}
pay() {  # TOOL CWD KEY VALUE — a payload with tool_input {KEY: VALUE}
  printf '{"tool_name": "%s", "cwd": "%s", "tool_input": {"%s": "%s"}, "session_id": "s"}' "$1" "$2" "$3" "$4"
}
decision() {  # stdin = hook stdout -> deny|allow, then the reason
  python3 -c '
import json, sys
t = sys.stdin.read().strip()
d = json.loads(t) if t else {}
h = d.get("hookSpecificOutput") or {}
r = h.get("permissionDecisionReason") if h.get("permissionDecision") == "deny" else d.get("reason") if d.get("decision") == "deny" else None
print("deny" if r else "allow"); print(r or "")'
}
context() {  # stdin = hook stdout -> the context text of either harness
  python3 -c '
import json, sys
t = sys.stdin.read().strip()
d = json.loads(t) if t else {}
print((d.get("hookSpecificOutput") or {}).get("additionalContext") or (d.get("hook_specific_output") or {}).get("additional_context") or "")'
}

echo "# 1. a lane's edit in the main checkout is denied"
for tk in Edit:file_path Write:file_path MultiEdit:file_path NotebookEdit:notebook_path; do
  out="$(hook c-901 claude PreToolUse "$(pay "${tk%%:*}" "$W/c-901" "${tk#*:}" "$R/sub/a.txt")" | decision)"
  eq "1. claude ${tk%%:*} into main: denied" deny "${out%%$'\n'*}"
done
out="$(hook c-901 claude PreToolUse "$(pay Edit "$R" file_path sub/a.txt)" | decision)"
eq "1. claude Edit, a path relative to a cwd in main: denied" deny "${out%%$'\n'*}"
has "1. the reason names the target" "$R/sub/a.txt" "$out"
has "1. the reason names the lane's own path" "edit $W/c-901/sub/a.txt instead" "$out"
for tool in edit write_file; do
  out="$(hook c-901 vibe PreToolUse "$(pay "$tool" "$W/c-901" file_path "$R/new.txt")" | decision)"
  eq "1. vibe $tool into main: denied" deny "${out%%$'\n'*}"
done
raw="$(hook c-901 vibe PreToolUse "$(pay write_file "$W/c-901" file_path "$R/new.txt")")"
eq "1. vibe's deny shape is decision + reason only" "decision reason" \
  "$(python3 -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "$raw")"

echo "# 2. the lane's own worktree and other repos are allowed"
for p in "$W/c-901/sub/a.txt" "$W/c-901/brand-new/dir/f.txt" "$T_TMP/other/f.txt" /etc/hostname; do
  out="$(hook c-901 claude PreToolUse "$(pay Edit "$W/c-901" file_path "$p")" | decision)"
  eq "2. claude Edit $p: allowed" allow "${out%%$'\n'*}"
done
out="$(hook c-901 claude PreToolUse "$(pay Write "$W/c-901" file_path sub/a.txt)" | decision)"
eq "2. a path relative to a cwd in the worktree: allowed" allow "${out%%$'\n'*}"
out="$(hook c-901 vibe PreToolUse "$(pay write_file "$W/c-901" file_path "$W/c-901/x.txt")")"
eq "2. vibe write_file in its worktree: no output" "" "$out"

echo "# 3. role seats, ids with no worktree and non-agents are allowed"
for id in c-001 g-002 c-777 c-905; do
  out="$(hook "$id" claude PreToolUse "$(pay Edit "$R" file_path "$R/sub/a.txt")" | decision)"
  eq "3. $id Edit into main: allowed" allow "${out%%$'\n'*}"
done
out="$(hook c-0011 claude PreToolUse "$(pay Edit "$R" file_path "$R/sub/a.txt")" | decision)"
eq "3. control: c-0011 is a lane, not seat 001: denied" deny "${out%%$'\n'*}"
out="$(env -u SPOOL_AGENT_ID SPOOL_HARNESS=claude bash "$HOOK" PreToolUse <<<"$(pay Edit "$R" file_path "$R/a.txt")")"
eq "3. no SPOOL_AGENT_ID: no output" "" "$out"

echo "# 4. a shell call in the main checkout warns, never denies"
raw="$(hook c-901 claude PreToolUse "$(pay Bash "$R" command "git merge --ff-only origin/master")")"
out="$(decision <<<"$raw")"
eq "4. claude Bash, cwd in main: allowed" allow "${out%%$'\n'*}"
has "4. claude: the warning in additionalContext" "WARNING: this shell call runs in the main checkout $R" "$(context <<<"$raw")"
has "4. the warning names the worktree" "$W/c-901" "$(context <<<"$raw")"
eq "4. control: cwd in its worktree, no warning" "" \
  "$(hook c-901 claude PreToolUse "$(pay Bash "$W/c-901" command ls)" | context)"
eq "4. control: a role seat in main, no warning" "" \
  "$(hook c-001 claude PreToolUse "$(pay Bash "$R" command ls)" | context)"
raw="$(hook c-901 vibe PreToolUse "$(pay bash "$R" command ls)")"
eq "4. vibe bash pre_tool, cwd in main: no deny, no output" "" "$raw"
has "4. vibe: the warning at post_tool" "WARNING: this shell call runs in the main checkout $R" \
  "$(hook c-901 vibe PostToolUse "$(pay bash "$R" command ls)" | context)"
eq "4. vibe control: cwd in its worktree, no warning" "" \
  "$(hook c-901 vibe PostToolUse "$(pay bash "$W/c-901" command ls)" | context)"

echo "# 5. vibe's own hook runner denies through the heartbeat entry"
VPY="${VIBE_PYTHON:-}"
if [ -z "$VPY" ] && command -v vibe >/dev/null 2>&1; then
  VPY="$(head -1 "$(readlink -f "$(command -v vibe)")" | sed -n 's/^#!//p')"
fi
"${VPY:-/nonexistent}" -c 'import vibe.core.hooks.manager' 2>/dev/null || VPY=""
if [ -z "$VPY" ]; then
  echo "SKIP - 5. no vibe python (VIBE_PYTHON, or vibe on PATH)"
else
  # the launcher's entry (spool-mirror-hooks.inc.sh smh_vibe_merge), on this tree's hook
  printf '[[hooks]]\nname = "spool-heartbeat-pre-tool"\ntype = "pre_tool"\ncommand = "SPOOL_HARNESS=vibe exec bash %s PreToolUse; exit 0"\ntimeout = 5.0\n' \
    "$HOOK" >"$T_TMP/hooks.toml"
  drive() {  # TOOL FILE_PATH -> DENY|ALLOW from vibe's HooksManager
    SPOOL_AGENT_ID=c-901 "$VPY" - "$T_TMP/hooks.toml" "$W/c-901" "$1" "$2" <<'EOF'
import asyncio, sys
from pathlib import Path
from vibe.core.hooks.config import load_hooks_file
from vibe.core.hooks.manager import HooksManager
from vibe.core.hooks.models import HookToolDenial, PreToolInvocation
res = load_hooks_file(Path(sys.argv[1]))
mgr = HooksManager(res.hooks, cwd=Path(sys.argv[2]))
async def one():
    inv = PreToolInvocation(session_id="t", transcript_path="/dev/null", cwd=sys.argv[2],
                            tool_name=sys.argv[3], tool_call_id="call_1", tool_input={"file_path": sys.argv[4]})
    async for ev in mgr.run(inv):
        if isinstance(ev, HookToolDenial):
            return "DENY"
    return "ALLOW"
print(asyncio.run(one()) if not res.issues else "ISSUES %s" % res.issues)
EOF
  }
  eq "5. vibe runner: write_file into main denied" DENY "$(drive write_file "$R/a.txt" 2>&1)"
  eq "5. vibe runner: edit into main denied" DENY "$(drive edit "$R/sub/a.txt" 2>&1)"
  eq "5. vibe runner control: write_file in its worktree allowed" ALLOW "$(drive write_file "$W/c-901/a.txt" 2>&1)"
fi
echo "# 6. SPL-2329: a lane's git WRITE aimed at the main checkout is denied"
sh6() {  # ID CWD COMMAND -> deny|allow (claude PreToolUse)
  hook "$1" claude PreToolUse "$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$2" "$3")" | decision | sed -n 1p
}
for c in "git -C $R rebase origin/master" "git -C $R reset --hard origin/master" "git -C $R commit -m x" \
  "git -C $R cherry-pick abc" "git -C $R checkout -b y" "git -C $R switch y" "git -C $R stash" \
  "git -C $R pull --ff-only" "git -C $R am x.patch" "git -C $R branch -d other-x" "git -C $R branch -D c-901-x" \
  "sudo -u u bash -c 'cd $R && git merge tmp-x'" "cd $R && git rebase origin/master"; do
  eq "6. lane, $c: denied (RED CONTROL: allowed before SPL-2329)" deny "$(sh6 c-901 "$W/c-901" "$c")"
done
for c in "git merge tmp-x" "git fetch $W/c-901/.git c-901-x:tmp-x" "git merge origin/master"; do
  eq "6. lane, cwd in main, $c: denied" deny "$(sh6 c-901 "$R" "$c")"
done
out="$(hook c-901 claude PreToolUse "$(pay Bash "$W/c-901" command "git -C $R rebase origin/master")" | decision)"
has "6. the reason names the lane's worktree" "run it in your worktree: git -C $W/c-901 rebase" "$out"
eq "6. vibe bash pre_tool: denied in vibe's shape" deny \
  "$(hook c-901 vibe PreToolUse "$(pay bash "$W/c-901" command "git -C $R reset --hard")" | decision | sed -n 1p)"
for c in "sudo -u u git -C $R merge --ff-only origin/master" "git -C $R fetch origin" "git -C $R fetch git@example.com:o/r.git master" \
  "git -C $R status" "git -C $R log --oneline -3" "git -C $R worktree list" "git -C $R branch -d c-901-x" "git -C $R stash list" \
  "git -C $R/sub diff"; do
  eq "6. lane, $c: allowed" allow "$(sh6 c-901 "$W/c-901" "$c")"
done
eq "6. lane, cwd in main, git fetch origin: allowed" allow "$(sh6 c-901 "$R" "git fetch origin")"
for c in "git rebase origin/master" "git reset --hard HEAD" "git commit -m x" "git -C $W/c-901 merge tmp-x" "git fetch origin a:b"; do
  eq "6. lane, $c in its own worktree: allowed" allow "$(sh6 c-901 "$W/c-901" "$c")"
done
eq "6. lane, a cd into its worktree first: allowed" allow "$(sh6 c-901 "$R" "cd $W/c-901 && git rebase origin/master")"
eq "6. git -C a variable is not read: allowed" allow "$(sh6 c-901 "$W/c-901" 'git -C "$MAIN" reset --hard')"
eq "6. a mention of git is not a call: allowed" allow "$(sh6 c-901 "$R" "grep -n 'git reset' README")"
for id in c-001 c-777; do
  eq "6. $id (role seat / no worktree), git -C main rebase: allowed" allow "$(sh6 "$id" "$R" "git -C $R rebase origin/master")"
done
out="$(env -u SPOOL_AGENT_ID SPOOL_HARNESS=claude bash "$HOOK" PreToolUse <<<"$(pay Bash "$R" command "git -C $R reset --hard")")"
eq "6. no SPOOL_AGENT_ID: no output" "" "$out"
for id in c-901 c-001; do
  [ -s "$SPOOL_ROOT/$id/hook.err" ] && nok "hook.err of $id: $(cat "$SPOOL_ROOT/$id/hook.err")"
done
t_done
