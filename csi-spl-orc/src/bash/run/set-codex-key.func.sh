#!/bin/bash
#------------------------------------------------------------------------------
# @description Log the box's AGENT user into the OpenAI Codex CLI with an API
# @description key (spec 161 2.2.5): the CLI's own key login,
# @description `codex login --with-api-key`, which reads the key on stdin and
# @description writes the CLI's login file <agent-home>/.codex/auth.json (the
# @description cnf auth marker, kept by cli_auth_credentials_store = "file").
# @description The fleet's default is the owner's SUBSCRIPTION login
# @description (`codex login --device-auth` as the agent user, owner msg
# @description aca6a7c5); this action is the key path only. It never writes
# @description the file itself and it replaces a subscription login.
# @description The key comes from ONE of:
# @description   1. the terminal (default): read -s, never echoed. Refused when
# @description      stdin is not a tty, and inside a fleet agent tmux window
# @description      (its scrollback is read by agents)
# @description   2. CODEX_KEY_FILE=<path>: a file holding OPENAI_API_KEY=<key>
# @description      or the bare key on one line
# @description   3. CODEX_KEY_STDIN=1: the same, on stdin
# @description It never travels in argv, an exported env var or a log: codex
# @description gets it on stdin, run with OPENAI_API_KEY and CODEX_API_KEY
# @description unset. Prints a masked check only (length, last 4) and the
# @description login file's mode and owner, never its content.
# @param CODEX_KEY_FILE (optional) - read the key from this file
# @param CODEX_KEY_STDIN (optional) - 1 reads the key from a non-tty stdin
# @param SPOOL_AGENT_USER (optional) - the agent user, default from $SPOOL_ROOT/box.env
# @param CODEX_KEY_AGENT_HOME (optional) - the agent home, default its passwd entry
# @param CODEX_BIN (optional) - the codex binary, default codex on the agent's PATH or ~/.local/bin
# @example ./run -a do_set_codex_key
# @example CODEX_KEY_FILE=$HOME/.openai/crs ./run -a do_set_codex_key
#------------------------------------------------------------------------------
do_set_codex_key() {
  local xt=0; [[ $- == *x* ]] && xt=1; set +x
  local rc=0; spl_sck_main || rc=$?
  (( xt )) && set -x
  return "$rc"
}

spl_sck_main() {
  local key="" agent home out rc=0
  spl_sck_read_key || return 1
  [[ -n "$key" ]] || { do_log "FATAL empty key: nothing written"; return 1; }
  [[ "$key" =~ ^[A-Za-z0-9._-]{16,256}$ ]] ||
    { do_log "FATAL the key is not 16..256 characters of [A-Za-z0-9._-] (length ${#key}): nothing written"; return 1; }
  do_log "INFO key read: length=${#key} last4=${key: -4}"
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { do_log "FATAL no agent user: set SPOOL_AGENT_USER"; return 1; }
  home="${CODEX_KEY_AGENT_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { do_log "FATAL no home for the agent user $agent: $home"; return 1; }
  if [[ "$(id -un)" == "$agent" ]]; then out="$(HOME="$home" bash -c "$(spl_sck_script)" set-codex-key <<<"$key")" || rc=$?
  else out="$(sudo -n -u "$agent" -H env CODEX_BIN="${CODEX_BIN:-}" bash -c "$(spl_sck_script)" set-codex-key <<<"$key")" || rc=$?
  fi
  key=""
  (( rc == 0 )) || { do_log "FATAL codex login --with-api-key failed (exit $rc): $(sed -n 's/^result //p' <<<"$out")"; return 1; }
  spl_sck_verify "$out"
}

