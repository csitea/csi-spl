#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the Gemini API key Nano Banana uses (spec 111 D-Q3,
# @description T011) for the box's AGENT user: <agent-home>/.nano-banana/crs
# @description holds ONE line GEMINI_API_KEY=<key>, file 600, dir 700, owned
# @description by the agent user, written atomically (temp file in that dir +
# @description mv). Modelled on do_set_mistral_key (spec 110).
# @description The key comes from a file only, never a pane paste:
# @description NANO_BANANA_KEY_FILE=<path>, default $HOME/.gemini/.csi/api_key
# @description (the box user's), holding GEMINI_API_KEY=<key> (or
# @description GOOGLE_API_KEY=<key>) or the bare key on one line.
# @description It never travels in argv, an exported env var or a log: the
# @description writer gets it on stdin. Prints a masked check only (length and
# @description the last 4 characters).
# @description TO_BOX=<box> writes it on that box instead, over ssh stdin to
# @description its agent user (AGENT_USER in its /etc/csi-spl-satellite.env,
# @description whose BOX_TAG must be <box>), the way do_set_mistral_key does.
# @param NANO_BANANA_KEY_FILE (optional) - the key file, default $HOME/.gemini/.csi/api_key
# @param TO_BOX (optional) - another box of the fleet (its BOX_TAG, e.g. sat)
# @param BOX_SSH_<BOX> (optional) - the ssh destination of that box, default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite (do_satellite_ssh_config)
# @param SPOOL_AGENT_USER (optional) - the agent user, default from $SPOOL_ROOT/box.env
# @param NANO_BANANA_KEY_AGENT_HOME (optional) - the agent home, default its passwd entry
# @example ./run -a do_set_nano_banana_key
# @example TO_BOX=sat ./run -a do_set_nano_banana_key
#------------------------------------------------------------------------------
do_set_nano_banana_key() {
  local xt=0; [[ $- == *x* ]] && xt=1; set +x
  local rc=0; spl_snb_main || rc=$?
  (( xt )) && set -x
  return "$rc"
}

spl_snb_main() {
  local key="" box="${TO_BOX:-}" out rc=0
  if [[ -n "$box" ]]; then
    [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] ||
      { do_log "FATAL TO_BOX must be a box id (e.g. sat), got: '$box'"; return 1; }
  fi
  spl_snb_read_key || return 1
  [[ -n "$key" ]] || { do_log "FATAL empty key: nothing written"; return 1; }
  [[ "$key" =~ ^[A-Za-z0-9._-]{16,256}$ ]] ||
    { do_log "FATAL the key is not 16..256 characters of [A-Za-z0-9._-] (length ${#key}): nothing written"; return 1; }
  local mask="length=${#key} last4=${key: -4}"
  do_log "INFO key read: $mask"
  if [[ -n "$box" ]]; then out="$(spl_snb_remote "$box" <<<"$key")" || rc=$?
  else out="$(spl_snb_local <<<"$key")" || rc=$?
  fi
  (( rc == 0 )) || { do_log "FATAL writing the key failed (exit $rc): $(sed -n 's/^result //p' <<<"$out")"; return 1; }
  spl_snb_verify "$out" "$mask"
}

# spl_snb_read_key: sets the caller's $key from the key file.
spl_snb_read_key() {
  local f="${NANO_BANANA_KEY_FILE:-$HOME/.gemini/.csi/api_key}" m
  [[ -f "$f" && -r "$f" ]] ||
    { do_log "FATAL NANO_BANANA_KEY_FILE is no readable file: $f"; return 1; }
  m="$(stat -c %a "$f")"
  [[ "${m: -2}" == 00 ]] || do_log "WARN $f is readable beyond its owner (mode $m): chmod 600 it"
  key="$(spl_snb_parse <"$f")"
}

# spl_snb_parse: stdin -> the key: the value of the last GEMINI_API_KEY= or
# GOOGLE_API_KEY= line (quotes stripped), else the first non-empty line; CR
# and blanks trimmed.
spl_snb_parse() {
  local line v="" first=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^(export[[:space:]]+)?(GEMINI|GOOGLE)_API_KEY=(.*)$ ]]; then
      v="${BASH_REMATCH[3]}"; v="${v#[\"\']}"; v="${v%[\"\']}"
    elif [[ -z "$first" ]]; then first="$line"
    fi
  done
  printf '%s' "${v:-$first}"
}

