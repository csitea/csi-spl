#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy ONE GCP service-account key file from this box to the
# @description agent user of another box of the fleet (t1 8451d159): the
# @description source is ~/.gcp/.csi/<KEY_NAME> here, the target is
# @description ~/.gcp/.csi/<KEY_NAME> in the home of the target box's agent
# @description user (its own $HOME), dir mode 700, file mode 600.
# @description   1. the box is reached by the satellite ssh alias
# @description      (do_satellite_ssh_config) or BOX_SSH_<BOX>; its own
# @description      /etc/csi-spl-satellite.env must name BOX_TAG=<TO_BOX> and
# @description      gives the AGENT_USER - a box that answers to another tag
# @description      is refused before a byte is sent
# @description   2. the key is streamed on ssh stdin into the target file: no
# @description      temp file on either box, never in argv, a log or stdout
# @description   3. a key already on the target is kept unless FORCE=1; an
# @description      identical one reads "already there"
# @description   4. verify on the target: the file, mode 600, the owner, its
# @description      client_email = the source's, sha256 equal. Prints the path,
# @description      mode, owner, the client_email DOMAIN and "sha256_equal=
# @description      yes|no"; never the key, its email or its sha.
# @description Dry run unless DRY_RUN=0 (the dry run makes no ssh call).
# @param KEY_NAME - required: one file name, ^key-csi-spl-[a-z0-9-]+\.json$ (no path, no glob)
# @param TO_BOX - required: the target box id (its BOX_TAG, e.g. sat)
# @param BOX_SSH_<BOX> (optional) - the ssh destination of that box (<BOX>: upper case, - as _), default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite (do_satellite_ssh_config)
# @param GCP_KEY_DIR (optional) - the source dir, default $HOME/.gcp/.csi
# @param FORCE (optional) - 1 replaces a different key on the target, default 0
# @param DRY_RUN (optional) - 1 (default) or 0
# @example KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat DRY_RUN=0 ./run -a do_box_copy_gcp_key
#------------------------------------------------------------------------------
do_box_copy_gcp_key() {
  do_require_bin jq sha256sum || return 1
  local name="${KEY_NAME:-}" box="${TO_BOX:-}" force="${FORCE:-0}" dry=1
  [[ "$name" =~ ^key-csi-spl-[a-z0-9-]+\.json$ ]] ||
    { do_log "FATAL KEY_NAME must be one file name matching ^key-csi-spl-[a-z0-9-]+\\.json\$ (no path, no glob), got: '$name'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] ||
    { do_log "FATAL TO_BOX must be a box id (e.g. sat), got: '$box'"; return 1; }
  [[ "$force" == 0 || "$force" == 1 ]] || { do_log "FATAL FORCE must be 0 or 1, got: '$force'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local src="${GCP_KEY_DIR:-$HOME/.gcp/.csi}/$name" sha email
  [[ -f "$src" && ! -L "$src" && -r "$src" ]] || { do_log "FATAL no readable key file $src"; return 1; }
  email="$(do_gcp_sa_key_email "$src")"
  [[ "$email" == *@*.* ]] || { do_log "FATAL $src is no service-account key (no client_email)"; return 1; }
  sha="$(sha256sum <"$src" | cut -d' ' -f1)"

  local k s dest
  k="$(tr 'a-z-' 'A-Z_' <<<"$box")"; s="BOX_SSH_$k"
  dest="${!s:-${SATELLITE_ALIAS:-satellite}}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: stream $name (client_email @${email#*@}) over ssh $dest to the agent user of box $box, ~/.gcp/.csi/$name mode 600$([[ $force == 1 ]] && echo ', replacing a different key (FORCE=1)')"
    do_log "OK DRY_RUN nothing was copied. Re-run with DRY_RUN=0 to copy."
    return 0
  fi

  local envf tag agent err
  err="$(mktemp)" || return 1
  envf="$(ssh -o BatchMode=yes "$dest" 'cat /etc/csi-spl-satellite.env' </dev/null 2>"$err")" ||
    { do_log "FATAL ssh $dest: cannot read its /etc/csi-spl-satellite.env: $(tail -n1 "$err")"; rm -f "$err"; return 1; }
  tag="$(sed -n 's/^BOX_TAG=\([a-z0-9][a-z0-9-]*\)$/\1/p' <<<"$envf")"
  agent="$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  [[ "$tag" == "$box" ]] || { do_log "FATAL ssh $dest answers as box '${tag:-?}', not '$box': nothing sent"; rm -f "$err"; return 1; }
  [[ -n "$agent" ]] || { do_log "FATAL box $box names no AGENT_USER in /etc/csi-spl-satellite.env: nothing sent"; rm -f "$err"; return 1; }

  local out rc=0 result
  out="$(spl_bcgk_on "$dest" "$agent" put "$name" "$sha" "$force" <"$src" 2>"$err")" || rc=$?
  result="$(sed -n 's/^result //p' <<<"$out")"
  case "$rc:$result" in
    0:copied) do_log "INFO copied $name to $agent@$box" ;;
    0:already-there) do_log "INFO already there: $name on $agent@$box is identical (sha256 equal), not rewritten" ;;
    3:exists-differs) do_log "FATAL $name on $agent@$box exists and differs: kept (FORCE=1 replaces it)"; rm -f "$err"; return 1 ;;
    *) do_log "FATAL copy to $agent@$box failed (exit $rc, ${result:-no result}): $(tail -n1 "$err")"; rm -f "$err"; return 1 ;;
  esac

  out="$(spl_bcgk_on "$dest" "$agent" verify "$name" "" "" </dev/null 2>"$err")"
  rm -f "$err"
  local path mode owner dmode tsha temail eq=no fails=0
  path="$(sed -n 's/^path //p' <<<"$out")"; mode="$(sed -n 's/^mode //p' <<<"$out")"
  owner="$(sed -n 's/^owner //p' <<<"$out")"; dmode="$(sed -n 's/^dirmode //p' <<<"$out")"
  tsha="$(sed -n 's/^sha //p' <<<"$out")"; temail="$(sed -n 's/^email //p' <<<"$out")"
  [[ -n "$tsha" && "$tsha" == "$sha" ]] && eq=yes
  echo "verify box=$box path=${path:-MISSING} mode=${mode:-?} dir_mode=${dmode:-?} owner=${owner:-?} client_email=@${temail#*@} sha256_equal=$eq"
  [[ -n "$path" ]] || { do_log "FAIL the key is not on $box"; fails=1; }
  [[ "$mode" == 600 ]] || { do_log "FAIL mode is ${mode:-?}, want 600"; fails=1; }
  [[ "$dmode" == 700 ]] || { do_log "FAIL dir mode is ${dmode:-?}, want 700"; fails=1; }
  [[ "$owner" == "$agent" ]] || { do_log "FAIL owner is ${owner:-?}, want $agent"; fails=1; }
  [[ "$temail" == "$email" ]] || { do_log "FAIL the target's client_email differs from the source's"; fails=1; }
  [[ "$eq" == yes ]] || { do_log "FAIL sha256 differs"; fails=1; }
  (( fails == 0 )) || return 1
  do_log "OK $name is on $box for $agent, verified"
}

