#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy ONE GCP service-account key file from the running user to
# @description a SECOND local user of this same box (SPL-2901): a box runs prd
# @description jobs as two users (the admin user's crontab and the agent
# @description user), each reading the key under its own $HOME, and
# @description do_box_copy_gcp_key writes only the other box's agent user. The
# @description source is ~/.gcp/.csi/<KEY_NAME> of the running user, the
# @description target ~/.gcp/.csi/<KEY_NAME> in TO_USER's own home, dir mode
# @description 700, file mode 600, owner TO_USER.
# @description   1. TO_USER must be a local user with a home dir; root (by name
# @description      or uid 0) and the running user are refused
# @description   2. the key is streamed on stdin into `sudo -n -u TO_USER -H`:
# @description      no temp file, never in argv, a log or stdout
# @description   3. an identical target reads "already there"; a different one
# @description      is kept unless FORCE=1, which moves it to <file>.prev first
# @description   4. verify as TO_USER: the file, mode 600, dir mode 700, the
# @description      owner, its client_email = the source's, sha256 equal. Prints
# @description      the path, modes, owner, the client_email DOMAIN and
# @description      "sha256_equal=yes|no" (do_box_copy_gcp_key's shape); never
# @description      the key, its email or its sha.
# @description Dry run unless DRY_RUN=0 (the dry run makes no sudo call).
# @param KEY_NAME - required: one file name, ^key-csi-spl-[a-z0-9-]+\.json$ (no path, no glob)
# @param TO_USER - required: the second local user of this box (e.g. <AGENT_USER>)
# @param GCP_KEY_DIR (optional) - the source dir, default $HOME/.gcp/.csi
# @param FORCE (optional) - 1 replaces a different key on the target (kept as .prev), default 0
# @param DRY_RUN (optional) - 1 (default) or 0
# @example KEY_NAME=key-csi-spl-prd.json TO_USER=<AGENT_USER> DRY_RUN=0 ./run -a do_gcp_key_copy_local_user
#------------------------------------------------------------------------------
do_gcp_key_copy_local_user() {
  do_require_bin jq sha256sum getent sudo || return 1
  local name="${KEY_NAME:-}" to="${TO_USER:-}" force="${FORCE:-0}" dry=1 me
  me="$(id -un)"
  [[ "$name" =~ ^key-csi-spl-[a-z0-9-]+\.json$ ]] ||
    { do_log "FATAL KEY_NAME must be one file name matching ^key-csi-spl-[a-z0-9-]+\\.json\$ (no path, no glob), got: '$name'"; return 1; }
  [[ "$force" == 0 || "$force" == 1 ]] || { do_log "FATAL FORCE must be 0 or 1, got: '$force'"; return 1; }
  spl_gkclu_check_user "$to" "$me" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local src="${GCP_KEY_DIR:-$HOME/.gcp/.csi}/$name" sha email
  [[ -f "$src" && ! -L "$src" && -r "$src" ]] || { do_log "FATAL no readable key file $src"; return 1; }
  email="$(do_gcp_sa_key_email "$src")"
  [[ "$email" == *@*.* ]] || { do_log "FATAL $src is no service-account key (no client_email)"; return 1; }
  sha="$(sha256sum <"$src" | cut -d' ' -f1)"

  if (( dry )); then
    do_log "INFO DRY_RUN would: copy $name (client_email @${email#*@}) from $me to $to on this box, ~$to/.gcp/.csi/$name mode 600$([[ $force == 1 ]] && echo ', a different key kept as .prev (FORCE=1)')"
    do_log "OK DRY_RUN nothing was copied. Re-run with DRY_RUN=0 to copy."
    return 0
  fi

  local out rc=0 result err
  err="$(mktemp)" || return 1
  out="$(spl_gkclu_as "$to" put "$name" "$sha" "$force" <"$src" 2>"$err")" || rc=$?
  result="$(sed -n 's/^result //p' <<<"$out")"
  case "$rc:$result" in
    0:copied) do_log "INFO copied $name to $to" ;;
    0:copied-prev) do_log "INFO copied $name to $to; its different key is kept as $name.prev (FORCE=1)" ;;
    0:already-there) do_log "INFO already there: $name of $to is identical (sha256 equal), not rewritten" ;;
    3:exists-differs) do_log "FATAL $name of $to exists and differs: kept (FORCE=1 replaces it, keeping it as $name.prev)"; rm -f "$err"; return 1 ;;
    *) do_log "FATAL copy to $to failed (exit $rc, ${result:-no result}): $(tail -n1 "$err")"; rm -f "$err"; return 1 ;;
  esac
  out="$(spl_gkclu_as "$to" verify "$name" "" "" </dev/null 2>"$err")"
  rm -f "$err"
  spl_gkclu_verify "$out" "$to" "$email" "$sha" || return 1
  do_log "OK $name is in the key dir of $to on this box, verified"
}

