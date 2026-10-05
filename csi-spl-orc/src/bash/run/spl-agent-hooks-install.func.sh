#!/bin/bash
#------------------------------------------------------------------------------
# @description Register the agent hook (specs/093 7.2) in the agent user's
# @description claude settings: one entry per event (SessionStart,
# @description UserPromptSubmit, PreToolUse, PostToolUse, Stop), each running
# @description `spool-agent-hook.sh <event>` of THIS checkout. The entries sit
# @description beside the existing spool-mirror.py ones, which are never
# @description touched; every other key of the file is kept.
# @description Idempotent: our entries are replaced by the same ones, so a
# @description second run reports "nothing to change". Dry run unless
# @description DRY_RUN=0; a write keeps a copy <file>.bak.<utc>.
# @description HOOKS_UNINSTALL=1 removes our entries instead (the rollback).
# @description A file that is not a JSON object is refused, never rewritten.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param HOOKS_SETTINGS (optional) - default $HOME/.claude/settings.json (run it as the agent user)
# @param HOOKS_UNINSTALL (optional) - 1 removes our entries
# @param HOOKS_ALLOW_WORKTREE (optional) - 1 allows DRY_RUN=0 from a linked worktree (tests only)
# @example ./run -a do_spl_agent_hooks_install
# @example DRY_RUN=0 ./run -a do_spl_agent_hooks_install
# @example DRY_RUN=0 HOOKS_UNINSTALL=1 ./run -a do_spl_agent_hooks_install
#------------------------------------------------------------------------------
do_spl_agent_hooks_install() {
  local dry="${DRY_RUN:-1}" un="${HOOKS_UNINSTALL:-0}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  local f="${HOOKS_SETTINGS:-$HOME/.claude/settings.json}"
  local script="$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-agent-hook.sh"
  [[ -r "$script" ]] || { do_log "FATAL the hook $script is not readable"; return 1; }
  local gd cd
  # The entries name THIS checkout's script: from a linked worktree (torn down
  # when its lane closes) they would point at nothing.
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ -n "$gd" && "$gd" != "$cd" && "${HOOKS_ALLOW_WORKTREE:-0}" != 1 ]]; then
    if [[ "$dry" == 0 && "$un" != 1 ]]; then
      do_log "FATAL $PROJ_PATH is a linked worktree: run the install from the main checkout - nothing changed"; return 1
    fi
    echo "WARN $PROJ_PATH is a linked worktree: the paths below would vanish with it; install from the main checkout"
  fi
  local after rc
  after="$(mktemp)"
  spl_agent_hooks_merge "$f" "$script" "$un" >"$after"; rc=$?
  if (( rc != 0 )); then rm -f "$after"; do_log "FATAL $f is not a JSON object - nothing changed"; return 1; fi
  if [[ -f "$f" ]] && cmp -s "$f" "$after"; then
    echo "OK hooks: nothing to change in $f"; rm -f "$after"; return 0
  fi
  if [[ "$dry" == 1 ]]; then echo "PLAN hooks: $f before -> after"; else echo "DO hooks: $f before -> after"; fi
  local src="$f"; [[ -f "$f" ]] || src=/dev/null
  diff -u --label before --label after "$src" "$after" | sed 's/^/  /'
  if [[ "$dry" == 0 ]]; then
    mkdir -p "$(dirname "$f")" || { rm -f "$after"; do_log "FATAL cannot create $(dirname "$f")"; return 1; }
    [[ -f "$f" ]] && cp -p "$f" "$f.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    if cat "$after" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; then
      echo "DONE hooks: $f"
    else
      rm -f "$f.tmp.$$" "$after"; do_log "FATAL cannot write $f"; return 1
    fi
  fi
  rm -f "$after"
}

# spl_agent_hooks_merge <settings> <hook script> <uninstall 0|1>: prints the
# settings with every entry naming spool-agent-hook.sh removed and, unless
# uninstalling, one fresh entry per event appended. The timeout is short on
# purpose: the hook's budget is 50 ms, and one that hangs must never hold a
# prompt, a tool call or a turn. The command is a no-op when the script is
# gone (a checkout mid-move), as the mirror entries are. Exit 1: not JSON.
spl_agent_hooks_merge() {
  python3 - "$1" "$2" "$3" <<'EOF_PY'
import json, shlex, sys
path, script, uninstall = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop")
try:
    d = json.load(open(path))
except FileNotFoundError:
    d = {}
except ValueError:
    sys.exit(1)
if not isinstance(d, dict) or not isinstance(d.get("hooks", {}), dict):
    sys.exit(1)
hooks = d.setdefault("hooks", {})
for ev in list(hooks):
    if isinstance(hooks[ev], list):
        hooks[ev] = [e for e in hooks[ev] if "spool-agent-hook.sh" not in json.dumps(e)]
        if not hooks[ev]:
            del hooks[ev]
if not uninstall:
    p = shlex.quote(script)
    for ev in EVENTS:
        cmd = f"[ -r {p} ] && exec bash {p} {ev}; exit 0"
        hooks.setdefault(ev, []).append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
if not hooks:
    del d["hooks"]
print(json.dumps(d, indent=2, ensure_ascii=False))
EOF_PY
}
