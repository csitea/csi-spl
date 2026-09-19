#!/bin/bash
#------------------------------------------------------------------------------
# @description Move a box's private keys (box-*.key) out of a keys dir that
# @description lies inside $SPOOL_ROOT (002 NFR-002) into a private dir outside
# @description it. A box keyed before `spool keygen` refused such a dir still
# @description loads its key from there, and the box warns with this action as
# @description the fix. Each key is copied 0600 into a 0700 dir, compared byte
# @description for byte, and only then removed from the spool root. A key that
# @description already exists at the target with other content is refused
# @description (never overwritten); an identical one only loses its source.
# @description DRY_RUN=1 (the default) prints the plan and changes nothing.
# @description Key contents are never printed. Run it as the box's OS user, in
# @description a quiet window, then set SPOOL_KEYS_DIR as it says and restart
# @description that box's agents.
# @param SPOOL_ROOT (optional) the box spool root, default /var/spool-hub (the box default)
# @param SPOOL_KEYS_DIR (optional) the legacy keys dir, default $SPOOL_ROOT/keys
# @param SPOOL_KEYS_DIR_NEW (optional) the target, default $HOME/.spool/keys (the box default)
# @param DRY_RUN (optional) 1 (default) plan only, 0 move
# @example ./run -a do_repair_spool_keys
# @example DRY_RUN=0 SPOOL_KEYS_DIR=/var/spool-hub/keys ./run -a do_repair_spool_keys
#------------------------------------------------------------------------------
do_repair_spool_keys() {
  local dry="${DRY_RUN:-1}" root="${SPOOL_ROOT:-/var/spool-hub}"
  local src dst rroot rsrc rdst k name plan=() moves=() drops=()
  src="${SPOOL_KEYS_DIR:-${root}/keys}"
  dst="${SPOOL_KEYS_DIR_NEW:-${HOME}/.spool/keys}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 1; }

  rroot=$(realpath -m -- "$root") && rsrc=$(realpath -m -- "$src") && rdst=$(realpath -m -- "$dst") \
    || { do_log "FATAL cannot resolve SPOOL_ROOT / SPOOL_KEYS_DIR / SPOOL_KEYS_DIR_NEW"; return 1; }
  if ! _spool_keys_inside "$rsrc" "$rroot"; then
    do_log "OK $src is outside SPOOL_ROOT $root: nothing to repair"
    return 0
  fi
  if _spool_keys_inside "$rdst" "$rroot"; then
    do_log "FATAL the target SPOOL_KEYS_DIR_NEW $dst is inside SPOOL_ROOT $root too"
    return 1
  fi

  for k in "$src"/box-*.key; do
    [[ -f "$k" ]] || continue
    name=$(basename -- "$k")
    if [[ -e "$dst/$name" ]]; then
      if cmp -s -- "$k" "$dst/$name"; then
        drops+=("$k"); plan+=("rm $k   (identical copy already at $dst/$name)")
      else
        do_log "FATAL $dst/$name exists with a DIFFERENT key: resolve by hand, nothing moved"
        return 1
      fi
    else
      moves+=("$k"); plan+=("move $k -> $dst/$name (0600, dir 0700)")
    fi
  done
  if (( ${#moves[@]} + ${#drops[@]} == 0 )); then
    do_log "OK no box-*.key in $src: nothing to move"
    return 0
  fi

  do_log "INFO keys dir $src is inside SPOOL_ROOT $root (002 NFR-002); plan:"
  printf '    %s\n' "${plan[@]}"
  if [[ "$dry" == 1 ]]; then
    do_log "OK dry run: nothing changed; apply with DRY_RUN=0 in a quiet window"
    return 0
  fi

  (umask 077 && mkdir -p -- "$dst") && chmod 700 -- "$dst" || { do_log "FATAL cannot create $dst"; return 1; }
  for k in "${moves[@]}"; do
    name=$(basename -- "$k")
    if ! (umask 077 && cp -- "$k" "$dst/.$name.tmp") || ! chmod 600 -- "$dst/.$name.tmp" \
      || ! cmp -s -- "$k" "$dst/.$name.tmp" || ! mv -n -- "$dst/.$name.tmp" "$dst/$name" \
      || ! cmp -s -- "$k" "$dst/$name"; then
      rm -f -- "$dst/.$name.tmp"
      do_log "FATAL copying $k to $dst failed; the source is kept"
      return 1
    fi
    drops+=("$k")
  done
  for k in "${drops[@]}"; do
    rm -f -- "$k" || { do_log "FATAL cannot remove $k (the copy at $dst is good)"; return 1; }
  done
  rmdir -- "$src" 2>/dev/null || true

  do_log "OK ${#drops[@]} key(s) now in $dst, none left in $src"
  if [[ "$rdst" == "$(realpath -m -- "${HOME}/.spool/keys")" ]]; then
    do_log "INFO now: unset SPOOL_KEYS_DIR (the box default is $dst) and restart this box's agents"
  else
    do_log "INFO now: export SPOOL_KEYS_DIR=$dst and restart this box's agents"
  fi
}

# _spool_keys_inside <path> <root>: both resolved; true when path is root or under it.
_spool_keys_inside() {
  [[ "$1" == "$2" || "$1" == "$2"/* ]]
}
