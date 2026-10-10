#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y13: the force-push block in claude, grok, agy and qwen.
# Owner order (t1 4e373f5d): nobody force-pushes master without his explicit
# approval, and that one he may do by hand: the block has no approval switch.
#
#   spool_install_force_push_guard <home> <data-dir> <dry 0|1> <fleet 0|1>
#
# Copies spawn-agents/scripts/force-push-guard-hook.sh and the ONE shared
# matcher spawn-agents/lib/force-push-guard.inc.sh into
# <data-dir>/force-push-guard/ (a copy: a moved checkout never unhooks it),
# then wires every harness that has a config dir in <home>
# (y13-force-push-guard.py):
#   claude  ~/.claude/settings.json: hooks.PreToolUse (matcher Bash) and
#           permissions.deny globs. Both block under bypassPermissions
#           (measured 2.1.292). grok reads this file as well.
#   grok    ~/.grok/hooks/force-push-guard.json: PreToolUse (always trusted;
#           "deny rules, hooks ... still apply" in always-approve).
#   qwen    ~/.qwen/settings.json: hooks.PreToolUse (run_shell_command) and
#           permissions.deny (checked before --yolo's auto-approve).
#   agy     ~/.gemini/config/hooks.json: the named hook "force-push-guard",
#           PreToolUse on run_command, {"decision":"deny"}.
# The hook entry fails CLOSED: a missing hook file refuses the shell call.
# Only on a --fleet install (the kill-guard rule). Idempotent: our entries are
# replaced, every other key and hook kept; a file that is not a JSON object is
# named and left alone (return 7). SPOOL_INSTALL_FORCE_PUSH_GUARD=0 skips it.
# The named action for both homes: ./run -a do_install_force_push_guard.
#------------------------------------------------------------------------------
spool_install_force_push_guard() {
  local home="$1" data="$2" dry="${3:-0}" fleet="${4:-0}" here sa
  if [ "${SPOOL_INSTALL_FORCE_PUSH_GUARD:-1}" = 0 ]; then
    echo "spool-install: force-push-guard: skipped (SPOOL_INSTALL_FORCE_PUSH_GUARD=0)" >&2
    return 0
  fi
  [ "$fleet" = 1 ] || return 0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  sa="$here/../../spawn-agents"
  python3 "$here/y13-force-push-guard.py" "$home" "$data/force-push-guard" "$dry" \
    "$sa/scripts/force-push-guard-hook.sh" "$sa/lib/force-push-guard.inc.sh"
}