# spl_snb_local: stdin = the key; runs the writer as the agent user here.
spl_snb_local() {
  local agent home
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { echo "result no-agent-user"; return 1; }
  home="${NANO_BANANA_KEY_AGENT_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { echo "result no-agent-home"; return 1; }
  if [[ "$(id -un)" == "$agent" ]]; then HOME="$home" bash -c "$(spl_snb_script)" set-nano-banana-key
  else sudo -n -u "$agent" -H bash -c "$(spl_snb_script)" set-nano-banana-key
  fi
}

# spl_snb_remote <box>: stdin = the key; the writer as that box's agent user.
spl_snb_remote() {
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
  ssh -o BatchMode=yes "$dest" "$(printf '%q ' sudo -n -u "$agent" -H bash -c "$(spl_snb_script)" set-nano-banana-key)"
}

# spl_snb_verify <writer output> <mask>: path, modes, owner, lines, masked key.
spl_snb_verify() {
  local out="$1" mask="$2" path mode dmode owner who lines got fails=0
  path="$(sed -n 's/^path //p' <<<"$out")"; mode="$(sed -n 's/^mode //p' <<<"$out")"
  dmode="$(sed -n 's/^dirmode //p' <<<"$out")"; owner="$(sed -n 's/^owner //p' <<<"$out")"
  who="$(sed -n 's/^user //p' <<<"$out")"; lines="$(sed -n 's/^lines //p' <<<"$out")"
  got="$(sed -n 's/^key //p' <<<"$out")"
  echo "verify path=${path:-MISSING} mode=${mode:-?} dir_mode=${dmode:-?} owner=${owner:-?} lines=${lines:-?} key=${got:-?}"
  [[ -n "$path" ]] || { do_log "FAIL no crs written"; fails=1; }
  [[ "$mode" == 600 ]] || { do_log "FAIL mode is ${mode:-?}, want 600"; fails=1; }
  [[ "$dmode" == 700 ]] || { do_log "FAIL dir mode is ${dmode:-?}, want 700"; fails=1; }
  [[ -n "$owner" && "$owner" == "$who" ]] || { do_log "FAIL owner is ${owner:-?}, want ${who:-?}"; fails=1; }
  [[ "$lines" == 1 ]] || { do_log "FAIL the crs holds ${lines:-?} lines, want 1"; fails=1; }
  [[ "$got" == "$mask" ]] || { do_log "FAIL the file holds key ${got:-?}, want $mask"; fails=1; }
  (( fails == 0 )) || return 1
  do_log "OK GEMINI_API_KEY is in $path for $owner ($mask)"
}

# The writer, run as the agent user in its own $HOME, the key on stdin. It
# writes ONE line to a temp file in the same dir and mv's it over the old
# crs. It prints the facts, and the key masked only.
spl_snb_script() {
  cat <<'SCRIPT'
set +x; umask 077
IFS= read -r k || [ -n "$k" ] || { echo "result no-key-on-stdin"; exit 4; }
[ -n "$k" ] || { echo "result empty-key"; exit 4; }
d="$HOME/.nano-banana" f="$HOME/.nano-banana/crs"
mkdir -p "$d" && chmod 700 "$d" || { echo "result cannot-create-$d"; exit 1; }
if [ -L "$f" ]; then echo "result target-is-symlink"; exit 1; fi
t="$(mktemp "$d/.crs.XXXXXX")" || { echo "result no-temp-file"; exit 1; }
printf 'GEMINI_API_KEY=%s\n' "$k" >"$t" && chmod 600 "$t" && mv -f "$t" "$f" ||
  { rm -f "$t"; echo "result write-failed"; exit 1; }
v="$(sed -n 's/^GEMINI_API_KEY=//p' "$f" | tail -n1)"
echo "path $f"
echo "mode $(stat -c %a "$f")"
echo "dirmode $(stat -c %a "$d")"
echo "owner $(stat -c %U "$f")"
echo "user $(id -un)"
echo "lines $(wc -l <"$f")"
echo "key length=${#v} last4=${v#"${v%????}"}"
SCRIPT
}
