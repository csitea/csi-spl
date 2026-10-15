#!/bin/bash
#------------------------------------------------------------------------------
# @description Pull the SPL-1874 private overlay (csi-spl-doc/doc/md/
# @description private-overlay.md) from the satellite to THIS box, for both box
# @description users. The satellite cannot reach this box; this box can ssh it.
# @description   1. the box is reached by BOX_SSH_<BOX> or the satellite alias;
# @description      its /etc/csi-spl-satellite.env must name BOX_TAG=<FROM_BOX>
# @description      and gives OWNER_USER and AGENT_USER, the two users pulled
# @description   2. both source files must exist and be non-empty before
# @description      anything is written here (fail fast, naming the user)
# @description   3. each file streams ssh stdout -> sudo on this box into
# @description      ~<user>/.gcp/.csi/csi-spl-private.yaml, owned by that user,
# @description      mode 600: never in a variable, argv, a log or stdout
# @description   4. verify: mode 600, owner, sha256 equal to the source's.
# @description      Prints the path, mode, owner and "sha256_equal=yes|no";
# @description      never the content or its sha.
# @description A local copy that differs is replaced: the satellite holds the
# @description master copy. Dry run unless DRY_RUN=0 (it reads the source
# @description shas over ssh, writes nothing).
# @param FROM_BOX (optional) - the source box id (its BOX_TAG), default sat
# @param BOX_SSH_<BOX> (optional) - the ssh destination of that box (<BOX>: upper case, - as _), default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite (do_satellite_ssh_config)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DRY_RUN=0 ./run -a do_spl_private_overlay_pull
#------------------------------------------------------------------------------
do_spl_private_overlay_pull() {
  do_require_bin sha256sum getent || return 1
  local box="${FROM_BOX:-sat}" dry=1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL FROM_BOX must be a box id (e.g. sat), got: '$box'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local dest users_line
  dest="$(spl_ppo_dest "$box")"
  users_line="$(spl_ppo_box_users "$dest" "$box")" || return 1
  local -a users; read -r -a users <<<"$users_line"

  local -A src_sha home
  local u h
  for u in "${users[@]}"; do
    h="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$h" ]] || { do_log "FATAL user $u (of box $box) does not exist here: nothing pulled"; return 1; }
    home[$u]="$h"
    src_sha[$u]="$(spl_ppo_remote "$dest" "$u" sha </dev/null 2>/dev/null)"
    [[ "${src_sha[$u]}" =~ ^[0-9a-f]{64}$ ]] ||
      { do_log "FATAL no overlay for $u on $box (~$u/.gcp/.csi/csi-spl-private.yaml missing, empty or a symlink): nothing pulled"; return 1; }
  done
  if (( dry )); then
    for u in "${users[@]}"; do
      do_log "INFO DRY_RUN would: pull $u@$box:~/.gcp/.csi/csi-spl-private.yaml to ${home[$u]}/.gcp/.csi/csi-spl-private.yaml, owner $u, mode 600"
    done
    do_log "OK DRY_RUN nothing was pulled. Re-run with DRY_RUN=0 to pull."
    return 0
  fi

  local fails=0
  for u in "${users[@]}"; do
    spl_ppo_pull_one "$dest" "$u" "${home[$u]}" "${src_sha[$u]}" || fails=1
  done
  (( fails == 0 )) || return 1
  do_log "OK the private overlay of ${users[*]} is pulled from $box, verified"
}

# spl_ppo_dest <box> -> its ssh destination: BOX_SSH_<BOX>, else the satellite alias.
spl_ppo_dest() {
  local k s
  k="$(tr 'a-z-' 'A-Z_' <<<"$1")"; s="BOX_SSH_$k"
  echo "${!s:-${SATELLITE_ALIAS:-satellite}}"
}

# spl_ppo_box_users <dest> <box> -> "<owner> [<agent>]" from the box's
# /etc/csi-spl-satellite.env, after checking it answers as <box>; its
# FATALs go to stderr, stdout is the caller's value.
spl_ppo_box_users() {
  local dest="$1" box="$2" envf tag owner agent err
  err="$(mktemp)" || return 1
  envf="$(ssh -o BatchMode=yes "$dest" 'cat /etc/csi-spl-satellite.env' </dev/null 2>"$err")" ||
    { do_log >&2 "FATAL ssh $dest: cannot read its /etc/csi-spl-satellite.env: $(tail -n1 "$err")"; rm -f "$err"; return 1; }
  rm -f "$err"
  tag="$(sed -n 's/^BOX_TAG=\([a-z0-9][a-z0-9-]*\)$/\1/p' <<<"$envf")"
  owner="$(sed -n 's/^OWNER_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  agent="$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  [[ "$tag" == "$box" ]] || { do_log >&2 "FATAL ssh $dest answers as box '${tag:-?}', not '$box': nothing pulled"; return 1; }
  [[ -n "$owner" && -n "$agent" ]] ||
    { do_log >&2 "FATAL box $box names no OWNER_USER or AGENT_USER in /etc/csi-spl-satellite.env: nothing pulled"; return 1; }
  if [[ "$agent" == "$owner" ]]; then echo "$owner"; else echo "$owner $agent"; fi
}

