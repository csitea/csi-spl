#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the Mistral Vibe API key for the box's AGENT user
# @description (spec 110 2.3, seat-4 change 1): <agent-home>/.vibe/.env holds
# @description MISTRAL_API_KEY=<key>, file 600, dir 700, owned by the agent
# @description user, written atomically (temp file in that dir + mv); every
# @description other line already in the file is kept.
# @description The key comes from ONE of:
# @description   1. the terminal (default): read -s, never echoed. Refused when
# @description      stdin is not a tty, and inside a fleet agent tmux window
# @description      (its scrollback is read by agents)
# @description   2. MISTRAL_KEY_FILE=<path>: a file holding MISTRAL_API_KEY=<key>
# @description      or the bare key on one line (e.g. the owner's crs file)
# @description   3. MISTRAL_KEY_STDIN=1: the same, on stdin (fed over ssh)
# @description It never travels in argv, an exported env var or a log: the
# @description writer gets it on stdin. Prints a masked check only (length and
# @description the last 4 characters).
# @description TO_BOX=<box> writes it on that box instead, over ssh stdin to
# @description its agent user (AGENT_USER in its /etc/csi-spl-satellite.env,
# @description whose BOX_TAG must be <box>), the way do_box_copy_gcp_key does.
# @description MISTRAL_KEY_CHECK_URL (no default) adds a read-only GET with the
# @description key as a bearer header read from a file descriptor; unset, the
# @description check is skipped.
# @param MISTRAL_KEY_FILE (optional) - read the key from this file
# @param MISTRAL_KEY_STDIN (optional) - 1 reads the key from a non-tty stdin
# @param TO_BOX (optional) - another box of the fleet (its BOX_TAG, e.g. sat)
# @param BOX_SSH_<BOX> (optional) - the ssh destination of that box, default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite (do_satellite_ssh_config)
# @param SPOOL_AGENT_USER (optional) - the agent user, default from $SPOOL_ROOT/box.env
# @param MISTRAL_KEY_AGENT_HOME (optional) - the agent home, default its passwd entry
# @param MISTRAL_KEY_CHECK_URL (optional) - a read-only vendor endpoint to probe the key
# @example ./run -a do_set_mistral_key
# @example MISTRAL_KEY_FILE=$HOME/.mistral/crs ./run -a do_set_mistral_key
# @example MISTRAL_KEY_FILE=$HOME/.mistral/crs TO_BOX=sat ./run -a do_set_mistral_key
#------------------------------------------------------------------------------
do_set_mistral_key() {
  local xt=0; [[ $- == *x* ]] && xt=1; set +x
  local rc=0; spl_smk_main || rc=$?
  (( xt )) && set -x
  return "$rc"
}

spl_smk_main() {
  local key="" box="${TO_BOX:-}" out rc=0
  if [[ -n "$box" ]]; then
    [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] ||
      { do_log "FATAL TO_BOX must be a box id (e.g. sat), got: '$box'"; return 1; }
  fi
  spl_smk_read_key || return 1
  [[ -n "$key" ]] || { do_log "FATAL empty key: nothing written"; return 1; }
  [[ "$key" =~ ^[A-Za-z0-9._-]{16,256}$ ]] ||
    { do_log "FATAL the key is not 16..256 characters of [A-Za-z0-9._-] (length ${#key}): nothing written"; return 1; }
  local mask="length=${#key} last4=${key: -4}"
  do_log "INFO key read: $mask"
  if [[ -n "$box" ]]; then out="$(spl_smk_remote "$box" <<<"$key")" || rc=$?
  else out="$(spl_smk_local <<<"$key")" || rc=$?
  fi
  (( rc == 0 )) || { do_log "FATAL writing the key failed (exit $rc): $(sed -n 's/^result //p' <<<"$out")"; return 1; }
  spl_smk_verify "$out" "$mask" || return 1
  spl_smk_check "$key"
}