# spl_gkclu_check_user <to> <me>: TO_USER is a local user with a home dir,
# neither root (by name or uid 0) nor the running user.
spl_gkclu_check_user() {
  local to="$1" me="$2" pw uid home
  [[ "$to" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL TO_USER must be a local user name, got: '$to'"; return 1; }
  [[ "$to" != root ]] || { do_log "FATAL TO_USER=root is refused"; return 1; }
  [[ "$to" != "$me" ]] || { do_log "FATAL TO_USER is the running user ($me): nothing to copy"; return 1; }
  pw="$(getent passwd "$to")" || { do_log "FATAL TO_USER '$to' is no local user"; return 1; }
  uid="$(cut -d: -f3 <<<"$pw")"; home="$(cut -d: -f6 <<<"$pw")"
  [[ "$uid" != 0 ]] || { do_log "FATAL TO_USER '$to' has uid 0: refused"; return 1; }
  [[ -n "$home" && "$home" != / && -d "$home" ]] || { do_log "FATAL TO_USER '$to' has no home dir ('$home')"; return 1; }
}

# spl_gkclu_verify <verify output> <to> <email> <sha>: the verify line, then
# one FAIL per check that does not hold.
spl_gkclu_verify() {
  local out="$1" to="$2" email="$3" sha="$4"
  local path mode owner dmode tsha temail eq=no fails=0
  path="$(sed -n 's/^path //p' <<<"$out")"; mode="$(sed -n 's/^mode //p' <<<"$out")"
  owner="$(sed -n 's/^owner //p' <<<"$out")"; dmode="$(sed -n 's/^dirmode //p' <<<"$out")"
  tsha="$(sed -n 's/^sha //p' <<<"$out")"; temail="$(sed -n 's/^email //p' <<<"$out")"
  [[ -n "$tsha" && "$tsha" == "$sha" ]] && eq=yes
  echo "verify user=$to path=${path:-MISSING} mode=${mode:-?} dir_mode=${dmode:-?} owner=${owner:-?} client_email=@${temail#*@} sha256_equal=$eq"
  [[ -n "$path" ]] || { do_log "FAIL the key is not in the key dir of $to"; fails=1; }
  [[ "$mode" == 600 ]] || { do_log "FAIL mode is ${mode:-?}, want 600"; fails=1; }
  [[ "$dmode" == 700 ]] || { do_log "FAIL dir mode is ${dmode:-?}, want 700"; fails=1; }
  [[ "$owner" == "$to" ]] || { do_log "FAIL owner is ${owner:-?}, want $to"; fails=1; }
  [[ "$temail" == "$email" ]] || { do_log "FAIL the target's client_email differs from the source's"; fails=1; }
  [[ "$eq" == yes ]] || { do_log "FAIL sha256 differs"; fails=1; }
  (( fails == 0 ))
}

# spl_gkclu_as <to> <op> <name> <sha> <force>: one step as TO_USER in its own
# $HOME (stdin = the key for put); argv carries the name, its sha256 and the flag.
spl_gkclu_as() {
  local to="$1"; shift
  sudo -n -u "$to" -H bash -c "$(spl_gkclu_script)" gcp-key-copy-local-user "$@"
}

# The step script run as TO_USER: put | verify, under umask 077. put writes
# stdin straight into the file; with FORCE=1 a different file moves to .prev
# first and comes back when the write fails or does not hash to the sha sent.
spl_gkclu_script() {
  cat <<'SCRIPT'
op="$1" name="$2" sha="$3" force="$4"
umask 077
d="$HOME/.gcp/.csi" f="$HOME/.gcp/.csi/$name"
case "$op" in
  put)
    mkdir -p "$d" && chmod 700 "$HOME/.gcp" "$d" || exit 1
    if [ -L "$f" ] || [ -L "$f.prev" ]; then echo "result target-is-symlink"; exit 1; fi
    res=copied
    if [ -e "$f" ]; then
      if [ "$(sha256sum <"$f" | cut -d' ' -f1)" = "$sha" ]; then chmod 600 "$f"; echo "result already-there"; exit 0; fi
      [ "$force" = 1 ] || { echo "result exists-differs"; exit 3; }
      mv -f "$f" "$f.prev" && chmod 600 "$f.prev" || exit 1
      res=copied-prev
    fi
    undo() { rm -f "$f"; if [ "$res" = copied-prev ]; then mv -f "$f.prev" "$f"; fi; }
    cat >"$f" && chmod 600 "$f" || { undo; exit 1; }
    [ "$(sha256sum <"$f" | cut -d' ' -f1)" = "$sha" ] || { undo; echo "result short-write"; exit 1; }
    echo "result $res" ;;
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
