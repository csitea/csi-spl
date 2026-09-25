#!/bin/bash
#------------------------------------------------------------------------------
# @description Print the CLI hooks that switch the terminal mirror on
# @description (specs/036): UserPromptSubmit and Stop, each calling
# @description `spool-mirror.py hook` of THIS checkout. Claude Code reads them
# @description from ~/.claude/settings.json or a `--settings <file>`; grok reads
# @description the same file (its [compat.claude] hooks scan), so one entry
# @description serves both CLIs.
# @description The fleet copy is the org overlay's claude-config settings
# @description fragment; this action is its source, and it is what a single
# @description test agent is launched with (`claude --settings <SETTINGS_OUT>`).
# @description Writes nothing unless SETTINGS_OUT is set. No secret.
# @param SETTINGS_OUT (optional) - also write the JSON to this file (0644)
# @param MIRROR_PY (optional) - the hook script, default this checkout's
# @param   src/bash/features/spawn-agents/scripts/spool-mirror.py
# @example ./run -a do_spl_desk_mirror_settings
# @example SETTINGS_OUT=/var/tmp/mirror-hooks.json ./run -a do_spl_desk_mirror_settings
#------------------------------------------------------------------------------
do_spl_desk_mirror_settings() {
  do_require_bin python3 || return 1
  local here py
  here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  py="${MIRROR_PY:-$(readlink -f "$here/../features/spawn-agents/scripts/spool-mirror.py")}"
  [[ -r "$py" ]] || { do_log "FATAL the mirror hook $py is not readable"; return 1; }
  local json
  json="$(spl_desk_mirror_settings_json "$py")" || return 1
  printf '%s\n' "$json"
  if [[ -n "${SETTINGS_OUT:-}" ]]; then
    printf '%s\n' "$json" >"$SETTINGS_OUT" && chmod 644 "$SETTINGS_OUT" ||
      { do_log "FATAL cannot write $SETTINGS_OUT"; return 1; }
    do_log "OK wrote the mirror hooks to $SETTINGS_OUT"
  fi
}

# spl_desk_mirror_settings_json <spool-mirror.py>: the hooks object. The
# timeout is short on purpose: the hook forks the post and returns at once,
# and a hook that hangs must never hold a prompt or a turn.
spl_desk_mirror_settings_json() {
  python3 - "$1" <<'EOF_PY'
import json, shlex, sys
cmd = "python3 " + shlex.quote(sys.argv[1]) + " hook"
h = [{"hooks": [{"type": "command", "command": cmd, "timeout": 10}]}]
print(json.dumps({"hooks": {"UserPromptSubmit": h, "Stop": h}}, indent=2, sort_keys=True))
EOF_PY
}