# spl_bcgk_on <dest> <agent> <op> <name> <sha> <force>: one step as the agent
# user on the target box (stdin = the key for put). The key travels on stdin
# only; argv carries the name, its sha256 and the flag.
spl_bcgk_on() {
  local dest="$1" agent="$2"; shift 2
  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  ssh -o BatchMode=yes "$dest" "$(printf '%q ' sudo -n -u "$agent" -H bash -c "$(spl_bcgk_script)" box-copy-gcp-key "$@")"
}

# The step script on the target: put | verify, under umask 077, in the agent
# user's own $HOME. put writes stdin straight into the file (no temp file),
# and removes it again when the bytes do not hash to the sha sent.
spl_bcgk_script() {
  cat <<'SCRIPT'
op="$1" name="$2" sha="$3" force="$4"
umask 077
d="$HOME/.gcp/.csi" f="$HOME/.gcp/.csi/$name"
case "$op" in
  put)
    mkdir -p "$d" && chmod 700 "$HOME/.gcp" "$d" || exit 1
    if [ -L "$f" ]; then echo "result target-is-symlink"; exit 1; fi
    if [ -e "$f" ]; then
      if [ "$(sha256sum <"$f" | cut -d' ' -f1)" = "$sha" ]; then chmod 600 "$f"; echo "result already-there"; exit 0; fi
      [ "$force" = 1 ] || { echo "result exists-differs"; exit 3; }
    fi
    cat >"$f" && chmod 600 "$f" || { rm -f "$f"; exit 1; }
    [ "$(sha256sum <"$f" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$f"; echo "result short-write"; exit 1; }
    echo "result copied" ;;
  verify)
    [ -f "$f" ] || exit 1
    echo "path $f"
    echo "mode $(stat -c %a "$f")"
    echo "owner $(stat -c %U "$f")"
    echo "dirmode $(stat -c %a "$d")"
    echo "sha $(sha256sum <"$f" | cut -d' ' -f1)"
    echo "email $(jq -r '.client_email // ""' "$f")" ;;
  *) exit 2 ;;
esac
SCRIPT
}