# spl_sck_read_key: sets the caller's $key from the file, stdin or terminal.
spl_sck_read_key() {
  if [[ -n "${CODEX_KEY_FILE:-}" ]]; then
    [[ -f "$CODEX_KEY_FILE" && -r "$CODEX_KEY_FILE" ]] ||
      { do_log "FATAL CODEX_KEY_FILE is no readable file: $CODEX_KEY_FILE"; return 1; }
    local m; m="$(stat -c %a "$CODEX_KEY_FILE")"
    [[ "${m: -2}" == 00 ]] || do_log "WARN $CODEX_KEY_FILE is readable beyond its owner (mode $m): chmod 600 it"
    key="$(spl_sck_parse <"$CODEX_KEY_FILE")"; return 0
  fi
  if [[ "${CODEX_KEY_STDIN:-0}" == 1 ]]; then key="$(spl_sck_parse)"; return 0; fi
  [[ -t 0 ]] || { do_log "FATAL stdin is not a terminal: type the key at the prompt, or give CODEX_KEY_FILE=<path> / CODEX_KEY_STDIN=1"; return 1; }
  if spl_sck_in_fleet_pane; then
    do_log "FATAL this is a fleet agent tmux window: its scrollback is read by agents. Run it in a plain ssh session (no tmux)"
    return 1
  fi
  IFS= read -r -s -p "OpenAI API key (not echoed): " key; echo >&2
  key="$(spl_sck_parse <<<"$key")"
}

# spl_sck_parse: stdin -> the key: the value of the last OPENAI_API_KEY= line
# (quotes stripped), else the first non-empty line; CR and blanks trimmed.
spl_sck_parse() {
  local line v="" first=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^(export[[:space:]]+)?OPENAI_API_KEY=(.*)$ ]]; then
      v="${BASH_REMATCH[2]}"; v="${v#[\"\']}"; v="${v%[\"\']}"
    elif [[ -z "$first" ]]; then first="$line"
    fi
  done
  printf '%s' "${v:-$first}"
}

# spl_sck_in_fleet_pane: 0 when this terminal is a tmux window named like an
# agent (the agent-id grammar, optional "<box tag>: " prefix). A tmux that
# cannot name its window counts as a fleet pane: refuse on doubt.
spl_sck_in_fleet_pane() {
  [[ -n "${TMUX:-}" ]] || return 1
  local w; w="$(tmux display-message -p '#W' 2>/dev/null)" || return 0
  [[ "$w" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*:\ )?([acgmoqu]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+) ]]
}

# spl_sck_verify <runner output>: the login file's mode and owner.
spl_sck_verify() {
  local out="$1" path mode owner who fails=0
  path="$(sed -n 's/^path //p' <<<"$out")"; mode="$(sed -n 's/^mode //p' <<<"$out")"
  owner="$(sed -n 's/^owner //p' <<<"$out")"; who="$(sed -n 's/^user //p' <<<"$out")"
  echo "verify path=${path:-MISSING} mode=${mode:-?} owner=${owner:-?}"
  [[ -n "$path" ]] || { do_log "FAIL codex wrote no $path"; fails=1; }
  [[ "$mode" == 600 ]] || { do_log "FAIL mode is ${mode:-?}, want 600"; fails=1; }
  [[ -n "$owner" && "$owner" == "$who" ]] || { do_log "FAIL owner is ${owner:-?}, want ${who:-?}"; fails=1; }
  (( fails == 0 )) || return 1
  do_log "OK codex is logged in with an API key for $owner ($path)"
}

# The runner, as the agent user in its own $HOME, the key on stdin: codex's
# own key login, then the facts of its login file, never its content.
spl_sck_script() {
  cat <<'SCRIPT'
set +x; umask 077
c="${CODEX_BIN:-}"
[ -n "$c" ] || c="$(command -v codex 2>/dev/null)"
[ -n "$c" ] || [ ! -x "$HOME/.local/bin/codex" ] || c="$HOME/.local/bin/codex"
[ -n "$c" ] || { echo "result no-codex-binary-run-do_install_openai_codex"; exit 4; }
f="$HOME/.codex/auth.json"
env -u OPENAI_API_KEY -u CODEX_API_KEY "$c" login --with-api-key >/dev/null 2>&1 || { echo "result codex-login-failed"; exit 1; }
[ -f "$f" ] || { echo "result no-$f-check-cli_auth_credentials_store"; exit 1; }
chmod 600 "$f"
echo "path $f"
echo "mode $(stat -c %a "$f")"
echo "owner $(stat -c %U "$f")"
echo "user $(id -un)"
SCRIPT
}