# spl_smk_read_key: sets the caller's $key from the file, stdin or terminal.
spl_smk_read_key() {
  if [[ -n "${MISTRAL_KEY_FILE:-}" ]]; then
    [[ -f "$MISTRAL_KEY_FILE" && -r "$MISTRAL_KEY_FILE" ]] ||
      { do_log "FATAL MISTRAL_KEY_FILE is no readable file: $MISTRAL_KEY_FILE"; return 1; }
    local m; m="$(stat -c %a "$MISTRAL_KEY_FILE")"
    [[ "${m: -2}" == 00 ]] || do_log "WARN $MISTRAL_KEY_FILE is readable beyond its owner (mode $m): chmod 600 it"
    key="$(spl_smk_parse <"$MISTRAL_KEY_FILE")"; return 0
  fi
  if [[ "${MISTRAL_KEY_STDIN:-0}" == 1 ]]; then key="$(spl_smk_parse)"; return 0; fi
  [[ -t 0 ]] || { do_log "FATAL stdin is not a terminal: type the key at the prompt, or give MISTRAL_KEY_FILE=<path> / MISTRAL_KEY_STDIN=1"; return 1; }
  if spl_smk_in_fleet_pane; then
    do_log "FATAL this is a fleet agent tmux window: its scrollback is read by agents. Run it in a plain ssh session (no tmux)"
    return 1
  fi
  IFS= read -r -s -p "Mistral API key (not echoed): " key; echo >&2
  key="$(spl_smk_parse <<<"$key")"
}

# spl_smk_parse: stdin -> the key: the value of the last MISTRAL_API_KEY= line
# (quotes stripped), else the first non-empty line; CR and blanks trimmed.
spl_smk_parse() {
  local line v="" first=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^(export[[:space:]]+)?MISTRAL_API_KEY=(.*)$ ]]; then
      v="${BASH_REMATCH[2]}"; v="${v#[\"\']}"; v="${v%[\"\']}"
    elif [[ -z "$first" ]]; then first="$line"
    fi
  done
  printf '%s' "${v:-$first}"
}

# spl_smk_in_fleet_pane: 0 when this terminal is a tmux window named like an
# agent (the agent-id grammar, optional "<box tag>: " prefix). A tmux that
# cannot name its window counts as a fleet pane: refuse on doubt.
spl_smk_in_fleet_pane() {
  [[ -n "${TMUX:-}" ]] || return 1
  local w; w="$(tmux display-message -p '#W' 2>/dev/null)" || return 0
  [[ "$w" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*:\ )?([acgqm]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+) ]]
}

# spl_smk_local: stdin = the key; runs the writer as the agent user here.
spl_smk_local() {
  local agent home
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { echo "result no-agent-user"; return 1; }
  home="${MISTRAL_KEY_AGENT_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { echo "result no-agent-home"; return 1; }
  if [[ "$(id -un)" == "$agent" ]]; then HOME="$home" bash -c "$(spl_smk_script)" set-mistral-key
  else sudo -n -u "$agent" -H bash -c "$(spl_smk_script)" set-mistral-key
  fi
}

# spl_smk_remote <box>: stdin = the key; the writer as that box's agent user.
spl_smk_remote() {
  local box="$1" k s dest envf tag agent
  k="$(tr 'a-z-' 'A-Z_' <<<"$box")"; s="BOX_SSH_$k"
  dest="${!s:-${SATELLITE_ALIAS:-satellite}}"
  envf="$(ssh -o BatchMode=yes "$dest" 'cat /etc/csi-spl-satellite.env' </dev/null 2>/dev/null)" ||
    { echo "result ssh-$dest-unreachable"; return 1; }
  tag="$(sed -n 's/^BOX_TAG=\([a-z0-9][a-z0-9-]*\)$/\1/p' <<<"$envf")"
  agent="$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  [[ "$tag" == "$box" ]] || { echo "result $dest-answers-as-${tag:-unknown}"; return 1; }
  [[ -n "$agent" ]] || { echo "result no-AGENT_USER-on-$box"; return 1; }
  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  ssh -o BatchMode=yes "$dest" "$(printf '%q ' sudo -n -u "$agent" -H bash -c "$(spl_smk_script)" set-mistral-key)"
}