# spl_ppo_pull_one <dest> <user> <home> <sha>: stream one overlay from the
# source box into this box's copy, then verify it; prints the verify line.
spl_ppo_pull_one() {
  local dest="$1" u="$2" h="$3" sha="$4" out rc result
  out="$(spl_ppo_remote "$dest" "$u" cat </dev/null 2>/dev/null | spl_ppo_local put "$u" "$h" "$sha" 2>/dev/null)"
  rc=$?; result="$(sed -n 's/^result //p' <<<"$out")"
  case "$rc:$result" in
    0:copied | 0:replaced | 0:already-there) do_log "INFO $u: $result" ;;
    *) do_log "FATAL pull for $u failed (exit $rc, ${result:-no result})"; return 1 ;;
  esac
  out="$(spl_ppo_local verify "$u" "$h" "" </dev/null 2>/dev/null)"
  local path mode fowner tsha eq=no
  path="$(sed -n 's/^path //p' <<<"$out")"; mode="$(sed -n 's/^mode //p' <<<"$out")"
  fowner="$(sed -n 's/^owner //p' <<<"$out")"; tsha="$(sed -n 's/^sha //p' <<<"$out")"
  [[ -n "$tsha" && "$tsha" == "$sha" ]] && eq=yes
  echo "verify user=$u path=${path:-MISSING} mode=${mode:-?} owner=${fowner:-?} sha256_equal=$eq"
  [[ -n "$path" && "$mode" == 600 && "$fowner" == "$u" && "$eq" == yes ]] ||
    { do_log "FAIL the overlay of $u is not verified"; return 1; }
}

# spl_ppo_remote <dest> <user> sha|cat: one read as <user> on the source box.
# sha prints the file's sha256; cat streams the file to stdout (the caller
# pipes it, never stores it). A missing, empty or symlinked file exits 4.
spl_ppo_remote() {
  local dest="$1" u="$2" op="$3" script
  # shellcheck disable=SC2016 # expanded by the remote shell
  script='f="$HOME/.gcp/.csi/csi-spl-private.yaml"; [ -s "$f" ] && [ ! -L "$f" ] || exit 4
case "$1" in sha) sha256sum <"$f" | cut -d" " -f1 ;; cat) cat "$f" ;; *) exit 2 ;; esac'
  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  ssh -o BatchMode=yes "$dest" "$(printf '%q ' sudo -n -u "$u" -H bash -c "$script" spl-private-overlay-pull "$op")"
}

# spl_ppo_local put|verify <user> <home> <sha>: one step as root on this box
# (another user's home dirs may be owned by the box owner). put reads stdin.
spl_ppo_local() {
  sudo -n bash -c "$(spl_ppo_script)" spl-private-overlay-pull "$@"
}

# The local step script: put writes stdin to a temp file beside the target,
# checks its sha, then chowns, chmods 600 and renames it into place. Missing
# dirs are made 700 and owned by the user.
spl_ppo_script() {
  cat <<'SCRIPT'
op="$1" u="$2" h="$3" sha="$4"
umask 077
d="$h/.gcp/.csi" f="$h/.gcp/.csi/csi-spl-private.yaml"
case "$op" in
  put)
    for x in "$h/.gcp" "$d"; do
      [ -d "$x" ] || { mkdir "$x" && chown "$u:" "$x" && chmod 700 "$x"; } || exit 1
    done
    if [ -L "$f" ]; then echo "result target-is-symlink"; exit 1; fi
    t="$f.pull.$$"
    cat >"$t" || { rm -f "$t"; exit 1; }
    [ "$(sha256sum <"$t" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$t"; echo "result short-write"; exit 1; }
    r=copied
    if [ -f "$f" ]; then
      if cmp -s "$t" "$f"; then r=already-there; else r=replaced; fi
    fi
    chown "$u:" "$t" && chmod 600 "$t" && mv -f "$t" "$f" || { rm -f "$t"; exit 1; }
    echo "result $r" ;;
  verify)
    [ -f "$f" ] || exit 1
    echo "path $f"
    echo "mode $(stat -c %a "$f")"
    echo "owner $(stat -c %U "$f")"
    echo "sha $(sha256sum <"$f" | cut -d' ' -f1)" ;;
  *) exit 2 ;;
esac
SCRIPT
}