# spl_smk_verify <writer output> <mask>: the path, modes, owner and masked key.
spl_smk_verify() {
  local out="$1" mask="$2" path mode dmode owner who got fails=0
  path="$(sed -n 's/^path //p' <<<"$out")"; mode="$(sed -n 's/^mode //p' <<<"$out")"
  dmode="$(sed -n 's/^dirmode //p' <<<"$out")"; owner="$(sed -n 's/^owner //p' <<<"$out")"
  who="$(sed -n 's/^user //p' <<<"$out")"; got="$(sed -n 's/^key //p' <<<"$out")"
  echo "verify path=${path:-MISSING} mode=${mode:-?} dir_mode=${dmode:-?} owner=${owner:-?} key=${got:-?}"
  [[ -n "$path" ]] || { do_log "FAIL no .env written"; fails=1; }
  [[ "$mode" == 600 ]] || { do_log "FAIL mode is ${mode:-?}, want 600"; fails=1; }
  [[ "$dmode" == 700 ]] || { do_log "FAIL dir mode is ${dmode:-?}, want 700"; fails=1; }
  [[ -n "$owner" && "$owner" == "$who" ]] || { do_log "FAIL owner is ${owner:-?}, want ${who:-?}"; fails=1; }
  [[ "$got" == "$mask" ]] || { do_log "FAIL the file holds key ${got:-?}, want $mask"; fails=1; }
  (( fails == 0 )) || return 1
  do_log "OK MISTRAL_API_KEY is in $path for $owner ($mask)"
}

# spl_smk_check <key>: optional read-only probe; the header goes through fd 3.
spl_smk_check() {
  local url="${MISTRAL_KEY_CHECK_URL:-}" code
  [[ -n "$url" ]] || { do_log "INFO key validity check skipped (MISTRAL_KEY_CHECK_URL not set)"; return 0; }
  code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H @/dev/fd/3 "$url" 3<<<"Authorization: Bearer $1" 2>/dev/null)"
  case "$code" in
    200) do_log "OK the vendor accepts the key (HTTP 200)" ;;
    401|403) do_log "FAIL the vendor refuses the key (HTTP $code): it is written, but dead"; return 1 ;;
    *) do_log "WARN key check inconclusive (HTTP ${code:-none}): the key is written" ;;
  esac
}

# The writer, run as the agent user in its own $HOME, the key on stdin. It
# keeps every other line of .vibe/.env, writes a temp file in the same dir and
# mv's it over the old one. It prints the facts, and the key masked only.
spl_smk_script() {
  cat <<'SCRIPT'
set +x; umask 077
IFS= read -r k || [ -n "$k" ] || { echo "result no-key-on-stdin"; exit 4; }
[ -n "$k" ] || { echo "result empty-key"; exit 4; }
d="$HOME/.vibe" f="$HOME/.vibe/.env"
mkdir -p "$d" && chmod 700 "$d" || { echo "result cannot-create-$d"; exit 1; }
if [ -L "$f" ]; then echo "result target-is-symlink"; exit 1; fi
t="$(mktemp "$d/.env.XXXXXX")" || { echo "result no-temp-file"; exit 1; }
{ if [ -f "$f" ]; then grep -v '^MISTRAL_API_KEY=' "$f" || true; fi
  printf 'MISTRAL_API_KEY=%s\n' "$k"; } >"$t" && chmod 600 "$t" && mv -f "$t" "$f" ||
  { rm -f "$t"; echo "result write-failed"; exit 1; }
v="$(sed -n 's/^MISTRAL_API_KEY=//p' "$f" | tail -n1)"
echo "path $f"
echo "mode $(stat -c %a "$f")"
echo "dirmode $(stat -c %a "$d")"
echo "owner $(stat -c %U "$f")"
echo "user $(id -un)"
echo "key length=${#v} last4=${v#"${v%????}"}"
SCRIPT
}
